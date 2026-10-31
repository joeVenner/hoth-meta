import SwiftUI

/// Top-level navigation: Feed, Map | Report | Hero (or Crew), Settings.
/// A custom bar replaces the system tab bar; the TabView keeps each tab's state alive.
/// Report opens full screen (camera → interview → ticket) so the floating bar never covers the flow.
struct RootTabs: View {
    enum Tab: Hashable, CaseIterable {
        case feed, map, hero, settings
    }

    /// True while the launch splash covers the app; onboarding waits until it ends.
    var isLaunching: Bool = false

    @ObservedObject private var services = AppServices.shared
    @State private var selection: Tab = .feed
    @State private var isReporting = false
    @AppStorage(OnboardingView.storageKey) private var isOnboardingDone = false

    var body: some View {
        TabView(selection: $selection) {
            FeedView().tag(Tab.feed).toolbar(.hidden, for: .tabBar)
            MapTabView().tag(Tab.map).toolbar(.hidden, for: .tabBar)
            // City Crew mode (Settings role) takes the Hero slot.
            Group { if services.isCrew { CrewView() } else { HeroProfileView() } }
                .tag(Tab.hero).toolbar(.hidden, for: .tabBar)
            SettingsView().tag(Tab.settings).toolbar(.hidden, for: .tabBar)
        }
        .fullScreenCover(isPresented: $isReporting) {
            ReportEntryView {
                isReporting = false
                selection = .feed
            }
            .environment(\.locale, services.localeOverride ?? Locale.autoupdatingCurrent)
            .environment(\.layoutDirection, services.layoutDirection)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HoTHTabBar(selection: $selection) { isReporting = true }
        }
        .tint(Color.hothAccent)
        .environment(\.locale, services.localeOverride ?? Locale.autoupdatingCurrent)
        .environment(\.layoutDirection, services.layoutDirection)
        .fullScreenCover(isPresented: Binding(get: { !isOnboardingDone && !isLaunching },
                                              set: { isOnboardingDone = !$0 })) {
            OnboardingView()
                .modifier(FadeInOnAppear())
                .background(Color("LaunchBackground").ignoresSafeArea())
                .environment(\.locale, services.localeOverride ?? Locale.autoupdatingCurrent)
                .environment(\.layoutDirection, services.layoutDirection)
        }
    }
}

private struct HoTHTabBar: View {
    @Binding var selection: RootTabs.Tab
    let onReport: () -> Void
    @ObservedObject private var services = AppServices.shared

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            // Two equal-width halves keep the Report button optically centred (also in RTL).
            HStack(spacing: 0) {
                item(.feed, title: "Feed", symbol: "square.stack.fill", identifier: "feedTabButton")
                item(.map, title: "Map", symbol: "map.fill", identifier: "mapTabButton")
            }
            .frame(maxWidth: .infinity)
            reportButton.frame(width: 76)
            HStack(spacing: 0) {
                // City Crew mode (Settings role) takes the Hero slot.
                if services.isCrew {
                    item(.hero, title: "Crew", symbol: "wrench.and.screwdriver.fill", identifier: "crewTabButton")
                } else {
                    item(.hero, title: "Hero", symbol: "shield.lefthalf.filled", identifier: "heroTabButton")
                }
                item(.settings, title: "Settings", symbol: "slider.horizontal.3", identifier: "settingsTabButton")
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, HoTHSpacing.s)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(Capsule(style: .continuous).fill(Color.hothSurface.opacity(0.7)))
        )
        .overlay(Capsule(style: .continuous).strokeBorder(Color.hothInk.opacity(0.06)))
        .shadow(color: Color.black.opacity(0.08), radius: 24, x: 0, y: 10)
        .padding(.horizontal, HoTHSpacing.l)
        .padding(.bottom, HoTHSpacing.xs)
    }

    private func item(_ tab: RootTabs.Tab, title: LocalizedStringKey, symbol: String,
                      identifier: String) -> some View {
        let isSelected = selection == tab
        return Button {
            Haptics.tap()
            withAnimation(HoTHMotion.spring) { selection = tab }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: isSelected ? .semibold : .regular))
                    .frame(height: 22)
                    .symbolEffect(.bounce, value: isSelected)
                Text(title)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isSelected ? Color.hothAccent : Color.hothInkSecondary.opacity(0.85))
            .frame(maxWidth: .infinity, minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityIdentifier(identifier)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var reportButton: some View {
        Button {
            Haptics.tap()
            onReport()
        } label: {
            ZStack {
                Circle()
                    .fill(Color.hothAccent)
                    .frame(width: 60, height: 60)
                    .shadow(color: Color.hothAccent.opacity(0.4), radius: 14, x: 0, y: 8)
                Image(systemName: "camera.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.white)
            }
            .offset(y: -14)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Report"))
        .accessibilityIdentifier("reportTabButton")
    }
}

/// Fades content in once; used so onboarding cross-fades in after the launch splash.
private struct FadeInOnAppear: ViewModifier {
    @State private var isVisible = false

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .onAppear { withAnimation(.easeOut(duration: 0.45)) { isVisible = true } }
    }
}

#Preview {
    RootTabs()
}
