import Foundation
import HoTHCore
import OSLog

/// One chat bubble.
struct ChatBubble: Identifiable, Equatable {
    enum Role { case assistant, resident }

    let id = UUID()
    let role: Role
    let text: String
}

/// Text quick-chat intake (P0-15).
///
/// Uses the `chat_intake` prompt through `MetaModelClient` when a key is available; on a missing key or
/// any API/network error it switches, mid-conversation if needed, to a deterministic local flow that
/// asks the category's slot questions in order, reads back, and asks about posting.
@MainActor
final class ChatIntakeModel: ObservableObject {
    enum Mode { case model, local }

    private enum LocalPhase: Equatable {
        case asking(Int)
        case confirming
        case correcting
        case askingPost
        case finished
    }

    @Published private(set) var bubbles: [ChatBubble] = []
    @Published private(set) var quickReplies: [String] = []
    @Published private(set) var isThinking = false
    @Published private(set) var mode: Mode
    @Published private(set) var isFinished = false

    let context: InterviewContext
    private let slots: [SlotQuestion]
    private let client: MetaModelClient?
    private let prompts: Prompts
    private let onComplete: (SubmitReportArgs) -> Void
    private let onUrgent: (String) -> Void

    private var answers: [String: String] = [:]
    private var phase: LocalPhase = .asking(0)
    private static let logger = Logger(subsystem: "io.fomy.hoth", category: "ChatIntake")

    init(context: InterviewContext, slots: [SlotQuestion], client: MetaModelClient?, prompts: Prompts,
         onComplete: @escaping (SubmitReportArgs) -> Void, onUrgent: @escaping (String) -> Void) {
        self.context = context
        self.slots = Array(slots.prefix(2))
        self.client = client
        self.prompts = prompts
        self.onComplete = onComplete
        self.onUrgent = onUrgent
        self.mode = client == nil ? .local : .model
    }

    private var arabic: Bool { context.isArabic }

    // MARK: Public

    func start() {
        guard bubbles.isEmpty else { return }
        switch mode {
        case .model:
            Task { await sendToModel(userMessage: arabic ? "(ابدأ المحادثة)" : "(start the conversation)", echo: false) }
        case .local:
            startLocal()
        }
    }

    func send(_ rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isThinking, !isFinished else { return }
        switch mode {
        case .model:
            Task { await sendToModel(userMessage: text, echo: true) }
        case .local:
            appendResident(text)
            handleLocal(text)
        }
    }

    // MARK: Local deterministic flow

    private func startLocal() {
        let intro = arabic
            ? "أنا المساعد الذكي في HoTH. شكراً إنك انتبهت 🙏 أشوف: \(context.analysis.titleAR)."
            : "I'm HoTH's AI assistant. Thanks for looking out for your neighbours 🙏 I can see: \(context.analysis.titleEN)."
        appendAssistant(intro)
        if slots.isEmpty {
            phase = .confirming
            askConfirmation()
        } else {
            phase = .asking(0)
            askSlot(0)
        }
    }

