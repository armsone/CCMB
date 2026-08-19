import Foundation

/// A metadata value a diagnostic record is allowed to carry. Restricting the
/// type (rather than accepting `Any`) is what keeps arbitrary error text,
/// account payloads, or other free-form strings from ever reaching the log
/// through a careless call site.
enum DiagnosticValue: Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    fileprivate var jsonValue: Any {
        switch self {
        case .string(let value): return DiagnosticLog.sanitizeValue(value)
        case .int(let value): return value
        case .double(let value): return value
        case .bool(let value): return value
        }
    }
}

/// One decoded line of the diagnostic log, used by callers that read the log
/// back (report generation, tests) rather than write to it.
struct DiagnosticRecord: Equatable {
    let timestamp: String
    let sessionID: String
    let event: String
    let metadata: [String: String]
}

/// Persistent, privacy-constrained, size-bounded rolling log for diagnosing
/// refresh problems after a restart.
///
/// Deliberately narrow: callers may only attach `DiagnosticValue` metadata
/// (never raw strings from network responses, tokens, or account data), keys
/// and string values are sanitized/truncated before being written, and the
/// on-disk footprint is capped at the current file plus one rotated file.
/// All file I/O happens on a dedicated background queue so logging can never
/// block a refresh, process, or UI queue, and every failure is swallowed —
/// a broken log must never break the app it is trying to diagnose.
final class DiagnosticLog: @unchecked Sendable {
    struct Limits {
        /// Size of the active log file before it is rotated. The on-disk
        /// footprint is bounded by roughly `maxFileBytes * 2` (current file +
        /// one rotated file).
        let maxFileBytes: Int
        /// Number of trailing metadata keys kept per record; extra keys are
        /// dropped rather than silently growing a record without bound.
        let maxMetadataKeys: Int

        static let `default` = Limits(maxFileBytes: 512 * 1_024, maxMetadataKeys: 8)
    }

    static let shared = DiagnosticLog()

    static let defaultDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library")
        .appendingPathComponent("Application Support")
        .appendingPathComponent("CCMB")
        .appendingPathComponent("diagnostics")

    let directoryURL: URL
    let fileURL: URL
    let rotatedFileURL: URL
    let sessionID: String

    private let limits: Limits
    private let clock: () -> Date
    private let queue = DispatchQueue(label: "com.codex.creditmenubar.diagnosticlog", qos: .utility)
    private let fileManager = FileManager.default

    /// Keys that must never be logged even if a call site passes one by
    /// mistake. Defense in depth on top of only ever passing controlled
    /// metadata at call sites.
    private static let blockedKeySubstrings = [
        "token", "auth", "password", "secret", "credential",
        "email", "apikey", "api_key", "organization"
    ]

    init(
        directoryURL: URL = DiagnosticLog.defaultDirectoryURL,
        limits: Limits = .default,
        sessionID: String = UUID().uuidString,
        clock: @escaping () -> Date = Date.init
    ) {
        self.directoryURL = directoryURL
        self.fileURL = directoryURL.appendingPathComponent("diagnostic.log")
        self.rotatedFileURL = directoryURL.appendingPathComponent("diagnostic.log.1")
        self.limits = limits
        self.sessionID = sessionID
        self.clock = clock
    }

    /// Appends one event. Returns immediately; the write happens
    /// asynchronously on `queue` and never throws or blocks the caller.
    func log(_ event: String, _ metadata: [String: DiagnosticValue] = [:]) {
        let date = clock()
        let sanitizedEvent = Self.sanitizeValue(event, maxLength: 64)
        let sanitizedMetadata = sanitizedMetadataDictionary(metadata)
        queue.async { [self] in
            let timestamp = Self.iso8601Formatter.string(from: date)
            append(timestamp: timestamp, event: sanitizedEvent, metadata: sanitizedMetadata)
        }
    }

    /// Waits until events already submitted to the logger are on disk. This
    /// is intentionally reserved for process termination, where an
    /// asynchronous final write would otherwise be lost as the app exits.
    func flush() {
        queue.sync {}
    }

    /// Reads the current file plus rotated file (oldest first) and returns
    /// the most recent `limit` decoded records. Runs synchronously on the
    /// logger's own background queue and blocks the caller's thread only
    /// while doing bounded, local disk reads (well under the size cap), so
    /// callers on the main thread should still dispatch this off the main
    /// queue for a snappy menu action.
    func recentRecords(limit: Int = 200) -> [DiagnosticRecord] {
        queue.sync {
            var records: [DiagnosticRecord] = []
            for url in [rotatedFileURL, fileURL] {
                records.append(contentsOf: Self.readRecords(at: url))
            }
            guard records.count > limit else { return records }
            return Array(records.suffix(limit))
        }
    }

