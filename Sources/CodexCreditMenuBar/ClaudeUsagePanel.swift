import AppKit
import Foundation
import Security

/// Reads the cache file that `claude-statusline.sh` writes from Claude Code's
/// official statusLine payload. Purely local file I/O — no network calls.
enum ClaudeUsageStore {
    static let cacheURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library")
        .appendingPathComponent("Application Support")
        .appendingPathComponent("CCMB")
        .appendingPathComponent("claude-usage-v1.json")

    private struct CacheFile: Decodable {
        let model: String?
        let weeklyUsedPercent: Double?
        let weeklyResetsAtEpoch: Double?
        let fiveHourUsedPercent: Double?
        let fiveHourResetsAtEpoch: Double?
        let contextUsedPercent: Double?
        let contextRemainingPercent: Double?
        let sessionCostUSD: Double?
        let publishedAt: String?
    }

    static func read() -> ClaudeUsageSnapshot? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        guard let raw = try? JSONDecoder().decode(CacheFile.self, from: data) else { return nil }

        let publishedAt = raw.publishedAt.flatMap { iso8601Formatter.date(from: $0) }
        return ClaudeUsageSnapshot(
            model: raw.model,
            weeklyUsedPercent: raw.weeklyUsedPercent,
            weeklyResetsAt: raw.weeklyResetsAtEpoch.map { Date(timeIntervalSince1970: $0) },
            fiveHourUsedPercent: raw.fiveHourUsedPercent,
            fiveHourResetsAt: raw.fiveHourResetsAtEpoch.map { Date(timeIntervalSince1970: $0) },
            contextUsedPercent: raw.contextUsedPercent,
            contextRemainingPercent: raw.contextRemainingPercent,
            sessionCostUSD: raw.sessionCostUSD,
            publishedAt: publishedAt
        )
    }
}

/// Two-column status panel: Codex info on the left, Claude info on the right,
/// hosted as the `view` of a single NSMenuItem.
@MainActor
final class SplitUsagePanelView: NSView {
    private let columnWidth: CGFloat = 190
    private let columnGap: CGFloat = 16
    private let sidePadding: CGFloat = 14
    private let topPadding: CGFloat = 8
    private let bottomPadding: CGFloat = 8
    private let headerRowGap: CGFloat = 6
    private let rowHeight: CGFloat = 16
    private let headerHeight: CGFloat = 14

    private let leftHeaderLabel = SplitUsagePanelView.makeHeaderLabel("Codex")
    private let rightHeaderLabel = SplitUsagePanelView.makeHeaderLabel("Claude")
    private let dividerView: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.separatorColor.cgColor
        return view
    }()

    private var leftLabels: [NSTextField] = []
    private var rightLabels: [NSTextField] = []

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 420, height: 40))
        addSubview(leftHeaderLabel)
        addSubview(rightHeaderLabel)
        addSubview(dividerView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func makeHeaderLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .boldSystemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    private static func makeRowLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .menuFont(ofSize: 0)
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    func setLines(left: [String], right: [String]) {
        sync(lines: left, labels: &leftLabels)
        sync(lines: right, labels: &rightLabels)
        layoutContent()
    }

    private func sync(lines: [String], labels: inout [NSTextField]) {
        while labels.count < lines.count {
            let label = Self.makeRowLabel()
            addSubview(label)
            labels.append(label)
        }
        while labels.count > lines.count {
            labels.removeLast().removeFromSuperview()
        }
        for (index, line) in lines.enumerated() {
            labels[index].stringValue = line
        }
    }

    private func layoutContent() {
        let rowCount = max(leftLabels.count, rightLabels.count, 1)
        let contentHeight = headerHeight + headerRowGap + CGFloat(rowCount) * rowHeight
        let totalHeight = topPadding + contentHeight + bottomPadding

        let leftX = sidePadding
        let rightX = sidePadding + columnWidth + columnGap
        let dividerX = sidePadding + columnWidth + (columnGap / 2)

        leftHeaderLabel.frame = NSRect(x: leftX, y: topPadding, width: columnWidth, height: headerHeight)
        rightHeaderLabel.frame = NSRect(x: rightX, y: topPadding, width: columnWidth, height: headerHeight)
        dividerView.frame = NSRect(x: dividerX, y: topPadding, width: 1, height: contentHeight)

        let rowsTop = topPadding + headerHeight + headerRowGap
        for (index, label) in leftLabels.enumerated() {
            label.frame = NSRect(x: leftX, y: rowsTop + CGFloat(index) * rowHeight, width: columnWidth, height: rowHeight)
        }
        for (index, label) in rightLabels.enumerated() {
            label.frame = NSRect(x: rightX, y: rowsTop + CGFloat(index) * rowHeight, width: columnWidth, height: rowHeight)
        }

        var newFrame = frame
        newFrame.size.height = totalHeight
        newFrame.size.width = sidePadding * 2 + columnWidth * 2 + columnGap
        frame = newFrame
    }
}

