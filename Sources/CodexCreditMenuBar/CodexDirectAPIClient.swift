import Foundation

/// Direct Codex usage reader. It reads the official CLI's local auth.json and
/// calls ChatGPT's usage endpoint without starting Node or codex app-server.
/// Derived from the documented architecture of Usage4Claude's MIT-licensed
/// Codex implementation. See THIRD_PARTY_NOTICES.md.
final class CodexDirectAPIClient: @unchecked Sendable {
    private let queue = DispatchQueue(label: "CodexCreditMenuBar.CodexDirectAPIClient")
    private let callbackQueue: DispatchQueue?
    private let session: URLSession
    private let diagnosticLog: DiagnosticLog?
    private var task: URLSessionDataTask?
    private var accessToken: String?
    private var isFetching = false

    var onRateLimitsUpdated: ((RateLimitSnapshot) -> Void)?
    var onError: ((String) -> Void)?
    var onRestartRequired: ((String) -> Void)?

    init(callbackQueue: DispatchQueue? = .main, diagnosticLog: DiagnosticLog? = nil) {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
        self.callbackQueue = callbackQueue
        self.diagnosticLog = diagnosticLog
    }

    func start() { refreshRateLimits() }
    func setAutoRefreshInterval(_ interval: TimeInterval) {}

