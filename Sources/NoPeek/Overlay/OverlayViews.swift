import NoPeekCore
import SwiftUI

/// Light vs dark text/backdrop, picked from the theme.
struct OverlayStyle {
    let isLight: Bool
    var primary: Color { isLight ? Pastel.ink : .white }
    var secondary: Color { isLight ? Pastel.ink.opacity(0.55) : .white.opacity(0.8) }
    var faint: Color { isLight ? Pastel.ink.opacity(0.35) : .white.opacity(0.4) }
    var textShadow: Color { isLight ? .clear : .black.opacity(0.5) }
}

private struct OverlayStyleKey: EnvironmentKey {
    static let defaultValue = OverlayStyle(isLight: false)
}

extension EnvironmentValues {
    var overlayStyle: OverlayStyle {
        get { self[OverlayStyleKey.self] }
        set { self[OverlayStyleKey.self] = newValue }
    }
}

struct OverlayRootView: View {
    @ObservedObject var session: LockSession
    @ObservedObject var panel: PanelState

    private var style: OverlayStyle { OverlayStyle(isLight: session.theme.isLight) }

    var body: some View {
        GeometryReader { geo in
            let scale = min(max(min(geo.size.width / 920, geo.size.height / 660), 0.38), 1.25)
            ZStack {
                backdrop

                if panel.isPrimary {
                    primaryContent
                        .scaleEffect(scale)
                        .frame(width: geo.size.width, height: geo.size.height)
                    footer
                } else {
                    SecondaryBadge().scaleEffect(scale)
                }

                if panel.isPrimary, session.app.unlock.touchID, !session.isFinished {
                    touchIDButton
                }

                FlashView(trigger: session.flash)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .onTapGesture { if panel.isPrimary { session.handleClick() } }
        }
        .environment(\.overlayStyle, style)
    }

    @ViewBuilder
    private var backdrop: some View {
        if style.isLight {
            ZStack {
                Color.white.opacity(0.5)
                SoftAuroraBackground().opacity(0.85)
            }
        } else {
            let unlocking: Bool = { if case .unlocking = session.phase { return true }; return false }()
            Color.black.opacity(unlocking ? 0.35 : 0.5)
        }
    }

    @ViewBuilder
    private var primaryContent: some View {
        switch session.phase {
        case .guarding, .capturing:
            GuardView(session: session, panel: panel)
        case .caught:
            CaughtView(image: session.caughtImage, ownerName: session.ownerName, capturedAt: session.caughtAt)
        case let .unlocking(discarded):
            WelcomeBackView(ownerName: session.ownerName, discardedPhoto: discarded)
        }
    }

    private var footer: some View {
        VStack {
            Spacer()
            Text(session.isPreview ? "Preview · press Esc to close" : "🙈 NoPeek is guarding \(session.app.name)")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(style.faint)
                .padding(.bottom, 14)
        }
        .allowsHitTesting(false)
    }

    private var touchIDButton: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button { session.requestTouchID() } label: {
                    Image(systemName: "touchid")
                        .font(.system(size: 20))
                        .foregroundStyle(style.faint)
                        .padding(12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Unlock with Touch ID")
            }
        }
    }
}

// MARK: - Guarding

struct GuardView: View {
    @ObservedObject var session: LockSession
    @ObservedObject var panel: PanelState
    @Environment(\.overlayStyle) private var style

    var body: some View {
        if session.theme == .peekaboo {
            // Peekaboo renders its own headline and caption inside the card.
            PeekabooView(session: session, panel: panel)
        } else {
            VStack(spacing: 34) {
                illustration
                Text(session.caption)
                    .font(.system(size: 40, weight: .heavy, design: .rounded))
                    .foregroundStyle(style.primary)
                    .multilineTextAlignment(.center)
                    .shadow(color: style.textShadow, radius: 8, y: 3)
                    .frame(maxWidth: 760)
                    .id(session.caption)
                    .transition(.asymmetric(insertion: .scale(scale: 0.6).combined(with: .opacity), removal: .opacity))
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.55), value: session.caption)
        }
    }

    @ViewBuilder
    private var illustration: some View {
        switch session.theme {
        case .bouncer:
            BouncerView(session: session)
        default:
            GooglyEyesView(session: session, panel: panel)
        }
    }
}

struct SecondaryBadge: View {
    @Environment(\.overlayStyle) private var style

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "eye.slash.fill").font(.system(size: 56))
            Text("Nope.").font(.system(size: 30, weight: .heavy, design: .rounded))
        }
        .foregroundStyle(style.secondary)
    }
}

// MARK: - Caught

