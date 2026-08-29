import AppKit
import CryptoKit
import Foundation
import Network
import Security

enum ClaudeOAuthAccountError: Error {
    case noCredential
    case keychain(OSStatus)
    case invalidResponse
    case http(Int)
    case callbackUnavailable
    case stateMismatch
    case cancelled

    var isNoCredential: Bool {
        if case .noCredential = self { return true }
        return false
    }
}

struct ClaudeOAuthAccountTokens {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
}

/// CCMB-owned credential storage. This never queries Claude Code's
/// `Claude Code-credentials` item, so macOS has no cross-application ACL to
/// approve. The stable Developer ID used by the installer remains the sole
/// trusted application for this item.
enum ClaudeOAuthCredentialStore {
    private static let service = "com.codex.creditmenubar.claude-oauth"
    private static let account = "refresh-token"

    static var hasCredential: Bool { readRefreshToken() != nil }

    static func readRefreshToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty
        else { return nil }
        return token
    }

    static func saveRefreshToken(_ token: String) throws {
        let data = Data(token.utf8)
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let updates: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrLabel as String: "CCMB Claude OAuth",
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let updateStatus = SecItemUpdate(identity as CFDictionary, updates as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw ClaudeOAuthAccountError.keychain(updateStatus)
        }
        var insertion = identity
        updates.forEach { insertion[$0.key] = $0.value }
        let addStatus = SecItemAdd(insertion as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw ClaudeOAuthAccountError.keychain(addStatus)
        }
    }
}

@MainActor
enum ClaudeOAuthAccountClient {
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let authorizeURL = URL(string: "https://claude.ai/oauth/authorize")!
    private static let tokenURL = URL(string: "https://console.anthropic.com/v1/oauth/token")!
    private static let scope = "user:profile"
    private static var cachedTokens: ClaudeOAuthAccountTokens?
    private static var tokenRequestInFlight = false
    private static var tokenWaiters: [(Result<String, Error>) -> Void] = []
    private static var loginCoordinator: ClaudeOAuthLoginCoordinator?

    static var hasCredential: Bool { ClaudeOAuthCredentialStore.hasCredential }

    static func clearCachedAccessToken() {
        cachedTokens = nil
    }

    static func accessToken(completion: @escaping (Result<String, Error>) -> Void) {
        if let cachedTokens, cachedTokens.expiresAt.timeIntervalSinceNow > 60 {
            completion(.success(cachedTokens.accessToken))
            return
        }
        guard let refreshToken = ClaudeOAuthCredentialStore.readRefreshToken() else {
            completion(.failure(ClaudeOAuthAccountError.noCredential))
            return
        }
        tokenWaiters.append(completion)
        guard !tokenRequestInFlight else { return }
        tokenRequestInFlight = true
        exchange(payload: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID
        ]) { result in
            finishTokenRequest(result, fallbackRefreshToken: refreshToken)
        }
    }

    static func startLogin(completion: @escaping (Result<Void, Error>) -> Void) {
        guard loginCoordinator == nil else { return }
        let coordinator = ClaudeOAuthLoginCoordinator(
            authorizeURL: authorizeURL,
            clientID: clientID,
            scope: scope
        ) { result in
            switch result {
            case .success(let authorization):
                exchange(payload: [
                    "grant_type": "authorization_code",
                    "code": authorization.code,
                    "state": authorization.state,
                    "redirect_uri": authorization.redirectURI,
                    "client_id": clientID,
                    "code_verifier": authorization.codeVerifier
                ]) { tokenResult in
                    switch tokenResult {
                    case .success(let tokens):
                        do {
                            guard !tokens.refreshToken.isEmpty else {
                                throw ClaudeOAuthAccountError.invalidResponse
                            }
                            try ClaudeOAuthCredentialStore.saveRefreshToken(tokens.refreshToken)
                            cachedTokens = tokens
                            loginCoordinator = nil
                            completion(.success(()))
                        } catch {
                            loginCoordinator = nil
                            completion(.failure(error))
                        }
                    case .failure(let error):
                        loginCoordinator = nil
                        completion(.failure(error))
                    }
                }
            case .failure(let error):
                loginCoordinator = nil
                completion(.failure(error))
            }
        }
        loginCoordinator = coordinator
        coordinator.start()
    }

    private static func finishTokenRequest(
        _ result: Result<ClaudeOAuthAccountTokens, Error>,
        fallbackRefreshToken: String
    ) {
        let accessResult: Result<String, Error>
        switch result {
        case .success(let tokens):
            let refreshToken = tokens.refreshToken.isEmpty ? fallbackRefreshToken : tokens.refreshToken
            let normalized = ClaudeOAuthAccountTokens(
                accessToken: tokens.accessToken,
                refreshToken: refreshToken,
                expiresAt: tokens.expiresAt
            )
            do {
                if refreshToken != fallbackRefreshToken {
                    try ClaudeOAuthCredentialStore.saveRefreshToken(refreshToken)
                }
                cachedTokens = normalized
                accessResult = .success(normalized.accessToken)
            } catch {
                accessResult = .failure(error)
            }
        case .failure(let error):
            accessResult = .failure(error)
        }
        let waiters = tokenWaiters
        tokenWaiters.removeAll()
        tokenRequestInFlight = false
        waiters.forEach { $0(accessResult) }
    }

    private static func exchange(
        payload: [String: String],
        completion: @escaping (Result<ClaudeOAuthAccountTokens, Error>) -> Void
    ) {
        var request = URLRequest(url: tokenURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let result: Result<ClaudeOAuthAccountTokens, Error>
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                result = .failure(ClaudeOAuthAccountError.http(http.statusCode))
            } else if let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let accessToken = json["access_token"] as? String,
                      !accessToken.isEmpty {
                let refreshToken = json["refresh_token"] as? String ?? ""
                let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue ?? 1_800
                result = .success(ClaudeOAuthAccountTokens(
                    accessToken: accessToken,
                    refreshToken: refreshToken,
                    expiresAt: Date().addingTimeInterval(expiresIn)
                ))
            } else {
                result = .failure(ClaudeOAuthAccountError.invalidResponse)
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }
}

