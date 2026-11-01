import Foundation

/// Metric distance labels for the app, whatever the device region.
///
/// HoTH serves Abu Dhabi, so distances are always metres or kilometres. `MeasurementFormatter`'s
/// `.naturalScale` follows the locale's measurement system, and a region-less `Locale("en")` (the
/// in-app English override) or an en_US device falls back to feet. Here the unit is chosen by hand
/// and `.providedUnit` keeps it; the locale only drives digits, separators and the unit symbol.
public enum DistanceFormatting {
    /// At or above this many (rounded) metres the label switches to kilometres.
    public static let kilometreThreshold: Double = 1000

    /// - Parameters:
    ///   - metres: distance in metres; negative or non-finite values are treated as 0.
    ///   - locale: pass the SwiftUI environment locale so the in-app language override applies.
    /// - Returns: "233 m" below 1 km (whole metres), "1.3 km" from 1 km up (one decimal, half-up),
    ///   localized for `locale` (e.g. Arabic unit names and, where the locale uses them, Arabic-Indic digits).
    public static func string(metres: Double, locale: Locale) -> String {
        let safeMetres = metres.isFinite ? max(0, metres) : 0
        let roundedMetres = safeMetres.rounded(.toNearestOrAwayFromZero)
        let isKilometres = roundedMetres >= kilometreThreshold

        let formatter = MeasurementFormatter()
        formatter.locale = locale
        formatter.unitOptions = .providedUnit
        formatter.unitStyle = .medium
        formatter.numberFormatter.locale = locale
        formatter.numberFormatter.roundingMode = .halfUp
        formatter.numberFormatter.minimumFractionDigits = isKilometres ? 1 : 0
        formatter.numberFormatter.maximumFractionDigits = isKilometres ? 1 : 0

        let measurement = isKilometres
            ? Measurement(value: safeMetres / 1000, unit: UnitLength.kilometers)
            : Measurement(value: roundedMetres, unit: UnitLength.meters)
        return formatter.string(from: measurement)
    }
}
