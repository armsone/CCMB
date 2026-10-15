import AppKit
import Darwin
import Foundation

/// 전역 수집 소스 선택: Codex·Claude·Gemini(본·부계정) 네 카드 전체에
/// 적용되는 전역 설정이다. 놀이터(NAS)가 기본이며, 이 Mac에서 직접 조회는
/// 명시적으로 선택하는 보조 옵션이다. NAS 연결 실패는 결코 이 Mac 직접
/// 조회로 자동 전환되지 않으며, 사용자가 명시적으로 선택을 바꾸기 전까지
/// 마지막 값/오래됨 표시만 보여준다. "이 Mac에서 직접 조회"를 선택했을 때만
/// 로컬 Codex app-server/Claude OAuth/Gemini `agy` 수집기가 호출된다.
enum DataCollectionSource: String {
    case nas
    case localMac

    var title: String {
        switch self {
        case .nas: return "놀이터(기본)"
        case .localMac: return "이 Mac에서 직접 조회(보조)"
        }
    }
}

/// Fetches the NAS's stored four-service snapshot (Codex, Claude, Gemini
/// account1, Gemini account2) over the read-only SSH transport in one
/// call, so a single throttled cadence updates all four NAS-sourced cards.
/// Entirely separate from any local collector (`agy`, Codex/Claude OAuth
/// clients) — this client never touches local CLI credentials and never
/// spawns them. A connection or schema-validation failure is reported
/// as-is; it never silently falls back to a local collector.
enum NASFourServiceClient {
    static let minimumRequestIntervalSeconds: TimeInterval = 180

    @MainActor private static var isFetchInFlight = false
    @MainActor private static var lastFetchDate: Date?
    @MainActor private static var currentTask: Task<Void, Never>?

    enum Outcome {
        case success(NASSnapshotV2)
        case skippedInFlight
        case skippedThrottled
        case failure(NASFetchError)
        /// The envelope failed strict v2 validation (unknown schema, missing
        /// or reordered service, wrong identity pairing).
        case unreadableResponse
    }

    @MainActor
    static func fetchIfDue(minimumInterval: TimeInterval, completion: @escaping (Outcome) -> Void) {
        guard !isFetchInFlight else {
            completion(.skippedInFlight)
            return
        }
        let now = Date()
        if let lastFetchDate, minimumInterval > 0, now.timeIntervalSince(lastFetchDate) < minimumInterval {
            completion(.skippedThrottled)
            return
        }
        isFetchInFlight = true
        lastFetchDate = now
        currentTask = Task { @MainActor in
            defer {
                isFetchInFlight = false
                currentTask = nil
            }
            do {
                let data = try await NASSnapshotClient().fetchSnapshot()
                guard let parsed = NASSnapshotV2Core.parse(data) else {
                    completion(.unreadableResponse)
                    return
                }
                completion(.success(parsed))
            } catch let error as NASFetchError {
                completion(.failure(error))
            } catch {
                completion(.failure(.cancelled))
            }
        }
    }

    /// Stops an in-flight read (SIGTERM→SIGKILL on the ssh child, then the
    /// normal reaped completion) when the user leaves NAS mode.
    @MainActor
    static func cancelInFlight() {
        currentTask?.cancel()
    }
}

/// Fetches the NAS's stored consumption-history v2 output over the same
/// read-only SSH transport as `NASFourServiceClient`, on its own throttle
/// so a slow or unavailable history never blocks the four-service snapshot
/// cadence. The helper's structured `{ok:false,error}` result is passed
/// through as such; the caller keeps whatever history it last parsed — this
/// client itself holds no cache.
enum NASHistoryClient {
    static let minimumRequestIntervalSeconds: TimeInterval = 180

    @MainActor private static var isFetchInFlight = false
    @MainActor private static var lastFetchDate: Date?
    @MainActor private static var currentTask: Task<Void, Never>?

    enum Outcome {
        case success(NASHistoryReadResult)
        case skippedInFlight
        case skippedThrottled
        case failure(NASFetchError)
    }

