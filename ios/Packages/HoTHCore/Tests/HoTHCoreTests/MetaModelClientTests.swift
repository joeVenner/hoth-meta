import XCTest
@testable import HoTHCore

final class MetaModelClientTests: XCTestCase {
    private let testKey = "LLM_000000_test-secret-123456789"

    override func setUp() {
        super.setUp()
        StubURLProtocol.handler = nil
        StubURLProtocol.captured = []
        StubURLProtocol.failure = nil
    }

    override func tearDown() {
        StubURLProtocol.failure = nil
        super.tearDown()
    }

    private func makeClient(key: APIKeyProvider? = nil) -> MetaModelClient {
        MetaModelClient(keyProvider: key ?? StaticKey(key: testKey), session: StubURLProtocol.makeSession(),
                     baseURL: URL(string: "https://stub.invalid/v1")!)
    }

    func testVisionAnalyzerUsesModelOverrideWhenSet() async throws {
        let envelope = try Fixtures.responsesEnvelope(payload: Fixtures.data("vision_analysis"))
        StubURLProtocol.handler = { _ in (200, envelope) }
        let analyzer = VisionAnalyzer(client: makeClient(), prompts: try Fixtures.prompts(), model: " muse-test-override ")
        _ = try await analyzer.analyze(imageData: Data([0xFF, 0xD8, 0xFF]), language: "en")
        let captured = try XCTUnwrap(StubURLProtocol.captured.first)
        let body = try JSONDecoder().decode(JSONValue.self, from: captured.body)
        XCTAssertEqual(body["model"], .string("muse-test-override"))
    }

