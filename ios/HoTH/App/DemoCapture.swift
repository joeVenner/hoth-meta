import Foundation
import OSLog

#if DEBUG
/// DEBUG-only demo-film capture mode (`HOTH_DEMO_CAPTURE=1` launch env, set by `DemoCaptureUITests`).
///
/// Unlike `HOTH_UITEST`, capture mode keeps every live path on (SAM, push-to-talk, the intake agent,
/// Muse Spark moderation, splash, alerts, notifications). It only makes launches repeatable: an
/// in-memory store that reseeds every launch, and a reset of the few UserDefaults that would otherwise
/// leak from one take into the next.
enum DemoCapture {
    enum EnvironmentKey {
        static let enabled = "HOTH_DEMO_CAPTURE"
        /// Also clear `hoth.onboarding.done`, so onboarding shows (pass no onboarding launch argument).
        static let showOnboarding = "HOTH_CAPTURE_ONBOARDING"
        /// Skip the launch splash for scenes that start mid-app.
        static let skipSplash = "HOTH_CAPTURE_SKIP_SPLASH"
        /// Absolute directory of push-to-talk WAV clips (see `FileVoicePlaylist`).
        static let wavDirectory = "HOTH_PTT_WAV_DIR"
        /// Absolute directory the capture JSON-lines log is appended to (see `CaptureLog`).
        static let logDirectory = "HOTH_CAPTURE_LOG_DIR"
        /// Scene name written into every capture-log record, so dry-run and take lines can be told apart.
        static let scene = "HOTH_CAPTURE_SCENE"
    }

    static func isEnabled(environment: [String: String]) -> Bool {
        environment[EnvironmentKey.enabled] == "1"
    }

    static func skipsSplash(environment: [String: String]) -> Bool {
        isEnabled(environment: environment) && environment[EnvironmentKey.skipSplash] == "1"
    }

    /// UserDefaults keys removed at launch in capture mode. `hoth.confirmedReportIDs` outlives the
    /// in-memory store, so a re-run would open a seeded case already "confirmed"; the alert timestamp
    /// would rate-limit the demo alert.
    @MainActor
    static func launchResetKeys(environment: [String: String]) -> [String] {
        guard isEnabled(environment: environment) else { return [] }
        var keys = [ConfirmedReports.storageKey, NeighbourAlertCenter.StorageKey.lastAlertAt]
        if environment[EnvironmentKey.showOnboarding] == "1" {
            keys.append(OnboardingView.storageKey)
        }
        return keys
    }

    /// Clears the per-take UserDefaults. Values passed as launch arguments live in the argument domain
    /// and still win for that run; this only removes what earlier runs persisted.
    @MainActor
    static func prepareLaunch(defaults: UserDefaults, environment: [String: String]) {
        for key in launchResetKeys(environment: environment) {
            defaults.removeObject(forKey: key)
        }
    }
}
#endif
