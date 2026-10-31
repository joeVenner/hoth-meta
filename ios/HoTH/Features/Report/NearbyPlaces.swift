import Foundation
import HoTHCore
import MapKit
import OSLog

/// P2-02: on-device MapKit lookup of child-relevant places (playground / school / park) within 100 m
/// of the capture. No network call of ours: MapKit answers on device. Bounded by a short timeout so
/// it can never hold up the report flow; on any miss the vision `scene_type` decides.
enum NearbyPlaces {
    static let searchRadius: CLLocationDistance = 100
    static let timeout: Duration = .milliseconds(1500)

    /// POI categories worth asking MapKit about. iOS 17 has no dedicated playground category, so an
    /// amusement park stands in for it.
    static let categories: [MKPointOfInterestCategory] = [.amusementPark, .school, .park, .nationalPark]

    private static let logger = Logger(subsystem: "io.fomy.hoth", category: "NearbyPlaces")

    /// Pure mapping from the categories MapKit returned to the priority agent's location type.
    /// Child-safety precedence: playground > school > park. Nil when nothing relevant is nearby.
    nonisolated static func locationType(for categories: [MKPointOfInterestCategory?]) -> LocationType? {
        let found = Set(categories.compactMap { $0 })
        if found.contains(.amusementPark) { return .playground }
        if found.contains(.school) { return .school }
        if found.contains(.park) || found.contains(.nationalPark) { return .park }
        return nil
    }

    /// Whether a lookup is worth running: never in demo mode (canned places), never on the simulator
    /// (no real fix), and only with a real GPS fix.
    nonisolated static func shouldLookUp(isDemoMode: Bool, hasGPS: Bool) -> Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return !isDemoMode && hasGPS
        #endif
    }

    /// Looks up the nearest relevant place, returning nil on timeout, error or no match.
    static func lookUp(latitude: Double, longitude: Double, timeout: Duration = timeout) async -> LocationType? {
        let center = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        return await withTaskGroup(of: LocationType??.self) { group in
            group.addTask { .some(await search(center: center)) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .none  // timed out
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? nil
        }
    }

    /// One MapKit request. Cancelling the task cancels the search, so the timeout above is honoured.
    private static func search(center: CLLocationCoordinate2D) async -> LocationType? {
        let request = MKLocalPointsOfInterestRequest(center: center, radius: searchRadius)
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: categories)
        let search = MKLocalSearch(request: request)
        return await withTaskCancellationHandler {
            do {
                let response = try await search.start()
                return locationType(for: response.mapItems.map(\.pointOfInterestCategory))
            } catch {
                logger.info("Nearby place lookup unavailable: \(String(describing: error))")
                return nil
            }
        } onCancel: {
            search.cancel()
        }
    }
}
