import HoTHCore
import SwiftData
import SwiftUI

/// Hero tab: the current neighbour's points, level and progress (Rewards levels from HoTHCore).
struct HeroProfileView: View {
    @ObservedObject private var services = AppServices.shared
    @Query(filter: #Predicate<Neighbour> { $0.isCurrentUser }) private var currentUsers: [Neighbour]
    @Query(sort: \Neighbour.points, order: .reverse) private var neighbours: [Neighbour]
    @State private var animatedProgress: Double = 0

    private var me: Neighbour? { currentUsers.first }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HoTHSpacing.l) {
                    VStack(alignment: .leading, spacing: HoTHSpacing.xs) {
                        Text("Your hero card")
                            .font(.hothDisplay(38))
                            .hothTracking(-1)
                            .foregroundStyle(Color.hothInk)
                        Text("Small acts, a safer hay.")
                            .font(.hothBody)
                            .foregroundStyle(Color.hothInkSecondary)
                    }
                    .padding(.top, HoTHSpacing.l)

                    if let me {
                        levelCard(for: me)
                        statsRow(for: me)
                        myReports(for: me)
                        leaderboard
                    } else {
                        Text("No profile yet. Reset the demo community in Settings.")
                            .font(.hothBody)
                            .foregroundStyle(Color.hothInkSecondary)
                    }
                }
                .padding(.horizontal, HoTHSpacing.m)
                .padding(.bottom, 120)
            }
            .background(Color.hothBackground.ignoresSafeArea())
            .navigationDestination(for: UUID.self) { id in
                if let report = me?.reports.first(where: { $0.id == id }) {
                    CaseDetailView(report: report)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private func levelTitle(points: Int) -> String {
        let level = Rewards.level(forPoints: points)
        return services.isArabic ? level.titleAR : level.titleEN
    }

    private func badgeImageName(points: Int) -> String {
        switch Rewards.level(forPoints: points) {
        case .neighbour: return "badge_neighbour"
        case .guardian: return "badge_guardian"
        case .heroOfTheHay: return "badge_hero"
        }
    }

    private func progress(points: Int) -> Double {
        let level = Rewards.level(forPoints: points)
        guard let remaining = Rewards.pointsToNextLevel(from: points) else { return 1 }
        let span = Double(points - level.minimumPoints + remaining)
        return span > 0 ? Double(points - level.minimumPoints) / span : 1
    }

    private func levelCard(for me: Neighbour) -> some View {
        VStack(alignment: .leading, spacing: HoTHSpacing.m) {
            HStack {
                Image(badgeImageName(points: me.points))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)
                    .shadow(color: Color.black.opacity(0.12), radius: 8, x: 0, y: 4)
                    .accessibilityHidden(true)
                Spacer()
            }
            Text(verbatim: levelTitle(points: me.points))
                .font(.hothDisplay(34))
                .foregroundStyle(Color.hothInk)
                .accessibilityIdentifier("heroLevelTitle")
            HStack(alignment: .firstTextBaseline, spacing: HoTHSpacing.xs) {
                Text(verbatim: "\(me.points)")
                    .font(.hothDisplay(56))
                    .foregroundStyle(Color.hothAccent)
                    .contentTransition(.numericText())
                    .accessibilityIdentifier("heroPoints")
                Text("points")
                    .font(.hothHeadline)
                    .foregroundStyle(Color.hothInkSecondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.hothSand)
                    Capsule()
                        .fill(LinearGradient(colors: [Color.hothAccent, Color.hothHigh], startPoint: .leading, endPoint: .trailing))
                        .frame(width: proxy.size.width * animatedProgress)
                }
            }
            .frame(height: 10)
            if let remaining = Rewards.pointsToNextLevel(from: me.points) {
                Text("\(remaining) points to the next level")
                    .font(.hothCaption)
                    .foregroundStyle(Color.hothInkSecondary)
            } else {
                Text("Top level reached. Thank you, hero.")
                    .font(.hothCaption)
                    .foregroundStyle(Color.hothInkSecondary)
            }
        }
        .padding(HoTHSpacing.l)
        .background(
            RoundedRectangle(cornerRadius: HoTHRadius.card + 4, style: .continuous)
                .fill(Color.hothSurface)
        )
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: HoTHRadius.card + 10, style: .continuous)
                .fill(Color.hothSand.opacity(0.6))
        )
        .shadow(color: Color.black.opacity(0.05), radius: 20, x: 0, y: 12)
        .onAppear {
            withAnimation(.spring(response: 0.9, dampingFraction: 0.8).delay(0.15)) {
                animatedProgress = progress(points: me.points)
            }
        }
        .onChange(of: me.points) { _, newValue in
            withAnimation(HoTHMotion.spring) { animatedProgress = progress(points: newValue) }
        }
    }

    /// The current neighbour's own reports, newest first; tap opens the case.
    private func myReports(for me: Neighbour) -> some View {
        let reports = me.reports
            .filter(\.isPosted)
            .sorted { $0.createdAt > $1.createdAt }
        return VStack(alignment: .leading, spacing: HoTHSpacing.s) {
            SectionHeader(title: "My reports").accessibilityIdentifier("myReportsHeader")
            if reports.isEmpty {
                emptyReports
            } else {
                HoTHCard(padding: HoTHSpacing.s) {
                    VStack(spacing: 0) {
                        ForEach(Array(reports.enumerated()), id: \.element.id) { index, report in
                            if index > 0 {
                                Divider().overlay(Color.hothInk.opacity(0.04)).padding(.leading, 76)
                            }
                            NavigationLink(value: report.id) { myReportRow(report) }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("myReportRow")
                        }
                    }
                }
            }
        }
    }

    private func myReportRow(_ report: Report) -> some View {
        HStack(spacing: 12) {
            ReportPhotoView(fileName: report.displayPhotoFileName, category: report.category,
                            priority: report.priority, symbolSize: 20)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Text(report.title(arabic: services.isArabic))
                    .font(.hothHeadline)
                    .foregroundStyle(Color.hothInk)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: HoTHSpacing.s) {
                    StatusPill(status: report.status).fixedSize()
                    Text(report.createdAt, format: .relative(presentation: .named))
                        .font(.hothCaption)
                        .foregroundStyle(Color.hothInkSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.forward")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.hothInkSecondary.opacity(0.7))
        }
        .padding(HoTHSpacing.s)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Open case"))
    }

    private var emptyReports: some View {
        HoTHCard {
            VStack(spacing: HoTHSpacing.s) {
                Image("empty_reports")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 200, maxHeight: 160)
                    .accessibilityHidden(true)
                Text("No reports yet")
                    .font(.hothHeadline)
                    .foregroundStyle(Color.hothInk)
                Text("Spot something unsafe? Tap the camera to report it.")
                    .font(.hothBody)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.hothInkSecondary)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func statsRow(for me: Neighbour) -> some View {
        HStack(spacing: HoTHSpacing.m) {
            statTile(value: "\(me.reports.count)", label: "Reports", symbol: "flag.fill")
            statTile(value: "\(me.trust)", label: "Trust", symbol: "hand.raised.fill")
            statTile(value: "\(me.comments.count)", label: "Comments", symbol: "bubble.left.fill")
        }
    }

    private func statTile(value: String, label: LocalizedStringKey, symbol: String) -> some View {
        HoTHCard {
            VStack(alignment: .leading, spacing: HoTHSpacing.xs) {
                Image(systemName: symbol).foregroundStyle(Color.hothTeal)
                Text(verbatim: value).font(.hothDisplay(26)).foregroundStyle(Color.hothInk)
                Text(label).font(.hothCaption).foregroundStyle(Color.hothInkSecondary)
            }
        }
    }

    private var leaderboard: some View {
        VStack(alignment: .leading, spacing: HoTHSpacing.s) {
            SectionHeader(title: "Heroes of the hay")
            HoTHCard {
                VStack(spacing: HoTHSpacing.m) {
                    ForEach(Array(neighbours.prefix(5).enumerated()), id: \.element.id) { index, neighbour in
                        HStack(spacing: HoTHSpacing.m) {
                            Text(verbatim: "\(index + 1)")
                                .font(.hothDisplay(18))
                                .foregroundStyle(Color.hothInkSecondary)
                                .frame(width: 22)
                            Image(systemName: neighbour.avatarSymbol)
                                .font(.system(size: 26))
                                .foregroundStyle(neighbour.isCurrentUser ? Color.hothAccent : Color.hothTeal.opacity(0.7))
                                .overlay(alignment: .bottomTrailing) {
                                    Image(badgeImageName(points: neighbour.points))
                                        .resizable()
                                        .frame(width: 16, height: 16)
                                        .offset(x: 4, y: 4)
                                        .accessibilityHidden(true)
                                }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: neighbour.displayName)
                                    .font(.hothHeadline)
                                    .foregroundStyle(Color.hothInk)
                                Text(verbatim: levelTitle(points: neighbour.points))
                                    .font(.hothCaption)
                                    .foregroundStyle(Color.hothInkSecondary)
                            }
                            Spacer()
                            Text(verbatim: "\(neighbour.points)")
                                .font(.hothHeadline)
                                .foregroundStyle(Color.hothInk)
                        }
                    }
                }
            }
        }
    }
}
