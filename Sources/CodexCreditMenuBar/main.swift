import AppKit
import Darwin
import Foundation
import Network
import Sparkle
import os.log

private let ccmbLog = OSLog(subsystem: "com.codex.creditmenubar", category: "CCMB")

private func writePrivateLog(_ message: String) {
    os_log("%{private}@", log: ccmbLog, type: .debug, message)
}

private enum SharedUsageStore {
    static let directoryURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library")
        .appendingPathComponent("Application Support")
        .appendingPathComponent("CCMB")
    static let snapshotURL = directoryURL.appendingPathComponent("usage-v1.json")
    static let helperURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex")
        .appendingPathComponent("bin")
        .appendingPathComponent("ccmb-usage")

    static func publish(
        _ snapshot: RateLimitSnapshot,
        claudeSnapshot: ClaudeUsageSnapshot?,
        claudeRetryAt: Date?,
        claudeFailureLabel: String?,
        geminiSnapshot: GeminiUsageSnapshot?,
        grokSnapshot: GrokUsageSnapshot?,
        refreshInterval: TimeInterval
    ) throws {
        let remainingPercent = snapshot.usedPercent.map(UsageCore.remainingPercent)
        let freshForSeconds = max(45, Int(refreshInterval) + 15)
        let sequence = Int64((snapshot.updatedAt.timeIntervalSince1970 * 1_000).rounded())

        var claudePayload = ClaudeUsageCore.sharedPayload(from: claudeSnapshot)
        let circuitOpen = claudeRetryAt.map { $0 > Date() } ?? false
        claudePayload["circuitState"] = circuitOpen ? "open" : "closed"
        claudePayload["nextEligibleAt"] = claudeRetryAt.map(iso8601Formatter.string(from:)) ?? NSNull()
        let staleReason: Any = circuitOpen ? "rate-limited" : (claudeFailureLabel as Any? ?? NSNull())
        claudePayload["staleReason"] = staleReason

        let payload: [String: Any] = [
            "schemaVersion": 1,
            "status": "ok",
            "source": "codex app-server",
            "method": "account/rateLimits/read",
            "weeklyRemainingPercent": remainingPercent ?? NSNull(),
            "sparkRemainingPercent": snapshot.sparkUsedPercent.map(UsageCore.remainingPercent) ?? NSNull(),
            "creditBalance": snapshot.creditBalance ?? NSNull(),
            "usedPercent": snapshot.usedPercent ?? NSNull(),
            "windowDurationMins": snapshot.windowDurationMinutes ?? NSNull(),
            "resetsAt": snapshot.resetsAt.map(iso8601Formatter.string(from:)) ?? NSNull(),
            "sparkResetsAt": snapshot.sparkResetsAt.map(iso8601Formatter.string(from:)) ?? NSNull(),
            "sparkUsedPercent": snapshot.sparkUsedPercent ?? NSNull(),
            "sparkWindowDurationMins": snapshot.sparkWindowDurationMinutes ?? NSNull(),
            "fetchedAt": iso8601Formatter.string(from: snapshot.updatedAt),
            "publishedAt": iso8601Formatter.string(from: Date()),
            "sequence": sequence,
            "refreshIntervalSeconds": Int(refreshInterval),
            "freshForSeconds": freshForSeconds,
            "ccmbProcessID": ProcessInfo.processInfo.processIdentifier,
            "ccmbBundleIdentifier": Bundle.main.bundleIdentifier ?? "",
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
            "claude": claudePayload,
            "codex": UsageCore.codexPayload(from: snapshot, freshForSeconds: freshForSeconds),
            "gemini": GeminiUsageCore.sharedPayload(from: geminiSnapshot),
            "grok": GrokUsageCore.sharedPayload(from: grokSnapshot)
        ]

        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)

        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: snapshotURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshotURL.path)
    }

    static func installHelper() throws {
        guard let executableURL = Bundle.main.executableURL else {
            throw CocoaError(.fileNoSuchFile)
        }

        let helperDirectory = helperURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: helperDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if FileManager.default.fileExists(atPath: helperURL.path) {
            let existingContents = try String(contentsOf: helperURL, encoding: .utf8)
            guard UsageCore.canReplaceUsageHelper(existingContents: existingContents) else {
                throw CocoaError(.fileWriteFileExists)
            }
        }
        let escapedExecutablePath = executableURL.path.replacingOccurrences(of: "'", with: "'\\''")
        let script = """
        #!/bin/sh
        \(UsageCore.usageHelperMarker)1
        exec '\(escapedExecutablePath)' --ccmb-usage "$@"
        """ + "\n"
        guard let data = script.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        try data.write(to: helperURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL.path)
    }

    static func readPayload() throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: snapshotURL.path) else { return nil }
        let data = try Data(contentsOf: snapshotURL)
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              payload["schemaVersion"] as? Int == 1 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return payload
    }

    static func readClaudeSnapshot() -> ClaudeUsageSnapshot? {
        guard let payload = try? readPayload(),
              let claude = payload["claude"] as? [String: Any]
        else { return nil }
        return ClaudeUsageCore.snapshot(fromSharedPayload: claude)
    }

    static func readGeminiSnapshot() -> GeminiUsageSnapshot? {
        guard let payload = try? readPayload(),
              let gemini = payload["gemini"] as? [String: Any]
        else { return nil }
        return GeminiUsageCore.snapshot(fromSharedPayload: gemini)
    }

    static func readGrokSnapshot() -> GrokUsageSnapshot? {
        guard let payload = try? readPayload(),
              let grok = payload["grok"] as? [String: Any]
        else { return nil }
        return GrokUsageCore.snapshot(fromSharedPayload: grok)
    }

    private static var iso8601Formatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}

private enum UsageCommand {
    static func runIfRequested() -> Bool {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.contains("--ccmb-usage") else { return false }

        do {
            var cacheIsCorrupt = false
            let cached: [String: Any]?
            do {
                cached = try SharedUsageStore.readPayload().map(decorateCache)
            } catch {
                // A present-but-corrupt or unsupported-schema cache must not block
                // the direct live query below; only --cache-only treats this as fatal.
                cacheIsCorrupt = true
                cached = nil
            }

            if arguments.contains("--verify-live") {
                let direct = try readDirect()
                var output = direct
                output["verification"] = verification(cached: cached, direct: direct)
                printJSON(output)
            } else if arguments.contains("--cache-only") {
                guard let cached else {
                    throw UsageCommandError.message(
                        UsageCore.cacheOnlyFailureMessage(cacheIsCorrupt: cacheIsCorrupt, path: SharedUsageStore.snapshotURL.path)
                    )
                }
                printJSON(cached)
            } else if let cached, cached["fresh"] as? Bool == true {
                printJSON(cached)
            } else {
                var direct = try readDirect()
                direct["cacheFallbackReason"] = UsageCore.cacheFallbackReason(cacheExists: cached != nil, cacheIsCorrupt: cacheIsCorrupt)
                direct["claude"] = cached?["claude"]
                    ?? ClaudeUsageCore.sharedPayload(from: ClaudeUsageStore.read())
                // No passive local cache exists for Gemini the way
                // `claude-statusline.sh` provides one for Claude, so a stale
                // CCMB cache is the only source here; absent that, Gemini is
                // simply reported unavailable rather than blocking this
                // command on a live `agy` launch.
                direct["gemini"] = cached?["gemini"] ?? GeminiUsageCore.sharedPayload(from: nil)
                // No passive local cache exists for Grok either — the local
                // `auth.json` carries no usage numbers of its own — so a
                // stale CCMB cache is likewise the only source here.
                direct["grok"] = cached?["grok"] ?? GrokUsageCore.sharedPayload(from: nil)
                if let cached {
                    direct["ccmbCache"] = cached
                }
                printJSON(direct)
            }
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            Darwin.exit(EXIT_FAILURE)
        }

        return true
    }

    private static func decorateCache(_ payload: [String: Any]) -> [String: Any] {
        let storedClaude = payload["claude"] as? [String: Any]
            ?? ClaudeUsageCore.sharedPayload(from: ClaudeUsageStore.read())
        let freshForSeconds = payload["freshForSeconds"] as? Int ?? 45
        let storedCodex = payload["codex"] as? [String: Any]
            ?? UsageCore.codexPayload(from: nil, freshForSeconds: freshForSeconds)
        let storedGemini = payload["gemini"] as? [String: Any]
            ?? GeminiUsageCore.sharedPayload(from: nil)
        let storedGrok = payload["grok"] as? [String: Any]
            ?? GrokUsageCore.sharedPayload(from: nil)
        var output: [String: Any] = [
            "weeklyRemainingPercent": payload["weeklyRemainingPercent"] ?? NSNull(),
            "sparkRemainingPercent": payload["sparkRemainingPercent"] ?? NSNull(),
            "creditBalance": payload["creditBalance"] ?? NSNull(),
            "usedPercent": payload["usedPercent"] ?? NSNull(),
            "sparkUsedPercent": payload["sparkUsedPercent"] ?? NSNull(),
            "windowDurationMins": payload["windowDurationMins"] ?? NSNull(),
            "resetsAt": payload["resetsAt"] ?? NSNull(),
            "sparkResetsAt": payload["sparkResetsAt"] ?? NSNull(),
            "sparkWindowDurationMins": payload["sparkWindowDurationMins"] ?? NSNull(),
            "origin": "ccmb-cache",
            "fetchedAt": payload["fetchedAt"] ?? NSNull(),
            "claude": ClaudeUsageCore.refreshedSharedPayload(storedClaude),
            "codex": UsageCore.refreshedCodexPayload(storedCodex),
            "gemini": GeminiUsageCore.refreshedSharedPayload(storedGemini),
            "grok": GrokUsageCore.refreshedSharedPayload(storedGrok)
        ]

        let fetchedAt = (payload["fetchedAt"] as? String).flatMap(iso8601Formatter.date(from:))
        let ageSeconds = UsageCore.cacheAgeSeconds(fetchedAt: fetchedAt, now: Date())
        let ccmbRunning = processMatches(
            payload["ccmbProcessID"],
            bundleIdentifier: payload["ccmbBundleIdentifier"] as? String
        )
        let statusOK = payload["status"] as? String == "ok"
        output["ageSeconds"] = ageSeconds
        output["freshForSeconds"] = freshForSeconds
        output["fresh"] = UsageCore.cacheIsFresh(
            statusOK: statusOK,
            processMatches: ccmbRunning,
            ageSeconds: ageSeconds,
            freshForSeconds: freshForSeconds
        )
        output["evidence"] = [
            "status": payload["status"] ?? NSNull(),
            "source": payload["source"] ?? NSNull(),
            "method": payload["method"] ?? NSNull(),
            "sequence": payload["sequence"] ?? NSNull(),
            "publishedAt": payload["publishedAt"] ?? NSNull(),
            "ccmbRunning": ccmbRunning,
            "cachePath": SharedUsageStore.snapshotURL.path
        ]
        return output
    }

    private static func readDirect() throws -> [String: Any] {
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var capturedSnapshot: RateLimitSnapshot?
        var capturedError: String?
        let client = CodexAppServerClient(callbackQueue: nil)

        client.onRateLimitsUpdated = { snapshot in
            lock.lock()
            capturedSnapshot = snapshot
            lock.unlock()
            semaphore.signal()
        }
        client.onError = { message in
            lock.lock()
            capturedError = message
            lock.unlock()
            semaphore.signal()
        }
        client.start()
        let waitResult = semaphore.wait(timeout: .now() + 15)
        client.stop()

        guard waitResult == .success else {
            throw UsageCommandError.message("codex app-server가 15초 안에 응답하지 않았습니다.")
        }
        lock.lock()
        defer { lock.unlock() }
        if let capturedError {
            throw UsageCommandError.message(capturedError)
        }
        guard let snapshot = capturedSnapshot, let usedPercent = snapshot.usedPercent else {
            throw UsageCommandError.message("Codex 사용량 응답을 읽지 못했습니다.")
        }

        let fetchedAt = iso8601Formatter.string(from: snapshot.updatedAt)
        return [
            "weeklyRemainingPercent": min(max(100 - usedPercent, 0), 100),
            "sparkRemainingPercent": snapshot.sparkUsedPercent.map { min(max(100 - $0, 0), 100) } ?? NSNull(),
            "creditBalance": snapshot.creditBalance ?? NSNull(),
            "usedPercent": usedPercent,
            "sparkUsedPercent": snapshot.sparkUsedPercent ?? NSNull(),
            "windowDurationMins": snapshot.windowDurationMinutes ?? NSNull(),
            "sparkWindowDurationMins": snapshot.sparkWindowDurationMinutes ?? NSNull(),
            "resetsAt": snapshot.resetsAt.map(iso8601Formatter.string(from:)) ?? NSNull(),
            "sparkResetsAt": snapshot.sparkResetsAt.map(iso8601Formatter.string(from:)) ?? NSNull(),
            "origin": "direct-app-server",
            "fetchedAt": fetchedAt,
            "ageSeconds": 0,
            "freshForSeconds": 15,
            "fresh": true,
            "claude": ClaudeUsageCore.sharedPayload(from: ClaudeUsageStore.read()),
            "codex": UsageCore.codexPayload(from: snapshot, freshForSeconds: 15, now: snapshot.updatedAt),
            "gemini": GeminiUsageCore.sharedPayload(from: nil),
            "grok": GrokUsageCore.sharedPayload(from: nil),
            "evidence": [
                "status": "ok",
                "source": "codex app-server",
                "method": "account/rateLimits/read",
                "verifiedAt": fetchedAt
            ]
        ]
    }

    private static func verification(cached: [String: Any]?, direct: [String: Any]) -> [String: Any] {
        let weeklyMatches = numbersMatch(cached?["weeklyRemainingPercent"], direct["weeklyRemainingPercent"])
        let creditMatches = numbersMatch(cached?["creditBalance"], direct["creditBalance"])
        return [
            "mode": "independent-app-server-read",
            "matches": cached != nil && weeklyMatches && creditMatches,
            "weeklyRemainingMatches": cached != nil && weeklyMatches,
            "creditBalanceMatches": cached != nil && creditMatches,
            "ccmb": cached ?? NSNull()
        ]
    }

    private static func numbersMatch(_ left: Any?, _ right: Any?) -> Bool {
        if left is NSNull || right is NSNull {
            return left is NSNull && right is NSNull
        }
        guard let left = (left as? NSNumber)?.doubleValue,
              let right = (right as? NSNumber)?.doubleValue else { return false }
        return abs(left - right) <= 0.000001
    }

    private static func processMatches(_ value: Any?, bundleIdentifier: String?) -> Bool {
        guard let pid = (value as? NSNumber)?.int32Value, pid > 1 else { return false }
        guard Darwin.kill(pid, 0) == 0 || errno == EPERM else { return false }
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return true }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == bundleIdentifier
    }

    private static func printJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8) else { return }
        line.append("\n")
        FileHandle.standardOutput.write(Data(line.utf8))
    }

    private static var iso8601Formatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}

private enum UsageCommandError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): message
        }
    }
}

private final class CodexAppServerClient: @unchecked Sendable {
    private struct LaunchCommand {
        let executable: URL
        let arguments: [String]
        let selectedCodexURL: URL?
        let searchBinURLs: [URL]

        var description: String {
            ([executable.path] + arguments).joined(separator: " ")
        }
    }

    private let processQueue = DispatchQueue(label: "CodexCreditMenuBar.CodexAppServerClient")
    private let processQueueKey = DispatchSpecificKey<UInt8>()
    private let callbackQueue: DispatchQueue?
    private let diagnosticLog: DiagnosticLog?
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var nextID = 1
    private var isInitialized = false
    private var pending: [Int: (Result<Any, Error>) -> Void] = [:]
    private var accountID: String?
    private var accountPlanType: String?
    private var isRefreshing = false
    private var refreshStartedAt: Date?
    private var refreshGeneration = 0
    private var currentCommandDescription: String?
    private var processFailureReported = false

    var onRateLimitsUpdated: ((RateLimitSnapshot) -> Void)?
    var onError: ((String) -> Void)?
    var onRestartRequired: ((String) -> Void)?

    init(callbackQueue: DispatchQueue? = .main, diagnosticLog: DiagnosticLog? = nil) {
        self.callbackQueue = callbackQueue
        self.diagnosticLog = diagnosticLog
        processQueue.setSpecific(key: processQueueKey, value: 1)
    }

    func start() {
        processQueue.async {
            guard self.process?.isRunning != true else { return }
            self.launchProcess()
        }
    }

    func refreshRateLimits() {
        processQueue.async {
            guard self.process?.isRunning == true else {
                self.launchProcess()
                return
            }

            guard self.isInitialized else {
                self.log("refresh skipped: initialization in progress")
                self.diagnosticLog?.log("codex_refresh_skip_initializing")
                return
            }
            if self.isRefreshing {
                let elapsed = abs(self.refreshStartedAt?.timeIntervalSinceNow ?? 0)
                guard elapsed > 15 else {
                    self.log("refresh skipped: already in progress")
                    self.diagnosticLog?.log("codex_refresh_skip_in_progress", ["elapsedSeconds": .int(Int(elapsed))])
                    return
                }

                self.log("refresh stale after \(Int(elapsed))s; restarting app-server")
                self.diagnosticLog?.log("codex_refresh_stale_restart", ["elapsedSeconds": .int(Int(elapsed))])
                self.isRefreshing = false
                self.stopCurrentProcess()
                self.launchProcess()
                return
            }

            self.isRefreshing = true
            self.refreshStartedAt = Date()
            self.refreshGeneration += 1
            let generation = self.refreshGeneration
            self.log("refresh begin")
            self.diagnosticLog?.log("codex_refresh_begin", ["reason": .string("refresh")])
            self.scheduleRefreshWatchdog(generation: generation, reason: "refresh")
            self.readAccount {
                self.readRateLimits()
            }
        }
    }

    func recoverFromSleep() {
        processQueue.async {
            self.log("recover from sleep")
            self.isRefreshing = false
            self.refreshStartedAt = nil
            self.accountID = nil
            self.accountPlanType = nil
            self.isInitialized = false
            self.refreshGeneration += 1
            self.pending.removeAll()
            self.stopCurrentProcess()
            self.launchProcess()
        }
    }

