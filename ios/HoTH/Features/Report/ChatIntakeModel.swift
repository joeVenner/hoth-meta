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
/// Uses the `chat_intake` prompt on Muse Spark through `MetaModelClient` when a key is available; on a missing key or
/// any API/network error it switches, mid-conversation if needed, to a deterministic local flow that
/// asks the category's slot questions in order, reads back, and asks about posting.
///
/// With an `IntakeToolbox` (and prompts.json `intake_agent`), each model turn is a small tool-calling agent:
/// Muse Spark may call `find_nearby_reports`, `segment_hazard` and `get_place_context` (at most
/// `max_tool_rounds` rounds) before the same structured turn output. A request the API rejects (400) or
/// a turn that does not decode switches tools off for the session and retries single-turn; a round limit
/// finishes that one turn single-turn with the tool results in the prompt. Priority stays with
/// `PriorityAgent`: the agent has no priority output, only answers that go through the safety floors.
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
    /// The tool the agent is running right now, for the typing indicator.
    @Published private(set) var toolActivity: IntakeToolbox.Activity?
    /// True while turns go through the tool-calling agent (false after a fallback to single-turn).
    @Published private(set) var usesTools: Bool

    let context: InterviewContext
    /// Every new assistant message, e.g. for the push-to-talk voice to read aloud.
    var onAssistantMessage: ((String) -> Void)?
    private let slots: [SlotQuestion]
    private let client: MetaModelClient?
    private let prompts: Prompts
    private let model: String
    private let onComplete: (SubmitReportArgs) -> Void
    private let onUrgent: (String) -> Void
    private let toolbox: IntakeToolbox?
    private let onConfirmExisting: ((UUID, SubmitReportArgs) -> Void)?
    /// Tool results from earlier turns, resent as text so the agent does not call them again.
    private var toolNotes: [String] = []
    /// The model turn in flight; `cancel()` stops it (exposed so tests can await it).
    private(set) var turnTask: Task<Void, Never>?

    private var answers: [String: String] = [:]
    private var phase: LocalPhase = .asking(0)
    private static let logger = Logger(subsystem: "io.fomy.hoth", category: "ChatIntake")

    /// - Parameter model: text model override (Settings); blank or nil uses `prompts.models.text`.
    /// - Parameters:
    ///   - toolbox: the agent's tools; nil (Settings off, no key, UI tests) keeps single-turn chat.
    ///   - onConfirmExisting: the resident chose to confirm a nearby report `find_nearby_reports` returned; the
    ///     args carry the answers so far, for a new ticket (through the safety floors) if that report is gone.
    init(context: InterviewContext, slots: [SlotQuestion], client: MetaModelClient?, prompts: Prompts,
         model: String? = nil, toolbox: IntakeToolbox? = nil,
         onComplete: @escaping (SubmitReportArgs) -> Void, onUrgent: @escaping (String) -> Void,
         onConfirmExisting: ((UUID, SubmitReportArgs) -> Void)? = nil) {
        self.context = context
        self.slots = Array(slots.prefix(2))
        self.client = client
        self.prompts = prompts
        self.model = Prompts.resolveTextModel(override: model, prompts: prompts)
        self.onComplete = onComplete
        self.onUrgent = onUrgent
        self.mode = client == nil ? .local : .model
        self.toolbox = toolbox
        self.onConfirmExisting = onConfirmExisting
        self.usesTools = client != nil && toolbox != nil && prompts.intakeAgent != nil
    }

    private var arabic: Bool { context.isArabic }

    // MARK: Public

    func start() {
        guard bubbles.isEmpty else { return }
        switch mode {
        case .model:
            turnTask = Task { await sendToModel(userMessage: arabic ? "(ابدأ المحادثة)" : "(start the conversation)", echo: false) }
        case .local:
            startLocal()
        }
    }

    func send(_ rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isThinking, !isFinished else { return }
        switch mode {
        case .model:
            turnTask = Task { await sendToModel(userMessage: text, echo: true) }
        case .local:
            appendResident(text)
            handleLocal(text)
        }
    }

    /// The interview screen went away: a late reply must not add bubbles or finish a reset report.
    func cancel() {
        turnTask?.cancel()
        turnTask = nil
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
        /// A `find_nearby_reports` id the resident chose to confirm; "" for none.
        let confirmReportID: String?

        enum CodingKeys: String, CodingKey {
            case reply, done, urgent, answers, anonymous
            case confirmReportID = "confirm_report_id"
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
    "required":["reply","done","urgent","urgent_reason","summary_en","summary_ar","answers","user_language","wants_to_post","anonymous","confirm_report_id"],
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
    "anonymous":{"type":"boolean"},
    "confirm_report_id":{"type":"string"}}}}
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
        urgent=true with urgent_reason and give safety advice in reply. Set confirm_report_id to "" unless \
        you were given tools and the resident confirmed a report a tool returned.
        """
    }

    /// The system prompt plus the agent's tool rules and the tool results gathered so far.
    private func agentSystemPrompt(_ agent: IntakeAgentSpec) -> String {
        var text = systemPrompt() + "\n\n" + agent.instructions
        if !toolNotes.isEmpty {
            text += "\n\nTool results so far:\n" + toolNotes.joined(separator: "\n")
        }
        return text
    }

    private static func note(for record: ToolCallRecord) -> String {
        "- \(record.name)(\(record.arguments.prefix(120))) -> \(record.output.prefix(800))"
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
        defer {
            isThinking = false
            toolActivity = nil
        }
        let user = Prompts.fill(prompts.chatIntake.userTemplate, ["user_message": userText])
        do {
            let turn: ModelTurn
            if usesTools, let toolbox, let agent = prompts.intakeAgent {
                turn = try await agentTurn(client: client, toolbox: toolbox, agent: agent, user: user, schema: schema)
            } else {
                turn = try await client.structured(model: model, system: systemPrompt(), user: user,
                                                   schema: schema, as: ModelTurn.self)
            }
            guard !Task.isCancelled else { return }
            apply(turn)
        } catch {
            // Cancelled on purpose (screen dismissed): not a reason to switch to the local flow.
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            Self.logger.error("Chat model unavailable, using local flow: \(String(describing: error))")
            switchToLocal(pending: echo ? userMessage : nil, alreadyEchoed: echo)
        }
    }

    /// One resident turn through the tool loop, with the single-turn call as its fallback.
    private func agentTurn(client: MetaModelClient, toolbox: IntakeToolbox, agent: IntakeAgentSpec,
                           user: String, schema: JSONSchemaSpec) async throws -> ModelTurn {
        let outcome: ToolLoop.Outcome<ModelTurn>
        do {
            outcome = try await ToolLoop.run(
                client: client, model: model, system: agentSystemPrompt(agent), user: user,
                tools: toolbox.tools, schema: schema, maxRounds: max(agent.maxToolRounds, 0)
            ) { [weak self] call in
                self?.toolActivity = IntakeToolbox.activity(for: call.name)
                let output = await toolbox.run(call)
                self?.toolActivity = nil
                return output
            }
        } catch let error as ModelAPIError where Self.fallsBackToSingleTurn(error) {
            // Tool calling (or tools + json_schema) rejected or not decodable: keep chatting without tools.
            Self.logger.error("Intake agent off, single-turn chat: \(String(describing: error))")
            usesTools = false
            return try await client.structured(model: model, system: systemPrompt(), user: user,
                                               schema: schema, as: ModelTurn.self)
        }
        switch outcome {
        case .final(let turn, let rounds, let calls):
            toolNotes += calls.map(Self.note(for:))
            Self.logger.info("Intake agent turn: \(rounds) tool round(s), calls \(calls.map(\.name).joined(separator: ","))")
            return turn
        case .roundLimit(let calls):
            toolNotes += calls.map(Self.note(for:))
            Self.logger.info("Intake agent hit the round limit; finishing this turn single-turn")
            return try await client.structured(model: model, system: agentSystemPrompt(agent), user: user,
                                               schema: schema, as: ModelTurn.self)
        }
    }

    /// Request-shape problems (and turns that do not decode) are worth one retry without tools; key, billing,
    /// rate-limit and network errors would fail single-turn too, so those go to the local flow.
    nonisolated static func fallsBackToSingleTurn(_ error: ModelAPIError) -> Bool {
        switch error {
        case .http(let code, _): return code == 400 || code == 404 || code == 422
        case .decoding, .refused: return true
        case .missingKey, .invalidKey, .rateLimited, .network, .incomplete: return false
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
        if let id = confirmableReportID(turn.confirmReportID), let onConfirmExisting {
            isFinished = true
            quickReplies = []
            onConfirmExisting(id, submitArgs(from: turn))
            return
        }
        if turn.done {
            isFinished = true
            quickReplies = []
            onComplete(submitArgs(from: turn))
            return
        }
        quickReplies = arabic ? ["إي", "لا", "مب متأكد"] : ["Yes", "No", "Not sure"]
    }

    private func submitArgs(from turn: ModelTurn) -> SubmitReportArgs {
        SubmitReportArgsFactory.make(
            summaryEN: turn.summaryEN.isEmpty ? context.analysis.titleEN : turn.summaryEN,
            summaryAR: turn.summaryAR.isEmpty ? context.analysis.titleAR : turn.summaryAR,
            answers: answers,
            userLanguage: turn.userLanguage.isEmpty ? context.language : turn.userLanguage,
            wantsToPost: turn.wantsToPost,
            anonymous: turn.anonymous)
    }

    /// Only an id the tool actually returned this session counts; a made-up one is ignored.
    private func confirmableReportID(_ raw: String?) -> UUID? {
        let text = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard let id = UUID(uuidString: text), toolbox?.offeredReportIDs.contains(id) == true else {
            Self.logger.error("Ignoring confirm_report_id the tools never returned")
            return nil
        }
        return id
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
        onAssistantMessage?(text)
    }

    private func appendResident(_ text: String) {
        bubbles.append(ChatBubble(role: .resident, text: text))
    }
}
