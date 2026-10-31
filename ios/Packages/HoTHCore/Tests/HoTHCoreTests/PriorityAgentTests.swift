import XCTest
@testable import HoTHCore

final class PriorityAgentTests: XCTestCase {
    private let childEquipment = makeVision(category: .playgroundEquipment, hazards: [.sharpEdge],
                                            childUseEquipment: true, scene: .park, proposal: .medium)

    // MARK: Child-equipment floor

    func testChildEquipmentSharpEdgeFloorsToHigh() {
        let decision = PriorityAgent.decide(PriorityInput(vision: childEquipment))
        XCTAssertEqual(decision.level, .high)
        XCTAssertEqual(decision.floorApplied, "HIGH — child equipment")
        XCTAssertTrue(decision.signals.contains { $0.id == "child_equipment_hazard" })
    }

    func testChildEquipmentFallFloorsToHigh() {
        let vision = makeVision(category: .playgroundEquipment, hazards: [.fall], childUseEquipment: true,
                                scene: .park, proposal: .low)
        XCTAssertEqual(PriorityAgent.decide(PriorityInput(vision: vision)).level, .high)
    }

    func testChildEquipmentWithoutSharpOrFallHasNoFloor() {
        let vision = makeVision(category: .playgroundEquipment, hazards: [.trip], childUseEquipment: true,
                                scene: .park, proposal: .low)
        let decision = PriorityAgent.decide(PriorityInput(vision: vision))
        XCTAssertEqual(decision.level, .low)
        XCTAssertNil(decision.floorApplied)
    }

    func testChildEquipmentInPlaygroundIsCriticalChildSafety() {
        let decision = PriorityAgent.decide(PriorityInput(vision: childEquipment, location: .playground))
        XCTAssertEqual(decision.level, .critical)
        XCTAssertEqual(decision.floorApplied, "CRITICAL — child safety")
        XCTAssertEqual(decision.reasonEN,
                       "Sharp metal on equipment children use, in a playground — escalated to critical.")
        XCTAssertTrue(decision.reasonAR.contains("حرجة"))
        XCTAssertGreaterThanOrEqual(decision.score, 80)
    }

    func testChildEquipmentNearSchoolIsCritical() {
        XCTAssertEqual(PriorityAgent.decide(PriorityInput(vision: childEquipment, location: .school)).level, .critical)
    }

    func testChildEquipmentWithChildPresentIsCritical() {
        let vision = makeVision(category: .playgroundEquipment, hazards: [.sharpEdge], childUseEquipment: true,
                                childPresent: true, scene: .park, proposal: .medium)
        let decision = PriorityAgent.decide(PriorityInput(vision: vision))
        XCTAssertEqual(decision.level, .critical)
        XCTAssertTrue(decision.signals.contains { $0.id == "child_present" })
    }

    func testChildEquipmentWithChildUsingNowFlagIsCritical() {
        XCTAssertEqual(PriorityAgent.decide(PriorityInput(vision: childEquipment, childUsingNow: true)).level, .critical)
    }

    func testChildUsingNowFromInterviewAnswer() {
        let english = PriorityInput(vision: childEquipment, answers: ["children_using_now": "Yes, two kids"])
        let arabic = PriorityInput(vision: childEquipment, answers: ["children_using_now": "ايه، في أطفال"])
        let negative = PriorityInput(vision: childEquipment, answers: ["children_using_now": "no"])
        XCTAssertEqual(PriorityAgent.decide(english).level, .critical)
        XCTAssertEqual(PriorityAgent.decide(arabic).level, .critical)
        XCTAssertEqual(PriorityAgent.decide(negative).level, .high)
    }

    func testExplicitFlagOverridesAnswer() {
        let input = PriorityInput(vision: childEquipment, answers: ["children_using_now": "yes"], childUsingNow: false)
        XCTAssertEqual(PriorityAgent.decide(input).level, .high)
    }

    // MARK: Open manhole

    func testOpenManholeIsAlwaysCritical() {
        let vision = makeVision(category: .openManhole, scene: .street, proposal: .low)
        let decision = PriorityAgent.decide(PriorityInput(vision: vision))
        XCTAssertEqual(decision.level, .critical)
        XCTAssertEqual(decision.floorApplied, "CRITICAL — open manhole")
    }

    // MARK: Electrical

    func testElectricalHazardFloorsToHigh() {
        let vision = makeVision(category: .electricalHazard, hazards: [.electrical], scene: .street, proposal: .low)
        let decision = PriorityAgent.decide(PriorityInput(vision: vision))
        XCTAssertEqual(decision.level, .high)
        XCTAssertEqual(decision.floorApplied, "HIGH — electrical")
    }

    func testElectricalHazardKindInOtherCategoryAlsoFloors() {
        let vision = makeVision(category: .other, hazards: [.electrical], scene: .street, proposal: .low)
        XCTAssertEqual(PriorityAgent.decide(PriorityInput(vision: vision)).level, .high)
    }

    func testElectricalNearPlaygroundIsCritical() {
        let vision = makeVision(category: .electricalHazard, hazards: [.electrical], scene: .street, proposal: .medium)
        let decision = PriorityAgent.decide(PriorityInput(vision: vision, location: .playground))
        XCTAssertEqual(decision.level, .critical)
        XCTAssertEqual(decision.floorApplied, "CRITICAL — electrical danger")
    }

    func testElectricalNearSchoolOrChildPresentIsCritical() {
        let vision = makeVision(category: .electricalHazard, hazards: [.electrical], scene: .schoolArea, proposal: .low)
        XCTAssertEqual(PriorityAgent.decide(PriorityInput(vision: vision)).level, .critical)
        let child = makeVision(category: .electricalHazard, hazards: [.electrical], childPresent: true,
                               scene: .street, proposal: .low)
        XCTAssertEqual(PriorityAgent.decide(PriorityInput(vision: child)).level, .critical)
    }

