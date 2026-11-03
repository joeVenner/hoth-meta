import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import HoTHCore

/// Category → SAM concept, box selection, JPEG size and overlay geometry. Hermetic (URLProtocol stub);
/// SAM text is doc-shaped, not recorded from the live API.
final class HazardSegmenterTests: XCTestCase {
    private struct SlowKey: APIKeyProvider {
        func apiKey() async throws -> String {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return "LLM_000000_test-secret-123456789"
        }
    }

    override func setUp() {
        super.setUp()
        StubURLProtocol.handler = nil
        StubURLProtocol.captured = []
    }

    private func makeClient(keyProvider: APIKeyProvider = StaticKey(key: "LLM_000000_test-secret-123456789")) -> MetaModelClient {
        MetaModelClient(keyProvider: keyProvider, session: StubURLProtocol.makeSession(),
                        baseURL: URL(string: "https://stub.invalid/v1")!)
    }

    /// A Responses envelope whose output text is SAM's token text.
    private func samEnvelope(_ text: String) throws -> Data {
        let encoded = try JSONEncoder().encode(JSONValue.object([
            "status": .string("completed"),
            "output": .array([.object([
                "type": .string("message"),
                "role": .string("assistant"),
                "content": .array([.object(["type": .string("output_text"), "text": .string(text)])])
            ])])
        ]))
        return encoded
    }

    private func instance(_ id: Int, _ x1: Int, _ y1: Int, _ x2: Int, _ y2: Int, w: Int = 100, h: Int = 50,
                          score: Double? = nil, frame: Int = 0) -> SegmentedInstance {
        SegmentedInstance(objectId: id, frame: frame,
                          box: PixelBox(x1: x1, y1: y1, x2: x2, y2: y2, sourceWidth: w, sourceHeight: h),
                          mask: nil, score: score)
    }

    // MARK: Concepts

    func testEveryRealCategoryHasAConceptAndOthersHaveNone() throws {
        let prompts = try Fixtures.prompts()
        XCTAssertEqual(prompts.segmentConcept(for: .potholePavement), "pothole")
        XCTAssertEqual(prompts.segmentConcept(for: .openManhole), "manhole")
        XCTAssertEqual(prompts.segmentConcept(for: .playgroundEquipment), "broken playground equipment")
        XCTAssertEqual(prompts.segmentConcept(for: .wasteOverflowDumping), "garbage")
        XCTAssertEqual(prompts.segmentConcept(for: .waterLeak), "water")
        XCTAssertEqual(prompts.segmentConcept(for: .electricalHazard), "exposed cable")
        XCTAssertEqual(prompts.segmentConcept(for: .blockedAccessibility), "obstruction")
        XCTAssertEqual(prompts.segmentConcept(for: .fitnessEquipment), "broken fitness equipment")
        XCTAssertNil(prompts.segmentConcept(for: .other))
        XCTAssertNil(prompts.segmentConcept(for: .notAnIssue))
        for category in ReportCategory.allCases where category != .other && category != .notAnIssue {
            let concept = try XCTUnwrap(prompts.segmentConcept(for: category), category.rawValue)
            XCTAssertLessThanOrEqual(concept.split(separator: " ").count, 3, "SAM wants a short noun phrase")
        }
    }

