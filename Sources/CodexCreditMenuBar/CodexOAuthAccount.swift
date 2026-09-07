import AppKit
import CryptoKit
import Foundation
import Network
import Security

/// CCMB-owned Codex OAuth refresh-token storage. It is intentionally separate
/// from the Codex CLI keychain item: CCMB never reads, writes, or broadens ACLs
/// for another application's credentials.
enum CodexOAuthCredentialStore {
    private static let service = "com.codex.creditmenubar.codex-oauth"
    private static let account = "refresh-token"

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
              let token = String(data: data, encoding: .utf8), !token.isEmpty else { return nil }
        return token
    }

    static func saveRefreshToken(_ token: String) throws {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let updates: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrLabel as String: "CCMB Codex OAuth",
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemUpdate(identity as CFDictionary, updates as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw CodexOAuthAccountClient.OAuthError.keychain(status) }
        var insertion = identity
        updates.forEach { insertion[$0.key] = $0.value }
        let addStatus = SecItemAdd(insertion as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw CodexOAuthAccountClient.OAuthError.keychain(addStatus) }
    }
}

enum CodexOAuthAccountClient {
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let authorizeURL = URL(string: "https://auth.openai.com/oauth/authorize")!
    private static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    private static let scope = "openid profile email offline_access api.connectors.read api.connectors.invoke"
    private static var cached: Tokens?
    private static var refreshing = false
    private static var waiters: [(Result<Tokens, Error>) -> Void] = []
    private static var login: LoginCoordinator?

    struct Tokens {
        let accessToken: String
        let refreshToken: String
        let email: String?
        let expiresAt: Date
    }

    enum OAuthError: Error {
        case noCredential, invalidResponse, http(Int), callbackUnavailable, stateMismatch, cancelled, keychain(OSStatus)
    }

    static func accessToken(completion: @escaping (Result<Tokens, Error>) -> Void) {
        if let cached, cached.expiresAt.timeIntervalSinceNow > 300 {
            DispatchQueue.main.async { completion(.success(cached)) }
            return
        }
        guard let refreshToken = CodexOAuthCredentialStore.readRefreshToken() else {
            DispatchQueue.main.async { completion(.failure(OAuthError.noCredential)) }
            return
        }
        DispatchQueue.main.async {
            waiters.append(completion)
            guard !refreshing else { return }
            refreshing = true
            exchange(payload: ["client_id": clientID, "grant_type": "refresh_token", "refresh_token": refreshToken]) { result in
                let normalized = result.map { response -> Tokens in
                    let nextRefresh = response.refreshToken.isEmpty ? refreshToken : response.refreshToken
                    if nextRefresh != refreshToken { try? CodexOAuthCredentialStore.saveRefreshToken(nextRefresh) }
                    return Tokens(accessToken: response.accessToken, refreshToken: nextRefresh, email: response.email, expiresAt: response.expiresAt)
                }
                if case .success(let tokens) = normalized { cached = tokens }
                let callbacks = waiters
                waiters.removeAll()
                refreshing = false
                callbacks.forEach { $0(normalized) }
            }
        }
    }

    @MainActor
    static func startLogin(completion: @escaping (Result<Void, Error>) -> Void) {
        guard login == nil else { return }
        let coordinator = LoginCoordinator { result in
            switch result {
            case .failure(let error):
                login = nil
                completion(.failure(error))
            case .success(let authorization):
                var form = URLComponents()
                form.queryItems = [
                    URLQueryItem(name: "grant_type", value: "authorization_code"),
                    URLQueryItem(name: "code", value: authorization.code),
                    URLQueryItem(name: "redirect_uri", value: authorization.redirectURI),
                    URLQueryItem(name: "client_id", value: clientID),
                    URLQueryItem(name: "code_verifier", value: authorization.verifier)
                ]
                exchange(body: (form.percentEncodedQuery ?? "").data(using: .utf8), contentType: "application/x-www-form-urlencoded") { tokenResult in
                    login = nil
                    switch tokenResult {
                    case .failure(let error): completion(.failure(error))
                    case .success(let response):
                        guard !response.refreshToken.isEmpty else { completion(.failure(OAuthError.invalidResponse)); return }
                        do {
                            try CodexOAuthCredentialStore.saveRefreshToken(response.refreshToken)
                            cached = Tokens(accessToken: response.accessToken, refreshToken: response.refreshToken, email: response.email, expiresAt: response.expiresAt)
                            completion(.success(()))
                        } catch { completion(.failure(error)) }
                    }
                }
            }
        }
        login = coordinator
        coordinator.start()
    }

    static func invalidateCachedToken() { cached = nil }

    private struct TokenResponse {
        let accessToken: String
        let refreshToken: String
        let email: String?
        let expiresAt: Date
    }

    private static func exchange(payload: [String: String], completion: @escaping (Result<TokenResponse, Error>) -> Void) {
        exchange(body: try? JSONSerialization.data(withJSONObject: payload), contentType: "application/json", completion: completion)
    }

