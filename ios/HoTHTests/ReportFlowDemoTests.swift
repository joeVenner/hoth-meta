import HoTHCore
import SwiftData
import XCTest
@testable import HoTH

/// Demo merge rule and interview-step routing (offline: no key, canned analyses, in-memory store).
@MainActor
final class ReportFlowDemoTests: XCTestCase {
    private struct NoKeyProvider: APIKeyProvider {
        func apiKey() async throws -> String { throw OpenAIError.missingKey }
    }

    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    override func setUp() async throws {
        container = try HoTHStore.makeContainer(inMemory: true)
    }

    override func tearDown() async throws {
        container = nil
    }

    private func makeFlow() throws -> ReportFlowModel {
        ReportFlowModel(client: OpenAIClient(keyProvider: NoKeyProvider()), prompts: try Prompts(bundle: .main),
                        language: { "en" }, isDemoMode: { true }, hasAPIKey: { false })
    }

    private func photo(_ sample: DemoSample) throws -> CapturedPhoto {
        try CaptureService.makeCapturedPhoto(from: sample.loadImage(), capturedAt: Date(), gps: sample.gpsFix,
                                             source: .demoLibrary, demoSampleID: sample.id)
    }

    @discardableResult
    private func insertReport(category: IssueCategory, at coordinate: Coordinate, photo: String?,
                              isDemoSeed: Bool, status: ReportStatus = .open) -> Report {
        let report = Report(category: category, titleEN: "Existing", titleAR: "موجود", summaryEN: "Existing",
                            summaryAR: "موجود", latitude: coordinate.latitude, longitude: coordinate.longitude,
                            placeName: "Test", photoFileName: photo, priority: .medium, priorityScore: 50,
                            priorityReasonEN: "", priorityReasonAR: "", status: status, isPosted: true,
                            isDemoSeed: isDemoSeed)
        context.insert(report)
        try? context.save()
        return report
    }

    // MARK: Merge policy

    func testOnlyThePotholeIsTheDuplicateDemo() {
        XCTAssertEqual(DemoSamples.all.filter(\.isDuplicateDemo).map(\.id), ["pothole"])
        XCTAssertEqual(ReportFlowModel.mergePolicy(demoSampleID: "pothole"), .intoDuplicateDemoSeed)
        XCTAssertEqual(ReportFlowModel.mergePolicy(demoSampleID: "spring_rider"), .never)
        XCTAssertEqual(ReportFlowModel.mergePolicy(demoSampleID: "unknown_sample"), .never)
        XCTAssertEqual(ReportFlowModel.mergePolicy(demoSampleID: nil), .judged)
    }

    func testDemoSamplesSitAwayFromSeededReports() throws {
        struct Seed: Decodable { let latitude: Double; let longitude: Double; let photo: String? }
        struct File: Decodable { let reports: [Seed] }
        let url = try XCTUnwrap(Bundle.main.url(forResource: "seed", withExtension: "json"))
        let seeds = try JSONDecoder().decode(File.self, from: Data(contentsOf: url)).reports
        var points = seeds.map { Coordinate(latitude: $0.latitude, longitude: $0.longitude) }
        points.append(Coordinate(latitude: 24.4234, longitude: 54.5762))  // neighbour-alert demo report
        XCTAssertGreaterThanOrEqual(DemoSamples.all.count, 8)
        for sample in DemoSamples.all where !sample.isDuplicateDemo {
            let nearest = points.map { Dedup.haversineMeters(sample.coordinate, $0) }.min() ?? .infinity
            XCTAssertGreaterThanOrEqual(nearest, 200, "\(sample.id) is \(Int(nearest)) m from a seeded report")
            XCTAssertFalse(sample.demoLabelEN.isEmpty || sample.demoLabelAR.isEmpty, "\(sample.id) label")
        }
        let r10 = try XCTUnwrap(seeds.first { $0.photo == DemoSamples.duplicateDemoSeedPhoto })
        let distance = Dedup.haversineMeters(DemoSamples.pothole.coordinate,
                                             Coordinate(latitude: r10.latitude, longitude: r10.longitude))
        XCTAssertLessThanOrEqual(distance, Dedup.radiusMeters)
    }

