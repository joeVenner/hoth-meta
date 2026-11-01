import XCTest
@testable import HoTHCore

/// Function tools over the Responses API. Shapes are doc-derived (dev.meta.ai/docs/tool-calling,
/// /docs/protocols/responses), not recorded from the live API.
final class ToolCallingTests: XCTestCase {
    private let testKey = "LLM_000000_test-secret-123456789"

    private struct Answer: Decodable, Equatable {
        let reply: String
    }

    private let schema = JSONSchemaSpec(name: "answer", strict: true, schema: .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "required": .array([.string("reply")]),
        "properties": .object(["reply": .object(["type": .string("string")])])
    ]))

    private let tools = [
        FunctionTool(name: "find_nearby_reports", description: "Open reports nearby.", parameters: .object([
            "type": .string("object"),
            "properties": .object(["radius_m": .object(["type": .string("integer")])]),
            "required": .array([.string("radius_m")]),
            "additionalProperties": .bool(false)
        ])),
        FunctionTool(name: "get_place_context", description: "Places nearby.",
                     parameters: .object(["type": .string("object"), "properties": .object([:])]))
    ]

    override func setUp() {
        super.setUp()
        StubURLProtocol.handler = nil
        StubURLProtocol.captured = []
    }

    private func makeClient() -> MetaModelClient {
        MetaModelClient(keyProvider: StaticKey(key: testKey), session: StubURLProtocol.makeSession(),
                        baseURL: URL(string: "https://stub.invalid/v1")!)
    }

    // MARK: Envelopes

    /// reasoning (encrypted) + commentary + one function_call per (id, name, args).
    private func callsEnvelope(_ calls: [(String, String, String)], commentary: String? = "Let me check.") -> Data {
        var output: [JSONValue] = [
            .object(["id": .string("rs_1"), "type": .string("reasoning"), "summary": .array([]),
                     "encrypted_content": .string("enc-abc")])
        ]
        if let commentary {
            output.append(.object([
                "id": .string("msg_c"), "type": .string("message"), "role": .string("assistant"),
                "phase": .string("commentary"), "status": .string("completed"),
                "content": .array([.object(["type": .string("output_text"), "text": .string(commentary)])])
            ]))
        }
        for (callID, name, arguments) in calls {
            output.append(.object([
                "id": .string("fc_\(callID)"), "type": .string("function_call"), "status": .string("completed"),
                "call_id": .string(callID), "name": .string(name), "arguments": .string(arguments)
            ]))
        }
        let root: JSONValue = .object(["id": .string("resp_1"), "status": .string("completed"), "output": .array(output)])
        return try! JSONEncoder().encode(root)
    }

    private func finalEnvelope(_ payload: String) throws -> Data {
        try Fixtures.responsesEnvelope(payload: Data(payload.utf8))
    }

    private func body(_ index: Int) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: StubURLProtocol.captured[index].body)
    }

    private func inputItems(_ index: Int) throws -> [JSONValue] {
        guard case .array(let items)? = try body(index)["input"] else {
            XCTFail("no input array")
            return []
        }
        return items
    }

    // MARK: respond

    func testRequestShapeIsStatelessWithFlatToolsAndSchema() async throws {
        let final = try finalEnvelope(#"{"reply":"hi"}"#)
        StubURLProtocol.handler = { _ in (200, final) }

        let response = try await makeClient().respond(
            model: "muse-spark-1.3", input: [MetaModelClient.messageItem(role: "user", text: "hello")],
            tools: tools, schema: schema)
        XCTAssertEqual(response.outputText, #"{"reply":"hi"}"#)
        XCTAssertTrue(response.functionCalls.isEmpty)

        let sent = try body(0)
        XCTAssertEqual(StubURLProtocol.captured[0].request.url?.path, "/v1/responses")
        XCTAssertEqual(sent["store"], .bool(false))
        XCTAssertEqual(sent["include"], .array([.string("reasoning.encrypted_content")]))
        XCTAssertNil(sent["previous_response_id"], "cannot be combined with encrypted replay")
        XCTAssertNil(sent["tool_choice"], "only the default 'auto' is accepted")
        XCTAssertEqual(sent["reasoning"]?["effort"], .string("low"))
        XCTAssertEqual(sent["text"]?["format"]?["type"], .string("json_schema"))
        XCTAssertEqual(sent["text"]?["format"]?["name"], .string("answer"))
        guard case .array(let sentTools)? = sent["tools"] else { return XCTFail("no tools") }
        XCTAssertEqual(sentTools.count, 2)
        XCTAssertEqual(sentTools[0]["type"], .string("function"))
        XCTAssertEqual(sentTools[0]["name"], .string("find_nearby_reports"), "flat, not nested under 'function'")
        XCTAssertNil(sentTools[0]["function"])
        XCTAssertNil(sentTools[0]["strict"])
        XCTAssertEqual(sentTools[0]["parameters"]?["required"], .array([.string("radius_m")]))
    }

    func testNoToolsOmitsToolsField() async throws {
        let final = try finalEnvelope(#"{"reply":"hi"}"#)
        StubURLProtocol.handler = { _ in (200, final) }
        _ = try await makeClient().respond(model: "m", input: [], tools: [], schema: nil)
        XCTAssertNil(try body(0)["tools"])
        XCTAssertNil(try body(0)["text"])
    }

    func testFunctionCallsParseAndCommentaryIsNotFinalText() async throws {
        let envelope = callsEnvelope([("call_1", "find_nearby_reports", #"{"radius_m":100}"#),
                                      ("call_2", "get_place_context", "{}")])
        StubURLProtocol.handler = { _ in (200, envelope) }
        let response = try await makeClient().respond(model: "m", input: [], tools: tools, schema: schema)
        XCTAssertNil(response.outputText)
        XCTAssertEqual(response.functionCalls, [
            FunctionCall(callID: "call_1", name: "find_nearby_reports", arguments: #"{"radius_m":100}"#),
            FunctionCall(callID: "call_2", name: "get_place_context", arguments: "{}")
        ])
        XCTAssertEqual(response.functionCalls[0].argumentsObject?["radius_m"], .number(100))
        XCTAssertEqual(response.outputItems.count, 4)
    }

    func testMalformedArgumentsGiveNilObject() {
        XCTAssertNil(FunctionCall(callID: "c", name: "n", arguments: "{radius").argumentsObject)
        XCTAssertNil(FunctionCall(callID: "c", name: "n", arguments: "[1]").argumentsObject)
    }

    func testFunctionCallWithoutCallIDIsDecodingError() async throws {
        let bad = Data(#"{"status":"completed","output":[{"type":"function_call","name":"x","arguments":"{}"}]}"#.utf8)
        StubURLProtocol.handler = { _ in (200, bad) }
        do {
            _ = try await makeClient().respond(model: "m", input: [], tools: tools, schema: schema)
            XCTFail("expected decoding error")
        } catch let error as ModelAPIError {
            guard case .decoding = error else { return XCTFail("got \(error)") }
        }
    }

    // MARK: ToolLoop

    func testLoopPairsEveryCallAndReplaysOutputThenDecodesFinal() async throws {
        let first = callsEnvelope([("call_1", "find_nearby_reports", #"{"radius_m":100}"#),
                                   ("call_2", "get_place_context", "{}")])
        let final = try finalEnvelope(#"{"reply":"A neighbour already reported this."}"#)
        var count = 0
        StubURLProtocol.handler = { _ in
            count += 1
            return (200, count == 1 ? first : final)
        }
        var executed: [String] = []
        let outcome: ToolLoop.Outcome<Answer> = try await ToolLoop.run(
            client: makeClient(), model: "muse-spark-1.3", system: "sys", user: "Resident: hi",
            tools: tools, schema: schema
        ) { call in
            executed.append(call.name)
            return call.name == "find_nearby_reports" ? #"{"reports":[{"id":"r1"}]}"# : #"{"places":[]}"#
        }

        guard case .final(let answer, let rounds, let calls) = outcome else { return XCTFail("no final") }
        XCTAssertEqual(answer, Answer(reply: "A neighbour already reported this."))
        XCTAssertEqual(rounds, 1)
        XCTAssertEqual(executed, ["find_nearby_reports", "get_place_context"])
        XCTAssertEqual(calls.map(\.output), [#"{"reports":[{"id":"r1"}]}"#, #"{"places":[]}"#])
        XCTAssertEqual(StubURLProtocol.captured.count, 2)

        // Round 2 resends system + user, the round-1 output verbatim (reasoning, commentary, calls), then
        // one function_call_output per call, in call order.
        let items = try inputItems(1)
        XCTAssertEqual(items.count, 2 + 4 + 2)
        XCTAssertEqual(items[0]["role"], .string("system"))
        XCTAssertEqual(items[1]["role"], .string("user"))
        XCTAssertEqual(items[2]["type"], .string("reasoning"))
        XCTAssertEqual(items[2]["encrypted_content"], .string("enc-abc"))
        XCTAssertEqual(items[3]["phase"], .string("commentary"))
        XCTAssertEqual(items[4]["type"], .string("function_call"))
        XCTAssertEqual(items[5]["type"], .string("function_call"))
        XCTAssertEqual(items[6]["type"], .string("function_call_output"))
        XCTAssertEqual(items[6]["call_id"], .string("call_1"))
        XCTAssertEqual(items[6]["output"], .string(#"{"reports":[{"id":"r1"}]}"#))
        XCTAssertEqual(items[7]["call_id"], .string("call_2"))
        XCTAssertNotNil(try body(1)["tools"], "tools are per request and must be resent")
        XCTAssertNotNil(try body(1)["text"])
    }

    func testLoopAnswersStraightAwayWithZeroRounds() async throws {
        let final = try finalEnvelope(#"{"reply":"ok"}"#)
        StubURLProtocol.handler = { _ in (200, final) }
        var executed = 0
        let outcome: ToolLoop.Outcome<Answer> = try await ToolLoop.run(
            client: makeClient(), model: "m", system: "s", user: "u", tools: tools, schema: schema
        ) { _ in
            executed += 1
            return "{}"
        }
        guard case .final(_, let rounds, let calls) = outcome else { return XCTFail("no final") }
        XCTAssertEqual(rounds, 0)
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(executed, 0)
    }

    func testLoopStopsAtRoundLimit() async throws {
        let envelope = callsEnvelope([("call_x", "get_place_context", "{}")], commentary: nil)
        StubURLProtocol.handler = { _ in (200, envelope) }
        let outcome: ToolLoop.Outcome<Answer> = try await ToolLoop.run(
            client: makeClient(), model: "m", system: "s", user: "u", tools: tools, schema: schema, maxRounds: 2
        ) { _ in "{}" }
        guard case .roundLimit(let calls) = outcome else { return XCTFail("expected round limit") }
        XCTAssertEqual(calls.count, 2, "two rounds executed")
        XCTAssertEqual(StubURLProtocol.captured.count, 3, "maxRounds + 1 requests, never more")
    }

    func testLoopFinalNotMatchingSchemaIsDecodingError() async throws {
        let final = try finalEnvelope(#"{"nope":1}"#)
        StubURLProtocol.handler = { _ in (200, final) }
        do {
            let _: ToolLoop.Outcome<Answer> = try await ToolLoop.run(
                client: makeClient(), model: "m", system: "s", user: "u", tools: tools, schema: schema
            ) { _ in "{}" }
            XCTFail("expected decoding error")
        } catch let error as ModelAPIError {
            guard case .decoding = error else { return XCTFail("got \(error)") }
        }
    }

    func testLoopSurfacesHTTPErrors() async throws {
        StubURLProtocol.handler = { _ in (400, Data(#"{"error":{"message":"bad tools"}}"#.utf8)) }
        do {
            let _: ToolLoop.Outcome<Answer> = try await ToolLoop.run(
                client: makeClient(), model: "m", system: "s", user: "u", tools: tools, schema: schema
            ) { _ in "{}" }
            XCTFail("expected HTTP error")
        } catch let error as ModelAPIError {
            XCTAssertEqual(error, .http(400, "bad tools"))
        }
    }
}
