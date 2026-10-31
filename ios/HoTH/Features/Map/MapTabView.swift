import SwiftData
import SwiftUI

/// Map tab: the community's reports full screen, with the same filters and pins as the feed's map
/// layout. Tapping a pin shows its card; tapping the card opens the case.
struct MapTabView: View {
    @ObservedObject private var services = AppServices.shared
    @Query private var reports: [Report]
    @State private var filter: FeedView.Filter = .all

    private var visibleReports: [Report] { FeedView.visibleReports(reports, filter: filter) }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                FeedMapView(reports: visibleReports, arabic: services.isArabic, isFullBleed: true)
                header
                    .padding(.horizontal, HoTHSpacing.m)
                    .padding(.top, HoTHSpacing.xs)
            }
            .background(Color.hothBackground.ignoresSafeArea())
            .navigationDestination(for: UUID.self) { id in
                if let report = reports.first(where: { $0.id == id }) {
                    CaseDetailView(report: report)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    /// Floating glass header, styled like the tab bar so the map reads as one surface.
    private var header: some View {
        VStack(alignment: .leading, spacing: HoTHSpacing.s) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your hay")
                    .font(.hothTitle)
                    .foregroundStyle(Color.hothInk)
                Spacer(minLength: HoTHSpacing.s)
                Text("\(visibleReports.count) reports")
                    .font(.hothCaption.weight(.semibold))
                    .foregroundStyle(Color.hothInkSecondary)
                    .contentTransition(.numericText())
                    .accessibilityIdentifier("mapReportCount")
            }
            FeedFilterBar(filter: $filter)
        }
        .padding(.horizontal, HoTHSpacing.m)
        .padding(.top, HoTHSpacing.m)
        .padding(.bottom, HoTHSpacing.s + 2)
        .background(
            RoundedRectangle(cornerRadius: HoTHRadius.card, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: HoTHRadius.card, style: .continuous)
                    .fill(Color.hothSurface.opacity(0.72)))
        )
        .overlay(RoundedRectangle(cornerRadius: HoTHRadius.card, style: .continuous)
            .strokeBorder(Color.hothInk.opacity(0.06)))
        .shadow(color: Color.black.opacity(0.08), radius: 20, x: 0, y: 8)
    }
}
