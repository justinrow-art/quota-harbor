import Darwin
import Foundation

enum ClaudeAuthState: Equatable, Sendable {
    case connected
    case notConnected
    case failed(code: ClaudeAuthFailureCode)
}

enum ClaudeAuthFailureCode: String, Equatable, Sendable {
    case invalidExecutable = "invalid-executable"
    case commandFailed = "command-failed"
    case outputTooLarge = "output-too-large"
    case invalidResponse = "invalid-response"
}

struct ClaudeAuthCommandRequest: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
    let timeout: Duration
    let maximumStdoutBytes: Int
    let maximumStderrBytes: Int
    let environment: [String: String]
}

struct ClaudeAuthCommandResult: Equatable, Sendable {
    let exitCode: Int32
    let stdout: Data
    let stderr: Data
}

protocol ClaudeAuthCommandRunning: Sendable {
    func run(
        _ request: ClaudeAuthCommandRequest
    ) async throws -> ClaudeAuthCommandResult
}

enum ClaudeAuthProcessPipe: CaseIterable, Hashable, Sendable {
    case standardOutput
    case standardError
}

enum ClaudeAuthProcessExit: Equatable, Sendable {
    case exit(Int32)
    case signal
}

enum ClaudeAuthProcessRunnerError: String, Error, Equatable, Sendable {
    case launchFailed = "launch-failed"
    case outputTooLarge = "output-too-large"
    case timedOut = "timed-out"
    case cancelled
    case ioFailed = "io-failed"
    case abnormalTermination = "abnormal-termination"
}

protocol ClaudeAuthProcessSession: Sendable {
    func launch() async throws
    func readChunk(
        from pipe: ClaudeAuthProcessPipe,
        maximumBytes: Int
    ) async throws -> Data?
    func waitForExit(timeout: Duration?) async -> ClaudeAuthProcessExit?
    func closeOutputHandles() async
    func sendTerminate() async
    func sendKill() async
}

protocol ClaudeAuthProcessSessionCreating: Sendable {
    func makeSession(
        for request: ClaudeAuthCommandRequest
    ) throws -> any ClaudeAuthProcessSession
}

protocol ClaudeAuthProcessSleeping: Sendable {
    func sleep(for duration: Duration) async throws
}

struct ClaudeAuthProcessRunner: ClaudeAuthCommandRunning, Sendable {
    private enum Event: Sendable {
        case output(ClaudeAuthProcessPipe, Data)
        case exit(ClaudeAuthProcessExit)
        case timeout
    }

    private let sessionFactory: any ClaudeAuthProcessSessionCreating
    private let sleeper: any ClaudeAuthProcessSleeping
    private let terminationGracePeriod: Duration

    init(
        sessionFactory: any ClaudeAuthProcessSessionCreating,
        sleeper: any ClaudeAuthProcessSleeping,
        terminationGracePeriod: Duration
    ) {
        self.sessionFactory = sessionFactory
        self.sleeper = sleeper
        self.terminationGracePeriod = terminationGracePeriod
    }

    func run(
        _ request: ClaudeAuthCommandRequest
    ) async throws -> ClaudeAuthCommandResult {
        guard !Task.isCancelled else {
            throw ClaudeAuthProcessRunnerError.cancelled
        }

        let session: any ClaudeAuthProcessSession
        do {
            session = try sessionFactory.makeSession(for: request)
        } catch {
            throw ClaudeAuthProcessRunnerError.launchFailed
        }
        let cleanup = ClaudeAuthProcessCleanup(
            session: session,
            terminationGracePeriod: terminationGracePeriod
        )
        return try await withTaskCancellationHandler {
            do {
                try await session.launch()
            } catch {
                await cleanup.finish()
                throw Task.isCancelled
                    ? ClaudeAuthProcessRunnerError.cancelled
                    : ClaudeAuthProcessRunnerError.launchFailed
            }
            guard !Task.isCancelled else {
                await cleanup.finish()
                throw ClaudeAuthProcessRunnerError.cancelled
            }
            return try await collectOutput(
                request: request,
                session: session,
                cleanup: cleanup
            )
        } onCancel: {
            cleanup.start()
        }
    }

