import Foundation

/// Mirrors the local usage snapshot into a user-selected File Provider folder.
/// Dropbox, Google Drive, iCloud Drive, OneDrive, and ordinary folders all
/// arrive as URLs through the same macOS file-provider surface, so CCMB never
/// needs provider OAuth tokens or SDKs.
final class RemoteFolderPublisher {
    static let fileName = "CCMB-usage-v1.json"

    private static let bookmarkDefaultsKey = "remoteFolderBookmarkV1"
    private static let nameDefaultsKey = "remoteFolderDisplayNameV1"

    private let snapshotFileURL: URL
    private let queue = DispatchQueue(label: "com.codex.creditmenubar.remote-folder", qos: .utility)

    var onStatusChange: (() -> Void)?
    private(set) var lastSuccessAt: Date?
    private(set) var lastFailureAdvice: String?

    var selectedFolderName: String? {
        UserDefaults.standard.string(forKey: Self.nameDefaultsKey)
    }

    var isConfigured: Bool {
        UserDefaults.standard.data(forKey: Self.bookmarkDefaultsKey) != nil
    }

    init(snapshotFileURL: URL) {
        self.snapshotFileURL = snapshotFileURL
    }

    func setFolder(_ url: URL) throws {
        let bookmark = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: [.nameKey],
            relativeTo: nil
        )
        UserDefaults.standard.set(bookmark, forKey: Self.bookmarkDefaultsKey)
        UserDefaults.standard.set(url.lastPathComponent, forKey: Self.nameDefaultsKey)
        lastFailureAdvice = nil
        notifyStatusChange()
        publishIfConfigured()
    }

    func clearFolder() {
        UserDefaults.standard.removeObject(forKey: Self.bookmarkDefaultsKey)
        UserDefaults.standard.removeObject(forKey: Self.nameDefaultsKey)
        lastSuccessAt = nil
        lastFailureAdvice = nil
        notifyStatusChange()
    }

    func publishIfConfigured() {
        guard let bookmark = UserDefaults.standard.data(forKey: Self.bookmarkDefaultsKey) else { return }
        queue.async { [weak self] in
            self?.publish(using: bookmark)
        }
    }

    private func publish(using bookmark: Data) {
        var stale = false
        let folderURL: URL
        do {
            folderURL = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
        } catch {
            finish(advice: "Dropbox·Google Drive 또는 파일 앱에서 동기화 폴더를 다시 선택하세요. 이전 폴더 권한을 열 수 없습니다.")
            return
        }

        let didStart = folderURL.startAccessingSecurityScopedResource()
        defer { if didStart { folderURL.stopAccessingSecurityScopedResource() } }

        do {
            let data = try Data(contentsOf: snapshotFileURL)
            try data.write(to: folderURL.appendingPathComponent(Self.fileName), options: .atomic)
            if stale {
                let renewed = try folderURL.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: [.nameKey],
                    relativeTo: nil
                )
                UserDefaults.standard.set(renewed, forKey: Self.bookmarkDefaultsKey)
            }
            finish(advice: nil)
        } catch {
            finish(advice: "선택한 클라우드 폴더가 온라인인지 확인하고 다시 동기화하세요. CCMB-usage-v1.json을 저장하지 못했습니다.")
        }
    }

    private func finish(advice: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let advice {
                self.lastFailureAdvice = advice
            } else {
                self.lastSuccessAt = Date()
                self.lastFailureAdvice = nil
            }
            self.onStatusChange?()
        }
    }

    private func notifyStatusChange() {
        DispatchQueue.main.async { [weak self] in self?.onStatusChange?() }
    }
}
