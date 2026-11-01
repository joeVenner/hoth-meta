import Foundation
import XCTest
@testable import HoTHCore

enum Fixtures {
    static func data(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Resources"),
            "Missing fixture \(name).json")
        return try Data(contentsOf: url)
    }

    /// The real app prompts file (single source of truth), located relative to this test file.
    static func appPromptsData() throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // HoTHCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // HoTHCore
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // ios
            .appendingPathComponent("HoTH/Resources/prompts.json")
        return try Data(contentsOf: url)
    }

    static func prompts() throws -> Prompts { try Prompts(data: appPromptsData()) }

    /// Wraps a model JSON payload in a recorded Responses API envelope.
    static func responsesEnvelope(payload: Data) throws -> Data {
        let template = try String(decoding: data("responses_envelope"), as: UTF8.self)
        let escaped = try String(decoding: JSONEncoder().encode(String(decoding: payload, as: UTF8.self)), as: UTF8.self)
        // `escaped` includes surrounding quotes; the template already has them.
        let inner = String(escaped.dropFirst().dropLast())
        return Data(template.replacingOccurrences(of: "__PAYLOAD__", with: inner).utf8)
    }
}

struct StaticKey: APIKeyProvider {
    let key: String
    func apiKey() async throws -> String { key }
}

struct FailingKey: APIKeyProvider {
    struct NoKey: Error {}
    func apiKey() async throws -> String { throw NoKey() }
}

/// Hermetic network stub: every request is answered by `handler`.
final class StubURLProtocol: URLProtocol {
    struct Captured {
        let request: URLRequest
        let body: Data
    }

    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var captured: [Captured] = []
    /// When set, the request fails with this error instead of calling `handler` (reset it after use).
    nonisolated(unsafe) static var failure: URLError?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.readBody(request)
        Self.captured.append(Captured(request: request, body: body))
        if let failure = Self.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let (status, data) = Self.handler?(request) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// Inside URLProtocol the body arrives as a stream, not `httpBody`.
    static func readBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }
}

func makeVision(
    category: ReportCategory = .other,
    hazards: [HazardKind] = [],
    childUseEquipment: Bool = false,
    childPresent: Bool = false,
    scene: SceneType = .other,
    proposal: Severity = .low,
    showsIssue: Bool = true,
    screen: Bool = false,
    stock: Bool = false
) -> VisionAnalysis {
    VisionAnalysis(
        category: category,
        hazards: hazards.map { Hazard(label: $0.rawValue, kind: $0, box: NormalizedBox(x: 0.1, y: 0.1, w: 0.2, h: 0.2)) },
        childUseEquipment: childUseEquipment,
        childPresent: childPresent,
        sceneType: scene,
        severityProposal: proposal,
        plausibility: PlausibilitySignals(showsReportedIssue: showsIssue, looksLikeScreenOrPrint: screen,
                                          looksLikeStockOrWatermarked: stock, notes: ""))
}