    private func collectOutput(
        request: ClaudeAuthCommandRequest,
        session: any ClaudeAuthProcessSession,
        cleanup: ClaudeAuthProcessCleanup
    ) async throws -> ClaudeAuthCommandResult {
        try await withThrowingTaskGroup(of: Event.self) { group in
            group.addTask {
                .output(
                    .standardOutput,
                    try await drain(
                        .standardOutput,
                        maximumBytes: request.maximumStdoutBytes,
                        from: session
                    )
                )
            }
            group.addTask {
                .output(
                    .standardError,
                    try await drain(
                        .standardError,
                        maximumBytes: request.maximumStderrBytes,
                        from: session
                    )
                )
            }
            group.addTask {
                guard let processExit = await session.waitForExit(timeout: nil) else {
                    throw ClaudeAuthProcessRunnerError.ioFailed
                }
                return .exit(processExit)
            }
            group.addTask {
                try await sleeper.sleep(for: request.timeout)
                try Task.checkCancellation()
                return .timeout
            }

            do {
                var stdout: Data?
                var stderr: Data?
                var exitCode: Int32?
                while let event = try await group.next() {
                    switch event {
                    case let .output(pipe, data):
                        switch pipe {
                        case .standardOutput:
                            stdout = data
                        case .standardError:
                            stderr = data
                        }
                    case let .exit(processExit):
                        switch processExit {
                        case let .exit(status):
                            exitCode = status
                        case .signal:
                            group.cancelAll()
                            await cleanup.closeAfterExit()
                            throw ClaudeAuthProcessRunnerError
                                .abnormalTermination
                        }
                    case .timeout:
                        throw ClaudeAuthProcessRunnerError.timedOut
                    }

                    if let stdout, let stderr, let exitCode {
                        try Task.checkCancellation()
                        group.cancelAll()
                        await cleanup.closeAfterExit()
                        return ClaudeAuthCommandResult(
                            exitCode: exitCode,
                            stdout: stdout,
                            stderr: stderr
                        )
                    }
                }
                throw ClaudeAuthProcessRunnerError.ioFailed
            } catch {
                group.cancelAll()
                await cleanup.finish()
                if Task.isCancelled || error is CancellationError {
                    throw ClaudeAuthProcessRunnerError.cancelled
                }
                throw (error as? ClaudeAuthProcessRunnerError) ?? .ioFailed
            }
        }
    }

    private func drain(
        _ pipe: ClaudeAuthProcessPipe,
        maximumBytes: Int,
        from session: any ClaudeAuthProcessSession
    ) async throws -> Data {
        guard maximumBytes >= 0 else {
            throw ClaudeAuthProcessRunnerError.ioFailed
        }

        var output = Data()
        output.reserveCapacity(maximumBytes)
        while true {
            let remainingBytes = maximumBytes - output.count
            let readSize = max(1, min(4_096, remainingBytes))
            guard let chunk = try await session.readChunk(
                from: pipe,
                maximumBytes: readSize
            ), !chunk.isEmpty else {
                return output
            }
            guard chunk.count <= remainingBytes else {
                throw ClaudeAuthProcessRunnerError.outputTooLarge
            }
            output.append(chunk)
        }
    }
}

private final class ClaudeAuthProcessCleanup: @unchecked Sendable {
    private enum Action {
        case closeAfterExit
        case terminate
    }

    private let session: any ClaudeAuthProcessSession
    private let terminationGracePeriod: Duration
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    init(
        session: any ClaudeAuthProcessSession,
        terminationGracePeriod: Duration
    ) {
        self.session = session
        self.terminationGracePeriod = terminationGracePeriod
    }

    func start() {
        _ = cleanupTask(for: .terminate)
    }

    func finish() async {
        await cleanupTask(for: .terminate).value
    }

    func closeAfterExit() async {
        await cleanupTask(for: .closeAfterExit).value
    }

