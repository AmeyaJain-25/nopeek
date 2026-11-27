import AppKit
import Combine
import NoPeekCore

enum LockReason {
    case idle, manual, system, switchedAway
}

/// Decides what is locked and when (idle, screen lock, sleep, switch-away, pause, owner unlocks)
/// and how a locked app is presented:
/// - in the background → the app is hidden (⌘H), so its content is gone from every Space/display;
/// - brought to the front → the full-screen lock shield appears on top of it.
/// Everything is event-driven; nothing polls window positions.
@MainActor
final class LockEngine: ObservableObject {
    @Published private(set) var sessions: [String: LockSession] = [:]
    @Published private(set) var pausedUntil: Date?

    /// Called whenever at least one app becomes locked (used to close Settings).
    var onLocksEngaged: (() -> Void)?

    private let settingsStore: SettingsStore
    private let captureStore: CaptureStore
    private let vault: SecretVault
    private let camera: CameraCapture
    private let notifier: Notifier
    private let shield: ShieldController
    /// Apps NoPeek hid, so only those get unhidden again. Persisted so that even after a crash
    /// or force-quit, the next launch brings them back.
    private var hiddenByUs: Set<String> = Set(UserDefaults.standard.stringArray(forKey: LockEngine.hiddenKey) ?? []) {
        didSet { UserDefaults.standard.set(Array(hiddenByUs), forKey: Self.hiddenKey) }
    }
    private static let hiddenKey = "engine.hiddenByUs"
    /// Apps with switch-away locking you just left; their timer starts once a real app takes over.
    private var pendingSwitchAway: Set<String> = []
    /// Running "lock after switching away" timers, cancelled if you come back first.
    private var switchAwayTimers: [String: Task<Void, Never>] = [:]
    /// A real app must stay in front this long before the app you left locks (absorbs ⌘Tab bounces).
    private static let switchAwayGrace: TimeInterval = 0.6

    /// System UI that briefly takes focus but isn't "switching to another app".
    private static let transientBundleIDs: Set<String> = [
        "com.apple.dock",                    // Mission Control, App Exposé, Launchpad
        "com.apple.Spotlight",
        "com.apple.notificationcenterui",
        "com.apple.controlcenter",
        "com.apple.WindowManager",           // Stage Manager
        "com.apple.systemuiserver",
        "com.apple.screencaptureui",
        "com.apple.screenshot.launcher",
        "com.apple.CharacterPaletteIM",      // emoji picker
        "com.apple.SecurityAgent",
        "com.apple.coreautha",
        "com.apple.LocalAuthentication.UIAgent",
        "com.apple.UserNotificationCenter",
        "com.apple.loginwindow",
        "com.apple.universalcontrol",
        "com.apple.PIPAgent",
        "com.raycast.macos",
        "com.runningwithcrayons.Alfred",
    ]

    /// A real, user-facing app (has a Dock icon) — as opposed to system UI and pop-up agents.
    private static func isRealApp(_ app: NSRunningApplication) -> Bool {
        guard let id = app.bundleIdentifier else { return false }
        return app.activationPolicy == .regular && !transientBundleIDs.contains(id) && id != Bundle.main.bundleIdentifier
    }
    private var tickTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []

    init(settingsStore: SettingsStore, captureStore: CaptureStore, vault: SecretVault,
         camera: CameraCapture, notifier: Notifier, shield: ShieldController) {
        self.shield = shield
        self.settingsStore = settingsStore
        self.captureStore = captureStore
        self.vault = vault
        self.camera = camera
        self.notifier = notifier
    }

    private var settings: AppSettings { settingsStore.settings }

    // MARK: Queries

    var activeSessions: [LockSession] { sessions.values.filter { !$0.isFinished } }
    var hasActiveLocks: Bool { !activeSessions.isEmpty }
    var isPaused: Bool { pausedUntil.map { $0 > Date() } ?? false }

    func isLocked(_ bundleID: String) -> Bool {
        sessions[bundleID].map { !$0.isFinished } ?? false
    }

    func session(forBundleID bundleID: String) -> LockSession? {
        sessions[bundleID]
    }

    // MARK: Lifecycle

