import Darwin
import Foundation

/// Reads the home NAS's four-service usage snapshot over the existing,
/// already-authenticated `hanstree-dev` SSH alias — this app never collects
/// a NAS password, never opens a browser session, and never touches any
/// SSH key material itself; it only spawns the system `/usr/bin/ssh` with a
/// fixed argv and lets the user's existing `~/.ssh/config` entry resolve
/// host/key/user. No shell is involved, so nothing here is interpretable as
/// a command injection vector: the remote command string is a fixed
/// literal, never built from any dynamic/user-controlled input.
enum NASConfig {
    static let sshExecutablePath = "/usr/bin/ssh"
    static let sshAlias = "hanstree-dev"
    static let remoteCommand = "python3 /workspace/web-app/usage.py --snapshot-json"
    static let remoteHistoryCommand = "python3 /workspace/web-app/usage.py --history-json"
    /// 24-hour history (schemaVersion 3). A separate fixed command so the
    /// strict 40-point v2 command above keeps working for older apps.
    static let remoteHistory24hCommand = "python3 /workspace/web-app/ccmb-history-24h.py"

    /// Batch mode (never prompts), strict host key checking against the
    /// existing known_hosts entry, no agent/X11/port forwarding of any kind,
    /// and a bounded connect timeout. No `-F`/`-i` is passed, so the user's
    /// own default `~/.ssh/config` resolves the alias and its key.
    static let sshOptions: [String] = [
        "-o", "BatchMode=yes",
        "-o", "StrictHostKeyChecking=yes",
        "-o", "ForwardAgent=no",
        "-o", "ForwardX11=no",
        "-o", "ClearAllForwardings=yes",
        "-o", "ConnectTimeout=10",
    ]

    static func sshArguments(remoteCommand: String) -> [String] {
        sshOptions + [sshAlias, remoteCommand]
    }
}

enum NASFetchError: Error, Equatable {
    /// `/usr/bin/ssh` could not be launched at all.
    case sshUnavailable
    /// ssh itself failed (exit 255): connection, host key, or key auth.
    case connectionFailed
    case timeout
    case cancelled
    case outputTooLarge
    /// The child exited but its stdout never reached EOF inside the drain
    /// grace period; the partial bytes are discarded, never parsed.
    case incompleteOutput
    /// The remote helper exited non-zero without a recognizable structured
    /// error body.
    case remoteExit(Int32)
    case emptyResponse
    case unreadableResponse

    var label: String {
        switch self {
        case .sshUnavailable: return "SSH 사용 불가"
        case .connectionFailed: return "NAS SSH 연결 실패"
        case .timeout: return "NAS 응답 시간 초과"
        case .cancelled: return "NAS 조회 취소됨"
        case .outputTooLarge: return "NAS 응답 크기 초과"
        case .incompleteOutput: return "NAS 응답 불완전"
        case .remoteExit(let status): return "NAS 도구 종료 코드 \(status)"
        case .emptyResponse: return "NAS 빈 응답"
        case .unreadableResponse: return "NAS 응답 해석 실패"
        }
    }
}

/// What the child produced once it has really exited and both pipes were
/// drained to EOF.
struct NASProcessOutput: Equatable {
    let exitStatus: Int32
    let terminatedBySignal: Bool
    let stdout: Data
    /// stderr is drained (so a chatty child can never block on a full pipe)
    /// but never kept: only its size is reported for diagnostics.
    let stderrByteCount: Int
}

