import AppKit
import Foundation
import WebKit

/// Read-only "Gemini 온라인" connection: a CCMB-owned WKWebView session onto
/// `https://gemini.google.com/usage`.
///
/// Boundaries this controller deliberately enforces:
/// - Navigation stays inside the Gemini/Google account domains needed for
///   sign-in and the usage page; any other main-frame destination opens in
///   the system browser instead.
/// - WebKit's own default website data store manages cookies/session state.
///   CCMB never reads, extracts, or persists cookies, tokens, or passwords —
///   the only thing persisted is the parsed usage snapshot.
/// - Page text is read exclusively while the usage page itself is showing,
///   parsed immediately by `GeminiOnlineUsageCore`, and never logged.
/// - The visible window only ever opens from an explicit user action.
///   Background ("quiet") refresh reuses the existing WebKit session in a
///   nearly transparent reference window so the client-rendered page keeps
///   its normal layout and hydration behavior. It obeys a conservative
///   minimum interval and only runs after a successful user connection.
@MainActor
final class GeminiOnlineWebController: NSObject, WKNavigationDelegate, NSWindowDelegate {
    enum Update {
        case snapshot(GeminiOnlineUsageSnapshot)
        /// Signed out (or Google refused the embedded session). The UI keeps
        /// a clear 연결 필요 recovery path instead of pretending success.
        case connectionRequired
        /// The usage page rendered but its structure was unreadable.
        case parseFailed
    }

    var onUpdate: ((Update) -> Void)?

    private static let usageURL = URL(string: "https://gemini.google.com/usage")!
    /// Domains the embedded session may navigate. `google.com` covers
    /// `accounts.google.com` and the consent pages the sign-in flow uses.
    private static let allowedDomains = [
        "gemini.google.com",
        "google.com",
        "gstatic.com",
        "googleusercontent.com",
        "googleapis.com",
        "recaptcha.net"
    ]
    /// The usage page is a client-rendered app, so extraction retries a few
    /// times after `didFinish` before declaring the structure unreadable.
    private static let extractionDelays: [TimeInterval] = [1.5, 3, 5]
    private static let quietTimeoutSeconds: TimeInterval = 45
    private static let maximumUsageRedirects = 3

    private var window: NSWindow?
    private var connectWebView: WKWebView?
    private var quietWebView: WKWebView?
    private var quietHostWindow: NSWindow?
    private var statusLabel: NSTextField?
    private var lastQuietRefreshAt: Date?
    private var quietWatchdogToken = 0
    private var usageRedirectCount = 0

    // MARK: - Explicit user actions

    /// First connection / reconnection: opens (or refocuses) the visible
    /// window on the usage page so the user can sign in if needed.
    func connect() {
        usageRedirectCount = 0
        if let window, let connectWebView {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            connectWebView.load(URLRequest(url: Self.usageURL))
            return
        }
        let webView = makeWebView()
        connectWebView = webView
        buildWindow(hosting: webView)
        setStatus("gemini.google.com 사용량 페이지를 여는 중…")
        webView.load(URLRequest(url: Self.usageURL))
    }

