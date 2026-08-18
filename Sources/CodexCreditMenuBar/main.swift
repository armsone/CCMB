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
        refreshInterval: TimeInterval
    ) throws {
        let remainingPercent = snapshot.usedPercent.map(UsageCore.remainingPercent)
        let freshForSeconds = max(45, Int(refreshInterval) + 15)
        let sequence = Int64((snapshot.updatedAt.timeIntervalSince1970 * 1_000).rounded())

        let payload: [String: Any] = [
            "schemaVersion": 1,
            "status": "ok",
            "source": "codex app-server",
            "method": "account/rateLimits/read",
            "weeklyRemainingPercent": remainingPercent ?? NSNull(),
            "creditBalance": snapshot.creditBalance ?? NSNull(),
            "usedPercent": snapshot.usedPercent ?? NSNull(),
            "windowDurationMins": snapshot.windowDurationMinutes ?? NSNull(),
            "resetsAt": snapshot.resetsAt.map(iso8601Formatter.string(from:)) ?? NSNull(),
            "fetchedAt": iso8601Formatter.string(from: snapshot.updatedAt),
            "publishedAt": iso8601Formatter.string(from: Date()),
            "sequence": sequence,
            "refreshIntervalSeconds": Int(refreshInterval),
            "freshForSeconds": freshForSeconds,
            "ccmbProcessID": ProcessInfo.processInfo.processIdentifier,
            "ccmbBundleIdentifier": Bundle.main.bundleIdentifier ?? "",
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
            "claude": ClaudeUsageCore.sharedPayload(from: claudeSnapshot),
            "codex": UsageCore.codexPayload(from: snapshot, freshForSeconds: freshForSeconds)
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
        var output: [String: Any] = [
            "weeklyRemainingPercent": payload["weeklyRemainingPercent"] ?? NSNull(),
            "creditBalance": payload["creditBalance"] ?? NSNull(),
            "usedPercent": payload["usedPercent"] ?? NSNull(),
            "windowDurationMins": payload["windowDurationMins"] ?? NSNull(),
            "resetsAt": payload["resetsAt"] ?? NSNull(),
            "origin": "ccmb-cache",
            "fetchedAt": payload["fetchedAt"] ?? NSNull(),
            "claude": ClaudeUsageCore.refreshedSharedPayload(storedClaude),
            "codex": UsageCore.refreshedCodexPayload(storedCodex)
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
            "creditBalance": snapshot.creditBalance ?? NSNull(),
            "usedPercent": usedPercent,
            "windowDurationMins": snapshot.windowDurationMinutes ?? NSNull(),
            "resetsAt": snapshot.resetsAt.map(iso8601Formatter.string(from:)) ?? NSNull(),
            "origin": "direct-app-server",
            "fetchedAt": fetchedAt,
            "ageSeconds": 0,
            "freshForSeconds": 15,
            "fresh": true,
            "claude": ClaudeUsageCore.sharedPayload(from: ClaudeUsageStore.read()),
            "codex": UsageCore.codexPayload(from: snapshot, freshForSeconds: 15, now: snapshot.updatedAt),
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
    private var isRefreshing = false
    private var refreshStartedAt: Date?
    private var refreshGeneration = 0
    private var currentCommandDescription: String?
    private var processFailureReported = false

    var onRateLimitsUpdated: ((RateLimitSnapshot) -> Void)?
    var onError: ((String) -> Void)?
    var onRestartRequired: ((String) -> Void)?

    init(callbackQueue: DispatchQueue? = .main) {
        self.callbackQueue = callbackQueue
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
                return
            }
            if self.isRefreshing {
                let elapsed = abs(self.refreshStartedAt?.timeIntervalSinceNow ?? 0)
                guard elapsed > 15 else {
                    self.log("refresh skipped: already in progress")
                    return
                }

                self.log("refresh stale after \(Int(elapsed))s; restarting app-server")
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
            initialize()
        } catch {
            let message = "Codex app-server 시작 실패 (실행 \(command.description)): \(error.localizedDescription)"
            log("launch failed \(message)")
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
                    "title": "Codex & Claude Meter Bar",
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
        sendRequest(method: "account/rateLimits/read", params: [:]) { result in
            defer {
                self.isRefreshing = false
                self.refreshStartedAt = nil
                self.log("refresh end")
            }

            switch result {
            case .success(let value):
                guard let object = value as? [String: Any] else {
                    self.emitError("Codex 사용량 응답을 읽지 못했습니다.")
                    return
                }
                self.onRateLimitsUpdated?(Self.parseRateLimits(object, accountID: self.accountID))
            case .failure(let error):
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

    private static func parseRateLimits(_ object: [String: Any], accountID: String?) -> RateLimitSnapshot {
        let rateLimits = object["rateLimits"] as? [String: Any]
        let primary = rateLimits?["primary"] as? [String: Any]

        let resetCredits = object.value(at: ["rateLimitResetCredits", "availableCount"]).flatMap(numberAsInt)
        let resetsAt = primary?["resetsAt"].flatMap(numberAsDouble).map {
            Date(timeIntervalSince1970: $0)
        }

        return RateLimitSnapshot(
            accountID: accountID,
            usedPercent: primary?["usedPercent"].flatMap(numberAsDouble),
            windowDurationMinutes: primary?["windowDurationMins"].flatMap(numberAsInt),
            resetsAt: resetsAt,
            resetCredits: resetCredits,
            creditBalance: object.value(at: ["rateLimits", "credits", "balance"]).flatMap(numberAsDouble),
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
    private let client = CodexAppServerClient()
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
    private var nextAutoRefreshAt = Date()
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
    private let refreshOffItem = NSMenuItem(title: "끔", action: #selector(setRefreshInterval(_:)), keyEquivalent: "")
    private let refresh30Item = NSMenuItem(title: "30초", action: #selector(setRefreshInterval(_:)), keyEquivalent: "")
    private let refresh60Item = NSMenuItem(title: "1분", action: #selector(setRefreshInterval(_:)), keyEquivalent: "")
    private let refresh300Item = NSMenuItem(title: "5분", action: #selector(setRefreshInterval(_:)), keyEquivalent: "")
    private let launchAtLoginItem = NSMenuItem(title: "로그인 시 자동 실행", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private let shareItem = NSMenuItem(title: "사용량 공유", action: nil, keyEquivalent: "")
    private let shareStatusItem = NSMenuItem(title: "공유 데이터 저장 대기 중…", action: nil, keyEquivalent: "")
    private let shareFolderItem = NSMenuItem(title: "저장 위치 열기", action: #selector(openSharedUsageFolder), keyEquivalent: "")
    private let copySharePromptCombinedItem = NSMenuItem(
        title: "전체(Codex+Claude) 요청문 복사",
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
    private let copyShareCommandItem = NSMenuItem(title: "공유 명령 복사", action: #selector(copyShareCommand), keyEquivalent: "")
    private let copyErrorItem = NSMenuItem(title: "오류 내용 복사", action: #selector(copyLastError), keyEquivalent: "")
    private let usagePageLinksView = UsagePageButtonsView()
    private let usagePageLinksItem = NSMenuItem()
    private let checkForUpdatesItem = NSMenuItem(
        title: "업데이트 확인…",
        action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
        keyEquivalent: ""
    )
    private let restartItem = NSMenuItem(title: "CCMB 다시 시작", action: #selector(restartApp), keyEquivalent: "")
    private let footerLinkItem = NSMenuItem(title: "GitHub에서 armsone 보기…", action: #selector(openFooterLink), keyEquivalent: "")
    private let quitItem = NSMenuItem(title: "CCMB 종료", action: #selector(quit), keyEquivalent: "q")
    private let splitPanelView = SplitUsagePanelView()
    private let splitPanelItem = NSMenuItem()
    private let usageSeparatorItem = NSMenuItem.separator()
    private let accountSeparatorItem = NSMenuItem.separator()
    private var lastRateLimitUpdatedAt: Date?
    private var lastSnapshot: RateLimitSnapshot?
    private var lastClaudeSnapshot: ClaudeUsageSnapshot?
    private var lastClaudeFetchFailureLabel: String?
    /// Set only while a 429 backoff is active; drives a live "N초 후 재시도"
    /// countdown in the panel instead of a static label frozen at fetch time.
    private var lastClaudeRateLimitRetryAt: Date?
    private var lastSharedUsageAt: Date?
    private var lastShareError: String?
    private var helperInstallError: String?
    private var shareFeedback: (message: String, expiresAt: Date)?
    private var lastErrorMessage: String?
    private var wakeRecoveryToken = 0
    private let wakeRestartDelay: TimeInterval = 14
    private var isOffline = false
    deinit {
        writePrivateLog("app delegate deinit")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        appLog("delegate did finish launching")
        NSApp.setActivationPolicy(.accessory)
        guard acquireSingleInstanceLock() else {
            NSApp.terminate(nil)
            return
        }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Keep Codex and Claude usage auto-refresh running"
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWakeFromSleep),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
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
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshClaudeUsage()
    }

    func applicationWillTerminate(_ notification: Notification) {
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
            self.restartApp()
        }
    }

    @objc private func restartApp() {
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

        guard refreshInterval > 0 else {
            appLog("auto refresh timer off")
            nextAutoRefreshAt = Date()
            updateCountdown()
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + refreshInterval,
            repeating: refreshInterval,
            leeway: .milliseconds(250)
        )
        timer.setEventHandler { [weak self] in
            self?.performAutoRefresh()
        }
        autoRefreshTimer = timer
        nextAutoRefreshAt = Date().addingTimeInterval(refreshInterval)
        timer.resume()
        appLog("auto refresh timer start \(Int(refreshInterval))s")
        updateCountdown()
    }

    private func stopAutoRefreshLoop() {
        autoRefreshTimer?.cancel()
        autoRefreshTimer = nil
        appLog("auto refresh timer stop")
    }

    private func performAutoRefresh() {
        appLog("auto refresh perform")
        nextAutoRefreshAt = Date().addingTimeInterval(refreshInterval)
        guard !isOffline else {
            showOfflineStatus()
            return
        }

        setDetailTitle("자동 갱신 중...", for: usageItem)
        setDetailTitle("자동 가져오기 중...", for: updatedItem)
        statusItem.button?.setAccessibilityValue("사용량 업데이트 중")
        updateCountdown()
        client.refreshRateLimits()
        refreshClaudeUsage()
    }

    private func resetCountdown() {
        guard refreshInterval > 0 else {
            updateCountdown()
            return
        }
        nextAutoRefreshAt = Date().addingTimeInterval(refreshInterval)
        updateCountdown()
    }

    private func updateCountdown() {
        updateShareStatus()
        guard refreshInterval > 0 else {
            setDetailTitle("새로 고침", for: refreshItem)
            return
        }

        let seconds = max(0, Int(ceil(nextAutoRefreshAt.timeIntervalSinceNow)))
        setDetailTitle("새로 고침 · \(Self.durationTitle(seconds: seconds)) 후", for: refreshItem)
    }

    private func updateRefreshIntervalMenu() {
        refreshOffItem.state = refreshInterval == 0 ? .on : .off
        refresh30Item.state = refreshInterval == 30 ? .on : .off
        refresh60Item.state = refreshInterval == 60 ? .on : .off
        refresh300Item.state = refreshInterval == 300 ? .on : .off
        setDetailTitle(refreshOffItem.title, for: refreshOffItem)
        setDetailTitle(refresh30Item.title, for: refresh30Item)
        setDetailTitle(refresh60Item.title, for: refresh60Item)
        setDetailTitle(refresh300Item.title, for: refresh300Item)
        if refreshInterval > 0 {
            setDetailTitle("자동 새로 고침 · \(Self.durationTitle(seconds: Int(refreshInterval)))", for: intervalItem)
        } else {
            setDetailTitle("자동 새로 고침 · 끔", for: intervalItem)
        }
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
        statusItem.button?.toolTip = "Codex 남은 사용량과 크레딧"
        statusItem.button?.imageHugsTitle = true
        statusItem.button?.setAccessibilityLabel("Codex 사용량")

        if #available(macOS 11.0, *) {
            if let image = NSImage(systemSymbolName: "bolt.circle", accessibilityDescription: "Codex") {
                image.isTemplate = true
                statusItem.button?.image = image
                statusItem.button?.imagePosition = .imageLeading
            }
        }
        setStatusTitle("…")
        statusItem.button?.setAccessibilityValue("사용량 확인 중")

        let menu = NSMenu()
        menu.autoenablesItems = false
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

        menu.addItem(usageItem)
        menu.addItem(creditBalanceItem)
        menu.addItem(resetCreditsItem)
        menu.addItem(resetItem)
        menu.addItem(usageSeparatorItem)
        menu.addItem(updatedItem)
        copyErrorItem.isHidden = true
        menu.addItem(copyErrorItem)
        usagePageLinksView.codexButton.target = self
        usagePageLinksView.codexButton.action = #selector(openDashboard)
        usagePageLinksView.claudeButton.target = self
        usagePageLinksView.claudeButton.action = #selector(openClaudeDashboard)
        usagePageLinksItem.view = usagePageLinksView
        usagePageLinksItem.isEnabled = true
        menu.addItem(usagePageLinksItem)
        menu.addItem(refreshItem)

        let intervalMenu = NSMenu()
        refreshOffItem.representedObject = 0
        refresh30Item.representedObject = 30
        refresh60Item.representedObject = 60
        refresh300Item.representedObject = 300
        intervalMenu.addItem(refreshOffItem)
        intervalMenu.addItem(refresh30Item)
        intervalMenu.addItem(refresh60Item)
        intervalMenu.addItem(refresh300Item)

        intervalItem.submenu = intervalMenu
        menu.addItem(intervalItem)
        menu.addItem(accountItem)
        menu.addItem(accountSeparatorItem)
        configureShareMenu()
        menu.addItem(shareItem)
        menu.addItem(.separator())
        menu.addItem(launchAtLoginItem)
        menu.addItem(.separator())
        menu.addItem(checkForUpdatesItem)
        menu.addItem(restartItem)
        menu.addItem(footerLinkItem)
        menu.addItem(quitItem)

        for item in menu.items {
            item.target = self
        }
        checkForUpdatesItem.target = updaterController
        refreshItem.target = self
        refreshOffItem.target = self
        refresh30Item.target = self
        refresh60Item.target = self
        refresh300Item.target = self
        launchAtLoginItem.target = self
        shareFolderItem.target = self
        copySharePromptCombinedItem.target = self
        copySharePromptCodexItem.target = self
        copySharePromptClaudeItem.target = self
        copyShareCommandItem.target = self
        copyErrorItem.target = self
        restartItem.target = self
        footerLinkItem.target = self
        quitItem.target = self
        updateRefreshIntervalMenu()
        updateLaunchAtLoginMenu()
        prepareNativeMenu(menu)

        menu.delegate = self
        statusItem.menu = menu
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
                self.restartApp()
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
                    self.showOfflineStatus()
                } else if wasOffline {
                    self.appLog("network online")
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
        publishSharedUsage(snapshot)
        updateSplitPanel()
    }

    private func publishSharedUsage(_ snapshot: RateLimitSnapshot) {
        do {
            try SharedUsageStore.publish(
                snapshot,
                claudeSnapshot: lastClaudeSnapshot,
                refreshInterval: refreshInterval
            )
            lastSharedUsageAt = snapshot.updatedAt
            lastShareError = nil
            updateShareStatus()
        } catch {
            lastShareError = error.localizedDescription
            updateShareStatus()
            appLog("shared usage publish failed: \(error.localizedDescription)")
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
        if let lastSnapshot {
            publishSharedUsage(lastSnapshot)
        }
        refreshStatusTitle()
        updateSplitPanel()

        let claudeFetchInterval = max(refreshInterval, ClaudeUsageCore.minimumRequestIntervalSeconds)
        ClaudeOAuthUsageClient.fetchIfDue(minimumInterval: claudeFetchInterval) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .success(let snapshot):
                self.lastClaudeSnapshot = ClaudeUsageCore.merge(preferred: snapshot, fallback: self.lastClaudeSnapshot)
                self.lastClaudeFetchFailureLabel = nil
                self.lastClaudeRateLimitRetryAt = nil
            case .skippedInFlight, .skippedThrottled:
                break
            case .rateLimited(let retryAt), .skippedRateLimitBackoff(let retryAt):
                self.lastClaudeFetchFailureLabel = nil
                self.lastClaudeRateLimitRetryAt = retryAt
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
                self.publishSharedUsage(lastSnapshot)
            }
            self.refreshStatusTitle()
            self.updateSplitPanel()
        }
    }

    private func refreshStatusTitle() {
        guard let snapshot = lastSnapshot else { return }
        setStatusTitle(Self.statusTitle(from: snapshot, claude: lastClaudeSnapshot))
        statusItem.button?.setAccessibilityValue(Self.accessibilityStatus(from: snapshot, claude: lastClaudeSnapshot))
    }

    private func updateSplitPanel() {
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
            )
        )
        splitPanelView.apply(model)

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
        let accent = NSColor.systemBlue
        var quota: UsagePanelQuota?
        var rows: [UsagePanelRow] = []

        if let usedPercent = snapshot.usedPercent {
            let remaining = remainingUsagePercent(from: usedPercent)
            quota = UsagePanelQuota(
                caption: "남은 주간 사용량",
                percentText: percentTitle(from: remaining),
                fraction: remaining / 100,
                color: remaining <= 15 ? .systemRed : accent,
                accessibilityValue: "남은 Codex 주간 사용량 \(percentTitle(from: remaining))"
            )
        } else {
            rows.append(UsagePanelRow(label: "주간 사용량", value: "정보 없음"))
        }

        if let creditBalance = snapshot.creditBalance {
            let weeklyExhausted = snapshot.usedPercent.map { remainingUsagePercent(from: $0) <= 0 } ?? false
            rows.append(UsagePanelRow(
                label: weeklyExhausted ? "크레딧 사용 중" : "크레딧 잔액",
                value: creditDetailTitle(from: creditBalance),
                valueColor: .systemGreen
            ))
        } else {
            rows.append(UsagePanelRow(
                label: "크레딧",
                value: snapshot.detailedCreditsReturned ? "형식 확인 필요" : "정보 없음"
            ))
        }

        if let resetCredits = snapshot.resetCredits {
            rows.append(UsagePanelRow(label: "초기화 크레딧", value: "\(resetCredits)개"))
        }

        if let resetsAt = snapshot.resetsAt {
            rows.append(UsagePanelRow(label: "주간 초기화", value: resetDateTimeFormatter.string(from: resetsAt)))
        } else if let minutes = snapshot.windowDurationMinutes {
            rows.append(UsagePanelRow(label: "사용량 창", value: "\(minutes)분"))
        }

        var statusLines: [String] = []
        statusLines.append(snapshot.accountID.map { "계정 \($0)" } ?? "계정 정보 없음")
        statusLines.append("업데이트 \(timeFormatter.string(from: snapshot.updatedAt))")

        return UsagePanelColumn(
            title: "Codex",
            accentColor: accent,
            quota: quota,
            rows: rows,
            statusLines: statusLines,
            statusColor: .secondaryLabelColor
        )
    }

    private static func claudeColumn(
        from snapshot: ClaudeUsageSnapshot?,
        fetchFailureLabel: String?,
        rateLimitRetryAt: Date?
    ) -> UsagePanelColumn {
        let accent = NSColor.systemOrange
        // A live countdown (rateLimitRetryAt) always takes priority over a
        // static label so it keeps ticking down across UI refreshes.
        let failureLabel = rateLimitRetryAt.map { ClaudeUsageCore.rateLimitRetryLabel(retryAt: $0, now: Date()) }
            ?? fetchFailureLabel

        guard let snapshot else {
            var statusLines: [String] = []
            if let failureLabel {
                statusLines.append("갱신 실패: \(failureLabel)")
            }
            statusLines.append("터미널에서 Claude Code 실행 시 자동으로 채워집니다")
            return UsagePanelColumn(
                title: "Claude",
                accentColor: accent,
                quota: nil,
                rows: [UsagePanelRow(label: "Claude", value: "정보 없음")],
                statusLines: statusLines,
                statusColor: failureLabel == nil ? .secondaryLabelColor : .systemRed
            )
        }

        var quota: UsagePanelQuota?
        var rows: [UsagePanelRow] = []

        if let remaining = ClaudeUsageCore.remainingPercent(from: snapshot.fiveHourUsedPercent) {
            quota = UsagePanelQuota(
                caption: "5시간 세션 남음",
                percentText: percentTitle(from: remaining),
                fraction: remaining / 100,
                color: remaining <= 15 ? .systemRed : accent,
                accessibilityValue: "남은 Claude 5시간 세션 사용량 \(percentTitle(from: remaining))"
            )
        } else {
            rows.append(UsagePanelRow(label: "5시간 세션", value: "정보 없음"))
        }

        if let resetsAt = snapshot.fiveHourResetsAt {
            rows.append(UsagePanelRow(label: "세션 초기화", value: resetDateTimeFormatter.string(from: resetsAt)))
        }
        if let remaining = ClaudeUsageCore.remainingPercent(from: snapshot.weeklyUsedPercent) {
            rows.append(UsagePanelRow(label: "주간 남음", value: percentTitle(from: remaining), valueColor: .systemPurple))
        }
        if let resetsAt = snapshot.weeklyResetsAt {
            rows.append(UsagePanelRow(label: "주간 초기화", value: resetDateTimeFormatter.string(from: resetsAt)))
        }
        if let model = snapshot.model {
            rows.append(UsagePanelRow(label: "모델", value: model))
        }
        for limit in snapshot.modelWeeklyLimits {
            guard let remaining = ClaudeUsageCore.remainingPercent(from: limit.usedPercent) else { continue }
            let detail = limit.resetsAt.map { "초기화 \(resetDateTimeFormatter.string(from: $0))" }
            rows.append(UsagePanelRow(
                label: "\(limit.modelName) 주간",
                value: "\(percentTitle(from: remaining)) 남음",
                detail: detail
            ))
        }
        if let extraUsage = snapshot.extraUsage {
            rows.append(UsagePanelRow(label: "추가 사용량", value: extraUsageTitle(extraUsage), valueColor: .systemPurple))
        }
        if let contextRemaining = snapshot.contextRemainingPercent {
            rows.append(UsagePanelRow(label: "컨텍스트 남음", value: percentTitle(from: contextRemaining)))
        }
        if let costTitle = ClaudeUsageCore.costTitle(from: snapshot.sessionCostUSD) {
            rows.append(UsagePanelRow(label: "이번 세션 비용", value: costTitle))
        }

        var statusLines: [String] = []
        if let account = snapshot.account {
            if let email = account.email {
                statusLines.append("계정 \(email)")
            }
            if let organizationName = account.organizationName, organizationName != account.email {
                statusLines.append("조직 \(organizationName)")
            }
        }
        if let publishedAt = snapshot.publishedAt {
            statusLines.append("업데이트 \(relativeFormatter.localizedString(for: publishedAt, relativeTo: Date()))")
        }
        if let failureLabel {
            statusLines.append("갱신 실패: \(failureLabel)")
        }
        if statusLines.isEmpty {
            statusLines.append("Claude 사용량 정보 대기 중")
        }

        return UsagePanelColumn(
            title: "Claude",
            accentColor: accent,
            quota: quota,
            rows: rows,
            statusLines: statusLines,
            statusColor: failureLabel == nil ? .secondaryLabelColor : .systemRed
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
        let menu = NSMenu()
        let pathItem = NSMenuItem(title: "저장: ~/Library/Application Support/CCMB", action: nil, keyEquivalent: "")
        let fileItem = NSMenuItem(title: "파일: usage-v1.json", action: nil, keyEquivalent: "")
        let guideItem = NSMenuItem(title: "채팅에 “CCMB 사용량 알려줘” 입력", action: nil, keyEquivalent: "")

        menu.addItem(shareStatusItem)
        menu.addItem(.separator())
        menu.addItem(pathItem)
        menu.addItem(fileItem)
        menu.addItem(shareFolderItem)
        menu.addItem(.separator())
        menu.addItem(guideItem)
        menu.addItem(copySharePromptCombinedItem)
        menu.addItem(.separator())
        menu.addItem(copySharePromptCodexItem)
        menu.addItem(copySharePromptClaudeItem)
        menu.addItem(.separator())
        menu.addItem(copyShareCommandItem)
        shareItem.submenu = menu
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
            "~/.codex/bin/ccmb-usage를 실행해서 Codex와 Claude의 남은 주간 사용량, Codex 크레딧을 알려줘. 각각 fresh가 false면 오래된 데이터라고 말해줘.",
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

    @objc private func refresh() {
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
    }

    @objc private func setRefreshInterval(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? Int else { return }
        refreshInterval = TimeInterval(seconds)
        UserDefaults.standard.set(seconds, forKey: Self.refreshIntervalDefaultsKey)
        if let lastSnapshot {
            do {
                try SharedUsageStore.publish(
                    lastSnapshot,
                    claudeSnapshot: lastClaudeSnapshot,
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
        resetCountdown()
        if refreshInterval > 0 {
            setDetailTitle("자동 새로 고침 · \(sender.title)", for: updatedItem)
            if isOffline {
                showOfflineStatus()
            } else {
                client.refreshRateLimits()
            }
        } else {
            setDetailTitle("자동 새로 고침 꺼짐", for: updatedItem)
        }
    }

    @objc private func openDashboard() {
        guard let url = URL(string: "https://chatgpt.com/codex/settings/usage") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openClaudeDashboard() {
        guard let url = URL(string: "https://claude.ai/settings/usage") else { return }
        NSWorkspace.shared.open(url)
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
        launchAtLoginItem.state = isLaunchAtLoginEnabled ? .on : .off
        setDetailTitle(launchAtLoginItem.title, for: launchAtLoginItem)
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

    private static func statusTitle(from snapshot: RateLimitSnapshot, claude: ClaudeUsageSnapshot?) -> String {
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

        return parts.isEmpty ? "—" : parts.joined(separator: "·")
    }

    private static func remainingUsagePercent(from usedPercent: Double) -> Double {
        UsageCore.remainingPercent(from: usedPercent)
    }

    private static func accessibilityStatus(from snapshot: RateLimitSnapshot, claude: ClaudeUsageSnapshot?) -> String {
        var parts: [String] = []
        if let usedPercent = snapshot.usedPercent {
            parts.append("남은 Codex 주간 사용량 \(percentTitle(from: remainingUsagePercent(from: usedPercent)))")
        }
        if let claudeRemaining = ClaudeUsageCore.remainingPercent(from: claude?.fiveHourUsedPercent) {
            parts.append("남은 Claude 세션 \(percentTitle(from: claudeRemaining))")
        }
        return parts.isEmpty ? "사용량 정보 없음" : parts.joined(separator: ", ")
    }

    private static func percentTitle(from percent: Double) -> String {
        percentFormatter.string(from: NSNumber(value: percent / 100)) ?? "\(Int(percent.rounded()))%"
    }

    private static func durationTitle(seconds: Int) -> String {
        if seconds >= 60 {
            let minutes = seconds / 60
            let remainder = seconds % 60
            return remainder == 0 ? "\(minutes)분" : "\(minutes)분 \(remainder)초"
        }

        return "\(seconds)초"
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
        formatter.dateFormat = "M월 d일 a h:mm"
        return formatter
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.unitsStyle = .full
        return formatter
    }()

    private static let launchAgentLabel = "com.codex.creditmenubar"
    private static let refreshIntervalDefaultsKey = "automaticRefreshIntervalSeconds"
    private static let footerLinkURLString = "https://github.com/armsone"

    private static func savedRefreshInterval() -> TimeInterval {
        let saved = UserDefaults.standard.object(forKey: refreshIntervalDefaultsKey) == nil
            ? nil
            : UserDefaults.standard.integer(forKey: refreshIntervalDefaultsKey)
        return UsageCore.normalizedRefreshInterval(saved)
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
