import SwiftUI

/// First-launch onboarding: "Spot it." / "Tell us in your language." / "Powered by Meta AI" (text
/// only) / "Fixed together." (with the permission primer), shown once and dismissed by setting
/// `hoth.onboarding.done`.
struct OnboardingView: View {
    static let storageKey = "hoth.onboarding.done"

    @AppStorage(OnboardingView.storageKey) private var isOnboardingDone = false
    @State private var pageIndex = 0

    private let pages: [OnboardingStep] = OnboardingStep.all

    private var isLastPage: Bool { pageIndex == pages.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            TabView(selection: $pageIndex) {
                ForEach(Array(pages.enumerated()), id: \.offset) { index, step in
                    Group {
                        switch step {
                        case .illustrated(let page, let showsPermissions):
                            OnboardingPageView(page: page, showsTagline: index == 0, showsPermissions: showsPermissions)
                        case .poweredByMeta:
                            PoweredByMetaPageView()
                        }
                    }
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(HoTHMotion.spring, value: pageIndex)

            VStack(spacing: HoTHSpacing.l) {
                PageDots(count: pages.count, selectedIndex: pageIndex)
                Button(action: advance) {
                    Text(isLastPage ? "Get started" : "Continue")
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("onboardingContinueButton")
            }
            .padding(.horizontal, HoTHSpacing.l)
            .padding(.bottom, HoTHSpacing.l)
        }
        .background(Color.hothBackground.ignoresSafeArea())
    }

    private var topBar: some View {
        HStack {
            Text(verbatim: "HoTH")
                .font(.hothDisplay(20))
                .foregroundStyle(Color.hothInk)
            Spacer()
            if !isLastPage {
                Button("Skip") { finish() }
                    .font(.hothHeadline)
                    .foregroundStyle(Color.hothInkSecondary)
                    .accessibilityIdentifier("onboardingSkipButton")
            }
        }
        .padding(.horizontal, HoTHSpacing.l)
        .padding(.top, HoTHSpacing.s)
        .frame(height: 44)
    }

    private func advance() {
        Haptics.tap()
        guard !isLastPage else {
            finish()
            return
        }
        withAnimation(HoTHMotion.spring) { pageIndex += 1 }
    }

    private func finish() {
        Haptics.success()
        isOnboardingDone = true
    }
}

// MARK: - Page model

private struct OnboardingPage {
    let imageName: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let pointSymbol: String
    let point: LocalizedStringKey

    static let spot = OnboardingPage(
        imageName: "onboarding_spot",
        title: "Spot it.",
        subtitle: "See something unsafe in your hay? Point your camera at it.",
        pointSymbol: "camera.viewfinder",
        point: "Live camera only. No gallery uploads."
    )
    static let talk = OnboardingPage(
        imageName: "onboarding_talk",
        title: "Tell us in your language.",
        subtitle: "Just talk. Your assistant asks the right questions and writes the report.",
        pointSymbol: "waveform",
        point: "Voice-first, in Arabic and English."
    )
    static let fixed = OnboardingPage(
        imageName: "onboarding_fixed",
        title: "Fixed together.",
        subtitle: "Neighbours confirm, the city crew fixes, everyone sees the before and after.",
        pointSymbol: "sparkles",
        point: "AI priority you can understand, with the reasons shown."
    )
}

/// One onboarding page. The permission primer is flagged per page so reordering cannot move it.
private enum OnboardingStep {
    case illustrated(OnboardingPage, showsPermissions: Bool)
    case poweredByMeta

    static let all: [OnboardingStep] = [
        .illustrated(.spot, showsPermissions: false),
        .illustrated(.talk, showsPermissions: false),
        .poweredByMeta,
        .illustrated(.fixed, showsPermissions: true),
    ]
}

// MARK: - Page view

private struct OnboardingPageView: View {
    let page: OnboardingPage
    let showsTagline: Bool
    let showsPermissions: Bool

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: HoTHSpacing.l) {
                illustration
                VStack(alignment: .leading, spacing: HoTHSpacing.s) {
                    if showsTagline {
                        // Separate runs so the bidi algorithm keeps "حيّ" first in both directions.
                        HStack(spacing: HoTHSpacing.xs) {
                            Text(verbatim: "حيّ")
                            Text(verbatim: "·")
                            Text("Hay = neighbourhood")
                        }
                            .font(.hothCaption.weight(.bold))
                            .foregroundStyle(Color.hothTeal)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.hothTeal.opacity(0.12)))
                    }
                    Text(page.title)
                        .font(.hothDisplay(40))
                        .hothTracking(-1)
                        .foregroundStyle(Color.hothInk)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(page.subtitle)
                        .font(.hothBody)
                        .foregroundStyle(Color.hothInkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                pointRow
                if showsPermissions { permissionPrimer }
            }
            .padding(.horizontal, HoTHSpacing.l)
            .padding(.bottom, HoTHSpacing.m)
        }
    }

    private var illustration: some View {
        Image(page.imageName)
            .resizable()
            .aspectRatio(3 / 2, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: HoTHRadius.card + 4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: HoTHRadius.card + 4, style: .continuous)
                    .strokeBorder(Color.hothInk.opacity(0.06), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.06), radius: 18, x: 0, y: 10)
            .padding(.top, HoTHSpacing.s)
            .accessibilityHidden(true)
    }

    private var pointRow: some View {
        HStack(alignment: .top, spacing: HoTHSpacing.s) {
            Image(systemName: page.pointSymbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.hothAccent)
                .frame(width: 22)
            Text(page.point)
                .font(.hothHeadline)
                .foregroundStyle(Color.hothInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(HoTHSpacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: HoTHRadius.inner, style: .continuous).fill(Color.hothSand.opacity(0.7)))
    }

    private var permissionPrimer: some View {
        VStack(alignment: .leading, spacing: HoTHSpacing.s) {
            Text("We'll ask for")
                .font(.hothCaption.weight(.bold))
                .textCase(.uppercase)
                .hothTracking(1.2)
                .foregroundStyle(Color.hothInkSecondary)
            PermissionRow(symbol: "camera.fill", title: "Camera", detail: "To photograph the hazard live, where it is.")
            PermissionRow(symbol: "mic.fill", title: "Microphone", detail: "To describe it by voice, in your language.")
            PermissionRow(symbol: "location.fill", title: "Location", detail: "To pin it on the map for neighbours nearby.")
        }
    }
}