    private func handleLocal(_ text: String) {
        switch phase {
        case .asking(let index):
            let slot = slots[index]
            answers[slot.id] = text
            if isUrgent(slot: slot, answer: text) {
                // "slot_id: answer" pairs let the flow keep every answer for the priority floors.
                finishUrgent(reason: answers.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "; "))
                return
            }
            let next = index + 1
            if next < slots.count {
                phase = .asking(next)
                askSlot(next)
            } else {
                phase = .confirming
                askConfirmation()
            }
        case .confirming:
            if AnswerParsing.isAffirmative(text) {
                phase = .askingPost
                askPost()
            } else {
                phase = .correcting
                quickReplies = []
                appendAssistant(arabic ? "ولا يهمك — شو أصحّح؟" : "No problem — what should I change?")
            }
        case .correcting:
            answers["correction"] = text
            phase = .askingPost
            askPost()
        case .askingPost:
            let choice = postChoice(from: text)
            phase = .finished
            finish(wantsToPost: choice.post, anonymous: choice.anonymous)
        case .finished:
            break
        }
    }

    private func askSlot(_ index: Int) {
        let slot = slots[index]
        appendAssistant(arabic ? slot.ar : slot.en)
        quickReplies = arabic ? ["إي", "لا", "مب متأكد"] : ["Yes", "No", "Not sure"]
    }

    private func askConfirmation() {
        appendAssistant(readBack())
        quickReplies = arabic ? ["إي، صح", "لا"] : ["Yes, that's right", "No"]
    }

    private func askPost() {
        appendAssistant(arabic
            ? "تبي تنشره لأهل الحي عشان ينتبهون؟"
            : "Do you want to post it to your neighbourhood so others stay careful?")
        quickReplies = arabic ? ["انشره", "انشره بدون اسم", "لا تنشره"] : ["Post it", "Post anonymously", "Don't post"]
    }

    private func readBack() -> String {
        let details = answeredDetails(arabic: arabic)
        if arabic {
            return "خلني أتأكد: \(context.analysis.titleAR)\(details.isEmpty ? "" : " — \(details)"). صح؟"
        }
        return "Let me read that back: \(context.analysis.titleEN)\(details.isEmpty ? "" : " — \(details)"). Is that right?"
    }

    private func answeredDetails(arabic: Bool) -> String {
        slots.compactMap { slot -> String? in
            guard let answer = answers[slot.id] else { return nil }
            return "\(arabic ? slot.ar : slot.en) \(answer)"
        }
        .joined(separator: arabic ? "، " : "; ")
    }

    private func postChoice(from text: String) -> (post: Bool, anonymous: Bool) {
        let lowered = text.lowercased()
        let declines = ["don't", "dont", "no", "لا تنشر", "لا"]
        if declines.contains(where: { lowered.hasPrefix($0) }) { return (false, false) }
        let anonymous = lowered.contains("anonym") || lowered.contains("بدون اسم")
        return (true, anonymous)
    }

    private func isUrgent(slot: SlotQuestion, answer: String) -> Bool {
        switch slot.urgentIf {
        case "always": return true
        case "yes": return AnswerParsing.isAffirmative(answer)
        default: return false
        }
    }

    private func finishUrgent(reason: String) {
        quickReplies = []
        appendAssistant(arabic
            ? "سلامتكم أهم شي. لا تلمسها وخلّ الأطفال بعيد. سجّلت البلاغ كعاجل."
            : "Your safety comes first. Please don't touch it and keep children away. I've marked this as urgent.")
        isFinished = true
        onUrgent(reason)
    }

    private func finish(wantsToPost: Bool, anonymous: Bool) {
        quickReplies = []
        appendAssistant(arabic ? "تمام، جهّزت التذكرة. شكراً لك 💛" : "Done — your ticket is ready. Thank you 💛")
        isFinished = true
        let summaryEN = [context.analysis.titleEN, answeredDetails(arabic: false)]
            .filter { !$0.isEmpty }.joined(separator: ". ")
        let summaryAR = [context.analysis.titleAR, answeredDetails(arabic: true)]
            .filter { !$0.isEmpty }.joined(separator: ". ")
        onComplete(SubmitReportArgsFactory.make(
            summaryEN: summaryEN, summaryAR: summaryAR, answers: answers,
            userLanguage: context.language, wantsToPost: wantsToPost, anonymous: anonymous))
    }

    // MARK: Model flow

    private struct ModelTurn: Decodable {
        struct Answer: Decodable {
            let id: String
            let answer: String
        }

        let reply: String
        let done: Bool
        let urgent: Bool
        let urgentReason: String
        let summaryEN: String
        let summaryAR: String
        let answers: [Answer]
        let userLanguage: String
        let wantsToPost: Bool
        let anonymous: Bool

        enum CodingKeys: String, CodingKey {
            case reply, done, urgent, answers, anonymous
            case urgentReason = "urgent_reason"
            case summaryEN = "summary_en"
            case summaryAR = "summary_ar"
            case userLanguage = "user_language"
            case wantsToPost = "wants_to_post"
        }
    }

    /// Strict output schema for one chat turn. `answers` is an array because strict mode needs fixed keys.
    private static let turnSchemaJSON = """
    {"name":"chat_turn","strict":true,"schema":{"type":"object","additionalProperties":false,
    "required":["reply","done","urgent","urgent_reason","summary_en","summary_ar","answers","user_language","wants_to_post","anonymous"],
    "properties":{
    "reply":{"type":"string"},
    "done":{"type":"boolean"},
    "urgent":{"type":"boolean"},
    "urgent_reason":{"type":"string"},
    "summary_en":{"type":"string"},
    "summary_ar":{"type":"string"},
    "answers":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["id","answer"],
      "properties":{"id":{"type":"string"},"answer":{"type":"string"}}}},
    "user_language":{"type":"string"},
    "wants_to_post":{"type":"boolean"},
    "anonymous":{"type":"boolean"}}}}
    """

    private static let turnSchema: JSONSchemaSpec? = {
        do {
            return try JSONDecoder().decode(JSONSchemaSpec.self, from: Data(turnSchemaJSON.utf8))
        } catch {
            Logger(subsystem: "io.fomy.hoth", category: "ChatIntake").error("Chat schema invalid: \(String(describing: error))")
            return nil
        }
    }()

    private func systemPrompt() -> String {
        let analysis = context.analysis
        let findings = """
        title: \(analysis.titleEN) / \(analysis.titleAR)
        category: \(analysis.category.rawValue)
        description: \(analysis.descriptionEN)
        hazards: \(analysis.hazards.map(\.label).joined(separator: ", "))
        current priority: \(context.priority.level.rawValue) — \(context.priority.reasonEN)
        """
        let slotLines = slots.map { "- id \($0.id): \(arabic ? $0.ar : $0.en)" }.joined(separator: "\n")
        let base = Prompts.fill(prompts.chatIntake.system, [
            "user_language": context.language,
            "findings": findings,
            "slot_questions": slotLines.isEmpty ? "(none)" : slotLines,
        ])
        return base + """


        Output format override: every turn is ONE JSON object matching the schema. Put your chat message \
        in "reply". Keep done=false until the resident has confirmed the read-back AND answered the posting \
        question; then set done=true and fill every field. Use slot ids as answer ids. If urgent, set \
        urgent=true with urgent_reason and give safety advice in reply.
        """
    }

    private func transcript(appending userMessage: String) -> String {
        let history = bubbles.map { ($0.role == .assistant ? "Assistant: " : "Resident: ") + $0.text }
        return (history + ["Resident: \(userMessage)"]).joined(separator: "\n")
    }

    private func sendToModel(userMessage: String, echo: Bool) async {
        guard let client, let schema = Self.turnSchema else {
            switchToLocal(pending: echo ? userMessage : nil)
            return
        }
        let userText = transcript(appending: userMessage)
        if echo { appendResident(userMessage) }
        isThinking = true
        defer { isThinking = false }
        do {
            let turn: ModelTurn = try await client.structured(
                model: prompts.models.text,
                system: systemPrompt(),
                user: Prompts.fill(prompts.chatIntake.userTemplate, ["user_message": userText]),
                schema: schema,
                as: ModelTurn.self
            )
            apply(turn)
        } catch {
            Self.logger.error("Chat model unavailable, using local flow: \(String(describing: error))")
            switchToLocal(pending: echo ? userMessage : nil, alreadyEchoed: echo)
        }
    }

    private func apply(_ turn: ModelTurn) {
        if !turn.reply.isEmpty { appendAssistant(turn.reply) }
        for answer in turn.answers { answers[answer.id] = answer.answer }
        if turn.urgent {
            isFinished = true
            quickReplies = []
            let pairs = answers.map { "\($0.key): \($0.value)" }.sorted()
            onUrgent((pairs + [turn.urgentReason.isEmpty ? "urgent" : turn.urgentReason]).joined(separator: "; "))
            return
        }
        if turn.done {
            isFinished = true
            quickReplies = []
            onComplete(SubmitReportArgsFactory.make(
                summaryEN: turn.summaryEN.isEmpty ? context.analysis.titleEN : turn.summaryEN,
                summaryAR: turn.summaryAR.isEmpty ? context.analysis.titleAR : turn.summaryAR,
                answers: answers,
                userLanguage: turn.userLanguage.isEmpty ? context.language : turn.userLanguage,
                wantsToPost: turn.wantsToPost,
                anonymous: turn.anonymous))
            return
        }
        quickReplies = arabic ? ["إي", "لا", "مب متأكد"] : ["Yes", "No", "Not sure"]
    }

    /// Falls back to the local flow, resuming at the first unanswered slot.
    private func switchToLocal(pending: String?, alreadyEchoed: Bool = false) {
        mode = .local
        if bubbles.isEmpty {
            startLocal()
            return
        }
        if let pending {
            if !alreadyEchoed { appendResident(pending) }
            // The pending message answers whatever was asked last; treat it as the next open slot.
            if let index = slots.firstIndex(where: { answers[$0.id] == nil }) {
                phase = .asking(index)
                handleLocal(pending)
                return
            }
        }
        if let index = slots.firstIndex(where: { answers[$0.id] == nil }) {
            phase = .asking(index)
            askSlot(index)
        } else {
            phase = .confirming
            askConfirmation()
        }
    }

    // MARK: Bubbles

    private func appendAssistant(_ text: String) {
        bubbles.append(ChatBubble(role: .assistant, text: text))
    }

    private func appendResident(_ text: String) {
        bubbles.append(ChatBubble(role: .resident, text: text))
    }
}
