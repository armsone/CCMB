import AppKit
import Foundation

/// A single non-secret facet of a Grok CLI OAuth entry plus the access token
/// needed to call the billing endpoint. The token is deliberately the only
/// field that ever leaves `GrokAuthStore`/`GrokAuthCore` as part of an
/// `Authorization` header — it is never logged, displayed, persisted by
/// CCMB, or included in any error/outcome value.
struct GrokAuthCredential: Equatable {
    let accessToken: String
    let email: String?
    let userID: String?
    let teamID: String?
    let expiresAt: Date?
    let hasRefreshToken: Bool
}

/// Pure parsing of the Grok CLI's local `auth.json`. CCMB only ever reads
/// this file and leaves every credential mutation to the official CLI.
enum GrokAuthCore {
    /// Entries are keyed like `https://auth.x.ai::<id>`.
    static let issuerPrefix = "https://auth.x.ai::"

    /// Picks the freshest token-bearing `https://auth.x.ai` entry — the one
    /// with the furthest-out `expires_at` — so a stale, previously-signed-out
    /// entry left behind in the file never wins over the active session.
    /// Entries with no expiry sort behind any entry that has one.
    static func selectCredential(from data: Data) -> GrokAuthCredential? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        var best: (credential: GrokAuthCredential, sortKey: Date)?
        for (key, value) in object {
            guard key.hasPrefix(issuerPrefix),
                  let entry = value as? [String: Any],
                  let token = entry["key"] as? String,
                  !token.isEmpty
            else { continue }

            let expiresAt = parseExpiresAt(entry["expires_at"])
            let credential = GrokAuthCredential(
                accessToken: token,
                email: entry["email"] as? String,
                userID: entry["user_id"] as? String,
                teamID: entry["team_id"] as? String,
                expiresAt: expiresAt,
                hasRefreshToken: (entry["refresh_token"] as? String)?.isEmpty == false
            )
            let sortKey = expiresAt ?? .distantPast
            if best == nil || sortKey > best!.sortKey {
                best = (credential, sortKey)
            }
        }
        return best?.credential
    }

    static func isExpired(_ credential: GrokAuthCredential, now: Date) -> Bool {
        guard let expiresAt = credential.expiresAt else { return false }
        return expiresAt <= now
    }

    /// `expires_at` has been observed as either epoch seconds (number or
    /// numeric string) or an ISO 8601 string; every other shape is treated as
    /// "no expiry known" rather than guessed at.
    private static func parseExpiresAt(_ raw: Any?) -> Date? {
        if let seconds = raw as? Double {
            return Date(timeIntervalSince1970: seconds)
        }
        if let seconds = raw as? Int {
            return Date(timeIntervalSince1970: Double(seconds))
        }
        if let string = raw as? String {
            if let seconds = Double(string) {
                return Date(timeIntervalSince1970: seconds)
            }
            return grokAuthISO8601Formatter.date(from: string)
                ?? grokAuthISO8601WholeSecondsFormatter.date(from: string)
        }
        return nil
    }
}

private let grokAuthISO8601Formatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

private let grokAuthISO8601WholeSecondsFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
}()

/// Reads the Grok CLI's local OAuth state file only. CCMB never writes to
/// this path; automatic refresh and login are delegated to the official CLI.
enum GrokAuthStore {
    static var authFileURL: URL {
        let environment = ProcessInfo.processInfo.environment["GROK_HOME"]
        if let environment, !environment.trimmingCharacters(in: .whitespaces).isEmpty {
            return URL(fileURLWithPath: environment).appendingPathComponent("auth.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok")
            .appendingPathComponent("auth.json")
    }

    static func readCredential() -> GrokAuthCredential? {
        guard let data = try? Data(contentsOf: authFileURL) else { return nil }
        return GrokAuthCore.selectCredential(from: data)
    }
}

/// Outcome of a `GrokUsageClient.fetchIfDue` attempt. Mirrors
/// `GeminiUsageFetchOutcome`'s shape: routine skips carry no diagnostic,
/// every other case is a sanitized reason safe to log and show next to stale
/// data. No case ever carries the access token.
enum GrokUsageFetchOutcome: Error {
    case success(GrokUsageSnapshot)
    case skippedInFlight
    case skippedThrottled
    case notSignedIn
    /// The local credential's own `expires_at` is in the past. The app may ask
    /// the official Grok CLI to refresh it before presenting the login action.
    case expiredCredential
    case httpFailure(status: Int)
    case transportFailure
    case decodeFailure

