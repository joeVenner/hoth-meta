import XCTest
@testable import HoTHCore

final class PromptsTests: XCTestCase {
    func testDecodesAppPromptsFile() throws {
        let prompts = try Fixtures.prompts()
        XCTAssertEqual(prompts.version, 1)
        XCTAssertFalse(prompts.models.vision.isEmpty)
        XCTAssertEqual(prompts.visionAnalyze.jsonSchema?.name, "vision_analysis")
        XCTAssertEqual(prompts.fixVerify.jsonSchema?.name, "fix_verification")
        XCTAssertEqual(prompts.sameIssue.jsonSchema?.name, "same_issue_check")
        XCTAssertEqual(prompts.visionAnalyze.jsonSchema?.strict, true)
        XCTAssertNil(prompts.chatIntake.jsonSchema)
        XCTAssertEqual(prompts.models, ModelIDs(vision: "muse-spark-1.3", text: "muse-spark-1.3",
                                                transcribe: "muse-voice-transcribe-1.0", segment: "sam-3.1"))
        XCTAssertEqual(prompts.slots(for: .playgroundEquipment).first?.id, "children_using_now")
        XCTAssertEqual(prompts.slots(for: .openManhole).first?.urgentIf, "always")
        XCTAssertTrue(prompts.slots(for: .notAnIssue).isEmpty)
    }

    func testSchemasUseGridBoxesAndAvoidRangeKeywords() throws {
        // Meta's strict subset doesn't promise numeric/array limits, so prompts.json carries none; the
        // app clamps instead. Boxes are integer corners on Muse Spark's 0-1000 grid.
        let prompts = try Fixtures.prompts()
        let specs = [prompts.visionAnalyze, prompts.fixVerify, prompts.sameIssue, prompts.moderation]
        for spec in specs {
            let encoded = try JSONEncoder().encode(try XCTUnwrap(spec.jsonSchema).schema)
            let text = String(decoding: encoded, as: UTF8.self)
            for keyword in ["minimum", "maximum", "maxItems", "minItems", "oneOf", "allOf"] {
                XCTAssertFalse(text.contains("\"\(keyword)\""), "\(keyword) in \(spec.jsonSchema?.name ?? "?")")
            }
        }
        let schema = try XCTUnwrap(prompts.visionAnalyze.jsonSchema).schema
        let box = schema["properties"]?["hazards"]?["items"]?["properties"]?["box"]
        XCTAssertEqual(box?["required"], .array(["x_min", "y_min", "x_max", "y_max"].map(JSONValue.string)))
        XCTAssertEqual(box?["properties"]?["x_min"]?["type"], .string("integer"))
        XCTAssertEqual(box?["additionalProperties"], .bool(false))
        XCTAssertTrue(prompts.visionAnalyze.system.contains("0-1000 grid"))
        XCTAssertTrue(prompts.fixVerify.system.contains("0-1000 grid"))
    }

    func testTextModelOverrideResolves() throws {
        let prompts = try Fixtures.prompts()
        XCTAssertEqual(Prompts.resolveTextModel(override: " ", prompts: prompts), prompts.models.text)
        XCTAssertEqual(Prompts.resolveTextModel(override: " muse-x ", prompts: prompts), "muse-x")
    }

    func testFillReplacesPlaceholdersAndKeepsUnknown() {
        let filled = Prompts.fill("Hi {{user_language}} {{user_language}} {{other}}", ["user_language": "en"])
        XCTAssertEqual(filled, "Hi en en {{other}}")
    }

    func testBundleWithoutPromptsThrows() {
        XCTAssertThrowsError(try Prompts(bundle: Bundle.module, resource: "does_not_exist")) { error in
            XCTAssertEqual(error as? PromptsError, .resourceNotFound("does_not_exist.json"))
        }
    }

    func testInvalidDataThrowsDecoding() {
        XCTAssertThrowsError(try Prompts(data: Data("{}".utf8))) { error in
            guard case .decoding? = error as? PromptsError else { return XCTFail("wrong error \(error)") }
        }
    }
}
