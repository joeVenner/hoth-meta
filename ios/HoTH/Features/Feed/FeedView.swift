import SwiftData
import SwiftUI

/// Community feed (P0-17): reports sorted by priority score, then recency.
struct FeedView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all, nearMe, critical, fixed
        var id: String { rawValue }

        var label: LocalizedStringKey {
            switch self {
            case .all: return "All"
            case .nearMe: return "Near me"
            case .critical: return "Critical"
            case .fixed: return "Fixed"
            }
        }

        var symbol: String {
            switch self {
            case .all: return "square.grid.2x2"
            case .nearMe: return "location.fill"
            case .critical: return "exclamationmark.octagon.fill"
            case .fixed: return "checkmark.seal.fill"
            }
        }
    }

    /// P2-03: list (default) or map of the same filtered reports.
    enum Layout: String, CaseIterable, Identifiable {
        case list, map
        var id: String { rawValue }
    }

    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var services = AppServices.shared
    @ObservedObject private var alerts = NeighbourAlertCenter.shared
    @Query private var reports: [Report]
    @Query(filter: #Predicate<Neighbour> { $0.isCurrentUser }) private var currentUsers: [Neighbour]
    @State private var filter: Filter = .all
    @State private var layout: Layout = .list
    @State private var hasAppeared = false
    @State private var path = NavigationPath()

    private var currentUser: Neighbour? { currentUsers.first }

    private var visibleReports: [Report] { Self.visibleReports(reports, filter: filter) }

    /// Posted, non-rejected reports matching `filter`, most urgent first (shared with the Map tab).
    static func visibleReports(_ reports: [Report], filter: Filter) -> [Report] {
        reports
            .filter { $0.isPosted && $0.status != .rejected }
            .filter { report in
                switch filter {
                case .all: return true
                case .nearMe: return report.distanceFromHome <= FeedGeography.nearMeRadius
                case .critical: return report.priority == .critical && report.status != .fixed
                case .fixed: return report.status == .fixed
                }
            }
            .sorted { lhs, rhs in
                if lhs.priorityScore != rhs.priorityScore { return lhs.priorityScore > rhs.priorityScore }
                return lhs.createdAt > rhs.createdAt
            }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                switch layout {
                case .list: listContent
                case .map: mapContent
                }
            }
            .background(Color.hothBackground.ignoresSafeArea())
            .hothStatusBarBackdrop()
            .navigationDestination(for: UUID.self) { id in
                if let report = reports.first(where: { $0.id == id }) {
                    CaseDetailView(report: report)
                }
            }
            .navigationDestination(for: CaseCommentsRoute.self) { route in
                if let report = reports.first(where: { $0.id == route.reportID }) {
                    CaseDetailView(report: report, focusesComments: true)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .overlay(alignment: .top) {
                if let banner = alerts.banner {
                    NeighbourAlertBannerView(banner: banner) { alerts.dismissBanner() }
                        .padding(.horizontal, HoTHSpacing.m)
                        .padding(.top, HoTHSpacing.xs)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .onAppear { hasAppeared = true }
            .task { await alerts.runLaunchSimulationIfNeeded(context: modelContext) }
        }
    }

    private var mapContent: some View {
        VStack(alignment: .leading, spacing: HoTHSpacing.m) {
            VStack(alignment: .leading, spacing: HoTHSpacing.l) {
                header
                layoutPicker
                filterBar
            }
            .padding(.horizontal, HoTHSpacing.m)
            FeedMapView(reports: visibleReports, arabic: services.isArabic)
        }
    }

    private var listContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HoTHSpacing.l) {
                header
                layoutPicker
                filterBar
                LazyVStack(spacing: HoTHSpacing.m) {
                    ForEach(Array(visibleReports.enumerated()), id: \.element.id) { index, report in
                        NavigationLink(value: report.id) {
                            FeedCard(
                                report: report,
                                arabic: services.isArabic,
                                hasVoted: currentUser.map { report.hasVote(from: $0) } ?? false,
                                canConfirm: SightingConfirmation.canConfirm(report, by: currentUser),
                                onVote: { toggleVote(on: report) },
                                onConfirm: { confirmSighting(on: report) },
                                onComment: { path.append(CaseCommentsRoute(reportID: report.id)) }
                            )
                        }
                        .buttonStyle(.plain)
                        .opacity(hasAppeared ? 1 : 0)
                        .offset(y: hasAppeared ? 0 : 18)
                        .animation(HoTHMotion.spring.delay(Double(min(index, 8)) * 0.06), value: hasAppeared)
                    }
                    if visibleReports.isEmpty { emptyState }
                }
            }
            .padding(.horizontal, HoTHSpacing.m)
            .padding(.bottom, 120)
        }
    }

    private var layoutPicker: some View {
        Picker("Feed layout", selection: $layout.animation(HoTHMotion.spring)) {
            Text("List").tag(Layout.list)
            Text("Map").tag(Layout.map)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("feedLayoutPicker")
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: HoTHSpacing.s) {
            HStack(alignment: .center, spacing: 12) {
                HoTHLogo(size: 44)
                // The Latin wordmark keeps its shape (dot after the H) in Arabic too.
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(verbatim: "HoTH")
                        .font(.hothDisplay(38))
                        .tracking(-1)
                        .foregroundStyle(Color.hothInk)
                        .accessibilityIdentifier("hothWordmark")
                        // Hidden demo trigger: replay a neighbour's critical report arriving.
                        .onLongPressGesture(minimumDuration: 0.6) {
                            guard services.demoMode else { return }
                            Haptics.success()
                            withAnimation(HoTHMotion.spring) {
                                alerts.simulateNeighbourReport(context: modelContext, bypassRateLimit: true)
                            }
                        }
                    Circle().fill(Color.hothAccent).frame(width: 9, height: 9)
                }
                .environment(\.layoutDirection, .leftToRight)
                Spacer(minLength: HoTHSpacing.s)
                if services.demoMode { DemoBadge() }
            }
            Text("حيّ · Hay = neighbourhood")
                .font(.hothCaption)
                .foregroundStyle(Color.hothInkSecondary)
            if layout == .list {
                Text("What your neighbours are fixing together")
                    .font(.hothTitle)
                    .foregroundStyle(Color.hothInk)
                    .padding(.top, HoTHSpacing.s)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, HoTHSpacing.l)
    }

    private var filterBar: some View { FeedFilterBar(filter: $filter) }

    private var emptyState: some View {
        VStack(spacing: HoTHSpacing.s) {
            Image("empty_feed")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 220, maxHeight: 180)
                .accessibilityHidden(true)
            Text("All calm here")
                .font(.hothHeadline)
                .foregroundStyle(Color.hothInk)
            Text("Nothing matches this filter right now.")
                .font(.hothBody)
                .foregroundStyle(Color.hothInkSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, HoTHSpacing.xl)
    }

    // MARK: Actions

    /// One vote per neighbour; tapping again withdraws it.
    private func toggleVote(on report: Report) {
        guard let currentUser else { return }
        Haptics.tap()
        withAnimation(HoTHMotion.spring) {
            if let existing = report.votes.first(where: { $0.voter?.id == currentUser.id }) {
                modelContext.delete(existing)
                report.votes.removeAll { $0.id == existing.id }
            } else if !report.hasVote(from: currentUser) {
                let vote = Vote(voter: currentUser)
                modelContext.insert(vote)
                vote.report = report
            }
        }
        try? modelContext.save()
    }

    private func confirmSighting(on report: Report) {
        var didConfirm = false
        withAnimation(HoTHMotion.spring) {
            didConfirm = SightingConfirmation.confirm(report, by: currentUser, context: modelContext)
        }
        guard didConfirm else { return }
        Haptics.success()
        try? modelContext.save()
    }
}

