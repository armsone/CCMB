import XCTest
@testable import CodexCreditMenuBar

final class DiagnosticLogTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CCMBDiagnosticLogTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    private func makeLog(
        limits: DiagnosticLog.Limits = .default,
        sessionID: String = "test-session",
        now: @escaping () -> Date = Date.init
    ) -> DiagnosticLog {
        DiagnosticLog(directoryURL: tempDirectory, limits: limits, sessionID: sessionID, clock: now)
    }

    /// Writes are dispatched to a private background queue, so tests drain
    /// it with a synchronous no-op round trip on the same serial queue that
    /// `log(_:_:)` and `recentRecords` both use, rather than sleeping.
    private func drain(_ log: DiagnosticLog) {
        _ = log.recentRecords(limit: 0)
    }

    func testDirectoryAndFilePermissionsAreLockedDown() throws {
        let log = makeLog()
        log.log("app_launch")
        drain(log)

        let attributes = try FileManager.default.attributesOfItem(atPath: tempDirectory.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)

        let fileAttributes = try FileManager.default.attributesOfItem(atPath: log.fileURL.path)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testExistingDirectoryPermissionsAreRepaired() throws {
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempDirectory.path)

        let log = makeLog()
        log.log("app_launch")
        log.flush()

        let attributes = try FileManager.default.attributesOfItem(atPath: tempDirectory.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testFlushPersistsQueuedTerminalEvent() {
        let log = makeLog()
        log.log("app_terminate")
        log.flush()

        XCTAssertEqual(log.recentRecords().last?.event, "app_terminate")
    }

    func testRecordsAreStructuredJSONLines() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let log = makeLog(sessionID: "session-abc", now: { now })
        log.log("codex_refresh_complete", ["elapsedSeconds": .double(1.5)])
        drain(log)

        let records = log.recentRecords()
        XCTAssertEqual(records.count, 1)
        let record = records[0]
        XCTAssertEqual(record.event, "codex_refresh_complete")
        XCTAssertEqual(record.sessionID, "session-abc")
        XCTAssertEqual(record.metadata["elapsedSeconds"], "1.5")
        XCTAssertTrue(record.timestamp.contains("2023") || !record.timestamp.isEmpty)
    }

    func testRotationKeepsCurrentPlusOneFileWithinBound() {
        let smallLimits = DiagnosticLog.Limits(maxFileBytes: 2_000, maxMetadataKeys: 8)
        let log = makeLog(limits: smallLimits)

        for index in 0..<500 {
            log.log("auto_refresh_timer_fire", ["index": .int(index)])
        }
        drain(log)

        XCTAssertTrue(FileManager.default.fileExists(atPath: log.fileURL.path))

        let currentSize = (try? FileManager.default.attributesOfItem(atPath: log.fileURL.path)[.size] as? Int) ?? nil
        XCTAssertNotNil(currentSize)
        XCTAssertLessThanOrEqual(currentSize ?? .max, smallLimits.maxFileBytes * 2)

        if FileManager.default.fileExists(atPath: log.rotatedFileURL.path) {
            let rotatedSize = (try? FileManager.default.attributesOfItem(atPath: log.rotatedFileURL.path)[.size] as? Int) ?? nil
            XCTAssertLessThanOrEqual(rotatedSize ?? .max, smallLimits.maxFileBytes * 2)
        }

        // Total on-disk footprint stays within the documented bound of
        // roughly `maxFileBytes * 2` regardless of how many events were
        // logged.
        let totalSize = (currentSize ?? 0)
            + ((try? FileManager.default.attributesOfItem(atPath: log.rotatedFileURL.path)[.size] as? Int) ?? nil ?? 0)
        XCTAssertLessThanOrEqual(totalSize, smallLimits.maxFileBytes * 2)
    }

    func testOversizedSingleRecordIsDroppedToPreserveSizeCap() {
        let limits = DiagnosticLog.Limits(maxFileBytes: 32, maxMetadataKeys: 8)
        let log = makeLog(limits: limits)
        log.log("event_that_cannot_fit")
        drain(log)

        let currentSize = ((try? FileManager.default.attributesOfItem(atPath: log.fileURL.path)[.size]) as? NSNumber)?.intValue ?? 0
        let rotatedSize = ((try? FileManager.default.attributesOfItem(atPath: log.rotatedFileURL.path)[.size]) as? NSNumber)?.intValue ?? 0
        XCTAssertLessThanOrEqual(currentSize + rotatedSize, limits.maxFileBytes * 2)
    }

    func testRecentRecordsIsBoundedAcrossRotatedAndCurrentFiles() {
        let smallLimits = DiagnosticLog.Limits(maxFileBytes: 1_500, maxMetadataKeys: 8)
        let log = makeLog(limits: smallLimits)

        for index in 0..<200 {
            log.log("manual_refresh", ["index": .int(index)])
        }
        drain(log)

        let records = log.recentRecords(limit: 20)
        XCTAssertLessThanOrEqual(records.count, 20)
        // The most recent record must be the last one written.
        XCTAssertEqual(records.last?.metadata["index"], "199")
    }

    func testMetadataValuesAreTruncatedAndControlCharactersStripped() {
        let log = makeLog()
        let longValue = String(repeating: "a", count: 500)
        log.log("event_with_long_value\nsecond line", ["note": .string("line1\nline2\ttab" + longValue)])
        drain(log)

        let record = log.recentRecords().first
        XCTAssertNotNil(record)
        XCTAssertFalse(record!.event.contains("\n"))
        let note = record!.metadata["note"] ?? ""
        XCTAssertFalse(note.contains("\n"))
        XCTAssertLessThanOrEqual(note.count, 201)
    }

    func testBlockedMetadataKeysAreDropped() {
        let log = makeLog()
        log.log("app_launch", [
            "authToken": .string("should-never-be-written"),
            "email": .string("user@example.com"),
            "organizationName": .string("Acme"),
            "elapsedSeconds": .double(2)
        ])
        drain(log)

        let record = log.recentRecords().first
        XCTAssertNotNil(record)
        XCTAssertNil(record?.metadata["authToken"])
        XCTAssertNil(record?.metadata["email"])
        XCTAssertNil(record?.metadata["organizationName"])
        XCTAssertEqual(record?.metadata["elapsedSeconds"], "2.0")
    }

    func testMetadataKeyCountIsBounded() {
        let limits = DiagnosticLog.Limits(maxFileBytes: 512 * 1_024, maxMetadataKeys: 3)
        let log = makeLog(limits: limits)
        var metadata: [String: DiagnosticValue] = [:]
        for index in 0..<10 {
            metadata["key\(index)"] = .int(index)
        }
        log.log("event", metadata)
        drain(log)

        let record = log.recentRecords().first
        XCTAssertEqual(record?.metadata.count, 3)
    }

    func testReportIncludesAppVersionAndRecentEventsWithoutSensitiveData() {
        let log = makeLog()
        log.log("app_launch", ["version": .string("1.2.3")])
        log.log("shared_payload_published", ["origin": .string("codex-fetch"), "codexFetchedAgeSeconds": .int(4)])
        drain(log)

        let report = log.report(appVersion: "1.2.3", maxEvents: 10)
        XCTAssertTrue(report.contains("appVersion: 1.2.3"))
        XCTAssertTrue(report.contains("shared_payload_published"))
        XCTAssertFalse(report.lowercased().contains("token"))
    }

    func testLoggingNeverThrowsWhenDirectoryIsUnwritable() {
        // A file in place of the log directory makes directory creation
        // fail; `log` must swallow the failure instead of crashing.
        let parent = tempDirectory.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: tempDirectory.path, contents: Data())

        let log = makeLog()
        log.log("app_launch")
        drain(log)

        XCTAssertTrue(log.recentRecords().isEmpty)
    }
}