    @MainActor
    static func fetchIfDue(minimumInterval: TimeInterval, completion: @escaping (Outcome) -> Void) {
        guard !isFetchInFlight else {
            completion(.skippedInFlight)
            return
        }
        let now = Date()
        if let lastFetchDate, minimumInterval > 0, now.timeIntervalSince(lastFetchDate) < minimumInterval {
            completion(.skippedThrottled)
            return
        }
        isFetchInFlight = true
        lastFetchDate = now
        currentTask = Task { @MainActor in
            defer {
                isFetchInFlight = false
                currentTask = nil
            }
            do {
                let result = try await NASSnapshotClient().fetchHistory()
                completion(.success(result))
            } catch let error as NASFetchError {
                completion(.failure(error))
            } catch {
                completion(.failure(.cancelled))
            }
        }
    }

    @MainActor
    static func cancelInFlight() {
        currentTask?.cancel()
    }
}

/// Reads only the active account identifier maintained by the local Gemini
/// CLI. OAuth credentials live in a different file and are never opened.
enum GeminiAccountStore {
    static let accountURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".gemini/google_accounts.json")

    static func readActiveEmail() -> String? {
        readActiveEmailWithSource().email
    }

    static func readActiveEmailWithSource() -> (email: String?, source: String, selectorFile: String, oauthFile: String) {
        let selectorFile = FileManager.default.fileExists(atPath: accountURL.path) ? "present" : "absent"
        if let data = try? Data(contentsOf: accountURL),
           let email = GeminiAccountCore.activeEmail(from: data) {
            return (email, "google_accounts", selectorFile, "not_checked")
        }

        // Some Antigravity/Gemini CLI versions keep the active account only
        // in the OAuth ID token and omit or delay google_accounts.json.
        // Decode the non-secret email claim locally; never persist or log the
        // token or any other credential field.
        let credentialsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/oauth_creds.json")
        let oauthFile = FileManager.default.fileExists(atPath: credentialsURL.path) ? "present" : "absent"
        if let data = try? Data(contentsOf: credentialsURL),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let idToken = root["id_token"] as? String,
           let email = GeminiAccountCore.emailFromIDToken(idToken) {
            return (email, "oauth_id_token", selectorFile, oauthFile)
        }

        // Antigravity builds can keep non-secret user metadata outside the
        // classic Gemini CLI selector files. Inspect only fixed application
        // directories and JSON files whose names indicate account metadata.
        for url in candidateMetadataURLs() {
            if let data = try? Data(contentsOf: url),
               let email = GeminiAccountCore.metadataEmail(from: data) {
                return (email, "app_metadata", selectorFile, oauthFile)
            }
        }
        for url in recentCLILogURLs() {
            if let email = GeminiAccountCore.emailFromCLIAuthLog(at: url) {
                return (email, "agy_cli_log", selectorFile, oauthFile)
            }
        }
        return (nil, "none", selectorFile, oauthFile)
    }

    private static func candidateMetadataURLs() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = [
            home.appendingPathComponent(".gemini/antigravity-cli/cache"),
            home.appendingPathComponent("Library/Application Support/com.google.GeminiMacOS")
        ]
        let manager = FileManager.default
        return roots.flatMap { (root) -> [URL] in
            guard let urls = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
            return urls.filter { url in
                url.pathExtension.lowercased() == "json" &&
                ["account", "user", "profile", "identity"].contains { url.deletingPathExtension().lastPathComponent.lowercased().contains($0) }
            }
        }
    }

    private static func recentCLILogURLs() -> [URL] {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity-cli/log")
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls.filter { $0.pathExtension == "log" }
            .sorted {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }
            .prefix(3)
            .map { $0 }
    }
}

/// Exact brand colors for the panel's three provider columns. Codex and
/// Claude were previously drawn with generic system accent colors
/// (`.systemBlue`/`.systemOrange`); these are the exact values requested for
/// all three so the panel reads as deliberately branded rather than
/// system-themed.
enum UsageBrandColors {
    static let codex = NSColor(ccmbHex: 0x10A37F)
    /// Lighter tint of the Codex green for the Spark bucket in the history
    /// chart, so it reads as "still Codex" while staying distinguishable
    /// from the ordinary weekly segment beneath it.
    static let codexSpark = NSColor(ccmbHex: 0x6FD3B4)
    static let claude = NSColor(ccmbHex: 0xD97757)
    static let claudeFable = NSColor(ccmbHex: 0xE69A7F)
    static let claudeWeekly = NSColor(ccmbHex: 0xC45D42)

