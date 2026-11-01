import HoTHCore
import OSLog
import SwiftData
import SwiftUI

/// Case detail (P0-17): photo, AI priority reasoning, timeline, votes, comments, "I saw it too".
struct CaseDetailView: View {
    @Bindable var report: Report
    /// Injected moderator; nil uses the live Muse Spark-backed one (local checks when offline / no key).
    var moderator: CommentModerator?
    /// Opened from a feed card's Comment button: scroll to the comments once shown.
    var focusesComments = false

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var services = AppServices.shared
    @Query(filter: #Predicate<Neighbour> { $0.isCurrentUser }) private var currentUsers: [Neighbour]
    @AppStorage(ConfirmedReports.storageKey) private var confirmedIDsRaw: String = ""
    @State private var draftComment = ""
    @State private var isPostingComment = false
    @State private var showConfirmToast = false
    @FocusState private var isComposerFocused: Bool

    private static let logger = Logger(subsystem: "io.fomy.hoth", category: "CaseDetail")
    private static let commentsAnchor = "caseComments"

    private var currentUser: Neighbour? { currentUsers.first }
    private var arabic: Bool { services.isArabic }
    private var hasConfirmed: Bool { confirmedIDsRaw.split(separator: ",").contains(Substring(report.id.uuidString)) }
    private var hasVoted: Bool { currentUser.map { report.hasVote(from: $0) } ?? false }
    private var isOwnReport: Bool { report.reporter?.isCurrentUser == true }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: HoTHSpacing.l) {
                    hero
                    VStack(alignment: .leading, spacing: HoTHSpacing.l) {
                        titleBlock
                        actionRow
                        priorityReasonCard
                        timelineCard
                        commentsSection.id(Self.commentsAnchor)
                    }
                    .padding(.horizontal, HoTHSpacing.m)
                }
                .padding(.bottom, 140)
            }
            .task {
                guard focusesComments else { return }
                // Let the push transition finish before scrolling.
                try? await Task.sleep(for: .milliseconds(350))
                withAnimation(HoTHMotion.spring) { proxy.scrollTo(Self.commentsAnchor, anchor: .top) }
            }
        }
        .background(Color.hothBackground.ignoresSafeArea())
        .ignoresSafeArea(edges: .top)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .overlay(alignment: .top) {
            if showConfirmToast {
                Label { Text("Thanks, neighbour. Priority updated.") } icon: { Image(systemName: "checkmark.circle.fill") }
                    .font(.hothCaption.weight(.semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, HoTHSpacing.m)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.hothTeal))
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, HoTHSpacing.s)
            }
        }
    }

    // MARK: Hero photo

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            ReportPhotoView(
                fileName: report.displayPhotoFileName,
                category: report.category,
                priority: report.priority,
                symbolSize: 72
            )
            .frame(height: 340)
            .frame(maxWidth: .infinity)
            .clipped()

            LinearGradient(colors: [.clear, Color.black.opacity(0.35)], startPoint: .center, endPoint: .bottom)
                .frame(height: 340)
                .allowsHitTesting(false)

            HStack(spacing: HoTHSpacing.s) {
                PriorityBadge(levelRaw: report.priorityRaw)
                    .background(Capsule().fill(Color.hothSurface))
                StatusPill(status: report.status)
                    .background(Capsule().fill(Color.hothSurface))
                Spacer()
                if report.isDemoSeed { DemoBadge().background(Capsule().fill(Color.hothSurface)) }
            }
            .padding(HoTHSpacing.m)
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: HoTHSpacing.s) {
            CategoryChip(categoryRaw: report.categoryRaw)
            Text(report.title(arabic: arabic))
                .font(.hothDisplay(30))
                .hothTracking(-0.6)
                .foregroundStyle(Color.hothInk)
                .fixedSize(horizontal: false, vertical: true)
            Label { Text(verbatim: report.placeName) } icon: { Image(systemName: "mappin.and.ellipse") }
                .font(.hothCaption)
                .foregroundStyle(Color.hothInkSecondary)
            let summary = report.summary(arabic: arabic)
            if !summary.isEmpty {
                Text(verbatim: summary)
                    .font(.hothBody)
                    .lineSpacing(4)
                    .foregroundStyle(Color.hothInk.opacity(0.85))
                    .padding(.top, HoTHSpacing.xs)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Actions

    private var actionRow: some View {
        HStack(spacing: HoTHSpacing.s) {
            Button(action: confirmSighting) {
                Label {
                    Text(hasConfirmed ? "You confirmed this" : "I saw it too")
                } icon: {
                    Image(systemName: hasConfirmed ? "checkmark" : "eye.fill")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(hasConfirmed || isOwnReport || report.status == .fixed)
            .accessibilityIdentifier("caseConfirmButton")

            Button(action: toggleVote) {
                HStack(spacing: HoTHSpacing.xs) {
                    Image(systemName: hasVoted ? "hand.thumbsup.fill" : "hand.thumbsup")
                        .symbolEffect(.bounce, value: hasVoted)
                    Text(verbatim: "\(report.voteCount)").contentTransition(.numericText())
                }
            }
            .buttonStyle(SecondaryButtonStyle())
            .frame(width: 104)
            .accessibilityLabel(Text(hasVoted ? "Remove vote" : "Vote"))
            .accessibilityIdentifier("caseVoteButton")
        }
    }

    // MARK: Priority reason

    private var priorityReasonCard: some View {
        HoTHCard(padding: HoTHSpacing.l) {
            VStack(alignment: .leading, spacing: HoTHSpacing.m) {
                HStack(spacing: HoTHSpacing.s) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(Color.hothAccent)
                    Text("Why this priority")
                        .font(.hothHeadline)
                        .foregroundStyle(Color.hothInk)
                    Spacer()
                    Text(verbatim: "\(report.priorityScore)")
                        .font(.hothDisplay(28))
                        .foregroundStyle(report.priority.tint)
                        .contentTransition(.numericText())
                    Text(verbatim: "/100")
                        .font(.hothCaption)
                        .foregroundStyle(Color.hothInkSecondary)
                }
                ProgressView(value: Double(min(max(report.priorityScore, 0), 100)), total: 100)
                    .tint(report.priority.tint)
                let reason = report.priorityReason(arabic: arabic)
                if !reason.isEmpty {
                    Text(verbatim: reason)
                        .font(.hothBody)
                        .lineSpacing(3)
                        .foregroundStyle(Color.hothInk.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !report.signals.isEmpty {
                    FlowLayout(spacing: HoTHSpacing.s) {
                        ForEach(report.signals, id: \.self) { signal in
                            Text(verbatim: SignalLabel.label(for: signal, arabic: arabic))
                                .font(.hothCaption)
                                .foregroundStyle(Color.hothTeal)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(Color.hothTeal.opacity(0.1)))
                        }
                    }
                }
                Text("AI proposes, safety rules can only raise the level.")
                    .font(.hothCaption)
                    .foregroundStyle(Color.hothInkSecondary)
            }
        }
    }

    // MARK: Timeline

    private struct TimelineStep: Identifiable {
        let id: Int
        let title: LocalizedStringKey
        let detail: Text?
        let symbol: String
        let isDone: Bool
    }

    private var timelineSteps: [TimelineStep] {
        let isInProgressOrLater = report.status == .inProgress || report.status == .fixed
        return [
            TimelineStep(id: 0, title: "Reported", detail: Text(report.createdAt, style: .relative),
                         symbol: "flag.fill", isDone: true),
            TimelineStep(id: 1, title: "Confirmed by neighbours",
                         detail: Text("\(report.confirmations) confirmations"),
                         symbol: "person.2.fill", isDone: report.confirmations > 0),
            TimelineStep(id: 2, title: "Crew in progress", detail: nil,
                         symbol: "wrench.and.screwdriver.fill", isDone: isInProgressOrLater),
            TimelineStep(id: 3, title: "Fixed",
                         detail: report.fixedAt.map { Text($0, style: .relative) },
                         symbol: "checkmark.seal.fill", isDone: report.status == .fixed),
        ]
    }

    private var timelineCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Timeline")
                .padding(.bottom, HoTHSpacing.m)
            HoTHCard(padding: HoTHSpacing.l) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(timelineSteps) { step in
                        HStack(alignment: .top, spacing: HoTHSpacing.m) {
                            VStack(spacing: 0) {
                                ZStack {
                                    Circle()
                                        .fill(step.isDone ? Color.hothTeal : Color.hothSand)
                                        .frame(width: 30, height: 30)
                                    Image(systemName: step.symbol)
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(step.isDone ? Color.white : Color.hothInkSecondary)
                                }
                                if step.id < timelineSteps.count - 1 {
                                    Rectangle()
                                        .fill(step.isDone ? Color.hothTeal.opacity(0.4) : Color.hothSand)
                                        .frame(width: 2, height: 26)
                                }
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(step.title)
                                    .font(.hothHeadline)
                                    .foregroundStyle(step.isDone ? Color.hothInk : Color.hothInkSecondary)
                                if let detail = step.detail {
                                    detail
                                        .font(.hothCaption)
                                        .foregroundStyle(Color.hothInkSecondary)
                                }
                            }
                            .padding(.top, 5)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }

    // MARK: Comments

    private var commentsSection: some View {
        VStack(alignment: .leading, spacing: HoTHSpacing.m) {
            SectionHeader(title: "Neighbours' comments")
            let comments = report.threadComments
            if comments.isEmpty {
                Text("No comments yet. Be the first to add context.")
                    .font(.hothBody)
                    .foregroundStyle(Color.hothInkSecondary)
            }
            ForEach(comments) { comment in
                CommentRow(comment: comment)
            }
            composer
        }
    }

    private var composer: some View {
        HStack(spacing: HoTHSpacing.s) {
            TextField(text: $draftComment, axis: .vertical) {
                Text("Add a helpful comment")
            }
            .font(.hothBody)
            .lineLimit(1...4)
            .focused($isComposerFocused)
            .accessibilityIdentifier("commentField")
            .padding(.horizontal, HoTHSpacing.m)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.hothSurface))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.hothInk.opacity(0.08))
            )

            Button(action: postComment) {
                Image(systemName: isPostingComment ? "ellipsis" : "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.hothAccent))
            }
            .buttonStyle(.plain)
            .disabled(draftComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isPostingComment)
            .accessibilityLabel(Text("Send comment"))
            .accessibilityIdentifier("commentSendButton")
        }
    }

    // MARK: Mutations

    private func toggleVote() {
        guard let currentUser else { return }
        Haptics.tap()
        withAnimation(HoTHMotion.spring) {
            if let existing = report.votes.first(where: { $0.voter?.id == currentUser.id }) {
                modelContext.delete(existing)
                report.votes.removeAll { $0.id == existing.id }
            } else {
                let vote = Vote(voter: currentUser)
                modelContext.insert(vote)
                vote.report = report
            }
        }
        save()
    }

    /// "I saw it too": +1 confirmation and priority recompute (shared with the feed card).
    private func confirmSighting() {
        guard !hasConfirmed, !isOwnReport else { return }
        var didConfirm = false
        withAnimation(HoTHMotion.spring) {
            didConfirm = SightingConfirmation.confirm(report, by: currentUser, context: modelContext)
            if didConfirm { showConfirmToast = true }
        }
        guard didConfirm else { return }
        Haptics.success()
        save()
        Task {
            try? await Task.sleep(for: .seconds(2.2))
            withAnimation(HoTHMotion.spring) { showConfirmToast = false }
        }
    }

    private func postComment() {
        let text = draftComment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // Brief guard against double-taps only; moderation runs in the background (row shows "Checking…").
        isPostingComment = true
        let comment = Comment(author: currentUser, text: text, moderationStatus: .pending)
        modelContext.insert(comment)
        withAnimation(HoTHMotion.spring) { comment.report = report }
        draftComment = ""
        isComposerFocused = false
        save()
        isPostingComment = false
        let activeModerator = moderator ?? ModelCommentModerator.live()
        let reportTitle = report.titleEN.isEmpty ? report.titleAR : report.titleEN
        Task { @MainActor in
            let status = await activeModerator.moderate(text, reportTitle: reportTitle)
            withAnimation(HoTHMotion.spring) { comment.moderationStatus = status }
            save()
        }
    }

    private func save() {
        do {
            try modelContext.save()
        } catch {
            Self.logger.error("Saving case changes failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Comment row

private struct CommentRow: View {
    let comment: Comment

    var body: some View {
        if comment.moderationStatus == .blocked {
            removedRow
        } else {
            commentRow
        }
    }

    private var removedRow: some View {
        Label { Text("Removed by community guidelines") } icon: { Image(systemName: "eye.slash") }
            .font(.hothCaption.italic())
            .foregroundStyle(Color.hothInkSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(HoTHSpacing.m)
            .background(
                RoundedRectangle(cornerRadius: HoTHRadius.inner, style: .continuous)
                    .strokeBorder(Color.hothInk.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
            .accessibilityIdentifier("commentRemoved")
    }

    private var commentRow: some View {
        HStack(alignment: .top, spacing: HoTHSpacing.s) {
            Image(systemName: comment.author?.avatarSymbol ?? "person.crop.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(Color.hothTeal.opacity(0.7))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: HoTHSpacing.xs) {
                    Text(verbatim: comment.author?.displayName ?? "Neighbour")
                        .font(.hothCaption.weight(.bold))
                        .foregroundStyle(Color.hothInk)
                    Text(comment.createdAt, style: .relative)
                        .font(.hothCaption)
                        .foregroundStyle(Color.hothInkSecondary)
                    if comment.moderationStatus == .pending {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text("Checking…")
                        }
                        .accessibilityIdentifier("commentPending")
                        .font(.caption2)
                        .foregroundStyle(Color.hothInkSecondary)
                    }
                    if comment.moderationStatus == .softened {
                        Image(systemName: "wand.and.stars")
                            .font(.caption2)
                            .foregroundStyle(Color.hothInkSecondary)
                            .accessibilityLabel(Text("Softened by moderation"))
                    }
                }
                Text(verbatim: comment.text)
                    .font(.hothBody)
                    .foregroundStyle(Color.hothInk.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(HoTHSpacing.m)
        .background(RoundedRectangle(cornerRadius: HoTHRadius.inner, style: .continuous).fill(Color.hothSurface))
    }
}

// MARK: - Flow layout

/// Wrapping chip layout; respects layout direction (RTL) via Layout's placement API.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0, rowHeight: CGFloat = 0, totalHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0 && rowWidth + spacing + size.width > maxWidth {
                totalHeight += rowHeight + spacing
                widest = max(widest, rowWidth)
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
            rowHeight = max(rowHeight, size.height)
        }
        widest = max(widest, rowWidth)
        return CGSize(width: proposal.width ?? widest, height: totalHeight + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