    func setAutoRefreshInterval(_ interval: TimeInterval) {
        processQueue.async {
            self.log("auto refresh interval \(Int(interval))s")
        }
    }

    func stop() {
        performOnProcessQueueAndWait {
            self.refreshGeneration += 1
            self.stopCurrentProcess()
        }
    }

    private func launchProcess() {
        stopCurrentProcess()

        let command = findCodexLaunchCommand()
        let process = Process()
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.environment = Self.codexEnvironment(
            preferredBinURL: command.selectedCodexURL?.deletingLastPathComponent(),
            searchBinURLs: command.searchBinURLs
        )
        if let selectedCodexURL = command.selectedCodexURL {
            log("selected codex executable \(selectedCodexURL.path)")
        } else {
            log("codex executable not found; falling back to /usr/bin/env")
            log("searched codex paths \(command.searchBinURLs.map { $0.appendingPathComponent("codex").path }.joined(separator: ", "))")
        }
        log("launch \(command.description)")

        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error

        output.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.processQueue.async {
                guard let self, let process, self.process === process else { return }
                self.handleOutput(data)
            }
        }

        error.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.processQueue.async {
                guard let self, let process, self.process === process else { return }
                self.handleErrorOutput(data)
            }
        }

        process.terminationHandler = { [weak self] terminatedProcess in
            self?.processQueue.asyncAfter(deadline: .now() + .milliseconds(50)) {
                self?.handleUnexpectedTermination(terminatedProcess, command: command)
            }
        }

        self.process = process
        stdinPipe = input
        stdoutPipe = output
        stderrPipe = error
        currentCommandDescription = command.description
        processFailureReported = false

        do {
            try process.run()
            diagnosticLog?.log("appserver_launch")
            initialize()
        } catch {
            let message = "Codex app-server 시작 실패 (실행 \(command.description)): \(error.localizedDescription)"
            log("launch failed \(message)")
            diagnosticLog?.log("appserver_launch_failed")
            process.terminationHandler = nil
            self.process = nil
            currentCommandDescription = nil
            processFailureReported = true
            cleanupCurrentPipes()
            emitError(message)
        }
    }

    private func stopCurrentProcess() {
        guard let currentProcess = process else {
            cleanupCurrentPipes()
            pending.removeAll()
            isInitialized = false
            isRefreshing = false
            refreshStartedAt = nil
            currentCommandDescription = nil
            return
        }

        currentProcess.terminationHandler = nil
        stdinPipe?.fileHandleForWriting.ccmbClose()

        if currentProcess.isRunning {
            log("stopping app-server pid \(currentProcess.processIdentifier) with SIGTERM")
            currentProcess.terminate()

            if !waitForExit(currentProcess, timeout: 0.5) {
                let pid = currentProcess.processIdentifier
                log("app-server pid \(pid) ignored SIGTERM; sending SIGKILL")
                if Darwin.kill(pid, SIGKILL) != 0 {
                    let errorNumber = errno
                    log("SIGKILL failed for pid \(pid), errno \(errorNumber): \(String(cString: strerror(errorNumber)))")
                }
                currentProcess.waitUntilExit()
            }
        } else {
            currentProcess.waitUntilExit()
        }

        process = nil
        currentCommandDescription = nil
        cleanupCurrentPipes()
        pending.removeAll()
        isInitialized = false
        isRefreshing = false
        refreshStartedAt = nil
    }

    private func performOnProcessQueueAndWait(_ work: () -> Void) {
        if DispatchQueue.getSpecific(key: processQueueKey) == 1 {
            work()
        } else {
            processQueue.sync(execute: work)
        }
    }

    private func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(timeout * Double(NSEC_PER_SEC))
        while process.isRunning, DispatchTime.now().uptimeNanoseconds < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }

        guard !process.isRunning else { return false }
        process.waitUntilExit()
        return true
    }

    private func handleUnexpectedTermination(_ terminatedProcess: Process, command: LaunchCommand) {
        guard process === terminatedProcess else {
            log("ignore stale app-server termination")
            return
        }

        let status = terminatedProcess.terminationStatus
        let reason = Self.terminationReasonDescription(terminatedProcess.terminationReason)
        var message = "Codex app-server 예기치 않은 종료 (코드 \(status), 이유 \(reason), 실행 \(command.description))"
        let stderr = stderrSummary()
        if !stderr.isEmpty {
            message += ": \(stderr)"
        }
        log("app-server terminated status \(status) reason \(reason)")
        diagnosticLog?.log("appserver_terminate", ["status": .int(Int(status)), "reason": .string(reason)])

        let shouldReport = !processFailureReported
        processFailureReported = true
        process = nil
        currentCommandDescription = nil
        cleanupCurrentPipes()
        pending.removeAll()
        isInitialized = false
        isRefreshing = false
        refreshStartedAt = nil

        if shouldReport {
            emitError(message)
        } else {
            log("process failure already reported; suppress duplicate UI error")
        }
    }

    private func cleanupCurrentPipes() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil

        let handles = [
            stdinPipe?.fileHandleForReading,
            stdinPipe?.fileHandleForWriting,
            stdoutPipe?.fileHandleForReading,
            stdoutPipe?.fileHandleForWriting,
            stderrPipe?.fileHandleForReading,
            stderrPipe?.fileHandleForWriting
        ]
        for case let handle? in handles {
            handle.ccmbClose()
        }

        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        stdoutBuffer.removeAll()
        stderrBuffer.removeAll()
    }

    private func initialize() {
        let clientVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "development"
        sendRequest(
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "codex_credit_menubar",
                    "title": "CCMB",
                    "version": clientVersion
                ]
            ]
        ) { result in
            switch result {
            case .success:
                guard self.sendNotification(method: "initialized", params: [:]) else { return }
                self.isInitialized = true
                self.isRefreshing = true
                self.refreshStartedAt = Date()
                self.refreshGeneration += 1
                let generation = self.refreshGeneration
                self.log("initial refresh begin")
                self.diagnosticLog?.log("codex_refresh_begin", ["reason": .string("initial")])
                self.scheduleRefreshWatchdog(generation: generation, reason: "initial refresh")
                self.readAccount {
                    self.readRateLimits()
                }
            case .failure(let error):
                self.emitError(error.localizedDescription)
                self.stopCurrentProcess()
            }
        }
    }

    private func sendRequest(method: String, params: [String: Any], completion: @escaping (Result<Any, Error>) -> Void) {
        let id = nextID
        nextID += 1
        pending[id] = completion
        if case .failure(let error) = sendJSONObject(["method": method, "id": id, "params": params]) {
            pending.removeValue(forKey: id)
            let isTransportFailure = error.isTransportFailure
            if isTransportFailure {
                processFailureReported = true
            }
            completion(.failure(error))
            if isTransportFailure {
                stopCurrentProcess()
            }
        }
    }

    private func scheduleRefreshWatchdog(generation: Int, reason: String) {
        processQueue.asyncAfter(deadline: .now() + 20) {
            guard self.isRefreshing else { return }
            guard self.refreshGeneration == generation else { return }

            let elapsed = abs(self.refreshStartedAt?.timeIntervalSinceNow ?? 0)
            self.log("\(reason) timed out after \(Int(elapsed))s; restarting app")
            self.diagnosticLog?.log("codex_refresh_watchdog_timeout", ["reason": .string(reason), "elapsedSeconds": .int(Int(elapsed))])
            self.isRefreshing = false
            self.refreshStartedAt = nil
            self.refreshGeneration += 1
            self.stopCurrentProcess()

            self.deliverCallback {
                self.onRestartRequired?("정보 가져오기가 응답하지 않아 앱을 재시작합니다.")
            }
        }
    }

    private func readRateLimits() {
        log("read rate limits")
        let startedAt = refreshStartedAt
        sendRequest(method: "account/rateLimits/read", params: [:]) { result in
            defer {
                self.isRefreshing = false
                self.refreshStartedAt = nil
                self.log("refresh end")
            }

            switch result {
            case .success(let value):
                guard let object = value as? [String: Any] else {
                    let elapsed = abs(startedAt?.timeIntervalSinceNow ?? 0)
                    self.diagnosticLog?.log("codex_refresh_failed", [
                        "kind": .string("invalid-response"),
                        "elapsedSeconds": .double(elapsed)
                    ])
                    self.emitError("Codex 사용량 응답을 읽지 못했습니다.")
                    return
                }
                let elapsed = abs(startedAt?.timeIntervalSinceNow ?? 0)
                self.diagnosticLog?.log("codex_refresh_complete", ["elapsedSeconds": .double(elapsed)])
                self.onRateLimitsUpdated?(Self.parseRateLimits(
                    object,
                    accountID: self.accountID,
                    accountPlanType: self.accountPlanType
                ))
            case .failure(let error):
                let elapsed = abs(startedAt?.timeIntervalSinceNow ?? 0)
                let kind = (error as? CodexClientError)?.isTransportFailure == true ? "transport" : "request"
                self.diagnosticLog?.log("codex_refresh_failed", [
                    "kind": .string(kind),
                    "elapsedSeconds": .double(elapsed)
                ])
                self.emitError(error.localizedDescription)
            }
        }
    }

    private func readAccount(completion: (() -> Void)? = nil) {
        log("read account")
        sendRequest(method: "account/read", params: [:]) { result in
            switch result {
            case .success(let value):
                if let object = value as? [String: Any] {
                    self.accountID = object.value(at: ["account", "email"]).map { String(describing: $0) }
                    self.accountPlanType = object.value(at: ["account", "planType"]) as? String
                }
                completion?()
            case .failure(let error):
                self.emitError(error.localizedDescription)
                if (error as? CodexClientError)?.isTransportFailure != true {
                    completion?()
                }
            }
        }
    }

    @discardableResult
    private func sendNotification(method: String, params: [String: Any]) -> Bool {
        if case .failure(let error) = sendJSONObject(["method": method, "params": params]) {
            if error.isTransportFailure {
                processFailureReported = true
            }
            emitError(error.localizedDescription)
            if error.isTransportFailure {
                stopCurrentProcess()
            }
            return false
        }
        return true
    }

    private func sendJSONObject(_ object: [String: Any]) -> Result<Void, CodexClientError> {
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: object)
        } catch {
            return .failure(.message("Codex 요청 인코딩 실패: \(error.localizedDescription)"))
        }
        let newline = Data([0x0A])

        let method = object["method"] as? String ?? "unknown"
        let requestID = object["id"].flatMap(Self.numberAsInt)
        log("send method \(method)\(requestID.map { " id \($0)" } ?? "")")
        guard process?.isRunning == true, let inputHandle = stdinPipe?.fileHandleForWriting else {
            let error = transportError("app-server가 실행 중이 아닙니다")
            log("send skipped: \(error.localizedDescription)")
            return .failure(error)
        }

        do {
            try inputHandle.ccmbWrite(data)
            try inputHandle.ccmbWrite(newline)
            return .success(())
        } catch {
            let transportError = transportError("stdin 쓰기 실패: \(error.localizedDescription)")
            log(transportError.localizedDescription)
            return .failure(transportError)
        }
    }

    private func transportError(_ detail: String) -> CodexClientError {
        var context = currentCommandDescription.map { "실행 \($0)" } ?? "실행 경로 없음"
        if let process, !process.isRunning {
            context += ", 코드 \(process.terminationStatus), 이유 \(Self.terminationReasonDescription(process.terminationReason))"
        }
        diagnosticLog?.log("appserver_transport_failure")
        return .transport("Codex app-server 통신 실패 (\(context)): \(detail)")
    }

    private func handleOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        stdoutBuffer.append(data)

        while let newlineRange = stdoutBuffer.firstRange(of: Data([0x0A])) {
            let lineData = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<newlineRange.lowerBound)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...newlineRange.lowerBound)
            guard !lineData.isEmpty else { continue }
            handleLine(lineData)
        }
    }

    private func handleErrorOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        stderrBuffer.append(data)
        if stderrBuffer.count > 8_192 {
            stderrBuffer.removeFirst(stderrBuffer.count - 8_192)
        }

        let message = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !message.isEmpty {
            log("stderr \(message.replacingOccurrences(of: "\n", with: " | "))")
        }
    }

    private func stderrSummary() -> String {
        let summary = String(decoding: stderrBuffer, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " | ")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(
                of: "\u{001B}\\[[0-9;]*m",
                with: "",
                options: .regularExpression
            )

        let maximumLength = 800
        guard summary.count > maximumLength else { return summary }
        return "…" + summary.suffix(maximumLength)
    }

    private func handleLine(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log("recv invalid JSON")
            return
        }

        if let method = object["method"] as? String {
            log("recv notification \(method)")
        } else if let rawID = object["id"], let id = Self.numberAsInt(rawID) {
            log("recv response id \(id)")
        } else {
            log("recv unrecognized message")
        }

        if let method = object["method"] as? String, method == "account/rateLimits/updated" {
            refreshRateLimits()
            return
        }

        guard
            let rawID = object["id"],
            let id = Self.numberAsInt(rawID),
            let completion = pending.removeValue(forKey: id)
        else {
            return
        }

        if let errorObject = object["error"] {
            completion(.failure(CodexClientError.message(String(describing: errorObject))))
            return
        }

        completion(.success(object["result"] ?? [:]))
    }

    private func emitError(_ message: String) {
        guard !message.isEmpty else { return }
        log("error \(message)")
        deliverCallback {
            self.onError?(message)
        }
    }

    private func deliverCallback(_ callback: @escaping () -> Void) {
        if let callbackQueue {
            callbackQueue.async(execute: callback)
        } else {
            callback()
        }
    }

    private func findCodexLaunchCommand() -> LaunchCommand {
        let searchBinURLs = codexSearchBinURLs()
        let candidates = searchBinURLs.map { $0.appendingPathComponent("codex") }

        if let codexURL = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return LaunchCommand(
                executable: codexURL,
                arguments: ["app-server"],
                selectedCodexURL: codexURL,
                searchBinURLs: searchBinURLs
            )
        }

        return LaunchCommand(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["codex", "app-server"],
            selectedCodexURL: nil,
            searchBinURLs: searchBinURLs
        )
    }

    private func codexSearchBinURLs() -> [URL] {
        let fileManager = FileManager.default
        let environment = ProcessInfo.processInfo.environment
        let homeURL = fileManager.homeDirectoryForCurrentUser
        var binURLs: [URL] = []

        if let currentPath = environment["PATH"] {
            binURLs.append(contentsOf: currentPath
                .split(separator: ":")
                .map { URL(fileURLWithPath: String($0)) })
        }

        binURLs.append(contentsOf: [
            homeURL.appendingPathComponent(".local/bin"),
            homeURL.appendingPathComponent(".volta/bin"),
            homeURL.appendingPathComponent(".asdf/shims"),
            homeURL.appendingPathComponent(".mise/shims"),
            homeURL.appendingPathComponent(".local/share/mise/shims")
        ])

        if let voltaHome = environment["VOLTA_HOME"], !voltaHome.isEmpty {
            binURLs.append(URL(fileURLWithPath: voltaHome).appendingPathComponent("bin"))
        }
        if let asdfDataDirectory = environment["ASDF_DATA_DIR"], !asdfDataDirectory.isEmpty {
            binURLs.append(URL(fileURLWithPath: asdfDataDirectory).appendingPathComponent("shims"))
        }

        var nvmRootURLs = [homeURL.appendingPathComponent(".nvm")]
        if let nvmDirectory = environment["NVM_DIR"], !nvmDirectory.isEmpty {
            nvmRootURLs.insert(URL(fileURLWithPath: nvmDirectory), at: 0)
        }

        for nvmRootURL in nvmRootURLs {
            let versionsURL = nvmRootURL.appendingPathComponent("versions/node")
            guard let versionURLs = try? fileManager.contentsOfDirectory(
                at: versionsURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            binURLs.append(contentsOf: versionURLs
                .sorted { lhs, rhs in
                    lhs.lastPathComponent.compare(rhs.lastPathComponent, options: .numeric) == .orderedDescending
                }
                .map { $0.appendingPathComponent("bin") })
        }

        binURLs.append(contentsOf: [
            URL(fileURLWithPath: "/opt/homebrew/bin"),
            URL(fileURLWithPath: "/usr/local/bin"),
            URL(fileURLWithPath: "/usr/bin"),
            URL(fileURLWithPath: "/bin"),
            URL(fileURLWithPath: "/usr/sbin"),
            URL(fileURLWithPath: "/sbin")
        ])

        var seenPaths = Set<String>()
        return binURLs.filter { seenPaths.insert($0.standardizedFileURL.path).inserted }
    }

    private static func codexEnvironment(preferredBinURL: URL?, searchBinURLs: [URL]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        var pathEntries: [String] = []
        if let preferredBinURL {
            pathEntries.append(preferredBinURL.standardizedFileURL.path)
        }
        pathEntries.append(contentsOf: searchBinURLs.map { $0.standardizedFileURL.path })
        if let currentPath = environment["PATH"] {
            pathEntries.append(contentsOf: currentPath.split(separator: ":").map(String.init))
        }

        var seenPaths = Set<String>()
        environment["PATH"] = pathEntries
            .filter { !$0.isEmpty && seenPaths.insert($0).inserted }
            .joined(separator: ":")
        return environment
    }

    private static func terminationReasonDescription(_ reason: Process.TerminationReason) -> String {
        switch reason {
        case .exit:
            return "exit"
        case .uncaughtSignal:
            return "signal"
        @unknown default:
            return "unknown"
        }
    }

    private func log(_ message: String) {
        writePrivateLog(message)
    }

    private static func parseRateLimits(
        _ object: [String: Any],
        accountID: String?,
        accountPlanType: String?
    ) -> RateLimitSnapshot {
        let rateLimits = object["rateLimits"] as? [String: Any]
        let primary = rateLimits?["primary"] as? [String: Any]
        let sparkWeekly = UsageCore.sparkWeeklyWindow(
            from: object["rateLimitsByLimitId"] as? [String: Any]
        )

        let resetCredits = object.value(at: ["rateLimitResetCredits", "availableCount"]).flatMap(numberAsInt)
        let resetsAt = primary?["resetsAt"].flatMap(numberAsDouble).map {
            Date(timeIntervalSince1970: $0)
        }

        return RateLimitSnapshot(
            accountID: accountID,
            planType: rateLimits?["planType"] as? String ?? accountPlanType,
            usedPercent: primary?["usedPercent"].flatMap(numberAsDouble),
            windowDurationMinutes: primary?["windowDurationMins"].flatMap(numberAsInt),
            resetsAt: resetsAt,
            resetCredits: resetCredits,
            creditBalance: object.value(at: ["rateLimits", "credits", "balance"]).flatMap(numberAsDouble),
            sparkUsedPercent: sparkWeekly?.usedPercent,
            sparkWindowDurationMinutes: sparkWeekly?.windowDurationMinutes,
            sparkResetsAt: sparkWeekly?.resetsAt,
            detailedCreditsReturned: object.containsKeyRecursively("credits"),
            updatedAt: Date()
        )
    }

    private static func numberAsDouble(_ value: Any) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func numberAsInt(_ value: Any) -> Int? {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        if let string = value as? String { return Int(string) }
        return nil
    }
}