    func testElectricalSparkingOrWaterIsCritical() {
        let vision = makeVision(category: .electricalHazard, hazards: [.electrical], scene: .street, proposal: .low)
        XCTAssertEqual(PriorityAgent.decide(PriorityInput(vision: vision, answers: ["sparking": "yes"])).level, .critical)
        XCTAssertEqual(PriorityAgent.decide(PriorityInput(vision: vision, answers: ["near_water": "نعم"])).level, .critical)
    }

    // MARK: Not an issue

    func testNotAnIssueIsLowAndFlaggedEvenWithConfirmations() {
        let vision = makeVision(category: .notAnIssue, proposal: .high)
        let decision = PriorityAgent.decide(PriorityInput(vision: vision, confirmations: 10, reportAgeHours: 100))
        XCTAssertEqual(decision.level, .low)
        XCTAssertTrue(decision.isFlagged)
        XCTAssertEqual(decision.score, 0)
        XCTAssertEqual(decision.signals.map(\.id), ["not_an_issue"])
    }

    // MARK: Score, thresholds, community

    func testFloorsNeverLowerTheLLMProposal() {
        let vision = makeVision(category: .potholePavement, hazards: [.trip], scene: .street, proposal: .critical)
        let decision = PriorityAgent.decide(PriorityInput(vision: vision))
        XCTAssertEqual(decision.level, .critical)
        XCTAssertNil(decision.floorApplied)
    }

    func testThresholds() {
        XCTAssertEqual(PriorityAgent.level(forScore: 0), .low)
        XCTAssertEqual(PriorityAgent.level(forScore: 39), .low)
        XCTAssertEqual(PriorityAgent.level(forScore: 40), .medium)
        XCTAssertEqual(PriorityAgent.level(forScore: 59), .medium)
        XCTAssertEqual(PriorityAgent.level(forScore: 60), .high)
        XCTAssertEqual(PriorityAgent.level(forScore: 79), .high)
        XCTAssertEqual(PriorityAgent.level(forScore: 80), .critical)
        XCTAssertEqual(PriorityAgent.level(forScore: 100), .critical)
    }

    func testConfirmationsAddSixEachCappedAtThirty() {
        let vision = makeVision(category: .potholePavement, hazards: [.trip], scene: .street, proposal: .low)
        let two = PriorityAgent.decide(PriorityInput(vision: vision, confirmations: 2))
        XCTAssertEqual(two.score, 20 + 12)
        XCTAssertEqual(two.level, .low)
        let many = PriorityAgent.decide(PriorityInput(vision: vision, confirmations: 20))
        XCTAssertEqual(many.signals.first { $0.id == "confirmations" }?.weight, 30)
        XCTAssertEqual(many.score, 50)
        XCTAssertEqual(many.level, .medium, "crossing the threshold bumps the level")
    }

    func testLongDurationAddsFivePointsOnlyAfterSevenDays() {
        let vision = makeVision(category: .wasteOverflowDumping, hazards: [.sanitation], scene: .residential, proposal: .low)
        XCTAssertEqual(PriorityAgent.decide(PriorityInput(vision: vision, durationDays: 7)).score, 20)
        XCTAssertEqual(PriorityAgent.decide(PriorityInput(vision: vision, durationDays: 8)).score, 25)
    }

    func testReportAgeIsInformationalOnly() {
        let vision = makeVision(category: .potholePavement, scene: .street, proposal: .medium)
        let decision = PriorityAgent.decide(PriorityInput(vision: vision, reportAgeHours: 72))
        XCTAssertEqual(decision.signals.first { $0.id == "report_age" }?.weight, 0)
        XCTAssertEqual(decision.score, 45)
    }

    func testScoreAlwaysInsideFinalLevelBand() {
        for category in ReportCategory.allCases {
            for proposal in Severity.allCases {
                for confirmations in [0, 3, 10] {
                    let vision = makeVision(category: category, hazards: [.sharpEdge, .electrical],
                                            childUseEquipment: true, scene: .playground, proposal: proposal)
                    let decision = PriorityAgent.decide(PriorityInput(vision: vision, confirmations: confirmations))
                    XCTAssertTrue((0...100).contains(decision.score))
                    XCTAssertEqual(PriorityAgent.level(forScore: decision.score), decision.level,
                                   "\(category) \(proposal) \(confirmations)")
                }
            }
        }
    }

    func testNoSignalsFallsBackToLLMReason() {
        let vision = VisionAnalysis(category: .potholePavement, sceneType: .street, severityProposal: .medium,
                                    severityReasonEN: "A deep pothole in the lane.", severityReasonAR: "حفرة عميقة.")
        let decision = PriorityAgent.decide(PriorityInput(vision: vision))
        XCTAssertEqual(decision.reasonEN, "A deep pothole in the lane. — rated medium.")
        XCTAssertTrue(decision.reasonAR.hasPrefix("حفرة عميقة."))
    }

    // MARK: Location

    func testLocationTypeMapping() {
        XCTAssertEqual(LocationType(scene: .playground), .playground)
        XCTAssertEqual(LocationType(scene: .schoolArea), .school)
        XCTAssertEqual(LocationType(scene: .park), .park)
        XCTAssertEqual(LocationType(scene: .sidewalk), .street)
        XCTAssertEqual(LocationType(scene: .parking), .street)
        XCTAssertEqual(LocationType(scene: .residential), .residential)
        XCTAssertEqual(LocationType(scene: .other), .unknown)
        XCTAssertEqual(LocationType(scene: .street, poi: .playground), .playground)
        XCTAssertEqual(LocationType(scene: .park, poi: .unknown), .park)
    }
}
