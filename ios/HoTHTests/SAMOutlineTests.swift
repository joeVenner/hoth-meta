import HoTHCore
import SwiftData
import UIKit
import XCTest
@testable import HoTH

/// SAM 3.1 overlay in the report flow, plus photo orientation → box mapping. Hermetic: vision is a
/// URLProtocol stub and SAM is a fake `HazardOutlining`.
@MainActor
final class SAMOutlineTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    override func setUp() async throws {
        container = try HoTHStore.makeContainer(inMemory: true)
        VisionStubURLProtocol.payload = try JSONEncoder().encode(DemoSamples.springRider.cannedAnalysis)
        VisionStubURLProtocol.resetRecording()
    }

    override func tearDown() async throws {
        container = nil
        VisionStubURLProtocol.payload = nil
    }

    private func makeFlow(hasKey: Bool, outliner: HazardOutlining?) throws -> ReportFlowModel {
        let client = MetaModelClient(keyProvider: StaticTestKey(), session: VisionStubURLProtocol.makeSession(),
                                     baseURL: URL(string: "https://stub.invalid/v1")!)
        return ReportFlowModel(client: client, prompts: try Prompts(bundle: .main), language: { "en" },
                               isDemoMode: { true }, hasAPIKey: { hasKey }, outliner: { outliner })
    }

    private func springRiderPhoto() throws -> CapturedPhoto {
        let sample = DemoSamples.springRider
        return try CaptureService.makeCapturedPhoto(from: sample.loadImage(), capturedAt: Date(), gps: sample.gpsFix,
                                                    source: .demoLibrary, demoSampleID: sample.id)
    }

    // MARK: Report flow

    func testLiveAnalysisIsOutlinedOnTheSameJPEG() async throws {
        let fake = FakeOutliner { _, _ in samFound }
        let flow = try makeFlow(hasKey: true, outliner: fake)
        let photo = try springRiderPhoto()
        await flow.submit(photo, context: context)
        XCTAssertEqual(flow.step, .analysis)
        XCTAssertFalse(flow.isDemoAnalysis, "vision came from the (stubbed) live call")
        await flow.waitForOutline()
        XCTAssertEqual(flow.outline, samFound)
        XCTAssertEqual(fake.calls.count, 1)
        let visionJPEG = try XCTUnwrap(VisionStubURLProtocol.sentJPEGs.first)
        XCTAssertEqual(fake.calls.first?.jpeg, visionJPEG, "SAM sees exactly the bytes vision saw")
        XCTAssertEqual(fake.calls.first?.category, .playgroundEquipment)
    }

    func testSAMFailureLeavesNoOverlayAndNeverBlocks() async throws {
        let fake = FakeOutliner { _, _ in throw HazardSegmenter.Failure.timedOut }
        let flow = try makeFlow(hasKey: true, outliner: fake)
        await flow.submit(try springRiderPhoto(), context: context)
        await flow.waitForOutline()
        XCTAssertEqual(flow.step, .analysis)
        XCTAssertNil(flow.outline)
        flow.continueFromAnalysis()
        XCTAssertEqual(flow.step, .interview, "the report carries on without SAM")
    }

    func testSlowSAMDoesNotHoldTheCardAndRetakeDropsIt() async throws {
        let fake = FakeOutliner { _, _ in
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return samFound
        }
        let flow = try makeFlow(hasKey: true, outliner: fake)
        let started = Date()
        await flow.submit(try springRiderPhoto(), context: context)
        XCTAssertEqual(flow.step, .analysis)
        XCTAssertNil(flow.outline)
        XCTAssertLessThan(Date().timeIntervalSince(started), 4, "submit never awaits SAM")
        flow.retake()
        await flow.waitForOutline()
        XCTAssertNil(flow.outline)
        XCTAssertEqual(flow.step, .capture)
    }

    func testCannedAnalysisNeverCallsSAM() async throws {
        let fake = FakeOutliner { _, _ in samFound }
        let flow = try makeFlow(hasKey: false, outliner: fake)
        await flow.submit(try springRiderPhoto(), context: context)
        await flow.waitForOutline()
        XCTAssertTrue(flow.isDemoAnalysis)
        XCTAssertNil(flow.outline)
        XCTAssertTrue(fake.calls.isEmpty, "no SAM boxes are invented for offline demo analyses")
    }

    func testNoOutlinerMeansNoOverlay() async throws {
        let flow = try makeFlow(hasKey: true, outliner: nil)
        await flow.submit(try springRiderPhoto(), context: context)
        await flow.waitForOutline()
        XCTAssertEqual(flow.step, .analysis)
        XCTAssertNil(flow.outline)
    }

    // MARK: Orientation

    func testRotatedCameraPhotoIsSentUprightSoBoxesMapToTheView() throws {
        // A portrait camera frame: 200 x 100 sensor pixels tagged `.right`, shown as 100 x 200.
        let sensor = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 200, height: 100),
                                                           format: Self.pointFormat).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        }.cgImage)
        let portrait = UIImage(cgImage: sensor, scale: 1, orientation: .right)
        XCTAssertEqual(portrait.size, CGSize(width: 100, height: 200))

        let upright = ImageResizing.normalizedAndDownsized(portrait, maxEdge: ImageResizing.maxPixelEdge)
        XCTAssertEqual(upright.imageOrientation, .up)
        XCTAssertEqual(upright.cgImage?.width, 100)
        XCTAssertEqual(upright.cgImage?.height, 200)
        let sent = try XCTUnwrap(upright.jpegData(compressionQuality: 0.8))
        XCTAssertEqual(JPEGSize.pixelSize(of: sent), PixelSize(width: 100, height: 200))

        // SAM reports boxes in the sent pixels; the bottom half of the photo...
        let instances = SAMOutputParser.parse("<0f>0<|box;x1=0;y1=100;x2=100;y2=200;w=100;h=200;c=0.9|>")
        let boxes = SegmentSelection.boxes(from: instances, sentImage: JPEGSize.pixelSize(of: sent))
        XCTAssertEqual(boxes, [NormalizedBox(x: 0, y: 0.5, w: 1, h: 0.5)])
        // ...lands on the bottom half of the aspect-fit photo (50 x 100 inside a 100 x 100 view).
        let rect = OverlayGeometry.viewRect(for: boxes[0], imageSize: upright.size,
                                            in: CGSize(width: 100, height: 100), mode: .fit)
        XCTAssertEqual(rect, CGRect(x: 25, y: 50, width: 50, height: 50))

        // The raw sensor JPEG (what an un-normalized UIImage encodes) is rejected, not misdrawn.
        let rotatedClaim = SAMOutputParser.parse("<0f>0<|box;x1=0;y1=0;x2=100;y2=50;w=200;h=100|>")
        XCTAssertTrue(SegmentSelection.boxes(from: rotatedClaim, sentImage: PixelSize(width: 100, height: 200)).isEmpty)
    }

    private static var pointFormat: UIGraphicsImageRendererFormat {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return format
    }
}

