import AppKit
import Combine
import NoPeekCore
import SwiftUI

enum SettingsTab: Hashable {
    case general, apps, intruder, caught, permissions
}

/// Wires every component together and owns the "guarded" owner actions.
@MainActor
final class AppCoordinator: ObservableObject {
    static let shared = AppCoordinator()

    let settingsStore = SettingsStore()
    let captureStore = CaptureStore()
    let vault = SecretVault()
    let notifier = Notifier()
    let engine: LockEngine
    let shield = ShieldController()
    let inputGuard = InputGuard()
    let preview: PreviewController

    @Published var settingsTab: SettingsTab = .general

    private let camera = CameraCapture()
    private var settingsWindow: NSWindow?
    private var lockAllHotKey: GlobalHotKey?
    private var registeredLockAllShortcut: KeyShortcut??
    private var cancellables: Set<AnyCancellable> = []
    private var allowTerminate = false
    private var signalSources: [DispatchSourceSignal] = []

    private init() {
        engine = LockEngine(settingsStore: settingsStore, captureStore: captureStore, vault: vault,
                            camera: camera, notifier: notifier, shield: shield)
        preview = PreviewController(engine: engine)
    }

    // MARK: Startup

    func start() {
        notifier.activate()
        notifier.onOpen = { [weak self] in self?.openSettings(tab: .caught) }

        engine.onLocksEngaged = { [weak self] in
            // Never leave Settings open for whoever sits down next.
            self?.settingsWindow?.close()
            self?.preview.close()
        }
        engine.start()

        // `pkill`/logout send SIGTERM, which skips the normal quit path: still unhide apps first.
        // The handler runs off the main thread so a stuck main thread can't block it: we ask the
        // main thread to unhide apps, but exit regardless (the next launch unhides anything left).
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global(qos: .userInitiated))
            source.setEventHandler { [weak self] in
                onMainRunLoop {
                    self?.engine.revealAllHidden()
                    self?.settingsStore.saveNow()
                }
                // Give the window server a moment to deliver the unhide requests, then leave without
                // running exit handlers (camera/XPC teardown in exit() could hang the process).
                armHardExit(after: 0.4)
            }
            source.resume()
            signalSources.append(source)
        }

        OwnerAuth.onProgressChange = { [weak self] inProgress in
            self?.shield.setAuthenticating(inProgress)
        }

        inputGuard.shouldIntercept = { [weak self] pid in
            guard let self, let app = NSRunningApplication(processIdentifier: pid),
                  let bundleID = app.bundleIdentifier else { return false }
            return self.engine.isLocked(bundleID)
        }
        inputGuard.onInterceptedKeyDown = { [weak self] event in
            guard let self, let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                  let session = self.engine.session(forBundleID: bundleID) else { return }
            session.handleKey(event)
        }
        startInputGuardWhenTrusted()
        engine.$sessions
            .map { sessions in sessions.values.contains { !$0.isFinished } }
            .removeDuplicates()
            .sink { [weak self] locked in self?.inputGuard.setActive(locked) }
            .store(in: &cancellables)

        settingsStore.$settings
            .map(\.lockAllShortcut)
            .removeDuplicates()
            .sink { [weak self] shortcut in self?.registerLockAllHotKey(shortcut) }
            .store(in: &cancellables)

        captureStore.purge(olderThanDays: settingsStore.settings.catchConfig.retentionDays)
        Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(6 * 3600))
                guard let self else { return }
                self.captureStore.purge(olderThanDays: self.settingsStore.settings.catchConfig.retentionDays)
            }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.allowTerminate = true }
        }

        // Dev/testing flags: `open NoPeek.app --args --lock-all` or `--preview`.
        let args = CommandLine.arguments
        log.info("Camera permission: \(CameraCapture.isAuthorized ? "authorized" : "NOT authorized", privacy: .public)")
        if args.contains("--test-capture") {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let result = await self.engine.selfTestCapture()
                log.info("Self-test capture: \(result, privacy: .public)")
            }
        } else if args.contains("--lock-all") {
            after(1) { [weak self] in self?.engine.lockAll() }
        } else if args.contains("--preview"), let app = settingsStore.settings.apps.first {
            after(1) { [weak self] in self?.showPreview(for: app) }
        } else if settingsStore.isFirstLaunch {
            openSettings(tab: .permissions)
        }
    }

    private func startInputGuardWhenTrusted() {
        Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.inputGuard.startIfPossible() { return }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func registerLockAllHotKey(_ shortcut: KeyShortcut?) {
        lockAllHotKey?.unregister()
        lockAllHotKey = nil
        guard let shortcut else { return }
        lockAllHotKey = GlobalHotKey(shortcut: shortcut) { [weak self] in
            self?.engine.lockAll()
        }
    }

    // MARK: Guarded actions

    /// Anything that weakens protection needs Touch ID/password while an app is locked.
    func guarded(_ reason: String, _ action: @escaping @MainActor () -> Void) {
        guard engine.hasActiveLocks else {
            action()
            return
        }
        Task { @MainActor in
            if await OwnerAuth.verify(reason: reason) { action() }
        }
    }

    func openSettings(tab: SettingsTab? = nil) {
        guarded("open NoPeek settings") { [weak self] in
            guard let self else { return }
            if let tab { self.settingsTab = tab }
            self.showSettingsWindow()
        }
    }

    func unlockFromMenu(_ app: ProtectedApp) {
        guarded("unlock \(app.name)") { [weak self] in
            self?.engine.unlock(bundleID: app.bundleID, animated: true)
        }
    }

    func pause(for duration: TimeInterval?) {
        guarded("pause NoPeek") { [weak self] in self?.engine.pause(for: duration) }
    }

    func requestQuit() {
        guarded("quit NoPeek") { [weak self] in
            self?.allowTerminate = true
            // Not inline: after Touch ID this runs inside a main-actor task, and terminate's nested
            // run loop would wait forever for a reply that needs that same task to finish first.
            onMainRunLoop { NSApp.terminate(nil) }
        }
    }

    func shouldTerminate() -> NSApplication.TerminateReply {
        if allowTerminate || !engine.hasActiveLocks {
            return revealThenTerminate()
        }
        Task { @MainActor in
            let ok = await OwnerAuth.verify(reason: "quit NoPeek")
            if ok {
                allowTerminate = true
                engine.revealAllHidden()
                try? await Task.sleep(for: .milliseconds(400))
                armHardExit(after: 3)
            }
            NSApp.reply(toApplicationShouldTerminate: ok)
        }
        return .terminateLater
    }

    /// Unhide locked apps, give the window server a moment, then quit.
    private func revealThenTerminate() -> NSApplication.TerminateReply {
        engine.revealAllHidden()
        settingsStore.saveNow()
        // A run-loop timer (not a task) so it fires inside AppKit's `.terminateLater` wait loop.
        onMainRunLoop(after: 0.4) { NSApp.reply(toApplicationShouldTerminate: true) }
        // If AppKit's own teardown ever stalls, don't leave a zombie NoPeek behind.
        armHardExit(after: 3)
        return .terminateLater
    }

    func protect(_ running: NSRunningApplication) {
        guard let bundleID = running.bundleIdentifier,
              !settingsStore.settings.apps.contains(where: { $0.bundleID == bundleID }) else { return }
        settingsStore.settings.apps.append(ProtectedApp(bundleID: bundleID, name: running.localizedName ?? bundleID))
    }

    func showPreview(for app: ProtectedApp) {
        preview.show(app: app, settings: settingsStore.settings,
                     digest: app.unlock.hasSecretWord ? vault.digest(for: app.id) : nil)
    }

    // MARK: Settings window

    private func showSettingsWindow() {
        if settingsWindow == nil {
            let root = SettingsView()
                .environmentObject(self)
                .environmentObject(settingsStore)
                .environmentObject(captureStore)
                .environmentObject(engine)
            let window = NSWindow(contentViewController: NSHostingController(rootView: root))
            window.title = "NoPeek"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 820, height: 580))
            window.minSize = NSSize(width: 720, height: 500)
            window.isReleasedWhenClosed = false
            window.center()
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                // Back to a pure menu-bar app once Settings closes.
                MainActor.assumeIsolated { _ = NSApp.setActivationPolicy(.accessory) }
            }
            settingsWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
