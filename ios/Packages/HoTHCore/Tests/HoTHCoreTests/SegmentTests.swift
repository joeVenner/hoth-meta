import XCTest
@testable import HoTHCore

/// SAM 3.1 segmentation. Fixtures are doc-derived (`*_doc.json`, dev.meta.ai/docs/sam/reading-segmentation),
/// not recorded from the live API.
final class SegmentTests: XCTestCase {
    private let testKey = "LLM_000000_test-secret-123456789"

    override func setUp() {
        super.setUp()
        StubURLProtocol.handler = nil
        StubURLProtocol.captured = []
    }

    private func makeClient() -> MetaModelClient {
        MetaModelClient(keyProvider: StaticKey(key: testKey), session: StubURLProtocol.makeSession(),
                        baseURL: URL(string: "https://stub.invalid/v1")!)
    }

    func testSegmentSendsConceptAndImageAndParsesBoxes() async throws {
        let envelope = try Fixtures.data("sam_two_objects_doc")
        StubURLProtocol.handler = { _ in (200, envelope) }

        let instances = try await makeClient().segment(
            image: ImageInput(jpegData: Data([0xFF, 0xD8, 0xFF])), concept: "  button ", model: "sam-3.1")
        XCTAssertEqual(instances.count, 2)
        XCTAssertEqual(instances[0].objectId, 0)
        XCTAssertEqual(instances[0].box, PixelBox(x1: 211, y1: 228, x2: 270, y2: 254, sourceWidth: 320, sourceHeight: 334))
        XCTAssertEqual(instances[1].objectId, 1)
        XCTAssertEqual(instances[1].mask?.height, 27)
        XCTAssertEqual(instances[1].mask?.width, 48)
        XCTAssertEqual(instances[1].mask?.encoding, .lossless)
        XCTAssertNil(instances[0].score)

        let captured = try XCTUnwrap(StubURLProtocol.captured.first)
        XCTAssertEqual(captured.request.url?.path, "/v1/responses")
        XCTAssertEqual(captured.request.value(forHTTPHeaderField: "Authorization"), "Bearer \(testKey)")
        let body = try JSONDecoder().decode(JSONValue.self, from: captured.body)
        XCTAssertEqual(body["model"], .string("sam-3.1"))
        XCTAssertEqual(body["metadata"]?["include_confidence"], .string("true"))
        XCTAssertEqual(body["metadata"]?["mask_encoding"], .string("one_bit"))
        XCTAssertNil(body["text"], "SAM takes no structured-output format")
        XCTAssertNil(body["reasoning"], "SAM is not a reasoning model")
        XCTAssertNil(body["stream"])
        guard case .array(let input)? = body["input"], input.count == 1,
              case .array(let content)? = input[0]["content"] else { return XCTFail("bad input shape") }
        XCTAssertEqual(input[0]["type"], .string("message"))
        XCTAssertEqual(input[0]["role"], .string("user"))
        XCTAssertEqual(content.first?["text"], .string("button"))
        XCTAssertTrue(content.last?["image_url"]?.stringValue?.hasPrefix("data:image/jpeg;base64,") ?? false)
        XCTAssertNil(content.last?["detail"])
    }

