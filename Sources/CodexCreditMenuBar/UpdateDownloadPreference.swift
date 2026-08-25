import Foundation

@MainActor
final class UpdateDownloadPreference {
    private let read: () -> Bool
    private let write: (Bool) -> Void
    private(set) var isEnabled: Bool

    init(read: @escaping () -> Bool, write: @escaping (Bool) -> Void) {
        self.read = read
        isEnabled = read()
        self.write = write
    }

    func setEnabled(_ enabled: Bool) {
        write(enabled)
        isEnabled = read()
    }

    var statusText: String {
        isEnabled ? "자동 다운로드 켬" : "자동 다운로드 끔"
    }
}