/// Spawns one child with a fixed argv (never a shell, never a user-editable
/// command string), drains stdout (bounded) and stderr (discarded) to EOF on
/// their own readability handlers, and reports exactly once — only after the
/// child has actually exited and been reaped. Timeout and task cancellation
/// send SIGTERM, then SIGKILL after a short grace, and still wait for the
/// real exit before resuming the caller, so no `ssh` process is ever leaked
/// behind a finished request.
struct NASSSHTransport {
    static let maximumOutputBytes = 256 * 1024
    /// Stored-file reads are fast; 25 s comfortably covers the 10 s connect
    /// timeout plus remote Python start-up without leaving a hung request
    /// around for minutes.
    static let processTimeoutSeconds: TimeInterval = 25
    static let killGraceSeconds: TimeInterval = 2
    /// After the child is reaped, how long to wait for a pipe EOF that a
    /// lingering grandchild could still be holding open.
    static let drainGraceSeconds: TimeInterval = 2

    /// Production entry point: always `/usr/bin/ssh` with the fixed option
    /// list and alias. Only the two fixed remote commands in `NASConfig` are
    /// ever passed here.
    static func run(command: String) async throws -> NASProcessOutput {
        try await runProcess(
            executableURL: URL(fileURLWithPath: NASConfig.sshExecutablePath),
            arguments: NASConfig.sshArguments(remoteCommand: command)
        )
    }

    /// Internal process runner. Tests inject a local stand-in executable
    /// (e.g. `/bin/sh -c '<fixture>'`) to exercise short/late/oversized
    /// output, stderr floods, timeout, cancellation and an already-gone
    /// child; production code only reaches this through `run(command:)`.
    static func runProcess(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval = processTimeoutSeconds,
        maximumOutputBytes: Int = maximumOutputBytes,
        killGrace: TimeInterval = killGraceSeconds,
        drainGrace: TimeInterval = drainGraceSeconds
    ) async throws -> NASProcessOutput {
        let run = NASProcessRun(
            executableURL: executableURL,
            arguments: arguments,
            timeout: timeout,
            maximumOutputBytes: maximumOutputBytes,
            killGrace: killGrace,
            drainGrace: drainGrace
        )
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                run.start(continuation: continuation)
            }
        } onCancel: {
            run.cancel()
        }
    }
}

/// One child process run. Every mutable field is guarded by `lock`; the
/// continuation is resumed at most once, from `finishIfReady`/`finish`.
private final class NASProcessRun: @unchecked Sendable {
    private enum Stream { case stdout, stderr }

    private let lock = NSLock()
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let timeout: TimeInterval
    private let maximumOutputBytes: Int
    private let killGrace: TimeInterval
    private let drainGrace: TimeInterval
    private let queue = DispatchQueue(label: "ccmb.nas.process", qos: .utility)

    private var continuation: CheckedContinuation<NASProcessOutput, Error>?
    private var launched = false
    private var finished = false
    private var cancelRequested = false
    private var timedOut = false
    private var outputOverflowed = false
    private var terminationRequested = false
    private var exited = false
    private var exitStatus: Int32 = 0
    private var terminatedBySignal = false
    private var stdoutData = Data()
    private var stderrByteCount = 0
    private var stdoutEOF = false
    private var stderrEOF = false