    func testZeroMatchesIsEmptyNotAnError() async throws {
        let envelope = try Fixtures.data("sam_zero_matches_doc")
        StubURLProtocol.handler = { _ in (200, envelope) }
        let instances = try await makeClient().segment(
            image: ImageInput(jpegData: Data([1])), concept: "unicorn", model: "sam-3.1")
        XCTAssertTrue(instances.isEmpty)

        // No message item at all is also a completed, empty lane.
        StubURLProtocol.handler = { _ in (200, Data(#"{"status":"completed","output":[]}"#.utf8)) }
        let none = try await makeClient().segment(image: ImageInput(jpegData: Data([1])), concept: "x", model: "sam-3.1")
        XCTAssertTrue(none.isEmpty)
    }

    func testBlankConceptSkipsNetwork() async throws {
        let instances = try await makeClient().segment(image: ImageInput(jpegData: Data([1])), concept: " ", model: "sam-3.1")
        XCTAssertTrue(instances.isEmpty)
        XCTAssertTrue(StubURLProtocol.captured.isEmpty)
    }

    func testParsesConfidenceFromBoxAndOneBitMask() {
        let line = "<0f>1<|box;x1=444;y1=625;x2=679;y2=850;w=1800;h=1200;c=0.9609375|>"
            + "<|mask;x=0;y=0;c=0.9609375;data=226,236,!abc|>"
        let instances = SAMOutputParser.parse(line)
        XCTAssertEqual(instances.count, 1)
        XCTAssertEqual(instances[0].objectId, 1)
        XCTAssertEqual(instances[0].score, 0.9609375)
        XCTAssertEqual(instances[0].mask, SegmentMask(height: 226, width: 236, encoding: .oneBit, payload: "abc"))
    }

    func testMaskPayloadMayContainDelimiterCharacters() {
        // base85 payloads can contain `|`, `>`, `!` and `~`; only `|>` before the next record ends a mask.
        let line = "<0f>3<|box;x1=1;y1=2;x2=3;y2=4;w=10;h=10|><|mask;x=0;y=0;data=2,2,~a|b>c!~|>,7<|box;x1=5;y1=5;x2=9;y2=9;w=10;h=10|><|mask;x=0;y=0;data=1,1,!z|>"
        let instances = SAMOutputParser.parse(line)
        XCTAssertEqual(instances.map(\.objectId), [3, 7])
        XCTAssertEqual(instances[0].mask?.payload, "a|b>c!~")
        XCTAssertEqual(instances[0].mask?.encoding, .lossless)
        XCTAssertEqual(instances[1].mask?.payload, "z")
    }

    func testSparseIdsAndMultipleFrames() {
        let text = """
        <0f>0<|box;x1=0;y1=0;x2=5;y2=5;w=10;h=10|><|mask;x=0;y=0;data=1,1,~a|>,2<|box;x1=1;y1=1;x2=6;y2=6;w=10;h=10|><|mask;x=0;y=0;data=1,1,~b|>
        <2f>2<|box;x1=2;y1=2;x2=7;y2=7;w=10;h=10|><|mask;x=0;y=0;data=1,1,~c|>
        """
        let instances = SAMOutputParser.parse(text)
        XCTAssertEqual(instances.map(\.objectId), [0, 2, 2])
        XCTAssertEqual(instances.map(\.frame), [0, 0, 2])
    }

    func testBoxWithoutMaskStillParses() {
        let instances = SAMOutputParser.parse("<0f>4<|box;x1=10;y1=20;x2=30;y2=40;w=100;h=200|>")
        XCTAssertEqual(instances.count, 1)
        XCTAssertNil(instances[0].mask)
    }

    func testMalformedInputIsSkipped() {
        XCTAssertTrue(SAMOutputParser.parse("").isEmpty)
        XCTAssertTrue(SAMOutputParser.parse("no tokens here").isEmpty)
        XCTAssertTrue(SAMOutputParser.parse("0<|box;x1=1;y1=1;x2=2;y2=2;w=3;h=3|>").isEmpty, "missing frame marker")
        XCTAssertTrue(SAMOutputParser.parse("<0f>0<|box;x1=1;y1=1;x2=2;w=3;h=3|>").isEmpty, "missing y2")
        XCTAssertTrue(SAMOutputParser.parse("<0f>0<|box;x1=1;y1=1;x2=2;y2=2;w=0;h=3|>").isEmpty, "zero width")
        let badMask = SAMOutputParser.parse("<0f>0<|box;x1=1;y1=1;x2=2;y2=2;w=3;h=3|><|mask;x=0;y=0;data=oops|>")
        XCTAssertEqual(badMask.count, 1)
        XCTAssertNil(badMask[0].mask)
    }

    func testPixelBoxNormalizesAndClamps() {
        let box = PixelBox(x1: 211, y1: 228, x2: 270, y2: 254, sourceWidth: 320, sourceHeight: 334).normalized
        XCTAssertEqual(box.x, 211.0 / 320, accuracy: 1e-9)
        XCTAssertEqual(box.w, 59.0 / 320, accuracy: 1e-9)
        XCTAssertEqual(box.y, 228.0 / 334, accuracy: 1e-9)
        XCTAssertEqual(box.h, 26.0 / 334, accuracy: 1e-9)

        let edge = PixelBox(x1: 300, y1: -4, x2: 330, y2: 20, sourceWidth: 320, sourceHeight: 334).normalized
        XCTAssertEqual(edge.y, 0)
        XCTAssertEqual(edge.x + edge.w, 1, accuracy: 1e-9)
    }
}
