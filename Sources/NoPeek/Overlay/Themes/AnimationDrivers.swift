import AppKit
import SwiftUI

/// Publishes the cursor position only when the mouse actually moves (event-driven, throttled).
/// Nothing re-renders while the mouse is still, so idle overlays cost ~0 CPU.
@MainActor
final class MouseTracker: ObservableObject {
    static let shared = MouseTracker()

    @Published private(set) var location: CGPoint = NSEvent.mouseLocation

    private static let minInterval: TimeInterval = 1 / 45
    private var monitors: [Any] = []
    private var subscribers = 0
    private var lastPublish = Date.distantPast
    private var trailing: Task<Void, Never>?

    func subscribe() {
        subscribers += 1
        guard subscribers == 1 else { return }
        location = NSEvent.mouseLocation
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.mouseMoved() }
            return event
        }) {
            monitors.append(local)
        }
    }

    func unsubscribe() {
        subscribers = max(0, subscribers - 1)
        guard subscribers == 0 else { return }
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        trailing?.cancel()
    }

    private func mouseMoved() {
        let now = Date()
        if now.timeIntervalSince(lastPublish) >= Self.minInterval {
            publish(at: now)
        } else if trailing == nil {
            // Make sure the final resting position is always delivered.
            trailing = after(Self.minInterval) { [weak self] in
                self?.trailing = nil
                self?.publish(at: Date())
            }
        }
    }

    private func publish(at now: Date) {
        lastPublish = now
        let point = NSEvent.mouseLocation
        if abs(point.x - location.x) > 0.5 || abs(point.y - location.y) > 0.5 {
            location = point
        }
    }
}

/// Unit direction × reach from a view (in panel space) toward the cursor (in screen space).
func gazeOffset(viewFrameInPanel local: CGRect, panelFrame: CGRect, mouse: CGPoint,
                maxReach: CGFloat, falloff: CGFloat) -> CGSize {
    let center = CGPoint(x: panelFrame.minX + local.midX, y: panelFrame.maxY - local.midY)
    let dx = mouse.x - center.x
    let dy = center.y - mouse.y
    let distance = max(hypot(dx, dy), 0.001)
    let reach = min(maxReach, distance / falloff)
    return CGSize(width: dx / distance * reach, height: dy / distance * reach)
}

/// Blinks every few seconds using short one-off animations (no per-frame timeline).
struct BlinkModifier: ViewModifier {
    @State private var closed = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(x: 1, y: closed ? 0.08 : 1)
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(Double.random(in: 2.8...5.2)))
                    withAnimation(.easeIn(duration: 0.07)) { closed = true }
                    try? await Task.sleep(for: .milliseconds(110))
                    withAnimation(.easeOut(duration: 0.1)) { closed = false }
                }
            }
    }
}