    func testBlankModelOverrideFallsBackToPrompts() throws {
        let prompts = try Fixtures.prompts()
        XCTAssertEqual(VisionAnalyzer(client: makeClient(), prompts: prompts, model: "  ").model, prompts.models.vision)
        XCTAssertEqual(DuplicateJudge(client: makeClient(), prompts: prompts, model: nil).model, prompts.models.vision)
        XCTAssertEqual(FixVerifier(client: makeClient(), prompts: prompts, model: "muse-x").model, "muse-x")
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
        XCTAssertEqual(captured.request.timeoutInterval, 60)
        XCTAssertEqual(captured.request.url?.host, "stub.invalid")

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
        XCTAssertNil(image["detail"], "Meta documents no image detail parameter")
        XCTAssertEqual(body["reasoning"]?["effort"], .string("low"))
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
            (401, Data(#"{"error":{"message":"Incorrect API key provided: LLM_000000_test-secret-123456789."}}"#.utf8))
        }
        do {
            let _: SameIssueVerdict = try await makeClient().structured(
                model: "m", system: "s", user: "u", schema: try Fixtures.prompts().sameIssue.jsonSchema!)
            XCTFail("expected error")
        } catch let error as ModelAPIError {
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
            (500, Data(#"{"error":{"message":"boom for LLM_000000_test-secret-123456789 and LLM_42_other"}}"#.utf8))
        }
        do {
            let _: SameIssueVerdict = try await makeClient().structured(
                model: "m", system: "s", user: "u", schema: try Fixtures.prompts().sameIssue.jsonSchema!)
            XCTFail("expected error")
        } catch let error as ModelAPIError {
            guard case .http(let code, let message) = error else { return XCTFail("wrong error \(error)") }
            XCTAssertEqual(code, 500)
            XCTAssertFalse(message.contains(testKey))
            XCTAssertFalse(message.contains("LLM_42_other"))
            XCTAssertTrue(message.contains("LLM_***"))
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
        } catch let error as ModelAPIError {
            XCTAssertEqual(error, .missingKey)
            XCTAssertTrue(StubURLProtocol.captured.isEmpty)
        }
    }

    func testDefaultsTargetMetaModelAPI() {
        let client = MetaModelClient(keyProvider: StaticKey(key: testKey))
        XCTAssertEqual(client.baseURL.absoluteString, "https://api.meta.ai/v1")
        XCTAssertEqual(client.timeout, 60)
        XCTAssertEqual(client.reasoningEffort, "low")
    }

    func testReasoningEffortIsConfigurableAndOmittable() async throws {
        let envelope = try Fixtures.responsesEnvelope(payload: Fixtures.data("same_issue_check"))
        StubURLProtocol.handler = { _ in (200, envelope) }
        let schema = try XCTUnwrap(try Fixtures.prompts().sameIssue.jsonSchema)

        let minimal = MetaModelClient(keyProvider: StaticKey(key: testKey), session: StubURLProtocol.makeSession(),
                                      baseURL: URL(string: "https://stub.invalid/v1")!, reasoningEffort: "minimal")
        let _: SameIssueVerdict = try await minimal.structured(model: "m", system: "s", user: "u", schema: schema)
        var body = try JSONDecoder().decode(JSONValue.self, from: StubURLProtocol.captured.last!.body)
        XCTAssertEqual(body["reasoning"]?["effort"], .string("minimal"))

        let omitted = MetaModelClient(keyProvider: StaticKey(key: testKey), session: StubURLProtocol.makeSession(),
                                      baseURL: URL(string: "https://stub.invalid/v1")!, reasoningEffort: nil)
        let _: SameIssueVerdict = try await omitted.structured(model: "m", system: "s", user: "u", schema: schema)
        body = try JSONDecoder().decode(JSONValue.self, from: StubURLProtocol.captured.last!.body)
        XCTAssertNil(body["reasoning"])
    }

    func testEmptyOutputIsDecodingErrorForStructured() async throws {
        let empty = #"{"status":"completed","output":[]}"#
        StubURLProtocol.handler = { _ in (200, Data(empty.utf8)) }
        await assertDecodingError()
    }

    func testCancelledRequestThrowsCancellationNotNetwork() async throws {
        StubURLProtocol.failure = URLError(.cancelled)
        do {
            let _: SameIssueVerdict = try await makeClient().structured(
                model: "m", system: "s", user: "u", schema: try Fixtures.prompts().sameIssue.jsonSchema!)
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
    }

    func testTimeoutStaysANetworkError() async throws {
        StubURLProtocol.failure = URLError(.timedOut)
        await assertThrows(.network(String(URLError.Code.timedOut.rawValue)))
    }

    func testCancellingTheCallingTaskThrowsCancellation() async throws {
        let envelope = try Fixtures.responsesEnvelope(payload: Fixtures.data("same_issue_check"))
        StubURLProtocol.handler = { _ in (200, envelope) }
        let client = makeClient()
        let schema = try XCTUnwrap(try Fixtures.prompts().sameIssue.jsonSchema)
        let task = Task {
            let _: SameIssueVerdict = try await client.structured(model: "m", system: "s", user: "u", schema: schema)
        }
        task.cancel()
        do {
            try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
    }

    func testTransportErrorMapping() {
        XCTAssertTrue(MetaModelClient.transportError(CancellationError(), isTaskCancelled: false) is CancellationError)
        XCTAssertTrue(MetaModelClient.transportError(URLError(.notConnectedToInternet), isTaskCancelled: true)
            is CancellationError)
        XCTAssertEqual(MetaModelClient.transportError(URLError(.notConnectedToInternet), isTaskCancelled: false)
            as? ModelAPIError, .network("-1009"))
    }

    func testSanitizerScrubsBearerAndLegacyTokens() {
        let body = Data(#"{"error":{"message":"bad Bearer abc.def-123 and sk-live-xyz"}}"#.utf8)
        let message = MetaModelClient.sanitizedErrorMessage(body)
        XCTAssertEqual(message, "bad Bearer *** and sk-***")
    }

    // MARK: Helpers

    private func assertThrows(_ expected: ModelAPIError, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            let _: SameIssueVerdict = try await makeClient().structured(
                model: "m", system: "s", user: "u", schema: try Fixtures.prompts().sameIssue.jsonSchema!)
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ModelAPIError, expected, file: file, line: line)
        }
    }

    private func assertDecodingError(file: StaticString = #filePath, line: UInt = #line) async {
        do {
            let _: SameIssueVerdict = try await makeClient().structured(
                model: "m", system: "s", user: "u", schema: try Fixtures.prompts().sameIssue.jsonSchema!)
            XCTFail("expected decoding error", file: file, line: line)
        } catch {
            guard case .decoding? = error as? ModelAPIError else {
                return XCTFail("wrong error \(error)", file: file, line: line)
            }
        }
    }
}
