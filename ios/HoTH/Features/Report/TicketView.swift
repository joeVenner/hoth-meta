import HoTHCore
import SwiftUI

/// The finished ticket (P0-16): number, title, priority + reason, routed team, read-back, post toggle.
struct TicketView: View {
    let ticketNumber: String
    let analysis: VisionAnalysis
    let priority: PriorityDecision
    let team: ReportRouting.Team
    let args: SubmitReportArgs?
    let slots: [SlotQuestion]
    let photo: UIImage?
    let isArabic: Bool
    let onSubmit: (_ post: Bool, _ anonymous: Bool) async -> Void

    @State private var postToNeighbourhood: Bool
    @State private var anonymous: Bool
    @State private var isSubmitting = false

    init(ticketNumber: String, analysis: VisionAnalysis, priority: PriorityDecision, team: ReportRouting.Team,
         args: SubmitReportArgs?, slots: [SlotQuestion], photo: UIImage?, isArabic: Bool,
         onSubmit: @escaping (_ post: Bool, _ anonymous: Bool) async -> Void) {
        self.ticketNumber = ticketNumber
        self.analysis = analysis
        self.priority = priority
        self.team = team
        self.args = args
        self.slots = slots
        self.photo = photo
        self.isArabic = isArabic
        self.onSubmit = onSubmit
        _postToNeighbourhood = State(initialValue: args?.wantsToPost ?? true)
        _anonymous = State(initialValue: args?.anonymous ?? false)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HoTHSpacing.m) {
                header
                PriorityReasonCard(priority: priority, isArabic: isArabic)
                routingCard
                readBackCard
                postCard
                Button {
                    isSubmitting = true
                    Task {
                        await onSubmit(postToNeighbourhood, anonymous)
                        isSubmitting = false
                    }
                } label: {
                    if isSubmitting {
                        ProgressView().tint(.white)
                    } else {
                        Label(postToNeighbourhood ? LocalizedStringKey("Submit & post") : LocalizedStringKey("Submit ticket"),
                              systemImage: "paperplane.fill")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isSubmitting)
                .accessibilityIdentifier("ticketSubmitButton")
            }
            .padding(HoTHSpacing.m)
            .padding(.bottom, HoTHSpacing.l)
        }
        .background(Color.hothBackground.ignoresSafeArea())
    }

    private var header: some View {
        HoTHCard {
            HStack(alignment: .top, spacing: HoTHSpacing.m) {
                VStack(alignment: .leading, spacing: HoTHSpacing.s) {
                    Text(ticketNumber)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.hothTeal)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.hothTeal.opacity(0.1)))
                        .accessibilityIdentifier("ticketNumber")
                    Text(isArabic ? analysis.titleAR : analysis.titleEN)
                        .font(.hothTitle)
                        .foregroundStyle(Color.hothInk)
                    if !isArabic, !analysis.titleAR.isEmpty {
                        Text(analysis.titleAR).font(.hothBody).foregroundStyle(Color.hothInkSecondary)
                    } else if isArabic, !analysis.titleEN.isEmpty {
                        Text(analysis.titleEN).font(.hothBody).foregroundStyle(Color.hothInkSecondary)
                    }
                    HStack(spacing: HoTHSpacing.s) {
                        PriorityBadge(levelRaw: priority.level.rawValue)
                        CategoryChip(categoryRaw: analysis.category.rawValue)
                    }
                }
                Spacer(minLength: 0)
                if let photo {
                    Image(uiImage: photo)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 76, height: 76)
                        .clipShape(RoundedRectangle(cornerRadius: HoTHRadius.inner, style: .continuous))
                }
            }
        }
    }

    private var routingCard: some View {
        HoTHCard {
            HStack(spacing: HoTHSpacing.m) {
                Image(systemName: team.symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.hothTeal))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Routed to").font(.hothCaption).foregroundStyle(Color.hothInkSecondary)
                    Text(team.name(arabic: isArabic)).font(.hothHeadline).foregroundStyle(Color.hothInk)
                }
                Spacer()
            }
        }
    }

    private var readBackCard: some View {
        HoTHCard {
            VStack(alignment: .leading, spacing: HoTHSpacing.s) {
                SectionHeader(title: "What you told us")
                Text(summary).font(.hothBody).foregroundStyle(Color.hothInk)
                ForEach(answerRows, id: \.question) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.question).font(.hothCaption).foregroundStyle(Color.hothInkSecondary)
                        Text(row.answer).font(.hothBody).foregroundStyle(Color.hothInk)
                    }
                }
            }
        }
    }

    private var postCard: some View {
        HoTHCard {
            VStack(alignment: .leading, spacing: HoTHSpacing.s) {
                Toggle(isOn: $postToNeighbourhood.animation(HoTHMotion.spring)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Post to your neighbourhood?").font(.hothHeadline).foregroundStyle(Color.hothInk)
                        Text("Faces and plates are blurred on your phone before posting.")
                            .font(.hothCaption).foregroundStyle(Color.hothInkSecondary)
                    }
                }
                .tint(Color.hothTeal)
                .accessibilityIdentifier("postToggle")
                if postToNeighbourhood {
                    Divider()
                    Toggle(isOn: $anonymous) {
                        Label("Post anonymously", systemImage: "person.fill.questionmark")
                            .font(.hothBody).foregroundStyle(Color.hothInk)
                    }
                    .tint(Color.hothTeal)
                    .accessibilityIdentifier("anonymousToggle")
                }
            }
        }
    }

    private var summary: String {
        guard let args else { return isArabic ? analysis.descriptionAR : analysis.descriptionEN }
        return isArabic ? args.summaryAR : args.summaryEN
    }

    private var answerRows: [(question: String, answer: String)] {
        guard let args else { return [] }
        return slots.compactMap { slot in
            guard let answer = args.answers[slot.id], !answer.isEmpty else { return nil }
            return (isArabic ? slot.ar : slot.en, answer)
        }
    }
}

/// Success after posting (or saving privately).
struct PostedView: View {
    let ticketNumber: String
    let isPosted: Bool
    let onDone: () -> Void

    @State private var appeared = false

    var body: some View {
        VStack(spacing: HoTHSpacing.l) {
            Spacer()
            ZStack {
                Circle().fill(Color.hothSuccess.opacity(0.15)).frame(width: 150, height: 150)
                    .scaleEffect(appeared ? 1 : 0.6)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 76, weight: .semibold))
                    .foregroundStyle(Color.hothSuccess)
                    .symbolEffect(.bounce, value: appeared)
            }
            VStack(spacing: HoTHSpacing.s) {
                Text(isPosted ? LocalizedStringKey("Posted — neighbours nearby will be alerted") : LocalizedStringKey("Ticket saved"))
                    .font(.hothDisplay(28))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.hothInk)
                Text(ticketNumber)
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.hothTeal)
                if isPosted {
                    Text("Only the blurred photo is shared. The original stays on your phone.")
                        .font(.hothCaption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Color.hothInkSecondary)
                }
            }
            .padding(.horizontal, HoTHSpacing.l)
            Spacer()
            Button("Done", action: onDone)
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, HoTHSpacing.l)
                .padding(.bottom, HoTHSpacing.l)
                .accessibilityIdentifier("postedDoneButton")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.hothBackground.ignoresSafeArea())
        .onAppear {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) { appeared = true }
        }
    }
}