struct CaughtView: View {
    let image: NSImage?
    let ownerName: String
    let capturedAt: Date
    @Environment(\.overlayStyle) private var style

    @State private var stampIn = false
    @State private var photoIn = false
    @State private var reported = false

    var body: some View {
        VStack(spacing: 28) {
            Text("Hehe, caught you 📸")
                .font(.system(size: 58, weight: style.isLight ? .bold : .heavy, design: .rounded))
                .foregroundStyle(style.primary)
                .shadow(color: style.textShadow, radius: 8, y: 3)

            polaroid
                .overlay(alignment: .topTrailing) { stamp }
                .scaleEffect(photoIn ? 1 : 0.4)
                .rotationEffect(.degrees(photoIn ? -4 : -25))
                .opacity(photoIn ? 1 : 0)

            HStack(spacing: 12) {
                if reported {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                } else {
                    ProgressView().controlSize(.small).tint(style.primary)
                }
                Text(reported ? "Reported to \(ownerName)" : "Reporting to \(ownerName)…")
                    .contentTransition(.opacity)
            }
            .font(.system(size: 26, weight: .semibold, design: .rounded))
            .foregroundStyle(style.secondary)
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) { photoIn = true }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.45).delay(0.5)) { stampIn = true }
            withAnimation(.easeInOut.delay(1.8)) { reported = true }
        }
    }

    private var polaroid: some View {
        VStack(spacing: 12) {
            photo
                .frame(width: 340, height: 255)
                .clipped()
            Text("Suspect #1 · \(capturedAt.formatted(date: .omitted, time: .shortened))")
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundStyle(.black.opacity(0.7))
        }
        .padding(14)
        .padding(.bottom, 8)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: style.isLight ? 18 : 2, style: .continuous))
        .shadow(color: style.isLight ? Pastel.lavenderDeep.opacity(0.3) : .black.opacity(0.45), radius: 24, y: 10)
    }

    @ViewBuilder
    private var photo: some View {
        if let image {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Color(white: 0.85)
                VStack(spacing: 8) {
                    Text("🫥").font(.system(size: 96))
                    Text("Camera shy? Logged anyway.")
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundStyle(.black.opacity(0.6))
                }
            }
        }
    }

    private var stamp: some View {
        Text("BUSTED")
            .font(.system(size: 46, weight: .black, design: .rounded))
            .foregroundStyle(.red)
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.red, lineWidth: 6))
            .rotationEffect(.degrees(16))
            .scaleEffect(stampIn ? 1 : 2.8)
            .opacity(stampIn ? 0.92 : 0)
            .offset(x: 46, y: -18)
    }
}

// MARK: - Welcome back

struct WelcomeBackView: View {
    let ownerName: String
    let discardedPhoto: Bool
    @Environment(\.overlayStyle) private var style
    @State private var shown = false

    var body: some View {
        VStack(spacing: 16) {
            Text(discardedPhoto ? "😮‍💨" : "👋")
                .font(.system(size: 110))
                .rotationEffect(.degrees(shown ? 0 : -30))
            Text(discardedPhoto ? "Phew, it was you." : "Welcome back, \(ownerName)")
                .font(.system(size: 48, weight: style.isLight ? .semibold : .heavy, design: .rounded))
            if discardedPhoto {
                Text("Photo deleted. No snitching today.")
                    .font(.system(size: 24, weight: .medium, design: .rounded))
                    .opacity(0.8)
            }
        }
        .foregroundStyle(style.primary)
        .scaleEffect(shown ? 1 : 0.6)
        .opacity(shown ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.55)) { shown = true }
        }
    }
}

// MARK: - Camera flash

struct FlashView: View {
    let trigger: Int
    @State private var opacity: Double = 0

    var body: some View {
        Color.white
            .opacity(opacity)
            .allowsHitTesting(false)
            .onChange(of: trigger) { _, _ in
                opacity = 1
                withAnimation(.easeOut(duration: 0.7)) { opacity = 0 }
            }
    }
}

// MARK: - Shared animation

struct ShakeOnPulse: ViewModifier {
    let pulse: Int
    var amplitude: CGFloat = 18

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: CGFloat(0), trigger: pulse) { view, x in
            view.offset(x: x)
        } keyframes: { _ in
            KeyframeTrack {
                CubicKeyframe(-amplitude, duration: 0.07)
                CubicKeyframe(amplitude * 0.9, duration: 0.07)
                CubicKeyframe(-amplitude * 0.6, duration: 0.07)
                CubicKeyframe(amplitude * 0.4, duration: 0.07)
                CubicKeyframe(0, duration: 0.08)
            }
        }
    }
}
