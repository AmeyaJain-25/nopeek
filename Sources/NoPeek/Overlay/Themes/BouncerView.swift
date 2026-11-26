import SwiftUI

/// A cartoon bouncer with shades and crossed arms behind a velvet rope.
/// Shakes his head on every try; his shades glint now and then.
struct BouncerView: View {
    @ObservedObject var session: LockSession

    private let skin = Color(red: 0.80, green: 0.58, blue: 0.42)
    private let skinShade = Color(red: 0.68, green: 0.47, blue: 0.33)

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: -22) {
                head
                    .keyframeAnimator(initialValue: 0.0, trigger: session.pulse) { view, angle in
                        view.rotationEffect(.degrees(angle), anchor: .bottom)
                    } keyframes: { _ in
                        KeyframeTrack {
                            CubicKeyframe(-12, duration: 0.09)
                            CubicKeyframe(12, duration: 0.12)
                            CubicKeyframe(-9, duration: 0.12)
                            CubicKeyframe(7, duration: 0.1)
                            CubicKeyframe(0, duration: 0.1)
                        }
                    }
                    .zIndex(1)
                torso
            }
            VelvetRope()
                .frame(width: 560, height: 130)
                .offset(y: 26)
        }
        .frame(width: 560, height: 390)
    }

    private var head: some View {
        ZStack {
            // Ears
            HStack(spacing: 128) {
                Circle().fill(skinShade).frame(width: 34, height: 34)
                Circle().fill(skinShade).frame(width: 34, height: 34)
            }
            .offset(y: 4)

            Circle()
                .fill(RadialGradient(colors: [skin, skinShade], center: .init(x: 0.4, y: 0.3), startRadius: 10, endRadius: 110))
                .frame(width: 150, height: 150)

            // Bald-head shine
            Ellipse().fill(.white.opacity(0.35)).frame(width: 46, height: 18).offset(x: -26, y: -52)

            Shades().offset(y: -6)

            // Frown
            FrownShape()
                .stroke(Color(red: 0.35, green: 0.18, blue: 0.12), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .frame(width: 46, height: 12)
                .offset(y: 40)

            // Earpiece cable
            Path { p in
                p.move(to: CGPoint(x: 0, y: 0))
                p.addQuadCurve(to: CGPoint(x: 14, y: 70), control: CGPoint(x: 18, y: 30))
            }
            .stroke(Color(white: 0.15), lineWidth: 3)
            .frame(width: 20, height: 70)
            .offset(x: 82, y: 44)
        }
        .frame(width: 210, height: 160)
    }

    private var torso: some View {
        ZStack {
            UnevenRoundedRectangle(topLeadingRadius: 70, bottomLeadingRadius: 8, bottomTrailingRadius: 8, topTrailingRadius: 70)
                .fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.05)], startPoint: .top, endPoint: .bottom))
                .frame(width: 300, height: 200)

            Text("SECURITY")
                .font(.system(size: 26, weight: .black, design: .rounded))
                .tracking(3)
                .foregroundStyle(Color(red: 1, green: 0.84, blue: 0.2))
                .offset(y: -46)

            // Crossed arms
            ZStack {
                Capsule().fill(skinShade).frame(width: 240, height: 50).rotationEffect(.degrees(-11))
                Capsule().fill(skin).frame(width: 240, height: 50).rotationEffect(.degrees(11))
                HStack(spacing: 196) {
                    Circle().fill(skin).frame(width: 44)
                    Circle().fill(skinShade).frame(width: 44)
                }
            }
            .offset(y: 28)
        }
    }
}

private struct Shades: View {
    @State private var glintX: CGFloat = -80

    var body: some View {
        HStack(spacing: 8) {
            lens
            lens
        }
        .overlay(Rectangle().fill(.black).frame(width: 16, height: 6))
        .overlay(
            Rectangle()
                .fill(.white.opacity(0.7))
                .frame(width: 12, height: 60)
                .rotationEffect(.degrees(25))
                .offset(x: glintX)
                .mask(HStack(spacing: 8) { lens; lens })
        )
        .task {
            // A glint sweeps across every few seconds; nothing renders in between.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                withAnimation(.easeInOut(duration: 0.6)) { glintX = 90 }
                try? await Task.sleep(for: .seconds(0.7))
                glintX = -80
            }
        }
    }

    private var lens: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(LinearGradient(colors: [Color(white: 0.25), .black], startPoint: .top, endPoint: .bottom))
            .frame(width: 58, height: 36)
    }
}

private struct VelvetRope: View {
    private let gold = LinearGradient(colors: [Color(red: 1, green: 0.86, blue: 0.38), Color(red: 0.72, green: 0.52, blue: 0.1)],
                                      startPoint: .leading, endPoint: .trailing)

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: 24, y: 22))
                    p.addQuadCurve(to: CGPoint(x: w - 24, y: 22), control: CGPoint(x: w / 2, y: 110))
                }
                .stroke(Color(red: 0.75, green: 0.05, blue: 0.12), style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .shadow(color: .black.opacity(0.4), radius: 4, y: 3)

                HStack {
                    post
                    Spacer()
                    post
                }
            }
        }
    }

    private var post: some View {
        VStack(spacing: 0) {
            Circle().fill(gold).frame(width: 30, height: 30)
            RoundedRectangle(cornerRadius: 5).fill(gold).frame(width: 14, height: 86)
            Ellipse().fill(gold).frame(width: 52, height: 14)
        }
        .frame(width: 52)
    }
}

private struct FrownShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY), control: CGPoint(x: rect.midX, y: rect.minY - rect.height))
        return p
    }
}
