import Foundation

enum AppServerNotification: Equatable, Sendable {
    case rateLimitsUpdated
    case authenticationChanged
}

enum AppServerOutboundMethod: String, CaseIterable, Sendable {
    case initialize = "initialize"
    case initialized = "initialized"
    case readAccount = "account/read"
    case readRateLimits = "account/rateLimits/read"
    case readUsage = "account/usage/read"
}

struct CodexAccountReadResult: Decodable, Equatable, Sendable {
    let account: ProviderAccountSummary?
    let requiresOpenaiAuth: Bool

    private enum CodingKeys: String, CodingKey {
        case account
        case requiresOpenaiAuth
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requiresOpenaiAuth = try container.decode(
            Bool.self,
            forKey: .requiresOpenaiAuth
        )
        account = try container.decodeIfPresent(
            CodexAccountPayload.self,
            forKey: .account
        )?.summary
    }
}

private struct CodexAccountPayload: Decodable {
    let summary: ProviderAccountSummary

    private enum CodingKeys: String, CodingKey {
        case type
        case email
        case planType
        case credentialSource
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "apiKey":
            summary = ProviderAccountSummary(maskedIdentity: nil)

        case "chatgpt":
            _ = try container.decode(String.self, forKey: .planType)
            guard let rawEmail = try container.decodeIfPresent(
                String.self,
                forKey: .email
            ) else {
                summary = ProviderAccountSummary(maskedIdentity: nil)
                return
            }
            guard let maskedIdentity = MaskedAccountIdentity.maskingEmail(
                rawEmail
            ) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .email,
                    in: container,
                    debugDescription: "Account email does not match the accepted schema."
                )
            }
            summary = ProviderAccountSummary(
                maskedIdentity: maskedIdentity
            )

        case "amazonBedrock":
            _ = try container.decodeIfPresent(
                String.self,
                forKey: .credentialSource
            )
            summary = ProviderAccountSummary(maskedIdentity: nil)

        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Account type is not part of the bundled schema."
            )
        }
    }
}

enum CodexAppServerClientError: Error, Equatable, Sendable {
    case invalidRequest
    case notConnected
    case staleGeneration
    case lineTooLong
    case timedOut
    case processExited
    case partialEOF
    case malformedJSON
    case invalidResponse
    case serverError(code: Int?)
    case transportFailure
}

protocol CodexAppServerConnection: CodexRPCLineTransport {
    func launch() async throws
    func verifySpawnedProcess() async throws
    func terminate() async
}

protocol CodexAppServerConnectionFactory: Sendable {
    func makeConnection() async throws -> any CodexAppServerConnection
}

struct ProductionCodexAppServerConnectionFactory: CodexAppServerConnectionFactory {
#if DEBUG
    private let productionRuntimeAccessCheck: @Sendable () throws -> Void
    private let manifestLoader: @Sendable () throws -> CodexTrustManifest

    init(
        productionRuntimeAccessCheck: @escaping @Sendable () throws -> Void = {
            try DebugProductionRuntimeGuard.requireCurrentProcessAccess()
        },
        manifestLoader: @escaping @Sendable () throws -> CodexTrustManifest = {
            try CodexTrustManifest.bundled()
        }
    ) {
        self.productionRuntimeAccessCheck = productionRuntimeAccessCheck
        self.manifestLoader = manifestLoader
    }
#endif

    func makeConnection() async throws -> any CodexAppServerConnection {
#if DEBUG
        try productionRuntimeAccessCheck()
        let manifest = try manifestLoader()
#else
        let manifest = try CodexTrustManifest.bundled()
#endif
        let verifier = CodexExecutableVerifier(
            manifest: manifest,
            requestedArguments: manifest.arguments,
            requestedEnvironmentKeys: manifest.environmentKeys
        )
        let verified = try verifier.verifyBeforeSpawn()
        let sourceEnvironment = ProcessInfo.processInfo.environment
        let environment = Dictionary(
            uniqueKeysWithValues: verified.environmentKeys.compactMap { key in
                sourceEnvironment[key].map { (key, $0) }
            }
        )
        return AppServerProcessTransport(
            verifiedExecutable: verified,
            verifier: verifier,
            environment: environment
        )
    }
}

