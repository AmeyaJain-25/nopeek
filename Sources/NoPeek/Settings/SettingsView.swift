import AppKit
import AVFoundation
import NoPeekCore
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject private var coordinator: AppCoordinator

    var body: some View {
        TabView(selection: $coordinator.settingsTab) {
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
            AppsTab().tabItem { Label("Apps", systemImage: "square.grid.2x2") }.tag(SettingsTab.apps)
            IntruderTab().tabItem { Label("Intruder Catch", systemImage: "camera.viewfinder") }.tag(SettingsTab.intruder)
            CaughtTab().tabItem { Label("Caught", systemImage: "photo.on.rectangle.angled") }.tag(SettingsTab.caught)
            PermissionsTab().tabItem { Label("Permissions", systemImage: "lock.shield") }.tag(SettingsTab.permissions)
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 500)
    }
}

// MARK: - Lock timing choices

private let switchAwayChoices: [Int] = [LockDelay.never, LockDelay.immediately, 5, 10, 30, 60, 120, 300, 600]
private let idleChoices: [Int] = [LockDelay.never, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800]

private func switchAwayLabel(_ seconds: Int) -> String {
    if seconds < 0 { return "Never" }
    if seconds == LockDelay.immediately { return "Immediately" }
    return "After \(DurationText.short(seconds))"
}

private func idleLabel(_ seconds: Int) -> String {
    seconds < 0 ? "Never" : "After \(DurationText.short(seconds))"
}

/// Plain-English rule for when this app locks, reflecting per-app overrides.
private func lockRuleDescription(for app: ProtectedApp, settings: AppSettings) -> String {
    func origin(_ override: Int?) -> String { override == nil ? "default" : "own setting" }
    if settings.lockTrigger == .wholeMac {
        guard let idle = settings.idleTimeout(for: app) else {
            return "\(app.name) never locks on its own, only with Lock All, the Mac's screen lock/sleep, or the menu."
        }
        return "\(app.name) locks with everything else after the whole Mac has had no keyboard/mouse input for \(DurationText.short(idle)). Switching apps doesn't lock it."
    }
    var parts: [String] = []
    if let delay = settings.switchAwayDelay(for: app) {
        let when = delay == 0 ? "as soon as you switch to another app" : "\(DurationText.short(delay)) after you switch to another app"
        parts.append("\(when) (\(origin(app.switchAwayLockSeconds)))")
    }
    if let idle = settings.idleTimeout(for: app) {
        parts.append("after \(DurationText.short(idle)) with no keyboard/mouse input (\(origin(app.idleLockSeconds)))")
    }
    if parts.isEmpty {
        return "\(app.name) never locks on its own, only with Lock All, the Mac's screen lock/sleep, or the menu."
    }
    return "\(app.name) locks " + parts.joined(separator: ", or ") + ", whichever comes first."
}

private let switchAwayFootnote = "Switching means another real app takes over. Mission Control, Spotlight, notifications and pop-ups don't count, and coming back before the time is up cancels it."

// MARK: - General

private struct GeneralTab: View {
    @EnvironmentObject private var store: SettingsStore
    @EnvironmentObject private var coordinator: AppCoordinator
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?

