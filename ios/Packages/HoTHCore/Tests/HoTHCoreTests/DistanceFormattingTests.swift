import XCTest
@testable import HoTHCore

final class DistanceFormattingTests: XCTestCase {
    /// Imperial words/symbols that must never appear (en + ar).
    private let imperialMarkers = ["ft", "mi", "yd", "feet", "mile", "قدم", "ميل", "ياردة"]

    private func assertMetric(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
        for marker in imperialMarkers {
            XCTAssertFalse(label.contains(marker), "\(label) contains \(marker)", file: file, line: line)
        }
    }

    // MARK: English (US region and the region-less in-app override both default to imperial)

    func testEnglishUSMetres() {
        let label = DistanceFormatting.string(metres: 233, locale: Locale(identifier: "en_US"))
        XCTAssertEqual(label, "233 m")
        assertMetric(label)
    }

    func testEnglishUSKilometresOneDecimalHalfUp() {
        XCTAssertEqual(DistanceFormatting.string(metres: 1250, locale: Locale(identifier: "en_US")), "1.3 km")
        XCTAssertEqual(DistanceFormatting.string(metres: 12_000, locale: Locale(identifier: "en_US")), "12.0 km")
    }

    func testRegionlessEnglishOverrideIsMetric() {
        let locale = Locale(identifier: "en")
        XCTAssertEqual(DistanceFormatting.string(metres: 763, locale: locale), "763 m")
        XCTAssertEqual(DistanceFormatting.string(metres: 1520, locale: locale), "1.5 km")
    }

    func testThresholdUsesRoundedMetres() {
        let locale = Locale(identifier: "en_US")
        XCTAssertEqual(DistanceFormatting.string(metres: 999.4, locale: locale), "999 m")
        XCTAssertEqual(DistanceFormatting.string(metres: 999.6, locale: locale), "1.0 km")
        XCTAssertEqual(DistanceFormatting.string(metres: 1000, locale: locale), "1.0 km")
    }

    func testZeroNegativeAndNonFiniteClampToZero() {
        let locale = Locale(identifier: "en_US")
        XCTAssertEqual(DistanceFormatting.string(metres: 0, locale: locale), "0 m")
        XCTAssertEqual(DistanceFormatting.string(metres: -5, locale: locale), "0 m")
        XCTAssertEqual(DistanceFormatting.string(metres: .nan, locale: locale), "0 m")
    }

    // MARK: Arabic (exact ICU wording varies by OS, so assert digits and units, not the full string)

    func testArabicMetres() {
        for identifier in ["ar", "ar_AE", "ar_SA"] {
            let locale = Locale(identifier: identifier)
            let label = DistanceFormatting.string(metres: 233, locale: locale)
            XCTAssertTrue(label.contains(localizedDigits("233", locale: locale)), "\(identifier): \(label)")
            XCTAssertTrue(label.contains("م"), "\(identifier): \(label)")
            XCTAssertFalse(label.contains("كم"), "\(identifier): \(label)")
            assertMetric(label)
        }
    }

    func testArabicKilometres() {
        for identifier in ["ar", "ar_AE", "ar_SA"] {
            let locale = Locale(identifier: identifier)
            let label = DistanceFormatting.string(metres: 1250, locale: locale)
            let expectedNumber = 1.3.formatted(.number.precision(.fractionLength(1)).locale(locale))
            XCTAssertTrue(label.contains(expectedNumber), "\(identifier): \(label) lacks \(expectedNumber)")
            XCTAssertTrue(label.contains("كم"), "\(identifier): \(label)")
            assertMetric(label)
        }
    }

    private func localizedDigits(_ integer: String, locale: Locale) -> String {
        (Int(integer) ?? 0).formatted(.number.locale(locale))
    }
}
