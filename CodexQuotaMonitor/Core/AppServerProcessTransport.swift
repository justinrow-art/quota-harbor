import Darwin
import Foundation

struct AppServerProcessConfiguration: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]?
}

enum AppServerProcessLaunchError: Error, Equatable, Sendable {
    case launchFailed
}

struct AppServerStdinWriter {
    private let fileHandle: FileHandle
    let fileDescriptorForTesting: Int32

    init(fileHandle: FileHandle) throws {
        let fileDescriptor = fileHandle.fileDescriptor
        guard Darwin.fcntl(fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw AppServerProcessLaunchError.launchFailed
        }
        self.fileHandle = fileHandle
        fileDescriptorForTesting = fileDescriptor
    }

    func write(_ framedLine: Data) throws {
        do {
            try fileHandle.write(contentsOf: framedLine)
        } catch {
            throw CodexRPCLineTransportError.processExited
        }
    }

    func close() {
        try? fileHandle.close()
    }
}

struct BoundedLineFramer: Sendable {
    private var accumulated = Data()

    var bufferedByteCount: Int {
        accumulated.count
    }

    mutating func append(_ chunk: Data, maximumBytes: Int) throws -> [Data] {
        var lines: [Data] = []
        for byte in chunk {
            if let line = try append(byte: byte, maximumBytes: maximumBytes) {
                lines.append(line)
            }
        }
        return lines
    }

    private mutating func append(byte: UInt8, maximumBytes: Int) throws -> Data? {
        if byte == 0x0A {
            let line = accumulated
            accumulated.removeAll(keepingCapacity: true)
            return line
        }

        guard maximumBytes >= 0, accumulated.count < maximumBytes else {
            accumulated.removeAll(keepingCapacity: false)
            throw CodexRPCLineTransportError.lineTooLong
        }
        accumulated.append(byte)
        return nil
    }
}

