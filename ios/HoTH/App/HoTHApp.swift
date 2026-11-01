import OSLog
import SwiftData
import SwiftUI

/// App entry point for HoTH ("Heroes of the Hay").
@main
struct HoTHApp: App {
    private let modelContainer: ModelContainer

    init() {
        let logger = Logger(subsystem: "io.fomy.hoth", category: "App")
        do {
            modelContainer = try HoTHStore.makeContainer(inMemory: AppServices.isUITestRun)
        } catch {
            // Keep the demo running on a broken store rather than crashing on launch.
            logger.error("Persistent store failed, using in-memory store: \(error.localizedDescription)")
            do {
                modelContainer = try HoTHStore.makeContainer(inMemory: true)
            } catch {
                fatalError("Unable to create even an in-memory ModelContainer: \(error)")
            }
        }
        do {
            try SeedLoader.seedIfNeeded(context: modelContainer.mainContext)
        } catch {
            logger.error("Seeding demo community failed: \(String(describing: error))")
        }
    }

    var body: some Scene {
        WindowGroup {
            AppRootView()
        }
        .modelContainer(modelContainer)
    }
}

/// Hosts the branded launch splash above the app, then cross-fades into RootTabs (or onboarding).
/// Skipped in UI-test runs so tests aren't slowed.
private struct AppRootView: View {
    @ObservedObject private var services = AppServices.shared
    @AppStorage(OnboardingView.storageKey) private var isOnboardingDone = false
    @State private var isSplashVisible = !AppServices.isUITestRun
    /// Holds onboarding back; released separately so the splash can stay mounted beneath the cover.
    @State private var isLaunching = !AppServices.isUITestRun

    var body: some View {
        ZStack {
            RootTabs(isLaunching: isLaunching)
                .id(services.resetGeneration)
            if isSplashVisible {
                LaunchSplashView(onFinish: finishSplash)
                    .environment(\.locale, services.localeOverride ?? Locale.autoupdatingCurrent)
                    .environment(\.layoutDirection, services.layoutDirection)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
    }

    private func finishSplash() {
        if isOnboardingDone {
            isLaunching = false
            withAnimation(.easeInOut(duration: 0.45)) { isSplashVisible = false }
            return
        }
        // Onboarding is a full-screen cover: present it without the slide-up so it fades in on the
        // same paper colour (see RootTabs), and only unmount the splash once it is hidden beneath.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { isLaunching = false }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            withTransaction(transaction) { isSplashVisible = false }
        }
    }
}
