import AppKit
import XCTest
@testable import CodexCreditMenuBar

/// Offscreen AppKit visual proof for the restored three-card layout. Runs
/// through the real `SplitUsagePanelView`/`UsagePanelModel` — the same
/// types the running app draws — with sanitized fixture data standing in
/// for a NAS read; it never renders a mock HTML view and never touches
/// SystemUIServer, Screen Capture, or any native CUA surface.
///
/// Set `CCMB_VISUAL_PROOF_PATH` to an absolute file path to have this test
/// write the rendered PNG there and fail (rather than silently skip) if
/// that write does not succeed; without it the PNG is still produced and
/// asserted non-empty, it just isn't persisted anywhere.
@MainActor
final class RenderUsagePanelVisualProofTests: XCTestCase {
    /// The restored Codex card: plan, reset-voucher count, and remaining
    /// credit rows, matching `codexColumn` in `main.swift`.
    private func sanitizedCodexColumn() -> UsagePanelColumn {
        UsagePanelColumn(
            title: "Codex",
            accentColor: UsageBrandColors.codex,
            quota: UsagePanelQuota(caption: "주간 남음", percentText: "70%", fraction: 0.7, color: UsageBrandColors.codex, accessibilityValue: "남은 Codex 주간 사용량 70%"),
            secondaryQuota: nil,
            rowGroups: [
                UsagePanelRowGroup(rows: [
                    UsagePanelRow(label: "요금제", value: "Plus", isEmphasized: false),
                    UsagePanelRow(label: "주간 초기화", value: "4일 뒤", isEmphasized: true),
                    UsagePanelRow(label: "초기화 가능", value: "3개", isEmphasized: false),
                    UsagePanelRow(label: "남은 크레딧", value: "$12.50", isEmphasized: true),
                ])
            ],
            accountLines: ["놀이터(NAS) 기준"],
            refreshLine: "마지막 갱신 방금",
            statusLines: [],
            statusColor: .secondaryLabelColor
        )
    }

    /// The restored Claude card: three peer rings (session, Fable weekly,
    /// overall weekly), matching `claudeColumn` in `main.swift`.
    private func sanitizedClaudeColumn() -> UsagePanelColumn {
        let accent = UsageBrandColors.claude
        func ring(_ caption: String, _ percent: Double) -> UsagePanelQuota {
            UsagePanelQuota(caption: caption, percentText: "\(Int(percent))%", fraction: percent / 100, color: accent, accessibilityValue: "\(caption) \(Int(percent))%")
        }
        return UsagePanelColumn(
            title: "Claude",
            accentColor: accent,
            quota: ring("세션 남음", 60),
            secondaryQuota: ring("Fable 주간 남음", 45),
            tertiaryQuota: ring("주간 남음", 50),
            rowGroups: [
                UsagePanelRowGroup(rows: [
                    UsagePanelRow(label: "세션 초기화", value: "2시간 뒤", isEmphasized: true),
                    UsagePanelRow(label: "주간 초기화", value: "3일 뒤", isEmphasized: true),
                ])
            ],
            accountLines: ["놀이터(NAS) 기준"],
            refreshLine: "마지막 갱신 방금",
            statusLines: [],
            statusColor: .secondaryLabelColor
        )
    }

    /// The restored Gemini card: two peer rings (session, weekly) for
    /// whichever fixed account is currently selected, matching
    /// `geminiColumn` in `main.swift`.
    private func sanitizedGeminiColumn(selected: NASServiceID) -> UsagePanelColumn {
        let accent = UsageBrandColors.geminiText
        func ring(_ caption: String, _ percent: Double) -> UsagePanelQuota {
            UsagePanelQuota(caption: caption, percentText: "\(Int(percent))%", fraction: percent / 100, color: accent, accessibilityValue: "\(caption) \(Int(percent))%")
        }
        return UsagePanelColumn(
            title: selected == .gemini2 ? "Gemini · 부" : "Gemini · 주",
            accentColor: accent,
            quota: ring("세션 남음", 80),
            secondaryQuota: ring("주간 남음", 65),
            rowGroups: [
                UsagePanelRowGroup(rows: [
                    UsagePanelRow(label: "세션 초기화", value: "1시간 뒤", isEmphasized: false),
                    UsagePanelRow(label: "주간 초기화", value: "5일 뒤", isEmphasized: false),
                ])
            ],
            accountLines: ["놀이터(NAS) 기준"],
            refreshLine: "마지막 갱신 방금",
            statusLines: [],
            statusColor: .secondaryLabelColor
        )
    }

