import XCTest
@testable import HoTHCore

/// Canonical WAV rewrite before upload to Muse Voice Transcribe.
final class WAVAudioTests: XCTestCase {
    /// Builds a WAV the way Apple's writer can: `fmt `, optional padding chunks, then `data`.
    private func wav(channels: Int = 1, sampleRate: Int = 24_000, bits: Int = 16, formatTag: Int = 1,
                     extraChunks: [(String, Int)] = [], pcm: Data) -> Data {
        var body = Data("WAVE".utf8)
        func chunk(_ id: String, _ payload: Data) {
            body.append(Data(id.utf8))
            withUnsafeBytes(of: UInt32(payload.count).littleEndian) { body.append(contentsOf: $0) }
            body.append(payload)
            if payload.count % 2 == 1 { body.append(0) }
        }
        var fmt = Data()
        func put16(_ value: Int) { withUnsafeBytes(of: UInt16(value).littleEndian) { fmt.append(contentsOf: $0) } }
        func put32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { fmt.append(contentsOf: $0) } }
        put16(formatTag); put16(channels); put32(sampleRate)
        put32(sampleRate * channels * bits / 8); put16(channels * bits / 8); put16(bits)
        chunk("fmt ", fmt)
        for (id, size) in extraChunks { chunk(id, Data(repeating: 0, count: size)) }
        chunk("data", pcm)
        var file = Data("RIFF".utf8)
        withUnsafeBytes(of: UInt32(body.count).littleEndian) { file.append(contentsOf: $0) }
        return file + body
    }

    func testStripsPaddingChunksToA44ByteHeader() throws {
        let pcm = Data((0..<48_000).map { UInt8($0 % 251) })  // 1 s at 24 kHz, 16-bit mono
        let result = try WAVAudio.canonicalPCM16(wav(extraChunks: [("FLLR", 4044), ("odd ", 3)], pcm: pcm))

        XCTAssertEqual(result.sampleRate, 24_000)
        XCTAssertEqual(result.durationMs, 1000)
        XCTAssertEqual(result.data.count, 44 + pcm.count)
        XCTAssertEqual(result.data.prefix(44), WAVAudio.header(sampleRate: 24_000, dataSize: pcm.count))
        XCTAssertEqual(result.data.suffix(from: 44), pcm)
        XCTAssertEqual(String(decoding: result.data[36..<40], as: UTF8.self), "data")
    }

    func testHeaderFieldsAreLittleEndianMono16Bit() {
        let header = [UInt8](WAVAudio.header(sampleRate: 16_000, dataSize: 10))
        XCTAssertEqual(header.count, 44)
        XCTAssertEqual(Array(header[4..<8]), [46, 0, 0, 0])            // RIFF size = 36 + 10
        XCTAssertEqual(Array(header[20..<24]), [1, 0, 1, 0])           // PCM, mono
        XCTAssertEqual(Array(header[24..<28]), [0x80, 0x3E, 0, 0])     // 16000
        XCTAssertEqual(Array(header[28..<32]), [0x00, 0x7D, 0, 0])     // 32000 bytes/s
        XCTAssertEqual(Array(header[32..<36]), [2, 0, 16, 0])          // block align 2, 16-bit
        XCTAssertEqual(Array(header[40..<44]), [10, 0, 0, 0])
    }

    func testAcceptsSixteenKilohertzAndExtensibleTag() throws {
        let result = try WAVAudio.canonicalPCM16(wav(sampleRate: 16_000, formatTag: 0xFFFE, pcm: Data(count: 3_200)))
        XCTAssertEqual(result.sampleRate, 16_000)
        XCTAssertEqual(result.durationMs, 100)
    }

    func testTruncatedDataChunkKeepsWholeSamples() throws {
        var file = wav(pcm: Data(count: 100))
        file.removeLast(51)  // the data chunk now claims more bytes than the file has, and ends mid-sample
        let result = try WAVAudio.canonicalPCM16(file)
        XCTAssertEqual(result.data.count, 44 + 48)
    }

    func testRejectsFormatsTheEndpointRefuses() {
        XCTAssertThrowsError(try WAVAudio.canonicalPCM16(wav(channels: 2, pcm: Data(count: 8)))) {
            XCTAssertEqual($0 as? WAVAudioError, .unsupportedFormat("2 channels"))
        }
        XCTAssertThrowsError(try WAVAudio.canonicalPCM16(wav(sampleRate: 44_100, pcm: Data(count: 8)))) {
            XCTAssertEqual($0 as? WAVAudioError, .unsupportedFormat("44100 Hz"))
        }
        XCTAssertThrowsError(try WAVAudio.canonicalPCM16(wav(bits: 32, pcm: Data(count: 8)))) {
            XCTAssertEqual($0 as? WAVAudioError, .unsupportedFormat("32-bit"))
        }
        XCTAssertThrowsError(try WAVAudio.canonicalPCM16(wav(formatTag: 3, pcm: Data(count: 8)))) {
            XCTAssertEqual($0 as? WAVAudioError, .unsupportedFormat("format tag 3"))
        }
    }

    func testRejectsNonWAVAndMissingChunks() {
        XCTAssertThrowsError(try WAVAudio.canonicalPCM16(Data("not audio".utf8))) {
            XCTAssertEqual($0 as? WAVAudioError, .notRIFFWave)
        }
        var noData = Data("RIFF\u{4}\u{0}\u{0}\u{0}WAVE".utf8)
        XCTAssertThrowsError(try WAVAudio.canonicalPCM16(noData)) {
            XCTAssertEqual($0 as? WAVAudioError, .missingChunk("fmt "))
        }
        noData = wav(pcm: Data(count: 4))
        noData.removeLast(12)  // drop the whole data chunk
        XCTAssertThrowsError(try WAVAudio.canonicalPCM16(noData)) {
            XCTAssertEqual($0 as? WAVAudioError, .missingChunk("data"))
        }
    }
}
