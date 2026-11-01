#if DEBUG
import CoreLocation
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

    /// Outside capture mode (always, in Release) push-to-talk records the microphone.
    func testRecorderFactoryUsesTheMicrophoneOutsideCapture() {
        let recorder = VoiceRecorderFactory.make()
        XCTAssertTrue(recorder is WAVVoiceRecorder)
        XCTAssertFalse(recorder is FileVoiceRecorder)
        XCTAssertEqual(VoiceRecorderFactory.micStatus(for: recorder)(), VoiceMicPermission.status,
                       "The real permission check, not the playlist's forced grant")
    }

    /// Capture C1 posts the spring rider as CRITICAL; the plan relies on it raising no neighbour alert
    /// over the feed and map shots. It sits about 1,079 m from home against a 1,000 m radius.
    func testSpringRiderSampleIsOutsideTheNeighbourAlertRadius() {
        let sample = DemoSamples.springRider.coordinate
        let distance = CLLocation(latitude: sample.latitude, longitude: sample.longitude).distance(from: FeedGeography.home)
        XCTAssertGreaterThan(distance, NeighbourAlertPolicy.radius)
        XCTAssertFalse(NeighbourAlertPolicy.shouldAlert(priority: .critical, distance: distance, lastAlertAt: nil))
    }
}
#endif
