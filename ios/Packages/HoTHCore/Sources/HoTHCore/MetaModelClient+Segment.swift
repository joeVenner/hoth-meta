import Foundation

/// SAM box in the source pixels of the image that was sent (`w`/`h` are that image's size).
public struct PixelBox: Equatable, Sendable {
    public let x1: Int
    public let y1: Int
    public let x2: Int
    public let y2: Int
    public let sourceWidth: Int
    public let sourceHeight: Int

    /// The same box as a 0...1 highlight region, ready for the overlays that draw `NormalizedBox`.
    public var normalized: NormalizedBox {
        NormalizedBox.fromCorners(x1: Double(x1), y1: Double(y1), x2: Double(x2), y2: Double(y2),
                                  width: Double(sourceWidth), height: Double(sourceHeight))
    }
}

/// SAM mask, kept encoded: the payload is base85 with an alphabet the docs don't pin down, so it is
/// not decoded here. `height` x `width` is the mask raster (smaller than the image; scale to draw).
public struct SegmentMask: Equatable, Sendable {
    public enum Encoding: String, Sendable {
        case lossless = "~"
        case oneBit = "!"
    }

    public let height: Int
    public let width: Int
    public let encoding: Encoding
    public let payload: String
}

/// One object SAM 3.1 found for a concept prompt.
public struct SegmentedInstance: Equatable, Sendable {
    /// Stable per-object id within a response (not dense, not 0-based).
    public let objectId: Int
    /// Frame index; always 0 for a still image.
    public let frame: Int
    public let box: PixelBox
    public let mask: SegmentMask?
    /// 0...1, present when the request asked for confidence.
    public let score: Double?
}

extension MetaModelClient {
    /// SAM 3.1 concept segmentation over POST /v1/responses (non-streaming).
    ///
    /// - Parameters:
    ///   - image: the JPEG to segment; returned boxes are in its pixels.
    ///   - concept: one short noun phrase ("broken swing"); one concept per request. Blank returns [].
    ///   - model: e.g. `prompts.models.segment`.
    /// - Returns: every match; an empty array is a normal "nothing found" result.
    public func segment(
        image: ImageInput,
        concept: String,
        model: String,
        includeConfidence: Bool = true
    ) async throws -> [SegmentedInstance] {
        let phrase = concept.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { return [] }
        // SAM takes no system prompt, reasoning or text.format; metadata values must be strings.
        let body: JSONValue = .object([
            "model": .string(model),
            "input": .array([
                .object([
                    "type": .string("message"),
                    "role": .string("user"),
                    "content": .array([
                        .object(["type": .string("input_text"), "text": .string(phrase)]),
                        .object(["type": .string("input_image"), "image_url": .string(image.dataURL)])
                    ])
                ])
            ]),
            "metadata": .object([
                "include_confidence": .string(includeConfidence ? "true" : "false"),
                "mask_encoding": .string("one_bit")
            ])
        ])
        let data = try await postJSON(path: "responses", body: body)
        guard let text = try Self.extractOutputText(from: data) else { return [] }
        return SAMOutputParser.parse(text)
    }
}

/// Parses SAM's special-token text (dev.meta.ai/docs/sam/reading-segmentation):
/// `<Nf>id<|box;x1=..;y1=..;x2=..;y2=..;w=..;h=..[;c=..]|><|mask;x=0;y=0[;c=..];data=H,W,<enc>payload|>,id...`
/// one line per frame. Malformed records are skipped rather than failing the whole response.
public enum SAMOutputParser {
    // The mask payload is base85 and may contain `|` or `>`, so a mask only ends at `|>` followed by the
    // next record (`,<id><|box;`) or the end of the line.
    private static let record = try! NSRegularExpression(
        pattern: #"(\d+)<\|box;([^|]*)\|>(?:<\|mask;(.*?)\|>(?=,\d+<\|box;|$))?"#)
    private static let frame = try! NSRegularExpression(pattern: #"^<(\d+)f>"#)

    public static func parse(_ text: String) -> [SegmentedInstance] {
        text.split(whereSeparator: \.isNewline).flatMap { parseLine(String($0)) }
    }

    static func parseLine(_ rawLine: String) -> [SegmentedInstance] {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        let whole = NSRange(line.startIndex..., in: line)
        guard let frameMatch = frame.firstMatch(in: line, range: whole),
              let frameIndex = Int(substring(line, frameMatch.range(at: 1)) ?? "") else { return [] }
        let rest = NSRange(location: frameMatch.range.upperBound, length: whole.length - frameMatch.range.upperBound)

        return record.matches(in: line, range: rest).compactMap { match in
            guard let objectId = Int(substring(line, match.range(at: 1)) ?? ""),
                  let boxFields = substring(line, match.range(at: 2)).map(fields),
                  let box = pixelBox(boxFields) else { return nil }
            let maskText = substring(line, match.range(at: 3))
            let mask = maskText.flatMap(parseMask)
            let score = boxFields["c"].flatMap(Double.init) ?? maskText.flatMap(maskConfidence)
            return SegmentedInstance(objectId: objectId, frame: frameIndex, box: box, mask: mask, score: score)
        }
    }

    private static func substring(_ line: String, _ range: NSRange) -> String? {
        guard range.location != NSNotFound, let swiftRange = Range(range, in: line) else { return nil }
        return String(line[swiftRange])
    }

    /// `k=v;k=v` → dictionary; read by key so the optional `c` can sit anywhere.
    private static func fields(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in text.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { result[String(parts[0])] = String(parts[1]) }
        }
        return result
    }

    private static func pixelBox(_ fields: [String: String]) -> PixelBox? {
        guard let x1 = fields["x1"].flatMap(Int.init), let y1 = fields["y1"].flatMap(Int.init),
              let x2 = fields["x2"].flatMap(Int.init), let y2 = fields["y2"].flatMap(Int.init),
              let width = fields["w"].flatMap(Int.init), let height = fields["h"].flatMap(Int.init),
              width > 0, height > 0 else { return nil }
        return PixelBox(x1: x1, y1: y1, x2: x2, y2: y2, sourceWidth: width, sourceHeight: height)
    }

    /// `x=0;y=0[;c=..];data=H,W,<enc>payload`. Only the first character after `H,W,` is the marker.
    private static func parseMask(_ text: String) -> SegmentMask? {
        guard let dataRange = text.range(of: "data=") else { return nil }
        let value = text[dataRange.upperBound...]
        let pieces = value.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false)
        guard pieces.count == 3, let height = Int(pieces[0]), let width = Int(pieces[1]),
              let marker = pieces[2].first,
              let encoding = SegmentMask.Encoding(rawValue: String(marker)) else { return nil }
        return SegmentMask(height: height, width: width, encoding: encoding, payload: String(pieces[2].dropFirst()))
    }

    private static func maskConfidence(_ text: String) -> Double? {
        guard let dataRange = text.range(of: ";data=") else { return nil }
        return fields(String(text[..<dataRange.lowerBound]))["c"].flatMap(Double.init)
    }
}
