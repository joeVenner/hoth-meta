#if DEBUG
import HoTHCore
import XCTest
@testable import HoTH

/// Capture mode launch reset (H1): pure env dictionaries and an isolated defaults suite; the process
/// environment is never touched.
@MainActor
final class DemoCaptureLaunchTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "DemoCaptureLaunchTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.set("A,B", forKey: ConfirmedReports.storageKey)
        defaults.set(1_000.0, forKey: NeighbourAlertCenter.StorageKey.lastAlertAt)
        defaults.set(true, forKey: OnboardingView.storageKey)
        defaults.set("ar", forKey: AppServices.SettingsKey.language)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testCaptureFlagNeedsExactlyOne() {
        XCTAssertTrue(DemoCapture.isEnabled(environment: ["HOTH_DEMO_CAPTURE": "1"]))
        XCTAssertFalse(DemoCapture.isEnabled(environment: [:]))
        XCTAssertFalse(DemoCapture.isEnabled(environment: ["HOTH_DEMO_CAPTURE": "true"]))
        // The UI-test flag is a different mode and never turns capture on.
        XCTAssertFalse(DemoCapture.isEnabled(environment: ["HOTH_UITEST": "1"]))
    }

    func testCaptureLaunchClearsConfirmationsAndAlertTimestampOnly() {
        DemoCapture.prepareLaunch(defaults: defaults, environment: ["HOTH_DEMO_CAPTURE": "1"])
        XCTAssertNil(defaults.object(forKey: ConfirmedReports.storageKey))
        XCTAssertNil(defaults.object(forKey: NeighbourAlertCenter.StorageKey.lastAlertAt))
        XCTAssertEqual(defaults.object(forKey: OnboardingView.storageKey) as? Bool, true, "Onboarding stays done")
        XCTAssertEqual(defaults.string(forKey: AppServices.SettingsKey.language), "ar", "Settings untouched")
    }

    func testCaptureOnboardingAlsoClearsOnboardingFlag() {
        DemoCapture.prepareLaunch(defaults: defaults,
                                  environment: ["HOTH_DEMO_CAPTURE": "1", "HOTH_CAPTURE_ONBOARDING": "1"])
        XCTAssertNil(defaults.object(forKey: OnboardingView.storageKey))
    }

    func testWithoutCaptureFlagNothingIsCleared() {
        DemoCapture.prepareLaunch(defaults: defaults, environment: ["HOTH_CAPTURE_ONBOARDING": "1", "HOTH_UITEST": "1"])
        XCTAssertEqual(defaults.string(forKey: ConfirmedReports.storageKey), "A,B")
        XCTAssertNotNil(defaults.object(forKey: NeighbourAlertCenter.StorageKey.lastAlertAt))
        XCTAssertNotNil(defaults.object(forKey: OnboardingView.storageKey))
    }

    func testSkipSplashOnlyInCaptureMode() {
        XCTAssertTrue(DemoCapture.skipsSplash(environment: ["HOTH_DEMO_CAPTURE": "1", "HOTH_CAPTURE_SKIP_SPLASH": "1"]))
        XCTAssertFalse(DemoCapture.skipsSplash(environment: ["HOTH_DEMO_CAPTURE": "1"]))
        XCTAssertFalse(DemoCapture.skipsSplash(environment: ["HOTH_CAPTURE_SKIP_SPLASH": "1"]))
    }

    func testTestProcessIsNotACaptureRun() {
        XCTAssertFalse(AppServices.isDemoCaptureRun)
    }
}
#endif