    func refreshRateLimits() {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.isFetching else {
                self.diagnosticLog?.log("codex_direct_refresh_skipped", ["reason": .string("in_flight")])
                return
            }
            self.isFetching = true
            self.fetch()
        }
    }

    func recoverFromSleep() { refreshRateLimits() }

    func stop() {
        queue.async { [weak self] in
            self?.task?.cancel()
            self?.task = nil
            self?.isFetching = false
        }
    }

    private func fetch() {
        if CodexOAuthCredentialStore.readRefreshToken() != nil {
            CodexOAuthAccountClient.accessToken { [weak self] result in
                guard let self else { return }
                self.queue.async {
                    switch result {
                    case .success(let tokens): self.fetchUsage(accessToken: tokens.accessToken, accountID: tokens.email, credentialSource: "ccmb_keychain_oauth")
                    case .failure: self.fetchFromCLIAuth()
                    }
                }
            }
            return
        }
        fetchFromCLIAuth()
    }

    private func fetchFromCLIAuth() {
        guard let credentials = readCredentials() else {
            fail("Codex 로그인 정보가 없습니다. Codex CLI에서 로그인하거나 CCMB에서 Codex 계정을 연결해 주세요.", kind: "credentials-missing")
            return
        }
        fetchUsage(accessToken: credentials.accessToken, accountID: credentials.accountID, credentialSource: "codex_cli_auth")
    }

    private func fetchUsage(accessToken token: String, accountID: String?, credentialSource: String) {
        accessToken = token
        guard let url = URL(string: "https://chatgpt.com/backend-api/wham/usage") else {
            fail("Codex 사용량 URL이 올바르지 않습니다.", kind: "invalid-url")
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("https://chatgpt.com", forHTTPHeaderField: "Origin")
        request.setValue("https://chatgpt.com/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")

        diagnosticLog?.log("codex_direct_request_begin", [
            "endpoint": .string("chatgpt.com/backend-api/wham/usage"),
            "credentialSource": .string(credentialSource)
        ])
        let startedAt = Date()
        task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            self.queue.async {
                self.task = nil
                self.isFetching = false
                if let error {
                    self.fail("Codex 직접 API 통신 실패: \(error.localizedDescription)", kind: "network", elapsed: Date().timeIntervalSince(startedAt))
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    self.fail("Codex 직접 API 응답을 확인하지 못했습니다.", kind: "no-response", elapsed: Date().timeIntervalSince(startedAt))
                    return
                }
                self.diagnosticLog?.log("codex_direct_response", [
                    "status": .int(http.statusCode),
                    "elapsedSeconds": .double(Date().timeIntervalSince(startedAt))
                ])
                guard let data else {
                    self.fail("Codex 직접 API 응답 본문이 없습니다.", kind: "no-data", elapsed: Date().timeIntervalSince(startedAt))
                    return
                }
                guard (200...299).contains(http.statusCode) else {
                    let message = http.statusCode == 401
                        ? "Codex 로그인이 만료됐습니다. Codex CLI에서 다시 로그인해 주세요."
                        : "Codex 직접 API가 HTTP \(http.statusCode)을 반환했습니다."
                    self.fail(message, kind: http.statusCode == 401 ? "unauthorized" : "http", elapsed: Date().timeIntervalSince(startedAt))
                    return
                }
                guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let snapshot = Self.parse(object, accountID: accountID) else {
                    self.fail("Codex 직접 API 응답 형식을 해석하지 못했습니다.", kind: "decode", elapsed: Date().timeIntervalSince(startedAt))
                    return
                }
                self.diagnosticLog?.log("codex_direct_refresh_complete", [
                    "elapsedSeconds": .double(Date().timeIntervalSince(startedAt))
                ])
                self.deliver { self.onRateLimitsUpdated?(snapshot) }
            }
        }
        task?.resume()
    }

    private func fail(_ message: String, kind: String, elapsed: TimeInterval? = nil) {
        isFetching = false
        var fields: [String: DiagnosticValue] = ["kind": .string(kind)]
        if let elapsed { fields["elapsedSeconds"] = .double(elapsed) }
        diagnosticLog?.log("codex_direct_refresh_failed", fields)
        deliver { self.onError?(message) }
    }

    private func deliver(_ work: @escaping () -> Void) {
        if let callbackQueue { callbackQueue.async(execute: work) }
        else { work() }
    }

    private struct Credentials {
        let accessToken: String
        let accountID: String?
    }

    private func readCredentials() -> Credentials? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String,
              !accessToken.isEmpty else { return nil }
        return Credentials(
            accessToken: accessToken,
            accountID: tokens["account_id"] as? String
        )
    }

    private static func parse(_ object: [String: Any], accountID: String?) -> RateLimitSnapshot? {
        let rateLimit = object["rate_limit"] as? [String: Any]
        func number(_ value: Any?) -> Double? {
            if let value = value as? Double { return value }
            if let value = value as? Int { return Double(value) }
            if let value = value as? String { return Double(value) }
            return nil
        }
        func date(_ window: [String: Any]) -> Date? {
            if let timestamp = number(window["reset_at"]) { return Date(timeIntervalSince1970: timestamp) }
            if let seconds = number(window["reset_after_seconds"]) { return Date().addingTimeInterval(seconds) }
            return nil
        }

        func windows(in limit: [String: Any]?) -> [[String: Any]] {
            [limit?["primary_window"], limit?["secondary_window"]].compactMap { $0 as? [String: Any] }
        }
        func nearestWindow(_ candidates: [[String: Any]], to seconds: Double) -> [String: Any]? {
            candidates.min { left, right in
                abs((number(left["limit_window_seconds"]) ?? 0) - seconds) < abs((number(right["limit_window_seconds"]) ?? 0) - seconds)
            }
        }

        // `wham/usage` puts the ordinary Codex weekly bucket at the root;
        // the optional 5-hour/Spark pair is listed under additional limits.
        // Do not treat the first root window as a session simply because an
        // older app-server response happened to label it that way.
        let baseWindows = windows(in: rateLimit)
        let weekly = nearestWindow(baseWindows, to: 604_800)
        let sparkLimit = (object["additional_rate_limits"] as? [[String: Any]])?.first {
            (($0["limit_name"] as? String) ?? "").localizedCaseInsensitiveContains("spark")
        }?["rate_limit"] as? [String: Any]
        let sparkWeekly = nearestWindow(windows(in: sparkLimit), to: 604_800)
        let credits = object["credits"] as? [String: Any]
        let balance = number(credits?["balance"])
        let resetCredits = number(
            (object["rate_limit_reset_credits"] as? [String: Any])?["available_count"]
        ).map(Int.init)
        guard weekly != nil || sparkWeekly != nil || balance != nil else { return nil }
        return RateLimitSnapshot(
            accountID: object["email"] as? String ?? accountID ?? object["account_id"] as? String,
            planType: object["plan_type"] as? String,
            usedPercent: number(weekly?["used_percent"]),
            windowDurationMinutes: number(weekly?["limit_window_seconds"]).map { Int($0 / 60) },
            resetsAt: weekly.flatMap(date),
            resetCredits: resetCredits,
            creditBalance: balance,
            sparkUsedPercent: number(sparkWeekly?["used_percent"]),
            sparkWindowDurationMinutes: number(sparkWeekly?["limit_window_seconds"]).map { Int($0 / 60) },
            sparkResetsAt: sparkWeekly.flatMap(date),
            detailedCreditsReturned: credits != nil,
            updatedAt: Date()
        )
    }
}
