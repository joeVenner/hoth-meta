import CoreImage
import UIKit
import Vision
import XCTest
@testable import HoTH

/// Face/plate blurring must leave non-sensitive photos intact and never leak the original on failure.
final class PrivacyBlurTests: XCTestCase {

    // MARK: No faces, no plates → not globally blurred

    func testSpringRiderPhotoIsNotGloballyBlurred() throws {
        let image = try XCTUnwrap(UIImage(named: "demo_springrider"), "demo_springrider asset missing")
        let result = FaceAndPlateBlur.blurSync(image)

        XCTAssertTrue(result.isSafeToPost, "Detection should succeed on a plain photo")
        let output = try XCTUnwrap(result.image)
        let source = try XCTUnwrap(image.cgImage)
        let regions = try FaceAndPlateBlur.detectRegions(in: source)
        let excluded = (regions.faces + regions.plates)
            .map { VNImageRectForNormalizedRect($0, source.width, source.height) }

        let diff = try meanPixelDifference(source, try XCTUnwrap(output.cgImage), excluding: excluded)
        // A whole-image Gaussian blur on this photo moves the mean by well over 10 levels.
        XCTAssertLessThan(diff, 2.0, "Pixels outside detected regions changed (mean diff \(diff))")
    }

    // MARK: Failure path → not posted

    func testFailedBlurCarriesNoImageAndIsNotPostable() {
        // A CIImage-backed UIImage has no CGImage: the blur cannot run and must fail closed.
        let ciOnly = UIImage(ciImage: CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32)))
        let result = FaceAndPlateBlur.blurSync(ciOnly)

        XCTAssertFalse(result.isSafeToPost)
        XCTAssertNil(result.image, "The original must never be returned as the public image")
        XCTAssertFalse(ReportFlowModel.canPostPublicly(wantsToPost: true, blur: result, blurredFileName: "x.jpg"))
    }

    func testCanPostPubliclyRequiresAllConditions() {
        let ok = FaceAndPlateBlur.Result(image: UIImage(), faceCount: 0, plateCount: 0)
        XCTAssertTrue(ReportFlowModel.canPostPublicly(wantsToPost: true, blur: ok, blurredFileName: "a.jpg"))
        XCTAssertFalse(ReportFlowModel.canPostPublicly(wantsToPost: true, blur: ok, blurredFileName: nil))
        XCTAssertFalse(ReportFlowModel.canPostPublicly(wantsToPost: false, blur: ok, blurredFileName: "a.jpg"))
        XCTAssertFalse(ReportFlowModel.canPostPublicly(wantsToPost: true, blur: .failed, blurredFileName: "a.jpg"))
    }

    // MARK: Plate heuristics

    func testPlateTextHeuristic() {
        XCTAssertTrue(FaceAndPlateBlur.isPlateText("A 12345"))
        XCTAssertTrue(FaceAndPlateBlur.isPlateText("AB-123"))
        XCTAssertFalse(FaceAndPlateBlur.isPlateText("PLAYGROUND"), "No digit")
        XCTAssertFalse(FaceAndPlateBlur.isPlateText("7"), "Too short")
        XCTAssertFalse(FaceAndPlateBlur.isPlateText("Call 800 123 4567 now"), "Too long")
        XCTAssertFalse(FaceAndPlateBlur.isPlateText("50% off!"), "Punctuation")
    }

    func testPlateBoxHeuristic() {
        XCTAssertTrue(FaceAndPlateBlur.isPlateLike(CGRect(x: 0.4, y: 0.2, width: 0.12, height: 0.04)))
        XCTAssertFalse(FaceAndPlateBlur.isPlateLike(CGRect(x: 0, y: 0, width: 0.6, height: 0.2)), "Too big")
        XCTAssertFalse(FaceAndPlateBlur.isPlateLike(CGRect(x: 0, y: 0, width: 0.05, height: 0.05)), "Square")
    }

    // MARK: Public photo selection

    func testPublicPhotoNeverFallsBackToOriginalForUserReports() {
        let mine = makeReport(photo: "report_x.jpg", blurred: nil, isDemoSeed: false)
        XCTAssertNil(mine.displayPhotoFileName)
        let blurred = makeReport(photo: "report_x.jpg", blurred: "report_x_public.jpg", isDemoSeed: false)
        XCTAssertEqual(blurred.displayPhotoFileName, "report_x_public.jpg")
        let seed = makeReport(photo: "seed_1", blurred: nil, isDemoSeed: true)
        XCTAssertEqual(seed.displayPhotoFileName, "seed_1")
    }

    // MARK: Helpers

    private func makeReport(photo: String?, blurred: String?, isDemoSeed: Bool) -> Report {
        Report(category: .other, titleEN: "t", titleAR: "t", summaryEN: "s", summaryAR: "s",
               latitude: 0, longitude: 0, placeName: "p", photoFileName: photo,
               blurredPhotoFileName: blurred, priority: .medium, priorityScore: 0,
               priorityReasonEN: "", priorityReasonAR: "", isDemoSeed: isDemoSeed)
    }

    /// Mean absolute RGB difference (0-255) between two same-size images, skipping `excluding` rects
    /// (pixel coordinates, bottom-left origin as returned by Vision).
    private func meanPixelDifference(_ a: CGImage, _ b: CGImage, excluding: [CGRect]) throws -> Double {
        XCTAssertEqual(a.width, b.width)
        XCTAssertEqual(a.height, b.height)
        let pa = try rgba(a), pb = try rgba(b)
        let width = a.width, height = a.height
        var total = 0.0
        var count = 0
        for row in 0..<height {
            let visionY = CGFloat(height - 1 - row)
            for col in 0..<width {
                let point = CGPoint(x: CGFloat(col), y: visionY)
                if excluding.contains(where: { $0.contains(point) }) { continue }
                let i = (row * width + col) * 4
                total += Double(abs(Int(pa[i]) - Int(pb[i])) + abs(Int(pa[i + 1]) - Int(pb[i + 1]))
                                + abs(Int(pa[i + 2]) - Int(pb[i + 2]))) / 3
                count += 1
            }
        }
        return count == 0 ? 0 : total / Double(count)
    }

    private func rgba(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { throw XCTSkip("Could not create bitmap context") }
        return pixels
    }
}