actor CodexAppServerClient {
    static let maximumLineBytes = 1_048_576

    private struct RequestKey: Hashable, Sendable {
        let epoch: UInt64
        let id: Int64
    }

    private struct PendingRequest {
        let continuation: CheckedContinuation<Data, any Error>
        let timeoutTask: Task<Void, Never>
    }

    private let connectionFactory: any CodexAppServerConnectionFactory
    private let requestTimeout: Duration
    private let clientInfo: ClientInfo

    private var connection: (any CodexAppServerConnection)?
    private var readerTask: Task<Void, Never>?
    private var activeConnectOperation: UInt64?
    private var nextConnectOperation: UInt64 = 1
    private var activeConnectionEpoch: UInt64?
    private var nextConnectionEpoch: UInt64 = 1
    private var nextRequestID: Int64 = 1
    private var pendingRequests: [RequestKey: PendingRequest] = [:]
    private var terminalError: CodexAppServerClientError?

    private var authGeneration: UInt64 = 0
    private var lastSession: UInt64?
    private var connectionGeneration: UInt64 = 0
    private var currentGeneration: GenerationToken?

    private var notificationContinuations: [
        UUID: AsyncStream<AppServerNotification>.Continuation
    ] = [:]

    init(
        connectionFactory: any CodexAppServerConnectionFactory =
            ProductionCodexAppServerConnectionFactory(),
        requestTimeout: Duration = .seconds(30),
        clientInfo: ClientInfo = ClientInfo(
            name: "CodexQuotaMonitor",
            version: "1.0"
        )
    ) {
        self.connectionFactory = connectionFactory
        self.requestTimeout = requestTimeout
        self.clientInfo = clientInfo
    }

    func connect(session: UInt64) async throws -> GenerationToken {
        let operation = try beginConnectOperation()
        let previousConnection = detachCurrentConnection(
            pendingError: CancellationError()
        )
        await previousConnection?.terminate()

        var candidateConnection: (any CodexAppServerConnection)?
        var candidateEpoch: UInt64?

        do {
            try requireCurrentConnectOperation(operation)
            terminalError = nil
            nextRequestID = 1

            let generation = try takeNextGeneration(session: session)
            let epoch = try takeConnectionEpoch()
            candidateEpoch = epoch
            let newConnection = try await connectionFactory.makeConnection()
            candidateConnection = newConnection
            try requireCurrentConnectOperation(operation)

            try await newConnection.launch()
            try requireCurrentConnectOperation(operation)
            try await newConnection.verifySpawnedProcess()
            try requireCurrentConnectOperation(operation)

            connection = newConnection
            activeConnectionEpoch = epoch
            currentGeneration = generation
            startReader(connection: newConnection, epoch: epoch)

            let response = try await sendRequest(
                method: .initialize,
                generation: generation
            )
            try requireCurrentConnectOperation(operation)
            let _: AppServerEmptyResult = try decodeResult(
                from: response.line,
                matching: response.id
            )
            try await sendInitialized(generation: generation)
            try requireCurrentConnectOperation(operation)

            guard terminalError == nil,
                  currentGeneration == generation,
                  activeConnectionEpoch == epoch else {
                throw terminalError ?? CodexAppServerClientError.staleGeneration
            }
            return generation
        } catch {
            let finalError = normalizedConnectError(
                error,
                operation: operation
            )
            await cleanupFailedConnect(
                candidateConnection: candidateConnection,
                candidateEpoch: candidateEpoch,
                operation: operation,
                pendingError: finalError
            )
            throw finalError
        }
    }

    func readRateLimits(
        generation: GenerationToken
    ) async throws -> RateLimitCatalog {
        let raw = try await readRateLimitsRaw(generation: generation)
        return try RateLimitCatalog(rawResponse: raw)
    }

    func readAccount(
        generation: GenerationToken
    ) async throws -> CodexAccountReadResult {
        try requireCurrent(generation)
        let response = try await sendRequest(
            method: .readAccount,
            generation: generation
        )
        let result: CodexAccountReadResult = try decodeResult(
            from: response.line,
            matching: response.id
        )
        try requireCurrent(generation)
        return result
    }

    func readUsage(
        generation: GenerationToken
    ) async throws -> TokenActivitySnapshot {
        try requireCurrent(generation)
        let response = try await sendRequest(
            method: .readUsage,
            generation: generation
        )
        let raw: GetAccountTokenUsageRawResponse = try decodeResult(
            from: response.line,
            matching: response.id
        )
        try requireCurrent(generation)
        return TokenActivitySnapshot(rawResponse: raw)
    }

    func notifications() -> AsyncStream<AppServerNotification> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
            notificationContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task {
                    await self?.removeNotificationContinuation(id: id)
                }
            }
        }
    }

    func disconnect() async {
        activeConnectOperation = nil
        terminalError = nil
        let activeConnection = detachCurrentConnection(
            pendingError: CancellationError()
        )
        await activeConnection?.terminate()
    }

    func pendingRequestCountForTesting() -> Int {
        pendingRequests.count
    }

    func hasActiveReaderForTesting() -> Bool {
        readerTask != nil && activeConnectionEpoch != nil
    }

    func activeConnectionEpochForTesting() -> UInt64? {
        activeConnectionEpoch
    }

    func cancelRequestForTesting(id: Int64, epoch: UInt64) {
        cancelRequest(key: RequestKey(epoch: epoch, id: id))
    }

    func readRateLimitsRaw(
        generation: GenerationToken
    ) async throws -> GetAccountRateLimitsRawResponse {
        try requireCurrent(generation)
        let response = try await sendRequest(
            method: .readRateLimits,
            generation: generation
        )
        let raw: GetAccountRateLimitsRawResponse = try decodeResult(
            from: response.line,
            matching: response.id
        )
        try requireCurrent(generation)
        return raw
    }

    private func sendInitialized(generation: GenerationToken) async throws {
        try requireCurrent(generation)
        let line = try encodeLine(
            AppServerInitializedNotification(
                method: AppServerOutboundMethod.initialized.rawValue
            )
        )
        guard let connection else {
            throw CodexAppServerClientError.notConnected
        }
        do {
            try await connection.send(line: line)
        } catch {
            throw mapTransportError(error)
        }
    }

    private func sendRequest(
        method: AppServerOutboundMethod,
        generation: GenerationToken
    ) async throws -> (id: Int64, line: Data) {
        try requireCurrent(generation)
        guard method != .initialized else {
            throw CodexAppServerClientError.invalidRequest
        }

        let id = try takeRequestID()
        let line: Data
        switch method {
        case .initialize:
            line = try encodeLine(
                AppServerInitializeRequest(
                    id: id,
                    method: method.rawValue,
                    params: AppServerInitializeParams(clientInfo: clientInfo)
                )
            )
        case .readAccount:
            line = try encodeLine(
                AppServerAccountReadRequest(
                    id: id,
                    method: method.rawValue,
                    params: AppServerAccountReadParams(refreshToken: false)
                )
            )
        case .readRateLimits, .readUsage:
            line = try encodeLine(
                AppServerReadRequest(id: id, method: method.rawValue)
            )
        case .initialized:
            throw CodexAppServerClientError.invalidRequest
        }

        let responseLine = try await awaitResponse(
            id: id,
            line: line,
            generation: generation
        )
        return (id, responseLine)
    }

    private func awaitResponse(
        id: Int64,
        line: Data,
        generation: GenerationToken
    ) async throws -> Data {
        let epoch = try currentEpoch(for: generation)
        let key = RequestKey(epoch: epoch, id: id)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeout = requestTimeout
                let timeoutTask = Task { [weak self] in
                    do {
                        try await ContinuousClock().sleep(for: timeout)
                    } catch {
                        return
                    }
                    await self?.timeoutRequest(key: key)
                }
                pendingRequests[key] = PendingRequest(
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
                Task { [weak self] in
                    await self?.sendRegisteredRequest(
                        key: key,
                        line: line,
                        epoch: epoch
                    )
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelRequest(key: key)
            }
        }
    }

    private func sendRegisteredRequest(
        key: RequestKey,
        line: Data,
        epoch: UInt64
    ) async {
        guard pendingRequests[key] != nil else { return }
        guard activeConnectionEpoch == epoch,
              terminalError == nil,
              let connection else {
            failRequest(key: key, with: terminalError ?? .notConnected)
            return
        }
        do {
            try await connection.send(line: line)
        } catch {
            await terminalize(mapTransportError(error), epoch: epoch)
        }
    }

    private func startReader(
        connection: any CodexAppServerConnection,
        epoch: UInt64
    ) {
        readerTask = Task { [weak self] in
            await self?.receiveLoop(connection: connection, epoch: epoch)
        }
    }

    private func receiveLoop(
        connection: any CodexAppServerConnection,
        epoch: UInt64
    ) async {
        while activeConnectionEpoch == epoch, !Task.isCancelled {
            do {
                guard let line = try await connection.receiveLine(
                    maximumBytes: Self.maximumLineBytes
                ) else {
                    await terminalize(.processExited, epoch: epoch)
                    return
                }
                guard activeConnectionEpoch == epoch, !Task.isCancelled else {
                    return
                }
                guard line.count <= Self.maximumLineBytes else {
                    await terminalize(.lineTooLong, epoch: epoch)
                    return
                }
                try await handleReceivedLine(line, epoch: epoch)
            } catch is CancellationError {
                return
            } catch {
                await terminalize(mapTransportError(error), epoch: epoch)
                return
            }
        }
    }

    private func handleReceivedLine(_ line: Data, epoch: UInt64) async throws {
        guard activeConnectionEpoch == epoch else { return }
        let header: AppServerIncomingHeader
        do {
            header = try JSONDecoder().decode(AppServerIncomingHeader.self, from: line)
        } catch {
            await terminalize(.malformedJSON, epoch: epoch)
            return
        }

        if let method = header.method {
            switch method {
            case "account/rateLimits/updated":
                publish(.rateLimitsUpdated)
            case "account/updated", "account/login/completed":
                try authenticationDidChange()
                publish(.authenticationChanged)
            default:
                break
            }
            return
        }

        guard case let .integer(id)? = header.id,
              let pending = pendingRequests.removeValue(
                forKey: RequestKey(epoch: epoch, id: id)
              ) else {
            return
        }
        pending.timeoutTask.cancel()
        pending.continuation.resume(returning: line)
    }

    private func authenticationDidChange() throws {
        let result = authGeneration.addingReportingOverflow(1)
        guard !result.overflow else {
            throw CodexAppServerClientError.invalidRequest
        }
        authGeneration = result.partialValue
        lastSession = nil
        connectionGeneration = 0
        currentGeneration = nil
        failAllPending(with: CodexAppServerClientError.staleGeneration)
    }

    private func takeNextGeneration(session: UInt64) throws -> GenerationToken {
        if lastSession != session {
            lastSession = session
            connectionGeneration = 0
        }
        let result = connectionGeneration.addingReportingOverflow(1)
        guard !result.overflow else {
            throw GenerationAdvanceError.overflow(.connection)
        }
        connectionGeneration = result.partialValue
        return GenerationToken(
            auth: authGeneration,
            session: session,
            connection: connectionGeneration
        )
    }

    private func takeConnectionEpoch() throws -> UInt64 {
        let epoch = nextConnectionEpoch
        let result = nextConnectionEpoch.addingReportingOverflow(1)
        guard !result.overflow else {
            throw CodexAppServerClientError.invalidRequest
        }
        nextConnectionEpoch = result.partialValue
        return epoch
    }

    private func beginConnectOperation() throws -> UInt64 {
        let operation = nextConnectOperation
        let result = nextConnectOperation.addingReportingOverflow(1)
        guard !result.overflow else {
            throw CodexAppServerClientError.invalidRequest
        }
        nextConnectOperation = result.partialValue
        activeConnectOperation = operation
        return operation
    }

    private func requireCurrentConnectOperation(_ operation: UInt64) throws {
        try Task.checkCancellation()
        guard activeConnectOperation == operation else {
            throw CancellationError()
        }
    }

    private func takeRequestID() throws -> Int64 {
        if let terminalError {
            throw terminalError
        }
        let id = nextRequestID
        guard nextRequestID < Int64.max else {
            throw CodexAppServerClientError.invalidRequest
        }
        nextRequestID += 1
        return id
    }

    private func requireCurrent(_ generation: GenerationToken) throws {
        if let terminalError {
            throw terminalError
        }
        guard connection != nil, activeConnectionEpoch != nil else {
            throw CodexAppServerClientError.notConnected
        }
        guard currentGeneration == generation else {
            throw CodexAppServerClientError.staleGeneration
        }
    }

    private func currentEpoch(for generation: GenerationToken) throws -> UInt64 {
        try requireCurrent(generation)
        guard let activeConnectionEpoch else {
            throw CodexAppServerClientError.notConnected
        }
        return activeConnectionEpoch
    }

    private func encodeLine<Value: Encodable>(_ value: Value) throws -> Data {
        let data: Data
        do {
            data = try JSONEncoder().encode(value)
        } catch {
            throw CodexAppServerClientError.invalidRequest
        }
        guard data.count <= Self.maximumLineBytes else {
            throw CodexAppServerClientError.lineTooLong
        }
        return data
    }

    private func decodeResult<Result: Decodable>(
        from line: Data,
        matching id: Int64
    ) throws -> Result {
        let response: AppServerResponseEnvelope<Result>
        do {
            response = try JSONDecoder().decode(
                AppServerResponseEnvelope<Result>.self,
                from: line
            )
        } catch {
            throw CodexAppServerClientError.invalidResponse
        }
        guard response.id == .integer(id) else {
            throw CodexAppServerClientError.invalidResponse
        }
        if let error = response.error {
            throw CodexAppServerClientError.serverError(code: error.code)
        }
        guard let result = response.result else {
            throw CodexAppServerClientError.invalidResponse
        }
        return result
    }

    private func timeoutRequest(key: RequestKey) async {
        guard pendingRequests[key] != nil else { return }
        await terminalize(.timedOut, epoch: key.epoch)
    }

    private func cancelRequest(key: RequestKey) {
        guard let pending = pendingRequests.removeValue(forKey: key) else {
            return
        }
        pending.timeoutTask.cancel()
        pending.continuation.resume(throwing: CancellationError())
    }

    private func failRequest(key: RequestKey, with error: any Error) {
        guard let pending = pendingRequests.removeValue(forKey: key) else {
            return
        }
        pending.timeoutTask.cancel()
        pending.continuation.resume(throwing: error)
    }

    private func failAllPending(with error: any Error) {
        let pending = pendingRequests.values
        pendingRequests.removeAll(keepingCapacity: true)
        for request in pending {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: error)
        }
    }

    private func terminalize(
        _ error: CodexAppServerClientError,
        epoch: UInt64
    ) async {
        guard activeConnectionEpoch == epoch else { return }
        if terminalError == nil {
            terminalError = error
        }
        currentGeneration = nil
        failAllPending(with: terminalError ?? error)
        let activeConnection = connection
        connection = nil
        activeConnectionEpoch = nil
        readerTask?.cancel()
        readerTask = nil
        await activeConnection?.terminate()
    }

    private func detachCurrentConnection(
        pendingError: any Error
    ) -> (any CodexAppServerConnection)? {
        failAllPending(with: pendingError)
        let activeConnection = connection
        connection = nil
        currentGeneration = nil
        activeConnectionEpoch = nil
        readerTask?.cancel()
        readerTask = nil
        return activeConnection
    }

    private func cleanupFailedConnect(
        candidateConnection: (any CodexAppServerConnection)?,
        candidateEpoch: UInt64?,
        operation: UInt64,
        pendingError: any Error
    ) async {
        if activeConnectOperation == operation,
           let candidateEpoch,
           activeConnectionEpoch == candidateEpoch {
            let ownedConnection = detachCurrentConnection(
                pendingError: pendingError
            )
            await ownedConnection?.terminate()
            return
        }
        await candidateConnection?.terminate()
    }

    private func normalizedConnectError(
        _ error: any Error,
        operation: UInt64
    ) -> any Error {
        if Task.isCancelled || activeConnectOperation != operation {
            return CancellationError()
        }
        if error is CancellationError
            || error is CodexExecutableTrustError
            || error is CodexTrustManifestLoadingError
            || error is AppServerProcessLaunchError
            || error is GenerationAdvanceError {
            return error
        }
        return mapTransportError(error)
    }

    private func mapTransportError(_ error: any Error) -> CodexAppServerClientError {
        if let clientError = error as? CodexAppServerClientError {
            return clientError
        }
        guard let transportError = error as? CodexRPCLineTransportError else {
            return .transportFailure
        }
        switch transportError {
        case .lineTooLong: return .lineTooLong
        case .processExited: return .processExited
        case .partialEOF: return .partialEOF
        }
    }

    private func publish(_ notification: AppServerNotification) {
        for continuation in notificationContinuations.values {
            continuation.yield(notification)
        }
    }

    private func removeNotificationContinuation(id: UUID) {
        notificationContinuations.removeValue(forKey: id)
    }
}

private struct AppServerInitializeRequest: Encodable {
    let id: Int64
    let method: String
    let params: AppServerInitializeParams
}

private struct AppServerInitializeParams: Encodable {
    let clientInfo: ClientInfo
}

private struct AppServerInitializedNotification: Encodable {
    let method: String
}

private struct AppServerAccountReadRequest: Encodable {
    let id: Int64
    let method: String
    let params: AppServerAccountReadParams
}

private struct AppServerAccountReadParams: Encodable {
    let refreshToken: Bool
}

private struct AppServerReadRequest: Encodable {
    let id: Int64
    let method: String
}

private struct AppServerEmptyResult: Decodable {}

private enum AppServerResponseID: Equatable, Decodable {
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

private struct AppServerIncomingHeader: Decodable {
    let id: AppServerResponseID?
    let method: String?
}

private struct AppServerResponseEnvelope<Result: Decodable>: Decodable {
    let id: AppServerResponseID
    let result: Result?
    let error: AppServerResponseError?
}

private struct AppServerResponseError: Decodable {
    let code: Int?
}