    init(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        maximumOutputBytes: Int,
        killGrace: TimeInterval,
        drainGrace: TimeInterval
    ) {
        self.timeout = timeout
        self.maximumOutputBytes = maximumOutputBytes
        self.killGrace = killGrace
        self.drainGrace = drainGrace
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    func start(continuation: CheckedContinuation<NASProcessOutput, Error>) {
        lock.lock()
        self.continuation = continuation
        if cancelRequested {
            // Cancelled before launch: nothing was spawned, nothing to reap.
            lock.unlock()
            closeReadEnds()
            finish(.failure(.cancelled))
            return
        }
        lock.unlock()

        install(stdoutPipe.fileHandleForReading, stream: .stdout)
        install(stderrPipe.fileHandleForReading, stream: .stderr)
        process.terminationHandler = { [self] finishedProcess in
            lock.lock()
            exited = true
            exitStatus = finishedProcess.terminationStatus
            terminatedBySignal = finishedProcess.terminationReason == .uncaughtSignal
            lock.unlock()
            // Give a lingering pipe holder a bounded window to close; the
            // normal path finishes much earlier through `finishIfReady`.
            queue.asyncAfter(deadline: .now() + drainGrace) { [self] in
                finishAfterDrainDeadline()
            }
            finishIfReady()
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            closeReadEnds()
            finish(.failure(.sshUnavailable))
            return
        }

        lock.lock()
        launched = true
        let cancelledDuringLaunch = cancelRequested
        lock.unlock()
        if cancelledDuringLaunch {
            requestTermination()
        }
        queue.asyncAfter(deadline: .now() + timeout) { [self] in
            lock.lock()
            let shouldTimeOut = !exited && !finished
            if shouldTimeOut { timedOut = true }
            lock.unlock()
            if shouldTimeOut { requestTermination() }
        }
    }

    func cancel() {
        lock.lock()
        cancelRequested = true
        let canSignal = launched && !exited
        lock.unlock()
        if canSignal { requestTermination() }
    }

    /// SIGTERM now, SIGKILL after `killGrace` if the child is still alive.
    /// Never signals a child that has already been reaped.
    private func requestTermination() {
        lock.lock()
        guard launched, !exited, !terminationRequested else {
            lock.unlock()
            return
        }
        terminationRequested = true
        lock.unlock()
        if process.isRunning { process.terminate() }
        queue.asyncAfter(deadline: .now() + killGrace) { [self] in
            lock.lock()
            let stillAlive = !exited
            lock.unlock()
            if stillAlive, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    private func install(_ handle: FileHandle, stream: Stream) {
        handle.readabilityHandler = { [self] handle in
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            let count = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(handle.fileDescriptor, raw.baseAddress, raw.count)
            }
            if count > 0 {
                append(Data(buffer[0..<count]), from: stream)
                return
            }
            if count < 0, errno == EINTR || errno == EAGAIN { return }
            // 0 = EOF; any other read error also ends this stream.
            handle.readabilityHandler = nil
            markEOF(stream)
        }
    }

    private func append(_ chunk: Data, from stream: Stream) {
        lock.lock()
        var overflowedNow = false
        switch stream {
        case .stdout:
            if outputOverflowed {
                break // keep draining so the child never blocks; discard
            } else if stdoutData.count + chunk.count > maximumOutputBytes {
                outputOverflowed = true
                overflowedNow = true
                stdoutData = Data()
            } else {
                stdoutData.append(chunk)
            }
        case .stderr:
            stderrByteCount += chunk.count
        }
        lock.unlock()
        // Oversized output can never be accepted; stop the child early
        // instead of draining an unbounded stream to the end.
        if overflowedNow { requestTermination() }
    }

    private func markEOF(_ stream: Stream) {
        lock.lock()
        switch stream {
        case .stdout: stdoutEOF = true
        case .stderr: stderrEOF = true
        }
        lock.unlock()
        finishIfReady()
    }

    private func finishIfReady() {
        lock.lock()
        let ready = exited && stdoutEOF && stderrEOF && !finished
        lock.unlock()
        guard ready else { return }
        closeReadEnds()
        finish(result())
    }

    private func finishAfterDrainDeadline() {
        lock.lock()
        let pending = !finished
        let stdoutComplete = stdoutEOF
        lock.unlock()
        guard pending else { return }
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        closeReadEnds()
        // stderr still open is only diagnostics; stdout without EOF means
        // the response may be cut short and is never parsed.
        finish(stdoutComplete ? result() : outcomeOverride() ?? .failure(.incompleteOutput))
    }

    /// Timeout/cancel/oversize take precedence over whatever the child
    /// printed before it was stopped.
    private func outcomeOverride() -> Result<NASProcessOutput, NASFetchError>? {
        lock.lock()
        defer { lock.unlock() }
        if outputOverflowed { return .failure(.outputTooLarge) }
        if cancelRequested { return .failure(.cancelled) }
        if timedOut { return .failure(.timeout) }
        return nil
    }

    private func result() -> Result<NASProcessOutput, NASFetchError> {
        if let override = outcomeOverride() { return override }
        lock.lock()
        defer { lock.unlock() }
        return .success(NASProcessOutput(
            exitStatus: exitStatus,
            terminatedBySignal: terminatedBySignal,
            stdout: stdoutData,
            stderrByteCount: stderrByteCount
        ))
    }

    private func closeReadEnds() {
        try? stdoutPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForReading.close()
    }

    private func finish(_ result: Result<NASProcessOutput, NASFetchError>) {
        lock.lock()
        guard !finished, let continuation else {
            lock.unlock()
            return
        }
        finished = true
        self.continuation = nil
        lock.unlock()
        // Break the Process → handler → run reference cycle.
        process.terminationHandler = nil
        switch result {
        case .success(let output): continuation.resume(returning: output)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }
}

/// Fetches the stored four-service snapshot (and, separately, the stored
/// history) over SSH. This is a read of whatever the NAS already has on
/// disk — it never asks the remote side to perform a fresh collection, so
/// there is no app-controlled "refresh" happening on the NAS from this
/// path. Neither method ever falls back to a local collector.
struct NASSnapshotClient {
    typealias Runner = (String) async throws -> NASProcessOutput

    private let runner: Runner

    init(runner: @escaping Runner = { try await NASSSHTransport.run(command: $0) }) {
        self.runner = runner
    }

    /// Returns raw bytes of the remote `--snapshot-json` output. The helper
    /// always exits 0 with a v2 envelope (an "unavailable" one when nothing
    /// is stored); any non-zero exit is a transport/helper failure.
    func fetchSnapshot() async throws -> Data {
        let output = try await runChecked(NASConfig.remoteCommand)
        guard output.exitStatus == 0 else {
            throw output.exitStatus == 255 ? NASFetchError.connectionFailed : NASFetchError.remoteExit(output.exitStatus)
        }
        guard !output.stdout.isEmpty else { throw NASFetchError.emptyResponse }
        return output.stdout
    }

    /// Runs the history helper and classifies the result. A structured
    /// `{ok:false,error:{code,message}}` body (the helper exits 1 for it) is
    /// reported as that error — never as an empty history.
    ///
    /// The 24-hour (v3) helper is asked first. When the NAS does not have it
    /// or it reports anything but a history, the strict v2 helper (newest 40
    /// points, about two hours) answers instead — shown as partial coverage,
    /// never padded. A failed SSH connection is not retried on the second
    /// command.
    func fetchHistory() async throws -> NASHistoryReadResult {
        if let wide = try await fetchHistory(command: NASConfig.remoteHistory24hCommand),
           case .history = wide {
            return wide
        }
        guard let narrow = try await fetchHistory(command: NASConfig.remoteHistoryCommand) else {
            throw NASFetchError.emptyResponse
        }
        return narrow
    }

    /// `nil` only when a non-255 failure left nothing to classify, which the
    /// 24-hour attempt treats as "try the v2 helper".
    private func fetchHistory(command: String) async throws -> NASHistoryReadResult? {
        let output = try await runChecked(command)
        if output.exitStatus == 255 { throw NASFetchError.connectionFailed }
        if output.exitStatus != 0, output.stdout.isEmpty {
            if command == NASConfig.remoteHistory24hCommand { return nil }
            throw NASFetchError.remoteExit(output.exitStatus)
        }
        return NASHistoryV2Core.interpret(stdout: output.stdout, exitStatus: output.exitStatus)
    }

    private func runChecked(_ command: String) async throws -> NASProcessOutput {
        do {
            return try await runner(command)
        } catch let error as NASFetchError {
            throw error
        } catch is CancellationError {
            throw NASFetchError.cancelled
        } catch {
            throw NASFetchError.sshUnavailable
        }
    }
}
