import AppKit
import SwiftUI

/// Soft pastel palette shared by the light theme.
enum Pastel {
    static let ink = Color(red: 0.16, green: 0.15, blue: 0.22)
    static let lavender = Color(red: 0.78, green: 0.72, blue: 1.0)
    static let lavenderDeep = Color(red: 0.64, green: 0.56, blue: 0.97)
    static let peach = Color(red: 1.0, green: 0.80, blue: 0.72)
    static let mint = Color(red: 0.68, green: 0.93, blue: 0.85)
    static let sky = Color(red: 0.70, green: 0.84, blue: 1.0)
    static let blush = Color(red: 1.0, green: 0.62, blue: 0.70)
}

/// Light, frosted "Hey, why are you peeking?" card with a little buddy peeking over the top.
struct PeekabooView: View {
    @ObservedObject var session: LockSession
    @ObservedObject var panel: PanelState

    var body: some View {
        ZStack(alignment: .top) {
            PeekingBuddy(session: session, panel: panel)
                .offset(y: -112)
            card
            hands.offset(y: -15)
        }
        .padding(.top, 120)
        .modifier(ShakeOnPulse(pulse: session.pulse, amplitude: 9))
    }

    private var card: some View {
        VStack(spacing: 14) {
            Text("Hey, why are you peeking?")
                .font(.system(size: 42, weight: .semibold, design: .rounded))
                .foregroundStyle(Pastel.ink)

            Text(session.caption)
                .font(.system(size: 21, weight: .medium, design: .rounded))
                .foregroundStyle(Pastel.ink.opacity(0.55))
                .id(session.caption)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 8)), removal: .opacity))

            appPill.padding(.top, 12)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 56)
        .padding(.top, 76)
        .padding(.bottom, 40)
        .frame(width: 660)
        .background {
            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .fill(.white.opacity(0.78))
                .overlay(
                    RoundedRectangle(cornerRadius: 36, style: .continuous)
                        .strokeBorder(.white, lineWidth: 1.5)
                )
                .shadow(color: Pastel.lavenderDeep.opacity(0.22), radius: 50, y: 26)
                .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
        }
        .animation(.smooth(duration: 0.45), value: session.caption)
    }

    private var appPill: some View {
        HStack(spacing: 8) {
            Image(nsImage: AppIcons.icon(for: session.app.bundleID))
                .resizable()
                .frame(width: 20, height: 20)
            Text("\(session.app.name) is private")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
            Image(systemName: "lock.fill").font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(Pastel.ink.opacity(0.6))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(Pastel.ink.opacity(0.05)))
    }

    /// Little hands gripping the top edge of the card.
    private var hands: some View {
        HStack(spacing: 96) {
            hand
            hand
        }
    }

    private var hand: some View {
        ZStack {
            Capsule()
                .fill(LinearGradient(colors: [Pastel.lavender, Pastel.lavenderDeep], startPoint: .top, endPoint: .bottom))
            HStack(spacing: 9) {
                ForEach(0..<3, id: \.self) { _ in
                    Capsule().fill(Pastel.ink.opacity(0.13)).frame(width: 2, height: 11)
                }
            }
            .offset(y: 3)
        }
        .frame(width: 58, height: 30)
        .shadow(color: Pastel.lavenderDeep.opacity(0.3), radius: 6, y: 3)
    }
}

/// Round lavender face: curious brows, "o" mouth, eyes that track the cursor.
/// Every motion is event-driven or a short one-off animation, so it idles at ~0 CPU.
private struct PeekingBuddy: View {
    @ObservedObject var session: LockSession
    @ObservedObject var panel: PanelState
    @ObservedObject private var mouse = MouseTracker.shared
    @State private var lifted = false

    private var suspicion: Double { min(Double(session.attempts), 5) }

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Pastel.lavender.opacity(0.9), Pastel.lavenderDeep],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(
                    Ellipse()
                        .fill(RadialGradient(colors: [.white.opacity(0.45), .white.opacity(0)], center: .center,
                                             startRadius: 0, endRadius: 34))
                        .frame(width: 70, height: 36)
                        .offset(x: -30, y: -55)
                )

            HStack(spacing: 74) {
                Ellipse().fill(Pastel.blush.opacity(0.5)).frame(width: 30, height: 16)
                Ellipse().fill(Pastel.blush.opacity(0.5)).frame(width: 30, height: 16)
            }
            .offset(y: 20)

            HStack(spacing: 46) {
                brow(side: -1)
                brow(side: 1)
            }
            .offset(y: -42)
            .animation(.spring(response: 0.4, dampingFraction: 0.6), value: suspicion)

            HStack(spacing: 38) {
                SoftEye(mouse: mouse.location, panelFrame: panel.frame)
                SoftEye(mouse: mouse.location, panelFrame: panel.frame)
            }
            .modifier(BlinkModifier())
            .offset(y: -8)

            Ellipse()
                .fill(Pastel.ink.opacity(0.75))
                .frame(width: 13, height: 15 + CGFloat(suspicion))
                .offset(y: 34)
                .animation(.spring(response: 0.35, dampingFraction: 0.55), value: suspicion)
        }
        .frame(width: 176, height: 176)
        .offset(y: lifted ? -7 : 0)
        .keyframeAnimator(initialValue: CGFloat(0), trigger: session.pulse) { view, y in
            view.offset(y: y)
        } keyframes: { _ in
            KeyframeTrack {
                SpringKeyframe(-30, duration: 0.18, spring: .snappy)
                SpringKeyframe(0, duration: 0.5, spring: .bouncy)
            }
        }
        .onAppear { mouse.subscribe() }
        .onDisappear { mouse.unsubscribe() }
        .task {
            // An occasional curious little peek instead of a constant bob.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double.random(in: 4...7)))
                withAnimation(.easeInOut(duration: 0.9)) { lifted = true }
                try? await Task.sleep(for: .seconds(1.1))
                withAnimation(.easeInOut(duration: 0.9)) { lifted = false }
            }
        }
    }

    /// Left brow raised (curious), right one lowers as suspicion grows.
    private func brow(side: Double) -> some View {
        Capsule()
            .fill(Pastel.ink.opacity(0.7))
            .frame(width: 26, height: 6)
            .rotationEffect(.degrees(side < 0 ? -12 : 6 + suspicion * 4))
            .offset(y: side < 0 ? -4 : CGFloat(suspicion))
    }
}

