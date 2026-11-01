import XCTest
@testable import HoTHCore

final class SchemaDecodingTests: XCTestCase {
    func testDecodesVisionAnalysisFixture() throws {
        let vision = try JSONDecoder().decode(VisionAnalysis.self, from: Fixtures.data("vision_analysis"))
        XCTAssertEqual(vision.category, .playgroundEquipment)
        XCTAssertEqual(vision.hazards.count, 2)
        XCTAssertEqual(vision.hazards[0].kind, .sharpEdge)
        // Model boxes arrive on the 0-1000 grid and are normalized (and clamped) on decode.
        assertBox(vision.hazards[0].box, NormalizedBox(x: 0.41, y: 0.52, w: 0.12, h: 0.1))
        assertBox(vision.hazards[1].box, NormalizedBox(x: 0.35, y: 0.6, w: 0.25, h: 0.4))
        XCTAssertTrue(vision.childUseEquipment)
        XCTAssertFalse(vision.childPresent)
        XCTAssertEqual(vision.sceneType, .playground)
        XCTAssertEqual(vision.severityProposal, .high)
        XCTAssertFalse(vision.plausibility.looksLikeScreenOrPrint)
        XCTAssertEqual(vision.suggestedQuestions, ["Are children using it right now?", "Is anyone hurt?"],
                       "trimmed to maxSuggestedQuestions")
        XCTAssertEqual(vision.confidence, .high)
    }

    func testHazardArabicLabelDecodesAndFallsBackToEnglish() throws {
        let vision = try JSONDecoder().decode(VisionAnalysis.self, from: Fixtures.data("vision_analysis"))
        XCTAssertEqual(vision.hazards[0].labelAR, "عمود معدني حاد مكشوف")
        XCTAssertEqual(vision.hazards[0].label(arabic: true), "عمود معدني حاد مكشوف")
        XCTAssertEqual(vision.hazards[0].label(arabic: false), "exposed sharp metal post")
        // Older responses have no label_ar: Arabic UI falls back to the English label.
        XCTAssertNil(vision.hazards[1].labelAR)
        XCTAssertEqual(vision.hazards[1].label(arabic: true), "unstable spring base")
    }

