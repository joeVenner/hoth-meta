import XCTest
@testable import HoTHCore

final class RewardsTests: XCTestCase {
    func testPointsPerEvent() {
        XCTAssertEqual(Rewards.points(for: .firstReporter), 20)
        XCTAssertEqual(Rewards.points(for: .confirmation), 10)
        XCTAssertEqual(Rewards.points(for: .verifiedFix), 50)
        XCTAssertEqual(Rewards.points(for: .rejectedReport), 0)
    }

    func testLevelBoundaries() {
        XCTAssertEqual(Rewards.level(forPoints: 0), .neighbour)
        XCTAssertEqual(Rewards.level(forPoints: 149), .neighbour)
        XCTAssertEqual(Rewards.level(forPoints: 150), .guardian)
        XCTAssertEqual(Rewards.level(forPoints: 399), .guardian)
        XCTAssertEqual(Rewards.level(forPoints: 400), .heroOfTheHay)
        XCTAssertEqual(HeroLevel.heroOfTheHay.titleEN, "Hero of the Hay")
    }

    func testPointsToNextLevel() {
        XCTAssertEqual(Rewards.pointsToNextLevel(from: 0), 150)
        XCTAssertEqual(Rewards.pointsToNextLevel(from: 390), 10)
        XCTAssertNil(Rewards.pointsToNextLevel(from: 400))
    }

    func testApplyingEventsAccumulatesPointsAndLevel() {
        let events: [RewardEvent] = [.firstReporter, .verifiedFix, .verifiedFix, .confirmation, .confirmation, .confirmation]
        let state = Rewards.apply(events)
        XCTAssertEqual(state.points, 20 + 100 + 30)
        XCTAssertEqual(state.level, .guardian)
    }

    func testTrustRisesWithVerifiedAndDropsWithRejected() {
        XCTAssertEqual(RewardState.initial.trust, 50)
        XCTAssertEqual(Rewards.apply(.verifiedReport, to: .initial).trust, 55)
        XCTAssertEqual(Rewards.apply(.rejectedReport, to: .initial).trust, 35)
    }

    func testTrustClampedToZeroAndHundred() {
        XCTAssertEqual(Rewards.apply(Array(repeating: .verifiedReport, count: 50)).trust, 100)
        XCTAssertEqual(Rewards.apply(Array(repeating: .rejectedReport, count: 10)).trust, 0)
        XCTAssertEqual(RewardState(points: -5, trust: 200), RewardState(points: 0, trust: 100))
    }
}