/// Feed card Comment button: opens the case scrolled to its comments.
struct CaseCommentsRoute: Hashable {
    let reportID: UUID
}

// MARK: - Filter bar

/// Horizontal filter chips (All / Near me / Critical / Fixed), shared by the Feed and Map tabs.
struct FeedFilterBar: View {
    @Binding var filter: FeedView.Filter

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: HoTHSpacing.s) {
                ForEach(FeedView.Filter.allCases) { option in
                    let isSelected = option == filter
                    Button {
                        Haptics.tap()
                        withAnimation(HoTHMotion.spring) { filter = option }
                    } label: {
                        Label { Text(option.label) } icon: { Image(systemName: option.symbol) }
                            .font(.hothCaption.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .foregroundStyle(isSelected ? Color.hothAccent : Color.hothInk)
                            .background(Capsule().fill(isSelected ? Color.hothAccent.opacity(0.14) : Color.hothSurface))
                            .overlay(Capsule().strokeBorder(Color.hothInk.opacity(isSelected ? 0 : 0.08)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(.vertical, 2)
        }
    }
}

// MARK: - Card

/// One report as a social post: reporter header, text, full-width photo, badges, counts and an
/// action bar (I saw it too / Comment / Share).
private struct FeedCard: View {
    @Environment(\.locale) private var locale
    let report: Report
    let arabic: Bool
    let hasVoted: Bool
    let canConfirm: Bool
    let onVote: () -> Void
    let onConfirm: () -> Void
    let onComment: () -> Void

    private var hasConfirmed: Bool { ConfirmedReports.contains(report.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            postHeader
                .padding(.horizontal, HoTHSpacing.m)
                .padding(.top, HoTHSpacing.m)

            postText
                .padding(.horizontal, HoTHSpacing.m)
                .padding(.top, HoTHSpacing.s + 2)

            photo.padding(.top, HoTHSpacing.s + 4)

            badgeRow
                .padding(.horizontal, HoTHSpacing.m)
                .padding(.top, HoTHSpacing.s + 4)

            countsRow
                .padding(.horizontal, HoTHSpacing.m)
                .padding(.top, HoTHSpacing.s + 2)

            Divider()
                .overlay(Color.hothInk.opacity(0.06))
                .padding(.horizontal, HoTHSpacing.m)
                .padding(.top, HoTHSpacing.s + 2)

            actionBar
                .padding(.horizontal, HoTHSpacing.xs)
                .padding(.vertical, HoTHSpacing.xs)
        }
        .background(
            RoundedRectangle(cornerRadius: HoTHRadius.card, style: .continuous).fill(Color.hothSurface)
        )
        .clipShape(RoundedRectangle(cornerRadius: HoTHRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: HoTHRadius.card, style: .continuous)
                .strokeBorder(Color.hothInk.opacity(0.06), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
    }

    // MARK: Header

    private var postHeader: some View {
        HStack(alignment: .center, spacing: HoTHSpacing.s + 2) {
            ReporterAvatar(reporter: report.isAnonymous ? nil : report.reporter)
            VStack(alignment: .leading, spacing: 2) {
                reporterName
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.hothInk)
                    .lineLimit(1)
                HStack(spacing: HoTHSpacing.xs) {
                    Text(report.createdAt, format: .relative(presentation: .named))
                    Text(verbatim: "·")
                    Image(systemName: "mappin.and.ellipse").font(.system(size: 10, weight: .semibold))
                    Text(verbatim: report.placeName)
                    Text(verbatim: "·")
                    Text(verbatim: FeedGeography.formattedDistance(report.distanceFromHome, locale: locale))
                }
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Color.hothInkSecondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var reporterName: some View {
        if report.isAnonymous || report.reporter == nil {
            Text("Anonymous neighbour")
        } else if let reporter = report.reporter, reporter.isCurrentUser {
            Text("You")
        } else {
            Text(verbatim: report.reporter?.displayName ?? "")
        }
    }

    // MARK: Text

    private var postText: some View {
        VStack(alignment: .leading, spacing: HoTHSpacing.xs) {
            Text(report.title(arabic: arabic))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.hothInk)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            let summary = report.summary(arabic: arabic)
            if !summary.isEmpty {
                Text(verbatim: summary)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.hothInk.opacity(0.85))
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
            }
        }
    }

    // MARK: Photo

    private var photo: some View {
        ReportPhotoView(
            fileName: report.displayPhotoFileName,
            category: report.category,
            priority: report.priority
        )
        .frame(height: 220)
        .frame(maxWidth: .infinity)
        .clipped()
        .overlay(alignment: .topTrailing) {
            if report.status == .fixed || report.status == .inProgress {
                StatusPill(status: report.status)
                    .background(Capsule().fill(Color.hothSurface))
                    .padding(HoTHSpacing.s + 2)
            }
        }
    }

    // MARK: Badges & counts

    private var badgeRow: some View {
        HStack(spacing: HoTHSpacing.s) {
            PriorityBadge(levelRaw: report.priorityRaw)
            CategoryChip(categoryRaw: report.categoryRaw)
            Spacer(minLength: HoTHSpacing.xs)
            Button(action: onVote) {
                HStack(spacing: HoTHSpacing.xs) {
                    Image(systemName: hasVoted ? "hand.thumbsup.fill" : "hand.thumbsup")
                        .symbolEffect(.bounce, value: hasVoted)
                    Text(verbatim: "\(report.voteCount)")
                        .contentTransition(.numericText())
                }
                .font(.hothCaption.weight(.bold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundStyle(hasVoted ? Color.white : Color.hothAccent)
                .background(Capsule().fill(hasVoted ? Color.hothAccent : Color.hothAccent.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(hasVoted ? "Remove vote" : "Vote"))
        }
    }

    private var countsRow: some View {
        HStack(spacing: HoTHSpacing.xs) {
            Image(systemName: "eye.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.hothAccent))
            Text("\(report.confirmations + 1) neighbours saw this")
            Text(verbatim: "·")
            Text("\(report.visibleComments.count) comments")
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .foregroundStyle(Color.hothInkSecondary)
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .accessibilityElement(children: .combine)
    }

    // MARK: Action bar

    private var actionBar: some View {
        HStack(spacing: 0) {
            Button(action: onConfirm) {
                actionLabel(hasConfirmed ? "You confirmed this" : "I saw it too",
                            symbol: hasConfirmed ? "checkmark.circle.fill" : "eye")
                    .foregroundStyle(hasConfirmed ? Color.hothAccent : Color.hothInkSecondary)
            }
            .disabled(!canConfirm)
            .opacity(canConfirm || hasConfirmed ? 1 : 0.45)
            .accessibilityIdentifier("feedConfirmButton")

            Button(action: onComment) {
                actionLabel("Comment", symbol: "bubble.left")
                    .foregroundStyle(Color.hothInkSecondary)
            }
            .accessibilityIdentifier("feedCommentButton")

            ShareLink(item: shareText, subject: Text(verbatim: report.title(arabic: arabic))) {
                actionLabel("Share", symbol: "square.and.arrow.up")
                    .foregroundStyle(Color.hothInkSecondary)
            }
            .accessibilityIdentifier("feedShareButton")
        }
        .buttonStyle(.plain)
    }

    private func actionLabel(_ title: LocalizedStringKey, symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
            Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, minHeight: 40)
        .contentShape(Rectangle())
    }

    /// Public post content only: title, summary and the place name already shown in the feed.
    /// Never the reporter, coordinates or photo.
    private var shareText: String {
        [report.title(arabic: arabic), report.summary(arabic: arabic), report.placeName]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

// MARK: - Avatar

/// Initials circle for a reporter; a person glyph for anonymous posts.
private struct ReporterAvatar: View {
    let reporter: Neighbour?

    private static let palette: [Color] = [.hothAccent, .hothTeal, .hothSuccess, .hothHigh, .hothLow]

    private var initials: String {
        guard let name = reporter?.displayName else { return "" }
        let letters = name.split(separator: " ").prefix(2).compactMap(\.first)
        return String(letters).uppercased()
    }

    /// Stable colour per neighbour (sum of the name's scalars; `hashValue` changes per launch).
    private var color: Color {
        guard let name = reporter?.displayName, !name.isEmpty else { return .hothInkSecondary }
        let sum = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return Self.palette[sum % Self.palette.count]
    }

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(reporter == nil ? 0.18 : 1))
            if reporter == nil || initials.isEmpty {
                Image(systemName: "person.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.hothInkSecondary)
            } else {
                Text(verbatim: initials)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.white)
            }
        }
        .frame(width: 40, height: 40)
        .accessibilityHidden(true)
    }
}
