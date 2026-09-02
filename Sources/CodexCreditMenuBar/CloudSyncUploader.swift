import CloudKit
import Foundation
import Security

/// Uploads the already-published `usage-v1.json` bytes to the user's own
/// CloudKit private database so the iPhone app can read them from anywhere.
///
/// Contract shared with CCMB-iOS `CloudKitSync.swift` — container identifier,
/// record type, fixed record name, and field names must stay identical on
/// both sides. One fixed record is overwritten on every upload; no history
/// accumulates. The record carries only the snapshot JSON (whose schema never
/// contains tokens, cookies, OAuth credentials, or raw CLI responses), the
/// schema version, the publish time, and the Mac app version.
///
/// Uploads are strictly best-effort and asynchronous: local publishing has
/// already succeeded before this class is asked to run, and no failure here
/// may delay or fail any local feature.
final class CloudSyncUploader {
    static let containerIdentifier = "iCloud.com.armsone.ccmb"
    static let recordType = "CCMBUsageSnapshot"
    static let recordName = "latest-usage-v1"

    private enum Field {
        static let schemaVersion = "schemaVersion"
        static let snapshot = "snapshot"
        static let macPublishedAt = "macPublishedAt"
        static let macAppVersion = "macAppVersion"
    }

    private static let enabledDefaultsKey = "cloudSyncEnabledV1"

    private let snapshotFileURL: URL
    private let workQueue = DispatchQueue(label: "com.codex.creditmenubar.cloudsync", qos: .utility)
    private var uploadInFlight = false
    private var uploadQueuedWhileInFlight = false

    /// Called on the main thread whenever status changes; the app delegate
    /// re-renders the 원격 동기화 menu items from the properties below.
    var onStatusChange: (() -> Void)?

    private(set) var lastSuccessAt: Date?
    private(set) var lastFailureAt: Date?
    /// Action-first advice for the last failure, shown as menu tooltip.
    private(set) var lastFailureAdvice: String?