private let iso8601Formatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
}()

/// Fetches Claude account rate-limit usage directly from Anthropic's
/// undocumented OAuth usage endpoint, using the long-lived token from
/// `claude setup-token` already stored locally. This endpoint is not
/// officially documented for third-party use and may change or stop
/// working without notice — failures are silently ignored and the UI
/// falls back to the passive statusLine cache (`ClaudeUsageStore`).
enum ClaudeOAuthUsageClient {
    private static let tokenURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library")
        .appendingPathComponent("Application Support")
        .appendingPathComponent("CCMB")
        .appendingPathComponent("claude-oauth-token")

    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// Floor on how often this endpoint is actually hit, independent of how
    /// often the caller asks — this unofficial endpoint has been observed to
    /// rate-limit (429) well below Codex's own refresh cadence.
    private static let minimumFetchInterval: TimeInterval = 90
    private static var lastFetchDate: Date?
    private static var isFetchInFlight = false

    static func fetchIfDue(completion: @escaping (ClaudeUsageSnapshot?) -> Void) {
        guard !isFetchInFlight else { return }
        if let last = lastFetchDate, Date().timeIntervalSince(last) < minimumFetchInterval {
            return
        }
        guard let token = readToken() else { return }

        isFetchInFlight = true
        lastFetchDate = Date()

        var request = URLRequest(url: usageURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-cli/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { data, response, _ in
            isFetchInFlight = false
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, let data else { return }
            guard let snapshot = parse(data) else { return }
            DispatchQueue.main.async { completion(snapshot) }
        }.resume()
    }

    /// The interactive `claude` CLI session's own OAuth token, stored by Claude
    /// Code in the login keychain. Unlike the `claude setup-token` file token,
    /// this one carries `user:profile` scope, which this usage endpoint
    /// requires. Read fresh on every call so a token Claude Code refreshes
    /// in the background is picked up automatically.
    private static func readKeychainToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let credentials = try? JSONDecoder().decode(StoredCredentials.self, from: data)
        else { return nil }
        return credentials.claudeAiOauth.accessToken
    }

    private struct StoredCredentials: Decodable {
        struct OAuth: Decodable {
            let accessToken: String
        }
        let claudeAiOauth: OAuth
    }

    private static func readToken() -> String? {
        if let keychainToken = readKeychainToken() {
            return keychainToken
        }
        guard let data = try? Data(contentsOf: tokenURL) else { return nil }
        let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (token?.isEmpty ?? true) ? nil : token
    }

    private struct UsageWindow: Decodable {
        let utilization: Double?
        let usage: Double?
        let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case usage
            case resetsAt = "resets_at"
        }

        var value: Double? { utilization ?? usage }
    }

    private struct UsageResponse: Decodable {
        let fiveHour: UsageWindow?
        let sevenDay: UsageWindow?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
        }
    }

    /// The live endpoint returns `resets_at` with fractional seconds
    /// (e.g. `2026-08-17T16:50:00.014898+00:00`), which the plain
    /// `iso8601Formatter` (used elsewhere for the statusLine cache's
    /// whole-second timestamps) can't parse.
    private static let resetsAtFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func parseResetsAt(_ string: String?) -> Date? {
        guard let string else { return nil }
        return resetsAtFormatter.date(from: string) ?? iso8601Formatter.date(from: string)
    }

    private static func parse(_ data: Data) -> ClaudeUsageSnapshot? {
        guard let response = try? JSONDecoder().decode(UsageResponse.self, from: data) else { return nil }
        return ClaudeUsageSnapshot(
            model: nil,
            weeklyUsedPercent: response.sevenDay?.value,
            weeklyResetsAt: parseResetsAt(response.sevenDay?.resetsAt),
            fiveHourUsedPercent: response.fiveHour?.value,
            fiveHourResetsAt: parseResetsAt(response.fiveHour?.resetsAt),
            contextUsedPercent: nil,
            contextRemainingPercent: nil,
            sessionCostUSD: nil,
            publishedAt: Date()
        )
    }
}