    var body: some View {
        Form {
            Section("You") {
                TextField("Your name", text: $store.settings.ownerName, prompt: Text("e.g. Alex"))
                Text("Shown to snoopers: “Reporting to \(store.settings.ownerDisplayName)…”")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Locking") {
                Picker("Lock based on", selection: $store.settings.lockTrigger) {
                    ForEach(LockTrigger.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                if store.settings.lockTrigger == .wholeMac {
                    Picker("Lock everything after the Mac is idle", selection: $store.settings.macIdleLockSeconds) {
                        ForEach(idleChoices, id: \.self) { Text(idleLabel($0)).tag($0) }
                    }
                } else {
                    Picker("Default: lock after switching away", selection: $store.settings.defaultSwitchAwayLockSeconds) {
                        ForEach(switchAwayChoices, id: \.self) { Text(switchAwayLabel($0)).tag($0) }
                    }
                    Picker("Default: lock after no input (idle)", selection: $store.settings.defaultIdleLockSeconds) {
                        ForEach(idleChoices, id: \.self) { Text(idleLabel($0)).tag($0) }
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    if store.settings.lockTrigger == .wholeMac {
                        Text("One timer for the whole Mac: any keyboard, mouse or trackpad input anywhere resets it, so you can keep working in other apps without anything locking. Each app's own timers are ignored (but kept) while this is on.")
                    } else {
                        Text("Both timers run independently; whichever fires first locks the app. Each app can override either one in the Apps tab.")
                        Text(switchAwayFootnote)
                    }
                    ForEach(store.settings.apps.filter(\.isEnabled)) { app in
                        Text("• " + lockRuleDescription(for: app, settings: store.settings))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Toggle("Lock when the screen locks or the Mac sleeps", isOn: $store.settings.lockOnScreenLock)
                Toggle("Unlock everything when I unlock my Mac", isOn: $store.settings.trustSystemUnlock)
                Toggle("Unlocking one app unlocks all of them", isOn: $store.settings.unlockAllTogether)
                LabeledContent("Lock all now (global shortcut)") {
                    ShortcutRecorder(shortcut: $store.settings.lockAllShortcut)
                }
            }

            Section("Look") {
                Picker("Overlay theme", selection: $store.settings.theme) {
                    ForEach(OverlayThemeID.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Button("Preview Overlay") {
                    if let app = store.settings.apps.first {
                        coordinator.showPreview(for: app)
                    }
                }
                .disabled(store.settings.apps.isEmpty)
            }

            Section("Startup") {
                Toggle("Launch NoPeek at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            launchError = nil
                        } catch {
                            launchError = error.localizedDescription
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let launchError {
                    Text(launchError).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Apps

private struct AppsTab: View {
    @EnvironmentObject private var store: SettingsStore
    @State private var selection: UUID?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.settings.apps) { app in
                        HStack(spacing: 10) {
                            Image(nsImage: AppIcons.icon(for: app.bundleID)).resizable().frame(width: 22, height: 22)
                            Text(app.name)
                            Spacer()
                            if !app.isEnabled { Text("off").font(.caption).foregroundStyle(.secondary) }
                        }
                        .tag(app.id)
                    }
                }
                Divider()
                HStack(spacing: 4) {
                    AddAppMenu(selection: $selection)
                    Button {
                        guard let selection else { return }
                        store.settings.apps.removeAll { $0.id == selection }
                        self.selection = store.settings.apps.first?.id
                    } label: {
                        Image(systemName: "minus").frame(width: 20, height: 18)
                    }
                    .buttonStyle(.borderless)
                    .disabled(selection == nil)
                    Spacer()
                }
                .padding(6)
            }
            .frame(width: 220)
            .background(.background.secondary)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Group {
                if let selection, store.app(withID: selection) != nil {
                    AppDetail(appID: selection).id(selection)
                } else {
                    ContentUnavailableView("Pick an app", systemImage: "hand.point.left",
                                           description: Text("Add any app you want NoPeek to guard."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { selection = selection ?? store.settings.apps.first?.id }
    }
}

private struct AddAppMenu: View {
    @EnvironmentObject private var store: SettingsStore
    @Binding var selection: UUID?

    var body: some View {
        Menu {
            Section("Running apps") {
                ForEach(runningApps, id: \.processIdentifier) { app in
                    Button(app.localizedName ?? app.bundleIdentifier ?? "App") {
                        add(bundleID: app.bundleIdentifier, name: app.localizedName)
                    }
                }
            }
            Divider()
            Button("Choose from Applications…", action: chooseFromDisk)
        } label: {
            Image(systemName: "plus").frame(width: 20, height: 18)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var runningApps: [NSRunningApplication] {
        let existing = Set(store.settings.apps.map(\.bundleID))
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil
                && $0.bundleIdentifier != Bundle.main.bundleIdentifier && !existing.contains($0.bundleIdentifier!) }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private func chooseFromDisk() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url) else { return }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        add(bundleID: bundle.bundleIdentifier, name: name)
    }

    private func add(bundleID: String?, name: String?) {
        guard let bundleID, !store.settings.apps.contains(where: { $0.bundleID == bundleID }) else { return }
        let app = ProtectedApp(bundleID: bundleID, name: name ?? bundleID)
        store.settings.apps.append(app)
        selection = app.id
    }
}

private struct AppDetail: View {
    @EnvironmentObject private var store: SettingsStore
    @EnvironmentObject private var coordinator: AppCoordinator
    let appID: UUID

    @State private var newSecret = ""
    @State private var secretError: String?
    @State private var editingSecret = false

    private var app: Binding<ProtectedApp> {
        Binding(
            get: { store.app(withID: appID) ?? ProtectedApp(id: appID, bundleID: "", name: "") },
            set: { store.update(app: $0) }
        )
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: AppIcons.icon(for: app.wrappedValue.bundleID)).resizable().frame(width: 48, height: 48)
                    VStack(alignment: .leading) {
                        Text(app.wrappedValue.name).font(.title2.weight(.semibold))
                        Text(app.wrappedValue.bundleID).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    Toggle("Protect", isOn: app.isEnabled).toggleStyle(.switch)
                }
            }

            Section {
                if store.settings.lockTrigger == .wholeMac {
                    Label("Overridden: General → Lock based on is set to whole Mac inactivity. These per-app settings apply again if you switch back.",
                          systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
                Picker("Lock after switching away", selection: app.switchAwayLockSeconds) {
                    Text("Default (\(switchAwayLabel(store.settings.defaultSwitchAwayLockSeconds).lowercased()))").tag(Int?.none)
                    Divider()
                    ForEach(switchAwayChoices, id: \.self) { Text(switchAwayLabel($0)).tag(Int?.some($0)) }
                }
                .disabled(store.settings.lockTrigger == .wholeMac)
                Picker("Lock after no input (idle)", selection: app.idleLockSeconds) {
                    Text("Default (\(idleLabel(store.settings.defaultIdleLockSeconds).lowercased()))").tag(Int?.none)
                    Divider()
                    ForEach(idleChoices, id: \.self) { Text(idleLabel($0)).tag(Int?.some($0)) }
                }
                .disabled(store.settings.lockTrigger == .wholeMac)
            } header: {
                Text("When to lock")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(lockRuleDescription(for: app.wrappedValue, settings: store.settings))
                    if store.settings.lockTrigger == .perApp { Text(switchAwayFootnote) }
                }
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                LabeledContent("Secret hotkey") {
                    ShortcutRecorder(shortcut: app.unlock.hotkey)
                }
                secretWordRow
                Toggle("Show a discreet Touch ID button", isOn: app.unlock.touchID)
            } header: {
                Text("Your way in")
            } footer: {
                if !app.wrappedValue.unlock.hasAnyMethod {
                    Label("No unlock method set. You can still unlock from the menu bar with Touch ID.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else {
                    Text("Nobody else sees these. Snoopers just see the overlay; you press the hotkey or type the word on it.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button("Test Lock Screen") { coordinator.showPreview(for: app.wrappedValue) }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var secretWordRow: some View {
        if app.wrappedValue.unlock.hasSecretWord && !editingSecret {
            LabeledContent("Secret word") {
                HStack {
                    Label("Set", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Button("Change") { editingSecret = true }
                    Button("Remove", role: .destructive) {
                        coordinator.vault.removeSecret(for: appID)
                        app.wrappedValue.unlock.hasSecretWord = false
                    }
                }
            }
        } else {
            LabeledContent("Secret word") {
                HStack {
                    SecureField("e.g. jj", text: $newSecret).frame(width: 140).onSubmit(saveSecret)
                    Button("Save", action: saveSecret).disabled(newSecret.isEmpty)
                    if editingSecret { Button("Cancel") { editingSecret = false; newSecret = "" } }
                }
            }
            if let secretError {
                Text(secretError).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func saveSecret() {
        do {
            try coordinator.vault.setSecret(newSecret, for: appID)
            app.wrappedValue.unlock.hasSecretWord = true
            newSecret = ""
            secretError = nil
            editingSecret = false
        } catch {
            secretError = error.localizedDescription
        }
    }
}

// MARK: - Intruder catch

private struct IntruderTab: View {
    @EnvironmentObject private var store: SettingsStore

    private var config: Binding<CatchConfig> { $store.settings.catchConfig }
    private var c: CatchConfig { config.wrappedValue }
    private var owner: String { store.settings.ownerDisplayName }

    var body: some View {
        Form {
            Section {
                Toggle("Snap a photo of persistent snoopers", isOn: config.isEnabled)
                if CameraCapture.status != .authorized {
                    Label("Camera access isn't granted yet. See Permissions.", systemImage: "camera.badge.ellipsis")
                        .foregroundStyle(.orange)
                }
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Stepper("Wrong tries before a photo: \(c.attemptsBeforeCapture)", value: config.attemptsBeforeCapture, in: 1...10)
                hint("A wrong try is a click on the lock screen, a burst of typing that isn't your secret, or a failed Touch ID. Rapid clicks count as one try; typing counts once you pause.")

                Stepper("Counting window: \(DurationText.short(c.attemptWindowSeconds))", value: config.attemptWindowSeconds, in: 10...300, step: 10)
                hint("Only tries made within the last \(DurationText.short(c.attemptWindowSeconds)) count towards the \(c.attemptsBeforeCapture). Older ones are forgotten. Example: 1 try, then another \(DurationText.short(c.attemptWindowSeconds + 10)) later, means no photo. \(c.attemptsBeforeCapture) tries close together means a photo.")
            } header: {
                Text("When to take a photo")
            }

            Section {
                Stepper("“It was me” grace: \(DurationText.short(c.ownerGraceSeconds))", value: config.ownerGraceSeconds, in: 0...120, step: 5)
                hint("If you unlock within \(DurationText.short(c.ownerGraceSeconds)) after a photo, NoPeek assumes those tries were yours and deletes the photo (“Phew, it was you”). Set to 0s while testing to keep every photo. The lock screen also warns one try before a photo is taken.")
            } header: {
                Text("Don't catch me")
            }

            Section {
                Stepper("Wait between photos: \(DurationText.short(c.cooldownSeconds))", value: config.cooldownSeconds, in: 0...600, step: 15)
                hint("After a photo, more tries won't take another until this much time has passed.")

                Stepper("Max photos per lock: \(c.maxCapturesPerSession)", value: config.maxCapturesPerSession, in: 1...20)
                hint("A cap for one locked period (from lock until you unlock).")

                Stepper("Keep photos for \(c.retentionDays) days", value: config.retentionDays, in: 1...365)
                hint("Older photos are deleted automatically. They're stored only on this Mac.")
            } header: {
                Text("Limits")
            }

            Section {
                hint("Changes apply from the next lock. A lock screen already showing keeps its old settings.")
            }
        }
        .formStyle(.grouped)
    }

    private var summary: String {
        guard c.isEnabled else { return "Off: wrong tries are counted and roasted, but no photos are taken." }
        let tries = c.attemptsBeforeCapture == 1 ? "1 wrong try" : "\(c.attemptsBeforeCapture) wrong tries"
        return "Right now: a photo is taken when someone makes \(tries) within \(DurationText.short(c.attemptWindowSeconds)). "
            + "If you unlock within \(DurationText.short(c.ownerGraceSeconds)) of a photo, it's deleted. "
            + "At most one photo every \(DurationText.short(c.cooldownSeconds)), \(c.maxCapturesPerSession) per lock. "
            + "You get a notification with the photo when \(owner) unlocks."
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Caught gallery

private struct CaughtTab: View {
    @EnvironmentObject private var captures: CaptureStore

    var body: some View {
        Group {
            if captures.records.isEmpty {
                ContentUnavailableView("No snoopers yet 😇", systemImage: "camera",
                                       description: Text("Photos of anyone who keeps trying to get in show up here."))
            } else {
                VStack(alignment: .leading) {
                    HStack {
                        Text("\(captures.records.count) photo\(captures.records.count == 1 ? "" : "s")").font(.headline)
                        Spacer()
                        Button("Show in Finder") { NSWorkspace.shared.open(AppPaths.capturesDirectory) }
                        Button("Delete All", role: .destructive) { captures.deleteAll() }
                    }
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 16)], spacing: 16) {
                            ForEach(captures.records) { record in
                                CaptureCard(record: record)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .onAppear { captures.markViewed() }
    }
}

private struct CaptureCard: View {
    @EnvironmentObject private var captures: CaptureStore
    let record: CaptureRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let image = captures.image(for: record) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.gray.opacity(0.2)
                }
            }
            .frame(height: 140)
            .frame(maxWidth: .infinity)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(record.appName).font(.headline)
            Text(record.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            Text("After \(record.attempt) tries").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(captures.url(for: record)) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([captures.url(for: record)]) }
            Divider()
            Button("Delete", role: .destructive) { captures.delete(ids: [record.id]) }
        }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(captures.url(for: record)) }
    }
}

// MARK: - Permissions

private struct PermissionsTab: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @State private var notifications: UNAuthorizationStatus?
    @State private var accessibilityTrusted = InputGuard.isTrusted
    @State private var cameraStatus = CameraCapture.status

    var body: some View {
        Form {
            Section {
                Text("NoPeek works without these, but each one makes it better. Nothing ever leaves your Mac.")
                    .foregroundStyle(.secondary)
            }

            permissionRow(
                title: "Camera",
                detail: "Snap a photo of persistent snoopers.",
                state: cameraStatus == .authorized ? .granted : (cameraStatus == .notDetermined ? .notAsked : .denied)
            ) {
                if cameraStatus == .notDetermined {
                    Button("Allow") { Task { _ = await CameraCapture.requestAccess(); refresh() } }
                } else {
                    Button("Open Settings") { openPrivacyPane("Privacy_Camera") }
                }
            }

            permissionRow(
                title: "Accessibility",
                detail: accessibilityTrusted
                    ? "Blocks keystrokes from reaching a locked app."
                    : "Blocks keystrokes from reaching a locked app. Already switched on in System Settings but still showing here? That entry is from an older build: use Reset & Allow.",
                state: accessibilityTrusted ? .granted : .denied
            ) {
                Button("Allow") {
                    InputGuard.promptForTrust()
                    openPrivacyPane("Privacy_Accessibility")
                }
                Button("Reset & Allow") { resetAccessibility() }
                    .help("Removes NoPeek's stale Accessibility entry and asks again.")
            }

            permissionRow(
                title: "Notifications",
                detail: notificationDetail,
                state: notifications.map { isAllowed($0) ? .granted : ($0 == .notDetermined ? .notAsked : .denied) } ?? .notAsked
            ) {
                if notifications == .notDetermined || notifications == nil {
                    Button("Allow") {
                        Task {
                            await coordinator.notifier.requestAuthorization()
                            await refreshNotifications()
                        }
                    }
                } else {
                    Button("Open Settings") { openNotificationSettings() }
                }
            }
        }
        .formStyle(.grouped)
        // Re-check every 2s so changes made in System Settings show up live.
        .task {
            while !Task.isCancelled {
                refresh()
                await refreshNotifications()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private enum PermissionState { case granted, denied, notAsked }

    private var notificationDetail: String {
        switch notifications {
        case .some(.denied):
            return "Tells you who got caught. Currently off: turn on “Allow notifications” for NoPeek in System Settings."
        default:
            return "Tells you who got caught when you're back."
        }
    }

    private func isAllowed(_ status: UNAuthorizationStatus) -> Bool {
        status == .authorized || status == .provisional
    }

    private func refresh() {
        accessibilityTrusted = InputGuard.isTrusted
        cameraStatus = CameraCapture.status
        if accessibilityTrusted { coordinator.inputGuard.startIfPossible() }
    }

    private func refreshNotifications() async {
        notifications = await coordinator.notifier.authorizationStatus()
    }

    private func resetAccessibility() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", "Accessibility", Bundle.main.bundleIdentifier ?? "io.github.ameyajain-25.nopeek"]
        try? task.run()
        task.waitUntilExit()
        InputGuard.promptForTrust()
        openPrivacyPane("Privacy_Accessibility")
    }

    private func openNotificationSettings() {
        let id = Bundle.main.bundleIdentifier ?? "io.github.ameyajain-25.nopeek"
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func permissionRow<Actions: View>(title: String, detail: String, state: PermissionState,
                                              @ViewBuilder actions: () -> Actions) -> some View {
        HStack(spacing: 12) {
            Image(systemName: state == .granted ? "checkmark.circle.fill" : (state == .denied ? "xmark.circle" : "circle.dashed"))
                .font(.title2)
                .foregroundStyle(state == .granted ? .green : (state == .denied ? .orange : .secondary))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if state != .granted {
                HStack { actions() }
            }
        }
        .padding(.vertical, 4)
    }

    private func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
