import SwiftUI

/// Branded cold-launch splash (~1.4 s). Its first frame matches the static `UILaunchScreen`
/// (`LaunchBackground` colour + centred 128 pt `hoth_logo`), so the hand-off from the system is seamless.
/// The logo springs in over a soft glow, the wordmark and tagline fade up, then `onFinish` fires.
/// Reduce Motion: no scaling or movement, only a gentle fade.
struct LaunchSplashView: View {
    /// Total time on screen before `onFinish` (the caller then cross-fades away).
    static let duration: Duration = .milliseconds(1400)
    /// Matches the static launch image: 384 px @3x.
    static let logoSize: CGFloat = 128

    let onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Starts at 1 to match the static launch image, then pops (spring) and settles.
    @State private var logoScale: CGFloat = 1
    @State private var isGlowing = false
    @State private var isWordmarkIn = false
    @State private var isTaglineIn = false

    var body: some View {
        ZStack {
            Color("LaunchBackground").ignoresSafeArea()

            // Logo sits at the exact full-screen centre (like the launch image); the glow and text
            // hang off it as background/overlay so neither shifts it.
            HoTHLogo(size: Self.logoSize)
                .scaleEffect(logoScale)
                .background(glow)
                .overlay(alignment: .top) { titleBlock.offset(y: Self.logoSize + 36) }
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("launchSplash")
        .task { await play() }
    }

    private var glow: some View {
        Circle()
            .fill(Color.hothAccent)
            .frame(width: Self.logoSize * 1.5, height: Self.logoSize * 1.5)
            .blur(radius: 44)
            .opacity(isGlowing ? 0.22 : 0)
            .scaleEffect(reduceMotion ? 1 : (isGlowing ? 1.15 : 0.7))
            .accessibilityHidden(true)
    }

    private var titleBlock: some View {
        VStack(spacing: HoTHSpacing.s) {
            VStack(spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(verbatim: "HoTH")
                        .font(.hothDisplay(40))
                        .tracking(-1.1)
                        .foregroundStyle(Color.hothInk)
                    Circle().fill(Color.hothAccent).frame(width: 8, height: 8)
                }
                .environment(\.layoutDirection, .leftToRight)
                Text("Heroes of the Hay")
                    .font(.hothCaption.weight(.semibold))
                    .textCase(.uppercase)
                    .hothTracking(1.6)
                    .foregroundStyle(Color.hothInkSecondary)
            }
            .opacity(isWordmarkIn ? 1 : 0)
            .offset(y: reduceMotion || isWordmarkIn ? 0 : 10)

            Text("The social network for your Hay")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(Color.hothInk.opacity(0.75))
                .padding(.top, HoTHSpacing.m)
                .opacity(isTaglineIn ? 1 : 0)
                .offset(y: reduceMotion || isTaglineIn ? 0 : 8)
        }
        .multilineTextAlignment(.center)
        .fixedSize()
    }

    @MainActor
    private func play() async {
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.4)) {
                isWordmarkIn = true
                isTaglineIn = true
            }
            try? await Task.sleep(for: Self.duration)
        } else {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { logoScale = 1.07 }
            withAnimation(.easeOut(duration: 0.6)) { isGlowing = true }
            withAnimation(.spring(response: 0.6, dampingFraction: 0.86).delay(0.3)) { isWordmarkIn = true }
            withAnimation(.spring(response: 0.6, dampingFraction: 0.86).delay(0.6)) { isTaglineIn = true }
            try? await Task.sleep(for: .milliseconds(260))
            withAnimation(.spring(response: 0.55, dampingFraction: 0.7)) { logoScale = 1 }
            try? await Task.sleep(for: .milliseconds(540))
            // Glow settles back down after its peak: one soft pulse.
            withAnimation(.easeInOut(duration: 0.6)) { isGlowing = false }
            try? await Task.sleep(for: Self.duration - .milliseconds(800))
        }
        guard !Task.isCancelled else { return }
        onFinish()
    }
}

#Preview {
    LaunchSplashView {}
}