private struct PermissionRow: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        HStack(alignment: .center, spacing: HoTHSpacing.m) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.hothTeal)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color.hothTeal.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.hothHeadline).foregroundStyle(Color.hothInk)
                Text(detail)
                    .font(.hothCaption)
                    .foregroundStyle(Color.hothInkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Powered by Meta AI

/// Text-only page naming the Meta models and what each does in HoTH (no Meta logo or marks).
private struct PoweredByMetaPageView: View {
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: HoTHSpacing.l) {
                VStack(alignment: .leading, spacing: HoTHSpacing.s) {
                    Label { Text("Powered by Meta AI") } icon: { Image(systemName: "sparkles") }
                        .font(.hothCaption.weight(.bold))
                        .foregroundStyle(Color.hothAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.hothAccent.opacity(0.12)))
                    Text("Three Meta models, one neighbourhood.")
                        .font(.hothDisplay(36))
                        .hothTracking(-1)
                        .foregroundStyle(Color.hothInk)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Each one has a single job in HoTH. You always review the report before it is posted.")
                        .font(.hothBody)
                        .foregroundStyle(Color.hothInkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, HoTHSpacing.l)

                VStack(spacing: HoTHSpacing.s) {
                    ModelRow(symbol: "sparkles", name: "Muse Spark 1.3",
                             detail: "Understands your photo, runs the interview agent, checks fixes and moderates comments.")
                    ModelRow(symbol: "waveform", name: "Muse Voice Transcribe",
                             detail: "Turns your Arabic or English voice into text.")
                    ModelRow(symbol: "viewfinder", name: "SAM 3.1 (Segment Anything)",
                             detail: "Outlines the hazard on your photo.")
                }

                Label {
                    Text("Your photo and voice go to the Meta Model API only when you report, and faces and number plates are blurred on your phone before the photo is sent.")
                } icon: {
                    Image(systemName: "lock.fill")
                }
                .font(.hothCaption)
                .foregroundStyle(Color.hothInkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, HoTHSpacing.l)
            .padding(.bottom, HoTHSpacing.m)
        }
        .accessibilityIdentifier("onboardingMetaPage")
    }
}

private struct ModelRow: View {
    let symbol: String
    /// Model names stay in Latin script in every language.
    let name: String
    let detail: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: HoTHSpacing.m) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.hothAccent)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.hothAccent.opacity(0.12)))
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: name).font(.hothHeadline).foregroundStyle(Color.hothInk)
                Text(detail)
                    .font(.hothCaption)
                    .foregroundStyle(Color.hothInkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(HoTHSpacing.m)
        .background(RoundedRectangle(cornerRadius: HoTHRadius.card, style: .continuous).fill(Color.hothSurface))
        .overlay(
            RoundedRectangle(cornerRadius: HoTHRadius.card, style: .continuous)
                .strokeBorder(Color.hothInk.opacity(0.06), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Page dots

private struct PageDots: View {
    let count: Int
    let selectedIndex: Int

    var body: some View {
        HStack(spacing: HoTHSpacing.s) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == selectedIndex ? Color.hothAccent : Color.hothInk.opacity(0.15))
                    .frame(width: index == selectedIndex ? 22 : 8, height: 8)
            }
        }
        .animation(HoTHMotion.spring, value: selectedIndex)
        .accessibilityElement()
        .accessibilityLabel(Text("Page \(selectedIndex + 1) of \(count)"))
    }
}

#Preview {
    OnboardingView()
}
