import HoTHCore
import MapKit
import XCTest
@testable import HoTH

/// P2-02: MapKit POI category → LocationType mapping (pure), and the chip it adds to the priority.
final class NearbyPlacesTests: XCTestCase {
    func testEmptyResultMapsToNil() {
        XCTAssertNil(NearbyPlaces.locationType(for: []))
    }

    func testUnrelatedOrMissingCategoriesMapToNil() {
        XCTAssertNil(NearbyPlaces.locationType(for: [.cafe, .parking, nil]))
    }

    func testEachRelevantCategory() {
        XCTAssertEqual(NearbyPlaces.locationType(for: [.amusementPark]), .playground)
        XCTAssertEqual(NearbyPlaces.locationType(for: [.school]), .school)
        XCTAssertEqual(NearbyPlaces.locationType(for: [.park]), .park)
        XCTAssertEqual(NearbyPlaces.locationType(for: [.nationalPark]), .park)
    }

    func testChildSafetyPrecedence() {
        XCTAssertEqual(NearbyPlaces.locationType(for: [.park, nil, .school]), .school)
        XCTAssertEqual(NearbyPlaces.locationType(for: [.school, .park, .amusementPark]), .playground)
    }

    func testDemoModeNeverLooksUp() {
        XCTAssertFalse(NearbyPlaces.shouldLookUp(isDemoMode: true, hasGPS: true))
        XCTAssertFalse(NearbyPlaces.shouldLookUp(isDemoMode: false, hasGPS: false))
    }

    func testNearbyPlaceAddsChipWithoutChangingScore() {
        let vision = VisionAnalysis(category: .potholePavement, sceneType: .street)
        let baseline = PriorityAgent.decide(PriorityInput(vision: vision))
        let nearPark = PriorityAgent.decide(PriorityInput(vision: vision, nearbyPlace: .park))
        XCTAssertEqual(nearPark.score, baseline.score)
        XCTAssertEqual(nearPark.level, baseline.level)
        XCTAssertTrue(nearPark.signals.contains { $0.id == "location_park" && $0.labelEN == "In a park" })
        XCTAssertFalse(baseline.signals.contains { $0.id.hasPrefix("location_") })
    }

    func testNearbySchoolBecomesTheLocationType() {
        let vision = VisionAnalysis(category: .potholePavement, sceneType: .street)
        let input = PriorityInput(vision: vision, nearbyPlace: .school)
        XCTAssertEqual(input.location, .school)
        let decision = PriorityAgent.decide(input)
        XCTAssertEqual(decision.signals.filter { $0.id.hasPrefix("location_") }.map(\.labelEN), ["Near a school"])
    }

    func testUnknownPlaceFallsBackToScene() {
        let vision = VisionAnalysis(category: .potholePavement, sceneType: .playground)
        let input = PriorityInput(vision: vision, nearbyPlace: .unknown)
        XCTAssertNil(input.nearbyPlace)
        XCTAssertEqual(input.location, .playground)
    }
}
