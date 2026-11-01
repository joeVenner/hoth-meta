import HoTHCore
import SwiftData
import UIKit
import Vision
import XCTest
@testable import HoTH

/// Privacy invariant: no unblurred photo bytes ever reach the Meta Model API. Every image in every
/// request (vision, duplicate judge, SAM, the intake agent's `segment_hazard`, fix check before/after)
/// must be an output of the on-device redactor; if redaction fails, nothing is sent at all.
/// Hermetic: Meta calls go to `VisionStubURLProtocol`, SAM and the fix verifier are fakes.
@MainActor
final class UploadRedactionTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }
    private var savedFiles: [String] = []

    override func setUp() async throws {
        container = try HoTHStore.makeContainer(inMemory: true)
        VisionStubURLProtocol.payload = try JSONEncoder().encode(DemoSamples.springRider.cannedAnalysis)
        VisionStubURLProtocol.resetRecording()
    }

    override func tearDown() async throws {
        VisionStubURLProtocol.payload = nil
        VisionStubURLProtocol.resetRecording()
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            for name in savedFiles { try? FileManager.default.removeItem(at: documents.appendingPathComponent(name)) }
        }
        container = nil
    }

    // MARK: Report flow

    func testEveryReportUploadIsTheRedactedJPEG() async throws {
        let redactor = RecordingRedactor()
        let outliner = ConceptRecordingOutliner()
        let flow = try makeFlow(redactor: redactor, outliner: outliner)
        // An open report of the same category right here, so the duplicate judge sends both photos.
        let existingOriginal = try XCTUnwrap(Self.solidImage(.green, size: CGSize(width: 80, height: 60))
            .jpegData(compressionQuality: 0.9))
        let existingPublic = try XCTUnwrap(Self.solidImage(.blue, size: CGSize(width: 80, height: 60))
            .jpegData(compressionQuality: 0.9))
        _ = try insertExistingReport(original: existingOriginal, public: existingPublic)

        let photo = try livePhoto()
        await flow.submit(photo, context: context)
        XCTAssertEqual(flow.step, .analysis)
        XCTAssertFalse(flow.isDemoAnalysis)
        await flow.waitForOutline()

        // The intake agent asks SAM for a different concept: a fresh SAM call on the same photo.
        let toolbox = try XCTUnwrap(flow.intakeToolbox(context: context, outliner: outliner))
        _ = await toolbox.run(FunctionCall(callID: "s", name: "segment_hazard", arguments: #"{"concept":"broken bin"}"#))

        let sentToSpark = VisionStubURLProtocol.sentJPEGs
        XCTAssertEqual(sentToSpark.count, 3, "vision (1) + duplicate judge (new + existing)")
        let samJPEGs = outliner.categoryCalls + outliner.conceptCalls
        XCTAssertEqual(outliner.categoryCalls.count, 1, "card outline")
        XCTAssertEqual(outliner.conceptCalls.count, 1, "segment_hazard")

        let redacted = redactor.outputs
        let unblurred = [photo.jpegData, existingOriginal, existingPublic]
        for jpeg in sentToSpark + samJPEGs {
            XCTAssertTrue(redacted.contains(jpeg), "a photo reached Meta without passing the redactor")
            XCTAssertFalse(unblurred.contains(jpeg), "unblurred bytes reached Meta")
        }
        XCTAssertEqual(redactor.inputCount, 2, "the new photo once (reused everywhere) + the existing one")
        XCTAssertEqual(sentToSpark.first, outliner.categoryCalls.first, "SAM sees exactly the bytes vision saw")
        XCTAssertTrue(flow.blurredImage === redactor.firstOutputImage, "the posted photo reuses the upload's blur")
    }

    func testFailedRedactionSendsNothingAndAsksForARetake() async throws {
        let outliner = ConceptRecordingOutliner()
        let flow = try makeFlow(redactor: { _ in nil }, outliner: outliner)
        await flow.submit(try livePhoto(), context: context)
        await flow.waitForOutline()

        guard case .failed(let message) = flow.step else { return XCTFail("Expected .failed, got \(flow.step)") }
        XCTAssertEqual(message, ReportFlowModel.redactionFailedMessage(arabic: false))
        XCTAssertTrue(VisionStubURLProtocol.bodies.isEmpty, "no request may be made without a redacted photo")
        XCTAssertTrue(outliner.categoryCalls.isEmpty && outliner.conceptCalls.isEmpty)
        XCTAssertFalse(ReportFlowModel.redactionFailedMessage(arabic: true).isEmpty)
    }

    func testCannedDemoAnalysisSendsNothing() async throws {
        let redactor = RecordingRedactor()
        let flow = try makeFlow(redactor: redactor, outliner: ConceptRecordingOutliner(), hasKey: false)
        let sample = DemoSamples.springRider
        let photo = try CaptureService.makeCapturedPhoto(from: sample.loadImage(), capturedAt: Date(), gps: sample.gpsFix,
                                                         source: .demoLibrary, demoSampleID: sample.id)
        await flow.submit(photo, context: context)
        XCTAssertTrue(flow.isDemoAnalysis)
        XCTAssertTrue(VisionStubURLProtocol.bodies.isEmpty)
        XCTAssertNil(flow.intakeToolbox(context: context, outliner: ConceptRecordingOutliner())?
            .tools.first { $0.name == "segment_hazard" }, "no SAM tool without a redacted upload")
    }

    // MARK: Fix check

    func testFixCheckSendsOnlyRedactedPhotosAndSavesThatBlur() async throws {
        let redactor = RecordingRedactor()
        let verifier = RecordingVerifier(verdict: FixVerdict(
            resolved: false, reasonEN: "Half", reasonAR: "نصف",
            remaining: [.init(label: "gravel", box: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))], isCanned: false))
        let sam = FakeOutliner { _, _ in SegmentOutline(concept: "pothole", boxes: []) }
        let model = FixCheckModel(verifierFactory: { _ in verifier }, outlinerFactory: { sam }, redactor: redactor.redact)
        let report = makeCrewReport()
        let after = Self.solidImage(.gray, size: CGSize(width: 64, height: 64))
        await model.check(report: report, after: after, demo: nil, context: context)
        await model.waitForOutline()

        XCTAssertEqual(model.phase, .verdict)
        let sent = [verifier.before, verifier.after].compactMap { $0 } + sam.calls.map(\.jpeg)
        XCTAssertEqual(sent.count, 3)
        for jpeg in sent { XCTAssertTrue(redactor.outputs.contains(jpeg), "fix-check photo was not redacted") }
        XCTAssertEqual(sam.calls.first?.jpeg, verifier.after, "SAM sees the after photo the verifier saw")

        // A resolved check saves the same redacted after photo (no second blur).
        let resolvedVerifier = RecordingVerifier(verdict: FixVerdict(resolved: true, reasonEN: "Done", reasonAR: "تم",
                                                                     remaining: [], isCanned: false))
        let resolvedRedactor = RecordingRedactor()
        let resolving = FixCheckModel(verifierFactory: { _ in resolvedVerifier }, outlinerFactory: { nil },
                                      redactor: resolvedRedactor.redact)
        let open = makeCrewReport()
        await resolving.check(report: open, after: after, demo: nil, context: context)
        XCTAssertEqual(resolving.phase, .verdict)
        XCTAssertEqual(resolvedRedactor.inputCount, 2, "before + after, each blurred once")
        let fixName = try XCTUnwrap(open.fixPhotoFileName)
        savedFiles.append(fixName)
        let saved = try XCTUnwrap(ReportPhotoView.loadImage(fixName)?.cgImage)
        XCTAssertEqual(Self.centreColor(of: saved), Self.centreColor(of: try XCTUnwrap(RecordingRedactor.marker(
            for: CGSize(width: 64, height: 64)).cgImage)), "the saved fix photo is the redactor's output")
    }

    func testFixCheckWithFailedRedactionSendsNothing() async throws {
        let verifier = RecordingVerifier(verdict: FixVerdict(resolved: true, reasonEN: "", reasonAR: "", remaining: [],
                                                             isCanned: false))
        let model = FixCheckModel(verifierFactory: { _ in verifier }, outlinerFactory: { nil }, redactor: { _ in nil })
        let report = makeCrewReport()
        await model.check(report: report, after: Self.solidImage(.gray, size: CGSize(width: 64, height: 64)),
                          demo: nil, context: context)
        guard case .failed = model.phase else { return XCTFail("Expected .failed, got \(model.phase)") }
        XCTAssertEqual(verifier.callCount, 0)
        XCTAssertEqual(report.status, .inProgress)
    }

    func testCannedFixCheckSkipsUploadBlurButSavesABlurredFix() async throws {
        let redactor = RecordingRedactor()
        let model = FixCheckModel(verifierFactory: { CannedFixVerifier(photo: $0 ?? .good) }, outlinerFactory: { nil },
                                  redactor: redactor.redact)
        let report = makeCrewReport()
        await model.check(report: report, after: Self.solidImage(.gray, size: CGSize(width: 64, height: 64)),
                          demo: .good, context: context)
        XCTAssertEqual(model.phase, .verdict)
        XCTAssertEqual(redactor.inputCount, 1, "canned verdicts send nothing: only the saved fix photo is blurred")
        savedFiles.append(try XCTUnwrap(report.fixPhotoFileName))

        // A failed blur never breaks the canned demo; it only means no public fix photo is saved.
        let failing = FixCheckModel(verifierFactory: { CannedFixVerifier(photo: $0 ?? .good) }, outlinerFactory: { nil },
                                    redactor: { _ in nil })
        let other = makeCrewReport()
        await failing.check(report: other, after: Self.solidImage(.gray, size: CGSize(width: 64, height: 64)),
                            demo: .good, context: context)
        XCTAssertEqual(failing.phase, .verdict)
        XCTAssertNil(other.fixPhotoFileName)
    }

    func testFixCheckBeforePhotoIsDownsizedBeforeBlur() async throws {
        let redactor = RecordingRedactor()
        let verifier = RecordingVerifier(verdict: FixVerdict(resolved: false, reasonEN: "", reasonAR: "", remaining: [],
                                                             isCanned: true))
        let model = FixCheckModel(verifierFactory: { _ in verifier }, outlinerFactory: { nil }, redactor: redactor.redact)
        let report = makeCrewReport()
        report.isDemoSeed = false
        let big = try XCTUnwrap(Self.solidImage(.gray, size: CGSize(width: 3000, height: 2000)).jpegData(compressionQuality: 0.5))
        let name = try XCTUnwrap(ReportPhotoFiles.save(big, named: "test_\(UUID().uuidString).jpg"))
        savedFiles.append(name)
        report.photoFileName = name
        await model.check(report: report, after: Self.solidImage(.gray, size: CGSize(width: 64, height: 64)),
                          demo: nil, context: context)
        XCTAssertEqual(model.phase, .verdict)
        XCTAssertLessThanOrEqual(redactor.maxInputEdge, ImageResizing.maxPixelEdge)
    }

    func testResetDuringFixCheckBlurSendsNothingAndAppliesNothing() async throws {
        let verifier = RecordingVerifier(verdict: FixVerdict(resolved: true, reasonEN: "", reasonAR: "", remaining: [],
                                                             isCanned: false))
        let holder = ModelHolder()
        let recording = RecordingRedactor()
        let model = FixCheckModel(verifierFactory: { _ in verifier }, outlinerFactory: { nil }, redactor: { image in
            await MainActor.run { holder.model?.reset() }
            return await recording.redact(image)
        })
        holder.model = model
        let report = makeCrewReport()
        await model.check(report: report, after: Self.solidImage(.gray, size: CGSize(width: 64, height: 64)),
                          demo: nil, context: context)
        XCTAssertEqual(verifier.callCount, 0, "a stale check must not upload")
        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.verdict)
        XCTAssertEqual(report.status, .inProgress)
    }

    // MARK: Real on-device blur

    func testRealRedactionHidesAPlateBeforeUpload() async throws {
        let image = Self.platePhoto()
        let source = try XCTUnwrap(image.cgImage)
        let before = try FaceAndPlateBlur.detectRegions(in: source)
        try XCTSkipIf(before.plates.isEmpty, "Vision did not read the synthetic plate on this runtime")

        let maybeUpload = await FaceAndPlateBlur.redactForUpload(image, quality: CaptureService.jpegQuality)
        let upload = try XCTUnwrap(maybeUpload)
        XCTAssertTrue(upload.result.isSafeToPost)
        XCTAssertGreaterThan(upload.result.plateCount, 0)
        let sent = try XCTUnwrap(UIImage(data: upload.jpegData)?.cgImage)
        XCTAssertEqual(sent.width, source.width, "same pixel size, so model boxes still land on the shown photo")
        XCTAssertEqual(sent.height, source.height)
        XCTAssertTrue(try FaceAndPlateBlur.detectRegions(in: sent).plates.isEmpty, "the plate is still readable")
    }

    func testRedactionFailsClosedOnTimeout() async {
        let started = Date()
        let late = await FaceAndPlateBlur.firstResult(timeout: .milliseconds(100), fallback: "timed out") {
            Thread.sleep(forTimeInterval: 1.5)
            return "late"
        }
        XCTAssertEqual(late, "timed out")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.2)
        let quick = await FaceAndPlateBlur.firstResult(timeout: .seconds(5), fallback: "timed out") { "done" }
        XCTAssertEqual(quick, "done")
    }

    func testUnredactableImageYieldsNoUpload() async {
        // A CIImage-backed UIImage has no CGImage: the blur fails, so there is nothing to send.
        let ciOnly = UIImage(ciImage: CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32)))
        let upload = await FaceAndPlateBlur.redactForUpload(ciOnly, quality: 0.8)
        XCTAssertNil(upload)
    }

    // MARK: Helpers

    private func makeFlow(redactor: @escaping @Sendable (UIImage) async -> FaceAndPlateBlur.Upload?,
                          outliner: HazardOutlining?, hasKey: Bool = true) throws -> ReportFlowModel {
        let client = MetaModelClient(keyProvider: StaticTestKey(), session: VisionStubURLProtocol.makeSession(),
                                     baseURL: URL(string: "https://stub.invalid/v1")!)
        return ReportFlowModel(client: client, prompts: try Prompts(bundle: .main), language: { "en" },
                               isDemoMode: { true }, hasAPIKey: { hasKey }, outliner: { outliner },
                               redactor: redactor)
    }

    private func makeFlow(redactor: RecordingRedactor, outliner: HazardOutlining?,
                          hasKey: Bool = true) throws -> ReportFlowModel {
        try makeFlow(redactor: redactor.redact, outliner: outliner, hasKey: hasKey)
    }

    /// A photo with no demo sample id, so the duplicate judge runs (merge policy `.judged`).
    private func livePhoto() throws -> CapturedPhoto {
        let sample = DemoSamples.springRider
        return try CaptureService.makeCapturedPhoto(from: sample.loadImage(), capturedAt: Date(), gps: sample.gpsFix,
                                                    source: .demoLibrary, demoSampleID: nil)
    }

    private func insertExistingReport(original: Data, public publicJPEG: Data) throws -> Report {
        let id = UUID().uuidString
        let originalName = try XCTUnwrap(ReportPhotoFiles.save(original, named: "test_\(id).jpg"))
        let publicName = try XCTUnwrap(ReportPhotoFiles.save(publicJPEG, named: "test_\(id)_public.jpg"))
        savedFiles += [originalName, publicName]
        let fix = DemoSamples.springRider.gpsFix
        let report = Report(category: .playgroundEquipment, titleEN: "Broken spring rider", titleAR: "لعبة مكسورة",
                            summaryEN: "Spring rider broken", summaryAR: "", latitude: fix.latitude + 5 / 111_000,
                            longitude: fix.longitude, placeName: "Park", photoFileName: originalName,
                            blurredPhotoFileName: publicName, priority: .high, priorityScore: 60,
                            priorityReasonEN: "", priorityReasonAR: "", status: .open)
        context.insert(report)
        try context.save()
        return report
    }

    private func makeCrewReport() -> Report {
        let report = Report(category: .potholePavement, titleEN: "Pothole", titleAR: "حفرة", summaryEN: "",
                            summaryAR: "", latitude: 24.42, longitude: 54.57, placeName: "Street 1",
                            priority: .high, priorityScore: 70, priorityReasonEN: "", priorityReasonAR: "",
                            status: .inProgress)
        report.photoFileName = DemoFixPhoto.beforeAssetName
        report.isDemoSeed = true
        context.insert(report)
        return report
    }

    nonisolated static func solidImage(_ color: UIColor, size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// A street-like scene with one plate-shaped "A 12345" sign.
    private static func platePhoto() -> UIImage {
        let size = CGSize(width: 1000, height: 700)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(white: 0.55, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let plate = CGRect(x: 380, y: 420, width: 240, height: 64)
            UIColor.white.setFill()
            context.fill(plate)
            let text = NSAttributedString(string: "A 12345", attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 44, weight: .bold),
                .foregroundColor: UIColor.black,
            ])
            text.draw(at: CGPoint(x: plate.minX + 22, y: plate.minY + 6))
        }
    }

    nonisolated static func centreColor(of image: CGImage) -> [UInt8] {
        var pixel = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpaceCreateDeviceRGB()
        pixel.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                          bytesPerRow: 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            let x = CGFloat(image.width / 2), y = CGFloat(image.height / 2)
            context.draw(image, in: CGRect(x: -x, y: -y, width: CGFloat(image.width), height: CGFloat(image.height)))
        }
        // JPEG round trips shift colours slightly; compare coarse buckets.
        return pixel.prefix(3).map { $0 / 32 }
    }
}

