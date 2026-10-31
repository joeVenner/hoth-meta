import MapKit
import SwiftUI

/// P2-03: the feed's reports on a map. Pins are coloured by priority (critical pulses); a tap shows a
/// compact card that opens the case. Styling follows `CrewMapView`.
struct FeedMapView: View {
    let reports: [Report]
    let arabic: Bool
    /// Full-screen Map tab layout (edge to edge) instead of the inset card inside the feed.
    var isFullBleed: Bool = false
    @State private var selectedID: UUID?
    @State private var position: MapCameraPosition = .region(MKCoordinateRegion(
        center: FeedGeography.home.coordinate,
        span: MKCoordinateSpan(latitudeDelta: 0.022, longitudeDelta: 0.022)
    ))

    private var selected: Report? { reports.first { $0.id == selectedID } }

    var body: some View {
        if isFullBleed {
            // Map tab: edge to edge under the header and floating tab bar; the card stays in the safe area.
            ZStack(alignment: .bottom) {
                map.ignoresSafeArea()
                selectedCard
            }
        } else {
            map
                .overlay(alignment: .bottom) { selectedCard }
                .clipShape(RoundedRectangle(cornerRadius: HoTHRadius.card, style: .continuous))
                .padding(.horizontal, HoTHSpacing.m)
                .padding(.bottom, 100)
        }
    }

    private var map: some View {
        Map(position: $position) {
            // Critical last so their pins sit on top.
            ForEach(reports.sorted { $0.priorityScore < $1.priorityScore }) { report in
                Annotation(report.title(arabic: arabic),
                           coordinate: CLLocationCoordinate2D(latitude: report.latitude, longitude: report.longitude)) {
                    FeedMapPin(report: report, arabic: arabic, isSelected: report.id == selectedID) {
                        Haptics.tap()
                        withAnimation(HoTHMotion.spring) {
                            selectedID = selectedID == report.id ? nil : report.id
                        }
                    }
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .mapControls { if !isFullBleed { MapCompass() } }
        .onChange(of: reports.map(\.id)) { _, ids in
            // A filter change can hide the selected report.
            if let selectedID, !ids.contains(selectedID) { self.selectedID = nil }
        }
    }

    @ViewBuilder private var selectedCard: some View {
        if let selected {
            NavigationLink(value: selected.id) {
                FeedMapCard(report: selected, arabic: arabic)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("feedMapCard")
            .padding(.horizontal, HoTHSpacing.m)
            // Full bleed: clear the floating tab bar (its inset doesn't reach the tab pages).
            .padding(.bottom, isFullBleed ? 96 : HoTHSpacing.m)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// Priority-coloured pin; critical ones pulse unless Reduce Motion is on.
private struct FeedMapPin: View {
    let report: Report
    let arabic: Bool
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    private var isCritical: Bool { report.priority == .critical && report.status != .fixed }

    var body: some View {
        Button(action: action) {
            ZStack {
                if isCritical {
                    Circle()
                        .fill(report.priority.tint.opacity(0.35))
                        .frame(width: 34, height: 34)
                        .scaleEffect(isPulsing ? 1.9 : 1)
                        .opacity(isPulsing ? 0 : 0.9)
                }
                Circle().fill(report.priority.tint).frame(width: 34, height: 34)
                    .shadow(color: report.priority.tint.opacity(0.5), radius: 6)
                Image(systemName: report.category.fallbackSymbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .overlay(Circle().strokeBorder(.white, lineWidth: isSelected ? 3 : 2).frame(width: 34, height: 34))
            .scaleEffect(isSelected ? 1.18 : 1)
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: report.title(arabic: arabic)))
        .accessibilityIdentifier("feedMapPin_\(report.priorityRaw)")
        .onAppear {
            guard isCritical, !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { isPulsing = true }
        }
    }
}

/// Compact card for the selected pin: photo, priority, title, place and distance.
private struct FeedMapCard: View {
    @Environment(\.locale) private var locale
    let report: Report
    let arabic: Bool

    var body: some View {
        HStack(spacing: 12) {
            ReportPhotoView(fileName: report.displayPhotoFileName, category: report.category,
                            priority: report.priority, symbolSize: 22)
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    PriorityBadge(levelRaw: report.priorityRaw).fixedSize()
                    if report.status == .fixed || report.status == .inProgress {
                        StatusPill(status: report.status).fixedSize()
                    }
                }
                .lineLimit(1)
                Text(report.title(arabic: arabic))
                    .font(.hothHeadline)
                    .foregroundStyle(Color.hothInk)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: HoTHSpacing.xs) {
                    Image(systemName: "mappin.and.ellipse")
                    Text(verbatim: report.placeName)
                    Text(verbatim: "·")
                    Text(verbatim: FeedGeography.formattedDistance(report.distanceFromHome, locale: locale))
                }
                .font(.hothCaption)
                .foregroundStyle(Color.hothInkSecondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.forward")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.hothInkSecondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: HoTHRadius.card, style: .continuous).fill(Color.hothSurface))
        .overlay(RoundedRectangle(cornerRadius: HoTHRadius.card, style: .continuous)
            .strokeBorder(Color.hothInk.opacity(0.06), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.12), radius: 18, x: 0, y: 8)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Open case"))
    }
}
