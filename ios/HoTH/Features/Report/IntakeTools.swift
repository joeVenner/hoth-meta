import Foundation
import HoTHCore
import OSLog

/// An open report near the capture, as the intake agent sees it. No reporter, comments or photos.
struct NearbyReportSummary: Equatable, Sendable {
    let id: UUID
    let category: String
    let titleEN: String
    let titleAR: String
    let distanceMeters: Int
    let confirmations: Int
    let status: String
}

/// What the phone knows about the place around the photo, for `get_place_context`.
struct PlaceContextSummary: Equatable, Sendable {
    /// The on-device MapKit POI within 100 m; nil when none was found or the lookup did not run
    /// (simulator, demo mode, no GPS fix).
    let nearbyPlace: LocationType?
    let sceneType: SceneType
    let childUseEquipment: Bool
}

/// The intake agent's function tools (prompts.json `intake_agent.tools`), run on the phone.
///
/// Every call returns a JSON string, errors included, so each `function_call` always gets its
/// `function_call_output`. Arguments are model-written and untrusted: they are clamped or refused here.
@MainActor
final class IntakeToolbox {
    enum Activity: Equatable {
        case nearbyReports, segmenting, placeContext
    }

    static let radiusRange = 10...500
    static let defaultRadius = 100
    static let maxReports = 5

    private let specs: [FunctionTool]
    private let nearbyReports: (Int) -> [NearbyReportSummary]
    private let placeContext: () -> PlaceContextSummary
    private let segment: ((String) async throws -> SegmentOutline?)?
    /// Report ids `find_nearby_reports` handed to the model; only these may be confirmed from the chat.
    private(set) var offeredReportIDs: Set<UUID> = []
    private var segmentCache: [String: String] = [:]
    private static let logger = Logger(subsystem: "io.fomy.hoth", category: "IntakeTools")

    /// - Parameters:
    ///   - specs: tool definitions from prompts.json.
    ///   - nearbyReports: open reports within the radius (metres), nearest first.
    ///   - segment: SAM on the analysed photo; nil (no key, UI tests) leaves `segment_hazard` out of `tools`.
    init(specs: [FunctionTool],
         nearbyReports: @escaping (Int) -> [NearbyReportSummary],
         placeContext: @escaping () -> PlaceContextSummary,
         segment: ((String) async throws -> SegmentOutline?)?) {
        self.specs = specs
        self.nearbyReports = nearbyReports
        self.placeContext = placeContext
        self.segment = segment
    }

    /// The tools this phone can actually run right now.
    var tools: [FunctionTool] {
        specs.filter { $0.name != "segment_hazard" || segment != nil }
    }

    static func activity(for name: String) -> Activity? {
        switch name {
        case "find_nearby_reports": return .nearbyReports
        case "segment_hazard": return .segmenting
        case "get_place_context": return .placeContext
        default: return nil
        }
    }

    func run(_ call: FunctionCall) async -> String {
        guard tools.contains(where: { $0.name == call.name }) else {
            return Self.error("unknown tool \(call.name)")
        }
        guard let arguments = call.argumentsObject else {
            return Self.error("arguments are not a JSON object")
        }
        switch call.name {
        case "find_nearby_reports":
            return findNearbyReports(arguments)
        case "segment_hazard":
            return await segmentHazard(arguments)
        case "get_place_context":
            return placeContextJSON()
        default:
            return Self.error("unknown tool \(call.name)")
        }
    }

    // MARK: Tools

    private func findNearbyReports(_ arguments: [String: JSONValue]) -> String {
        let radius = Self.clampedRadius(arguments["radius_m"])
        let reports = Array(nearbyReports(radius).prefix(Self.maxReports))
        offeredReportIDs.formUnion(reports.map(\.id))
        let items: [JSONValue] = reports.map { report in
            .object([
                "id": .string(report.id.uuidString),
                "category": .string(report.category),
                "title_en": .string(report.titleEN),
                "title_ar": .string(report.titleAR),
                "distance_m": .number(Double(report.distanceMeters)),
                "confirmations": .number(Double(report.confirmations)),
                "status": .string(report.status)
            ])
        }
        return Self.encode(.object(["radius_m": .number(Double(radius)), "reports": .array(items)]))
    }

    private func segmentHazard(_ arguments: [String: JSONValue]) async -> String {
        guard let segment else { return Self.error("segmentation unavailable") }
        guard let raw = arguments["concept"]?.stringValue,
              let concept = HazardSegmenter.sanitizedConcept(raw) else {
            return Self.error("concept must be a short noun phrase (1-4 words)")
        }
        // Each call is a paid SAM request (up to 20 s); never repeat one.
        let key = concept.lowercased()
        if let cached = segmentCache[key] { return cached }
        let result: String
        do {
            if let outline = try await segment(concept) {
                let boxes: [JSONValue] = outline.boxes.map { box in
                    .object(["x": .number(Self.rounded(box.x)), "y": .number(Self.rounded(box.y)),
                             "w": .number(Self.rounded(box.w)), "h": .number(Self.rounded(box.h))])
                }
                result = Self.encode(.object(["concept": .string(outline.concept),
                                              "count": .number(Double(outline.boxes.count)),
                                              "boxes": .array(boxes)]))
            } else {
                result = Self.error("concept refused")
            }
        } catch {
            Self.logger.error("segment_hazard failed: \(String(describing: error))")
            result = Self.error("segmentation failed or timed out")
        }
        segmentCache[key] = result
        return result
    }

    private func placeContextJSON() -> String {
        let context = placeContext()
        return Self.encode(.object([
            // Honest about a lookup that found nothing or never ran.
            "nearby_place": .string(context.nearbyPlace?.rawValue ?? "none_found"),
            "lookup_radius_m": .number(NearbyPlaces.searchRadius),
            "scene_type": .string(context.sceneType.rawValue),
            "child_use_equipment": .bool(context.childUseEquipment)
        ]))
    }

    // MARK: Helpers

    static func clampedRadius(_ value: JSONValue?) -> Int {
        let requested: Int
        switch value {
        case .number(let number) where number.isFinite:
            // Clamp before converting: `Int(_:)` traps on a finite Double outside Int's range (e.g. 1e30).
            let clamped = min(max(number, Double(radiusRange.lowerBound)), Double(radiusRange.upperBound))
            requested = Int(clamped.rounded())
        case .string(let text): requested = Int(text) ?? defaultRadius
        default: requested = defaultRadius
        }
        return min(max(requested, radiusRange.lowerBound), radiusRange.upperBound)
    }

    private static func rounded(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }

    static func error(_ message: String) -> String {
        encode(.object(["error": .string(message)]))
    }

    private static func encode(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return #"{"error":"encoding failed"}"# }
        return String(decoding: data, as: UTF8.self)
    }
}