    private func sanitizedGrokColumn() -> UsagePanelColumn {
        UsagePanelColumn(
            title: "Grok",
            accentColor: .systemGray,
            quota: UsagePanelQuota(caption: "사용량", percentText: "10%", fraction: 0.1, color: .systemGray, accessibilityValue: "10%"),
            secondaryQuota: nil,
            rowGroups: [UsagePanelRowGroup(rows: [UsagePanelRow(label: "주간 사용", value: "10%", isEmphasized: true)])],
            accountLines: ["놀이터(NAS) 기준"],
            refreshLine: "마지막 갱신 방금",
            statusLines: [],
            statusColor: .secondaryLabelColor
        )
    }

    private func sanitizedModel(selected: NASServiceID) -> UsagePanelModel {
        UsagePanelModel(
            codex: sanitizedCodexColumn(),
            claude: sanitizedClaudeColumn(),
            gemini: sanitizedGeminiColumn(selected: selected),
            grok: sanitizedGrokColumn()
        )
    }

    func testRendersExactlyThreeCardsNoSecondGeminiCard() throws {
        let view = SplitUsagePanelView()
        view.apply(sanitizedModel(selected: .gemini))

        XCTAssertEqual(view.frame.width, UsagePanelLayout.viewWidth, accuracy: 0.001)
        let cardFrames = view.subviews
            .filter { $0.frame.width == UsagePanelLayout.columnWidth }
            .map(\.frame.minX)
            .sorted()
        XCTAssertEqual(cardFrames, UsagePanelLayout.columnX)
        XCTAssertEqual(cardFrames.count, 3)

        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            XCTFail("could not allocate offscreen bitmap")
            return
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            XCTFail("could not encode PNG")
            return
        }
        XCTAssertGreaterThan(png.count, 0)