// MARK: - Fakes

/// Stands in for the on-device blur: returns a magenta image of the same pixel size (so it can never
/// equal the original's bytes) and records every input and output.
final class RecordingRedactor: @unchecked Sendable {
    private let lock = NSLock()
    private var produced: [FaceAndPlateBlur.Upload] = []
    private var inputs = 0

    var outputs: [Data] { lock.withLock { produced.map(\.jpegData) } }
    var inputCount: Int { lock.withLock { inputs } }
    var firstOutputImage: UIImage? { lock.withLock { produced.first?.result.image } }
    /// Largest pixel edge of any image handed to the redactor.
    var maxInputEdge: CGFloat { lock.withLock { largestEdge } }
    private var largestEdge: CGFloat = 0

    static func marker(for pixelSize: CGSize) -> UIImage {
        UploadRedactionTests.solidImage(.magenta, size: pixelSize)
    }

    var redact: @Sendable (UIImage) async -> FaceAndPlateBlur.Upload? {
        { [self] image in
            let pixels = CGSize(width: image.cgImage?.width ?? 1, height: image.cgImage?.height ?? 1)
            let output = Self.marker(for: pixels)
            guard let data = output.jpegData(compressionQuality: 0.8) else { return nil }
            let upload = FaceAndPlateBlur.Upload(jpegData: data,
                                                 result: FaceAndPlateBlur.Result(image: output, faceCount: 1, plateCount: 0))
            lock.withLock {
                inputs += 1
                largestEdge = max(largestEdge, pixels.width, pixels.height)
                produced.append(upload)
            }
            return upload
        }
    }
}

