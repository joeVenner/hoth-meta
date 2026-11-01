import Foundation
import HoTHCore
import OSLog

#if DEBUG
/// DEBUG-only one-line summaries of intake-agent tool calls, e.g.
/// `find_nearby_reports radius_m=150 -> 0 results`. Pure, so the format is unit-tested.
enum ToolCallLogLine {
    static let maxValueLength = 40

    /// - Parameters:
    ///   - name: the tool the model called.
    ///   - arguments: the model's arguments (nil when they were not a JSON object).
    ///   - output: the JSON string the tool returned to the model.
    static func format(name: String, arguments: [String: JSONValue]?, output: String) -> String {
        let argumentText = (arguments ?? [:]).keys.sorted()
            .map { key in "\(key)=\(describe(arguments?[key] ?? .null))" }
            .joined(separator: " ")
        let call = argumentText.isEmpty ? name : "\(name) \(argumentText)"
        return "\(call) -> \(result(name: name, arguments: arguments, output: output))"
    }

    private static func result(name: String, arguments: [String: JSONValue]?, output: String) -> String {
        guard case .object(let object)? = try? JSONDecoder().decode(JSONValue.self, from: Data(output.utf8)) else {
            return "unparsed output"
        }
        if let message = object["error"]?.stringValue { return "error: \(sanitized(message))" }
        switch name {
        case "find_nearby_reports":
            let count: Int
            if case .array(let reports)? = object["reports"] { count = reports.count } else { count = 0 }
            var text = count == 1 ? "1 result" : "\(count) results"
            // The toolbox clamps the radius; say so when the model asked for something else.
            if case .number(let used)? = object["radius_m"], arguments?["radius_m"] != .number(used) {
                text += " within \(Int(used)) m"
            }
            return text
        case "segment_hazard":
            if case .number(let count)? = object["count"] {
                return Int(count) == 1 ? "1 box" : "\(Int(count)) boxes"
            }
            return "ok"
        case "get_place_context":
            return ["nearby_place", "scene_type", "child_use_equipment"]
                .compactMap { key in object[key].map { "\(key)=\(describe($0))" } }
                .joined(separator: " ")
        default:
            return "ok"
        }
    }

    /// Model-written values are untrusted: one line, bounded length.
    static func describe(_ value: JSONValue) -> String {
        switch value {
        case .string(let text):
            let clean = sanitized(text)
            return clean.isEmpty || clean.contains(" ") || clean.contains("=") ? "\"\(clean)\"" : clean
        case .number(let number):
            if number.isFinite, number == number.rounded(), abs(number) < 1e15 { return String(Int(number)) }
            return String(number)
        case .bool(let flag):
            return flag ? "true" : "false"
        case .null:
            return "null"
        case .array, .object:
            let data = (try? JSONEncoder().encode(value)) ?? Data()
            return sanitized(String(decoding: data, as: UTF8.self))
        }
    }

    private static func sanitized(_ text: String) -> String {
        let oneLine = text.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard oneLine.count > maxValueLength else { return oneLine }
        return String(oneLine.prefix(maxValueLength)) + "…"
    }
}

/// DEBUG-only capture log: every record goes to `os.Logger`; in capture mode (`HOTH_DEMO_CAPTURE=1`)
/// it is also appended as one JSON line to `<HOTH_CAPTURE_LOG_DIR>/hoth_app_log.jsonl` (else
/// `<Documents>/capture/`), which the capture UI test collects for the film's "real app log" inset.
/// Never throws: a log that cannot be written must not change what the app does.
enum CaptureLog {
    static let fileName = "hoth_app_log.jsonl"
    private static let logger = Logger(subsystem: "io.fomy.hoth", category: "CaptureLog")

    // MARK: Events

    /// One intake-agent tool call and its result.
    static func recordToolCall(_ call: FunctionCall, output: String, durationMs: Int) {
        let line = ToolCallLogLine.format(name: call.name, arguments: call.argumentsObject, output: output)
        logger.debug("tool \(line, privacy: .public) (\(durationMs, privacy: .public) ms)")
        let outputValue = (try? JSONDecoder().decode(JSONValue.self, from: Data(output.utf8))) ?? .string(output)
        append(event: "tool_call", fields: [
            "tool": .string(call.name),
            "arguments": call.argumentsObject.map(JSONValue.object) ?? .string(call.arguments),
            "output": outputValue,
            "duration_ms": .number(Double(durationMs)),
            "line": .string(line),
        ])
    }

    /// The app started in capture mode; proves the host log directory (and the WAV playlist, if named)
    /// are reachable from the simulator without making any Meta call.
    static func recordLaunch(environment: [String: String] = ProcessInfo.processInfo.environment) {
        var fields: [String: JSONValue] = [:]
        if let path = FileVoiceRecorder.playlistDirectory(environment: environment) {
            switch FileVoicePlaylist.load(directory: path) {
            case .success(let clips):
                fields["ptt_clips"] = .array(clips.map { .string($0.url.lastPathComponent) })
            case .failure(let error):
                fields["ptt_error"] = .string(error.description)
            }
        }
        append(event: "capture_launch", fields: fields, environment: environment)
    }

    // MARK: Writing

    private static func append(event: String, fields: [String: JSONValue],
                               environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard DemoCapture.isEnabled(environment: environment) else { return }
        guard let directory = directory(environment: environment) else {
            logger.error("Capture log directory unavailable; \(event, privacy: .public) not written")
            return
        }
        var record = fields
        record["event"] = .string(event)
        record["t"] = .number(Date().timeIntervalSince1970)
        if let scene = environment[DemoCapture.EnvironmentKey.scene], !scene.isEmpty {
            record["scene"] = .string(scene)
        }
        do {
            try append(record: record, to: directory.appendingPathComponent(fileName))
        } catch {
            logger.error("Capture log write failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Appends `record` as one sorted-key JSON line, creating the file when needed.
    static func append(record: [String: JSONValue], to file: URL, fileManager: FileManager = .default) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(JSONValue.object(record))
        data.append(0x0A)
        if !fileManager.fileExists(atPath: file.path) {
            guard fileManager.createFile(atPath: file.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    /// `HOTH_CAPTURE_LOG_DIR` when it is an absolute path to an existing directory (symlinks in the
    /// path resolved), else `<Documents>/capture` (created), else nil.
    static func directory(environment: [String: String], fileManager: FileManager = .default) -> URL? {
        if let path = environment[DemoCapture.EnvironmentKey.logDirectory], !path.isEmpty {
            if let url = validatedDirectory(path, fileManager: fileManager) { return url }
            logger.error("HOTH_CAPTURE_LOG_DIR is not an absolute existing directory; using Documents/capture")
        }
        guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let fallback = documents.appendingPathComponent("capture", isDirectory: true)
        do {
            try fileManager.createDirectory(at: fallback, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return fallback
    }

    static func validatedDirectory(_ path: String, fileManager: FileManager = .default) -> URL? {
        guard path.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return url
    }
}
#endif
