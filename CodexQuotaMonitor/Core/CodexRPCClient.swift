import Foundation

protocol CodexRPCLineTransport: Sendable {
    func send(line: Data) async throws
    func receiveLine(maximumBytes: Int) async throws -> Data?
}

enum CodexRPCLineTransportError: Error, Equatable, Sendable {
    case lineTooLong
    case processExited
    case partialEOF
}

struct ClientInfo: Encodable, Equatable, Sendable {
    let name: String
    let version: String
    let title: String?

    init(name: String, version: String, title: String? = nil) {
        self.name = name
        self.version = version
        self.title = title
    }
}

enum CodexRPCClientError: Error, Equatable, Sendable {
    case invalidRequest
    case lineTooLong
    case timedOut
    case processExited
    case malformedJSON
    case invalidResponse
    case serverError(code: Int?)
    case transportFailure
}

actor CodexRPCClient {
    static let maximumLineBytes = 1_048_576

    private struct PendingRequest {
        let continuation: CheckedContinuation<Data, any Error>
        let timeoutTask: Task<Void, Never>
    }

    private let transport: any CodexRPCLineTransport
    private let requestTimeout: Duration
    private var nextRequestID: Int64 = 1
    private var pendingRequests: [Int64: PendingRequest] = [:]
    private var readerTask: Task<Void, Never>?
    private var terminalError: CodexRPCClientError?

    init(
        transport: any CodexRPCLineTransport,
        requestTimeout: Duration = .seconds(30)
    ) {
        self.transport = transport
        self.requestTimeout = requestTimeout
    }

    func initialize(clientInfo: ClientInfo) async throws {
        let id = try takeRequestID()
        let line = try encodeLine(
            InitializeRequest(
                id: id,
                method: AppServerOutboundMethod.initialize.rawValue,
                params: InitializeParams(clientInfo: clientInfo)
            )
        )
        let responseLine = try await sendRequest(id: id, line: line)
        let _: EmptyResult = try decodeResult(from: responseLine, matching: id)
    }

    func sendInitialized() async throws {
        if let terminalError {
            throw terminalError
        }

        let line = try encodeLine(
            InitializedNotification(
                method: AppServerOutboundMethod.initialized.rawValue
            )
        )
        do {
            try await transport.send(line: line)
        } catch {
            let clientError = mapTransportError(error)
            transitionToTerminal(clientError)
            throw clientError
        }
    }

    func readRateLimits() async throws -> GetAccountRateLimitsRawResponse {
        let id = try takeRequestID()
        let line = try encodeLine(
            RateLimitsRequest(
                id: id,
                method: AppServerOutboundMethod.readRateLimits.rawValue
            )
        )
        let responseLine = try await sendRequest(id: id, line: line)
        return try decodeResult(from: responseLine, matching: id)
    }

    private func takeRequestID() throws -> Int64 {
        if let terminalError {
            throw terminalError
        }

        let id = nextRequestID
        guard nextRequestID < Int64.max else {
            throw CodexRPCClientError.invalidRequest
        }
        nextRequestID += 1
        return id
    }

    private func encodeLine<Value: Encodable>(_ value: Value) throws -> Data {
        let line: Data
        do {
            line = try JSONEncoder().encode(value)
        } catch {
            throw CodexRPCClientError.invalidRequest
        }

        guard line.count <= Self.maximumLineBytes else {
            throw CodexRPCClientError.lineTooLong
        }
        return line
    }

    private func sendRequest(id: Int64, line: Data) async throws -> Data {
        if let terminalError {
            throw terminalError
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeout = requestTimeout
                let timeoutTask = Task { [weak self] in
                    do {
                        try await ContinuousClock().sleep(for: timeout)
                    } catch {
                        return
                    }
                    await self?.timeoutRequest(id: id)
                }
                pendingRequests[id] = PendingRequest(
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )

                Task { [weak self] in
                    await self?.sendRegisteredRequest(id: id, line: line)
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelRequest(id: id)
            }
        }
    }

    private func sendRegisteredRequest(id: Int64, line: Data) async {
        guard pendingRequests[id] != nil else {
            return
        }
        if let terminalError {
            failRequest(id: id, with: terminalError)
            return
        }

        do {
            try await transport.send(line: line)
        } catch {
            transitionToTerminal(mapTransportError(error))
            return
        }
        startReaderIfNeeded()
    }

    private func mapTransportError(_ error: any Error) -> CodexRPCClientError {
        guard let transportError = error as? CodexRPCLineTransportError else {
            return .transportFailure
        }
        switch transportError {
        case .lineTooLong: return .lineTooLong
        case .processExited: return .processExited
        case .partialEOF: return .processExited
        }
    }

    private func startReaderIfNeeded() {
        guard readerTask == nil, terminalError == nil, !pendingRequests.isEmpty else {
            return
        }
        readerTask = Task { [weak self] in
            await self?.receivePendingResponses()
        }
    }

    private func receivePendingResponses() async {
        while terminalError == nil, !pendingRequests.isEmpty {
            do {
                guard let line = try await transport.receiveLine(
                    maximumBytes: Self.maximumLineBytes
                ) else {
                    transitionToTerminal(.processExited)
                    break
                }
                guard line.count <= Self.maximumLineBytes else {
                    transitionToTerminal(.lineTooLong)
                    break
                }
                handleReceivedLine(line)
            } catch is CancellationError {
                break
            } catch let error as CodexRPCLineTransportError {
                switch error {
                case .lineTooLong: transitionToTerminal(.lineTooLong)
                case .processExited: transitionToTerminal(.processExited)
                case .partialEOF: transitionToTerminal(.processExited)
                }
                break
            } catch {
                transitionToTerminal(.transportFailure)
                break
            }
        }

        readerTask = nil
        startReaderIfNeeded()
    }

    private func handleReceivedLine(_ line: Data) {
        let header: ResponseHeader
        do {
            header = try JSONDecoder().decode(ResponseHeader.self, from: line)
        } catch {
            failAllPending(with: .malformedJSON)
            return
        }

        guard case let .integer(id)? = header.id,
              let pending = pendingRequests.removeValue(forKey: id)
        else {
            return
        }

        pending.timeoutTask.cancel()
        pending.continuation.resume(returning: line)
    }

    private func decodeResult<Result: Decodable>(
        from line: Data,
        matching id: Int64
    ) throws -> Result {
        let response: ResponseEnvelope<Result>
        do {
            response = try JSONDecoder().decode(ResponseEnvelope<Result>.self, from: line)
        } catch {
            throw CodexRPCClientError.invalidResponse
        }

        guard response.id == .integer(id) else {
            throw CodexRPCClientError.invalidResponse
        }
        if let error = response.error {
            throw CodexRPCClientError.serverError(code: error.code)
        }
        guard let result = response.result else {
            throw CodexRPCClientError.invalidResponse
        }
        return result
    }

    private func timeoutRequest(id: Int64) {
        failRequest(id: id, with: .timedOut)
        stopReaderIfIdle()
    }

    private func cancelRequest(id: Int64) {
        guard let pending = pendingRequests.removeValue(forKey: id) else {
            return
        }
        pending.timeoutTask.cancel()
        pending.continuation.resume(throwing: CancellationError())
        stopReaderIfIdle()
    }

    private func failRequest(id: Int64, with error: CodexRPCClientError) {
        guard let pending = pendingRequests.removeValue(forKey: id) else {
            return
        }
        pending.timeoutTask.cancel()
        pending.continuation.resume(throwing: error)
    }

    private func failAllPending(with error: CodexRPCClientError) {
        let pending = pendingRequests.values
        pendingRequests.removeAll(keepingCapacity: true)
        for request in pending {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: error)
        }
    }

    private func stopReaderIfIdle() {
        if pendingRequests.isEmpty {
            readerTask?.cancel()
        }
    }

    private func transitionToTerminal(_ error: CodexRPCClientError) {
        guard terminalError == nil else {
            return
        }
        terminalError = error
        readerTask?.cancel()
        failAllPending(with: error)
    }
}

private struct InitializeRequest: Encodable {
    let id: Int64
    let method: String
    let params: InitializeParams
}

private struct InitializeParams: Encodable {
    let clientInfo: ClientInfo
}

private struct InitializedNotification: Encodable {
    let method: String
}

private struct RateLimitsRequest: Encodable {
    let id: Int64
    let method: String
}

private struct EmptyResult: Decodable {}

private enum ResponseID: Equatable, Decodable {
    case integer(Int64)
    case string(String)

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }
}

private struct ResponseHeader: Decodable {
    let id: ResponseID?
}

private struct ResponseEnvelope<Result: Decodable>: Decodable {
    let id: ResponseID
    let result: Result?
    let error: ResponseError?
}

private struct ResponseError: Decodable {
    let code: Int?
}