    /// Google's four brand colors, in their canonical order. Used as a
    /// gradient rather than reduced to a single solid accent, since Gemini
    /// has no single brand color the way Codex and Claude do.
    static let geminiGradient: [NSColor] = [
        NSColor(ccmbHex: 0x4285F4), // blue
        NSColor(ccmbHex: 0xEA4335), // red
        NSColor(ccmbHex: 0xFBBC05), // yellow
        NSColor(ccmbHex: 0x34A853)  // green
    ]

    /// Same Google palette with a green-leading order for the weekly ring.
    /// The palette remains unmistakably Gemini while the two adjacent limits
    /// can be distinguished without relying on their captions alone.
    static let geminiWeeklyGradient: [NSColor] = [
        NSColor(ccmbHex: 0x34A853), // green
        NSColor(ccmbHex: 0x4285F4), // blue
        NSColor(ccmbHex: 0xEA4335), // red
        NSColor(ccmbHex: 0xFBBC05)  // yellow
    ]

    /// A single representative color for contexts that must stay legible as
    /// plain text (titles, row labels) rather than a gradient: Gemini's own
    /// blue, the leading color of the four-color mark.
    static let geminiText = geminiGradient[0]
}

private extension NSColor {
    /// `srgbRed:` (not `calibratedRed:`) so the exact hex value requested
    /// matches what actually renders — the calibrated color space can shift
    /// the displayed color away from the literal sRGB hex triplet.
    convenience init(ccmbHex hex: Int) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// Outcome of a `GeminiUsageClient.fetchIfDue` attempt. Mirrors
/// `ClaudeUsageFetchOutcome`'s shape: routine skips carry no diagnostic, every
/// other case is a sanitized reason safe to log and show next to stale data.
enum GeminiUsageFetchOutcome {
    case success(GeminiUsageSnapshot)
    case skippedInFlight
    case skippedThrottled
    case commandNotFound
    case timedOut
    case nonZeroExit(Int32)
    case decodeFailure

    var diagnosticDescription: String? {
        switch self {
        case .success, .skippedInFlight, .skippedThrottled:
            return nil
        case .commandNotFound:
            return "agy command not found"
        case .timedOut:
            return "agy timed out"
        case .nonZeroExit(let status):
            return "agy exited \(status)"
        case .decodeFailure:
            return "agy response decode failed"
        }
    }

    /// Short Korean label safe to show next to the stale Gemini panel data.
    var staleReasonLabel: String? {
        switch self {
        case .success, .skippedInFlight, .skippedThrottled:
            return nil
        case .commandNotFound:
            return "agy(Antigravity CLI) 없음"
        case .timedOut:
            return "응답 시간 초과"
        case .nonZeroExit:
            return "agy 실행 오류"
        case .decodeFailure:
            return "응답 처리 실패"
        }
    }
}

/// Fetches Gemini/Antigravity usage by launching the locally installed `agy`
/// CLI in plan/sandbox mode with JSON output, entirely offline from CCMB's
/// own perspective — `agy` itself is responsible for any network access it
/// needs. Every launch uses a resolved `agy` executable with an argument array
/// (never a shell string), runs off the main thread, and is bounded by its own
/// timeout so a hung or missing CLI can never block the UI.
enum GeminiUsageClient {
    /// `agy`'s own `--print-timeout 1m` plus headroom for process startup and
    /// scheduling before CCMB gives up and reports a timeout itself.
    private static let processTimeoutSeconds: TimeInterval = 75

    @MainActor private static var isFetchInFlight = false
    @MainActor private static var lastFetchDate: Date?