    /// A concise, clipboard-ready report: app version plus the most recent
    /// bounded set of events. Contains no sensitive fields because every
    /// record it draws from was already sanitized when written.
    func report(appVersion: String, maxEvents: Int = 100) -> String {
        let records = recentRecords(limit: maxEvents)
        var lines = [
            "CCMB diagnostic report",
            "appVersion: \(appVersion)",
            "session: \(sessionID)",
            "events: \(records.count)"
        ]
        for record in records {
            var line = "\(record.timestamp) [\(record.sessionID)] \(record.event)"
            if !record.metadata.isEmpty {
                let metaText = record.metadata
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }
                    .joined(separator: " ")
                line += " \(metaText)"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Writing

    private func append(timestamp: String, event: String, metadata: [String: String]) {
        do {
            try ensureDirectory()
        } catch {
            return
        }

        var record: [String: Any] = [
            "ts": timestamp,
            "session": sessionID,
            "event": event
        ]
        if !metadata.isEmpty {
            record["meta"] = metadata
        }

        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        let line = data + Data([0x0A])

        // A single record larger than the configured file cap cannot be
        // retained without violating the rolling-log size guarantee.
        guard line.count <= limits.maxFileBytes else { return }

        let existingSize = (try? fileManager.attributesOfItem(atPath: fileURL.path))?[.size] as? Int
        if let existingSize, existingSize + line.count > limits.maxFileBytes {
            rotate()
        }

        appendLine(line, to: fileURL)
    }

    private func ensureDirectory() throws {
        if !fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
    }

    private func rotate() {
        try? fileManager.removeItem(at: rotatedFileURL)
        try? fileManager.moveItem(at: fileURL, to: rotatedFileURL)
    }

    /// Uses the pre-macOS-10.15.4 `FileHandle` API (non-throwing
    /// `write(_:)`/`seekToEndOfFile()`) since this package's deployment
    /// target predates the throwing `write(contentsOf:)` variant used
    /// elsewhere behind an availability check.
    private func appendLine(_ line: Data, to url: URL) {
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = FileHandle(forWritingAtPath: url.path) else { return }
        handle.seekToEndOfFile()
        handle.write(line)
        handle.closeFile()
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: - Reading

    private static func readRecords(at url: URL) -> [DiagnosticRecord] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
        return data
            .split(separator: 0x0A)
            .compactMap { lineData -> DiagnosticRecord? in
                guard let object = try? JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any],
                      let timestamp = object["ts"] as? String,
                      let sessionID = object["session"] as? String,
                      let event = object["event"] as? String
                else { return nil }
                let metadata = (object["meta"] as? [String: Any])?.compactMapValues { value -> String? in
                    switch value {
                    case let string as String: return string
                    case let number as NSNumber: return number.stringValue
                    default: return nil
                    }
                } ?? [:]
                return DiagnosticRecord(timestamp: timestamp, sessionID: sessionID, event: event, metadata: metadata)
            }
    }

    // MARK: - Sanitization

    private func sanitizedMetadataDictionary(_ metadata: [String: DiagnosticValue]) -> [String: String] {
        var sanitized: [String: String] = [:]
        for (key, value) in metadata.sorted(by: { $0.key < $1.key }) {
            let cleanKey = Self.sanitizeValue(key, maxLength: 32)
            guard !cleanKey.isEmpty, !Self.isBlockedKey(cleanKey) else { continue }
            sanitized[cleanKey] = String(describing: value.jsonValue)
            if sanitized.count == limits.maxMetadataKeys { break }
        }
        return sanitized
    }

    private static func isBlockedKey(_ key: String) -> Bool {
        let lowered = key.lowercased()
        return blockedKeySubstrings.contains { lowered.contains($0) }
    }

    /// Strips control characters/newlines and truncates to a small bound.
    /// Applied to every event name, metadata key, and string metadata value
    /// so a call site can never smuggle multi-line or oversized text into
    /// the log.
    fileprivate static func sanitizeValue(_ value: String, maxLength: Int = 200) -> String {
        let collapsed = String(value.unicodeScalars.map { scalar -> Character in
            CharacterSet.controlCharacters.contains(scalar) ? " " : Character(scalar)
        })
        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxLength else { return trimmed }
        let truncated = trimmed.prefix(maxLength)
        return "\(truncated)…"
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