/// Hazard tags never overlap, stay within 60% width, and small boxes fall back to a number badge.
final class HazardLabelLayoutTests: XCTestCase {
    private let size = CGSize(width: 360, height: 540)

    func testLabelsDoNotOverlapAndAreCapped() {
        let boxes = [CGRect(x: 40, y: 220, width: 180, height: 100),
                     CGRect(x: 120, y: 200, width: 80, height: 60),
                     CGRect(x: 90, y: 300, width: 60, height: 50)]
        let items = HazardLabelLayout.layout(boxes: boxes, labelWidths: [300, 400, 150], in: size)
        let frames = items.compactMap(\.labelFrame)
        XCTAssertFalse(frames.isEmpty)
        for (i, a) in frames.enumerated() {
            XCTAssertLessThanOrEqual(a.width, size.width * HazardLabelLayout.maxLabelWidthFraction + 0.5)
            XCTAssertGreaterThanOrEqual(a.minX, 0)
            XCTAssertLessThanOrEqual(a.maxX, size.width)
            for b in frames[(i + 1)...] { XCTAssertFalse(a.intersects(b), "\(a) overlaps \(b)") }
        }
        XCTAssertEqual(items.map(\.number), [1, 2, 3])
    }

    func testCapsuleNeverCoversASmallBoxBadge() {
        // Mirrors the spring rider: a narrow box sitting on top of a wide one.
        let narrow = CGRect(x: 150, y: 200, width: 30, height: 90)
        let wide = CGRect(x: 30, y: 240, width: 190, height: 150)
        let items = HazardLabelLayout.layout(boxes: [narrow, wide], labelWidths: [200, 220], in: size)
        let badge = items[0].badgeCenter
        let badgeRect = CGRect(x: badge.x - 11, y: badge.y - 11, width: 22, height: 22)
        XCTAssertNil(items[0].labelFrame)
        if let capsule = items[1].labelFrame { XCTAssertFalse(capsule.intersects(badgeRect)) }
    }

    func testSmallBoxShowsNumberOnly() {
        let items = HazardLabelLayout.layout(boxes: [CGRect(x: 100, y: 100, width: 30, height: 20)],
                                             labelWidths: [120], in: size)
        XCTAssertNil(items[0].labelFrame)
    }

    func testBoxAtTopEdgePlacesLabelBelow() {
        let box = CGRect(x: 20, y: 2, width: 200, height: 120)
        let frame = HazardLabelLayout.layout(boxes: [box], labelWidths: [120], in: size)[0].labelFrame
        XCTAssertNotNil(frame)
        XCTAssertGreaterThanOrEqual(frame?.minY ?? 0, box.maxY)
    }
}
