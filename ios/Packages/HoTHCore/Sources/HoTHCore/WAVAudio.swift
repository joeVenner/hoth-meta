import Foundation

/// A mono 16-bit PCM WAV that Muse Voice Transcribe accepts (16 or 24 kHz).
public struct PCMWAV: Equatable, Sendable {
    /// Canonical RIFF/WAVE: one 16-byte `fmt ` chunk, then `data`, nothing else (44-byte header).
    public let data: Data
    public let sampleRate: Int
    public let durationMs: Int
}

/// Errors from reading a recorded WAV before upload.
public enum WAVAudioError: Error, Equatable, CustomStringConvertible {
    case notRIFFWave
    case missingChunk(String)
    case unsupportedFormat(String)

    public var description: String {
        switch self {
        case .notRIFFWave: return "Audio is not a RIFF/WAVE file"
        case .missingChunk(let id): return "Audio has no '\(id)' chunk"
        case .unsupportedFormat(let detail): return "Audio format not supported: \(detail)"
        }
    }
}

/// Rewrites a WAV to the canonical 44-byte-header layout.
///
/// Apple's file writer may add padding chunks (e.g. `FLLR`) between `fmt ` and `data`. A strict reader
/// could reject those, so the app uploads only `fmt ` + `data`. Also checks the format up front, since the
/// endpoint answers anything but mono 16-bit PCM at 16/24 kHz with a 400.
public enum WAVAudio {
    public static let supportedSampleRates: Set<Int> = [16_000, 24_000]

    public static func canonicalPCM16(_ wav: Data) throws -> PCMWAV {
        let bytes = [UInt8](wav)
        guard bytes.count >= 12, ascii(bytes, 0) == "RIFF", ascii(bytes, 8) == "WAVE" else {
            throw WAVAudioError.notRIFFWave
        }

        var format: (channels: Int, sampleRate: Int, bits: Int, audioFormat: Int)?
        var samples: ArraySlice<UInt8>?
        var offset = 12
        while offset + 8 <= bytes.count {
            let id = ascii(bytes, offset)
            let size = Int(uint32(bytes, offset + 4))
            let start = offset + 8
            // A truncated last chunk (recording cut short) keeps what is there.
            let end = min(start + size, bytes.count)
            if id == "fmt ", end - start >= 16 {
                format = (channels: Int(uint16(bytes, start + 2)), sampleRate: Int(uint32(bytes, start + 4)),
                          bits: Int(uint16(bytes, start + 14)), audioFormat: Int(uint16(bytes, start)))
            } else if id == "data" {
                samples = bytes[start..<end]
            }
            // Chunks are word-aligned: odd sizes carry one pad byte.
            offset = start + size + (size % 2)
        }

        guard let format else { throw WAVAudioError.missingChunk("fmt ") }
        guard let samples else { throw WAVAudioError.missingChunk("data") }
        // 1 = PCM; 0xFFFE = WAVE_FORMAT_EXTENSIBLE, which Apple uses for some PCM files.
        guard format.audioFormat == 1 || format.audioFormat == 0xFFFE else {
            throw WAVAudioError.unsupportedFormat("format tag \(format.audioFormat)")
        }
        guard format.channels == 1 else { throw WAVAudioError.unsupportedFormat("\(format.channels) channels") }
        guard format.bits == 16 else { throw WAVAudioError.unsupportedFormat("\(format.bits)-bit") }
        guard supportedSampleRates.contains(format.sampleRate) else {
            throw WAVAudioError.unsupportedFormat("\(format.sampleRate) Hz")
        }

        // Drop a dangling half sample so the data length stays a multiple of the block size.
        let pcm = samples.prefix(samples.count - samples.count % 2)
        let output = header(sampleRate: format.sampleRate, dataSize: pcm.count) + Data(pcm)
        let durationMs = pcm.count * 1000 / (format.sampleRate * 2)
        return PCMWAV(data: output, sampleRate: format.sampleRate, durationMs: durationMs)
    }

    /// 44-byte header for mono 16-bit PCM.
    static func header(sampleRate: Int, dataSize: Int) -> Data {
        var data = Data()
        func append(_ text: String) { data.append(Data(text.utf8)) }
        func append32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: Int) { withUnsafeBytes(of: UInt16(value).littleEndian) { data.append(contentsOf: $0) } }
        append("RIFF")
        append32(36 + dataSize)
        append("WAVE")
        append("fmt ")
        append32(16)
        append16(1)               // PCM
        append16(1)               // mono
        append32(sampleRate)
        append32(sampleRate * 2)  // byte rate
        append16(2)               // block align
        append16(16)              // bits per sample
        append("data")
        append32(dataSize)
        return data
    }

    private static func ascii(_ bytes: [UInt8], _ offset: Int) -> String {
        guard offset + 4 <= bytes.count else { return "" }
        return String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
    }

    private static func uint16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func uint32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * UInt32($1)) }
    }
}