    func testHazardBlankArabicLabelFallsBackAndRoundTrips() throws {
        let blank = Hazard(label: "Pothole", labelAR: "  ", kind: .trip, box: NormalizedBox(x: 0.1, y: 0.1, w: 0.2, h: 0.2))
        XCTAssertEqual(blank.label(arabic: true), "Pothole")
        let hazard = Hazard(label: "Pothole", labelAR: "حفرة", kind: .trip, box: NormalizedBox(x: 0.1, y: 0.1, w: 0.2, h: 0.2))
        let encoded = try JSONEncoder().encode(hazard)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["label_ar"] as? String, "حفرة")
        XCTAssertEqual(try JSONDecoder().decode(Hazard.self, from: encoded), hazard)
    }

    func testVisionAnalysisRoundTripsWithSnakeCaseKeys() throws {
        let original = try JSONDecoder().decode(VisionAnalysis.self, from: Fixtures.data("vision_analysis"))
        let encoded = try JSONEncoder().encode(original)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNotNil(object["child_use_equipment"])
        XCTAssertNotNil(object["severity_proposal"])
        XCTAssertEqual(try JSONDecoder().decode(VisionAnalysis.self, from: encoded), original)
    }

    func testStoredBoxShapeReloadsUnchangedAndClamps() throws {
        let stored = NormalizedBox(x: 0.41, y: 0.52, w: 0.12, h: 0.1)
        let encoded = try JSONEncoder().encode(stored)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Double])
        XCTAssertEqual(Set(object.keys), ["x", "y", "w", "h"])
        XCTAssertEqual(try JSONDecoder().decode(NormalizedBox.self, from: encoded), stored)

        let outOfRange = Data(#"{"x":-0.2,"y":0.9,"w":0.5,"h":0.5}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(NormalizedBox.self, from: outOfRange),
                       NormalizedBox(x: 0, y: 0.9, w: 0.5, h: 0.09999999999999998))

        let swapped = Data(#"{"x_min":800,"y_min":900,"x_max":200,"y_max":-5}"#.utf8)
        assertBox(try JSONDecoder().decode(NormalizedBox.self, from: swapped), NormalizedBox(x: 0.2, y: 0, w: 0.6, h: 0.9))
    }

    func testVisionKeysMatchPromptsSchemaRequiredList() throws {
        let prompts = try Fixtures.prompts()
        let schema = try XCTUnwrap(prompts.visionAnalyze.jsonSchema).schema
        guard case .array(let required)? = schema["required"] else { return XCTFail("no required list") }
        let requiredKeys = Set(required.compactMap(\.stringValue))
        let encoded = try JSONEncoder().encode(makeVision())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(object.keys), requiredKeys)
    }

    func testEnumsMatchPromptsSchema() throws {
        let prompts = try Fixtures.prompts()
        let schema = try XCTUnwrap(prompts.visionAnalyze.jsonSchema).schema
        func enumValues(_ node: JSONValue?) -> Set<String> {
            guard case .array(let values)? = node?["enum"] else { return [] }
            return Set(values.compactMap(\.stringValue))
        }
        let properties = schema["properties"]
        XCTAssertEqual(enumValues(properties?["category"]), Set(ReportCategory.allCases.map(\.rawValue)))
        XCTAssertEqual(enumValues(properties?["scene_type"]), Set(SceneType.allCases.map(\.rawValue)))
        XCTAssertEqual(enumValues(properties?["severity_proposal"]), Set(Severity.allCases.map(\.rawValue)))
        XCTAssertEqual(enumValues(properties?["hazards"]?["items"]?["properties"]?["kind"]),
                       Set(HazardKind.allCases.map(\.rawValue)))
        XCTAssertEqual(prompts.categories, ReportCategory.allCases)
    }

    func testRejectsUnknownCategory() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Fixtures.data("vision_analysis")) as? [String: Any])
        object["category"] = "spaceship"
        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(VisionAnalysis.self, from: data))
    }

    func testDecodesFixVerificationFixture() throws {
        let fix = try JSONDecoder().decode(FixVerification.self, from: Fixtures.data("fix_verification"))
        XCTAssertFalse(fix.resolved)
        XCTAssertTrue(fix.sameLocationLikely)
        XCTAssertEqual(fix.remainingIssues.first?.box.w ?? 0, 0.14, accuracy: 1e-9)
        XCTAssertFalse(fix.reasonAR.isEmpty)
    }

    func testDecodesSameIssueFixture() throws {
        let verdict = try JSONDecoder().decode(SameIssueVerdict.self, from: Fixtures.data("same_issue_check"))
        XCTAssertTrue(verdict.sameIssue)
        XCTAssertTrue(verdict.reason.contains("spring rider"))
    }

    func testDecodesSubmitReportArgsFixture() throws {
        let args = try JSONDecoder().decode(SubmitReportArgs.self, from: Fixtures.data("submit_report_args"))
        XCTAssertEqual(args.answers["children_using_now"], "yes, two kids")
        XCTAssertEqual(args.userLanguage, "ar-khaleeji")
        XCTAssertTrue(args.wantsToPost)
        XCTAssertFalse(args.anonymous)
    }

    func testSeverityIsOrdered() {
        XCTAssertLessThan(Severity.low, .medium)
        XCTAssertLessThan(Severity.medium, .high)
        XCTAssertLessThan(Severity.high, .critical)
        XCTAssertEqual([Severity.critical, .low, .high].max(), .critical)
    }

    private func assertBox(_ actual: NormalizedBox, _ expected: NormalizedBox,
                           file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.x, expected.x, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(actual.w, expected.w, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(actual.h, expected.h, accuracy: 1e-9, file: file, line: line)
    }
}
