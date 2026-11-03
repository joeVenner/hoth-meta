#if DEBUG
import HoTHCore
import XCTest
@testable import HoTH

/// DEBUG tool-call log: the one-line format the film's S12 inset quotes, and the JSON-lines append.
/// Temp files only; the capture-mode gate keeps unit-test runs from writing anything else.
final class CaptureLogTests: XCTestCase {
    private func line(_ name: String, _ arguments: String, _ output: String) -> String {
        let call = FunctionCall(callID: "c1", name: name, arguments: arguments)
        return ToolCallLogLine.format(name: name, arguments: call.argumentsObject, output: output)
    }

    func testNearbyReportsLine() {
        XCTAssertEqual(line("find_nearby_reports", #"{"radius_m":150}"#, #"{"radius_m":150,"reports":[]}"#),
                       "find_nearby_reports radius_m=150 -> 0 results")
        XCTAssertEqual(line("find_nearby_reports", #"{"radius_m":150}"#,
                            #"{"radius_m":150,"reports":[{"id":"x"}]}"#),
                       "find_nearby_reports radius_m=150 -> 1 result")
    }

    func testNearbyReportsLineShowsTheClampedRadius() {
        XCTAssertEqual(line("find_nearby_reports", #"{"radius_m":5000}"#, #"{"radius_m":500,"reports":[{},{}]}"#),
                       "find_nearby_reports radius_m=5000 -> 2 results within 500 m")
        XCTAssertEqual(line("find_nearby_reports", "{}", #"{"radius_m":100,"reports":[]}"#),
                       "find_nearby_reports -> 0 results within 100 m")
    }

    func testSegmentAndPlaceLines() {
        XCTAssertEqual(line("segment_hazard", #"{"concept":"broken seat"}"#, #"{"boxes":[{},{}],"concept":"broken seat","count":2}"#),
                       #"segment_hazard concept="broken seat" -> 2 boxes"#)
        XCTAssertEqual(line("get_place_context", "{}",
                            #"{"child_use_equipment":true,"lookup_radius_m":100,"nearby_place":"none_found","scene_type":"playground"}"#),
                       "get_place_context -> nearby_place=none_found scene_type=playground child_use_equipment=true")
    }

    func testErrorsAndUnparsedOutput() {
        XCTAssertEqual(line("segment_hazard", #"{"concept":"x"}"#, #"{"error":"segmentation failed or timed out"}"#),
                       "segment_hazard concept=x -> error: segmentation failed or timed out")
        XCTAssertEqual(line("find_nearby_reports", "not json", "oops"), "find_nearby_reports -> unparsed output")
    }

    func testModelWrittenValuesStayOnOneBoundedLine() {
        let long = String(repeating: "a", count: 80)
        let result = line("segment_hazard", #"{"concept":"two\nlines \#(long)"}"#, #"{"count":0}"#)
        XCTAssertFalse(result.contains("\n"))
        XCTAssertTrue(result.hasPrefix(#"segment_hazard concept="two lines aaaa"#))
        XCTAssertTrue(result.contains("…\" -> 0 boxes"))
        XCTAssertEqual(ToolCallLogLine.describe(.number(1.5)), "1.5")
        XCTAssertEqual(ToolCallLogLine.describe(.string("")), "\"\"")
    }

    func testQuotesAndBackslashesInValuesAreEscaped() {
        XCTAssertEqual(ToolCallLogLine.describe(.string(#"a"b"#)), #""a\"b""#)
        XCTAssertEqual(ToolCallLogLine.describe(.string(#"a\b"#)), #""a\\b""#)
        XCTAssertEqual(ToolCallLogLine.describe(.string("plain")), "plain")
    }

    func testAppendRefusesASymlinkedLogFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureLogTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.txt")
        let link = directory.appendingPathComponent(CaptureLog.fileName)

        // Dangling link: must not create the target through it.
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try CaptureLog.append(record: ["event": .string("x")], to: link))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))

        // Link to an existing file: must not append to it.
        try Data("keep".utf8).write(to: target)
        XCTAssertThrowsError(try CaptureLog.append(record: ["event": .string("x")], to: link))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep")
    }

    func testAppendWritesSortedJSONLines() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureLogTests-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        try CaptureLog.append(record: ["line": .string("a -> b"), "event": .string("tool_call")], to: file)
        try CaptureLog.append(record: ["event": .string("capture_launch")], to: file)

        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines, [#"{"event":"tool_call","line":"a -> b"}"#, #"{"event":"capture_launch"}"#])
    }

    func testLogDirectoryMustBeAnAbsoluteExistingDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureLogTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertEqual(CaptureLog.validatedDirectory(directory.path)?.path, directory.resolvingSymlinksInPath().path)
        XCTAssertNil(CaptureLog.validatedDirectory("relative/logs"))
        XCTAssertNil(CaptureLog.validatedDirectory(directory.appendingPathComponent("missing").path))
        let file = directory.appendingPathComponent("file.txt")
        try Data().write(to: file)
        XCTAssertNil(CaptureLog.validatedDirectory(file.path))
    }
}
#endif
