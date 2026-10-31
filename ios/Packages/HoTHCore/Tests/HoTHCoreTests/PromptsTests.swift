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
        XCTAssertEqual(prompts.realtimeTools.count, 2)
        XCTAssertEqual(prompts.slots(for: .playgroundEquipment).first?.id, "children_using_now")
        XCTAssertEqual(prompts.slots(for: .openManhole).first?.urgentIf, "always")
        XCTAssertTrue(prompts.slots(for: .notAnIssue).isEmpty)
    }

    func testSchemaNumbersSurviveRoundTrip() throws {
        // minimum/maximum 0/1 must stay numbers, never become booleans, when forwarded to the API.
        let prompts = try Fixtures.prompts()
        let schema = try XCTUnwrap(prompts.visionAnalyze.jsonSchema).schema
        let encoded = try JSONEncoder().encode(schema)
        let reparsed = try JSONDecoder().decode(JSONValue.self, from: encoded)
        let xNode = reparsed["properties"]?["hazards"]?["items"]?["properties"]?["box"]?["properties"]?["x"]
        XCTAssertEqual(xNode?["maximum"], .number(1))
        XCTAssertEqual(xNode?["minimum"], .number(0))
        XCTAssertEqual(reparsed["additionalProperties"], .bool(false))
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
