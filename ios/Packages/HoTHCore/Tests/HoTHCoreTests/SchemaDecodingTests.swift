import XCTest
@testable import HoTHCore

final class SchemaDecodingTests: XCTestCase {
    func testDecodesVisionAnalysisFixture() throws {
        let vision = try JSONDecoder().decode(VisionAnalysis.self, from: Fixtures.data("vision_analysis"))
        XCTAssertEqual(vision.category, .playgroundEquipment)
        XCTAssertEqual(vision.hazards.count, 2)
        XCTAssertEqual(vision.hazards[0].kind, .sharpEdge)
        XCTAssertEqual(vision.hazards[0].box, NormalizedBox(x: 0.41, y: 0.52, w: 0.12, h: 0.1))
        XCTAssertTrue(vision.childUseEquipment)
        XCTAssertFalse(vision.childPresent)
        XCTAssertEqual(vision.sceneType, .playground)
        XCTAssertEqual(vision.severityProposal, .high)
        XCTAssertFalse(vision.plausibility.looksLikeScreenOrPrint)
        XCTAssertEqual(vision.suggestedQuestions.count, 1)
        XCTAssertEqual(vision.confidence, .high)
    }

    func testVisionAnalysisRoundTripsWithSnakeCaseKeys() throws {
        let original = try JSONDecoder().decode(VisionAnalysis.self, from: Fixtures.data("vision_analysis"))
        let encoded = try JSONEncoder().encode(original)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNotNil(object["child_use_equipment"])
        XCTAssertNotNil(object["severity_proposal"])
        XCTAssertEqual(try JSONDecoder().decode(VisionAnalysis.self, from: encoded), original)
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
        XCTAssertEqual(fix.remainingIssues.first?.box.w, 0.14)
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
}