    @MainActor
    static func fetchIfDue(minimumInterval: TimeInterval, completion: @escaping (GeminiUsageFetchOutcome) -> Void) {
        guard !isFetchInFlight else {
            completion(.skippedInFlight)
            return
        }
        let now = Date()
        if GeminiUsageCore.shouldThrottleFetch(minimumInterval: minimumInterval, lastFetchDate: lastFetchDate, now: now) {
            completion(.skippedThrottled)
            return
        }

        isFetchInFlight = true
        lastFetchDate = now

        runAgy(arguments: ["-p", "/usage", "--mode", "plan", "--sandbox", "--output-format", "json", "--print-timeout", "1m"]) { usageResult in
            switch usageResult {
            case .failure(let outcome):
                DispatchQueue.main.async { @MainActor in
                    isFetchInFlight = false
                    completion(outcome)
                }
            case .success(let usageData):
                guard let buckets = GeminiUsageCore.parseUsage(usageData) else {
                    DispatchQueue.main.async { @MainActor in
                        isFetchInFlight = false
                        completion(.decodeFailure)
                    }
                    return
                }

                let accountMetadata = GeminiAccountStore.readActiveEmailWithSource()
                DiagnosticLog.shared.log("gemini_account_metadata", [
                    "source": .string(accountMetadata.source),
                    "selectorFile": .string(accountMetadata.selectorFile),
                    "oauthFile": .string(accountMetadata.oauthFile),
                    "result": .string(accountMetadata.email == nil ? "missing" : "found")
                ])
                let snapshot = GeminiUsageCore.snapshot(
                    buckets: buckets,
                    creditBalance: nil,
                    publishedAt: Date(),
                    accountEmail: accountMetadata.email,
                    planTitle: GeminiUsageCore.parsePlanTitle(usageData)
                )
                DispatchQueue.main.async { @MainActor in
                    isFetchInFlight = false
                    completion(.success(snapshot))
                }
            }
        }
    }

    private enum RunResult {
        case success(Data)
        case failure(GeminiUsageFetchOutcome)
    }

    /// Finder-launched apps commonly do not inherit Homebrew's PATH, so check
    /// both the inherited PATH and the standard Apple Silicon/Intel Homebrew
    /// locations before reporting that `agy` is unavailable.
    private static func agyExecutableURL() -> URL? {
        var candidates = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("agy") }
        candidates.append(contentsOf: [
            URL(fileURLWithPath: "/opt/homebrew/bin/agy"),
            URL(fileURLWithPath: "/usr/local/bin/agy"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/agy")
        ])
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Runs `agy <arguments>` on a background queue and reports exactly one
    /// terminal outcome without exposing stderr or account-specific output.
    private static func runAgy(arguments: [String], completion: @escaping (RunResult) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            guard let executableURL = agyExecutableURL() else {
                completion(.failure(.commandNotFound))
                return
            }

            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            process.standardInput = FileHandle.nullDevice

            var outputData = Data()
            let outputHandle = outputPipe.fileHandleForReading
            let outputDrained = DispatchSemaphore(value: 0)
            let processExited = DispatchSemaphore(value: 0)
            outputHandle.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    outputDrained.signal()
                } else {
                    outputData.append(chunk)
                }
            }
            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                // Drained and discarded so the child process never blocks on
                // a full stderr pipe; CCMB has nowhere private-log-free to
                // put it here and does not need its contents to proceed.
                if handle.availableData.isEmpty {
                    handle.readabilityHandler = nil
                }
            }
            process.terminationHandler = { _ in processExited.signal() }

            do {
                try process.run()
            } catch {
                outputHandle.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                completion(.failure(.commandNotFound))
                return
            }

            let timedOut = processExited.wait(timeout: .now() + processTimeoutSeconds) == .timedOut
            if timedOut {
                process.terminate()
                if processExited.wait(timeout: .now() + 2) == .timedOut {
                    kill(process.processIdentifier, SIGKILL)
                    _ = processExited.wait(timeout: .now() + 2)
                }
            }
            process.waitUntilExit()
            _ = outputDrained.wait(timeout: .now() + 2)
            outputHandle.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil

            if timedOut {
                completion(.failure(.timedOut))
                return
            }

            let status = process.terminationStatus
            guard status == 0 else {
                completion(.failure(.nonZeroExit(status)))
                return
            }

            completion(.success(outputData))
        }
    }
}