    private static func exchange(body: Data?, contentType: String, completion: @escaping (Result<TokenResponse, Error>) -> Void) {
        var request = URLRequest(url: tokenURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        URLSession.shared.dataTask(with: request) { data, response, error in
            let result: Result<TokenResponse, Error>
            if error != nil { result = .failure(OAuthError.invalidResponse) }
            else if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { result = .failure(OAuthError.http(http.statusCode)) }
            else if let data,
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let access = json["access_token"] as? String, !access.isEmpty {
                let idToken = json["id_token"] as? String
                result = .success(TokenResponse(
                    accessToken: access,
                    refreshToken: json["refresh_token"] as? String ?? "",
                    email: jwtClaim("email", token: idToken) ?? jwtClaim("email", token: access),
                    expiresAt: jwtExpiry(access) ?? Date().addingTimeInterval(1_800)
                ))
            } else { result = .failure(OAuthError.invalidResponse) }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    private static func jwtExpiry(_ token: String) -> Date? {
        guard let number = jwtObject(token)?["exp"] as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: number.doubleValue)
    }

    private static func jwtClaim(_ key: String, token: String?) -> String? { jwtObject(token)?[key] as? String }

    private static func jwtObject(_ token: String?) -> [String: Any]? {
        guard let token else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private struct Authorization { let code: String; let verifier: String; let redirectURI: String }

    @MainActor
    private final class LoginCoordinator {
        private let completion: (Result<Authorization, Error>) -> Void
        private let callback = CallbackServer()
        private let verifier = randomURLSafe(64)
        private let state = randomURLSafe(32)
        private var redirectURI = ""

        init(completion: @escaping (Result<Authorization, Error>) -> Void) { self.completion = completion }

        func start() {
            guard let port = callback.start(ports: [1455, 1457], handler: { [weak self] query in self?.receive(query) }) else {
                completion(.failure(OAuthError.callbackUnavailable)); return
            }
            redirectURI = "http://localhost:\(port)/auth/callback"
            let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
            var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)
            components?.queryItems = [
                URLQueryItem(name: "response_type", value: "code"), URLQueryItem(name: "client_id", value: clientID),
                URLQueryItem(name: "redirect_uri", value: redirectURI), URLQueryItem(name: "scope", value: scope),
                URLQueryItem(name: "code_challenge", value: challenge), URLQueryItem(name: "code_challenge_method", value: "S256"),
                URLQueryItem(name: "id_token_add_organizations", value: "true"), URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
                URLQueryItem(name: "originator", value: "codex_cli_rs"), URLQueryItem(name: "state", value: state)
            ]
            guard let url = components?.url else { completion(.failure(OAuthError.invalidResponse)); return }
            NSWorkspace.shared.open(url)
        }

        private func receive(_ query: [String: String]) {
            callback.stop()
            guard query["error"] == nil else { completion(.failure(OAuthError.cancelled)); return }
            guard query["state"] == state else { completion(.failure(OAuthError.stateMismatch)); return }
            guard let code = query["code"], !code.isEmpty else { completion(.failure(OAuthError.invalidResponse)); return }
            completion(.success(Authorization(code: code, verifier: verifier, redirectURI: redirectURI)))
        }
    }

    private final class CallbackServer {
        private let queue = DispatchQueue(label: "CodexCreditMenuBar.codex-oauth-callback")
        private var listener: NWListener?
        private var handler: (([String: String]) -> Void)?

        func start(ports: [UInt16], handler: @escaping ([String: String]) -> Void) -> UInt16? {
            self.handler = handler
            for port in ports {
                guard let endpoint = NWEndpoint.Port(rawValue: port), let candidate = try? NWListener(using: .tcp, on: endpoint) else { continue }
                let ready = DispatchSemaphore(value: 0); var isReady = false
                candidate.stateUpdateHandler = { state in if case .ready = state { isReady = true }; if case .ready = state { ready.signal() }; if case .failed = state { ready.signal() } }
                candidate.newConnectionHandler = { [weak self] in self?.receive($0) }
                candidate.start(queue: queue); _ = ready.wait(timeout: .now() + 2)
                if isReady { listener = candidate; return port }
                candidate.cancel()
            }
            return nil
        }

        func stop() { listener?.cancel(); listener = nil }

        private func receive(_ connection: NWConnection) {
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
                guard let self, let data, let text = String(data: data, encoding: .utf8) else { connection.cancel(); return }
                let path = text.components(separatedBy: "\r\n").first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                let pairs: [(String, String)] = (URLComponents(string: path)?.queryItems ?? []).compactMap { item in
                    guard let value = item.value else { return nil }
                    return (item.name, value)
                }
                let query = Dictionary(uniqueKeysWithValues: pairs)
                let body = "<html><body><p>CCMB Codex 연결 처리 완료. 이 탭을 닫으세요.</p></body></html>"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                if query["code"] != nil || query["error"] != nil { DispatchQueue.main.async { self.handler?(query) } }
            }
        }
    }

    private static func randomURLSafe(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        precondition(SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess)
        return Data(bytes).base64URL
    }
}

private extension Data {
    var base64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}
