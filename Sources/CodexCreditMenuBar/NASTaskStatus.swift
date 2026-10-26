import Foundation

/// Aggregate task counts published by the NAS (`--task-status-json`).
struct NASTaskStatusCounts: Equatable {
    let running: Int
    let preparing: Int
    let waiting: Int
    /// Server-side capture time.
    let capturedAt: Date
}

enum NASTaskStatusParser {
    /// Strict decode: schema 1, non-negative integer counts, valid timestamp.
    /// Anything else is `nil` — never a zero-filled value.
    static func parse(_ data: Data, now: Date = Date()) -> NASTaskStatusCounts? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        guard let schema = integer(object["schemaVersion"]), schema == 1,
              let running = integer(object["running"]), running >= 0,
              let preparing = integer(object["preparing"]), preparing >= 0,
              let waiting = integer(object["waiting"]), waiting >= 0,
              let stamp = object["capturedAt"] as? String,
              let capturedAt = date(from: stamp),
              capturedAt <= now.addingTimeInterval(300)
        else { return nil }
        return NASTaskStatusCounts(running: running, preparing: preparing, waiting: waiting, capturedAt: capturedAt)
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double == double.rounded(), abs(double) < 1e9 else { return nil }
        return Int(double)
    }

    private static func date(from text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}

/// What the header pill shows.
enum NASTaskStatusDisplay: Equatable {
    /// Local Mac mode: the NAS task counts are not shown.
    case hidden
    /// No answer yet.
    case checking
    /// The last read failed and nothing earlier is available.
    case unavailable
    /// Counts from the NAS; `stale` when older than the refresh cadence allows
    /// and `failed` when the most recent read failed (last value retained).
    case counts(NASTaskStatusCounts, fetchedAt: Date, stale: Bool, failed: Bool)
}

/// Fetches the aggregate over the existing safe SSH transport. Main-actor
/// state: one request in flight, throttled, last success retained.
@MainActor
final class NASTaskStatusStore {
    /// The NAS refresh runs every 3 minutes; the server heartbeat (60s) is
    /// only its own freshness, so the app tolerates one missed cycle.
    static let staleAfter: TimeInterval = 240

    private var lastCounts: NASTaskStatusCounts?
    private var lastFetchedAt: Date?
    private var lastFailed = false
    private var lastAttemptAt: Date?
    private var inFlight: Task<Void, Never>?
    private var attemptToken = 0

    func display(now: Date = Date()) -> NASTaskStatusDisplay {
        if let counts = lastCounts, let fetchedAt = lastFetchedAt {
            let stale = now.timeIntervalSince(counts.capturedAt) > Self.staleAfter
            return .counts(counts, fetchedAt: fetchedAt, stale: stale, failed: lastFailed)
        }
        return lastFailed ? .unavailable : .checking
    }

    /// `completion` runs on the main actor after a finished attempt (not for
    /// skipped or cancelled ones).
    func fetchIfDue(minimumInterval: TimeInterval, completion: @escaping @MainActor () -> Void) {
        guard inFlight == nil else { return }
        if let last = lastAttemptAt, Date().timeIntervalSince(last) < minimumInterval { return }
        lastAttemptAt = Date()
        attemptToken += 1
        let token = attemptToken
        inFlight = Task { @MainActor [weak self] in
            var parsed: NASTaskStatusCounts?
            do {
                let output = try await NASSSHTransport.run(command: NASConfig.remoteTaskStatusCommand)
                if output.exitStatus == 0 { parsed = NASTaskStatusParser.parse(output.stdout) }
            } catch {
                parsed = nil
            }
            guard let self, self.attemptToken == token, !Task.isCancelled else { return }
            self.inFlight = nil
            if let parsed {
                self.lastCounts = parsed
                self.lastFetchedAt = Date()
                self.lastFailed = false
            } else {
                self.lastFailed = true
            }
            completion()
        }
    }

    /// Drops any in-flight request (data source switched away from NAS).
    func cancelInFlight() {
        attemptToken += 1
        inFlight?.cancel()
        inFlight = nil
    }
}
