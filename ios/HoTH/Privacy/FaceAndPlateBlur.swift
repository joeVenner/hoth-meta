import CoreImage
import CoreImage.CIFilterBuiltins
import OSLog
import UIKit
import Vision

/// On-device face and licence-plate blurring with Apple Vision (P0-18).
///
/// The blurred image is the only one ever posted to the neighbourhood feed; the original stays on
/// the device for the ticket. Only detected faces and plate-like text (a short alphanumeric string
/// with a digit, in a small, wide rectangle) are obscured; everything else is left untouched.
/// If detection or rendering fails, the result is marked unsafe and carries no image, so the
/// caller keeps the report private instead of posting either the original or a smeared photo.
enum FaceAndPlateBlur {
    struct Result {
        /// The redacted image; nil whenever redaction could not be guaranteed.
        let image: UIImage?
        let faceCount: Int
        let plateCount: Int
        /// False on every failure path: the photo must not be posted publicly.
        var isSafeToPost: Bool { image != nil }

        static let failed = Result(image: nil, faceCount: 0, plateCount: 0)
    }

    /// Plates (and the text line Vision boxes on them) are wide and short.
    static let plateAspectRange: ClosedRange<CGFloat> = 1.5...6.5
    /// Ignore tiny text (far-away signage) and big blocks (posters, shop signs).
    static let plateAreaRange: ClosedRange<CGFloat> = 0.0002...0.05
    /// Plate numbers are short: e.g. "A 12345", "DUBAI 1234", "AB-123".
    static let plateCharacterRange: ClosedRange<Int> = 2...10

    private static let logger = Logger(subsystem: "io.fomy.hoth", category: "Privacy")

    /// Detects faces and plate-like text and blurs only those regions. Never throws: on failure the
    /// result is `Result.failed` (`isSafeToPost == false`).
    static func blur(_ image: UIImage) async -> Result {
        await Task.detached(priority: .userInitiated) {
            blurSync(image)
        }.value
    }

    static func blurSync(_ image: UIImage) -> Result {
        // Vision and Core Image both use bottom-left normalized coordinates on an upright image.
        let upright = image.imageOrientation == .up
            ? image
            : ImageResizing.normalizedAndDownsized(image, maxEdge: max(image.size.width, image.size.height))
        guard let cgImage = upright.cgImage else {
            logger.error("Blur failed: image has no CGImage backing")
            return .failed
        }

        let regions: DetectedRegions
        do {
            regions = try detectRegions(in: cgImage)
        } catch {
            logger.error("Vision request failed: \(error.localizedDescription)")
            return .failed
        }

        let all = regions.faces + regions.plates
        guard !all.isEmpty else {
            return Result(image: upright, faceCount: 0, plateCount: 0)
        }
        guard let output = blurRegions(all, in: cgImage, scale: upright.scale) else {
            logger.error("Blur failed: could not render the redacted image")
            return .failed
        }
        return Result(image: output, faceCount: regions.faces.count, plateCount: regions.plates.count)
    }

    // MARK: Detection

    struct DetectedRegions {
        let faces: [CGRect]
        let plates: [CGRect]
    }

    /// Normalized (bottom-left origin) rectangles to obscure. Throws if Vision itself fails.
    static func detectRegions(in cgImage: CGImage) throws -> DetectedRegions {
        let faceRequest = VNDetectFaceRectanglesRequest()
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = false
        #if targetEnvironment(simulator)
        // The simulator has no Neural Engine/GPU inference context; CPU keeps detection working.
        faceRequest.usesCPUOnly = true
        textRequest.usesCPUOnly = true
        #endif
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([faceRequest, textRequest])

        let faces = (faceRequest.results ?? []).map { padded($0.boundingBox, by: 0.25) }
        let plates = (textRequest.results ?? [])
            .filter { observation in
                guard let text = observation.topCandidates(1).first?.string else { return false }
                return isPlateLike(observation.boundingBox) && isPlateText(text)
            }
            .map { padded($0.boundingBox, by: 0.15) }
        return DetectedRegions(faces: faces, plates: plates)
    }

    // MARK: Heuristics (pure)

    static func isPlateLike(_ box: CGRect) -> Bool {
        guard box.height > 0 else { return false }
        let aspect = box.width / box.height
        let area = box.width * box.height
        return plateAspectRange.contains(aspect) && plateAreaRange.contains(area)
    }

    /// Short, mostly alphanumeric, with at least one digit (every plate number has one).
    static func isPlateText(_ text: String) -> Bool {
        let compact = text.filter { !$0.isWhitespace && $0 != "-" && $0 != "·" && $0 != "." }
        guard plateCharacterRange.contains(compact.count) else { return false }
        guard compact.contains(where: \.isNumber) else { return false }
        return compact.allSatisfy { $0.isLetter || $0.isNumber }
    }

    static func padded(_ box: CGRect, by fraction: CGFloat) -> CGRect {
        box.insetBy(dx: -box.width * fraction, dy: -box.height * fraction)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    // MARK: Rendering

    private static let context = CIContext(options: nil)

    private static func blurRegions(_ regions: [CGRect], in cgImage: CGImage, scale: CGFloat) -> UIImage? {
        let base = CIImage(cgImage: cgImage)
        let extent = base.extent
        let radius = max(extent.width, extent.height) * 0.03

        let blurred = base.clampedToExtent()
            .applyingGaussianBlur(sigma: radius)
            .cropped(to: extent)
        let pixellate = CIFilter.pixellate()
        pixellate.inputImage = blurred.clampedToExtent()
        pixellate.scale = Float(max(8, radius))
        let obscured = (pixellate.outputImage ?? blurred).cropped(to: extent)

        var mask = CIImage(color: .black).cropped(to: extent)
        for region in regions {
            let rect = VNImageRectForNormalizedRect(region, Int(extent.width), Int(extent.height))
            let white = CIImage(color: .white).cropped(to: rect)
            mask = white.composited(over: mask)
        }

        let blend = CIFilter.blendWithMask()
        blend.inputImage = obscured
        blend.backgroundImage = base
        blend.maskImage = mask
        guard let output = blend.outputImage,
              let rendered = context.createCGImage(output, from: extent) else { return nil }
        return UIImage(cgImage: rendered, scale: scale, orientation: .up)
    }
}
