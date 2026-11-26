import AppKit
import Combine
import NoPeekCore
import SwiftUI

// MARK: - Panel

/// Per-panel view state the SwiftUI content observes.
@MainActor
final class PanelState: ObservableObject {
    @Published var frame: CGRect = .zero
    /// The primary panel shows the illustration and counts clicks; others just blur.
    @Published var isPrimary = false
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Frosted panel that hosts the overlay UI. Used full-screen for the lock shield and
/// as a floating card for the settings preview.
@MainActor
final class OverlayPanel: NSPanel {
    enum Style {
        /// Covers a whole display (incl. menu bar) on every Space.
        case shield
        /// Floating rounded window, used by the settings preview.
        case preview
    }

    /// Above the menu bar, so a locked app's menus can't be used either.
    static let shieldLevel = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)

    let session: LockSession
    let state = PanelState()
    var onKeyDown: ((NSEvent) -> Void)?
    private var cancellables: Set<AnyCancellable> = []

    init(session: LockSession, frame: CGRect, style: Style) {
        self.session = session
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        becomesKeyOnlyIfNeeded = false
        worksWhenModal = true
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        state.frame = frame

        switch style {
        case .shield:
            level = Self.shieldLevel
            // Belongs only to the Space it's shown on (so swiping away leaves it behind), may sit over
            // full-screen apps, and steps aside for Mission Control / App Exposé.
            collectionBehavior = [.fullScreenAuxiliary, .transient, .ignoresCycle]
        case .preview:
            level = .floating
            collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        }

        let container = NSView(frame: CGRect(origin: .zero, size: frame.size))
        container.wantsLayer = true
        container.layer?.cornerRadius = style == .preview ? 16 : 0
        container.layer?.masksToBounds = true

        let blur = NSVisualEffectView(frame: container.bounds)
        if session.theme.isLight {
            blur.material = .popover
            blur.appearance = NSAppearance(named: .aqua)
        } else {
            blur.material = .hudWindow
            blur.appearance = NSAppearance(named: .darkAqua)
        }
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]
        container.addSubview(blur)

        let hosting = FirstMouseHostingView(rootView: OverlayRootView(session: session, panel: state))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        contentView = container

        // Fade out at the end of the welcome-back animation.
        session.$phase
            .sink { [weak self] phase in
                guard case let .unlocking(discarded) = phase else { return }
                // Unlocked: never block clicks again, even while the goodbye animation plays.
                self?.ignoresMouseEvents = true
                after(discarded ? 1.4 : 0.55) {
                    NSAnimationContext.runAnimationGroup({ ctx in
                        ctx.duration = 0.3
                        self?.animator().alphaValue = 0
                    }, completionHandler: {
                        // Take itself off screen too, so no panel can ever be left behind.
                        self?.orderOut(nil)
                    })
                }
            }
            .store(in: &cancellables)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            onKeyDown?(event)
            return
        }
        super.sendEvent(event)
    }

    /// Swallow every key equivalent (⌘Q, ⌘W, …) while guarding.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        onKeyDown?(event)
        return true
    }
}

// MARK: - Lock shield

/// Shows the lock screen while a locked app is in front: one frosted panel per display.
///
/// Fully event-driven: nothing is tracked or polled. Panels exist only while shown, so a
/// hidden shield costs nothing.
@MainActor
final class ShieldController {
    var keyHandler: (LockSession, NSEvent) -> Void = { $0.handleKey($1) }

    private var panels: [OverlayPanel] = []
    private(set) weak var session: LockSession?
    private var observers: [NSObjectProtocol] = []
    private var phaseWatch: AnyCancellable?
    /// Longest the "welcome back" can stay up before the shield removes itself regardless.
    static let finishedWatchdog: TimeInterval = 2.5

    var isShowing: Bool { !panels.isEmpty }

