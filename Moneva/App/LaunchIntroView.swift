import SwiftUI

/// The 3-second launch intro (design/intro canvas): the wallet card rises, its stripe draws in,
/// the coin drops onto the corner, the wordmark rises letter by letter, then everything fades over Home.
/// Geometry is the app icon's (design/icons/Wallet.dc.html) scaled to a 200 pt box.
struct LaunchIntroView: View {
    var onFinish: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var started = false

    private static let duration = 3.0
    private static let name = Array("Ledgea")

    struct Frame {
        var cardY: CGFloat = 90
        var cardAngle = 6.0
        var cardScale: CGFloat = 0.9
        var cardOpacity = 0.0
        var stripe: CGFloat = 0
        var coinY: CGFloat = -170
        var coinScaleX: CGFloat = 0.9
        var coinScaleY: CGFloat = 0.9
        var coinOpacity = 0.0
        /// Seconds since the wordmark started (0…0.8); each letter starts 45 ms after the previous one.
        var wordTime = 0.0
        /// 0 → 1 over the closing hand-off.
        var exit = 0.0

        /// Reduce Motion: the finished mark, only the hand-off fade keeps playing.
        static let settled = Frame(cardY: 0, cardAngle: -8, cardScale: 1, cardOpacity: 1, stripe: 1, coinY: 0,
                                   coinScaleX: 1, coinScaleY: 1, coinOpacity: 1, wordTime: 1)
    }

    var body: some View {
        ZStack {
            Palette.ground.ignoresSafeArea()
            content(Frame())
                .keyframeAnimator(initialValue: Frame(), trigger: started) { _, frame in
                    content(frame)
                } keyframes: { _ in
                    KeyframeTrack(\.cardY) {
                        SpringKeyframe(0, duration: 0.84, spring: .init(duration: 0.6, bounce: 0.3))
                        LinearKeyframe(0, duration: 0.36)
                        LinearKeyframe(3, duration: 0.09, timingCurve: .easeOut)
                        SpringKeyframe(0, duration: 0.3)
                    }
                    KeyframeTrack(\.cardAngle) {
                        SpringKeyframe(-8, duration: 0.84, spring: .init(duration: 0.6, bounce: 0.3))
                        LinearKeyframe(-8, duration: 0.36)
                        LinearKeyframe(-8.6, duration: 0.09, timingCurve: .easeOut)
                        SpringKeyframe(-8, duration: 0.3)
                    }
                    KeyframeTrack(\.cardScale) { SpringKeyframe(1, duration: 0.66, spring: .snappy) }
                    KeyframeTrack(\.cardOpacity) { LinearKeyframe(1, duration: 0.4) }
                    KeyframeTrack(\.stripe) {
                        LinearKeyframe(0, duration: 0.54)
                        LinearKeyframe(1, duration: 0.42, timingCurve: .easeInOut)
                    }
                    KeyframeTrack(\.coinY) {
                        LinearKeyframe(-170, duration: 0.72)
                        LinearKeyframe(0, duration: 0.48, timingCurve: .easeIn)
                        LinearKeyframe(-10, duration: 0.15, timingCurve: .easeOut)
                        LinearKeyframe(0, duration: 0.15, timingCurve: .easeIn)
                    }
                    KeyframeTrack(\.coinScaleX) {
                        LinearKeyframe(0.9, duration: 0.72)
                        LinearKeyframe(1, duration: 0.38)
                        LinearKeyframe(1.12, duration: 0.1)
                        SpringKeyframe(1, duration: 0.3)
                    }
                    KeyframeTrack(\.coinScaleY) {
                        LinearKeyframe(0.9, duration: 0.72)
                        LinearKeyframe(1, duration: 0.38)
                        LinearKeyframe(0.86, duration: 0.1)
                        SpringKeyframe(1, duration: 0.3)
                    }
                    KeyframeTrack(\.coinOpacity) {
                        LinearKeyframe(0, duration: 0.72)
                        LinearKeyframe(1, duration: 0.09)
                    }
                    KeyframeTrack(\.wordTime) {
                        LinearKeyframe(0, duration: 1.3)
                        LinearKeyframe(0.8, duration: 0.8)
                    }
                    KeyframeTrack(\.exit) {
                        LinearKeyframe(0, duration: 2.55)
                        LinearKeyframe(1, duration: 0.45, timingCurve: .easeIn)
                    }
                }
        }
        .contentShape(.rect)
        .onTapGesture(perform: onFinish)
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: "Ledgea"))
        .task {
            started = true
            try? await Task.sleep(for: .seconds(Self.duration))
            onFinish()
        }
    }

    private func content(_ animated: Frame) -> some View {
        var frame = reduceMotion ? .settled : animated
        frame.exit = animated.exit
        return VStack(spacing: 4) {
            mark(frame)
            wordmark(frame.wordTime)
        }
        .padding(.bottom, 40)
        .scaleEffect(1 + 0.06 * frame.exit)
        .opacity(1 - frame.exit)
    }

    private func mark(_ frame: Frame) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11)
                .fill(Palette.accent)
                .overlay(alignment: .topLeading) {
                    Rectangle()
                        .fill(Palette.accentSoft.opacity(0.85))
                        .frame(height: 12)
                        .scaleEffect(x: frame.stripe, anchor: .leading)
                        .offset(y: 26)
                }
                .clipShape(.rect(cornerRadius: 11))
                .frame(width: 121, height: 82)
                .scaleEffect(frame.cardScale)
                .rotationEffect(.degrees(frame.cardAngle))
                .offset(y: frame.cardY)
                .opacity(frame.cardOpacity)
                .position(x: 100.5, y: 100)

            Circle()
                .fill(Color(hex: "F2EFE9"))
                .overlay { Circle().strokeBorder(Palette.accent.opacity(0.22), lineWidth: 2) }
                .frame(width: 43, height: 43)
                .scaleEffect(x: frame.coinScaleX, y: frame.coinScaleY, anchor: .bottom)
                .offset(y: frame.coinY)
                .opacity(frame.coinOpacity)
                .position(x: 149.5, y: 50.5)
        }
        .frame(width: 200, height: 200)
    }

    private func wordmark(_ time: Double) -> some View {
        HStack(spacing: 0) {
            ForEach(Self.name.indices, id: \.self) { index in
                let linear = min(max((time - Double(index) * 0.045) / 0.55, 0), 1)
                let progress = 1 - pow(1 - linear, 3)
                Text(verbatim: String(Self.name[index]))
                    .opacity(progress)
                    .offset(y: 16 * (1 - progress))
            }
        }
        .font(.system(size: 44, weight: .medium, design: .serif))
        .kerning(-0.5)
        .foregroundStyle(Palette.ink)
    }
}

#Preview {
    LaunchIntroView {}
}