    /// Quiet refresh: re-reads the usage page without any window, only when
    /// a WebKit session has produced a snapshot before, and never more often
    /// than the conservative minimum interval. `force` (the user's explicit
    /// 새로고침 action) bypasses the interval but nothing else.
    func refreshQuietlyIfDue(force: Bool = false) {
        guard GeminiOnlineUsageCore.hasConnectedBefore() else { return }
        guard quietWebView == nil, connectWebView == nil else { return }
        let now = Date()
        if !force,
           let lastQuietRefreshAt,
           now.timeIntervalSince(lastQuietRefreshAt) < GeminiOnlineUsageCore.minimumQuietRefreshIntervalSeconds {
            return
        }
        lastQuietRefreshAt = now
        usageRedirectCount = 0

        let webView = makeWebView()
        quietWebView = webView
        attachQuietWebView(webView)
        let cachePolicy: URLRequest.CachePolicy = force ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy
        webView.load(URLRequest(url: Self.usageURL, cachePolicy: cachePolicy, timeoutInterval: 30))

        quietWatchdogToken += 1
        let token = quietWatchdogToken
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.quietTimeoutSeconds) { [weak self] in
            guard let self, self.quietWatchdogToken == token, self.quietWebView != nil else { return }
            // Timed out: tear down silently. The panel already reports the
            // snapshot's age honestly, so no fabricated status is needed.
            self.finishQuiet(reporting: nil)
        }
    }

    // MARK: - Web view / window construction

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // WebKit's default persistent store owns all site data; CCMB never
        // touches it beyond letting the session exist.
        configuration.websiteDataStore = .default()
        // Match Safari's full user-agent shape; Google commonly refuses
        // embedded sign-in from web views that omit the Safari suffix.
        configuration.applicationNameForUserAgent = "Version/17.6 Safari/605.1.15"
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        return webView
    }

    private func buildWindow(hosting webView: WKWebView) {
        let contentRect = NSRect(x: 0, y: 0, width: 520, height: 660)
        let panel = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Gemini 온라인 연결"
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        let root = NSView(frame: contentRect)
        let barHeight: CGFloat = 30
        webView.frame = NSRect(
            x: 0,
            y: barHeight,
            width: contentRect.width,
            height: contentRect.height - barHeight
        )
        webView.autoresizingMask = [.width, .height]
        root.addSubview(webView)

        let bar = NSView(frame: NSRect(x: 0, y: 0, width: contentRect.width, height: barHeight))
        bar.autoresizingMask = [.width]
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 10, y: 7, width: contentRect.width - 130, height: 16)
        label.autoresizingMask = [.width]
        statusLabel = label
        bar.addSubview(label)

        let readButton = NSButton(title: "사용량 다시 읽기", target: self, action: #selector(rereadUsage))
        readButton.bezelStyle = .rounded
        readButton.controlSize = .small
        readButton.font = .systemFont(ofSize: 11)
        readButton.frame = NSRect(x: contentRect.width - 118, y: 3, width: 110, height: 24)
        readButton.autoresizingMask = [.minXMargin]
        readButton.setAccessibilityLabel("Gemini 사용량 페이지 다시 읽기")
        bar.addSubview(readButton)
        root.addSubview(bar)

        panel.contentView = root
        panel.center()
        window = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Gemini's usage screen is a client-rendered app. Keeping the quiet
    /// reader in a real, screen-positioned view hierarchy prevents WebKit
    /// from skipping the layout/hydration work that an unattached view can
    /// miss, while remaining non-interactive and effectively invisible.
    private func attachQuietWebView(_ webView: WKWebView) {
        let contentRect = NSRect(x: 0, y: 0, width: 520, height: 660)
        let host = NSWindow(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        host.isReleasedWhenClosed = false
        host.ignoresMouseEvents = true
        host.hasShadow = false
        host.isOpaque = true
        host.backgroundColor = .windowBackgroundColor
        host.alphaValue = 0.01
        host.collectionBehavior = [.transient, .ignoresCycle]

        let root = NSView(frame: contentRect)
        webView.frame = root.bounds
        webView.autoresizingMask = [.width, .height]
        root.addSubview(webView)
        host.contentView = root

        if let screenFrame = NSScreen.main?.visibleFrame {
            host.setFrameOrigin(NSPoint(
                x: screenFrame.midX - contentRect.width / 2,
                y: screenFrame.midY - contentRect.height / 2
            ))
        }
        quietHostWindow = host
        host.orderBack(nil)
    }

    private func setStatus(_ text: String) {
        statusLabel?.stringValue = text
    }

    @objc private func rereadUsage() {
        guard let connectWebView else { return }
        usageRedirectCount = 0
        if isUsagePage(connectWebView.url) {
            setStatus("사용량 표시를 읽는 중…")
            scheduleExtraction(on: connectWebView, attempt: 0)
        } else {
            connectWebView.load(URLRequest(url: Self.usageURL))
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        connectWebView?.stopLoading()
        connectWebView?.navigationDelegate = nil
        connectWebView = nil
        statusLabel = nil
        window = nil
    }

    // MARK: - WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        guard ["https", "http", "about", "blob", "data"].contains(scheme) else {
            decisionHandler(.cancel)
            return
        }
        guard let host = url.host?.lowercased() else {
            decisionHandler(.allow)
            return
        }
        guard Self.isAllowedHost(host) else {
            decisionHandler(.cancel)
            // Deliberate outbound links leave for the system browser;
            // blocked subresources are simply dropped.
            if navigationAction.targetFrame == nil || navigationAction.targetFrame?.isMainFrame == true {
                NSWorkspace.shared.open(url)
            }
            return
        }
        if navigationAction.targetFrame == nil {
            // Keep allowed pop-up targets inside this same view.
            decisionHandler(.cancel)
            webView.load(navigationAction.request)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === connectWebView || webView === quietWebView else { return }
        guard let url = webView.url, let host = url.host?.lowercased() else { return }
        let isQuiet = webView === quietWebView

        if host == "gemini.google.com" {
            if isUsagePage(url) {
                if !isQuiet { setStatus("사용량 표시를 읽는 중…") }
                scheduleExtraction(on: webView, attempt: 0)
            } else if usageRedirectCount < Self.maximumUsageRedirects {
                // Sign-in lands on /app; steer back to /usage a bounded
                // number of times so a redirect loop can never spin.
                usageRedirectCount += 1
                if !isQuiet { setStatus("사용량 페이지로 이동하는 중…") }
                webView.load(URLRequest(url: Self.usageURL))
            } else if isQuiet {
                finishQuiet(reporting: .parseFailed)
            } else {
                setStatus("사용량 페이지를 열지 못했습니다")
                onUpdate?(.parseFailed)
            }
        } else if host == "accounts.google.com" || host.hasSuffix(".accounts.google.com") {
            if isQuiet {
                finishQuiet(reporting: .connectionRequired)
            } else {
                setStatus("Google 계정으로 로그인해 주세요")
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleNavigationFailure(webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleNavigationFailure(webView)
    }

    private func handleNavigationFailure(_ webView: WKWebView) {
        if webView === quietWebView {
            finishQuiet(reporting: nil)
        } else if webView === connectWebView {
            setStatus("페이지를 불러오지 못했습니다 · 다시 시도해 주세요")
        }
    }

    // MARK: - Extraction

    private func isUsagePage(_ url: URL?) -> Bool {
        url?.host?.lowercased() == "gemini.google.com" && url?.path.hasPrefix("/usage") == true
    }

    private func scheduleExtraction(on webView: WKWebView, attempt: Int) {
        guard attempt < Self.extractionDelays.count else {
            if webView === quietWebView {
                finishQuiet(reporting: .parseFailed)
            } else {
                setStatus("사용량 표시를 읽지 못했습니다 · 페이지 구조가 바뀌었을 수 있습니다")
                onUpdate?(.parseFailed)
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.extractionDelays[attempt]) { [weak self, weak webView] in
            MainActor.assumeIsolated {
                guard let self, let webView else { return }
                guard webView === self.connectWebView || webView === self.quietWebView else { return }
                guard self.isUsagePage(webView.url) else { return }
                // Reads only the rendered usage screen's visible text; the
                // result goes straight to the parser and is never logged or
                // stored.
                webView.evaluateJavaScript("document.body ? document.body.innerText : ''") { value, _ in
                    MainActor.assumeIsolated {
                        let text = value as? String ?? ""
                        if let snapshot = GeminiOnlineUsageCore.parse(visibleText: text) {
                            self.handleSuccess(snapshot, webView: webView)
                        } else if GeminiOnlineUsageCore.textLooksSignedOut(text) {
                            self.handleSignedOut(webView: webView)
                        } else {
                            self.scheduleExtraction(on: webView, attempt: attempt + 1)
                        }
                    }
                }
            }
        }
    }

    private func handleSuccess(_ snapshot: GeminiOnlineUsageSnapshot, webView: WKWebView) {
        GeminiOnlineUsageCore.persist(snapshot)
        if webView === quietWebView {
            teardownQuietWebView()
        } else {
            setStatus("사용량을 읽었습니다 · 이 창은 닫아도 됩니다")
        }
        onUpdate?(.snapshot(snapshot))
    }

    private func handleSignedOut(webView: WKWebView) {
        if webView === quietWebView {
            finishQuiet(reporting: .connectionRequired)
        } else {
            setStatus("Google 계정으로 로그인해 주세요")
        }
    }

    private func finishQuiet(reporting update: Update?) {
        teardownQuietWebView()
        if let update {
            onUpdate?(update)
        }
    }

    private func teardownQuietWebView() {
        quietWatchdogToken += 1
        quietWebView?.stopLoading()
        quietWebView?.navigationDelegate = nil
        quietWebView = nil
        quietHostWindow?.orderOut(nil)
        quietHostWindow?.close()
        quietHostWindow = nil
    }

    private static func isAllowedHost(_ host: String) -> Bool {
        allowedDomains.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
