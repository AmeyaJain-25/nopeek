import AppKit
import NoPeekCore
import SwiftUI

struct MenuBarIcon: View {
    @EnvironmentObject private var engine: LockEngine
    @EnvironmentObject private var captures: CaptureStore

    var body: some View {
        Image(systemName: symbol)
    }

    private var symbol: String {
        if captures.unseenCount > 0 { return "eye.trianglebadge.exclamationmark" }
        if engine.isPaused { return "eye" }
        return "eye.slash"
    }
}

struct MenuBarContent: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var store: SettingsStore
    @EnvironmentObject private var captures: CaptureStore
    @EnvironmentObject private var engine: LockEngine

    var body: some View {
        Text(statusLine)

        Divider()

        ForEach(store.settings.apps.filter(\.isEnabled)) { app in
            if engine.isLocked(app.bundleID) {
                Button("🔒  \(app.name) — Unlock…") { coordinator.unlockFromMenu(app) }
            } else {
                Button("🔓  \(app.name) — Lock Now") { engine.lock(app) }
            }
        }

        if let front = frontmostUnprotectedApp {
            Button("➕  Protect “\(front.localizedName ?? "this app")”") { coordinator.protect(front) }
        }

        Divider()

        Button(lockAllTitle) { engine.lockAll() }

        if engine.isPaused {
            Button("▶︎  Resume Protection") { engine.resume() }
        } else {
            Menu("⏸  Pause Protection") {
                Button("For 15 Minutes") { coordinator.pause(for: 15 * 60) }
                Button("For 1 Hour") { coordinator.pause(for: 3600) }
                Button("Until I Resume") { coordinator.pause(for: nil) }
            }
        }

        Button(captures.unseenCount > 0 ? "📸  Caught \(captures.unseenCount) New Snooper(s)…" : "📸  Caught Snoopers…") {
            coordinator.openSettings(tab: .caught)
        }
        Button("Settings…") { coordinator.openSettings() }

        Divider()

        Button("Quit NoPeek") { coordinator.requestQuit() }
    }

    private var statusLine: String {
        if engine.isPaused {
            if let until = engine.pausedUntil, until != .distantFuture {
                return "Paused until \(until.formatted(date: .omitted, time: .shortened))"
            }
            return "Paused"
        }
        let locked = engine.activeSessions.count
        return locked == 0 ? "NoPeek is watching 👀" : "\(locked) app\(locked == 1 ? "" : "s") locked"
    }

    private var lockAllTitle: String {
        let shortcut = store.settings.lockAllShortcut.map { "   \($0.displayString)" } ?? ""
        return "🔒  Lock All Now\(shortcut)"
    }

    private var frontmostUnprotectedApp: NSRunningApplication? {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.activationPolicy == .regular,
              let bundleID = front.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier,
              !store.settings.apps.contains(where: { $0.bundleID == bundleID }) else { return nil }
        return front
    }
}
