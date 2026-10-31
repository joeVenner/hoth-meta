import XCTest
@testable import HoTHCore

final class OpenAIClientTests: XCTestCase {
    private let testKey = "sk-test-123456789"

    override func setUp() {
        super.setUp()
        StubURLProtocol.handler = nil
        StubURLProtocol.captured = []
    }

    private func makeClient(key: APIKeyProvider? = nil) -> OpenAIClient {
        OpenAIClient(keyProvider: key ?? StaticKey(key: testKey), session: StubURLProtocol.makeSession(),
                     baseURL: URL(string: "https://stub.invalid/v1")!)
    }

    func testVisionAnalyzerUsesModelOverrideWhenSet() async throws {
        let envelope = try Fixtures.responsesEnvelope(payload: Fixtures.data("vision_analysis"))
        StubURLProtocol.handler = { _ in (200, envelope) }
        let analyzer = VisionAnalyzer(client: makeClient(), prompts: try Fixtures.prompts(), model: " gpt-test-override ")
        _ = try await analyzer.analyze(imageData: Data([0xFF, 0xD8, 0xFF]), language: "en")
        let captured = try XCTUnwrap(StubURLProtocol.captured.first)
        let body = try JSONDecoder().decode(JSONValue.self, from: captured.body)
        XCTAssertEqual(body["model"], .string("gpt-test-override"))
    }

    func testBlankModelOverrideFallsBackToPrompts() throws {
        let prompts = try Fixtures.prompts()
        XCTAssertEqual(VisionAnalyzer(client: makeClient(), prompts: prompts, model: "  ").model, prompts.models.vision)
        XCTAssertEqual(DuplicateJudge(client: makeClient(), prompts: prompts, model: nil).model, prompts.models.vision)
        XCTAssertEqual(FixVerifier(client: makeClient(), prompts: prompts, model: "gpt-x").model, "gpt-x")
    }

    func testVisionAnalyzerSendsStrictSchemaAndDecodes() async throws {
        let envelope = try Fixtures.responsesEnvelope(payload: Fixtures.data("vision_analysis"))
        StubURLProtocol.handler = { _ in (200, envelope) }
        let analyzer = VisionAnalyzer(client: makeClient(), prompts: try Fixtures.prompts())

        let result = try await analyzer.analyze(imageData: Data([0xFF, 0xD8, 0xFF]), language: "ar-khaleeji")
        XCTAssertEqual(result.category, .playgroundEquipment)

        let captured = try XCTUnwrap(StubURLProtocol.captured.first)
        XCTAssertEqual(captured.request.url?.path, "/v1/responses")
        XCTAssertEqual(captured.request.httpMethod, "POST")
        XCTAssertEqual(captured.request.value(forHTTPHeaderField: "Authorization"), "Bearer \(testKey)")
        XCTAssertEqual(captured.request.timeoutInterval, 30)

        let body = try JSONDecoder().decode(JSONValue.self, from: captured.body)
        let format = body["text"]?["format"]
        XCTAssertEqual(format?["type"], .string("json_schema"))
        XCTAssertEqual(format?["strict"], .bool(true))
        XCTAssertEqual(format?["name"], .string("vision_analysis"))
        XCTAssertEqual(body["model"], .string(try Fixtures.prompts().models.vision))
        guard case .array(let input)? = body["input"], case .array(let userContent)? = input.last?["content"] else {
            return XCTFail("bad input shape")
        }
        let image = try XCTUnwrap(userContent.first { $0["type"] == .string("input_image") })
        XCTAssertTrue(image["image_url"]?.stringValue?.hasPrefix("data:image/jpeg;base64,") ?? false)
        guard case .array(let systemContent)? = input.first?["content"] else { return XCTFail("no system") }
        let systemText = systemContent.first?["text"]?.stringValue ?? ""
        XCTAssertFalse(systemText.contains("{{user_language}}"))
        XCTAssertTrue(systemText.contains("ar-khaleeji"))
    }

    func testFixVerifierAndDuplicateJudgeDecode() async throws {
        let prompts = try Fixtures.prompts()
        let fixEnvelope = try Fixtures.responsesEnvelope(payload: Fixtures.data("fix_verification"))
        StubURLProtocol.handler = { _ in (200, fixEnvelope) }
        let fix = try await FixVerifier(client: makeClient(), prompts: prompts).verify(
            before: Data([1]), after: Data([2]), reportTitle: "Spring rider", category: .playgroundEquipment,
            beforeCapturedAt: Date(), afterCapturedAt: Date())
        XCTAssertFalse(fix.resolved)

        let sameEnvelope = try Fixtures.responsesEnvelope(payload: Fixtures.data("same_issue_check"))
        StubURLProtocol.handler = { _ in (200, sameEnvelope) }
        let snapshot = ReportSnapshot(summary: "x", category: .potholePavement, capturedAt: Date(), jpegData: Data([3]))
        let verdict = try await DuplicateJudge(client: makeClient(), prompts: prompts)
            .judge(new: snapshot, existing: snapshot, distanceMeters: 12.4)
        XCTAssertTrue(verdict.sameIssue)
        let body = try JSONDecoder().decode(JSONValue.self, from: StubURLProtocol.captured.last!.body)
        guard case .array(let input)? = body["input"], case .array(let content)? = input.last?["content"] else {
            return XCTFail("bad input")
        }
        XCTAssertEqual(content.filter { $0["type"] == .string("input_image") }.count, 2)
        XCTAssertTrue(content.first?["text"]?.stringValue?.contains("about 12 m") ?? false)
    }