    /// The app binary must be signed with the iCloud container entitlement
    /// before CloudKit will accept any call. Checked once via the code
    /// signature so an unsigned developer build reports a precise reason
    /// instead of an opaque CloudKit error.
    let hasCloudKitEntitlement: Bool

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledDefaultsKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledDefaultsKey)
            notifyStatusChange()
        }
    }

    init(snapshotFileURL: URL) {
        self.snapshotFileURL = snapshotFileURL
        self.hasCloudKitEntitlement = Self.checkEntitlement()
    }

    private static func checkEntitlement() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                  task,
                  "com.apple.developer.icloud-container-identifiers" as CFString,
                  nil
              ),
              let identifiers = value as? [String] else {
            return false
        }
        return identifiers.contains(containerIdentifier)
    }

    /// Fire-and-forget upload after a successful local publish.
    func uploadIfEnabled(trigger: String) {
        guard isEnabled else { return }
        upload(trigger: trigger)
    }

    /// The menu's "지금 동기화": runs even while the automatic toggle is off
    /// so a one-off push never requires flipping settings.
    func uploadNow() {
        upload(trigger: "manual")
    }

    private func upload(trigger: String) {
        guard hasCloudKitEntitlement else {
            recordFailure("앱이 iCloud 컨테이너 서명 없이 빌드되었습니다. Apple Developer 계정에서 iCloud.com.armsone.ccmb 컨테이너를 등록하고 entitlement를 포함해 다시 서명하세요.")
            return
        }
        workQueue.async { [weak self] in
            guard let self else { return }
            if self.uploadInFlight {
                // The next run re-reads the file, so one queued pass carries
                // every publish that happened while this one was in flight.
                self.uploadQueuedWhileInFlight = true
                return
            }
            self.uploadInFlight = true
            self.performUpload()
        }
    }

    /// Runs on `workQueue`. Fetches the fixed record (creating it on first
    /// run), replaces its fields with the current file contents, and saves.
    private func performUpload() {
        let data: Data
        do {
            data = try Data(contentsOf: snapshotFileURL)
        } catch {
            finishUpload(advice: "CCMB가 아직 사용량 스냅샷을 저장하지 않았습니다. 잠시 뒤 사용량 갱신 후 다시 시도하세요.")
            return
        }

        let database = CKContainer(identifier: Self.containerIdentifier).privateCloudDatabase
        let recordID = CKRecord.ID(recordName: Self.recordName)
        database.fetch(withRecordID: recordID) { [weak self] existingRecord, fetchError in
            guard let self else { return }
            if let fetchError, !Self.isUnknownItem(fetchError) {
                self.finishUpload(advice: Self.advice(for: fetchError))
                return
            }
            let record = existingRecord ?? CKRecord(recordType: Self.recordType, recordID: recordID)
            record[Field.schemaVersion] = 1 as Int64
            record[Field.snapshot] = data
            record[Field.macPublishedAt] = Date()
            record[Field.macAppVersion] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"

            database.save(record) { _, saveError in
                self.finishUpload(advice: saveError.map(Self.advice(for:)))
            }
        }
    }

    private static func isUnknownItem(_ error: Error) -> Bool {
        (error as? CKError)?.code == .unknownItem
    }

    private static func advice(for error: Error) -> String {
        guard let ckError = error as? CKError else {
            return "잠시 뒤 ‘지금 동기화’를 다시 누르세요. 오류: \(error.localizedDescription)"
        }
        // .accountTemporarilyUnavailable is macOS 12+ only; the package's
        // deployment target is older, so it is matched behind a gate.
        if #available(macOS 12.0, *), ckError.code == .accountTemporarilyUnavailable {
            return "시스템 설정에서 iPhone과 같은 Apple ID로 iCloud에 로그인한 뒤 ‘지금 동기화’를 누르세요."
        }
        switch ckError.code {
        case .notAuthenticated:
            return "시스템 설정에서 iPhone과 같은 Apple ID로 iCloud에 로그인한 뒤 ‘지금 동기화’를 누르세요."
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy:
            return "네트워크 연결을 확인한 뒤 ‘지금 동기화’를 누르세요. 다음 사용량 갱신 때도 자동으로 다시 시도합니다."
        case .badContainer, .missingEntitlement, .permissionFailure, .badDatabase:
            return "Apple Developer 계정에서 iCloud.com.armsone.ccmb 컨테이너 등록과 서명 설정이 필요합니다."
        case .quotaExceeded:
            return "iCloud 저장 공간이 가득 찼습니다. iCloud 공간을 확보한 뒤 다시 시도하세요."
        case .serverRecordChanged:
            // Only this Mac writes the record, so a conflict means two CCMB
            // instances raced; the next publish resolves it.
            return "다음 사용량 갱신 때 자동으로 다시 업로드합니다."
        default:
            return "잠시 뒤 ‘지금 동기화’를 다시 누르세요. iCloud 오류: \(ckError.localizedDescription)"
        }
    }

    /// `advice == nil` means success. Always ends on the main thread so menu
    /// updates never race.
    private func finishUpload(advice: String?) {
        workQueue.async { [weak self] in
            guard let self else { return }
            self.uploadInFlight = false
            let rerun = self.uploadQueuedWhileInFlight
            self.uploadQueuedWhileInFlight = false
            DispatchQueue.main.async {
                if let advice {
                    self.lastFailureAt = Date()
                    self.lastFailureAdvice = advice
                } else {
                    self.lastSuccessAt = Date()
                    self.lastFailureAt = nil
                    self.lastFailureAdvice = nil
                }
                self.onStatusChange?()
            }
            if rerun {
                self.uploadInFlight = true
                self.performUpload()
            }
        }
    }

    private func recordFailure(_ advice: String) {
        DispatchQueue.main.async {
            self.lastFailureAt = Date()
            self.lastFailureAdvice = advice
            self.onStatusChange?()
        }
    }

    private func notifyStatusChange() {
        if Thread.isMainThread {
            onStatusChange?()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.onStatusChange?()
            }
        }
    }
}
