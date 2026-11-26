import AppKit
import SwiftUI

/// Two big googly eyes that follow the cursor, blink, and get angrier with every try.
/// Event-driven: renders only when the mouse moves, a blink happens, or a try is made.
struct GooglyEyesView: View {
    @ObservedObject var session: LockSession
    @ObservedObject var panel: PanelState
    @ObservedObject private var mouse = MouseTracker.shared

    private var anger: Double { min(Double(session.attempts), 5) }

    var body: some View {
        HStack(spacing: 40) {
            EyeView(side: -1, mouse: mouse.location, panelFrame: panel.frame, anger: anger)
            EyeView(side: 1, mouse: mouse.location, panelFrame: panel.frame, anger: anger)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.6), value: anger)
        .modifier(ShakeOnPulse(pulse: session.pulse))
        .frame(height: 260)
        .onAppear { mouse.subscribe() }
        .onDisappear { mouse.unsubscribe() }
    }
}

private struct EyeView: View {
    let side: CGFloat
    let mouse: CGPoint
    let panelFrame: CGRect
    let anger: Double

    private let size: CGFloat = 180

    var body: some View {
        VStack(spacing: 14) {
            Capsule()
                .fill(Color(white: 0.95))
                .frame(width: size * 0.75, height: 18)
                .rotationEffect(.degrees(Double(side) * -(6 + anger * 6)))
                .offset(y: CGFloat(anger) * 3)

            GeometryReader { geo in
                let offset = gazeOffset(viewFrameInPanel: geo.frame(in: .global), panelFrame: panelFrame,
                                        mouse: mouse, maxReach: size * 0.22, falloff: 3)
                ZStack {
                    Circle().fill(.white)
                    Circle()
                        .fill(.black)
                        .frame(width: size * 0.44, height: size * 0.44)
                        .overlay(
                            Circle().fill(.white)
                                .frame(width: size * 0.12, height: size * 0.12)
                                .offset(x: -size * 0.07, y: -size * 0.07)
                        )
                        .offset(offset)
                        .animation(.interactiveSpring(response: 0.2, dampingFraction: 0.75), value: offset)
                    // Eyelid squints more as anger grows.
                    Rectangle()
                        .fill(Color(red: 0.98, green: 0.82, blue: 0.62))
                        .frame(height: size * CGFloat(anger) * 0.07)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
                .modifier(BlinkModifier())
                .clipShape(Circle())
                .overlay(Circle().stroke(.black.opacity(0.85), lineWidth: 7))
                .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
            }
            .frame(width: size, height: size)
        }
    }
}