    private func cleanupTask(for action: Action) -> Task<Void, Never> {
        lock.lock()
        defer { lock.unlock() }
        if let task {
            return task
        }

        let session = session
        let terminationGracePeriod = terminationGracePeriod
        let task = Task.detached {
            await session.closeOutputHandles()
            guard action == .terminate else {
                return
            }
            await session.sendTerminate()
            if await session.waitForExit(
                timeout: terminationGracePeriod
            ) == nil {
                await session.sendKill()
                _ = await session.waitForExit(timeout: nil)
            }
        }
        self.task = task
        return task
    }
}

final class ClaudeAuthProcessExitLatch: @unchecked Sendable {
    private typealias Waiter = CheckedContinuation<
        ClaudeAuthProcessExit?,
        Never
    >

    private let lock = NSLock()
    private var publishedExit: ClaudeAuthProcessExit?
    private var nextWaiterID: UInt64 = 1
    private var waiters: [UInt64: Waiter] = [:]

    func publish(_ processExit: ClaudeAuthProcessExit) {
        let pendingWaiters: [Waiter] = lock.withLock {
            guard publishedExit == nil else {
                return []
            }
            publishedExit = processExit
            let pendingWaiters = Array(waiters.values)
            waiters.removeAll()
            return pendingWaiters
        }
        pendingWaiters.forEach { $0.resume(returning: processExit) }
    }

    func wait(timeout: Duration?) async -> ClaudeAuthProcessExit? {
        await withCheckedContinuation { continuation in
            let registration: (ClaudeAuthProcessExit?, UInt64?) = lock.withLock {
                if let publishedExit {
                    return (publishedExit, nil)
                }
                let waiterID = nextWaiterID
                nextWaiterID &+= 1
                waiters[waiterID] = continuation
                return (nil, waiterID)
            }

            if let processExit = registration.0 {
                continuation.resume(returning: processExit)
                return
            }
            guard let timeout, let waiterID = registration.1 else {
                return
            }
            Task.detached { [self] in
                if timeout > .zero {
                    try? await Task.sleep(for: timeout)
                }
                expire(waiterID: waiterID)
            }
        }
    }

    var hasPublishedExit: Bool {
        lock.withLock { publishedExit != nil }
    }

    private func expire(waiterID: UInt64) {
        let waiter = lock.withLock {
            waiters.removeValue(forKey: waiterID)
        }
        waiter?.resume(returning: nil)
    }
}

private actor ClaudeAuthFileHandleChunkReader {
    private let handle: FileHandle
    private var iterator: FileHandle.AsyncBytes.Iterator
    private var isClosed = false

    init(handle: FileHandle) {
        self.handle = handle
        iterator = handle.bytes.makeAsyncIterator()
    }

    func read(maximumBytes: Int) async throws -> Data? {
        guard maximumBytes > 0, !isClosed else {
            return nil
        }

        var chunk = Data()
        chunk.reserveCapacity(maximumBytes)
        do {
            while chunk.count < maximumBytes {
                guard let byte = try await nextByte() else {
                    return chunk.isEmpty ? nil : chunk
                }
                chunk.append(byte)
            }
            return chunk
        } catch {
            if isClosed {
                return chunk.isEmpty ? nil : chunk
            }
            throw ClaudeAuthProcessRunnerError.ioFailed
        }
    }

    func close() {
        guard !isClosed else {
            return
        }
        isClosed = true
        try? handle.close()
    }

    private func nextByte() async throws -> UInt8? {
        var localIterator = iterator
        let byte = try await localIterator.next()
        iterator = localIterator
        return byte
    }
}

