import MapKit
import SwiftData
import SwiftUI

/// City Crew mode (P1-02): ranked queue of open / in-progress cases, team filter, and a map.
struct CrewView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case queue, map
        var id: String { rawValue }
    }

    @ObservedObject private var services = AppServices.shared
    @Query private var reports: [Report]
    @State private var mode: Mode = .queue
    @State private var teamFilter: String?

    private var ranked: [Report] { CrewQueue.ranked(reports, teamNameEN: teamFilter) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, HoTHSpacing.m)
                    .padding(.top, HoTHSpacing.m)
                switch mode {
                case .queue: queue
                case .map: CrewMapView(reports: ranked)
                }
            }
            .background(Color.hothBackground.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            // Value-based so the case stays open after it leaves the queue (fixed).
            .navigationDestination(for: UUID.self) { id in
                if let report = reports.first(where: { $0.id == id }) {
                    CrewCaseView(report: report)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: HoTHSpacing.s) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("City Crew")
                        .font(.hothDisplay(34))
                        .hothTracking(-1)
                        .foregroundStyle(Color.hothInk)
                    Text("\(ranked.count) open cases, most urgent first")
                        .font(.hothCaption)
                        .foregroundStyle(Color.hothInkSecondary)
                }
                Spacer()
                teamMenu
            }
            Picker("View", selection: $mode) {
                Text("Queue").tag(Mode.queue)
                Text("Map").tag(Mode.map)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("crewModePicker")
        }
        .padding(.bottom, HoTHSpacing.s)
    }

    private var teamMenu: some View {
        Menu {
            Button { teamFilter = nil } label: {
                Label("All teams", systemImage: teamFilter == nil ? "checkmark" : "person.3.fill")
            }
            ForEach(CrewQueue.allTeams, id: \.nameEN) { team in
                Button { teamFilter = team.nameEN } label: {
                    Label(team.name(arabic: services.isArabic),
                          systemImage: teamFilter == team.nameEN ? "checkmark" : team.symbol)
                }
            }
        } label: {
            HStack(spacing: HoTHSpacing.xs) {
                Image(systemName: "line.3.horizontal.decrease.circle.fill")
                Text(currentTeamName).lineLimit(1)
            }
            .font(.hothCaption.weight(.semibold))
            .foregroundStyle(Color.hothTeal)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color.hothTeal.opacity(0.12)))
        }
        .accessibilityIdentifier("crewTeamFilter")
    }

    private var currentTeamName: String {
        guard let teamFilter, let team = CrewQueue.allTeams.first(where: { $0.nameEN == teamFilter }) else {
            return String(localized: "All teams")
        }
        return team.name(arabic: services.isArabic)
    }

    private var queue: some View {
        ScrollView {
            VStack(spacing: HoTHSpacing.m) {
                if ranked.isEmpty {
                    Text("No open cases for this team.")
                        .font(.hothBody)
                        .foregroundStyle(Color.hothInkSecondary)
                        .padding(.top, HoTHSpacing.xl)
                }
                ForEach(Array(ranked.enumerated()), id: \.element.id) { index, report in
                    NavigationLink(value: report.id) {
                        CrewRow(rank: index + 1, report: report, isArabic: services.isArabic)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("crewRow_\(index + 1)")
                }
            }
            .padding(.horizontal, HoTHSpacing.m)
            .padding(.top, HoTHSpacing.xs)
            .padding(.bottom, 120)
        }
    }
}

/// One queue row: rank, priority, category, team, age, confirmations, AI reason.
struct CrewRow: View {
    let rank: Int
    let report: Report
    let isArabic: Bool
    @Environment(\.locale) private var locale

    var body: some View {
        HoTHCard(padding: 14) {
            HStack(alignment: .top, spacing: 12) {
                ReportPhotoView(fileName: report.displayPhotoFileName, category: report.category,
                                priority: report.priority, symbolSize: 22)
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        Text("\(rank)")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(report.priority.tint))
                            .offset(x: -6, y: -6)
                    }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        PriorityBadge(levelRaw: report.priorityRaw)
                        Text("\(report.priorityScore)")
                            .font(.hothCaption.weight(.bold).monospacedDigit())
                            .foregroundStyle(report.priority.tint)
                        Spacer(minLength: 0)
                        if report.status == .inProgress { StatusPill(status: .inProgress) }
                    }
                    Text(report.title(arabic: isArabic))
                        .font(.hothHeadline)
                        .foregroundStyle(Color.hothInk)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(report.priorityReason(arabic: isArabic))
                        .font(.hothCaption)
                        .foregroundStyle(Color.hothInkSecondary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        CategoryChip(categoryRaw: report.categoryRaw)
                        let team = CrewQueue.team(for: report)
                        Label(team.name(arabic: isArabic), systemImage: team.symbol)
                            .font(.hothCaption)
                            .foregroundStyle(Color.hothTeal)
                            .lineLimit(1)
                    }
                    HStack(spacing: HoTHSpacing.m) {
                        Label(CrewFormat.age(report.createdAt, locale: locale), systemImage: "clock")
                        Label("\(CrewFormat.confirmations(report)) confirmed", systemImage: "person.2.fill")
                    }
                    .font(.hothCaption)
                    .foregroundStyle(Color.hothInkSecondary)
                }
            }
        }
    }
}

enum CrewFormat {
    static func age(_ date: Date, locale: Locale) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: .now)
    }

    static func confirmations(_ report: Report) -> Int { max(report.confirmations, report.voteCount) }
}

/// Map of open cases, pins coloured by priority.
struct CrewMapView: View {
    let reports: [Report]
    @ObservedObject private var services = AppServices.shared
    @State private var position: MapCameraPosition = .region(MKCoordinateRegion(
        center: FeedGeography.home.coordinate,
        span: MKCoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.03)
    ))

    var body: some View {
        Map(position: $position) {
            ForEach(reports) { report in
                Annotation(report.title(arabic: services.isArabic),
                           coordinate: CLLocationCoordinate2D(latitude: report.latitude, longitude: report.longitude)) {
                    NavigationLink(value: report.id) {
                        ZStack {
                            Circle().fill(report.priority.tint).frame(width: 34, height: 34)
                                .shadow(color: report.priority.tint.opacity(0.5), radius: 6)
                            Image(systemName: report.category.fallbackSymbol)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                    }
                }
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .padding(.bottom, 90)
    }
}