    var diagnosticDescription: String? {
        switch self {
        case .success, .skippedInFlight, .skippedThrottled:
            return nil
        case .notSignedIn:
            return "no Grok credential found"
        case .expiredCredential:
            return "Grok credential expired"
        case .httpFailure(let status):
            return "http \(status)"
        case .transportFailure:
            return "network error"
        case .decodeFailure:
            return "response decode failed"
        }
    }

    /// Short Korean label safe to show next to the stale Grok panel data.
    var staleReasonLabel: String? {
        switch self {
        case .success, .skippedInFlight, .skippedThrottled:
            return nil
        case .notSignedIn:
            return "브라우저에서 Grok 로그인이 필요합니다"
        case .expiredCredential:
            return "인증 만료 · 브라우저에서 Grok 로그인이 필요합니다"
        case .httpFailure(let status) where status == 401 || status == 403:
            return "인증 만료 · 브라우저에서 Grok 로그인이 필요합니다"
        case .httpFailure(let status):
            return "서버 오류(\(status))"
        case .transportFailure:
            return "네트워크 오류"
        case .decodeFailure:
            return "응답 처리 실패"
        }
    }
}

/// Fetches Grok CLI usage from its own `cli-chat-proxy` billing endpoint,
/// using the OAuth token the `grok` CLI already stored locally. Credential
/// writes and browser authentication remain owned by the official Grok CLI.
enum GrokUsageClient {
    private static let creditsURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    private static let billingURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing")!
    private static let settingsURL = URL(string: "https://cli-chat-proxy.grok.com/v1/settings")!

    @MainActor private static var isFetchInFlight = false
    @MainActor private static var lastFetchDate: Date?