    func testDuplicateDemoMergesIntoSeededR10() async throws {
        let r10 = insertReport(category: .potholePavement, at: Coordinate(latitude: 24.4183, longitude: 54.5803),
                               photo: DemoSamples.duplicateDemoSeedPhoto, isDemoSeed: true)
        let flow = try makeFlow()
        await flow.submit(try photo(DemoSamples.pothole), context: context)
        guard case .duplicate(let outcome) = flow.step else { return XCTFail("Expected a merge, got \(flow.step)") }
        XCTAssertEqual(outcome.reportID, r10.id)
        XCTAssertEqual(r10.confirmations, 1)
    }

    func testOtherDemoSamplesNeverMerge() async throws {
        let sample = DemoSamples.springRider
        // A seeded report and the resident's own earlier take, both at the sample's exact spot.
        insertReport(category: .playgroundEquipment, at: sample.coordinate, photo: "seed_1", isDemoSeed: true)
        insertReport(category: .playgroundEquipment, at: sample.coordinate, photo: nil, isDemoSeed: false)
        let flow = try makeFlow()
        await flow.submit(try photo(sample), context: context)
        XCTAssertEqual(flow.step, .analysis)
    }

    func testFakeScreenSampleIsRejected() async throws {
        let flow = try makeFlow()
        await flow.submit(try photo(DemoSamples.fakeScreen), context: context)
        guard case .needsRetake = flow.step else { return XCTFail("Expected a retake, got \(flow.step)") }
    }

    // MARK: Interview routing

    func testInterviewStartsWithVoiceByDefault() {
        XCTAssertEqual(InterviewStepView.initialMode(prefersVoice: true, isUITestRun: false), .talk)
        XCTAssertEqual(InterviewStepView.initialMode(prefersVoice: false, isUITestRun: false), .type)
        XCTAssertEqual(InterviewStepView.initialMode(prefersVoice: true, isUITestRun: true), .type)
    }

    func testSafetySheetResumesIntoInterview() async throws {
        let flow = try makeFlow()
        await flow.submit(try photo(DemoSamples.openManhole), context: context)
        XCTAssertEqual(flow.step, .analysis)
        flow.continueFromAnalysis()
        XCTAssertEqual(flow.safetyAlert?.resumesInterview, true)
        XCTAssertEqual(flow.step, .analysis, "The interview must not start behind the safety sheet")
        flow.continueAfterSafety()
        XCTAssertNil(flow.safetyAlert)
        XCTAssertEqual(flow.step, .interview)
    }

    func testSwipingSafetySheetAwayStillReachesInterview() async throws {
        let flow = try makeFlow()
        await flow.submit(try photo(DemoSamples.exposedWire), context: context)
        flow.continueFromAnalysis()
        XCTAssertNotNil(flow.safetyAlert)
        flow.safetyAlert = nil  // what a swipe-down does to the binding
        flow.safetySheetDismissed()
        XCTAssertEqual(flow.step, .interview)
    }

    func testNonCriticalGoesStraightToInterview() async throws {
        let flow = try makeFlow()
        await flow.submit(try photo(DemoSamples.waste), context: context)
        flow.continueFromAnalysis()
        XCTAssertNil(flow.safetyAlert)
        XCTAssertEqual(flow.step, .interview)
    }

    func testMergedDuplicateCanAddVoiceNote() async throws {
        let r10 = insertReport(category: .potholePavement, at: Coordinate(latitude: 24.4183, longitude: 54.5803),
                               photo: DemoSamples.duplicateDemoSeedPhoto, isDemoSeed: true)
        let flow = try makeFlow()
        await flow.submit(try photo(DemoSamples.pothole), context: context)
        guard case .duplicate(let outcome) = flow.step else { return XCTFail("Expected a merge") }
        flow.addVoiceNote(to: outcome)
        XCTAssertEqual(flow.step, .interview)
        flow.interviewCompleted(SubmitReportArgs(summaryEN: "It is in the left lane", summaryAR: "في المسار الأيسر",
                                                 answers: [:], userLanguage: "en", wantsToPost: true,
                                                 anonymous: false), context: context)
        guard case .duplicate(let updated) = flow.step else { return XCTFail("Expected back on the merge screen") }
        XCTAssertTrue(updated.hasVoiceNote)
        XCTAssertEqual(r10.comments.map(\.text), ["It is in the left lane"])
    }
}
