import Foundation
import HoTHCore
import OSLog

/// Model output for the prompts.json `moderation` spec (strict schema: decision + reason).
struct ModerationVerdict: Decodable, Equatable {
    let decision: String
    let reason: String

    var status: ModerationStatus { decision.lowercased() == "block" ? .blocked : .allowed }
}

// MARK: - Local checks

/// Offline moderation: blocks personal data (emails, phone numbers) and a tiny list of obvious
/// slurs/insults. Everything else is allowed; the AI moderator handles nuance when online.
struct LocalCommentModerator: CommentModerator {
    /// Deliberately tiny and unambiguous: words with innocent street meanings (e.g. "dog") are excluded.
    static let blockedWords: Set<String> = [
        "idiot", "idiots", "moron", "morons", "retard", "retarded", "bitch", "bastard", "fuck", "fucking",
        "غبي", "اغبياء", "أغبياء", "حمار", "حمير", "تافه", "حقير", "يلعن",
    ]

    private static let emailRegex = try! NSRegularExpression(
        pattern: #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#, options: [.caseInsensitive])
    /// 8+ digits, optionally led by "+" and separated by spaces, dots or dashes (UAE mobiles are 9-12 digits).
    private static let phoneRegex = try! NSRegularExpression(pattern: #"\+?\d(?:[\s.\-]?\d){7,}"#)

    static func check(_ text: String) -> ModerationStatus {
        let normalized = normalizeDigits(text)
        let range = NSRange(normalized.startIndex..., in: normalized)
        if emailRegex.firstMatch(in: normalized, range: range) != nil { return .blocked }
        if phoneRegex.firstMatch(in: normalized, range: range) != nil { return .blocked }
        let words = normalized.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
        if words.contains(where: { blockedWords.contains($0) }) { return .blocked }
        return .allowed
    }

    /// Maps Arabic-Indic (٠-٩) and Eastern Arabic-Indic (۰-۹) digits to ASCII so phone checks see them.
    static func normalizeDigits(_ text: String) -> String {
        String(text.unicodeScalars.map { scalar -> Character in
            switch scalar.value {
            case 0x0660...0x0669: return Character(UnicodeScalar(scalar.value - 0x0660 + 0x30)!)
            case 0x06F0...0x06F9: return Character(UnicodeScalar(scalar.value - 0x06F0 + 0x30)!)
            default: return Character(scalar)
            }
        })
    }

    func moderate(_ text: String, reportTitle: String) async -> ModerationStatus {
        Self.check(text)
    }
}

// MARK: - OpenAI moderator

/// P1-06: local checks first (no call when they already block), then the `moderation` prompt.
/// Missing key, offline or any API error falls back to the local verdict (allow).
struct OpenAICommentModerator: CommentModerator {
    let client: OpenAIClient
    let prompts: Prompts
    let hasKey: @Sendable () -> Bool

    private static let logger = Logger(subsystem: "io.fomy.hoth", category: "Moderation")

    func moderate(_ text: String, reportTitle: String) async -> ModerationStatus {
        let local = LocalCommentModerator.check(text)
        guard local == .allowed, hasKey() else { return local }
        let spec = prompts.moderation
        guard let schema = spec.jsonSchema else { return local }
        let values = ["report_title": reportTitle, "comment": text]
        do {
            let verdict = try await client.structured(
                model: prompts.models.text,
                system: Prompts.fill(spec.system, values),
                user: Prompts.fill(spec.userTemplate, values),
                schema: schema,
                as: ModerationVerdict.self
            )
            Self.logger.info("Moderation \(verdict.decision, privacy: .public): \(verdict.reason, privacy: .public)")
            return verdict.status
        } catch {
            Self.logger.error("Moderation fell back to local checks: \(String(describing: error), privacy: .public)")
            return local
        }
    }
}

extension OpenAICommentModerator {
    /// App moderator: local-only in UI-test runs (no live calls), else OpenAI-backed.
    @MainActor
    static func live() -> CommentModerator {
        if AppServices.isUITestRun { return LocalCommentModerator() }
        let services = AppServices.shared
        let provider = services.keyProvider
        return OpenAICommentModerator(client: services.openAI, prompts: services.prompts,
                                      hasKey: { provider.currentKey() != nil })
    }
}