actor AppServerProcessTransport: CodexAppServerConnection {
    nonisolated let configuration: AppServerProcessConfiguration

    private struct PendingReceive {
        let id: Int64
        let maximumBytes: Int
        let continuation: CheckedContinuation<Data?, any Error>
    }

    private var process: Process?
    private var stdinWriter: AppServerStdinWriter?
    private var outputHandle: FileHandle?
    private var readerTask: Task<Void, Never>?
    private var readerDemandContinuation: CheckedContinuation<Bool, Never>?
    private var generation: Int64 = 0
    private var nextReceiveID: Int64 = 1
    private var pendingReceives: [PendingReceive] = []
    private var completedLines: [Data] = []
    private var lineFramer = BoundedLineFramer()
    private var terminalError: CodexRPCLineTransportError?
    private var terminationRequested = false
    private let verifiedExecutable: VerifiedCodexExecutable?
    private let executableVerifier: CodexExecutableVerifier?
#if DEBUG
    private let productionRuntimeAccessCheck: @Sendable () throws -> Void
#endif

    #if DEBUG
    nonisolated static func makeProduction(binaryPath: String) -> AppServerProcessTransport {
        AppServerProcessTransport(
            executableURL: URL(fileURLWithPath: binaryPath),
            arguments: ["app-server", "--listen", "stdio://"]
        )
    }

    internal init(
        executableURL: URL,
        arguments: [String],
        productionRuntimeAccessCheck:
            @escaping @Sendable () throws -> Void = {
                try DebugProductionRuntimeGuard.requireCurrentProcessAccess()
            }
    ) {
        configuration = AppServerProcessConfiguration(
            executableURL: executableURL,
            arguments: arguments,
            environment: nil
        )
        verifiedExecutable = nil
        executableVerifier = nil
        self.productionRuntimeAccessCheck = productionRuntimeAccessCheck
    }
    #endif

    internal init(
        verifiedExecutable: VerifiedCodexExecutable,
        verifier: CodexExecutableVerifier,
        environment: [String: String]
    ) {
        configuration = AppServerProcessConfiguration(
            executableURL: verifiedExecutable.executableURL,
            arguments: verifiedExecutable.arguments,
            environment: environment
        )
        self.verifiedExecutable = verifiedExecutable
        executableVerifier = verifier
#if DEBUG
        productionRuntimeAccessCheck = {
            try DebugProductionRuntimeGuard.requireCurrentProcessAccess()
        }
#endif
    }

    func launch() throws {
        if let process {
            guard process.isRunning else {
                throw CodexRPCLineTransportError.processExited
            }
            return
        }
        guard !terminationRequested,
              let standardError = FileHandle(forWritingAtPath: "/dev/null")
        else {
            throw AppServerProcessLaunchError.launchFailed
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let stdinWriter: AppServerStdinWriter
        do {
            stdinWriter = try AppServerStdinWriter(
                fileHandle: inputPipe.fileHandleForWriting
            )
        } catch {
            try? inputPipe.fileHandleForReading.close()
            try? inputPipe.fileHandleForWriting.close()
            try? outputPipe.fileHandleForReading.close()
            try? outputPipe.fileHandleForWriting.close()
            try? standardError.close()
            throw AppServerProcessLaunchError.launchFailed
        }
        process.executableURL = configuration.executableURL
        process.arguments = configuration.arguments
        if let environment = configuration.environment {
            process.environment = environment
        }
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = standardError

        do {
            if let executableVerifier, let verifiedExecutable {
                try executableVerifier.verifyImmediatelyBeforeSpawn(
                    verifiedExecutable
                )
            }
#if DEBUG
            try productionRuntimeAccessCheck()
#endif
            try process.run()
        } catch let error as CodexExecutableTrustError {
            try? inputPipe.fileHandleForReading.close()
            stdinWriter.close()
            try? outputPipe.fileHandleForReading.close()
            try? outputPipe.fileHandleForWriting.close()
            try? standardError.close()
            throw error
        } catch {
            try? inputPipe.fileHandleForReading.close()
            stdinWriter.close()
            try? outputPipe.fileHandleForReading.close()
            try? outputPipe.fileHandleForWriting.close()
            try? standardError.close()
            throw AppServerProcessLaunchError.launchFailed
        }

        try? inputPipe.fileHandleForReading.close()
        try? outputPipe.fileHandleForWriting.close()
        try? standardError.close()
        self.process = process
        self.stdinWriter = stdinWriter
        outputHandle = outputPipe.fileHandleForReading
        generation += 1
        startReader(
            from: outputPipe.fileHandleForReading.bytes.makeAsyncIterator(),
            generation: generation
        )
    }

    func send(line: Data) throws {
        guard !terminationRequested,
              terminalError == nil,
              let process,
              process.isRunning,
              let stdinWriter
        else {
            throw terminalError ?? CodexRPCLineTransportError.processExited
        }

        do {
            try stdinWriter.write(Self.framedLineForSending(line))
        } catch {
            throw CodexRPCLineTransportError.processExited
        }
    }

    func verifySpawnedProcess() throws {
        guard let executableVerifier else {
            return
        }
        guard let process, process.isRunning else {
            throw CodexRPCLineTransportError.processExited
        }
        try executableVerifier.verifySpawnedProcess(
            pid: process.processIdentifier
        )
    }

    func receiveLine(maximumBytes: Int) async throws -> Data? {
        if let terminalError {
            throw terminalError
        }
        guard !terminationRequested, process != nil, maximumBytes >= 0 else {
            throw maximumBytes < 0
                ? CodexRPCLineTransportError.lineTooLong
                : CodexRPCLineTransportError.processExited
        }

        let receiveID = nextReceiveID
        nextReceiveID += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                registerReceive(
                    id: receiveID,
                    maximumBytes: maximumBytes,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelReceive(id: receiveID)
            }
        }
    }

    func terminate() async {
        guard !terminationRequested else {
            if let process {
                _ = await waitForExit(process, attempts: 100)
            }
            return
        }
        terminationRequested = true
        terminalError = .processExited
        failAllPending(with: CodexRPCLineTransportError.processExited)
        readerDemandContinuation?.resume(returning: false)
        readerDemandContinuation = nil
        stdinWriter?.close()
        try? outputHandle?.close()
        stdinWriter = nil
        outputHandle = nil
        readerTask?.cancel()

        guard let process else {
            return
        }
        if process.isRunning {
            process.terminate()
        }
        if await waitForExit(process, attempts: 100) {
            self.process = nil
            return
        }

        _ = Darwin.kill(process.processIdentifier, SIGKILL)
        if await waitForExit(process, attempts: 100) {
            self.process = nil
        }
    }

    func isRunningForTesting() -> Bool {
        process?.isRunning ?? false
    }

    func pendingReceiveCountForTesting() -> Int {
        pendingReceives.count
    }

    nonisolated static func framedLineForSending(_ line: Data) -> Data {
        var framed = line
        framed.append(0x0A)
        return framed
    }

    private func registerReceive(
        id: Int64,
        maximumBytes: Int,
        continuation: CheckedContinuation<Data?, any Error>
    ) {
        if Task.isCancelled {
            continuation.resume(throwing: CancellationError())
            return
        }
        if let terminalError {
            continuation.resume(throwing: terminalError)
            return
        }
        if !completedLines.isEmpty {
            let line = completedLines.removeFirst()
            if line.count > maximumBytes {
                continuation.resume(throwing: CodexRPCLineTransportError.lineTooLong)
            } else {
                continuation.resume(returning: line)
            }
            return
        }
        guard lineFramer.bufferedByteCount <= maximumBytes else {
            transitionToTerminal(.lineTooLong)
            continuation.resume(throwing: CodexRPCLineTransportError.lineTooLong)
            return
        }

        pendingReceives.append(
            PendingReceive(
                id: id,
                maximumBytes: maximumBytes,
                continuation: continuation
            )
        )
        readerDemandContinuation?.resume(returning: true)
        readerDemandContinuation = nil
    }

    private func cancelReceive(id: Int64) {
        guard let index = pendingReceives.firstIndex(where: { $0.id == id }) else {
            return
        }
        let pending = pendingReceives.remove(at: index)
        pending.continuation.resume(throwing: CancellationError())
    }

    private func startReader(
        from initialIterator: FileHandle.AsyncBytes.Iterator,
        generation: Int64
    ) {
        readerTask = Task { [weak self] in
            guard let self else {
                return
            }
            var iterator = initialIterator
            while await self.waitForReaderDemand(generation: generation) {
                var chunk = Data()
                chunk.reserveCapacity(4_096)
                var reachedEnd = false

                do {
                    while chunk.count < 4_096 {
                        guard let byte = try await iterator.next() else {
                            reachedEnd = true
                            break
                        }
                        chunk.append(byte)
                        if byte == 0x0A {
                            break
                        }
                    }
                } catch is CancellationError {
                    await self.readerDidEnd(generation: generation)
                    return
                } catch {
                    await self.readerDidEnd(generation: generation)
                    return
                }

                if !chunk.isEmpty {
                    await self.readerDidProduce(chunk, generation: generation)
                }
                if reachedEnd {
                    await self.readerDidEnd(generation: generation)
                    return
                }
            }
        }
    }

    private func waitForReaderDemand(generation: Int64) async -> Bool {
        guard self.generation == generation,
              !terminationRequested,
              terminalError == nil
        else {
            return false
        }
        if !pendingReceives.isEmpty {
            return true
        }
        return await withCheckedContinuation { continuation in
            readerDemandContinuation = continuation
        }
    }

    private func readerDidProduce(_ chunk: Data, generation: Int64) {
        guard self.generation == generation,
              !terminationRequested,
              terminalError == nil
        else {
            return
        }

        let maximumBytes = pendingReceives.first?.maximumBytes
            ?? CodexRPCClient.maximumLineBytes
        do {
            let lines = try lineFramer.append(chunk, maximumBytes: maximumBytes)
            for line in lines {
                if pendingReceives.isEmpty {
                    completedLines.append(line)
                } else {
                    let pending = pendingReceives.removeFirst()
                    pending.continuation.resume(returning: line)
                }
            }
        } catch {
            transitionToTerminal(.lineTooLong)
        }
    }

    private func readerDidEnd(generation: Int64) {
        guard self.generation == generation else {
            return
        }
        transitionToTerminal(
            lineFramer.bufferedByteCount == 0 ? .processExited : .partialEOF
        )
    }

    private func transitionToTerminal(_ error: CodexRPCLineTransportError) {
        guard terminalError == nil else {
            return
        }
        terminalError = error
        failAllPending(with: error)
        readerDemandContinuation?.resume(returning: false)
        readerDemandContinuation = nil
    }

    private func failAllPending(with error: any Error) {
        let pending = pendingReceives
        pendingReceives.removeAll(keepingCapacity: false)
        for receive in pending {
            receive.continuation.resume(throwing: error)
        }
    }

    private func waitForExit(_ process: Process, attempts: Int) async -> Bool {
        for _ in 0..<attempts {
            if !process.isRunning {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return !process.isRunning
    }
}