// MARK: - Test doubles

private let samFound = SegmentOutline(concept: "broken playground equipment",
                                      boxes: [NormalizedBox(x: 0.3, y: 0.4, w: 0.2, h: 0.3)])

struct StaticTestKey: APIKeyProvider {
    func apiKey() async throws -> String { "LLM_000000_test-secret-123456789" }
}

/// Records SAM requests and answers with `respond`.
final class FakeOutliner: HazardOutlining, @unchecked Sendable {
    struct Call {
        let jpeg: Data
        let category: ReportCategory
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private let respond: @Sendable (Data, ReportCategory) async throws -> SegmentOutline?

    init(respond: @escaping @Sendable (Data, ReportCategory) async throws -> SegmentOutline?) {
        self.respond = respond
    }

    var calls: [Call] { lock.withLock { recorded } }

    func outline(jpegData: Data, category: ReportCategory) async throws -> SegmentOutline? {
        lock.withLock { recorded.append(Call(jpeg: jpegData, category: category)) }
        return try await respond(jpegData, category)
    }
}

/// Answers every Responses call with `payload` as the model's JSON output, and records each request
/// body so tests can check exactly which photo bytes would have left the phone.
final class VisionStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var payload: Data?
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recordedBodies: [Data] = []

    /// Request bodies since the last `resetRecording()`.
    static var bodies: [Data] { lock.withLock { recordedBodies } }
    static func resetRecording() { lock.withLock { recordedBodies = [] } }

    /// Every `data:image/jpeg;base64,` payload in the recorded bodies, decoded, in request order.
    static var sentJPEGs: [Data] { bodies.flatMap(Self.jpegs(inBody:)) }

    static func jpegs(inBody body: Data) -> [Data] {
        guard let object = try? JSONSerialization.jsonObject(with: body) else { return [] }
        return dataURLs(in: object).compactMap { url in
            let prefix = "data:image/jpeg;base64,"
            guard url.hasPrefix(prefix) else { return nil }
            return Data(base64Encoded: String(url.dropFirst(prefix.count)))
        }
    }

    private static func dataURLs(in object: Any) -> [String] {
        switch object {
        case let string as String: return string.hasPrefix("data:") ? [string] : []
        case let array as [Any]: return array.flatMap(dataURLs(in:))
        case let dictionary as [String: Any]: return dictionary.values.flatMap(dataURLs(in:))
        default: return []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLSession moves the body into a stream before it reaches a URLProtocol.
        let body = request.httpBody ?? request.httpBodyStream.map(Self.readAll) ?? Data()
        Self.lock.withLock { Self.recordedBodies.append(body) }
        let text = String(decoding: Self.payload ?? Data(), as: UTF8.self)
        let envelope: [String: Any] = [
            "status": "completed",
            "output": [["type": "message", "role": "assistant",
                        "content": [["type": "output_text", "text": text]]]]
        ]
        let data = (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data()
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.payload == nil ? 500 : 200,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readAll(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [VisionStubURLProtocol.self]
        return URLSession(configuration: config)
    }
}
