import AppKit
import SwiftUI

@main
struct NoPeekApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(AppCoordinator.shared)
                .environmentObject(AppCoordinator.shared.settingsStore)
                .environmentObject(AppCoordinator.shared.captureStore)
                .environmentObject(AppCoordinator.shared.engine)
        } label: {
            MenuBarIcon()
                .environmentObject(AppCoordinator.shared.captureStore)
                .environmentObject(AppCoordinator.shared.engine)
        }
        .menuBarExtraStyle(.menu)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppCoordinator.shared.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppCoordinator.shared.shouldTerminate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
