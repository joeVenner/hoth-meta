import Foundation

/// Classifies one live photo with the `vision_analyze` prompt from prompts.json.
public struct VisionAnalyzer: Sendable {
    private let client: MetaModelClient
    private let prompts: Prompts
    private let modelOverride: String?

    /// - Parameter model: optional model id (e.g. the Settings override); blank or nil falls back to
    ///   `prompts.models.vision`.
    public init(client: MetaModelClient, prompts: Prompts, model: String? = nil) {
        self.client = client
        self.prompts = prompts
        self.modelOverride = model
    }

    /// The model actually sent to the API.
    public var model: String { Prompts.resolveVisionModel(override: modelOverride, prompts: prompts) }

    /// - Parameters:
    ///   - imageData: JPEG bytes (the app downsizes to <= 1024 px before calling).
    ///   - language: resident language hint, e.g. "en", "ar-khaleeji".
    public func analyze(
        imageData: Data,
        language: String,
        capturedAt: Date = Date(),
        placeHint: String = "unknown",
        userNote: String = ""
    ) async throws -> VisionAnalysis {
        let spec = prompts.visionAnalyze
        guard let schema = spec.jsonSchema else { throw ModelAPIError.decoding("vision_analyze has no json_schema") }
        let values = [
            "user_language": language,
            "captured_at": ISO8601DateFormatter().string(from: capturedAt),
            "place_hint": placeHint,
            "user_note": userNote
        ]
        return try await client.structured(
            model: model,
            system: Prompts.fill(spec.system, values),
            user: Prompts.fill(spec.userTemplate, values),
            images: [ImageInput(jpegData: imageData)],
            schema: schema,
            as: VisionAnalysis.self
        )
    }
}