/// Records SAM requests by category (card outline) and by free-form concept (`segment_hazard`).
final class ConceptRecordingOutliner: HazardOutlining, @unchecked Sendable {
    private let lock = NSLock()
    private var byCategory: [Data] = []
    private var byConcept: [Data] = []

    var categoryCalls: [Data] { lock.withLock { byCategory } }
    var conceptCalls: [Data] { lock.withLock { byConcept } }

    func outline(jpegData: Data, category: ReportCategory) async throws -> SegmentOutline? {
        lock.withLock { byCategory.append(jpegData) }
        return SegmentOutline(concept: "playground equipment", boxes: [])
    }

    func outline(jpegData: Data, concept: String) async throws -> SegmentOutline? {
        lock.withLock { byConcept.append(jpegData) }
        return SegmentOutline(concept: concept, boxes: [])
    }
}

/// Records the before/after bytes a fix check sends.
final class RecordingVerifier: FixVerifying, @unchecked Sendable {
    let verdict: FixVerdict
    private let lock = NSLock()
    private var calls = 0
    private var lastBefore: Data?
    private var lastAfter: Data?

    init(verdict: FixVerdict) { self.verdict = verdict }

    var callCount: Int { lock.withLock { calls } }
    var before: Data? { lock.withLock { lastBefore } }
    var after: Data? { lock.withLock { lastAfter } }

    func verify(before: Data, after: Data, reportTitle: String, categoryRaw: String,
                beforeCapturedAt: Date) async throws -> FixVerdict {
        lock.withLock {
            calls += 1
            lastBefore = before
            lastAfter = after
        }
        return verdict
    }
}

/// Lets a fake redactor reach the model it was injected into (to simulate a mid-check reset).
@MainActor
final class ModelHolder {
    weak var model: FixCheckModel?
}
