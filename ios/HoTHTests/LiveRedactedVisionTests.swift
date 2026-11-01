import HoTHCore
import SwiftData
import UIKit
import XCTest
@testable import HoTH

/// Live check (real Muse Spark calls) that the blurred-before-upload path still reads the spring
/// rider demo photo right: playground_equipment + sharp_edge + child_use_equipment on every run.
///
/// Skipped unless `TEST_RUNNER_HOTH_LIVE_REDACTED=1` and `TEST_RUNNER_META_API_KEY` are set (the
/// runner sees them without the prefix). Optional `TEST_RUNNER_HOTH_LIVE_RUNS` (default 5) and
/// `TEST_RUNNER_HOTH_LIVE_OUT` (a host JSONL path for per-run results). The key is never logged.
@MainActor
final class LiveRedactedVisionTests: XCTestCase {
    private struct EnvironmentKey: APIKeyProvider {
        let key: String
        func apiKey() async throws -> String { key }
    }

    func testSpringRiderThroughTheBlurredPath() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["HOTH_LIVE_REDACTED"] == "1", "Live: set TEST_RUNNER_HOTH_LIVE_REDACTED=1")
        let key = try XCTUnwrap(environment["META_API_KEY"].flatMap { $0.isEmpty ? nil : $0 },
                                "Set TEST_RUNNER_META_API_KEY")
        let runs = Int(environment["HOTH_LIVE_RUNS"] ?? "") ?? 5
        let outURL = environment["HOTH_LIVE_OUT"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }

        let container = try HoTHStore.makeContainer(inMemory: true)
        let client = MetaModelClient(keyProvider: EnvironmentKey(key: key))
        let prompts = try Prompts(bundle: .main)
        let sample = DemoSamples.springRider
        var failures: [String] = []

        for run in 1...runs {
            // Times the redactor separately from the whole submit (redaction + vision + dedup).
            let timing = RedactionTiming()
            let flow = ReportFlowModel(client: client, prompts: prompts, language: { "en" }, isDemoMode: { true },
                                       hasAPIKey: { true }, outliner: { nil },
                                       redactor: { image in await timing.measure(image) })
            let photo = try CaptureService.makeCapturedPhoto(from: sample.loadImage(), capturedAt: Date(),
                                                             gps: sample.gpsFix, source: .demoLibrary,
                                                             demoSampleID: sample.id)
            let started = Date()
            await flow.submit(photo, context: container.mainContext)
            let total = Date().timeIntervalSince(started)

            let analysis = flow.analysis
            let category = analysis?.category.rawValue ?? "none"
            let kinds = analysis?.hazards.map(\.kind.rawValue) ?? []
            let childEquipment = analysis?.childUseEquipment ?? false
            let isLive = !flow.isDemoAnalysis
            let passed = isLive && category == "playground_equipment" && kinds.contains("sharp_edge") && childEquipment
            if !passed { failures.append("run \(run): live=\(isLive) \(category) \(kinds) child=\(childEquipment)") }

            let record: [String: Any] = [
                "run": run, "live": isLive, "category": category, "hazard_kinds": kinds,
                "child_use_equipment": childEquipment, "priority": flow.priority?.level.rawValue ?? "none",
                "redaction_s": timing.seconds, "faces": timing.faces, "plates": timing.plates,
                "submit_total_s": total, "passed": passed,
            ]
            append(record, to: outURL)
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    private func append(_ record: [String: Any], to url: URL?) {
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        print("LIVE_REDACTED " + String(decoding: data, as: UTF8.self))
        guard let url else { return }
        var line = data
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url)
        }
    }
}

/// Wraps the production redactor and records how long it took and what it found.
private final class RedactionTiming: @unchecked Sendable {
    private let lock = NSLock()
    private var elapsed = 0.0
    private var faceCount = 0
    private var plateCount = 0

    var seconds: Double { lock.withLock { elapsed } }
    var faces: Int { lock.withLock { faceCount } }
    var plates: Int { lock.withLock { plateCount } }

    func measure(_ image: UIImage) async -> FaceAndPlateBlur.Upload? {
        let started = Date()
        let upload = await ReportFlowModel.redactForUpload(image)
        let took = Date().timeIntervalSince(started)
        lock.withLock {
            elapsed += took
            faceCount += upload?.result.faceCount ?? 0
            plateCount += upload?.result.plateCount ?? 0
        }
        return upload
    }
}