    func start() {
        // Recover from a previous run that ended without unhiding (crash, kill -9).
        revealAllHidden()

        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .seconds(1))
            }
        }

        let distributed = DistributedNotificationCenter.default()
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.settings.lockOnScreenLock else { return }
                self.lockAll(reason: .system)
            }
        })
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // Getting past the macOS lock screen proves it's the owner.
                guard let self, self.settings.trustSystemUnlock else { return }
                self.unlockAll(animated: false)
            }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.settings.lockOnScreenLock else { return }
                    self.lockAll(reason: .system)
                }
            })
        }

        // "Immediately" apps: leaving them only marks them; they lock once a *real* app takes over
        // (see handleActivation). Mission Control, Spotlight, pop-ups etc. don't count.
        observers.append(workspace.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let running = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                // `sessions[bundleID] == nil`: not locked, and not mid "welcome back" either.
                guard let self, !self.isPaused, let bundleID = running?.bundleIdentifier,
                      self.sessions[bundleID] == nil,
                      let app = self.settings.apps.first(where: { $0.bundleID == bundleID && $0.isEnabled }),
                      self.settings.locksOnSwitchAway(app) else { return }
                self.pendingSwitchAway.insert(bundleID)
                // Activation and deactivation can arrive in either order; if a real app is
                // already in front, act now.
                self.lockLeftAppsIfTakenOver(by: NSWorkspace.shared.frontmostApplication)
            }
        })

        // Locked app brought forward → shield it. Anything else brought forward → hide locked apps.
        observers.append(workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let running = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self, let running else { return }
                self.handleActivation(of: running)
            }
        })

        // Swiping between Spaces: keep the shield only where the locked app actually is.
        observers.append(workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // Let the swipe animation and window list settle first.
                _ = after(0.25) { self?.handleSpaceChange() }
            }
        })

        // Apps removed/disabled in settings shouldn't stay locked.
        settingsStore.$settings
            .sink { [weak self] _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.reconcileWithSettings() } }
            }
            .store(in: &cancellables)
    }

    // MARK: Locking

    func lock(_ app: ProtectedApp, reason: LockReason = .manual) {
        guard app.isEnabled else { return }
        if let existing = sessions[app.bundleID] {
            if !existing.isFinished { return }
            // Still fading out from an unlock: tear that shield down now so it can't be stranded.
            existing.cancelTimers()
            shield.hide(ifShowing: existing)
        }

        let session = LockSession(
            app: app,
            theme: settings.theme.resolved(),
            ownerName: settings.ownerDisplayName,
            catchConfig: settings.catchConfig,
            digest: app.unlock.hasSecretWord ? vault.digest(for: app.id) : nil
        )
        session.delegate = self
        sessions[app.bundleID] = session
        log.info("Locked \(app.name, privacy: .public) (\(String(describing: reason), privacy: .public))")
        present(session)
        // Switching apps (e.g. opening NoPeek Settings) shouldn't slam Settings shut.
        if reason != .switchedAway { onLocksEngaged?() }
    }

    func lockAll(reason: LockReason = .manual) {
        for app in settings.apps where app.isEnabled {
            lock(app, reason: reason)
        }
    }

    // MARK: Unlocking

    /// - Parameter activate: bring the app to the front once the shield is gone (owner unlocked from the shield).
    func unlock(bundleID: String, animated: Bool, activate: Bool = false) {
        guard let session = sessions[bundleID], !session.isFinished else { return }
        let now = Date()

        // Photos taken right before the owner got in were the owner fumbling: delete them.
        let discarded = OwnerGrace.recordsToDiscard(session.captures, unlockDate: now,
                                                    graceSeconds: settings.catchConfig.ownerGraceSeconds)
        let discardedIDs = Set(discarded.map(\.id))
        captureStore.delete(ids: discardedIDs)
        session.removeCaptures(ids: discardedIDs)
        if !discarded.isEmpty || !session.captures.isEmpty {
            log.info("Unlock: discarded \(discarded.count) photo(s) taken within the \(self.settings.catchConfig.ownerGraceSeconds)s \"it was me\" grace; kept \(session.captures.count)")
        }
        report(keptCaptures: session.captures, app: session.app)

        session.finish(discardedPhoto: !discarded.isEmpty)
        log.info("Unlocked \(session.app.name, privacy: .public)")

        let showingShield = shield.session === session
        let linger: TimeInterval = animated && showingShield ? (discarded.isEmpty ? 0.9 : 1.8) : 0
        let remove = { [weak self, weak session] in
            guard let self, let session else { return }
            // Always take this session's shield down, even if a newer session replaced it.
            self.shield.hide(ifShowing: session)
            guard self.sessions[bundleID] === session else { return }
            self.sessions[bundleID] = nil
            // Switched to another app during the "welcome back"? Don't yank the app forward, and
            // treat it as leaving (so switch-away locking still applies).
            let front = NSWorkspace.shared.frontmostApplication
            let movedOn = front.map { $0.bundleIdentifier != bundleID && Self.isRealApp($0) } ?? false
            self.reveal(bundleID: bundleID, activate: activate && !movedOn)
            if movedOn, self.settings.locksOnSwitchAway(session.app) {
                self.pendingSwitchAway.insert(bundleID)
                self.lockLeftAppsIfTakenOver(by: front)
            }
        }
        if linger > 0 { after(linger, remove) } else { remove() }
    }

    func unlockAll(animated: Bool, activating activeBundleID: String? = nil) {
        for bundleID in sessions.keys {
            unlock(bundleID: bundleID, animated: animated, activate: bundleID == activeBundleID)
        }
    }

    /// Unhide everything NoPeek hid (used on quit so nothing stays hidden).
    func revealAllHidden() {
        for bundleID in hiddenByUs {
            reveal(bundleID: bundleID, activate: false)
        }
        shield.hide()
    }

    // MARK: Pause

    func pause(for duration: TimeInterval?) {
        pausedUntil = duration.map { Date().addingTimeInterval($0) } ?? .distantFuture
        unlockAll(animated: false)
    }

    func resume() {
        pausedUntil = nil
    }

    // MARK: Private

    private func tick() {
        if let until = pausedUntil {
            if until > Date() { return }
            pausedUntil = nil
        }
        let idle = IdleMonitor.secondsSinceLastInput()
        // In whole-Mac mode `idleTimeout(for:)` is the same Mac-wide value for every app, so they all
        // lock on the same tick; switch-away is off there too (`switchAwayDelay` returns nil).
        for app in settings.apps where app.isEnabled && sessions[app.bundleID] == nil {
            if let timeout = settings.idleTimeout(for: app), idle >= TimeInterval(timeout) {
                lock(app, reason: .idle)
            }
        }
    }

    private func reconcileWithSettings() {
        let enabled = Set(settings.apps.filter(\.isEnabled).map(\.bundleID))
        for (bundleID, session) in sessions where !enabled.contains(bundleID) {
            session.cancelTimers()
            sessions[bundleID] = nil
            shield.hide(ifShowing: session)
            reveal(bundleID: bundleID, activate: false)
        }
    }

    // MARK: Presentation

    private func present(_ session: LockSession) {
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == session.bundleID {
            shield.show(session)
        } else {
            hide(bundleID: session.bundleID)
        }
    }

    private func handleActivation(of app: NSRunningApplication) {
        // Touch ID / password sheets briefly take focus; don't react to that.
        guard !OwnerAuth.isInProgress else { return }
        guard let bundleID = app.bundleIdentifier, bundleID != Bundle.main.bundleIdentifier else { return }

        // Came back to an "Immediately" app before anything else took over: stay unlocked.
        pendingSwitchAway.remove(bundleID)
        switchAwayTimers.removeValue(forKey: bundleID)?.cancel()

        if let session = sessions[bundleID], !session.isFinished {
            shield.show(session)
            return
        }

        guard Self.isRealApp(app) else {
            // Mission Control / App Exposé: keep locked content out of the window previews.
            if bundleID == "com.apple.dock", let shown = shield.session, !shown.isFinished {
                shield.hide()
                hide(bundleID: shown.bundleID)
            }
            // Other system UI (Spotlight, notifications, emoji picker, auth sheets…): ignore.
            return
        }

        // A real app took over.
        lockLeftAppsIfTakenOver(by: app)
        if let shown = shield.session, !shown.isFinished {
            shield.hide()
        }
        for session in activeSessions {
            hide(bundleID: session.bundleID)
        }
    }

    /// Starts the "lock after switching away" timer for apps you left, once a real app (not the
    /// one you left) is in front. Coming back before it fires cancels it (see handleActivation).
    private func lockLeftAppsIfTakenOver(by front: NSRunningApplication?) {
        guard !pendingSwitchAway.isEmpty, let front, let frontID = front.bundleIdentifier,
              !pendingSwitchAway.contains(frontID), Self.isRealApp(front) else { return }
        let left = pendingSwitchAway
        pendingSwitchAway.removeAll()
        for leftID in left {
            guard let app = settings.apps.first(where: { $0.bundleID == leftID && $0.isEnabled }),
                  let delay = settings.switchAwayDelay(for: app) else { continue }
            // Even "Immediately" waits a beat so a quick ⌘Tab out-and-back never locks.
            let wait = max(Self.switchAwayGrace, TimeInterval(delay))
            log.info("Left \(leftID, privacy: .public) for \(frontID, privacy: .public): locking in \(wait)s unless you come back")
            switchAwayTimers[leftID]?.cancel()
            switchAwayTimers[leftID] = after(wait) { [weak self] in
                guard let self else { return }
                self.switchAwayTimers[leftID] = nil
                guard !self.isPaused, self.sessions[leftID] == nil,
                      NSWorkspace.shared.frontmostApplication?.bundleIdentifier != leftID,
                      let protected = self.settings.apps.first(where: { $0.bundleID == leftID && $0.isEnabled }),
                      self.settings.locksOnSwitchAway(protected) else { return }
                self.lock(protected, reason: .switchedAway)
            }
        }
    }

    private func handleSpaceChange() {
        guard let session = shield.session, !session.isFinished else { return }
        if ShieldController.hasVisibleWindow(bundleID: session.bundleID) {
            // The locked app is on the Space now showing: (re)create the shield here, so it can
            // never be stranded on the Space you swiped away from.
            shield.show(session, forceRebuild: true)
        } else {
            // You swiped somewhere the locked app isn't: no shield here; tuck the app away.
            shield.hide()
            hide(bundleID: session.bundleID)
        }
    }

    private func hide(bundleID: String) {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) where !app.isHidden {
            // hide()'s return value isn't reliable (it can hide yet return false), so always record it.
            hiddenByUs.insert(bundleID)
            app.hide()
        }
    }

    private func reveal(bundleID: String, activate: Bool) {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        if hiddenByUs.remove(bundleID) != nil {
            apps.forEach { $0.unhide() }
        }
        if activate {
            apps.first?.activate()
        }
    }

    private func report(keptCaptures: [CaptureRecord], app: ProtectedApp) {
        guard let latest = keptCaptures.max(by: { $0.date < $1.date }) else { return }
        let count = keptCaptures.count
        notifier.post(
            title: "🚨 Caught \(count == 1 ? "a snooper" : "\(count) snoopers") on \(app.name)",
            body: "Someone kept trying to get into \(app.name) while you were away. Tap to see who.",
            imageURL: captureStore.url(for: latest)
        )
    }

    /// Diagnostics: runs the real camera → save pipeline once and reports the result.
    func selfTestCapture() async -> String {
        let status: String
        switch CameraCapture.status {
        case .authorized: status = "authorized"
        case .denied: status = "denied"
        case .restricted: status = "restricted"
        case .notDetermined: status = "not asked yet"
        @unknown default: status = "unknown"
        }
        do {
            let data = try await camera.capturePhoto()
            guard let record = captureStore.add(imageData: data, date: Date(), bundleID: "io.github.ameyajain-25.nopeek.selftest",
                                                appName: "NoPeek self-test", attempt: 0) else {
                return "camera=\(status) captured=\(data.count)B saved=false"
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: captureStore.url(for: record).path)[.size] as? Int) ?? 0
            return "camera=\(status) captured=\(data.count)B saved=\(record.fileName) fileSize=\(size)B"
        } catch {
            return "camera=\(status) error=\(error)"
        }
    }

    /// Takes the photo. `persist: false` is used by the settings preview.
    func capturePhoto(for session: LockSession, attempt: Int, persist: Bool) {
        Task { @MainActor in
            let data: Data?
            do {
                data = try await camera.capturePhoto()
            } catch {
                log.info("No photo taken: \(String(describing: error), privacy: .public)")
                data = nil
            }
            let image = data.flatMap(NSImage.init(data:))

            var record: CaptureRecord?
            if persist, let data {
                record = captureStore.add(imageData: data, date: Date(), bundleID: session.bundleID,
                                          appName: session.app.name, attempt: attempt)
                if let record {
                    log.info("Saved photo \(record.fileName, privacy: .public) for \(session.app.name, privacy: .public) (try #\(attempt))")
                } else {
                    log.error("Camera returned data but saving the photo failed")
                }
            }

            if session.isFinished {
                // The owner unlocked while the camera was busy: that photo is the owner.
                if let record, let finishedAt = session.finishedAt,
                   OwnerGrace.shouldDiscard(captureDate: record.date, unlockDate: finishedAt,
                                            graceSeconds: settings.catchConfig.ownerGraceSeconds) {
                    captureStore.delete(ids: [record.id])
                }
                return
            }
            session.showCaught(image: image, record: record)
        }
    }
}

extension LockEngine: LockSessionDelegate {
    func sessionDidAuthenticate(_ session: LockSession) {
        if settings.unlockAllTogether {
            unlockAll(animated: true, activating: session.bundleID)
        } else {
            unlock(bundleID: session.bundleID, animated: true, activate: true)
        }
    }

    func sessionRequestsCapture(_ session: LockSession, attempt: Int) {
        capturePhoto(for: session, attempt: attempt, persist: true)
    }
}
