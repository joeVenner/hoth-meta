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
        NavigationStack {
            Group {
                switch layout {
                case .list: listContent
                case .map: mapContent
                }
            }
            .background(Color.hothBackground.ignoresSafeArea())
            .navigationDestination(for: UUID.self) { id in
                if let report = reports.first(where: { $0.id == id }) {
                    CaseDetailView(report: report)
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
                LazyVStack(spacing: HoTHSpacing.l) {
                    ForEach(Array(visibleReports.enumerated()), id: \.element.id) { index, report in
                        NavigationLink(value: report.id) {
                            FeedCard(
                                report: report,
                                arabic: services.isArabic,
                                hasVoted: currentUser.map { report.hasVote(from: $0) } ?? false,
                                onVote: { toggleVote(on: report) }
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
                        .font(.hothDisplay(44))
                        .tracking(-1.2)
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
                            .foregroundStyle(isSelected ? Color.hothBackground : Color.hothInk)
                            .background(Capsule().fill(isSelected ? Color.hothInk : Color.hothSurface))
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

private struct FeedCard: View {
    @Environment(\.locale) private var locale
    let report: Report
    let arabic: Bool
    let hasVoted: Bool
    let onVote: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                ReportPhotoView(
                    fileName: report.displayPhotoFileName,
                    category: report.category,
                    priority: report.priority
                )
                .frame(height: 190)
                .frame(maxWidth: .infinity)
                .clipped()

                HStack {
                    PriorityBadge(levelRaw: report.priorityRaw)
                        .background(Capsule().fill(Color.hothSurface))
                    Spacer()
                    if report.status == .fixed || report.status == .inProgress {
                        StatusPill(status: report.status)
                            .background(Capsule().fill(Color.hothSurface))
                    }
                }
                .padding(HoTHSpacing.m)
            }
            .clipShape(RoundedRectangle(cornerRadius: HoTHRadius.card - 6, style: .continuous))
            .padding(6)

            VStack(alignment: .leading, spacing: HoTHSpacing.s) {
                CategoryChip(categoryRaw: report.categoryRaw)
                Text(report.title(arabic: arabic))
                    .font(.system(size: 21, weight: .semibold, design: .serif))
                    .foregroundStyle(Color.hothInk)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: HoTHSpacing.xs) {
                    Image(systemName: "mappin.and.ellipse")
                    Text(verbatim: report.placeName)
                    Text(verbatim: "·")
                    Text(verbatim: FeedGeography.formattedDistance(report.distanceFromHome, locale: locale))
                    Text(verbatim: "·")
                    Text(report.createdAt, style: .relative)
                }
                .font(.hothCaption)
                .foregroundStyle(Color.hothInkSecondary)
                .lineLimit(1)

                Divider().overlay(Color.hothInk.opacity(0.04)).padding(.vertical, HoTHSpacing.xs)

                HStack(spacing: HoTHSpacing.m) {
                    Label {
                        Text("\(report.confirmations + 1) neighbours saw this")
                    } icon: {
                        Image(systemName: "eye.fill")
                    }
                    .foregroundStyle(Color.hothInkSecondary)

                    Label {
                        Text(verbatim: "\(report.visibleComments.count)")
                    } icon: {
                        Image(systemName: "bubble.left.fill")
                    }
                    .foregroundStyle(Color.hothInkSecondary)
                    .accessibilityLabel(Text("\(report.visibleComments.count) comments"))

                    Spacer()

                    Button(action: onVote) {
                        HStack(spacing: HoTHSpacing.xs) {
                            Image(systemName: hasVoted ? "hand.thumbsup.fill" : "hand.thumbsup")
                                .symbolEffect(.bounce, value: hasVoted)
                            Text(verbatim: "\(report.voteCount)")
                                .contentTransition(.numericText())
                        }
                        .font(.hothCaption.weight(.bold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .foregroundStyle(hasVoted ? Color.white : Color.hothAccent)
                        .background(Capsule().fill(hasVoted ? Color.hothAccent : Color.hothAccent.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(hasVoted ? "Remove vote" : "Vote"))
                }
                .font(.hothCaption)
            }
            .padding(.horizontal, HoTHSpacing.m)
            .padding(.top, HoTHSpacing.s)
            .padding(.bottom, HoTHSpacing.m)
        }
        .background(
            RoundedRectangle(cornerRadius: HoTHRadius.card, style: .continuous).fill(Color.hothSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HoTHRadius.card, style: .continuous)
                .strokeBorder(Color.hothInk.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.03), radius: 2, x: 0, y: 1)
        .shadow(color: Color.black.opacity(0.05), radius: 20, x: 0, y: 12)
    }
}