/// Minimal glossy eye that drifts toward the cursor.
private struct SoftEye: View {
    let mouse: CGPoint
    let panelFrame: CGRect

    var body: some View {
        GeometryReader { geo in
            let offset = gazeOffset(viewFrameInPanel: geo.frame(in: .global), panelFrame: panelFrame,
                                    mouse: mouse, maxReach: 7, falloff: 25)
            ZStack {
                Ellipse().fill(Pastel.ink)
                Circle().fill(.white).frame(width: 7, height: 7).offset(x: -4, y: -6)
            }
            .frame(width: 22, height: 28)
            .offset(offset)
            .animation(.interactiveSpring(response: 0.22, dampingFraction: 0.8), value: offset)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(width: 36, height: 40)
    }
}

/// Slowly drifting pastel blobs behind everything.
/// Runs entirely on Core Animation (the system render server), so the app itself does
/// almost no work per frame: no SwiftUI re-renders, no offscreen blurs.
struct SoftAuroraBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> AuroraView { AuroraView() }
    func updateNSView(_ nsView: AuroraView, context: Context) {}
}

final class AuroraView: NSView {
    private struct Blob {
        let color: NSColor
        let size: CGFloat      // fraction of the larger side
        let from: CGPoint      // unit coordinates (0...1)
        let to: CGPoint
        let duration: CFTimeInterval
    }

    private let blobs: [Blob] = [
        Blob(color: NSColor(Pastel.lavender), size: 0.75, from: CGPoint(x: 0.18, y: 0.72), to: CGPoint(x: 0.32, y: 0.58), duration: 9),
        Blob(color: NSColor(Pastel.peach), size: 0.68, from: CGPoint(x: 0.84, y: 0.78), to: CGPoint(x: 0.70, y: 0.62), duration: 11),
        Blob(color: NSColor(Pastel.mint), size: 0.64, from: CGPoint(x: 0.55, y: 0.14), to: CGPoint(x: 0.72, y: 0.24), duration: 13),
        Blob(color: NSColor(Pastel.sky), size: 0.60, from: CGPoint(x: 0.14, y: 0.16), to: CGPoint(x: 0.26, y: 0.28), duration: 10),
    ]
    private var layers: [CAGradientLayer] = []
    private var laidOutSize: CGSize = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        for blob in blobs {
            let g = CAGradientLayer()
            g.type = .radial
            g.colors = [blob.color.withAlphaComponent(0.85).cgColor,
                        blob.color.withAlphaComponent(0.35).cgColor,
                        blob.color.withAlphaComponent(0).cgColor]
            g.locations = [0, 0.45, 1]
            g.startPoint = CGPoint(x: 0.5, y: 0.5)
            g.endPoint = CGPoint(x: 1, y: 1)
            layer?.addSublayer(g)
            layers.append(g)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        guard bounds.size != laidOutSize, bounds.width > 0, bounds.height > 0 else { return }
        laidOutSize = bounds.size
        let side = max(bounds.width, bounds.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (blob, g) in zip(blobs, layers) {
            let d = side * blob.size
            g.bounds = CGRect(x: 0, y: 0, width: d, height: d)
            let from = CGPoint(x: blob.from.x * bounds.width, y: blob.from.y * bounds.height)
            let to = CGPoint(x: blob.to.x * bounds.width, y: blob.to.y * bounds.height)
            g.position = from
            g.removeAllAnimations()
            let drift = CABasicAnimation(keyPath: "position")
            drift.fromValue = NSValue(point: from)
            drift.toValue = NSValue(point: to)
            drift.duration = blob.duration
            drift.autoreverses = true
            drift.repeatCount = .infinity
            drift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            g.add(drift, forKey: "drift")
        }
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