    func testStatus401MapsToInvalidKeyWithoutLeakingKey() async throws {
        StubURLProtocol.handler = { _ in
            (401, Data(#"{"error":{"message":"Incorrect API key provided: sk-test-123456789."}}"#.utf8))
        }
        do {
            let _: SameIssueVerdict = try await makeClient().structured(
                model: "m", system: "s", user: "u", schema: try Fixtures.prompts().sameIssue.jsonSchema!)
            XCTFail("expected error")
        } catch let error as OpenAIError {
            XCTAssertEqual(error, .invalidKey)
            XCTAssertFalse(String(describing: error).contains(testKey))
        }
    }

    func testStatus429MapsToRateLimited() async throws {
        StubURLProtocol.handler = { _ in (429, Data()) }
        await assertThrows(.rateLimited)
    }

    func testStatus500MapsToHTTPWithScrubbedMessage() async throws {
        StubURLProtocol.handler = { _ in
            (500, Data(#"{"error":{"message":"boom for sk-test-123456789"}}"#.utf8))
        }
        do {
            let _: SameIssueVerdict = try await makeClient().structured(
                model: "m", system: "s", user: "u", schema: try Fixtures.prompts().sameIssue.jsonSchema!)
            XCTFail("expected error")
        } catch let error as OpenAIError {
            guard case .http(let code, let message) = error else { return XCTFail("wrong error \(error)") }
            XCTAssertEqual(code, 500)
            XCTAssertFalse(message.contains(testKey))
            XCTAssertTrue(message.contains("sk-***"))
        }
    }

    func testGarbageBodyMapsToDecoding() async throws {
        StubURLProtocol.handler = { _ in (200, Data("not json".utf8)) }
        await assertDecodingError()
    }

    func testOutputNotMatchingSchemaMapsToDecoding() async throws {
        let envelope = try Fixtures.responsesEnvelope(payload: Data(#"{"unexpected":1}"#.utf8))
        StubURLProtocol.handler = { _ in (200, envelope) }
        await assertDecodingError()
    }

    func testRefusalAndIncompleteAreTyped() async throws {
        let refusal = #"{"status":"completed","output":[{"type":"message","content":[{"type":"refusal","refusal":"no"}]}]}"#
        StubURLProtocol.handler = { _ in (200, Data(refusal.utf8)) }
        await assertThrows(.refused("no"))

        let incomplete = #"{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[]}"#
        StubURLProtocol.handler = { _ in (200, Data(incomplete.utf8)) }
        await assertThrows(.incomplete("max_output_tokens"))
    }

    func testMissingKeyFailsBeforeNetwork() async throws {
        do {
            let _: SameIssueVerdict = try await makeClient(key: FailingKey()).structured(
                model: "m", system: "s", user: "u", schema: try Fixtures.prompts().sameIssue.jsonSchema!)
            XCTFail("expected error")
        } catch let error as OpenAIError {
            XCTAssertEqual(error, .missingKey)
            XCTAssertTrue(StubURLProtocol.captured.isEmpty)
        }
    }

    func testRealtimeClientSecretTopLevelShape() async throws {
        StubURLProtocol.handler = { _ in (200, Data(#"{"value":"ek_test_abc","expires_at":1760000000}"#.utf8)) }
        let tools = try Fixtures.prompts().realtimeTools
        let secret = try await makeClient().createRealtimeClientSecret(
            model: "gpt-realtime-2.1", instructions: "hi", tools: tools, voice: "marin")
        XCTAssertEqual(secret.value, "ek_test_abc")
        XCTAssertEqual(secret.expiresAt, Date(timeIntervalSince1970: 1_760_000_000))

        let captured = try XCTUnwrap(StubURLProtocol.captured.first)
        XCTAssertEqual(captured.request.url?.path, "/v1/realtime/client_secrets")
        let body = try JSONDecoder().decode(JSONValue.self, from: captured.body)
        XCTAssertEqual(body["session"]?["type"], .string("realtime"))
        XCTAssertEqual(body["session"]?["model"], .string("gpt-realtime-2.1"))
        XCTAssertEqual(body["session"]?["audio"]?["output"]?["voice"], .string("marin"))
        guard case .array(let sentTools)? = body["session"]?["tools"] else { return XCTFail("no tools") }
        XCTAssertEqual(sentTools, tools)
    }

    func testRealtimeClientSecretNestedShape() async throws {
        StubURLProtocol.handler = { _ in
            (200, Data(#"{"client_secret":{"value":"ek_nested","expires_at":1760000100}}"#.utf8))
        }
        let secret = try await makeClient().createRealtimeClientSecret(model: "m", instructions: "", tools: [])
        XCTAssertEqual(secret.value, "ek_nested")
    }

    func testRealtimeClientSecretMissingValueIsDecodingError() {
        XCTAssertThrowsError(try OpenAIClient.parseClientSecret(Data(#"{"foo":1}"#.utf8))) { error in
            guard case .decoding? = error as? OpenAIError else { return XCTFail("wrong error") }
        }
    }

    // MARK: Helpers

    private func assertThrows(_ expected: OpenAIError, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            let _: SameIssueVerdict = try await makeClient().structured(
                model: "m", system: "s", user: "u", schema: try Fixtures.prompts().sameIssue.jsonSchema!)
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? OpenAIError, expected, file: file, line: line)
        }
    }

    private func assertDecodingError(file: StaticString = #filePath, line: UInt = #line) async {
        do {
            let _: SameIssueVerdict = try await makeClient().structured(
                model: "m", system: "s", user: "u", schema: try Fixtures.prompts().sameIssue.jsonSchema!)
            XCTFail("expected decoding error", file: file, line: line)
        } catch {
            guard case .decoding? = error as? OpenAIError else {
                return XCTFail("wrong error \(error)", file: file, line: line)
            }
        }
    }
}
