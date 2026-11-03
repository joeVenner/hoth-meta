import HoTHCore
import SwiftData
import UIKit
import XCTest
@testable import HoTH

/// The capture log's blur evidence: every Meta request that carries a photo is preceded by the
/// `redaction` of exactly the bytes it sends, and its `meta_request` line comes before the request
/// actually reaches the network. Hermetic: Meta calls go to `VisionStubURLProtocol`, SAM and the fix
/// verifier are fakes that stamp the shared event sequence when called.
@MainActor
final class UploadAuditTests: XCTestCase {
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

    func testReportUploadsAreRedactedBeforeEachRequest() async throws {
        let events = AuditEventLog()
        VisionStubURLProtocol.onRequest = { body in
            // One photo: vision; two: the duplicate judge (new + existing).
            events.append(.network(VisionStubURLProtocol.jpegs(inBody: body).count == 2 ? "dedup" : "vision"))
        }
        let outliner = StampingOutliner(events: events)
        let flow = try makeFlow(audit: events.audit, outliner: outliner)
        _ = try insertExistingReport()

        await flow.submit(try livePhoto(), context: context)
        XCTAssertEqual(flow.step, .analysis)
        await flow.waitForOutline()
        let toolbox = try XCTUnwrap(flow.intakeToolbox(context: context, outliner: outliner))
        _ = await toolbox.run(FunctionCall(callID: "s", name: "segment_hazard", arguments: #"{"concept":"broken bin"}"#))

        let log = events.events
        let redactions = log.compactMap { if case .redaction(let r) = $0 { return r } else { return nil } }
        XCTAssertEqual(redactions.map(\.path), [.vision, .dedup], "the new photo once, the existing photo once")
        XCTAssertEqual(redactions.first?.faces, 1, "counts come from the redactor's result")
        XCTAssertEqual(redactions.first?.plates, 0)
        XCTAssertTrue(redactions.allSatisfy { $0.durationMs >= 0 && $0.uploadID.count == 8 })
        let visionID = try XCTUnwrap(redactions.first?.uploadID)
        let existingID = try XCTUnwrap(redactions.last?.uploadID)

        let requests = log.compactMap { if case .request(let path, let ids) = $0 { return (path, ids) } else { return nil } }
        XCTAssertEqual(Set(requests.map(\.0.rawValue)), ["vision", "sam", "dedup", "segment_hazard"])
        XCTAssertEqual(requests.first { $0.0 == .vision }?.1, [visionID])
        XCTAssertEqual(requests.first { $0.0 == .sam }?.1, [visionID], "SAM reuses the vision redaction")
        XCTAssertEqual(requests.first { $0.0 == .segmentHazard }?.1, [visionID])
        XCTAssertEqual(requests.first { $0.0 == .dedup }?.1, [visionID, existingID])

        try assertOrdered(log, requestPaths: [.vision: "vision", .sam: "sam", .dedup: "dedup",
                                              .segmentHazard: "segment_hazard"])
    }

    func testFixCheckRedactsBothPhotosBeforeTheVerifierAndSAM() async throws {
        let events = AuditEventLog()
        let verifier = StampingVerifier(events: events, verdict: FixVerdict(
            resolved: false, reasonEN: "Half", reasonAR: "نصف",
            remaining: [.init(label: "gravel", box: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))], isCanned: false))
        let outliner = StampingOutliner(events: events)
        let model = FixCheckModel(verifierFactory: { _ in verifier }, outlinerFactory: { outliner },
                                  redactor: RecordingRedactor().redact, audit: events.audit)
        await model.check(report: makeCrewReport(), after: UploadRedactionTests.solidImage(.gray, size: CGSize(width: 64, height: 64)),
                          demo: nil, context: context)
        await model.waitForOutline()
        XCTAssertEqual(model.phase, .verdict)

        let log = events.events
        let redactions = log.compactMap { if case .redaction(let r) = $0 { return r } else { return nil } }
        XCTAssertEqual(redactions.map(\.path), [.fixcheck, .fixcheck], "before + after")
        let requests = log.compactMap { if case .request(let path, let ids) = $0 { return (path, ids) } else { return nil } }
        XCTAssertEqual(requests.map(\.0), [.fixcheck, .sam])
        XCTAssertEqual(Set(requests[0].1), Set(redactions.map(\.uploadID)))
        XCTAssertEqual(requests[1].1.count, 1)
        XCTAssertTrue(redactions.map(\.uploadID).contains(requests[1].1[0]), "SAM sends one of the fix-check redactions")
        try assertOrdered(log, requestPaths: [.fixcheck: "fixcheck", .sam: "sam"])
    }

    func testNothingIsLoggedWhenNoPhotoIsSent() async throws {
        let events = AuditEventLog()
        // Failed redaction: no redaction line, no request line.
        let failing = try makeFlow(audit: events.audit, outliner: StampingOutliner(events: events), redactor: { _ in nil })
        await failing.submit(try livePhoto(), context: context)
        // Canned demo analysis (no key): nothing leaves the phone.
        let canned = try makeFlow(audit: events.audit, outliner: StampingOutliner(events: events), hasKey: false)
        let sample = DemoSamples.springRider
        await canned.submit(try CaptureService.makeCapturedPhoto(from: sample.loadImage(), capturedAt: Date(), gps: sample.gpsFix,
                                                                 source: .demoLibrary, demoSampleID: sample.id),
                            context: context)
        // Canned fix verdict: no upload blur, so no audit (the saved fix photo is blurred, not sent).
        let fix = FixCheckModel(verifierFactory: { CannedFixVerifier(photo: $0 ?? .good) }, outlinerFactory: { nil },
                                redactor: RecordingRedactor().redact, audit: events.audit)
        let report = makeCrewReport()
        await fix.check(report: report, after: UploadRedactionTests.solidImage(.gray, size: CGSize(width: 64, height: 64)),
                        demo: .good, context: context)
        if let name = report.fixPhotoFileName { savedFiles.append(name) }
        XCTAssertEqual(events.events, [])
    }

    func testCaptureLogFieldsCarryNoImageBytes() throws {
        let redaction = UploadAudit.Redaction(path: .segmentHazard, uploadID: "ab12cd34", faces: 2, plates: 1, durationMs: 41)
        XCTAssertEqual(CaptureLog.redactionFields(redaction), [
            "path": .string("segment_hazard"), "upload_id": .string("ab12cd34"),
            "faces": .number(2), "plates": .number(1), "ms": .number(41),
        ])
        XCTAssertEqual(CaptureLog.metaRequestFields(path: .vision, uploadIDs: ["ab12cd34"]), [
            "path": .string("vision"), "upload_ids": .array([.string("ab12cd34")]),
        ])
        XCTAssertNotEqual(UploadAudit.newUploadID(), UploadAudit.newUploadID())
    }

    // MARK: Helpers

    /// For each path: its `meta_request` comes after every redaction it names, and before the network event.
    private func assertOrdered(_ log: [AuditEventLog.Event], requestPaths: [UploadAudit.Path: String],
                               file: StaticString = #filePath, line: UInt = #line) throws {
        for (path, network) in requestPaths {
            let requestIndex = try XCTUnwrap(log.firstIndex {
                if case .request(path, _) = $0 { return true } else { return false }
            }, "no meta_request for \(path)", file: file, line: line)
            guard case .request(_, let ids) = log[requestIndex] else { continue }
            for id in ids {
                let redactionIndex = try XCTUnwrap(log.firstIndex {
                    if case .redaction(let r) = $0 { return r.uploadID == id } else { return false }
                }, "meta_request \(path) names an unknown redaction", file: file, line: line)
                XCTAssertLessThan(redactionIndex, requestIndex, "\(path) was requested before its redaction finished",
                                  file: file, line: line)
            }
            let networkIndex = try XCTUnwrap(log.firstIndex(of: .network(network)),
                                             "\(network) never reached the network", file: file, line: line)
            XCTAssertLessThan(requestIndex, networkIndex, "\(path) was sent before its meta_request line",
                              file: file, line: line)
        }
    }

    private func makeFlow(audit: UploadAudit, outliner: HazardOutlining?, hasKey: Bool = true,
                          redactor: (@Sendable (UIImage) async -> FaceAndPlateBlur.Upload?)? = nil) throws -> ReportFlowModel {
        let client = MetaModelClient(keyProvider: StaticTestKey(), session: VisionStubURLProtocol.makeSession(),
                                     baseURL: URL(string: "https://stub.invalid/v1")!)
        return ReportFlowModel(client: client, prompts: try Prompts(bundle: .main), language: { "en" },
                               isDemoMode: { true }, hasAPIKey: { hasKey }, outliner: { outliner },
                               redactor: redactor ?? RecordingRedactor().redact, audit: audit)
    }

    /// No demo sample id, so the duplicate judge runs.
    private func livePhoto() throws -> CapturedPhoto {
        let sample = DemoSamples.springRider
        return try CaptureService.makeCapturedPhoto(from: sample.loadImage(), capturedAt: Date(), gps: sample.gpsFix,
                                                    source: .demoLibrary, demoSampleID: nil)
    }

    /// An open report of the same category 5 m away, with a public photo for the judge.
    private func insertExistingReport() throws -> Report {
        let jpeg = try XCTUnwrap(UploadRedactionTests.solidImage(.blue, size: CGSize(width: 80, height: 60))
            .jpegData(compressionQuality: 0.9))
        let id = UUID().uuidString
        let original = try XCTUnwrap(ReportPhotoFiles.save(jpeg, named: "test_\(id).jpg"))
        let publicName = try XCTUnwrap(ReportPhotoFiles.save(jpeg, named: "test_\(id)_public.jpg"))
        savedFiles += [original, publicName]
        let fix = DemoSamples.springRider.gpsFix
        let report = Report(category: .playgroundEquipment, titleEN: "Broken spring rider", titleAR: "لعبة مكسورة",
                            summaryEN: "Spring rider broken", summaryAR: "", latitude: fix.latitude + 5 / 111_000,
                            longitude: fix.longitude, placeName: "Park", photoFileName: original,
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
}

// MARK: - Fakes

/// One ordered sequence shared by the audit, the stub network and the fake models.
final class AuditEventLog: @unchecked Sendable {
    enum Event: Equatable {
        case redaction(UploadAudit.Redaction)
        case request(UploadAudit.Path, [String])
        case network(String)
    }

    private let lock = NSLock()
    private var recorded: [Event] = []

    var events: [Event] { lock.withLock { recorded } }
    func append(_ event: Event) { lock.withLock { recorded.append(event) } }

    var audit: UploadAudit {
        UploadAudit(redacted: { [self] in append(.redaction($0)) },
                    request: { [self] path, ids in append(.request(path, ids)) })
    }
}

/// SAM fake that stamps `network("sam")` / `network("segment_hazard")` when called.
final class StampingOutliner: HazardOutlining, @unchecked Sendable {
    let events: AuditEventLog
    init(events: AuditEventLog) { self.events = events }

    func outline(jpegData: Data, category: ReportCategory) async throws -> SegmentOutline? {
        events.append(.network("sam"))
        return SegmentOutline(concept: "playground equipment", boxes: [])
    }

    func outline(jpegData: Data, concept: String) async throws -> SegmentOutline? {
        events.append(.network("segment_hazard"))
        return SegmentOutline(concept: concept, boxes: [])
    }
}

/// Fix verifier fake that stamps `network("fixcheck")` when called.
final class StampingVerifier: FixVerifying, @unchecked Sendable {
    let events: AuditEventLog
    let verdict: FixVerdict
    init(events: AuditEventLog, verdict: FixVerdict) {
        self.events = events
        self.verdict = verdict
    }

    func verify(before: Data, after: Data, reportTitle: String, categoryRaw: String,
                beforeCapturedAt: Date) async throws -> FixVerdict {
        events.append(.network("fixcheck"))
        return verdict
    }
}