private enum CodexClientError: LocalizedError {
    case message(String)
    case transport(String)

    var isTransportFailure: Bool {
        if case .transport = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .message(let message):
            return message
        case .transport(let message):
            return message
        }
    }
}

private extension Dictionary where Key == String, Value == Any {
    func value(at path: [String]) -> Any? {
        guard let first = path.first else { return self }
        guard let value = self[first] else { return nil }
        guard path.count > 1 else { return value }
        return (value as? [String: Any])?.value(at: Array(path.dropFirst()))
    }

    func containsKeyRecursively(_ searchedKey: String) -> Bool {
        for (key, value) in self {
            if key == searchedKey { return true }
            if let dictionary = value as? [String: Any], dictionary.containsKeyRecursively(searchedKey) {
                return true
            }
            if let array = value as? [[String: Any]], array.contains(where: { $0.containsKeyRecursively(searchedKey) }) {
                return true
            }
        }

        return false
    }
}

private extension FileHandle {
    func ccmbWrite(_ data: Data) throws {
        if #available(macOS 10.15.4, *) {
            try write(contentsOf: data)
        } else {
            write(data)
        }
    }

    func ccmbClose() {
        if #available(macOS 10.15.4, *) {
            try? close()
        } else {
            closeFile()
        }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var statusMenu: NSMenu?
    private let client = CodexAppServerClient(diagnosticLog: .shared)
    private let networkMonitor = NWPathMonitor()
    private let networkQueue = DispatchQueue(label: "CodexCreditMenuBar.NetworkMonitor")
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    private var countdownTimer: DispatchSourceTimer?
    private var autoRefreshTimer: DispatchSourceTimer?
    private var refreshInterval: TimeInterval = AppDelegate.savedRefreshInterval()
    private var claudeRefreshInterval: TimeInterval = AppDelegate.savedClaudeRefreshInterval()
    private var geminiRefreshInterval: TimeInterval = AppDelegate.savedGeminiRefreshInterval()
    private var grokRefreshInterval: TimeInterval = AppDelegate.savedGrokRefreshInterval()
    private var nextAutoRefreshAt = Date()
    private var nextCodexRefreshAt = Date()
    private var nextClaudeRefreshAt = Date()
    private var nextGeminiRefreshAt = Date()
    private var nextGrokRefreshAt = Date()
    private var activity: NSObjectProtocol?
    private var instanceLockFileDescriptor: Int32 = -1

    private let accountItem = NSMenuItem(title: "계정 확인 중…", action: nil, keyEquivalent: "")
    private let usageItem = NSMenuItem(title: "Codex 사용량 확인 중…", action: nil, keyEquivalent: "")
    private let resetItem = NSMenuItem(title: "초기화 시간 확인 중…", action: nil, keyEquivalent: "")
    private let resetCreditsItem = NSMenuItem(title: "초기화 크레딧 확인 중…", action: nil, keyEquivalent: "")
    private let creditBalanceItem = NSMenuItem(title: "크레딧 확인 중…", action: nil, keyEquivalent: "")
    private let updatedItem = NSMenuItem(title: "가져온 시간 없음", action: nil, keyEquivalent: "")
    private let refreshItem = NSMenuItem(title: "새로 고침 · 30초 후", action: #selector(refresh), keyEquivalent: "")
    private let intervalItem = NSMenuItem(title: "자동 새로 고침 · 30초", action: nil, keyEquivalent: "")
    /// Each provider owns its cadence and choices. The timer scheduler wakes
    /// at the shortest enabled interval, while per-provider due dates ensure
    /// that wake-up never turns into an early request for another provider.
    private lazy var refreshIntervalItems: [NSMenuItem] = UsageCore.refreshIntervalOptions.map { seconds in
        let item = NSMenuItem(
            title: seconds == 0 ? "끔" : Self.durationTitle(seconds: seconds),
            action: #selector(AppDelegate.setCodexRefreshInterval(_:)),
            keyEquivalent: ""
        )
        item.representedObject = seconds
        return item
    }
    private lazy var claudeRefreshIntervalItems: [NSMenuItem] = UsageCore.claudeRefreshIntervalOptions.map { seconds in
        let item = NSMenuItem(
            title: seconds == 0 ? "끔" : Self.durationTitle(seconds: seconds),
            action: #selector(AppDelegate.setClaudeRefreshInterval(_:)),
            keyEquivalent: ""
        )
        item.representedObject = seconds
        return item
    }
    private lazy var geminiRefreshIntervalItems: [NSMenuItem] = UsageCore.geminiRefreshIntervalOptions.map { seconds in
        let item = NSMenuItem(
            title: seconds == 0 ? "끔" : Self.durationTitle(seconds: seconds),
            action: #selector(AppDelegate.setGeminiRefreshInterval(_:)),
            keyEquivalent: ""
        )
        item.representedObject = seconds
        return item
    }
    private lazy var grokRefreshIntervalItems: [NSMenuItem] = UsageCore.grokRefreshIntervalOptions.map { seconds in
        let item = NSMenuItem(
            title: seconds == 0 ? "끔" : Self.durationTitle(seconds: seconds),
            action: #selector(AppDelegate.setGrokRefreshInterval(_:)),
            keyEquivalent: ""
        )
        item.representedObject = seconds
        return item
    }
    private let codexIntervalItem = NSMenuItem(title: "Codex · 30초", action: nil, keyEquivalent: "")
    private let claudeIntervalItem = NSMenuItem(title: "Claude · 10분", action: nil, keyEquivalent: "")
    private let geminiIntervalItem = NSMenuItem(title: "Gemini · 5분", action: nil, keyEquivalent: "")
    private let grokIntervalItem = NSMenuItem(title: "Grok · 5분", action: nil, keyEquivalent: "")
    private let pinnedUsageWindowItem = NSMenuItem(
        title: "항상 보기",
        action: #selector(togglePinnedUsageWindow),
        keyEquivalent: ""
    )
    private let launchAtLoginItem = NSMenuItem(title: "자동 실행", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private let shareItem = NSMenuItem(title: "사용량 공유", action: nil, keyEquivalent: "")
    private let shareStatusItem = NSMenuItem(title: "공유 데이터 저장 대기 중…", action: nil, keyEquivalent: "")
    private let shareFolderItem = NSMenuItem(title: "저장 위치 열기", action: #selector(openSharedUsageFolder), keyEquivalent: "")
    private let copySharePromptCombinedItem = NSMenuItem(
        title: "전체(Codex+Claude+Gemini+Grok) 요청문 복사",
        action: #selector(copySharePromptCombined),
        keyEquivalent: ""
    )
    private let copySharePromptCodexItem = NSMenuItem(
        title: "Codex 전용 요청문 복사",
        action: #selector(copySharePromptCodex),
        keyEquivalent: ""
    )
    private let copySharePromptClaudeItem = NSMenuItem(
        title: "Claude 전용 요청문 복사",
        action: #selector(copySharePromptClaude),
        keyEquivalent: ""
    )
    private let copySharePromptGeminiItem = NSMenuItem(
        title: "Gemini 전용 요청문 복사",
        action: #selector(copySharePromptGemini),
        keyEquivalent: ""
    )
    private let copySharePromptGrokItem = NSMenuItem(
        title: "Grok 전용 요청문 복사",
        action: #selector(copySharePromptGrok),
        keyEquivalent: ""
    )
    private let copyShareCommandItem = NSMenuItem(title: "공유 명령 복사", action: #selector(copyShareCommand), keyEquivalent: "")
    private let copyErrorItem = NSMenuItem(title: "오류 내용 복사", action: #selector(copyLastError), keyEquivalent: "")
    private let usagePageLinksView = UsagePageButtonsView()
    private let usagePageLinksItem = NSMenuItem()
    private let menuRefreshControlsView = RefreshIntervalControlsView()
    private let menuRefreshControlsItem = NSMenuItem()
    private let lifecycleActionsView = LifecycleActionsRowView()
    private let lifecycleActionsItem = NSMenuItem()
    private let historyChartView = UsageHistoryChartView()
    private let historyChartItem = NSMenuItem()
    /// Per-refresh consumption strips, persisted so the chart is not blank for
    /// the first stretch after every launch.
    private var codexConsumption = UsageConsumptionTracker()
    private var claudeConsumption = UsageConsumptionTracker()
    private var geminiConsumption = UsageConsumptionTracker()
    private var grokConsumption = UsageConsumptionTracker()
    private let checkForUpdatesItem = NSMenuItem(
        title: "업데이트 확인…",
        action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
        keyEquivalent: ""
    )
    private lazy var updateVersionView = VersionOpacityRowView(
        alwaysTitle: "항상 보기",
        updateTitle: "업데이트 확인…",
        versionTitle: "현재 버전 \(appVersion)"
    )
    private var panelOpacity: Double = AppDelegate.savedPanelOpacity()
    private let updateVersionItem = NSMenuItem()
    private let restartItem = NSMenuItem(title: "CCMB 다시 시작", action: #selector(restartApp), keyEquivalent: "")
    private let diagnosticsItem = NSMenuItem(title: "진단", action: nil, keyEquivalent: "")
    private let copyDiagnosticReportItem = NSMenuItem(title: "진단 리포트 복사", action: #selector(copyDiagnosticReport), keyEquivalent: "")
    private let openDiagnosticLogItem = NSMenuItem(title: "진단 로그 폴더 열기", action: #selector(openDiagnosticLogFolder), keyEquivalent: "")
    private let footerLinkItem = NSMenuItem(title: "GitHub에서 armsone 보기…", action: #selector(openFooterLink), keyEquivalent: "")
    private let quitItem = NSMenuItem(title: "CCMB 종료", action: #selector(quit), keyEquivalent: "q")
    private let splitPanelView = SplitUsagePanelView()
    private let splitPanelItem = NSMenuItem()
    private var pinnedUsageWindowController: PinnedUsageWindowController?
    /// The status-item's own dropdown, once usage data has loaded at least
    /// once. Reuses the exact same content stack as the persistent "항상
    /// 보기" panel — one whole-panel background behind fully opaque
    /// foreground rows — instead of an `NSMenu`, whose own vibrant
    /// background can't be tinted by the opacity slider. Before the first
    /// snapshot arrives, `showStatusMenu` still falls back to the native
    /// `statusMenu` built below, which carries the original loading/offline
    /// text rows.
    private lazy var statusDropdownController: PinnedUsageWindowController = {
        let controller = PinnedUsageWindowController(transient: true)
        controller.dismissalExcludedView = statusItem.button
        controller.onCodexRefreshIntervalChange = { [weak self] in self?.applyCodexRefreshInterval($0) }
        controller.onClaudeRefreshIntervalChange = { [weak self] in self?.applyClaudeRefreshInterval($0) }
        controller.onGeminiRefreshIntervalChange = { [weak self] in self?.applyGeminiRefreshInterval($0) }
        controller.onGrokRefreshIntervalChange = { [weak self] in self?.applyGrokRefreshInterval($0) }
        controller.onGrokUsageAction = { [weak self] in self?.performGrokUsageAction() }
        controller.onOpacityChange = { [weak self] in self?.changePinnedPanelOpacity($0) }
        controller.setShareMenu(makeShareMenu())
        controller.onCheckForUpdates = { [weak self] in self?.updaterController.checkForUpdates(nil) }
        controller.onOpenDiagnosticLog = { [weak self] in self?.openDiagnosticLogFolder() }
        controller.onOpenGitHub = { [weak self] in self?.openFooterLink() }
        controller.onToggleLaunchAtLogin = { [weak self] in self?.toggleLaunchAtLogin() }
        controller.onRestart = { [weak self] in self?.restartApp() }
        controller.onQuit = { [weak self] in self?.quit() }
        controller.onToggleAlwaysView = { [weak self] in self?.togglePinnedUsageWindow() }
        controller.setOpacity(panelOpacity)
        return controller
    }()
    private let usageSeparatorItem = NSMenuItem.separator()
    private let accountSeparatorItem = NSMenuItem.separator()
    private var lastRateLimitUpdatedAt: Date?
    private var lastSnapshot: RateLimitSnapshot?
    private var lastClaudeSnapshot: ClaudeUsageSnapshot?
    private var lastClaudeFetchFailureLabel: String?
    /// Set only while a 429 backoff is active; drives a live "N초 후 재시도"
    /// countdown in the panel instead of a static label frozen at fetch time.
    private var lastClaudeRateLimitRetryAt: Date?
    private var lastGeminiSnapshot: GeminiUsageSnapshot?
    private var lastGeminiFetchFailureLabel: String?
    private var lastGrokSnapshot: GrokUsageSnapshot?
    private var lastGrokFetchFailureLabel: String?
    private var grokLoginRequired = false
    private var grokLoginInProgress = false
    private var grokAuthRecoveryInProgress = false
    private var lastGrokAuthRecoveryAttemptAt: Date?
    private var lastSharedUsageAt: Date?
    private var lastShareError: String?
    private var helperInstallError: String?
    private var shareFeedback: (message: String, expiresAt: Date)?
    private var lastErrorMessage: String?
    private var wakeRecoveryToken = 0
    private let wakeRestartDelay: TimeInterval = 14
    private var isOffline = false
    private let diagnosticLog = DiagnosticLog.shared
    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
    }
    deinit {
        writePrivateLog("app delegate deinit")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        appLog("delegate did finish launching")
        diagnosticLog.log("app_launch", ["version": .string(appVersion)])
        NSApp.setActivationPolicy(.accessory)
        guard acquireSingleInstanceLock() else {
            NSApp.terminate(nil)
            return
        }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Keep Codex, Claude, Gemini, and Grok usage auto-refresh running"
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWakeFromSleep),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        loadConsumptionTrackers()
        configureStatusItem()
        installUsageHelper()
        configureClient()
        startNetworkMonitor()
        refreshLaunchAgentPathIfNeeded()
        client.setAutoRefreshInterval(refreshInterval)
        client.start()
        startCountdownTimer()
        restartAutoRefreshTimer()
        refreshClaudeUsage()
        refreshGeminiUsage()
        refreshGrokUsage()
    }

    func menuWillOpen(_ menu: NSMenu) {
        diagnosticLog.log("menu_open")
    }

    func applicationWillTerminate(_ notification: Notification) {
        diagnosticLog.log("app_terminate")
        countdownTimer?.cancel()
        networkMonitor.cancel()
        stopAutoRefreshLoop()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
        client.stop()
        if instanceLockFileDescriptor >= 0 {
            Darwin.close(instanceLockFileDescriptor)
            instanceLockFileDescriptor = -1
        }
        diagnosticLog.flush()
    }

    private func acquireSingleInstanceLock() -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: SharedUsageStore.directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            appLog("single instance directory failed: \(error.localizedDescription)")
            return false
        }

        let lockURL = SharedUsageStore.directoryURL.appendingPathComponent("instance.lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            appLog("single instance lock open failed: errno \(errno)")
            return false
        }
        guard Darwin.lockf(descriptor, F_TLOCK, 0) == 0 else {
            Darwin.close(descriptor)
            appLog("another CCMB instance is already running")
            return false
        }
        instanceLockFileDescriptor = descriptor
        return true
    }

    @objc private func handleWakeFromSleep() {
        appLog("did wake from sleep")
        diagnosticLog.log("sleep_wake_recovery")
        recoverAfterWake()
    }

    private func recoverAfterWake() {
        guard !isOffline else {
            showOfflineStatus()
            return
        }

        wakeRecoveryToken += 1
        let token = wakeRecoveryToken
        lastRateLimitUpdatedAt = nil

        setDetailTitle("잠자기 복귀: 복구 중...", for: usageItem)
        setDetailTitle("잠자기 복귀: 복구 중...", for: updatedItem)
        statusItem.button?.setAccessibilityValue("사용량 복구 중")

        stopAutoRefreshLoop()
        countdownTimer?.cancel()
        client.recoverFromSleep()
        startCountdownTimer()
        restartAutoRefreshTimer()
        resetCountdown()
        scheduleWakeRecoveryWatchdog(token: token)
    }

    private func scheduleWakeRecoveryWatchdog(token: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self else { return }
            guard token == self.wakeRecoveryToken else { return }
            guard !self.isOffline else {
                self.showOfflineStatus()
                return
            }

            guard self.lastRateLimitUpdatedAt == nil else { return }

            self.appLog("wake recovery watchdog: no update after 8s, retry app-server")
            self.setDetailTitle("복구 재시도 중...", for: self.updatedItem)
            self.client.recoverFromSleep()
            self.scheduleWakeRecoveryRestart(token: token)
        }
    }

    private func scheduleWakeRecoveryRestart(token: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + wakeRestartDelay) { [weak self] in
            guard let self else { return }
            guard token == self.wakeRecoveryToken else { return }
            guard !self.isOffline else {
                self.showOfflineStatus()
                return
            }
            guard self.lastRateLimitUpdatedAt == nil else { return }

            self.appLog("wake recovery watchdog: hard restart triggered")
            self.setDetailTitle("앱 재시작 복구...", for: self.updatedItem)
            self.restartAppForReason("wake-recovery")
        }
    }

    @objc private func restartApp() {
        restartAppForReason("manual")
    }

    private func restartAppForReason(_ reason: String) {
        diagnosticLog.log("app_restart_requested", ["reason": .string(reason)])
        let appPath = Bundle.main.bundlePath
        if FileManager.default.fileExists(atPath: appPath) {
            let relauncher = Process()
            relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
            relauncher.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$1\"", "ccmb-relaunch", appPath]
            try? relauncher.run()
        }
        NSApp.terminate(nil)
    }

    private func startCountdownTimer() {
        countdownTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            self?.updateCountdown()
        }
        countdownTimer = timer
        timer.resume()
        updateCountdown()
    }

    private func restartAutoRefreshTimer() {
        autoRefreshTimer?.cancel()
        autoRefreshTimer = nil
        resetProviderDeadlines()
        scheduleNextAutoRefresh()
        updateCountdown()
    }

    /// Arms a one-shot timer for the exact earliest provider deadline. A
    /// repeating 30-second scheduler could leave slower providers displayed at
    /// zero for almost a full tick before it happened to wake again.
    private func scheduleNextAutoRefresh() {
        autoRefreshTimer?.cancel()
        autoRefreshTimer = nil
        updateNextAutoRefreshAt()
        guard nextAutoRefreshAt != .distantFuture else {
            appLog("auto refresh timer off")
            diagnosticLog.log("auto_refresh_timer_stop", ["reason": .string("disabled")])
            return
        }

        let delay = max(0, nextAutoRefreshAt.timeIntervalSinceNow)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + delay,
            leeway: .milliseconds(100)
        )
        timer.setEventHandler { [weak self] in
            self?.performAutoRefresh()
        }
        autoRefreshTimer = timer
        timer.resume()
        appLog("auto refresh scheduler next \(Int(ceil(delay)))s")
        diagnosticLog.log("auto_refresh_timer_start", ["intervalSeconds": .int(Int(ceil(delay)))])
    }

    private func stopAutoRefreshLoop() {
        autoRefreshTimer?.cancel()
        autoRefreshTimer = nil
        appLog("auto refresh timer stop")
        diagnosticLog.log("auto_refresh_timer_stop", ["reason": .string("stop")])
    }

    private func performAutoRefresh() {
        let now = Date()
        let refreshCodex = refreshInterval > 0 && now >= nextCodexRefreshAt
        let refreshClaude = claudeRefreshInterval > 0 && now >= nextClaudeRefreshAt
        let refreshGemini = geminiRefreshInterval > 0 && now >= nextGeminiRefreshAt
        let refreshGrok = grokRefreshInterval > 0 && now >= nextGrokRefreshAt
        guard refreshCodex || refreshClaude || refreshGemini || refreshGrok else {
            updateNextAutoRefreshAt()
            scheduleNextAutoRefresh()
            updateCountdown()
            return
        }
        if refreshCodex { nextCodexRefreshAt = now.addingTimeInterval(refreshInterval) }
        if refreshClaude { nextClaudeRefreshAt = now.addingTimeInterval(claudeRefreshInterval) }
        if refreshGemini { nextGeminiRefreshAt = now.addingTimeInterval(geminiRefreshInterval) }
        if refreshGrok { nextGrokRefreshAt = now.addingTimeInterval(grokRefreshInterval) }
        updateNextAutoRefreshAt()
        scheduleNextAutoRefresh()
        appLog("auto refresh perform codex=\(refreshCodex) claude=\(refreshClaude) gemini=\(refreshGemini) grok=\(refreshGrok)")
        diagnosticLog.log("auto_refresh_timer_fire", [
            "codex": .bool(refreshCodex),
            "claude": .bool(refreshClaude),
            "gemini": .bool(refreshGemini),
            "grok": .bool(refreshGrok)
        ])
        guard !isOffline else {
            showOfflineStatus()
            return
        }

        setDetailTitle("자동 갱신 중...", for: usageItem)
        setDetailTitle("자동 가져오기 중...", for: updatedItem)
        statusItem.button?.setAccessibilityValue("사용량 업데이트 중")
        updateCountdown()
        if refreshCodex { client.refreshRateLimits() }
        if refreshClaude { refreshClaudeUsage() }
        if refreshGemini { refreshGeminiUsage() }
        if refreshGrok { refreshGrokUsage() }
    }

    private func resetCountdown() {
        resetProviderDeadlines()
        scheduleNextAutoRefresh()
        updateCountdown()
    }

    private func resetProviderDeadlines() {
        let now = Date()
        nextCodexRefreshAt = refreshInterval > 0 ? now.addingTimeInterval(refreshInterval) : .distantFuture
        nextClaudeRefreshAt = claudeRefreshInterval > 0 ? now.addingTimeInterval(claudeRefreshInterval) : .distantFuture
        nextGeminiRefreshAt = geminiRefreshInterval > 0 ? now.addingTimeInterval(geminiRefreshInterval) : .distantFuture
        nextGrokRefreshAt = grokRefreshInterval > 0 ? now.addingTimeInterval(grokRefreshInterval) : .distantFuture
        if let retryAt = lastClaudeRateLimitRetryAt, retryAt > nextClaudeRefreshAt {
            nextClaudeRefreshAt = retryAt
        }
        updateNextAutoRefreshAt()
    }

    private func updateNextAutoRefreshAt() {
        nextAutoRefreshAt = [nextCodexRefreshAt, nextClaudeRefreshAt, nextGeminiRefreshAt, nextGrokRefreshAt].min() ?? .distantFuture
    }

    private func updateCountdown() {
        updateShareStatus()
        let remaining: (Date, TimeInterval) -> Int? = { deadline, interval in
            guard interval > 0, deadline != .distantFuture else { return nil }
            return max(0, Int(ceil(deadline.timeIntervalSinceNow)))
        }
        let codexRemaining = remaining(nextCodexRefreshAt, refreshInterval)
        let claudeRemaining = remaining(nextClaudeRefreshAt, claudeRefreshInterval)
        let geminiRemaining = remaining(nextGeminiRefreshAt, geminiRefreshInterval)
        let grokRemaining = remaining(nextGrokRefreshAt, grokRefreshInterval)
        menuRefreshControlsView.updateCountdown(
            codex: codexRemaining,
            claude: claudeRemaining,
            gemini: geminiRemaining,
            grok: grokRemaining
        )
        pinnedUsageWindowController?.updateRefreshCountdown(
            codex: codexRemaining,
            claude: claudeRemaining,
            gemini: geminiRemaining,
            grok: grokRemaining
        )
        statusDropdownController.updateRefreshCountdown(
            codex: codexRemaining,
            claude: claudeRemaining,
            gemini: geminiRemaining,
            grok: grokRemaining
        )
        guard nextAutoRefreshAt != .distantFuture else {
            setDetailTitle("새로 고침", for: refreshItem)
            return
        }

        let seconds = max(0, Int(ceil(nextAutoRefreshAt.timeIntervalSinceNow)))
        setDetailTitle("다음 자동 갱신 · \(Self.durationTitle(seconds: seconds)) 후", for: refreshItem)
        if lastClaudeRateLimitRetryAt != nil {
            updateSplitPanel()
        }
    }

    private func updateRefreshIntervalMenu() {
        for item in refreshIntervalItems {
            let seconds = (item.representedObject as? Int) ?? -1
            item.state = Int(refreshInterval) == seconds ? .on : .off
            setDetailTitle(item.title, for: item)
        }
        for item in claudeRefreshIntervalItems {
            let seconds = (item.representedObject as? Int) ?? -1
            item.state = Int(claudeRefreshInterval) == seconds ? .on : .off
        }
        for item in geminiRefreshIntervalItems {
            let seconds = (item.representedObject as? Int) ?? -1
            item.state = Int(geminiRefreshInterval) == seconds ? .on : .off
        }
        for item in grokRefreshIntervalItems {
            let seconds = (item.representedObject as? Int) ?? -1
            item.state = Int(grokRefreshInterval) == seconds ? .on : .off
        }
        codexIntervalItem.title = "Codex · \(Self.intervalTitle(refreshInterval))"
        claudeIntervalItem.title = "Claude · \(Self.intervalTitle(claudeRefreshInterval))"
        geminiIntervalItem.title = "Gemini · \(Self.intervalTitle(geminiRefreshInterval))"
        grokIntervalItem.title = "Grok · \(Self.intervalTitle(grokRefreshInterval))"
        menuRefreshControlsView.apply(
            codex: Int(refreshInterval),
            claude: Int(claudeRefreshInterval),
            gemini: Int(geminiRefreshInterval),
            grok: Int(grokRefreshInterval)
        )
        setDetailTitle("자동 새로 고침 · 앱별 설정", for: intervalItem)
    }

    private func setDetailTitle(_ title: String, for item: NSMenuItem) {
        item.title = title
    }

    private func prepareNativeMenu(_ menu: NSMenu) {
        menu.autoenablesItems = false
        for item in menu.items {
            guard !item.isSeparatorItem else { continue }
            if let submenu = item.submenu {
                prepareNativeMenu(submenu)
            }
            // Items hosting a custom view (the split usage panel, the usage
            // page buttons) manage their own subview interactivity and must
            // stay enabled regardless of the item's own action/submenu.
            guard item.view == nil else { continue }
            item.isEnabled = item.action != nil || item.submenu != nil
        }
    }

    private func configureStatusItem() {
        statusItem.button?.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        statusItem.button?.toolTip = "Codex, Claude, Gemini, Grok 남은 사용량과 크레딧"
        statusItem.button?.imageHugsTitle = true
        statusItem.button?.setAccessibilityLabel("Codex, Claude, Gemini, Grok 사용량")

        if #available(macOS 11.0, *) {
            if let image = NSImage(systemSymbolName: "bolt.circle", accessibilityDescription: "CCMB 사용량") {
                image.isTemplate = true
                statusItem.button?.image = image
                statusItem.button?.imagePosition = .imageLeading
            }
        }
        setStatusTitle("…")
        statusItem.button?.setAccessibilityValue("사용량 확인 중")

        let menu = NSMenu()
        menu.autoenablesItems = false
        // Status-item menus anchor their trailing edge beneath the status
        // button. Matching the dashboard width keeps the rightmost Grok
        // column directly below that button instead of leaving a side gutter.
        menu.minimumWidth = UsagePanelLayout.viewWidth
        accountItem.isEnabled = true
        usageItem.isEnabled = true
        resetItem.isEnabled = true
        resetCreditsItem.isEnabled = true
        creditBalanceItem.isEnabled = true
        updatedItem.isEnabled = true
        refreshItem.isEnabled = true
        intervalItem.isEnabled = true
        setDetailTitle(accountItem.title, for: accountItem)
        setDetailTitle(usageItem.title, for: usageItem)
        setDetailTitle(resetItem.title, for: resetItem)
        setDetailTitle(resetCreditsItem.title, for: resetCreditsItem)
        setDetailTitle(creditBalanceItem.title, for: creditBalanceItem)
        setDetailTitle(updatedItem.title, for: updatedItem)
        setDetailTitle(refreshItem.title, for: refreshItem)
        setDetailTitle(intervalItem.title, for: intervalItem)
        resetCreditsItem.isHidden = true

        splitPanelItem.view = splitPanelView
        splitPanelItem.isHidden = true
        menu.addItem(splitPanelItem)

        menuRefreshControlsView.onCodexChange = { [weak self] in self?.applyCodexRefreshInterval($0) }
        menuRefreshControlsView.onClaudeChange = { [weak self] in self?.applyClaudeRefreshInterval($0) }
        menuRefreshControlsView.onGeminiChange = { [weak self] in self?.applyGeminiRefreshInterval($0) }
        menuRefreshControlsView.onGrokChange = { [weak self] in self?.applyGrokRefreshInterval($0) }
        menuRefreshControlsItem.view = menuRefreshControlsView
        menuRefreshControlsItem.isEnabled = true
        menu.addItem(menuRefreshControlsItem)

        menu.addItem(usageItem)
        menu.addItem(creditBalanceItem)
        menu.addItem(resetCreditsItem)
        menu.addItem(resetItem)
        menu.addItem(usageSeparatorItem)
        menu.addItem(updatedItem)
        copyErrorItem.isHidden = true
        menu.addItem(copyErrorItem)
        historyChartItem.view = historyChartView
        historyChartItem.isEnabled = false
        historyChartItem.isHidden = true
        menu.addItem(historyChartItem)

        usagePageLinksView.codexButton.target = self
        usagePageLinksView.codexButton.action = #selector(openDashboard)
        usagePageLinksView.claudeButton.target = self
        usagePageLinksView.claudeButton.action = #selector(openClaudeDashboard)
        usagePageLinksView.geminiButton.target = self
        usagePageLinksView.geminiButton.action = #selector(openGeminiDashboard)
        usagePageLinksView.grokButton.target = self
        usagePageLinksView.grokButton.action = #selector(performGrokUsageAction)
        usagePageLinksItem.view = usagePageLinksView
        usagePageLinksItem.isEnabled = true
        menu.addItem(usagePageLinksItem)

        let codexIntervalMenu = NSMenu()
        for item in refreshIntervalItems {
            codexIntervalMenu.addItem(item)
        }
        codexIntervalItem.submenu = codexIntervalMenu

        let claudeIntervalMenu = NSMenu()
        for item in claudeRefreshIntervalItems {
            claudeIntervalMenu.addItem(item)
        }
        claudeIntervalItem.submenu = claudeIntervalMenu

        let geminiIntervalMenu = NSMenu()
        for item in geminiRefreshIntervalItems {
            geminiIntervalMenu.addItem(item)
        }
        geminiIntervalItem.submenu = geminiIntervalMenu

        let grokIntervalMenu = NSMenu()
        for item in grokRefreshIntervalItems {
            grokIntervalMenu.addItem(item)
        }
        grokIntervalItem.submenu = grokIntervalMenu

        let intervalMenu = NSMenu()
        intervalMenu.addItem(codexIntervalItem)
        intervalMenu.addItem(claudeIntervalItem)
        intervalMenu.addItem(geminiIntervalItem)
        intervalMenu.addItem(grokIntervalItem)
        intervalItem.submenu = intervalMenu
        menu.addItem(accountItem)
        menu.addItem(accountSeparatorItem)

        configureShareMenu()
        menu.addItem(shareItem)
        menu.addItem(.separator())
        updateVersionView.updateButton.target = updaterController
        updateVersionView.updateButton.action = #selector(SPUStandardUpdaterController.checkForUpdates(_:))
        updateVersionView.versionButton.isBordered = false
        updateVersionView.versionButton.isEnabled = false
        updateVersionView.versionButton.font = .systemFont(ofSize: 11, weight: .regular)
        updateVersionView.versionButton.setAccessibilityRole(.staticText)
        updateVersionView.opacitySlider.target = self
        updateVersionView.opacitySlider.action = #selector(changePanelOpacity(_:))
        updateVersionView.setOpacity(panelOpacity)
        updateVersionItem.view = updateVersionView
        updateVersionItem.isEnabled = true
        menu.addItem(updateVersionItem)
        applyPanelOpacity()

        configureDiagnosticsMenu()
        updateVersionView.alwaysViewButton.target = self
        updateVersionView.alwaysViewButton.action = #selector(togglePinnedUsageWindow)
        lifecycleActionsView.launchButton.target = self
        lifecycleActionsView.launchButton.action = #selector(toggleLaunchAtLogin)
        lifecycleActionsView.diagnosticButton.target = self
        lifecycleActionsView.diagnosticButton.action = #selector(openDiagnosticLogFolder)
        lifecycleActionsView.githubButton.target = self
        lifecycleActionsView.githubButton.action = #selector(openFooterLink)
        lifecycleActionsView.restartButton.target = self
        lifecycleActionsView.restartButton.action = #selector(restartApp)
        lifecycleActionsView.quitButton.target = self
        lifecycleActionsView.quitButton.action = #selector(quit)
        lifecycleActionsItem.view = lifecycleActionsView
        lifecycleActionsItem.isEnabled = true
        menu.addItem(lifecycleActionsItem)

        let bottomPaddingItem = NSMenuItem()
        bottomPaddingItem.view = NSView(frame: NSRect(
            x: 0,
            y: 0,
            width: UsagePanelLayout.viewWidth,
            height: 4
        ))
        bottomPaddingItem.isEnabled = false
        menu.addItem(bottomPaddingItem)

        for item in menu.items {
            item.target = self
        }
        checkForUpdatesItem.target = updaterController
        refreshItem.target = self
        // The loop above only walks top-level items, so submenu items need
        // their target set explicitly.
        for item in refreshIntervalItems {
            item.target = self
        }
        for item in claudeRefreshIntervalItems {
            item.target = self
        }
        for item in geminiRefreshIntervalItems {
            item.target = self
        }
        for item in grokRefreshIntervalItems {
            item.target = self
        }
        launchAtLoginItem.target = self
        pinnedUsageWindowItem.target = self
        shareFolderItem.target = self
        copySharePromptCombinedItem.target = self
        copySharePromptCodexItem.target = self
        copySharePromptClaudeItem.target = self
        copySharePromptGeminiItem.target = self
        copySharePromptGrokItem.target = self
        copyShareCommandItem.target = self
        copyErrorItem.target = self
        restartItem.target = self
        copyDiagnosticReportItem.target = self
        openDiagnosticLogItem.target = self
        footerLinkItem.target = self
        quitItem.target = self
        updateRefreshIntervalMenu()
        updatePinnedUsageWindowMenu()
        updateLaunchAtLoginMenu()
        prepareNativeMenu(menu)

        menu.delegate = self
        statusMenu = menu
        statusItem.menu = nil
        statusItem.button?.target = self
        statusItem.button?.action = #selector(showStatusMenu)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    /// Opens the wide dashboard centered beneath the status item, with its
    /// top edge seven points below the menu-bar button's bottom edge.
    @objc private func showStatusMenu() {
        guard let button = statusItem.button, let window = button.window else { return }

        // Before the first usage snapshot ever arrives, fall back to the
        // native menu, which still carries the original loading/offline/
        // error text rows that the dropdown panel has no equivalent for.
        guard lastSnapshot != nil else {
            guard let menu = statusMenu else { return }
            menu.update()
            let windowRect = button.convert(button.bounds, to: nil)
            let screenRect = window.convertToScreen(windowRect)
            let point = NSPoint(x: screenRect.midX - menu.size.width / 2, y: screenRect.minY - 7)
            button.highlight(true)
            menu.popUp(positioning: nil, at: point, in: nil)
            button.highlight(false)
            return
        }

        if statusDropdownController.isVisible {
            statusDropdownController.close()
            return
        }

        diagnosticLog.log("menu_open")
        let windowRect = button.convert(button.bounds, to: nil)
        let screenRect = window.convertToScreen(windowRect)
        let point = NSPoint(x: screenRect.midX - UsagePanelLayout.viewWidth / 2, y: screenRect.minY - 7)
        button.highlight(true)
        statusDropdownController.positionTopLeft(point)
        statusDropdownController.show()
        button.highlight(false)
    }

    private func configureClient() {
        client.onRateLimitsUpdated = { [weak self] snapshot in
            DispatchQueue.main.async {
                self?.isOffline = false
                self?.lastRateLimitUpdatedAt = Date()
                self?.apply(snapshot)
            }
        }

        client.onError = { [weak self] message in
            DispatchQueue.main.async {
                guard let self else { return }
                self.lastErrorMessage = message
                self.setStatusTitle("!")
                self.statusItem.button?.setAccessibilityValue("사용량 가져오기 실패")
                self.setDetailTitle("사용량을 가져오지 못했습니다", for: self.usageItem)
                self.usageItem.toolTip = message
                self.copyErrorItem.isHidden = false
                self.setDetailTitle("가져오기 실패 \(Self.timeFormatter.string(from: Date()))", for: self.updatedItem)
            }
        }

        client.onRestartRequired = { [weak self] message in
            DispatchQueue.main.async {
                guard let self else { return }
                guard !self.isOffline else {
                    self.showOfflineStatus()
                    return
                }

                self.appLog(message)
                self.setStatusTitle("!")
                self.setDetailTitle(message, for: self.updatedItem)
                self.restartAppForReason("appserver-watchdog")
            }
        }
    }

    private func startNetworkMonitor() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self else { return }
                let wasOffline = self.isOffline
                self.isOffline = path.status != .satisfied

                if self.isOffline {
                    self.appLog("network offline")
                    self.diagnosticLog.log("network_offline")
                    self.showOfflineStatus()
                } else if wasOffline {
                    self.appLog("network online")
                    self.diagnosticLog.log("network_online")
                    self.setDetailTitle("연결 복구, 다시 가져오는 중...", for: self.updatedItem)
                    self.statusItem.button?.setAccessibilityValue("연결 복구 중")
                    self.client.recoverFromSleep()
                    self.restartAutoRefreshTimer()
                }
            }
        }
        networkMonitor.start(queue: networkQueue)
    }

    private func showOfflineStatus() {
        setStatusTitle("OFF")
        statusItem.button?.setAccessibilityValue("오프라인")
        setDetailTitle("오프라인", for: usageItem)
        setDetailTitle("인터넷 연결 대기 중...", for: updatedItem)
        updateCountdown()
    }

    private func apply(_ snapshot: RateLimitSnapshot) {
        lastSnapshot = snapshot
        recordCodexConsumption(from: snapshot)
        refreshStatusTitle()
        lastErrorMessage = nil
        usageItem.toolTip = nil
        copyErrorItem.isHidden = true

        if let usedPercent = snapshot.usedPercent {
            let remainingPercent = Self.remainingUsagePercent(from: usedPercent)
            setDetailTitle("남은 주간 사용량 \(Self.percentTitle(from: remainingPercent))", for: usageItem)
        } else {
            setDetailTitle("주간 사용량 정보 없음", for: usageItem)
        }

        if let accountID = snapshot.accountID {
            setDetailTitle("계정 \(accountID)", for: accountItem)
        } else {
            setDetailTitle("계정 정보 없음", for: accountItem)
        }

        if let resetsAt = snapshot.resetsAt {
            setDetailTitle("\(Self.resetDateTimeFormatter.string(from: resetsAt)) 초기화", for: resetItem)
            resetItem.toolTip = nil
        } else if let minutes = snapshot.windowDurationMinutes {
            setDetailTitle("사용량 창 \(minutes)분", for: resetItem)
            resetItem.toolTip = nil
        } else {
            setDetailTitle("초기화 시간 없음", for: resetItem)
            resetItem.toolTip = nil
        }

        if let resetCredits = snapshot.resetCredits {
            resetCreditsItem.isHidden = false
            setDetailTitle("초기화 크레딧 \(resetCredits)개", for: resetCreditsItem)
        } else {
            resetCreditsItem.isHidden = true
        }

        if let creditBalance = snapshot.creditBalance {
            setDetailTitle("크레딧 \(Self.creditDetailTitle(from: creditBalance))", for: creditBalanceItem)
        } else {
            setDetailTitle(
                snapshot.detailedCreditsReturned ? "크레딧 형식 확인 필요" : "크레딧 정보 없음",
                for: creditBalanceItem
            )
        }
        setDetailTitle("최근 업데이트 \(Self.timeFormatter.string(from: snapshot.updatedAt))", for: updatedItem)
        publishSharedUsage(snapshot, origin: "codex-fetch")
        updateSplitPanel()
    }

    /// Writes the shared `usage-v1.json` snapshot. `origin` distinguishes a
    /// genuine Codex fetch (`apply(_:)`, right after a fresh app-server
    /// response) from a republish triggered by an unrelated Claude/Gemini
    /// refresh reusing the last known Codex snapshot — the two look
    /// identical in the written file but must not look identical in the
    /// diagnostic log, or a stalled Codex fetch could hide behind a stream
    /// of "successful" publishes that never carried new Codex data.
    private func publishSharedUsage(_ snapshot: RateLimitSnapshot, origin: String) {
        do {
            try SharedUsageStore.publish(
                snapshot,
                claudeSnapshot: lastClaudeSnapshot,
                claudeRetryAt: lastClaudeRateLimitRetryAt,
                claudeFailureLabel: lastClaudeFetchFailureLabel,
                geminiSnapshot: lastGeminiSnapshot,
                grokSnapshot: lastGrokSnapshot,
                refreshInterval: refreshInterval
            )
            lastSharedUsageAt = snapshot.updatedAt
            lastShareError = nil
            updateShareStatus()
            let codexAgeSeconds = max(0, Int(Date().timeIntervalSince(snapshot.updatedAt)))
            diagnosticLog.log("shared_payload_published", [
                "origin": .string(origin),
                "codexFetchedAgeSeconds": .int(codexAgeSeconds)
            ])
        } catch {
            lastShareError = error.localizedDescription
            updateShareStatus()
            appLog("shared usage publish failed: \(error.localizedDescription)")
            diagnosticLog.log("shared_payload_publish_failed")
        }
    }

    private func refreshClaudeUsage() {
        lastClaudeSnapshot = ClaudeUsageCore.mergingCacheSnapshot(
            current: lastClaudeSnapshot,
            cache: SharedUsageStore.readClaudeSnapshot()
        )
        lastClaudeSnapshot = ClaudeUsageCore.mergingCacheSnapshot(
            current: lastClaudeSnapshot,
            cache: ClaudeUsageStore.read()
        )
        recordClaudeConsumption()
        if let lastSnapshot {
            publishSharedUsage(lastSnapshot, origin: "cache-republish")
        }
        refreshStatusTitle()
        updateSplitPanel()

        // A complete, recent statusLine observation came from Claude Code's
        // own response path. Prefer it over an extra request to the
        // undocumented OAuth endpoint.
        if let snapshot = lastClaudeSnapshot,
           snapshot.quotaSource == "claude-statusline",
           snapshot.hasRateLimitUsage,
           ClaudeUsageCore.isFresh(
               publishedAt: snapshot.publishedAt,
               now: Date(),
               freshForSeconds: ClaudeUsageCore.statusLineFreshForSeconds
           ) {
            return
        }

        let claudeFetchInterval = max(claudeRefreshInterval, ClaudeUsageCore.minimumRequestIntervalSeconds)
        ClaudeOAuthUsageClient.fetchIfDue(minimumInterval: claudeFetchInterval) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .success(let snapshot):
                self.lastClaudeSnapshot = ClaudeUsageCore.merge(preferred: snapshot, fallback: self.lastClaudeSnapshot)
                self.recordClaudeConsumption()
                self.lastClaudeFetchFailureLabel = nil
                self.lastClaudeRateLimitRetryAt = nil
            case .skippedInFlight, .skippedThrottled:
                break
            case .rateLimited(let retryAt), .skippedRateLimitBackoff(let retryAt):
                self.lastClaudeFetchFailureLabel = nil
                self.lastClaudeRateLimitRetryAt = retryAt
                self.nextClaudeRefreshAt = retryAt
                self.updateNextAutoRefreshAt()
                self.scheduleNextAutoRefresh()
                if let diagnostic = outcome.diagnosticDescription {
                    self.appLog("claude usage fetch failed: \(diagnostic)")
                }
            case .noCredential, .keychainCredentialUnreadable, .httpFailure, .transportFailure, .decodeFailure:
                self.lastClaudeFetchFailureLabel = outcome.staleReasonLabel
                self.lastClaudeRateLimitRetryAt = nil
                if let diagnostic = outcome.diagnosticDescription {
                    self.appLog("claude usage fetch failed: \(diagnostic)")
                }
            }
            if let lastSnapshot = self.lastSnapshot {
                self.publishSharedUsage(lastSnapshot, origin: "cache-republish")
            }
            self.refreshStatusTitle()
            self.updateSplitPanel()
        }
    }

    /// Restores the last successful Gemini snapshot from CCMB's own shared
    /// file first (so a restart never shows "정보 없음" for data fetched
    /// minutes ago), then asks `agy` for a fresh read on the same throttled
    /// cadence Claude uses. Each call to `agy` spawns a subprocess, so this
    /// is deliberately more conservative than Claude's HTTP floor.
    private func refreshGeminiUsage() {
        if lastGeminiSnapshot == nil, let cached = SharedUsageStore.readGeminiSnapshot() {
            lastGeminiSnapshot = cached
            recordGeminiConsumption()
            refreshStatusTitle()
            updateSplitPanel()
        }

        let minimumInterval = max(geminiRefreshInterval, GeminiUsageCore.minimumRequestIntervalSeconds)
        GeminiUsageClient.fetchIfDue(minimumInterval: minimumInterval) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .success(let snapshot):
                self.lastGeminiSnapshot = snapshot
                self.recordGeminiConsumption()
                self.lastGeminiFetchFailureLabel = nil
            case .skippedInFlight, .skippedThrottled:
                break
            case .commandNotFound, .timedOut, .nonZeroExit, .decodeFailure:
                self.lastGeminiFetchFailureLabel = outcome.staleReasonLabel
                if let diagnostic = outcome.diagnosticDescription {
                    self.appLog("gemini usage fetch failed: \(diagnostic)")
                }
            }
            if let lastSnapshot = self.lastSnapshot {
                self.publishSharedUsage(lastSnapshot, origin: "cache-republish")
            }
            self.refreshStatusTitle()
            self.updateSplitPanel()
        }
    }

    /// Restores the last successful Grok snapshot from CCMB's own shared
    /// file first, then asks the billing endpoint for a fresh read on the
    /// same throttled cadence Gemini uses. Expired OAuth state is first handed
    /// to the official CLI for its own background token refresh.
    private func refreshGrokUsage(force: Bool = false, allowAuthRecovery: Bool = true) {
        if lastGrokSnapshot == nil, let cached = SharedUsageStore.readGrokSnapshot() {
            lastGrokSnapshot = cached
            recordGrokConsumption()
            refreshStatusTitle()
            updateSplitPanel()
        }

        let minimumInterval = max(grokRefreshInterval, GrokUsageCore.minimumRequestIntervalSeconds)
        GrokUsageClient.fetchIfDue(minimumInterval: minimumInterval, force: force) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .success(let snapshot):
                self.lastGrokSnapshot = snapshot
                self.recordGrokConsumption()
                self.lastGrokFetchFailureLabel = nil
                self.grokLoginRequired = false
            case .skippedInFlight, .skippedThrottled:
                break
            case .notSignedIn:
                self.grokLoginRequired = true
                self.lastGrokFetchFailureLabel = outcome.staleReasonLabel
            case .expiredCredential:
                if allowAuthRecovery, self.startAutomaticGrokAuthRecovery() { return }
                self.grokLoginRequired = true
                self.lastGrokFetchFailureLabel = outcome.staleReasonLabel
            case .httpFailure(let status) where status == 401 || status == 403:
                if allowAuthRecovery, self.startAutomaticGrokAuthRecovery() { return }
                self.grokLoginRequired = true
                self.lastGrokFetchFailureLabel = outcome.staleReasonLabel
            case .httpFailure, .transportFailure, .decodeFailure:
                self.lastGrokFetchFailureLabel = outcome.staleReasonLabel
            }
            if let diagnostic = outcome.diagnosticDescription {
                self.appLog("grok usage fetch failed: \(diagnostic)")
            }
            self.finishGrokRefreshUI()
        }
    }

    /// Uses the CLI's harmless model-list command to let its built-in OAuth
    /// refresher update `auth.json`, at most once per five minutes.
    private func startAutomaticGrokAuthRecovery() -> Bool {
        guard !grokAuthRecoveryInProgress,
              GrokAuthStore.readCredential()?.hasRefreshToken == true
        else { return false }
        if let lastGrokAuthRecoveryAttemptAt,
           Date().timeIntervalSince(lastGrokAuthRecoveryAttemptAt) < 300 {
            return false
        }

        grokAuthRecoveryInProgress = true
        lastGrokAuthRecoveryAttemptAt = Date()
        lastGrokFetchFailureLabel = nil
        updateSplitPanel()
        GrokAuthenticationClient.refreshCredential { [weak self] result in
            DispatchQueue.main.async { @MainActor in
                guard let self else { return }
                self.grokAuthRecoveryInProgress = false
                if case .success = result {
                    self.refreshGrokUsage(force: true, allowAuthRecovery: false)
                } else {
                    self.grokLoginRequired = true
                    self.lastGrokFetchFailureLabel = result.failureLabel.map {
                        "\($0) · 브라우저 로그인이 필요합니다"
                    } ?? "브라우저에서 Grok 로그인이 필요합니다"
                    self.finishGrokRefreshUI()
                }
            }
        }
        return true
    }

    private func finishGrokRefreshUI() {
        if let lastSnapshot {
            publishSharedUsage(lastSnapshot, origin: "cache-republish")
        }
        refreshStatusTitle()
        updateSplitPanel()
    }

    @objc private func performGrokUsageAction() {
        guard grokLoginRequired else {
            NSWorkspace.shared.open(UsageDashboardURLs.grok)
            return
        }
        guard !grokLoginInProgress, !grokAuthRecoveryInProgress else { return }

        grokLoginInProgress = true
        lastGrokFetchFailureLabel = nil
        updateSplitPanel()
        GrokAuthenticationClient.login { [weak self] result in
            DispatchQueue.main.async { @MainActor in
                guard let self else { return }
                self.grokLoginInProgress = false
                if case .success = result {
                    self.grokLoginRequired = false
                    self.lastGrokFetchFailureLabel = nil
                    self.lastGrokAuthRecoveryAttemptAt = nil
                    self.refreshGrokUsage(force: true, allowAuthRecovery: false)
                } else {
                    self.grokLoginRequired = true
                    self.lastGrokFetchFailureLabel = result.failureLabel.map {
                        "\($0) · 브라우저 로그인이 필요합니다"
                    } ?? "브라우저에서 Grok 로그인이 필요합니다"
                    self.finishGrokRefreshUI()
                }
            }
        }
    }

    // MARK: - Per-refresh consumption chart
    //
    // Everything below is plain data bookkeeping plus a view update. It runs on
    // the main thread but never blocks it: no waits, no process control, no
    // synchronous IPC. That matters because this code runs while the menu is
    // open, and a stalled main thread during menu tracking freezes keyboard
    // input for the whole system.

    /// The chart is its own full-width row just above the usage-page buttons,
    /// so it refreshes alongside the panel rather than as part of a column.
    private func updateHistoryChart() {
        let codexStrip = lastSnapshot.flatMap { codexHistoryStrip(from: $0) }
        let hasContent = historyChartView.apply(
            codex: codexStrip,
            claude: claudeHistoryStrip(),
            gemini: geminiHistoryStrip(),
            grok: grokHistoryStrip()
        )
        historyChartItem.isHidden = !hasContent
    }

    /// Codex bills against the weekly quota until it is exhausted and only then
    /// draws down credits, so "how much did that refresh cost" is a different
    /// number depending on which meter is live. The chart follows whichever one
    /// is actually being spent.
    private static func codexChartsCredits(_ snapshot: RateLimitSnapshot) -> Bool {
        guard let balance = snapshot.creditBalance, balance > 0 else { return false }
        guard let usedPercent = snapshot.usedPercent else { return true }
        return remainingUsagePercent(from: usedPercent) <= 0
    }

    private func recordCodexConsumption(from snapshot: RateLimitSnapshot) {
        let usesCredits = Self.codexChartsCredits(snapshot)
        codexConsumption.record(
            reading: usesCredits ? snapshot.creditBalance : snapshot.usedPercent,
            at: snapshot.updatedAt,
            isDecreasing: usesCredits,
            metricKey: usesCredits ? "codex.credit" : "codex.weekly"
        )
        persistConsumptionTrackers()
    }

    private func recordClaudeConsumption() {
        guard let snapshot = lastClaudeSnapshot, let publishedAt = snapshot.publishedAt else { return }
        // The 5-hour session meter is the one that visibly moves while working;
        // weekly is the fallback for accounts that only report it.
        let usesSession = snapshot.fiveHourUsedPercent != nil
        claudeConsumption.record(
            reading: usesSession ? snapshot.fiveHourUsedPercent : snapshot.weeklyUsedPercent,
            at: publishedAt,
            isDecreasing: false,
            metricKey: usesSession ? "claude.session" : "claude.weekly"
        )
        persistConsumptionTrackers()
    }

    private func codexHistoryStrip(from snapshot: RateLimitSnapshot) -> UsageHistoryStrip? {
        // No emptiness guard: the strip is always drawn at full width, with
        // not-yet-measured slots shown as faint placeholders.
        let samples = codexConsumption.samples
        let usesCredits = Self.codexChartsCredits(snapshot)
        let unit = usesCredits ? " 크레딧" : "%"
        let latest = samples.last?.amount ?? 0
        return UsageHistoryStrip(
            caption: "Codex · 갱신당 \(usesCredits ? "크레딧" : "주간") \(UsageConsumptionCore.amountTitle(latest, unit: usesCredits ? "" : "%"))",
            samples: samples,
            slotCount: UsageConsumptionTracker.defaultCapacity,
            unitSuffix: unit,
            color: UsageBrandColors.codex,
            accessibilityValue: "최근 \(samples.count)회 갱신 소비 기록, 마지막 갱신 \(UsageConsumptionCore.amountTitle(latest, unit: unit))"
        )
    }

    private func claudeHistoryStrip() -> UsageHistoryStrip? {
        let samples = claudeConsumption.samples
        let usesSession = lastClaudeSnapshot?.fiveHourUsedPercent != nil
        let latest = UsageConsumptionCore.amountTitle(samples.last?.amount ?? 0, unit: "%")
        return UsageHistoryStrip(
            caption: "Claude · 갱신당 \(usesSession ? "세션" : "주간") \(latest)",
            samples: samples,
            slotCount: UsageConsumptionTracker.defaultCapacity,
            unitSuffix: "%",
            color: UsageBrandColors.claude,
            accessibilityValue: "최근 \(samples.count)회 갱신 소비 기록, 마지막 갱신 \(latest)"
        )
    }

    /// Records Gemini's per-refresh consumption. Unlike Codex/Claude, `agy`
    /// only ever reports a *remaining* fraction — never a used percentage
    /// that counts up — so this always differences the remaining percent as
    /// a decreasing metric, the same way Codex's credit balance is tracked.
    private func recordGeminiConsumption() {
        guard let snapshot = lastGeminiSnapshot, let publishedAt = snapshot.publishedAt else { return }
        let usesFiveHour = snapshot.fiveHourRemainingFraction != nil
        let remainingPercent = GeminiUsageCore.remainingPercent(
            from: usesFiveHour ? snapshot.fiveHourRemainingFraction : snapshot.weeklyRemainingFraction
        )
        geminiConsumption.record(
            reading: remainingPercent,
            at: publishedAt,
            isDecreasing: true,
            metricKey: usesFiveHour ? "gemini.5h" : "gemini.weekly"
        )
        persistConsumptionTrackers()
    }

    private func geminiHistoryStrip() -> UsageHistoryStrip? {
        let samples = geminiConsumption.samples
        let usesFiveHour = lastGeminiSnapshot?.fiveHourRemainingFraction != nil
        let latest = UsageConsumptionCore.amountTitle(samples.last?.amount ?? 0, unit: "%")
        return UsageHistoryStrip(
            caption: "Gemini · 갱신당 \(usesFiveHour ? "세션" : "주간") \(latest)",
            samples: samples,
            slotCount: UsageConsumptionTracker.defaultCapacity,
            unitSuffix: "%",
            color: UsageBrandColors.geminiText,
            accessibilityValue: "최근 \(samples.count)회 갱신 소비 기록, 마지막 갱신 \(latest)"
        )
    }

    /// Records Grok's per-refresh consumption. The billing endpoint reports a
    /// *used* percentage that counts up (weekly, or the monthly fallback when
    /// no weekly figure is available), the same increasing-metric shape
    /// Claude's own weekly percentage uses.
    private func recordGrokConsumption() {
        guard let snapshot = lastGrokSnapshot, let publishedAt = snapshot.publishedAt else { return }
        let usesWeekly = snapshot.weeklyUsedPercent != nil
        grokConsumption.record(
            reading: usesWeekly ? snapshot.weeklyUsedPercent : snapshot.monthlyUsedPercent,
            at: publishedAt,
            isDecreasing: false,
            metricKey: usesWeekly ? "grok.weekly" : "grok.monthly"
        )
        persistConsumptionTrackers()
    }

    private func grokHistoryStrip() -> UsageHistoryStrip? {
        let samples = grokConsumption.samples
        let usesWeekly = lastGrokSnapshot?.weeklyUsedPercent != nil
        let latest = UsageConsumptionCore.amountTitle(samples.last?.amount ?? 0, unit: "%")
        return UsageHistoryStrip(
            caption: "Grok · 갱신당 \(usesWeekly ? "주간" : "월간") \(latest)",
            samples: samples,
            slotCount: UsageConsumptionTracker.defaultCapacity,
            unitSuffix: "%",
            color: GrokBrandColor.mark,
            accessibilityValue: "최근 \(samples.count)회 갱신 소비 기록, 마지막 갱신 \(latest)"
        )
    }

    private func loadConsumptionTrackers() {
        guard let data = UserDefaults.standard.data(forKey: Self.consumptionHistoryDefaultsKey),
              let store = try? JSONDecoder().decode(UsageConsumptionHistoryStore.self, from: data) else { return }
        codexConsumption = store.codex
        claudeConsumption = store.claude
        geminiConsumption = store.gemini
        grokConsumption = store.grok
    }

    private func persistConsumptionTrackers() {
        let store = UsageConsumptionHistoryStore(
            codex: codexConsumption,
            claude: claudeConsumption,
            gemini: geminiConsumption,
            grok: grokConsumption
        )
        guard let data = try? JSONEncoder().encode(store) else { return }
        UserDefaults.standard.set(data, forKey: Self.consumptionHistoryDefaultsKey)
    }

    private func refreshStatusTitle() {
        guard let snapshot = lastSnapshot else { return }
        setStatusTitle(Self.statusTitle(from: snapshot, claude: lastClaudeSnapshot, gemini: lastGeminiSnapshot))
        statusItem.button?.setAccessibilityValue(
            Self.accessibilityStatus(from: snapshot, claude: lastClaudeSnapshot, gemini: lastGeminiSnapshot)
        )
    }

    private func updateSplitPanel() {
        updateHistoryChart()
        usagePageLinksView.applyGrokAuthState(
            loginRequired: grokLoginRequired,
            loginInProgress: grokLoginInProgress || grokAuthRecoveryInProgress
        )
        guard let lastSnapshot else {
            splitPanelItem.isHidden = true
            return
        }

        let model = UsagePanelModel(
            codex: Self.codexColumn(from: lastSnapshot),
            claude: Self.claudeColumn(
                from: lastClaudeSnapshot,
                fetchFailureLabel: lastClaudeFetchFailureLabel,
                rateLimitRetryAt: lastClaudeRateLimitRetryAt
            ),
            gemini: Self.geminiColumn(
                from: lastGeminiSnapshot,
                fetchFailureLabel: lastGeminiFetchFailureLabel
            ),
            grok: Self.grokColumn(
                from: lastGrokSnapshot,
                fetchFailureLabel: lastGrokFetchFailureLabel
            )
        )
        splitPanelView.apply(model)
        updatePinnedUsageWindow(with: model)
        updateStatusDropdown(with: model)

        accountItem.isHidden = true
        usageItem.isHidden = true
        resetItem.isHidden = true
        resetCreditsItem.isHidden = true
        creditBalanceItem.isHidden = true
        updatedItem.isHidden = true
        usageSeparatorItem.isHidden = true
        accountSeparatorItem.isHidden = true
        splitPanelItem.isHidden = false
    }

    private static func codexColumn(from snapshot: RateLimitSnapshot) -> UsagePanelColumn {
        let accent = UsageBrandColors.codex
        var quota: UsagePanelQuota?
        var sparkQuota: UsagePanelQuota?
        var rows: [UsagePanelRow] = []

        if let planTitle = CodexPlanCore.title(for: snapshot.planType) {
            rows.append(UsagePanelRow(label: "요금제", value: planTitle))
        }

        if let usedPercent = snapshot.usedPercent {
            let remaining = remainingUsagePercent(from: usedPercent)
            if UsageCore.codexQuotaDisplaysCredits(
                usedPercent: snapshot.usedPercent,
                creditBalance: snapshot.creditBalance
            ), let creditBalance = snapshot.creditBalance {
                let creditTitle = creditDetailTitle(from: creditBalance)
                quota = UsagePanelQuota(
                    caption: "남은 크레딧",
                    percentText: creditTitle,
                    fraction: 0,
                    color: accent,
                    accessibilityValue: "남은 Codex 크레딧 \(creditTitle)",
                    displayStyle: .prominentValue
                )
            } else {
                quota = UsagePanelQuota(
                    caption: "주간 남음",
                    percentText: percentTitle(from: remaining),
                    fraction: remaining / 100,
                    color: accent,
                    accessibilityValue: "남은 Codex 주간 사용량 \(percentTitle(from: remaining))"
                )
            }
        } else {
            rows.append(UsagePanelRow(label: "주간 남음", value: "정보 없음", isEmphasized: true))
        }

        if let sparkUsedPercent = snapshot.sparkUsedPercent {
            let sparkRemaining = UsageCore.remainingPercent(from: sparkUsedPercent)
            sparkQuota = UsagePanelQuota(
                caption: "Spark 남음",
                percentText: percentTitle(from: sparkRemaining),
                fraction: sparkRemaining / 100,
                color: accent,
                accessibilityValue: "남은 Spark 주간 사용량 \(percentTitle(from: sparkRemaining))"
            )
        }

        if let resetCredits = snapshot.resetCredits {
            rows.append(UsagePanelRow(label: "초기화", value: "\(resetCredits)개"))
        }

        if let resetsAt = snapshot.resetsAt {
            rows.append(UsagePanelRow(
                label: "주간",
                value: resetDateTimeFormatter.string(from: resetsAt),
                isEmphasized: true
            ))
        } else if let minutes = snapshot.windowDurationMinutes {
            rows.append(UsagePanelRow(label: "주간", value: "\(minutes)분 창", isEmphasized: true))
        }

        if let sparkResetsAt = snapshot.sparkResetsAt {
            rows.append(UsagePanelRow(
                label: "Spark 주간",
                value: resetDateTimeFormatter.string(from: sparkResetsAt),
                isEmphasized: true
            ))
        } else if let minutes = snapshot.sparkWindowDurationMinutes {
            rows.append(UsagePanelRow(label: "Spark 주간", value: "\(minutes)분 창", isEmphasized: true))
        }

        if let creditBalance = snapshot.creditBalance {
            rows.append(UsagePanelRow(
                label: "크레딧",
                value: creditDetailTitle(from: creditBalance),
                isEmphasized: true
            ))
        } else {
            rows.append(UsagePanelRow(
                label: "크레딧",
                value: snapshot.detailedCreditsReturned ? "형식 확인 필요" : "정보 없음",
                isEmphasized: true
            ))
        }

        return UsagePanelColumn(
            title: "Codex",
            accentColor: accent,
            quota: quota,
            secondaryQuota: sparkQuota,
            rows: rows,
            accountLines: [snapshot.accountID.map { "계정 \($0)" } ?? "계정 정보 없음"],
            refreshLine: "업데이트 \(relativeFormatter.localizedString(for: snapshot.updatedAt, relativeTo: Date()))",
            statusLines: [],
            statusColor: .secondaryLabelColor
        )
    }

    private static func claudeColumn(
        from snapshot: ClaudeUsageSnapshot?,
        fetchFailureLabel: String?,
        rateLimitRetryAt: Date?
    ) -> UsagePanelColumn {
        let accent = UsageBrandColors.claude
        // A live countdown (rateLimitRetryAt) always takes priority over a
        // static label so it keeps ticking down across UI refreshes.
        let rateLimitLabel = rateLimitRetryAt.map { ClaudeUsageCore.rateLimitRetryLabel(retryAt: $0, now: Date()) }
        let failureLabel = rateLimitLabel
            ?? fetchFailureLabel

        guard let snapshot else {
            var statusLines: [String] = []
            if let rateLimitLabel {
                statusLines.append(rateLimitLabel)
            } else if let failureLabel {
                statusLines.append("갱신 실패: \(failureLabel)")
            }
            statusLines.append("터미널에서 Claude Code 실행 시 자동으로 채워집니다")
            return UsagePanelColumn(
                title: "Claude",
                accentColor: accent,
                quota: nil,
                secondaryQuota: nil,
                rows: [UsagePanelRow(label: "Claude", value: "정보 없음")],
                accountLines: ["계정 정보 없음"],
                refreshLine: nil,
                statusLines: statusLines,
                statusColor: rateLimitLabel != nil ? .systemOrange : (failureLabel == nil ? .secondaryLabelColor : .systemRed)
            )
        }

        var quota: UsagePanelQuota?
        var weeklyQuota: UsagePanelQuota?
        var fableQuota: UsagePanelQuota?
        var rows: [UsagePanelRow] = []
        let fableLimit = ClaudeUsageCore.fableWeeklyLimit(in: snapshot.modelWeeklyLimits)

        if let planTitle = ClaudePlanStore.readTitle() {
            rows.append(UsagePanelRow(label: "요금제", value: planTitle))
        }

        if let remaining = ClaudeUsageCore.remainingPercent(from: snapshot.fiveHourUsedPercent) {
            quota = UsagePanelQuota(
                caption: "세션 남음",
                percentText: percentTitle(from: remaining),
                fraction: remaining / 100,
                color: accent,
                accessibilityValue: "남은 Claude 세션 사용량 \(percentTitle(from: remaining))"
            )
        } else {
            rows.append(UsagePanelRow(label: "세션 남음", value: "정보 없음", isEmphasized: true))
        }

        if let resetsAt = snapshot.fiveHourResetsAt {
            rows.append(UsagePanelRow(
                label: "세션",
                value: resetDateTimeFormatter.string(from: resetsAt),
                isEmphasized: true
            ))
        }
        if let resetsAt = fableLimit?.resetsAt {
            rows.append(UsagePanelRow(
                label: "Fable",
                value: resetDateTimeFormatter.string(from: resetsAt)
            ))
        }
        if let remaining = ClaudeUsageCore.remainingPercent(from: snapshot.weeklyUsedPercent) {
            weeklyQuota = UsagePanelQuota(
                caption: "주간 남음",
                percentText: percentTitle(from: remaining),
                fraction: remaining / 100,
                color: accent,
                accessibilityValue: "남은 Claude 주간 사용량 \(percentTitle(from: remaining))"
            )
        }
        if let resetsAt = snapshot.weeklyResetsAt {
            rows.append(UsagePanelRow(
                label: "주간",
                value: resetDateTimeFormatter.string(from: resetsAt)
            ))
        }
        if let model = snapshot.model {
            rows.append(UsagePanelRow(label: "모델", value: model))
        }
        // The Fable weekly limit is promoted to its own top ring (session,
        // Fable, weekly), so it is excluded from the lower model-limit rows
        // that the rest of `modelWeeklyLimits` still populates.
        if let fableLimit, let remaining = ClaudeUsageCore.remainingPercent(from: fableLimit.usedPercent) {
            fableQuota = UsagePanelQuota(
                caption: "Fable 남음",
                percentText: percentTitle(from: remaining),
                fraction: remaining / 100,
                color: accent,
                accessibilityValue: "남은 Claude Fable 주간 사용량 \(percentTitle(from: remaining))"
            )
        }
        for limit in snapshot.modelWeeklyLimits {
            guard limit != fableLimit else { continue }
            guard let remaining = ClaudeUsageCore.remainingPercent(from: limit.usedPercent) else { continue }
            let detail = limit.resetsAt.map { resetDateTimeFormatter.string(from: $0) }
            rows.append(UsagePanelRow(
                label: "\(limit.modelName) 주간",
                value: "\(percentTitle(from: remaining)) 남음",
                detail: detail
            ))
        }
        if let extraUsage = snapshot.extraUsage {
            rows.append(UsagePanelRow(label: "추가 사용량", value: extraUsageTitle(extraUsage), valueColor: .systemPurple))
        }
        var accountLines: [String] = []
        if let account = snapshot.account {
            if let email = account.email {
                accountLines.append("계정 \(email)")
            }
        }
        if accountLines.isEmpty {
            accountLines.append("계정 정보 없음")
        }
        let refreshLine = snapshot.publishedAt.map {
            "업데이트 \(relativeFormatter.localizedString(for: $0, relativeTo: Date()))"
        }
        var statusLines: [String] = []
        if let rateLimitLabel {
            statusLines.append(rateLimitLabel)
        } else if let failureLabel {
            statusLines.append("갱신 실패: \(failureLabel)")
        }

        return UsagePanelColumn(
            title: "Claude",
            accentColor: accent,
            quota: quota,
            secondaryQuota: fableQuota ?? weeklyQuota,
            tertiaryQuota: fableQuota != nil ? weeklyQuota : nil,
            rows: rows,
            accountLines: accountLines,
            refreshLine: refreshLine,
            statusLines: statusLines,
            statusColor: rateLimitLabel != nil ? .systemOrange : (failureLabel == nil ? .secondaryLabelColor : .systemRed)
        )
    }

    /// Gemini's primary ring intentionally uses `primaryQuotaGradientColors`
    /// instead of a solid accent — the only column of the three with no
    /// single official brand color to fall back to.
    private static func geminiColumn(
        from snapshot: GeminiUsageSnapshot?,
        fetchFailureLabel: String?
    ) -> UsagePanelColumn {
        let accent = UsageBrandColors.geminiText

        guard let snapshot else {
            var statusLines: [String] = []
            if let fetchFailureLabel {
                statusLines.append("갱신 실패: \(fetchFailureLabel)")
            } else {
                statusLines.append("Antigravity CLI(agy) 설치와 로그인이 필요합니다")
            }
            return UsagePanelColumn(
                title: "Gemini",
                accentColor: accent,
                quota: nil,
                secondaryQuota: nil,
                rows: [UsagePanelRow(label: "Gemini", value: "정보 없음")],
                accountLines: ["계정 정보 없음"],
                refreshLine: nil,
                statusLines: statusLines,
                statusColor: fetchFailureLabel == nil ? .secondaryLabelColor : .systemRed
            )
        }

        var quota: UsagePanelQuota?
        var weeklyQuota: UsagePanelQuota?
        var rows: [UsagePanelRow] = []

        if let planTitle = snapshot.planTitle {
            rows.append(UsagePanelRow(label: "요금제", value: planTitle))
        }

        if let remaining = GeminiUsageCore.remainingPercent(from: snapshot.fiveHourRemainingFraction) {
            quota = UsagePanelQuota(
                caption: "세션 남음",
                percentText: percentTitle(from: remaining),
                fraction: remaining / 100,
                color: accent,
                accessibilityValue: "남은 Gemini 세션 사용량 \(percentTitle(from: remaining))"
            )
        } else {
            rows.append(UsagePanelRow(label: "세션 남음", value: "정보 없음", isEmphasized: true))
        }
        if let resetsAt = snapshot.fiveHourResetsAt {
            rows.append(UsagePanelRow(
                label: "세션",
                value: resetDateTimeFormatter.string(from: resetsAt),
                isEmphasized: true
            ))
        }
        if let remaining = GeminiUsageCore.remainingPercent(from: snapshot.weeklyRemainingFraction) {
            weeklyQuota = UsagePanelQuota(
                caption: "주간 남음",
                percentText: percentTitle(from: remaining),
                fraction: remaining / 100,
                color: accent,
                accessibilityValue: "남은 Gemini 주간 사용량 \(percentTitle(from: remaining))"
            )
        }
        if let resetsAt = snapshot.weeklyResetsAt {
            rows.append(UsagePanelRow(
                label: "주간",
                value: resetDateTimeFormatter.string(from: resetsAt)
            ))
        }
        if let creditBalance = snapshot.creditBalance {
            rows.append(UsagePanelRow(
                label: "크레딧",
                value: "\(creditBalance)",
                valueColor: creditBalance > 0 ? .systemGreen : .labelColor
            ))
        } else {
            rows.append(UsagePanelRow(label: "크레딧", value: "정보 없음"))
        }

        var statusLines: [String] = []
        if let fetchFailureLabel {
            statusLines.append("갱신 실패: \(fetchFailureLabel)")
        }

        let accountLines = [snapshot.accountEmail.map { "계정 \($0)" } ?? "계정 정보 없음"]

        return UsagePanelColumn(
            title: "Gemini",
            accentColor: accent,
            quota: quota,
            secondaryQuota: weeklyQuota,
            rows: rows,
            accountLines: accountLines,
            refreshLine: snapshot.publishedAt.map {
                "업데이트 \(relativeFormatter.localizedString(for: $0, relativeTo: Date()))"
            },
            statusLines: statusLines,
            statusColor: fetchFailureLabel == nil ? .secondaryLabelColor : .systemRed,
            primaryQuotaGradientColors: nil,
            secondaryQuotaGradientColors: nil
        )
    }

    /// Grok's weekly ring remains the primary quota. The compact detail list
    /// deliberately uses the same four labels the other provider columns use.
    private static func grokColumn(
        from snapshot: GrokUsageSnapshot?,
        fetchFailureLabel: String?
    ) -> UsagePanelColumn {
        let accent = GrokBrandColor.mark

        guard let snapshot else {
            var statusLines: [String] = []
            if let fetchFailureLabel {
                statusLines.append("갱신 실패: \(fetchFailureLabel)")
            } else {
                statusLines.append("사용량 정보를 불러오는 중…")
            }
            return UsagePanelColumn(
                title: "Grok",
                accentColor: accent,
                quota: UsagePanelQuota(
                    caption: "주간 남음",
                    percentText: "—",
                    fraction: 0,
                    color: accent,
                    accessibilityValue: "Grok 주간 사용량 정보 없음"
                ),
                secondaryQuota: nil,
                rows: [UsagePanelRow(label: "Grok", value: "정보 없음")],
                accountLines: ["계정 정보 없음"],
                refreshLine: nil,
                statusLines: statusLines,
                statusColor: fetchFailureLabel == nil ? .secondaryLabelColor : .systemRed
            )
        }

        var quota: UsagePanelQuota?
        var rows: [UsagePanelRow] = []

        if let estimate = snapshot.rollingTokenUsage {
            quota = UsagePanelQuota(
                caption: "24시간 추정 남음",
                percentText: percentTitle(from: estimate.remainingPercent),
                fraction: estimate.remainingPercent / 100,
                color: accent,
                accessibilityValue: "이 Mac 기록으로 추정한 남은 Grok 24시간 사용량 \(percentTitle(from: estimate.remainingPercent))"
            )
        } else if let remaining = GrokUsageCore.remainingPercent(from: snapshot.weeklyUsedPercent) {
            quota = UsagePanelQuota(
                caption: "주간 남음",
                percentText: percentTitle(from: remaining),
                fraction: remaining / 100,
                color: accent,
                accessibilityValue: "남은 Grok 주간 사용량 \(percentTitle(from: remaining))"
            )
        } else {
            quota = UsagePanelQuota(
                caption: "주간 남음",
                percentText: "—",
                fraction: 0,
                color: accent,
                accessibilityValue: "Grok 주간 사용량 정보 없음"
            )
        }
        rows.append(UsagePanelRow(label: "요금제", value: snapshot.subscriptionTier ?? "정보 없음"))
        if let estimate = snapshot.rollingTokenUsage {
            let used = NumberFormatter.localizedString(from: NSNumber(value: estimate.usedTokens), number: .decimal)
            let limit = NumberFormatter.localizedString(from: NSNumber(value: estimate.limitTokens), number: .decimal)
            rows.append(UsagePanelRow(label: "토큰 추정", value: "\(used) / \(limit)"))
            if let recoveryAt = estimate.recoveryAt {
                rows.append(UsagePanelRow(
                    label: "회복 예상",
                    value: resetDateTimeFormatter.string(from: recoveryAt),
                    isEmphasized: true
                ))
            }
        }
        rows.append(UsagePanelRow(
            label: "월간",
            value: snapshot.monthlyUsedCredits.map { "\(creditDetailTitle(from: $0)) 크레딧 사용" } ?? "정보 없음"
        ))
        rows.append(UsagePanelRow(
            label: "주간",
            value: snapshot.weeklyResetsAt.map(resetDateTimeFormatter.string(from:)) ?? "정보 없음",
            isEmphasized: true
        ))
        rows.append(UsagePanelRow(
            label: "크레딧",
            value: snapshot.extraCreditBalance.map { "\(creditDetailTitle(from: $0)) 크레딧" } ?? "정보 없음"
        ))

        var statusLines: [String] = []
        if snapshot.weeklyUsedPercent == nil, snapshot.rollingTokenUsage != nil {
            statusLines.append("추정 · 이 Mac의 최근 Grok 기록 기준")
        } else if snapshot.weeklyUsedPercent == nil {
            statusLines.append("주간 잔량: Grok에서 수치를 제공하지 않음")
        }
        if let fetchFailureLabel {
            statusLines.append("갱신 실패: \(fetchFailureLabel)")
        }

        let accountLines = [snapshot.accountEmail.map { "계정 \($0)" } ?? "계정 정보 없음"]

        return UsagePanelColumn(
            title: "Grok",
            accentColor: accent,
            quota: quota,
            secondaryQuota: nil,
            rows: rows,
            accountLines: accountLines,
            refreshLine: snapshot.publishedAt.map {
                "업데이트 \(relativeFormatter.localizedString(for: $0, relativeTo: Date()))"
            },
            statusLines: statusLines,
            statusColor: fetchFailureLabel == nil ? .secondaryLabelColor : .systemRed
        )
    }

    /// `extraUsage`'s `limitCents`/`usedCents` are cents-denominated
    /// regardless of which API field variant populated them.
    private static func extraUsageTitle(_ extraUsage: ClaudeExtraUsage) -> String {
        let currency = extraUsage.currency ?? "USD"
        func amount(_ cents: Double?) -> String? {
            guard let cents else { return nil }
            return String(format: "%.2f", cents / 100)
        }
        switch (amount(extraUsage.usedCents), amount(extraUsage.limitCents)) {
        case let (used?, limit?):
            return "\(used) / \(limit) \(currency)"
        case let (used?, nil):
            return "\(used) \(currency) 사용"
        case let (nil, limit?):
            return "한도 \(limit) \(currency)"
        default:
            return "정보 없음"
        }
    }

    private func configureShareMenu() {
        let shareTitleStyle = NSMutableParagraphStyle()
        shareTitleStyle.firstLineHeadIndent = 4
        shareTitleStyle.headIndent = 4
        shareItem.attributedTitle = NSAttributedString(
            string: "사용량 공유",
            attributes: [.paragraphStyle: shareTitleStyle]
        )
        shareItem.setAccessibilityLabel("사용량 공유")
        shareItem.submenu = makeShareMenu()
    }

    private func makeShareMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func copyItem(_ source: NSMenuItem) -> NSMenuItem {
            let item = NSMenuItem(title: source.title, action: source.action, keyEquivalent: source.keyEquivalent)
            item.target = source.action == nil ? nil : self
            item.isEnabled = source.action == nil ? false : source.isEnabled
            item.state = source.state
            item.toolTip = source.toolTip
            item.setAccessibilityLabel(source.accessibilityLabel())
            return item
        }
        let pathItem = NSMenuItem(title: "저장: ~/Library/Application Support/CCMB", action: nil, keyEquivalent: "")
        let fileItem = NSMenuItem(title: "파일: usage-v1.json", action: nil, keyEquivalent: "")
        let guideItem = NSMenuItem(title: "채팅에 “CCMB 사용량 알려줘” 입력", action: nil, keyEquivalent: "")
        pathItem.isEnabled = false
        fileItem.isEnabled = false
        guideItem.isEnabled = false

        menu.addItem(copyItem(shareStatusItem))
        menu.addItem(.separator())
        menu.addItem(pathItem)
        menu.addItem(fileItem)
        menu.addItem(copyItem(shareFolderItem))
        menu.addItem(.separator())
        menu.addItem(guideItem)
        menu.addItem(copyItem(copySharePromptCombinedItem))
        menu.addItem(.separator())
        menu.addItem(copyItem(copySharePromptCodexItem))
        menu.addItem(copyItem(copySharePromptClaudeItem))
        menu.addItem(copyItem(copySharePromptGeminiItem))
        menu.addItem(copyItem(copySharePromptGrokItem))
        menu.addItem(.separator())
        menu.addItem(copyItem(copyShareCommandItem))
        return menu
    }

    private func configureDiagnosticsMenu() {
        let menu = NSMenu()
        let pathItem = NSMenuItem(
            title: "저장: ~/Library/Application Support/CCMB/diagnostics",
            action: nil,
            keyEquivalent: ""
        )
        menu.addItem(pathItem)
        menu.addItem(.separator())
        menu.addItem(copyDiagnosticReportItem)
        menu.addItem(openDiagnosticLogItem)
        diagnosticsItem.submenu = menu
    }

    private func installUsageHelper() {
        do {
            try SharedUsageStore.installHelper()
            helperInstallError = nil
            copyShareCommandItem.isEnabled = true
            appLog("usage helper installed at \(SharedUsageStore.helperURL.path)")
        } catch {
            helperInstallError = error.localizedDescription
            copyShareCommandItem.isEnabled = false
            updateShareStatus()
            appLog("usage helper install failed: \(error.localizedDescription)")
        }
    }

    private func updateShareStatus() {
        if let helperInstallError {
            setDetailTitle("공유 명령 설치 실패", for: shareStatusItem)
            shareStatusItem.toolTip = helperInstallError
            return
        }
        if let lastShareError {
            setDetailTitle("공유 저장 실패", for: shareStatusItem)
            shareStatusItem.toolTip = lastShareError
            return
        }
        shareStatusItem.toolTip = nil

        if let feedback = shareFeedback {
            if Date() <= feedback.expiresAt {
                setDetailTitle(feedback.message, for: shareStatusItem)
                return
            }
            shareFeedback = nil
        }

        guard let lastSharedUsageAt else {
            setDetailTitle("공유 데이터 저장 대기 중…", for: shareStatusItem)
            return
        }

        let age = max(0, Int(Date().timeIntervalSince(lastSharedUsageAt)))
        let freshnessLimit = max(45, Int(refreshInterval) + 15)
        let state = age <= freshnessLimit ? "최신" : "오래됨"
        setDetailTitle("공유 상태 \(state) · \(Self.durationTitle(seconds: age)) 전", for: shareStatusItem)
    }

    @objc private func openSharedUsageFolder() {
        try? FileManager.default.createDirectory(at: SharedUsageStore.directoryURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(SharedUsageStore.directoryURL)
    }

    @objc private func copySharePromptCombined() {
        copySharePrompt(
            "~/.codex/bin/ccmb-usage를 실행해서 Codex·Claude·Gemini·Grok의 남은 주간 사용량과 Codex·Gemini 크레딧을 알려줘. 각각 fresh가 false면 오래된 데이터라고 말해줘.",
            label: "전체"
        )
    }

    @objc private func copySharePromptCodex() {
        copySharePrompt(
            "~/.codex/bin/ccmb-usage를 실행해서 codex 항목의 남은 주간 사용량과 크레딧을 알려줘. codex.fresh가 false면 오래된 데이터라고 말해줘.",
            label: "Codex"
        )
    }

    @objc private func copySharePromptClaude() {
        copySharePrompt(
            "~/.codex/bin/ccmb-usage를 실행해서 claude 항목의 남은 주간·5시간 사용량을 알려줘. claude.fresh가 false면 오래된 데이터라고 말해줘.",
            label: "Claude"
        )
    }

    @objc private func copySharePromptGemini() {
        copySharePrompt(
            "~/.codex/bin/ccmb-usage를 실행해서 gemini 항목의 남은 주간·5시간 사용량과 AI 크레딧을 알려줘. gemini.fresh가 false면 오래된 데이터라고 말해줘.",
            label: "Gemini"
        )
    }

    @objc private func copySharePromptGrok() {
        copySharePrompt(
            "~/.codex/bin/ccmb-usage를 실행해서 grok 항목의 남은 주간·월간 사용량을 알려줘. grok.fresh가 false면 오래된 데이터라고 말해줘.",
            label: "Grok"
        )
    }

    private func copySharePrompt(_ prompt: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
        shareFeedback = ("\(label) 요청문을 복사했습니다", Date().addingTimeInterval(3))
        updateShareStatus()
    }

    @objc private func copyShareCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(SharedUsageStore.helperURL.path, forType: .string)
        shareFeedback = ("공유 명령을 복사했습니다", Date().addingTimeInterval(3))
        updateShareStatus()
    }

    @objc private func copyLastError() {
        guard let lastErrorMessage else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastErrorMessage, forType: .string)
        setDetailTitle("오류 내용을 복사했습니다", for: updatedItem)
    }

    @objc private func copyDiagnosticReport() {
        let version = appVersion
        setDetailTitle("진단 리포트 준비 중…", for: copyDiagnosticReportItem)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let report = self.diagnosticLog.report(appVersion: version)
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(report, forType: .string)
                self.setDetailTitle("진단 리포트를 복사했습니다", for: self.copyDiagnosticReportItem)
            }
        }
    }

    @objc private func openDiagnosticLogFolder() {
        try? FileManager.default.createDirectory(at: diagnosticLog.directoryURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(diagnosticLog.directoryURL)
    }

    @objc private func refresh() {
        diagnosticLog.log("manual_refresh")
        guard !isOffline else {
            showOfflineStatus()
            return
        }

        restartAutoRefreshTimer()
        resetCountdown()
        setDetailTitle("Codex 사용량 새로고침 중...", for: usageItem)
        setDetailTitle("수동 가져오기 중...", for: updatedItem)
        statusItem.button?.setAccessibilityValue("사용량 새로 고침 중")
        client.refreshRateLimits()
        refreshClaudeUsage()
        refreshGeminiUsage()
        refreshGrokUsage()
    }

    @objc private func setCodexRefreshInterval(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? Int else { return }
        applyCodexRefreshInterval(seconds)
    }

    private func applyCodexRefreshInterval(_ seconds: Int) {
        refreshInterval = TimeInterval(seconds)
        UserDefaults.standard.set(seconds, forKey: Self.refreshIntervalDefaultsKey)
        if let lastSnapshot {
            do {
                try SharedUsageStore.publish(
                    lastSnapshot,
                    claudeSnapshot: lastClaudeSnapshot,
                    claudeRetryAt: lastClaudeRateLimitRetryAt,
                    claudeFailureLabel: lastClaudeFetchFailureLabel,
                    geminiSnapshot: lastGeminiSnapshot,
                    grokSnapshot: lastGrokSnapshot,
                    refreshInterval: refreshInterval
                )
                lastShareError = nil
            } catch {
                lastShareError = error.localizedDescription
            }
        }
        updateRefreshIntervalMenu()
        client.setAutoRefreshInterval(refreshInterval)
        restartAutoRefreshTimer()
        if refreshInterval > 0 {
            setDetailTitle("Codex 자동 갱신 · \(Self.durationTitle(seconds: seconds))", for: updatedItem)
            if isOffline {
                showOfflineStatus()
            } else {
                client.refreshRateLimits()
            }
        } else {
            setDetailTitle("Codex 자동 갱신 꺼짐", for: updatedItem)
        }
        updateSplitPanel()
    }

    @objc private func setClaudeRefreshInterval(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? Int else { return }
        applyClaudeRefreshInterval(seconds)
    }

    private func applyClaudeRefreshInterval(_ seconds: Int) {
        claudeRefreshInterval = TimeInterval(seconds)
        UserDefaults.standard.set(seconds, forKey: Self.claudeRefreshIntervalDefaultsKey)
        updateRefreshIntervalMenu()
        restartAutoRefreshTimer()
        setDetailTitle(
            seconds > 0 ? "Claude 자동 갱신 · \(Self.durationTitle(seconds: seconds))" : "Claude 자동 갱신 꺼짐",
            for: updatedItem
        )
        if seconds > 0, !isOffline {
            refreshClaudeUsage()
        }
        updateSplitPanel()
    }

    @objc private func setGeminiRefreshInterval(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? Int else { return }
        applyGeminiRefreshInterval(seconds)
    }

    private func applyGeminiRefreshInterval(_ seconds: Int) {
        geminiRefreshInterval = TimeInterval(seconds)
        UserDefaults.standard.set(seconds, forKey: Self.geminiRefreshIntervalDefaultsKey)
        updateRefreshIntervalMenu()
        restartAutoRefreshTimer()
        setDetailTitle(
            seconds > 0 ? "Gemini 자동 갱신 · \(Self.durationTitle(seconds: seconds))" : "Gemini 자동 갱신 꺼짐",
            for: updatedItem
        )
        if seconds > 0, !isOffline {
            refreshGeminiUsage()
        }
        updateSplitPanel()
    }

    @objc private func setGrokRefreshInterval(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? Int else { return }
        applyGrokRefreshInterval(seconds)
    }

    private func applyGrokRefreshInterval(_ seconds: Int) {
        grokRefreshInterval = TimeInterval(seconds)
        UserDefaults.standard.set(seconds, forKey: Self.grokRefreshIntervalDefaultsKey)
        updateRefreshIntervalMenu()
        restartAutoRefreshTimer()
        setDetailTitle(
            seconds > 0 ? "Grok 자동 갱신 · \(Self.durationTitle(seconds: seconds))" : "Grok 자동 갱신 꺼짐",
            for: updatedItem
        )
        if seconds > 0, !isOffline {
            refreshGrokUsage()
        }
        updateSplitPanel()
    }

    @objc private func togglePinnedUsageWindow() {
        if pinnedUsageWindowController?.isVisible == true {
            pinnedUsageWindowController?.close()
            return
        }
        UserDefaults.standard.set(true, forKey: Self.pinnedUsageWindowDefaultsKey)
        updatePinnedUsageWindowMenu()
        updateSplitPanel()
    }

    private func updatePinnedUsageWindow(with model: UsagePanelModel) {
        guard UserDefaults.standard.bool(forKey: Self.pinnedUsageWindowDefaultsKey) else { return }
        let controller: PinnedUsageWindowController
        if let existing = pinnedUsageWindowController {
            controller = existing
        } else {
            controller = PinnedUsageWindowController()
            controller.onClose = { [weak self] in
                UserDefaults.standard.set(false, forKey: Self.pinnedUsageWindowDefaultsKey)
                self?.updatePinnedUsageWindowMenu()
            }
            controller.onCodexRefreshIntervalChange = { [weak self] in self?.applyCodexRefreshInterval($0) }
            controller.onClaudeRefreshIntervalChange = { [weak self] in self?.applyClaudeRefreshInterval($0) }
            controller.onGeminiRefreshIntervalChange = { [weak self] in self?.applyGeminiRefreshInterval($0) }
            controller.onGrokRefreshIntervalChange = { [weak self] in self?.applyGrokRefreshInterval($0) }
            controller.onGrokUsageAction = { [weak self] in self?.performGrokUsageAction() }
            controller.onOpacityChange = { [weak self] in self?.changePinnedPanelOpacity($0) }
            controller.setShareMenu(makeShareMenu())
            controller.onCheckForUpdates = { [weak self] in self?.updaterController.checkForUpdates(nil) }
            controller.onOpenDiagnosticLog = { [weak self] in self?.openDiagnosticLogFolder() }
            controller.onOpenGitHub = { [weak self] in self?.openFooterLink() }
            controller.onToggleLaunchAtLogin = { [weak self] in self?.toggleLaunchAtLogin() }
            controller.onRestart = { [weak self] in self?.restartApp() }
            controller.onQuit = { [weak self] in self?.quit() }
            pinnedUsageWindowController = controller
            controller.setOpacity(panelOpacity)
        }
        controller.apply(
            model: model,
            codexHistory: lastSnapshot.flatMap { codexHistoryStrip(from: $0) },
            claudeHistory: claudeHistoryStrip(),
            geminiHistory: geminiHistoryStrip(),
            grokHistory: grokHistoryStrip(),
            codexRefreshInterval: Int(refreshInterval),
            claudeRefreshInterval: Int(claudeRefreshInterval),
            geminiRefreshInterval: Int(geminiRefreshInterval),
            grokRefreshInterval: Int(grokRefreshInterval)
        )
        controller.applyLowerControlsState(
            versionText: "현재 버전 \(appVersion)",
            launchAtLoginEnabled: isLaunchAtLoginEnabled,
            alwaysViewEnabled: UserDefaults.standard.bool(forKey: Self.pinnedUsageWindowDefaultsKey),
            grokLoginRequired: grokLoginRequired,
            grokLoginInProgress: grokLoginInProgress || grokAuthRecoveryInProgress
        )
        controller.setShareMenu(makeShareMenu())
        if !controller.isVisible {
            controller.show()
        }
        updatePinnedUsageWindowMenu()
    }

    /// Keeps the status-item's own transient dropdown current even while it
    /// isn't visible, so it never needs to rebuild `UsagePanelModel` itself
    /// when `showStatusMenu` opens it — the same reasoning `apply(...)`
    /// below already uses for the persistent pinned panel.
    private func updateStatusDropdown(with model: UsagePanelModel) {
        statusDropdownController.apply(
            model: model,
            codexHistory: lastSnapshot.flatMap { codexHistoryStrip(from: $0) },
            claudeHistory: claudeHistoryStrip(),
            geminiHistory: geminiHistoryStrip(),
            grokHistory: grokHistoryStrip(),
            codexRefreshInterval: Int(refreshInterval),
            claudeRefreshInterval: Int(claudeRefreshInterval),
            geminiRefreshInterval: Int(geminiRefreshInterval),
            grokRefreshInterval: Int(grokRefreshInterval)
        )
        statusDropdownController.applyLowerControlsState(
            versionText: "현재 버전 \(appVersion)",
            launchAtLoginEnabled: isLaunchAtLoginEnabled,
            alwaysViewEnabled: UserDefaults.standard.bool(forKey: Self.pinnedUsageWindowDefaultsKey),
            grokLoginRequired: grokLoginRequired,
            grokLoginInProgress: grokLoginInProgress || grokAuthRecoveryInProgress
        )
        statusDropdownController.setShareMenu(makeShareMenu())
    }

    private func updatePinnedUsageWindowMenu() {
        let enabled = UserDefaults.standard.bool(forKey: Self.pinnedUsageWindowDefaultsKey)
        pinnedUsageWindowItem.state = enabled ? .on : .off
        updateVersionView.alwaysViewButton.title = enabled ? "✓ 항상 보기" : "항상 보기"
        statusDropdownController.applyLowerControlsState(
            versionText: "현재 버전 \(appVersion)",
            launchAtLoginEnabled: isLaunchAtLoginEnabled,
            alwaysViewEnabled: enabled,
            grokLoginRequired: grokLoginRequired,
            grokLoginInProgress: grokLoginInProgress || grokAuthRecoveryInProgress
        )
    }

    /// Applies one shared value to the status dropdown and the pinned panel
    /// so their whole-panel background materials fade together while all
    /// text, charts, and buttons stay fully opaque.
    private func applyPanelOpacity() {
        statusDropdownController.setOpacity(panelOpacity)
        pinnedUsageWindowController?.setOpacity(panelOpacity)
        updateVersionView.setOpacity(panelOpacity)
    }

    @objc private func changePanelOpacity(_ sender: NSSlider) {
        setPanelOpacity(sender.doubleValue)
    }

    /// Same opacity change the status menu's own slider performs, invoked
    /// from the pinned panel's mirrored slider via a callback rather than
    /// duplicating the persistence/apply logic there.
    private func changePinnedPanelOpacity(_ opacity: Double) {
        setPanelOpacity(opacity)
    }

    private func setPanelOpacity(_ opacity: Double) {
        panelOpacity = UsageCore.normalizedPanelOpacity(opacity)
        UserDefaults.standard.set(panelOpacity, forKey: Self.panelOpacityDefaultsKey)
        applyPanelOpacity()
    }

    @objc private func openDashboard() {
        NSWorkspace.shared.open(UsageDashboardURLs.codex)
    }

    @objc private func openClaudeDashboard() {
        NSWorkspace.shared.open(UsageDashboardURLs.claude)
    }

    @objc private func openGeminiDashboard() {
        NSWorkspace.shared.open(UsageDashboardURLs.gemini)
    }

    @objc private func openFooterLink() {
        guard let url = URL(string: Self.footerLinkURLString) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func toggleLaunchAtLogin() {
        if isLaunchAtLoginEnabled {
            try? FileManager.default.removeItem(at: Self.launchAgentURL)
        } else {
            do {
                try installLaunchAgent()
            } catch {
                setDetailTitle("자동 시작 설정 실패", for: updatedItem)
            }
        }

        updateLaunchAtLoginMenu()
    }

    private var isLaunchAtLoginEnabled: Bool {
        FileManager.default.fileExists(atPath: Self.launchAgentURL.path)
    }

    private func updateLaunchAtLoginMenu() {
        let enabled = isLaunchAtLoginEnabled
        launchAtLoginItem.state = enabled ? .on : .off
        lifecycleActionsView.launchButton.title = enabled ? "✓ 자동 실행" : "자동 실행"
        setDetailTitle(launchAtLoginItem.title, for: launchAtLoginItem)
        pinnedUsageWindowController?.applyLowerControlsState(
            versionText: "현재 버전 \(appVersion)",
            launchAtLoginEnabled: enabled,
            alwaysViewEnabled: UserDefaults.standard.bool(forKey: Self.pinnedUsageWindowDefaultsKey),
            grokLoginRequired: grokLoginRequired,
            grokLoginInProgress: grokLoginInProgress || grokAuthRecoveryInProgress
        )
        statusDropdownController.applyLowerControlsState(
            versionText: "현재 버전 \(appVersion)",
            launchAtLoginEnabled: enabled,
            alwaysViewEnabled: UserDefaults.standard.bool(forKey: Self.pinnedUsageWindowDefaultsKey),
            grokLoginRequired: grokLoginRequired,
            grokLoginInProgress: grokLoginInProgress || grokAuthRecoveryInProgress
        )
    }

    private func refreshLaunchAgentPathIfNeeded() {
        guard isLaunchAtLoginEnabled else { return }
        do {
            try installLaunchAgent()
        } catch {
            setDetailTitle("자동 시작 경로 갱신 실패", for: updatedItem)
        }
    }

    private func installLaunchAgent() throws {
        try FileManager.default.createDirectory(
            at: Self.launchAgentURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let plist: [String: Any] = [
            "Label": Self.launchAgentLabel,
            "ProgramArguments": [
                "/usr/bin/open",
                Bundle.main.bundlePath
            ],
            "RunAtLoad": true,
            "KeepAlive": false,
            "LimitLoadToSessionType": "Aqua",
            "StandardOutPath": "/tmp/CCMB.launchd.out.log",
            "StandardErrorPath": "/tmp/CCMB.launchd.err.log"
        ]

        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: Self.launchAgentURL, options: .atomic)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func setStatusTitle(_ title: String) {
        guard let button = statusItem.button else { return }
        button.title = title

        let font = button.font ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        let titleWidth = (title as NSString).size(withAttributes: [.font: font]).width
        let iconWidth = button.image?.size.width ?? 0
        statusItem.length = ceil(iconWidth + titleWidth + 8)
    }

    private static let percentFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    private static func creditDetailTitle(from balance: Double) -> String {
        UsageCore.creditDetailTitle(from: balance)
    }

    private static func statusTitle(
        from snapshot: RateLimitSnapshot,
        claude: ClaudeUsageSnapshot?,
        gemini: GeminiUsageSnapshot?
    ) -> String {
        var parts: [String] = []

        if let codexTitle = UsageCore.menuBarCodexTitle(
            usedPercent: snapshot.usedPercent,
            creditBalance: snapshot.creditBalance
        ) {
            parts.append(codexTitle)
        }

        if let claudeRemaining = ClaudeUsageCore.remainingPercent(from: claude?.fiveHourUsedPercent) {
            parts.append(percentTitle(from: claudeRemaining))
        }

        if let geminiRemaining = GeminiUsageCore.remainingPercent(from: gemini?.fiveHourRemainingFraction) {
            parts.append(percentTitle(from: geminiRemaining))
        }

        return parts.isEmpty ? "—" : parts.joined(separator: "·")
    }

    private static func remainingUsagePercent(from usedPercent: Double) -> Double {
        UsageCore.remainingPercent(from: usedPercent)
    }

    private static func accessibilityStatus(
        from snapshot: RateLimitSnapshot,
        claude: ClaudeUsageSnapshot?,
        gemini: GeminiUsageSnapshot?
    ) -> String {
        var parts: [String] = []
        if let usedPercent = snapshot.usedPercent {
            parts.append("남은 Codex 주간 사용량 \(percentTitle(from: remainingUsagePercent(from: usedPercent)))")
        }
        if let claudeRemaining = ClaudeUsageCore.remainingPercent(from: claude?.fiveHourUsedPercent) {
            parts.append("남은 Claude 세션 \(percentTitle(from: claudeRemaining))")
        }
        if let geminiRemaining = GeminiUsageCore.remainingPercent(from: gemini?.fiveHourRemainingFraction) {
            parts.append("남은 Gemini 5시간 사용량 \(percentTitle(from: geminiRemaining))")
        }
        return parts.isEmpty ? "사용량 정보 없음" : parts.joined(separator: ", ")
    }

    private static func percentTitle(from percent: Double) -> String {
        percentFormatter.string(from: NSNumber(value: percent / 100)) ?? "\(Int(percent.rounded()))%"
    }

    private static func durationTitle(seconds: Int) -> String {
        if seconds >= 3_600 {
            let hours = seconds / 3_600
            let minutes = (seconds % 3_600) / 60
            return minutes == 0 ? "\(hours)시간" : "\(hours)시간 \(minutes)분"
        }
        if seconds >= 60 {
            let minutes = seconds / 60
            let remainder = seconds % 60
            return remainder == 0 ? "\(minutes)분" : "\(minutes)분 \(remainder)초"
        }

        return "\(seconds)초"
    }

    private static func intervalTitle(_ interval: TimeInterval) -> String {
        interval > 0 ? durationTitle(seconds: Int(interval)) : "끔"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    private static let resetDateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "M/d(EEEEE) HH:mm"
        return formatter
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.unitsStyle = .full
        return formatter
    }()

    private static let launchAgentLabel = "com.codex.creditmenubar"
    private static let refreshIntervalDefaultsKey = "codexAutomaticRefreshIntervalSeconds"
    private static let claudeRefreshIntervalDefaultsKey = "claudeAutomaticRefreshIntervalSeconds"
    private static let geminiRefreshIntervalDefaultsKey = "geminiAutomaticRefreshIntervalSeconds"
    private static let grokRefreshIntervalDefaultsKey = "grokAutomaticRefreshIntervalSeconds"
    private static let pinnedUsageWindowDefaultsKey = "pinnedUsageWindowEnabled"
    private static let consumptionHistoryDefaultsKey = "usageConsumptionHistoryV1"
    private static let panelOpacityDefaultsKey = "usagePanelOpacity"
    private static let footerLinkURLString = "https://github.com/armsone"

    private static func savedPanelOpacity() -> Double {
        guard UserDefaults.standard.object(forKey: panelOpacityDefaultsKey) != nil else { return 1.0 }
        let saved = UserDefaults.standard.double(forKey: panelOpacityDefaultsKey)
        return UsageCore.normalizedPanelOpacity(saved)
    }

    private static func savedRefreshInterval() -> TimeInterval {
        let saved = UserDefaults.standard.object(forKey: refreshIntervalDefaultsKey) == nil
            ? nil
            : UserDefaults.standard.integer(forKey: refreshIntervalDefaultsKey)
        return UsageCore.normalizedRefreshInterval(saved)
    }

    private static func savedClaudeRefreshInterval() -> TimeInterval {
        let saved = UserDefaults.standard.object(forKey: claudeRefreshIntervalDefaultsKey) == nil
            ? nil
            : UserDefaults.standard.integer(forKey: claudeRefreshIntervalDefaultsKey)
        return UsageCore.normalizedClaudeRefreshInterval(saved)
    }

    private static func savedGeminiRefreshInterval() -> TimeInterval {
        let saved = UserDefaults.standard.object(forKey: geminiRefreshIntervalDefaultsKey) == nil
            ? nil
            : UserDefaults.standard.integer(forKey: geminiRefreshIntervalDefaultsKey)
        return UsageCore.normalizedGeminiRefreshInterval(saved)
    }

    private static func savedGrokRefreshInterval() -> TimeInterval {
        let saved = UserDefaults.standard.object(forKey: grokRefreshIntervalDefaultsKey) == nil
            ? nil
            : UserDefaults.standard.integer(forKey: grokRefreshIntervalDefaultsKey)
        return UsageCore.normalizedGrokRefreshInterval(saved)
    }

    private static let launchAgentURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("LaunchAgents")
            .appendingPathComponent("\(launchAgentLabel).plist")
    }()

    private func appLog(_ message: String) {
        Self.appLog(message)
    }

    private static func appLog(_ message: String) {
        writePrivateLog("app \(message)")
    }
}

@MainActor
private enum AppRuntime {
    static let app = NSApplication.shared
    static let delegate = AppDelegate()
}

if !UsageCommand.runIfRequested() {
    MainActor.assumeIsolated {
        AppRuntime.app.delegate = AppRuntime.delegate
        AppRuntime.app.run()
    }
}