final class ClaudeAuthFoundationProcessSession:
    ClaudeAuthProcessSession,
    @unchecked Sendable {
    private enum PendingSignal {
        case none
        case terminate
        case kill
    }

    private let process: Process
    private let stdoutReader: ClaudeAuthFileHandleChunkReader
    private let stderrReader: ClaudeAuthFileHandleChunkReader
    private let exitLatch = ClaudeAuthProcessExitLatch()
    private let lock = NSLock()
    private var childHandles: [FileHandle]
    private var launchWasAttempted = false
    private var didLaunch = false
    private var didSendTerminate = false
    private var didSendKill = false

    init(
        request: ClaudeAuthCommandRequest,
        process: Process = Process(),
        stdoutPipe: Pipe = Pipe(),
        stderrPipe: Pipe = Pipe()
    ) throws {
        let nullDescriptor = Darwin.open("/dev/null", O_RDONLY | O_CLOEXEC)
        guard nullDescriptor != -1 else {
            Self.closePipe(stdoutPipe)
            Self.closePipe(stderrPipe)
            throw ClaudeAuthProcessRunnerError.launchFailed
        }
        let inputHandle = FileHandle(
            fileDescriptor: nullDescriptor,
            closeOnDealloc: true
        )
        let ownedHandles = [
            stdoutPipe.fileHandleForReading,
            stdoutPipe.fileHandleForWriting,
            stderrPipe.fileHandleForReading,
            stderrPipe.fileHandleForWriting,
            inputHandle,
        ]
        do {
            try ownedHandles.forEach(Self.markCloseOnExec)
        } catch {
            ownedHandles.forEach { try? $0.close() }
            throw ClaudeAuthProcessRunnerError.launchFailed
        }

        self.process = process
        stdoutReader = ClaudeAuthFileHandleChunkReader(
            handle: stdoutPipe.fileHandleForReading
        )
        stderrReader = ClaudeAuthFileHandleChunkReader(
            handle: stderrPipe.fileHandleForReading
        )
        childHandles = [
            stdoutPipe.fileHandleForWriting,
            stderrPipe.fileHandleForWriting,
            inputHandle,
        ]

        process.executableURL = request.executableURL
        process.arguments = request.arguments
        process.environment = request.environment
        process.standardInput = inputHandle
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let exitLatch = exitLatch
        process.terminationHandler = { process in
            switch process.terminationReason {
            case .exit:
                exitLatch.publish(.exit(process.terminationStatus))
            case .uncaughtSignal:
                exitLatch.publish(.signal)
            @unknown default:
                exitLatch.publish(.signal)
            }
        }
    }

    func launch() async throws {
        let mayLaunch = lock.withLock {
            guard !launchWasAttempted else {
                return false
            }
            launchWasAttempted = true
            return true
        }
        guard mayLaunch else {
            throw ClaudeAuthProcessRunnerError.launchFailed
        }

        do {
            try process.run()
            let pendingSignal = lock.withLock {
                didLaunch = true
                if didSendKill {
                    return PendingSignal.kill
                }
                if didSendTerminate {
                    return PendingSignal.terminate
                }
                return PendingSignal.none
            }
            closeChildHandles()
            if !exitLatch.hasPublishedExit {
                switch pendingSignal {
                case .none:
                    break
                case .terminate:
                    process.terminate()
                case .kill:
                    _ = Darwin.kill(process.processIdentifier, SIGKILL)
                }
            }
        } catch {
            closeChildHandles()
            await closeOutputHandles()
            exitLatch.publish(.signal)
            throw ClaudeAuthProcessRunnerError.launchFailed
        }
    }

    func readChunk(
        from pipe: ClaudeAuthProcessPipe,
        maximumBytes: Int
    ) async throws -> Data? {
        guard maximumBytes > 0 else {
            throw ClaudeAuthProcessRunnerError.ioFailed
        }
        switch pipe {
        case .standardOutput:
            return try await stdoutReader.read(maximumBytes: maximumBytes)
        case .standardError:
            return try await stderrReader.read(maximumBytes: maximumBytes)
        }
    }

    func waitForExit(
        timeout: Duration?
    ) async -> ClaudeAuthProcessExit? {
        await exitLatch.wait(timeout: timeout)
    }

    func closeOutputHandles() async {
        async let closeStdout: Void = stdoutReader.close()
        async let closeStderr: Void = stderrReader.close()
        _ = await (closeStdout, closeStderr)
    }

    func sendTerminate() async {
        let shouldTerminate = lock.withLock {
            guard !didSendTerminate,
                  !exitLatch.hasPublishedExit
            else {
                return false
            }
            didSendTerminate = true
            return didLaunch && !didSendKill
        }
        if shouldTerminate {
            process.terminate()
        }
    }

    func sendKill() async {
        let processIdentifier: Int32? = lock.withLock {
            guard !didSendKill,
                  !exitLatch.hasPublishedExit
            else {
                return nil
            }
            didSendKill = true
            return didLaunch ? process.processIdentifier : nil
        }
        if let processIdentifier {
            _ = Darwin.kill(processIdentifier, SIGKILL)
        }
    }

    private func closeChildHandles() {
        let handles = lock.withLock {
            let handles = childHandles
            childHandles.removeAll()
            return handles
        }
        handles.forEach { try? $0.close() }
    }

    private static func markCloseOnExec(_ handle: FileHandle) throws {
        let descriptor = handle.fileDescriptor
        let flags = Darwin.fcntl(descriptor, F_GETFD)
        guard flags != -1,
              Darwin.fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) != -1
        else {
            throw ClaudeAuthProcessRunnerError.launchFailed
        }
    }

    private static func closePipe(_ pipe: Pipe) {
        try? pipe.fileHandleForReading.close()
        try? pipe.fileHandleForWriting.close()
    }
}

