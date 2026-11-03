import CoreGraphics
import Foundation
import ImageIO

/// SAM 3.1 boxes for one concept on one photo, ready to draw (0...1, top-left origin).
public struct SegmentOutline: Equatable, Sendable {
    /// The noun phrase SAM was asked for, e.g. "pothole".
    public let concept: String
    /// Best matches first; empty means SAM found nothing (callers keep Muse Spark's boxes then).
    public let boxes: [NormalizedBox]

    public init(concept: String, boxes: [NormalizedBox]) {
        self.concept = concept
        self.boxes = boxes
    }
}

/// Outlines a report category's hazard with SAM 3.1, inside a hard time budget.
///
/// SAM is decoration on top of Muse Spark's analysis: callers treat every error (timeout included) as
/// "no overlay" and never hold the report for it.
public struct HazardSegmenter: Sendable {
    public enum Failure: Error, Equatable {
        case timedOut
    }

    private let client: MetaModelClient
    private let prompts: Prompts
    public let timeout: TimeInterval

    /// - Parameter timeout: total budget for the SAM call. Shorter than the client's 60 s: Spark has
    ///   already answered, so a slow outline is not worth waiting for.
    public init(client: MetaModelClient, prompts: Prompts, timeout: TimeInterval = 20) {
        self.client = client
        self.prompts = prompts
        self.timeout = timeout
    }

    /// - Parameters:
    ///   - jpegData: the exact JPEG sent to the model, upright (orientation `.up`); boxes map onto it.
    ///   - category: picks the concept from prompts.json `segment_concepts`.
    /// - Returns: nil when the category has no concept (no network call); otherwise the selected boxes.
    /// - Throws: `Failure.timedOut` past `timeout`, or the client's `ModelAPIError`.
    public func outline(jpegData: Data, category: ReportCategory) async throws -> SegmentOutline? {
        guard let concept = prompts.segmentConcept(for: category) else { return nil }
        let client = client
        let model = prompts.models.segment
        let instances = try await Self.withTimeout(timeout) {
            try await client.segment(image: ImageInput(jpegData: jpegData), concept: concept, model: model)
        }
        let boxes = SegmentSelection.boxes(from: instances, sentImage: JPEGSize.pixelSize(of: jpegData))
        return SegmentOutline(concept: concept, boxes: boxes)
    }

    /// Runs `operation`, cancelling it and throwing `Failure.timedOut` once `seconds` pass.
    static func withTimeout<T: Sendable>(_ seconds: TimeInterval,
                                         _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
                throw Failure.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw Failure.timedOut }
            return first
        }
    }
}

/// Pixel size of an image as displayed (EXIF orientation applied).
public struct PixelSize: Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public enum JPEGSize {
    /// Reads the size from the image header without decoding pixels. Orientations 5-8 (rotated 90°)
    /// swap width and height, so the result matches what `UIImage` shows.
    public static func pixelSize(of data: Data) -> PixelSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return (5...8).contains(orientation) ? PixelSize(width: height, height: width) : PixelSize(width: width, height: height)
    }
}

/// Which SAM matches get drawn. Pure, so the thresholds are unit tested.
public enum SegmentSelection {
    /// Loose on purpose: SAM's live score distribution is unverified, so only clear noise is dropped.
    public static let minScore = 0.25
    /// Boxes under 0.05% of the photo are specks, not hazards.
    public static let minAreaFraction = 0.0005
    public static let maxBoxes = 3
    /// SAM's `w`/`h` must describe the image that was sent; a different aspect means a rotated or
    /// re-framed image, and its boxes would land in the wrong place.
    public static let aspectTolerance = 0.02

    /// - Parameter sentImage: size of the JPEG that was sent (nil skips the aspect check).
    /// - Returns: up to `maxBoxes` boxes, highest score first (unscored after scored, in SAM's order).
    public static func boxes(from instances: [SegmentedInstance], sentImage: PixelSize?,
                             maxCount: Int = maxBoxes) -> [NormalizedBox] {
        let kept = instances.enumerated().filter { _, instance in
            guard instance.frame == 0, aspectMatches(instance.box, sentImage) else { return false }
            if let score = instance.score, score < minScore { return false }
            let box = instance.box.normalized
            return box.w * box.h >= minAreaFraction
        }
        let ranked = kept.sorted { lhs, rhs in
            switch (lhs.element.score, rhs.element.score) {
            case let (left?, right?) where left != right: return left > right
            case (.some, .none): return true
            case (.none, .some): return false
            default: return lhs.offset < rhs.offset
            }
        }
        return ranked.prefix(max(maxCount, 0)).map { $0.element.box.normalized }
    }

    static func aspectMatches(_ box: PixelBox, _ sentImage: PixelSize?) -> Bool {
        guard let sentImage else { return true }
        let reported = Double(box.sourceWidth) / Double(box.sourceHeight)
        let sent = Double(sentImage.width) / Double(sentImage.height)
        return abs(reported - sent) / sent <= aspectTolerance
    }
}

/// Maps 0...1 image boxes into a view that shows the image aspect-fit or aspect-fill.
public enum OverlayGeometry {
    public enum ContentMode: Sendable {
        case fit
        case fill
    }

    /// Where the whole image lands inside `container` (for `.fill` it overflows and is clipped).
    public static func imageFrame(imageSize: CGSize, in container: CGSize, mode: ContentMode) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, container.width > 0, container.height > 0 else {
            return .zero
        }
        let scaleX = container.width / imageSize.width
        let scaleY = container.height / imageSize.height
        let scale = mode == .fit ? min(scaleX, scaleY) : max(scaleX, scaleY)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// The box in container points. With `.fill` the result may extend past the container (clip it).
    public static func viewRect(for box: NormalizedBox, imageSize: CGSize, in container: CGSize,
                                mode: ContentMode) -> CGRect {
        let frame = imageFrame(imageSize: imageSize, in: container, mode: mode)
        return CGRect(x: frame.minX + box.x * frame.width, y: frame.minY + box.y * frame.height,
                      width: box.w * frame.width, height: box.h * frame.height)
    }
}