    func testPromptsWithoutConceptMapStillDecode() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Fixtures.appPromptsData()) as? [String: Any])
        object.removeValue(forKey: "segment_concepts")
        let prompts = try Prompts(data: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(prompts.segmentConcepts)
        XCTAssertNil(prompts.segmentConcept(for: .potholePavement))
    }

    // MARK: Segmenter

    func testOutlineSendsCategoryConceptAndReturnsSelectedBoxes() async throws {
        let text = "<0f>0<|box;x1=10;y1=5;x2=60;y2=30;w=100;h=50;c=0.4|>,1<|box;x1=20;y1=10;x2=90;y2=45;w=100;h=50;c=0.9|>"
        let envelope = try samEnvelope(text)
        StubURLProtocol.handler = { _ in (200, envelope) }
        let segmenter = HazardSegmenter(client: makeClient(), prompts: try Fixtures.prompts())

        let outline = try await segmenter.outline(jpegData: Data([0xFF, 0xD8]), category: .potholePavement)
        XCTAssertEqual(outline?.concept, "pothole")
        XCTAssertEqual(outline?.boxes.count, 2)
        XCTAssertEqual(try XCTUnwrap(outline?.boxes.first).x, 0.2, accuracy: 1e-9, "higher score first")

        let body = try JSONDecoder().decode(JSONValue.self, from: try XCTUnwrap(StubURLProtocol.captured.first).body)
        XCTAssertEqual(body["model"], .string("sam-3.1"))
        guard case .array(let input)? = body["input"], case .array(let content)? = input.first?["content"] else {
            return XCTFail("bad input shape")
        }
        XCTAssertEqual(content.first?["text"], .string("pothole"))
    }

    func testOutlineWithNoMatchesIsEmptyNotNil() async throws {
        let envelope = try samEnvelope("<0f>")
        StubURLProtocol.handler = { _ in (200, envelope) }
        let outline = try await HazardSegmenter(client: makeClient(), prompts: try Fixtures.prompts())
            .outline(jpegData: Data([1]), category: .openManhole)
        XCTAssertEqual(outline, SegmentOutline(concept: "manhole", boxes: []))
    }

    func testCategoryWithoutConceptMakesNoCall() async throws {
        let segmenter = HazardSegmenter(client: makeClient(), prompts: try Fixtures.prompts())
        let other = try await segmenter.outline(jpegData: Data([1]), category: .other)
        let notIssue = try await segmenter.outline(jpegData: Data([1]), category: .notAnIssue)
        XCTAssertNil(other)
        XCTAssertNil(notIssue)
        XCTAssertTrue(StubURLProtocol.captured.isEmpty)
    }

    func testOutlineTimesOut() async throws {
        let segmenter = HazardSegmenter(client: makeClient(keyProvider: SlowKey()), prompts: try Fixtures.prompts(),
                                        timeout: 0.1)
        let started = Date()
        do {
            _ = try await segmenter.outline(jpegData: Data([1]), category: .potholePavement)
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? HazardSegmenter.Failure, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "the slow call is cancelled, not awaited")
        XCTAssertTrue(StubURLProtocol.captured.isEmpty)
    }

    func testOutlineSurfacesServerErrors() async throws {
        StubURLProtocol.handler = { _ in (500, Data(#"{"error":{"message":"boom"}}"#.utf8)) }
        do {
            _ = try await HazardSegmenter(client: makeClient(), prompts: try Fixtures.prompts())
                .outline(jpegData: Data([1]), category: .potholePavement)
            XCTFail("expected an error")
        } catch {
            XCTAssertNotNil(error as? ModelAPIError)
        }
    }

    // MARK: Selection

    func testSelectionRanksByScoreAndCaps() {
        let instances = [
            instance(1, 0, 0, 10, 10, score: 0.5),
            instance(2, 10, 10, 30, 30),
            instance(3, 20, 0, 40, 20, score: 0.95),
            instance(4, 50, 0, 70, 20, score: 0.7),
            instance(5, 60, 10, 80, 30)
        ]
        let boxes = SegmentSelection.boxes(from: instances, sentImage: PixelSize(width: 100, height: 50))
        XCTAssertEqual(boxes.map(\.x), [0.2, 0.5, 0.0])
        XCTAssertEqual(SegmentSelection.boxes(from: instances, sentImage: nil, maxCount: 5).map(\.x),
                       [0.2, 0.5, 0.0, 0.1, 0.6], "unscored keep SAM's order after scored")
    }

    func testSelectionDropsNoiseOtherFramesAndLowScores() {
        let instances = [
            instance(1, 0, 0, 1, 1, w: 1000, h: 500),          // 0.0002% of the photo: a speck
            instance(2, 0, 0, 50, 25, score: 0.1),             // below the score floor
            instance(3, 0, 0, 50, 25, frame: 1),               // not the still frame
            instance(4, 10, 10, 10, 40),                       // zero width
            instance(5, 0, 0, 50, 25, score: 0.25)             // exactly the floor: kept
        ]
        let boxes = SegmentSelection.boxes(from: instances, sentImage: PixelSize(width: 100, height: 50))
        XCTAssertEqual(boxes, [NormalizedBox(x: 0, y: 0, w: 0.5, h: 0.5)])
        XCTAssertTrue(SegmentSelection.boxes(from: [], sentImage: nil).isEmpty)
    }

    func testSelectionDropsBoxesFromARotatedOrReframedImage() {
        // SAM says 50 x 100 (portrait) but a 100 x 50 landscape JPEG was sent: the frame was rotated.
        let rotated = instance(1, 0, 0, 25, 50, w: 50, h: 100)
        XCTAssertTrue(SegmentSelection.boxes(from: [rotated], sentImage: PixelSize(width: 100, height: 50)).isEmpty)
        // Same aspect at another resolution (SAM resized internally) still maps, by SAM's own w/h.
        let resized = instance(1, 0, 0, 100, 50, w: 200, h: 100)
        XCTAssertEqual(SegmentSelection.boxes(from: [resized], sentImage: PixelSize(width: 1024, height: 512)),
                       [NormalizedBox(x: 0, y: 0, w: 0.5, h: 0.5)])
    }

    func testReversedAndOutOfBoundsCornersAreNormalized() {
        let instances = SAMOutputParser.parse("<0f>0<|box;x1=90;y1=60;x2=40;y2=-5;w=100;h=50|>")
        let boxes = SegmentSelection.boxes(from: instances, sentImage: PixelSize(width: 100, height: 50))
        XCTAssertEqual(boxes.count, 1)
        XCTAssertEqual(boxes[0].x, 0.4, accuracy: 1e-9)
        XCTAssertEqual(boxes[0].y, 0)
        XCTAssertEqual(boxes[0].w, 0.5, accuracy: 1e-9)
        XCTAssertEqual(boxes[0].h, 1)
    }

    func testMalformedRecordBesideAGoodOneKeepsTheGoodOne() {
        let line = "<0f>0<|box;x1=1;y1=1;x2=oops;y2=2;w=3;h=3|>,5<|box;x1=10;y1=10;x2=40;y2=30;w=100;h=50;c=0.8|>"
        let instances = SAMOutputParser.parse(line)
        XCTAssertEqual(instances.map(\.objectId), [5])
        XCTAssertEqual(instances.first?.score, 0.8)
    }

    // MARK: JPEG size

    func testJPEGSizeAppliesRotatedOrientation() throws {
        XCTAssertEqual(JPEGSize.pixelSize(of: try jpeg(width: 40, height: 20, orientation: 1)),
                       PixelSize(width: 40, height: 20))
        XCTAssertEqual(JPEGSize.pixelSize(of: try jpeg(width: 40, height: 20, orientation: 6)),
                       PixelSize(width: 20, height: 40), "EXIF 6 (camera portrait) is shown rotated")
        XCTAssertNil(JPEGSize.pixelSize(of: Data([0xFF, 0xD8, 0xFF])))
    }

    private func jpeg(width: Int, height: Int, orientation: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    // MARK: Geometry

    func testAspectFitLetterboxesAndMapsBoxes() {
        // 200 x 100 photo in a 100 x 100 view: 100 x 50 image, 25 pt bars top and bottom.
        let size = CGSize(width: 200, height: 100)
        XCTAssertEqual(OverlayGeometry.imageFrame(imageSize: size, in: CGSize(width: 100, height: 100), mode: .fit),
                       CGRect(x: 0, y: 25, width: 100, height: 50))
        let rect = OverlayGeometry.viewRect(for: NormalizedBox(x: 0.5, y: 0.5, w: 0.5, h: 0.5), imageSize: size,
                                            in: CGSize(width: 100, height: 100), mode: .fit)
        XCTAssertEqual(rect, CGRect(x: 50, y: 50, width: 50, height: 25))
    }

    func testAspectFillCropsAndMapsBoxes() {
        // 200 x 100 photo filling a 76 x 76 thumbnail: 152 x 76 image, 38 pt cropped off each side.
        let size = CGSize(width: 200, height: 100)
        let container = CGSize(width: 76, height: 76)
        XCTAssertEqual(OverlayGeometry.imageFrame(imageSize: size, in: container, mode: .fill),
                       CGRect(x: -38, y: 0, width: 152, height: 76))
        let centre = OverlayGeometry.viewRect(for: NormalizedBox(x: 0.25, y: 0, w: 0.5, h: 1), imageSize: size,
                                              in: container, mode: .fill)
        XCTAssertEqual(centre, CGRect(x: 0, y: 0, width: 76, height: 76), "the middle half is exactly what shows")
        let edge = OverlayGeometry.viewRect(for: NormalizedBox(x: 0, y: 0, w: 0.1, h: 0.1), imageSize: size,
                                            in: container, mode: .fill)
        XCTAssertFalse(edge.intersects(CGRect(origin: .zero, size: container)), "a box in the cropped margin is off-view")
    }

    func testGeometryWithEmptySizesIsZero() {
        XCTAssertEqual(OverlayGeometry.imageFrame(imageSize: .zero, in: CGSize(width: 10, height: 10), mode: .fit), .zero)
        XCTAssertEqual(OverlayGeometry.imageFrame(imageSize: CGSize(width: 10, height: 10), in: .zero, mode: .fill), .zero)
    }
}