private struct ClaudeAuthFoundationProcessSessionFactory:
    ClaudeAuthProcessSessionCreating {
    func makeSession(
        for request: ClaudeAuthCommandRequest
    ) throws -> any ClaudeAuthProcessSession {
        try ClaudeAuthFoundationProcessSession(request: request)
    }
}

private struct ClaudeAuthContinuousSleeper: ClaudeAuthProcessSleeping {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

extension ClaudeAuthProcessRunner {
    init() {
        self.init(
            sessionFactory: ClaudeAuthFoundationProcessSessionFactory(),
            sleeper: ClaudeAuthContinuousSleeper(),
            terminationGracePeriod: .milliseconds(250)
        )
    }
}

struct ClaudeAuthStatusClient: Sendable {
    private struct Response: Decodable {
        let loggedIn: Bool
    }

    private static let arguments = ["auth", "status"]
    private static let timeout: Duration = .seconds(5)
    private static let maximumOutputBytes = 65_536
    private static let allowedEnvironmentKeys = [
        "HOME",
        "PATH",
        "TMPDIR",
        "LANG",
        "LC_ALL",
        "CLAUDE_CONFIG_DIR",
    ]

    let executableURL: URL
    let runner: any ClaudeAuthCommandRunning
    private let environment: [String: String]

    init(
        executableURL: URL,
        environmentSource: [String: String],
        runner: any ClaudeAuthCommandRunning
    ) {
        self.executableURL = executableURL
        self.runner = runner
        environment = Self.allowedEnvironmentKeys.reduce(into: [:]) {
            filteredEnvironment, key in
            filteredEnvironment[key] = environmentSource[key]
        }
    }

    func fetch() async -> ClaudeAuthState {
        guard isValidExecutableURL else {
            return .failed(code: .invalidExecutable)
        }

        let request = ClaudeAuthCommandRequest(
            executableURL: executableURL,
            arguments: Self.arguments,
            timeout: Self.timeout,
            maximumStdoutBytes: Self.maximumOutputBytes,
            maximumStderrBytes: Self.maximumOutputBytes,
            environment: environment
        )

        let result: ClaudeAuthCommandResult
        do {
            result = try await runner.run(request)
        } catch ClaudeAuthProcessRunnerError.outputTooLarge {
            return .failed(code: .outputTooLarge)
        } catch {
            return .failed(code: .commandFailed)
        }

        guard
            result.stdout.count <= Self.maximumOutputBytes,
            result.stderr.count <= Self.maximumOutputBytes
        else {
            return .failed(code: .outputTooLarge)
        }

        guard result.exitCode == 0 || result.exitCode == 1 else {
            return .failed(code: .commandFailed)
        }

        guard let response = try? JSONDecoder().decode(
            Response.self,
            from: result.stdout
        ) else {
            return .failed(code: .invalidResponse)
        }

        guard response.loggedIn else {
            return .notConnected
        }
        return result.exitCode == 0
            ? .connected
            : .failed(code: .invalidResponse)
    }

    private var isValidExecutableURL: Bool {
        executableURL.isFileURL
            && executableURL.path.hasPrefix("/")
            && executableURL.path != "/"
            && !executableURL.hasDirectoryPath
            && executableURL.host == nil
            && executableURL.query == nil
            && executableURL.fragment == nil
    }
}