private struct ClaudeOAuthAuthorization {
    let code: String
    let state: String
    let codeVerifier: String
    let redirectURI: String
}

@MainActor
private final class ClaudeOAuthLoginCoordinator {
    private let authorizeURL: URL
    private let clientID: String
    private let scope: String
    private let completion: (Result<ClaudeOAuthAuthorization, Error>) -> Void
    private let callbackServer = ClaudeOAuthCallbackServer()
    private let codeVerifier: String
    private let state: String
    private var redirectURI = ""

    init(
        authorizeURL: URL,
        clientID: String,
        scope: String,
        completion: @escaping (Result<ClaudeOAuthAuthorization, Error>) -> Void
    ) {
        self.authorizeURL = authorizeURL
        self.clientID = clientID
        self.scope = scope
        self.completion = completion
        codeVerifier = ClaudeOAuthLoginCoordinator.randomURLSafe(byteCount: 64)
        state = ClaudeOAuthLoginCoordinator.randomURLSafe(byteCount: 32)
    }

    func start() {
        guard let port = callbackServer.start(ports: [1456, 1458], callback: { [weak self] query in
            self?.handle(query)
        }) else {
            completion(.failure(ClaudeOAuthAccountError.callbackUnavailable))
            return
        }
        redirectURI = "http://localhost:\(port)/callback"
        let challenge = SHA256.hash(data: Data(codeVerifier.utf8))
        var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: Self.base64URL(Data(challenge))),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)
        ]
        guard let url = components?.url else {
            completion(.failure(ClaudeOAuthAccountError.invalidResponse))
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func handle(_ query: [String: String]) {
        callbackServer.stop()
        guard query["error"] == nil else {
            completion(.failure(ClaudeOAuthAccountError.cancelled))
            return
        }
        guard let returnedState = query["state"], returnedState == state else {
            completion(.failure(ClaudeOAuthAccountError.stateMismatch))
            return
        }
        guard let code = query["code"], !code.isEmpty else {
            completion(.failure(ClaudeOAuthAccountError.invalidResponse))
            return
        }
        completion(.success(ClaudeOAuthAuthorization(
            code: code,
            state: returnedState,
            codeVerifier: codeVerifier,
            redirectURI: redirectURI
        )))
    }

    private static func randomURLSafe(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        precondition(SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) == errSecSuccess)
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private final class ClaudeOAuthCallbackServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.codex.creditmenubar.claude-oauth-callback")
    private var callback: (([String: String]) -> Void)?

    func start(ports: [UInt16], callback: @escaping ([String: String]) -> Void) -> UInt16? {
        self.callback = callback
        for port in ports {
            guard let endpointPort = NWEndpoint.Port(rawValue: port),
                  let candidate = try? NWListener(using: .tcp, on: endpointPort)
            else { continue }
            let semaphore = DispatchSemaphore(value: 0)
            var ready = false
            candidate.stateUpdateHandler = { state in
                switch state {
                case .ready: ready = true; semaphore.signal()
                case .waiting, .failed, .cancelled: semaphore.signal()
                default: break
                }
            }
            candidate.newConnectionHandler = { [weak self] in self?.handle($0) }
            candidate.start(queue: queue)
            _ = semaphore.wait(timeout: .now() + 2)
            if ready {
                listener = candidate
                return port
            }
            candidate.cancel()
        }
        return nil
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            let query = Self.parseQuery(request)
            let success = query["code"] != nil
            let body = "<html><body style='font-family:-apple-system;text-align:center;padding-top:80px'><h2>\(success ? "CCMB Claude 연결 완료" : "Claude 연결 실패")</h2><p>이 탭을 닫고 CCMB로 돌아가세요.</p></body></html>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            if query["code"] != nil || query["error"] != nil {
                DispatchQueue.main.async { self.callback?(query) }
            }
        }
    }

    private static func parseQuery(_ request: String) -> [String: String] {
        guard let line = request.components(separatedBy: "\r\n").first,
              line.hasPrefix("GET "),
              let path = line.split(separator: " ").dropFirst().first,
              let components = URLComponents(string: String(path))
        else { return [:] }
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap {
            guard let value = $0.value else { return nil }
            return ($0.name, value)
        })
    }
}