    @MainActor
    static func fetchIfDue(
        minimumInterval: TimeInterval,
        force: Bool = false,
        completion: @escaping (GrokUsageFetchOutcome) -> Void
    ) {
        guard !isFetchInFlight else {
            completion(.skippedInFlight)
            return
        }
        let now = Date()
        if !force, GrokUsageCore.shouldThrottleFetch(minimumInterval: minimumInterval, lastFetchDate: lastFetchDate, now: now) {
            completion(.skippedThrottled)
            return
        }

        guard let credential = GrokAuthStore.readCredential() else {
            completion(.notSignedIn)
            return
        }
        if GrokAuthCore.isExpired(credential, now: now) {
            completion(.expiredCredential)
            return
        }

        isFetchInFlight = true
        lastFetchDate = now

        func request(for url: URL) -> URLRequest {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let userID = credential.userID {
                request.setValue(userID, forHTTPHeaderField: "x-userid")
            }
            request.timeoutInterval = 10
            return request
        }

        func fetch(_ url: URL, completion: @escaping (Result<Data, GrokUsageFetchOutcome>) -> Void) {
            URLSession.shared.dataTask(with: request(for: url)) { data, response, _ in
                guard let http = response as? HTTPURLResponse else {
                    completion(.failure(.transportFailure))
                    return
                }
                guard http.statusCode == 200 else {
                    completion(.failure(.httpFailure(status: http.statusCode)))
                    return
                }
                guard let data else {
                    completion(.failure(.decodeFailure))
                    return
                }
                completion(.success(data))
            }.resume()
        }

        func finish(_ outcome: GrokUsageFetchOutcome) {
            DispatchQueue.main.async { @MainActor in
                isFetchInFlight = false
                completion(outcome)
            }
        }

        // One bounded request per endpoint, no retries. The sequence avoids
        // competing requests while still collecting the four requested facts.
        fetch(creditsURL) { creditsResult in
            switch creditsResult {
            case .failure(let outcome): finish(outcome)
            case .success(let creditsData):
                fetch(billingURL) { billingResult in
                    switch billingResult {
                    case .failure(let outcome): finish(outcome)
                    case .success(let billingData):
                        fetch(settingsURL) { settingsResult in
                            switch settingsResult {
                            case .failure(let outcome): finish(outcome)
                            case .success(let settingsData):
                                if let snapshot = GrokUsageCore.parseCombined(
                                    creditsData: creditsData,
                                    billingData: billingData,
                                    settingsData: settingsData,
                                    accountEmail: credential.email
                                ) {
                                    finish(.success(snapshot))
                                } else {
                                    finish(.decodeFailure)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

enum GrokAuthenticationOutcome: Equatable {
    case success
    case commandNotFound
    case timedOut
    case failed

    var failureLabel: String? {
        switch self {
        case .success:
            return nil
        case .commandNotFound:
            return "Grok CLI를 찾을 수 없습니다"
        case .timedOut:
            return "Grok 인증 시간이 초과되었습니다"
        case .failed:
            return "Grok 인증에 실패했습니다"
        }
    }
}

/// Delegates token refresh and browser login to the official Grok CLI so
/// CCMB never needs to understand, persist, or display OAuth secrets itself.
enum GrokAuthenticationClient {
    private static let refreshTimeoutSeconds: TimeInterval = 20
    private static let loginTimeoutSeconds: TimeInterval = 300

    static func refreshCredential(completion: @escaping (GrokAuthenticationOutcome) -> Void) {
        runGrok(arguments: ["models"], timeout: refreshTimeoutSeconds) { outcome in
            guard case .success = outcome,
                  let credential = GrokAuthStore.readCredential(),
                  !GrokAuthCore.isExpired(credential, now: Date())
            else {
                completion(outcome == .success ? .failed : outcome)
                return
            }
            completion(.success)
        }
    }

    static func login(completion: @escaping (GrokAuthenticationOutcome) -> Void) {
        runGrok(arguments: ["login", "--oauth"], timeout: loginTimeoutSeconds) { outcome in
            guard case .success = outcome,
                  let credential = GrokAuthStore.readCredential(),
                  !GrokAuthCore.isExpired(credential, now: Date())
            else {
                completion(outcome == .success ? .failed : outcome)
                return
            }
            completion(.success)
        }
    }

    private static func grokExecutableURL() -> URL? {
        var candidates = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("grok") }
        let home = FileManager.default.homeDirectoryForCurrentUser
        candidates.append(contentsOf: [
            home.appendingPathComponent(".grok/bin/grok"),
            home.appendingPathComponent(".local/bin/grok"),
            URL(fileURLWithPath: "/opt/homebrew/bin/grok"),
            URL(fileURLWithPath: "/usr/local/bin/grok")
        ])
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func runGrok(
        arguments: [String],
        timeout: TimeInterval,
        completion: @escaping (GrokAuthenticationOutcome) -> Void
    ) {
        DispatchQueue.global(qos: .utility).async {
            guard let executableURL = grokExecutableURL() else {
                completion(.commandNotFound)
                return
            }

            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                if handle.availableData.isEmpty { handle.readabilityHandler = nil }
            }
            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                if handle.availableData.isEmpty { handle.readabilityHandler = nil }
            }

            let exited = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in exited.signal() }
            do {
                try process.run()
            } catch {
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                completion(.commandNotFound)
                return
            }

            let timedOut = exited.wait(timeout: .now() + timeout) == .timedOut
            if timedOut {
                process.terminate()
                if exited.wait(timeout: .now() + 2) == .timedOut {
                    kill(process.processIdentifier, SIGKILL)
                    _ = exited.wait(timeout: .now() + 2)
                }
            }
            process.waitUntilExit()
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil

            if timedOut {
                completion(.timedOut)
            } else {
                completion(process.terminationStatus == 0 ? .success : .failed)
            }
        }
    }
}

/// Restrained, monochrome brand mark for Grok, deliberately not a copy of
/// the X social-network logo — a plain code-native prompt chevron in the
/// same neutral ink the rest of CCMB's UI already uses for secondary text.
enum GrokBrandColor {
    static let mark = NSColor.labelColor.withAlphaComponent(0.72)
}
