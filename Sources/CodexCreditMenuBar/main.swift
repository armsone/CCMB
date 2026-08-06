import AppKit
import Darwin
import Foundation
import Network

private struct RateLimitSnapshot {
    let accountID: String?
    let usedPercent: Double?
    let windowDurationMinutes: Int?
    let resetsAt: Date?
    let sparkLimitName: String?
    let sparkUsedPercent: Double?
    let sparkResetsAt: Date?
    let resetCredits: Int?
    let creditBalance: Double?
    let detailedCreditsReturned: Bool
    let updatedAt: Date
}

private final class CodexAppServerClient {
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
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var nextID = 1
    private var isInitialized = false
    private var pending: [Int: (Result<Any, Error>) -> Void] = [:]
    private let logURL = URL(fileURLWithPath: "/tmp/CodexCreditMenuBar.debug.log")
    private var accountID: String?
    private var isRefreshing = false
    private var refreshStartedAt: Date?
    private var refreshGeneration = 0
    private var currentCommandDescription: String?
    private var processFailureReported = false

    var onRateLimitsUpdated: ((RateLimitSnapshot) -> Void)?
    var onError: ((String) -> Void)?
    var onRestartRequired: ((String) -> Void)?

    init() {
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

            guard self.isInitialized else { return }
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
        try? stdinPipe?.fileHandleForWriting.close()

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
            try? handle.close()
        }

        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        stdoutBuffer.removeAll()
        stderrBuffer.removeAll()
    }

    private func initialize() {
        sendRequest(
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "codex_credit_menubar",
                    "title": "Codex Credit Menu Bar",
                    "version": "0.3.20"
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

            DispatchQueue.main.async {
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
                    self.emitError("Codex usage response could not be read.")
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
            try inputHandle.write(contentsOf: data)
            try inputHandle.write(contentsOf: newline)
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
        DispatchQueue.main.async {
            self.onError?(message)
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
        let line = "[\(Date())] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: logURL.path) {
            if let handle = try? FileHandle(forWritingTo: logURL) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            }
        } else {
            try? data.write(to: logURL)
        }
    }

    private static func parseRateLimits(_ object: [String: Any], accountID: String?) -> RateLimitSnapshot {
        let rateLimits = object["rateLimits"] as? [String: Any]
        let primary = rateLimits?["primary"] as? [String: Any]
        let sparkLimit = sparkRateLimit(from: object)
        let sparkPrimary = sparkLimit?["primary"] as? [String: Any]

        let resetCredits = object.value(at: ["rateLimitResetCredits", "availableCount"]).flatMap(numberAsInt)
        let resetsAt = primary?["resetsAt"].flatMap(numberAsDouble).map {
            Date(timeIntervalSince1970: $0)
        }
        let sparkResetsAt = sparkPrimary?["resetsAt"].flatMap(numberAsDouble).map {
            Date(timeIntervalSince1970: $0)
        }

        return RateLimitSnapshot(
            accountID: accountID,
            usedPercent: primary?["usedPercent"].flatMap(numberAsDouble),
            windowDurationMinutes: primary?["windowDurationMins"].flatMap(numberAsInt),
            resetsAt: resetsAt,
            sparkLimitName: sparkLimit?["limitName"] as? String,
            sparkUsedPercent: sparkPrimary?["usedPercent"].flatMap(numberAsDouble),
            sparkResetsAt: sparkResetsAt,
            resetCredits: resetCredits,
            creditBalance: object.value(at: ["rateLimits", "credits", "balance"]).flatMap(numberAsDouble),
            detailedCreditsReturned: object.containsKeyRecursively("credits"),
            updatedAt: Date()
        )
    }

    private static func sparkRateLimit(from object: [String: Any]) -> [String: Any]? {
        let limits = object["rateLimitsByLimitId"] as? [String: Any]
        if let sparkLimit = limits?["codex_bengalfox"] as? [String: Any] {
            return sparkLimit
        }

        return limits?.values.compactMap { $0 as? [String: Any] }.first { limit in
            let limitID = (limit["limitId"] as? String)?.lowercased() ?? ""
            let limitName = (limit["limitName"] as? String)?.lowercased() ?? ""
            return limitID.contains("spark") || limitName.contains("spark")
        }
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

private final class WhiteMenuRowView: NSView {
    static let backgroundColor = NSColor.black.withAlphaComponent(0.1)
    static let textColor = NSColor.white.withAlphaComponent(0.8)
    static let rowHeight: CGFloat = 22

    private let hoverLayer = CALayer()
    private let stateLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let arrowLabel = NSTextField(labelWithString: "")
    private weak var item: NSMenuItem?
    private var trackingArea: NSTrackingArea?
    private var isHovered = false {
        didSet {
            updateHoverAppearance()
        }
    }

    init(item: NSMenuItem) {
        self.item = item
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: Self.rowHeight))

        wantsLayer = true
        refreshAppearance()
        hoverLayer.opacity = 0
        hoverLayer.cornerRadius = 6
        hoverLayer.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
        hoverLayer.borderColor = NSColor.white.withAlphaComponent(0.28).cgColor
        hoverLayer.borderWidth = 0.5
        hoverLayer.shadowColor = NSColor.white.cgColor
        hoverLayer.shadowOpacity = 0.12
        hoverLayer.shadowRadius = 5
        hoverLayer.shadowOffset = .zero
        layer?.addSublayer(hoverLayer)
        setup(label: stateLabel, alignment: .center)
        setup(label: titleLabel, alignment: .left)
        setup(label: arrowLabel, alignment: .center)
        arrowLabel.stringValue = item.submenu == nil ? "" : "›"

        addSubview(stateLabel)
        addSubview(titleLabel)
        addSubview(arrowLabel)
        update(title: item.title, state: item.state)
    }

    func refreshAppearance() {
        layer?.backgroundColor = Self.backgroundColor.cgColor
        stateLabel.textColor = Self.textColor
        titleLabel.textColor = Self.textColor
        arrowLabel.textColor = Self.textColor
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        refreshAppearance()
        hoverLayer.frame = bounds.insetBy(dx: 5, dy: 1)
        stateLabel.frame = NSRect(x: 10, y: -4, width: 22, height: Self.rowHeight)
        arrowLabel.frame = NSRect(x: bounds.width - 34, y: -4, width: 22, height: Self.rowHeight)
        titleLabel.frame = NSRect(x: 40, y: -4, width: bounds.width - 80, height: Self.rowHeight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        guard isInteractive else { return }
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func mouseDown(with event: NSEvent) {
        guard let item else { return }

        if let submenu = item.submenu {
            submenu.popUp(positioning: nil, at: NSPoint(x: bounds.maxX - 8, y: bounds.maxY), in: self)
            return
        }

        item.menu?.cancelTracking()
        if let action = item.action {
            NSApp.sendAction(action, to: item.target, from: item)
        }
    }

    func update(title: String, state: NSControl.StateValue) {
        titleLabel.stringValue = title
        stateLabel.stringValue = state == .on ? "✓" : ""
        arrowLabel.stringValue = item?.submenu == nil ? "" : "›"
        needsLayout = true
        needsDisplay = true
    }

    func setRowWidth(_ width: CGFloat) {
        frame.size.width = width
        needsLayout = true
    }

    private func setup(label: NSTextField, alignment: NSTextAlignment) {
        label.textColor = Self.textColor
        label.font = .menuFont(ofSize: 0)
        label.alignment = alignment
        label.lineBreakMode = .byTruncatingTail
        label.backgroundColor = .clear
        label.isBordered = false
        label.isEditable = false
        label.isSelectable = false
    }

    private var isInteractive: Bool {
        item?.action != nil || item?.submenu != nil
    }

    private func updateHoverAppearance() {
        let targetOpacity: Float = isHovered && isInteractive ? 1 : 0
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = hoverLayer.presentation()?.opacity ?? hoverLayer.opacity
        animation.toValue = targetOpacity
        animation.duration = 0.08
        hoverLayer.opacity = targetOpacity
        hoverLayer.add(animation, forKey: "opacity")
    }
}

private final class BlackMenuSeparatorView: NSView {
    private let lineLayer = CALayer()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 7))
        wantsLayer = true
        layer?.backgroundColor = WhiteMenuRowView.backgroundColor.cgColor
        lineLayer.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
        layer?.addSublayer(lineLayer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func refreshAppearance() {
        layer?.backgroundColor = WhiteMenuRowView.backgroundColor.cgColor
        lineLayer.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
    }

    override func layout() {
        super.layout()
        refreshAppearance()
        lineLayer.frame = NSRect(x: 10, y: floor(bounds.height / 2), width: bounds.width - 20, height: 1)
    }

    func setRowWidth(_ width: CGFloat) {
        frame.size.width = width
        needsLayout = true
    }
}

private final class FooterGlassButton: NSButton {
    var isCircle = false {
        didSet {
            needsLayout = true
        }
    }

    private var trackingArea: NSTrackingArea?
    private var isHovered = false {
        didSet {
            updateGlassAppearance()
        }
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = isCircle ? min(bounds.width, bounds.height) / 2 : 8
        updateGlassAppearance()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    private func updateGlassAppearance() {
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.backgroundColor = NSColor.white.withAlphaComponent(isHovered ? 0.22 : 0).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(isHovered ? 0.42 : 0).cgColor
        layer?.borderWidth = isHovered ? 0.7 : 0
        layer?.shadowColor = NSColor.white.cgColor
        layer?.shadowOpacity = isHovered ? 0.16 : 0
        layer?.shadowRadius = isHovered ? 7 : 4
        layer?.shadowOffset = .zero
    }
}

private final class FooterControlsView: NSView {
    private let restartButton = FooterGlassButton(title: "다시 시작", target: nil, action: nil)
    private let linkButton = FooterGlassButton(title: "!", target: nil, action: nil)
    private let quitButton = FooterGlassButton(title: "종료", target: nil, action: nil)
    private weak var parentMenu: NSMenu?
    var onRestart: (() -> Void)?
    var onOpenLink: (() -> Void)?
    var onQuit: (() -> Void)?

    init(menu: NSMenu?) {
        self.parentMenu = menu
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 27))
        wantsLayer = true
        refreshAppearance()
        setupButton(restartButton, action: #selector(restartClicked))
        setupButton(linkButton, action: #selector(linkClicked))
        setupButton(quitButton, action: #selector(quitClicked))
        linkButton.isCircle = true
        linkButton.toolTip = "Instagram"
        addSubview(restartButton)
        addSubview(linkButton)
        addSubview(quitButton)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func refreshAppearance() {
        layer?.backgroundColor = WhiteMenuRowView.backgroundColor.cgColor
    }

    override func layout() {
        super.layout()
        layer?.backgroundColor = WhiteMenuRowView.backgroundColor.cgColor
        let inset: CGFloat = 8
        let gap: CGFloat = 6
        let centerWidth: CGFloat = 28
        let sideWidth = floor((bounds.width - (inset * 2) - (gap * 2) - centerWidth) / 2)
        restartButton.frame = NSRect(x: inset, y: 3, width: sideWidth, height: 21)
        linkButton.frame = NSRect(x: restartButton.frame.maxX + gap, y: 3, width: centerWidth, height: 21)
        quitButton.frame = NSRect(x: linkButton.frame.maxX + gap, y: 3, width: sideWidth, height: 21)
    }

    func setRowWidth(_ width: CGFloat) {
        frame.size.width = width
        needsLayout = true
    }

    private func setupButton(_ button: NSButton, action: Selector) {
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: WhiteMenuRowView.textColor,
            .font: NSFont.menuFont(ofSize: 0)
        ]
        button.target = self
        button.action = action
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.font = .menuFont(ofSize: 0)
        button.contentTintColor = WhiteMenuRowView.textColor
        button.attributedTitle = NSAttributedString(string: button.title, attributes: attributes)
        button.attributedAlternateTitle = NSAttributedString(string: button.title, attributes: attributes)
        button.alignment = .center
        button.setButtonType(.momentaryChange)
    }

    @objc private func restartClicked() {
        parentMenu?.cancelTracking()
        onRestart?()
    }

    @objc private func linkClicked() {
        parentMenu?.cancelTracking()
        onOpenLink?()
    }

    @objc private func quitClicked() {
        parentMenu?.cancelTracking()
        onQuit?()
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

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let client = CodexAppServerClient()
    private let networkMonitor = NWPathMonitor()
    private let networkQueue = DispatchQueue(label: "CodexCreditMenuBar.NetworkMonitor")
    private var countdownTimer: DispatchSourceTimer?
    private let autoRefreshLock = NSLock()
    private var autoRefreshGeneration = 0
    private var refreshInterval: TimeInterval = 30
    private var nextAutoRefreshAt = Date().addingTimeInterval(30)
    private var activity: NSObjectProtocol?

    private let accountItem = NSMenuItem(title: "계정 확인 중...", action: nil, keyEquivalent: "")
    private let usageItem = NSMenuItem(title: "Codex 사용량 확인 중...", action: nil, keyEquivalent: "")
    private let sparkUsageItem = NSMenuItem(title: "Spark 사용량 확인 중...", action: nil, keyEquivalent: "")
    private let resetItem = NSMenuItem(title: "초기화 시간 확인 중...", action: nil, keyEquivalent: "")
    private let resetCreditsItem = NSMenuItem(title: "리셋 크레딧 확인 중...", action: nil, keyEquivalent: "")
    private let creditBalanceItem = NSMenuItem(title: "크레딧 확인 중...", action: nil, keyEquivalent: "")
    private let updatedItem = NSMenuItem(title: "가져온 시간 없음", action: nil, keyEquivalent: "")
    private let refreshItem = NSMenuItem(title: "새로고침(30초 남음)", action: #selector(refresh), keyEquivalent: "")
    private let intervalItem = NSMenuItem(title: "자동 갱신 간격 30초", action: nil, keyEquivalent: "")
    private let refreshOffItem = NSMenuItem(title: "Off", action: #selector(setRefreshInterval(_:)), keyEquivalent: "")
    private let refresh30Item = NSMenuItem(title: "30초", action: #selector(setRefreshInterval(_:)), keyEquivalent: "")
    private let refresh60Item = NSMenuItem(title: "1분", action: #selector(setRefreshInterval(_:)), keyEquivalent: "")
    private let refresh300Item = NSMenuItem(title: "5분", action: #selector(setRefreshInterval(_:)), keyEquivalent: "")
    private let launchAtLoginItem = NSMenuItem(title: "자동시작", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private var lastRateLimitUpdatedAt: Date?
    private var wakeRecoveryToken = 0
    private let wakeRestartDelay: TimeInterval = 14
    private var isOffline = false
    deinit {
        appLog("delegate deinit")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        appLog("delegate did finish launching")
        NSApp.setActivationPolicy(.accessory)
        terminateOtherInstances()
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Keep Codex credit auto-refresh running"
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWakeFromSleep),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        configureStatusItem()
        configureClient()
        startNetworkMonitor()
        refreshLaunchAgentPathIfNeeded()
        client.setAutoRefreshInterval(refreshInterval)
        client.start()
        startCountdownTimer()
        restartAutoRefreshTimer()
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
    }

    private func terminateOtherInstances() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        let currentPID = ProcessInfo.processInfo.processIdentifier

        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier) where app.processIdentifier != currentPID {
            app.terminate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if !app.isTerminated {
                    app.forceTerminate()
                }
            }
        }
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
        autoRefreshLock.lock()
        autoRefreshGeneration += 1
        let generation = autoRefreshGeneration
        let interval = refreshInterval
        autoRefreshLock.unlock()

        guard interval > 0 else {
            appLog("auto refresh loop off")
            return
        }

        appLog("auto refresh loop start \(Int(interval))s generation \(generation)")
        Thread.detachNewThread { [weak self] in
            while true {
                Thread.sleep(forTimeInterval: interval)
                guard let self else {
                    AppDelegate.appLog("auto refresh loop stopped: delegate missing")
                    return
                }
                guard self.isAutoRefreshGenerationActive(generation) else {
                    self.appLog("auto refresh loop stopped: stale generation \(generation)")
                    return
                }
                self.appLog("auto refresh loop wake generation \(generation)")
                self.performAutoRefresh()
            }
        }
    }

    private func stopAutoRefreshLoop() {
        autoRefreshLock.lock()
        autoRefreshGeneration += 1
        autoRefreshLock.unlock()
        appLog("auto refresh loop stop")
    }

    private func isAutoRefreshGenerationActive(_ generation: Int) -> Bool {
        autoRefreshLock.lock()
        defer { autoRefreshLock.unlock() }
        return autoRefreshGeneration == generation && refreshInterval > 0
    }

    private func performAutoRefresh() {
        appLog("auto refresh perform")
        guard !isOffline else {
            DispatchQueue.main.async {
                self.showOfflineStatus()
            }
            return
        }

        DispatchQueue.main.async {
            self.nextAutoRefreshAt = Date().addingTimeInterval(self.refreshInterval)
            self.setDetailTitle("자동 갱신 중...", for: self.usageItem)
            self.setDetailTitle("자동 가져오기 중...", for: self.updatedItem)
            self.updateCountdown()
        }
        client.refreshRateLimits()
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
        guard refreshInterval > 0 else {
            setDetailTitle("새로고침(자동 갱신 꺼짐)", for: refreshItem)
            return
        }

        let seconds = max(0, Int(ceil(nextAutoRefreshAt.timeIntervalSinceNow)))
        setDetailTitle("새로고침(\(Self.durationTitle(seconds: seconds)) 남음)", for: refreshItem)
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
        setDetailTitle(refreshInterval > 0
            ? "자동 갱신 간격 \(Self.durationTitle(seconds: Int(refreshInterval)))"
            : "자동 갱신 간격 Off", for: intervalItem)
    }

    private func setDetailTitle(_ title: String, for item: NSMenuItem) {
        item.title = title
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: WhiteMenuRowView.textColor,
                .font: NSFont.menuFont(ofSize: 0)
            ]
        )
        if let menu = item.menu {
            resizeWhiteMenuRows(in: menu)
        }
        if let rowView = item.view as? WhiteMenuRowView {
            rowView.update(title: title, state: item.state)
            rowView.refreshAppearance()
        }
    }

    private func forceWhiteMenuTitles(in menu: NSMenu) {
        menu.autoenablesItems = false
        for item in menu.items {
            guard !item.isSeparatorItem else { continue }
            item.isEnabled = true
            item.keyEquivalent = ""
            setDetailTitle(item.title, for: item)
            if item.view == nil {
                item.view = WhiteMenuRowView(item: item)
            }
            if let submenu = item.submenu {
                forceWhiteMenuTitles(in: submenu)
            }
            if let rowView = item.view as? WhiteMenuRowView {
                rowView.refreshAppearance()
            }
            if let separatorView = item.view as? BlackMenuSeparatorView {
                separatorView.refreshAppearance()
            }
            if let footerView = item.view as? FooterControlsView {
                footerView.refreshAppearance()
            }
        }
        resizeWhiteMenuRows(in: menu)
    }

    private func resizeWhiteMenuRows(in menu: NSMenu) {
        let font = NSFont.menuFont(ofSize: 0)
        let maxTextWidth = menu.items
            .filter { !$0.isSeparatorItem }
            .map { ($0.title as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 160
        let hasState = menu.items.contains { $0.state == .on }
        let hasSubmenu = menu.items.contains { $0.submenu != nil }
        let stateWidth: CGFloat = hasState ? 34 : 18
        let arrowWidth: CGFloat = hasSubmenu ? 36 : 14
        let width = min(max(ceil(maxTextWidth + stateWidth + arrowWidth + 32), 190), 340)

        for item in menu.items {
            (item.view as? WhiteMenuRowView)?.setRowWidth(width)
            (item.view as? BlackMenuSeparatorView)?.setRowWidth(width)
            (item.view as? FooterControlsView)?.setRowWidth(width)
            if let submenu = item.submenu {
                resizeWhiteMenuRows(in: submenu)
            }
        }
    }

    private func makeBlackSeparatorItem() -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.view = BlackMenuSeparatorView()
        return item
    }

    private func configureStatusItem() {
        statusItem.button?.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        statusItem.button?.toolTip = "Codex credit usage"
        statusItem.button?.imageHugsTitle = true

        if let image = NSImage(systemSymbolName: "bolt.circle", accessibilityDescription: "Codex") {
            image.isTemplate = true
            statusItem.button?.image = image
            statusItem.button?.imagePosition = .imageLeading
        }
        setStatusTitle("...")

        let menu = NSMenu()
        menu.autoenablesItems = false
        accountItem.isEnabled = true
        usageItem.isEnabled = true
        sparkUsageItem.isEnabled = true
        resetItem.isEnabled = true
        resetCreditsItem.isEnabled = true
        creditBalanceItem.isEnabled = true
        updatedItem.isEnabled = true
        refreshItem.isEnabled = true
        intervalItem.isEnabled = true
        setDetailTitle(accountItem.title, for: accountItem)
        setDetailTitle(usageItem.title, for: usageItem)
        setDetailTitle(sparkUsageItem.title, for: sparkUsageItem)
        setDetailTitle(resetItem.title, for: resetItem)
        setDetailTitle(resetCreditsItem.title, for: resetCreditsItem)
        setDetailTitle(creditBalanceItem.title, for: creditBalanceItem)
        setDetailTitle(updatedItem.title, for: updatedItem)
        setDetailTitle(refreshItem.title, for: refreshItem)
        setDetailTitle(intervalItem.title, for: intervalItem)
        makeDashboardLink(creditBalanceItem)
        makeDashboardLink(usageItem)
        makeDashboardLink(sparkUsageItem)
        makeDashboardLink(resetCreditsItem)
        makeDashboardLink(resetItem)
        makeDashboardLink(updatedItem)
        makeDashboardLink(accountItem)

        menu.addItem(accountItem)
        menu.addItem(makeBlackSeparatorItem())
        menu.addItem(usageItem)
        menu.addItem(sparkUsageItem)
        menu.addItem(creditBalanceItem)
        menu.addItem(resetCreditsItem)
        menu.addItem(resetItem)
        menu.addItem(makeBlackSeparatorItem())
        menu.addItem(updatedItem)
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
        menu.addItem(makeBlackSeparatorItem())
        menu.addItem(launchAtLoginItem)
        menu.addItem(makeBlackSeparatorItem())
        let footerItem = NSMenuItem(title: "다시 시작 ! 종료", action: nil, keyEquivalent: "")
        let footerView = FooterControlsView(menu: menu)
        footerView.onRestart = { [weak self] in
            self?.restartApp()
        }
        footerView.onOpenLink = { [weak self] in
            self?.openFooterLink()
        }
        footerView.onQuit = {
            NSApp.terminate(nil)
        }
        footerItem.view = footerView
        menu.addItem(footerItem)

        for item in menu.items {
            item.target = self
        }
        refreshItem.target = self
        refreshOffItem.target = self
        refresh30Item.target = self
        refresh60Item.target = self
        refresh300Item.target = self
        launchAtLoginItem.target = self
        updateRefreshIntervalMenu()
        updateLaunchAtLoginMenu()
        forceWhiteMenuTitles(in: menu)

        statusItem.menu = menu
    }

    private func makeDashboardLink(_ item: NSMenuItem) {
        item.action = #selector(openDashboard)
        item.target = self
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
                self.setStatusTitle("!")
                self.setDetailTitle("오류: \(message)", for: self.usageItem)
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
                    self.client.recoverFromSleep()
                    self.resetCountdown()
                }
            }
        }
        networkMonitor.start(queue: networkQueue)
    }

    private func showOfflineStatus() {
        setStatusTitle("OFF")
        setDetailTitle("오프라인", for: usageItem)
        setDetailTitle("인터넷 연결 대기 중...", for: updatedItem)
        updateCountdown()
    }

    private func apply(_ snapshot: RateLimitSnapshot) {
        setStatusTitle(Self.statusTitle(from: snapshot))

        if let usedPercent = snapshot.usedPercent {
            let remainingPercent = Self.remainingUsagePercent(from: usedPercent)
            setDetailTitle("남은 주간 사용량 \(Self.percentTitle(from: remainingPercent))", for: usageItem)
        } else {
            setDetailTitle("주간 사용량을 받지 못했습니다.", for: usageItem)
        }

        if let sparkUsedPercent = snapshot.sparkUsedPercent {
            let sparkRemainingPercent = Self.remainingUsagePercent(from: sparkUsedPercent)
            setDetailTitle("남은 Spark 사용량 \(Self.percentTitle(from: sparkRemainingPercent))", for: sparkUsageItem)
        } else {
            setDetailTitle("Spark 사용량 정보 없음", for: sparkUsageItem)
        }

        if let accountID = snapshot.accountID {
            setDetailTitle("계정 \(accountID)", for: accountItem)
        } else {
            setDetailTitle("계정 정보 없음", for: accountItem)
        }

        if let resetsAt = snapshot.resetsAt {
            let relativeReset = Self.relativeFormatter.localizedString(for: resetsAt, relativeTo: Date())
            let exactReset = Self.resetDateTimeFormatter.string(from: resetsAt)
            setDetailTitle("\(relativeReset) 초기화 (\(exactReset))", for: resetItem)
        } else if let minutes = snapshot.windowDurationMinutes {
            setDetailTitle("사용량 창 \(minutes)분", for: resetItem)
        } else {
            setDetailTitle("초기화 시간 없음", for: resetItem)
        }

        if let resetCredits = snapshot.resetCredits {
            setDetailTitle("리셋 크레딧 \(resetCredits)개", for: resetCreditsItem)
        } else {
            setDetailTitle("리셋 크레딧 정보 없음", for: resetCreditsItem)
        }

        if let creditBalance = snapshot.creditBalance {
            setDetailTitle("크레딧 \(Self.creditDetailTitle(from: creditBalance))", for: creditBalanceItem)
        } else {
            setDetailTitle(
                snapshot.detailedCreditsReturned ? "크레딧 형식 확인 필요" : "크레딧 정보 없음",
                for: creditBalanceItem
            )
        }
        setDetailTitle("최근 가져옴 \(Self.timeFormatter.string(from: snapshot.updatedAt))", for: updatedItem)
    }

    @objc private func refresh() {
        guard !isOffline else {
            showOfflineStatus()
            return
        }

        resetCountdown()
        setDetailTitle("Codex 사용량 새로고침 중...", for: usageItem)
        setDetailTitle("수동 가져오기 중...", for: updatedItem)
        client.refreshRateLimits()
    }

    @objc private func setRefreshInterval(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? Int else { return }
        refreshInterval = TimeInterval(seconds)
        updateRefreshIntervalMenu()
        client.setAutoRefreshInterval(refreshInterval)
        restartAutoRefreshTimer()
        resetCountdown()
        if refreshInterval > 0 {
            setDetailTitle("자동 갱신 \(sender.title)마다", for: updatedItem)
            if isOffline {
                showOfflineStatus()
            } else {
                client.refreshRateLimits()
            }
        } else {
            setDetailTitle("자동 갱신 꺼짐", for: updatedItem)
        }
    }

    @objc private func openDashboard() {
        guard let url = URL(string: "https://chatgpt.com/codex/settings/usage") else { return }
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

    private static func creditTitle(from balance: Double?) -> String {
        guard let balance else { return "..." }
        return "\(Int(balance.rounded()))"
    }

    private static func creditDetailTitle(from balance: Double) -> String {
        String(format: "%.4f", balance)
    }

    private static func statusTitle(from snapshot: RateLimitSnapshot) -> String {
        var parts: [String] = []

        if let usedPercent = snapshot.usedPercent {
            let remainingPercent = remainingUsagePercent(from: usedPercent)
            if remainingPercent > 0 {
                parts.append(percentTitle(from: remainingPercent))
            }
        }

        if let sparkUsedPercent = snapshot.sparkUsedPercent {
            let sparkRemainingPercent = remainingUsagePercent(from: sparkUsedPercent)
            if sparkRemainingPercent > 0 {
                parts.append("S\(percentTitle(from: sparkRemainingPercent))")
            }
        }

        if parts.count < 2 {
            parts.append(creditTitle(from: snapshot.creditBalance))
        }

        return parts.joined(separator: ",")
    }

    private static func remainingUsagePercent(from usedPercent: Double) -> Double {
        min(max(100 - usedPercent, 0), 100)
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
        formatter.dateFormat = "M월 d일 EEEE a h:mm"
        return formatter
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.unitsStyle = .full
        return formatter
    }()

    private static let launchAgentLabel = "com.codex.creditmenubar"
    private static let footerLinkURLString = "https://www.instagram.com/armsone/"

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
        let line = "[\(Date())] app \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: "/tmp/CodexCreditMenuBar.debug.log")

        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            }
        } else {
            try? data.write(to: url)
        }
    }
}

private enum AppRuntime {
    static let app = NSApplication.shared
    static let delegate = AppDelegate()
}

AppRuntime.app.delegate = AppRuntime.delegate
AppRuntime.app.run()