    init() {
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // Display plugged/unplugged or resolution changed: rebuild for the new layout.
                guard let self, let session = self.session, !session.isFinished else { return }
                self.show(session, forceRebuild: true)
            }
        })
    }

    func show(_ session: LockSession, forceRebuild: Bool = false) {
        if !forceRebuild, self.session === session, isShowing {
            focus()
            return
        }
        hide()
        // Never put up a shield for a session that's already unlocked.
        guard !session.isFinished else { return }
        self.session = session
        // Safety net: once unlocked, the shield goes away even if nobody else removes it.
        phaseWatch = session.$phase.sink { [weak self, weak session] phase in
            guard case .unlocking = phase else { return }
            _ = after(Self.finishedWatchdog) {
                guard let self, let session, self.session === session else { return }
                self.hide()
            }
        }

        let primary = Self.screen(forBundleID: session.bundleID) ?? Self.screenUnderMouse() ?? NSScreen.main
        for screen in NSScreen.screens {
            let panel = OverlayPanel(session: session, frame: screen.frame, style: .shield)
            panel.state.isPrimary = screen == primary
            panel.onKeyDown = { [weak self, weak session] event in
                guard let self, let session else { return }
                self.keyHandler(session, event)
            }
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        focus()
    }

    func hide() {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        session = nil
        phaseWatch = nil
    }

    func hide(ifShowing session: LockSession) {
        if self.session === session { hide() }
    }

    /// While a Touch ID / password sheet is up, drop below it so it's visible.
    func setAuthenticating(_ authenticating: Bool) {
        for panel in panels {
            panel.level = authenticating ? .normal : OverlayPanel.shieldLevel
        }
        if !authenticating, isShowing { focus() }
    }

    /// Take keyboard focus so keystrokes land on the shield, never on the locked app.
    private func focus() {
        NSApp.activate(ignoringOtherApps: true)
        panels.first { $0.state.isPrimary }?.makeKeyAndOrderFront(nil)
    }

    // MARK: Screen choice (one-shot lookups, no polling)

    /// Whether the app has a window visible on the Space(s) currently showing.
    static func hasVisibleWindow(bundleID: String) -> Bool {
        screen(forBundleID: bundleID) != nil
    }

    private static func screen(forBundleID bundleID: String) -> NSScreen? {
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier))
        guard !pids.isEmpty,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        for entry in info {
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  (entry[kCGWindowLayer as String] as? Int) == 0,
                  let dict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict),
                  bounds.width >= 80, bounds.height >= 60 else { continue }
            let center = CGPoint(x: bounds.midX, y: primaryHeight - bounds.midY)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
                return screen
            }
        }
        return nil
    }

    private static func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
    }
}

// MARK: - Settings preview

/// Shows the real overlay in a floating window so you can test themes, hotkeys and secrets.
@MainActor
final class PreviewController: LockSessionDelegate {
    private var panel: OverlayPanel?
    private var session: LockSession?
    private let engine: LockEngine

    init(engine: LockEngine) {
        self.engine = engine
    }

    func show(app: ProtectedApp, settings: AppSettings, digest: SecretDigest?) {
        close()
        let session = LockSession(app: app, theme: settings.theme.resolved(), ownerName: settings.ownerDisplayName,
                                  catchConfig: settings.catchConfig, digest: digest, isPreview: true)
        session.delegate = self

        let screen = NSScreen.main ?? NSScreen.screens[0]
        let size = CGSize(width: min(1000, screen.visibleFrame.width * 0.8),
                          height: min(660, screen.visibleFrame.height * 0.8))
        let frame = CGRect(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.midY - size.height / 2,
                           width: size.width, height: size.height)
        let panel = OverlayPanel(session: session, frame: frame, style: .preview)
        panel.state.isPrimary = true
        panel.onKeyDown = { [weak self, weak session] event in
            if event.keyCode == 53, ModifierKeys(event.modifierFlags).isEmpty { // Esc
                self?.close()
            } else {
                session?.handleKey(event)
            }
        }
        self.session = session
        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        session?.cancelTimers()
        panel?.orderOut(nil)
        panel = nil
        session = nil
    }

    func sessionDidAuthenticate(_ session: LockSession) {
        session.finish(discardedPhoto: false)
        after(0.9) { [weak self] in
            if self?.session === session { self?.close() }
        }
    }

    func sessionRequestsCapture(_ session: LockSession, attempt: Int) {
        engine.capturePhoto(for: session, attempt: attempt, persist: false)
    }
}