        guard let requestedPath = ProcessInfo.processInfo.environment["CCMB_VISUAL_PROOF_PATH"] else { return }
        let outputURL = URL(fileURLWithPath: requestedPath)
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: outputURL)
    }

    /// Renders a model into a PNG at `path` (skipped when unset) and
    /// returns the real `SplitUsagePanelView`'s laid-out content height, so
    /// the before/after comparison is backed by the same production
    /// layout math `apply(_:)` uses, not an estimate.
    private func renderAndMeasure(_ model: UsagePanelModel, path: String?) throws -> CGFloat {
        let view = SplitUsagePanelView()
        view.apply(model)
        if let path {
            let outputURL = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                XCTFail("could not allocate offscreen bitmap")
                return view.frame.height
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                XCTFail("could not encode PNG")
                return view.frame.height
            }
            try png.write(to: outputURL)
        }
        return view.frame.height
    }

    /// Builds the real `NASFourServiceState` (via `apply(_:)`, the same
    /// mutator the live NAS read path uses) carrying a two-host status —
    /// the shape that used to produce the removed per-host phase/heartbeat/
    /// return/auto-switch lines.
    private func twoHostState() -> NASFourServiceState {
        var state = NASFourServiceState()
        let runningHost = NASExecutionHost(
            hostID: "worker-1",
            runID: "run-42",
            executionAccount: .gemini2,
            phase: "running",
            stateChangedAt: Date().addingTimeInterval(-600),
            lastHeartbeatAt: Date().addingTimeInterval(-5),
            returnState: "pending"
        )
        let idleHost = NASExecutionHost(
            hostID: "worker-2",
            runID: nil,
            executionAccount: nil,
            phase: "idle",
            stateChangedAt: Date().addingTimeInterval(-7200),
            lastHeartbeatAt: nil,
            returnState: "not_required"
        )
        let snapshot = NASSnapshotV2(
            generatedAt: Date(),
            collection: nil,
            entries: [],
            hostStatus: NASHostStatus(hosts: [runningHost, idleHost], autoSwitchEnabled: true)
        )
        state.apply(snapshot)
        return state
    }

    /// Reproduces exactly the per-host phase/heartbeat/return/auto-switch
    /// footer lines the old (pre-restoration) `NASHostStatusPresentation`
    /// used to emit for the idle `.gemini` card while `.gemini2` runs —
    /// kept only in this test as the "before" fixture for the visual proof,
    /// since the production code no longer renders this chatter.
    private func oldStyleHostFooterLines(state: NASFourServiceState, now: Date) -> [String] {
        guard let status = state.hostStatus else { return [] }
        var lines: [String] = ["실행 중: 부계정"]
        for host in status.hosts(for: .gemini) + status.commonHosts {
            lines.append(host.executionAccount == nil ? "공용 호스트 \(host.hostID)" : "호스트 \(host.hostID)")
            lines.append(host.phase == "idle" ? "대기" : (host.phase ?? "단계 정보 없음"))
            if host.returnState == "pending" { lines.append("복귀 확인 대기") }
        }
        lines.append(status.autoSwitchEnabled == true ? "자동 전환 켜짐" : "자동 전환 꺼짐")
        if state.hostStatusIsStale { lines.append("호스트 상태 오래됨") }
        return lines
    }

    /// Proves the restoration: the real production
    /// `NASHostStatusPresentation.footerLines` now returns at most one
    /// compact line for the same two-host NAS state that used to produce a
    /// multi-line chatter block, and the real `SplitUsagePanelView` layout
    /// height (shared across all three columns, see `apply(_:)`) shrinks
    /// accordingly.
    func testGeminiHostFooterShrinksFromChatterToOneLine() throws {
        let state = twoHostState()
        let now = Date()

        let oldLines = oldStyleHostFooterLines(state: state, now: now)
        XCTAssertGreaterThanOrEqual(oldLines.count, 4, "fixture must reproduce the old multi-line chatter")

        let newLines = NASHostStatusPresentation.footerLines(for: .gemini, state: state, source: .nas)
        XCTAssertLessThanOrEqual(newLines.count, 1, "restored footer must be at most one compact line")
        XCTAssertEqual(newLines, [])

        func model(extraGeminiLines: [String]) -> UsagePanelModel {
            var gemini = sanitizedGeminiColumn(selected: .gemini)
            gemini = UsagePanelColumn(
                title: gemini.title,
                accentColor: gemini.accentColor,
                quota: gemini.quota,
                secondaryQuota: gemini.secondaryQuota,
                tertiaryQuota: gemini.tertiaryQuota,
                rowGroups: gemini.rowGroups,
                accountLines: gemini.accountLines + extraGeminiLines,
                refreshLine: gemini.refreshLine,
                statusLines: gemini.statusLines,
                statusColor: gemini.statusColor
            )
            return UsagePanelModel(
                codex: sanitizedCodexColumn(),
                claude: sanitizedClaudeColumn(),
                gemini: gemini,
                grok: sanitizedGrokColumn()
            )
        }

        let outputDir = ProcessInfo.processInfo.environment["CCMB_VISUAL_PROOF_DIR"]
        let oldHeight = try renderAndMeasure(
            model(extraGeminiLines: oldLines),
            path: outputDir.map { "\($0)/gemini-host-footer-old.png" }
        )
        let newHeight = try renderAndMeasure(
            model(extraGeminiLines: newLines),
            path: outputDir.map { "\($0)/gemini-host-footer-new.png" }
        )

        XCTAssertLessThan(newHeight, oldHeight, "restored layout must be shorter than the chatter-filled layout")
    }
}
