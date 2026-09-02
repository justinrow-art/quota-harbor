import Foundation

protocol AppServerQuotaSession: Sendable {
    func launch() async throws
    func initialize(clientInfo: ClientInfo) async throws
    func sendInitialized() async throws
    func readRateLimits() async throws -> GetAccountRateLimitsRawResponse
    func terminate() async
}

protocol AppServerQuotaSessionFactory: Sendable {
    func makeSession() async throws -> any AppServerQuotaSession
}

struct ProductionAppServerQuotaSessionFactory: AppServerQuotaSessionFactory {
    func makeSession() async throws -> any AppServerQuotaSession {
        ProductionAppServerQuotaSession(client: CodexAppServerClient())
    }
}

private actor ProductionAppServerQuotaSession: AppServerQuotaSession {
    private let client: CodexAppServerClient
    private var generation: GenerationToken?

    init(client: CodexAppServerClient) {
        self.client = client
    }

    func launch() async throws {
        generation = try await client.connect(session: 0)
    }

    func initialize(clientInfo: ClientInfo) async throws {
        // The continuous client owns the complete handshake during connect().
    }

    func sendInitialized() async throws {
        // The continuous client owns the complete handshake during connect().
    }

    func readRateLimits() async throws -> GetAccountRateLimitsRawResponse {
        guard let generation else {
            throw CodexAppServerClientError.notConnected
        }
        return try await client.readRateLimitsRaw(generation: generation)
    }

    func terminate() async {
        generation = nil
        await client.disconnect()
    }
}

actor AppServerQuotaLoader: QuotaLoading {
    private static let clientInfo = ClientInfo(
        name: "CodexQuotaMonitor",
        version: "1.0"
    )

    private let sessionFactory: any AppServerQuotaSessionFactory
    private var session: (any AppServerQuotaSession)?
    private var inFlightLoad: Task<NormalizedQuota, any Error>?
    private var isTerminated = false

    init() {
        sessionFactory = ProductionAppServerQuotaSessionFactory()
    }

    internal init(sessionFactory: any AppServerQuotaSessionFactory) {
        self.sessionFactory = sessionFactory
    }

    func loadQuota() async throws -> NormalizedQuota {
        guard !isTerminated else {
            throw CancellationError()
        }
        if let inFlightLoad {
            return try await inFlightLoad.value
        }

        let task = Task { [self] in
            try await performLoad()
        }
        inFlightLoad = task

        do {
            let quota = try await task.value
            inFlightLoad = nil
            return quota
        } catch {
            inFlightLoad = nil
            throw error
        }
    }

    func terminate() async {
        isTerminated = true
        let loadToFinish = inFlightLoad
        loadToFinish?.cancel()
        await discardSession()
        if let loadToFinish {
            _ = await loadToFinish.result
        }
        inFlightLoad = nil
        await discardSession()
    }

    private func performLoad() async throws -> NormalizedQuota {
        var remainingRestarts = 1

        while true {
            try ensureActive()
            do {
                let activeSession = try await readySession()
                let rawResponse = try await activeSession.readRateLimits()
                try ensureActive()
                return try NormalizedQuota(rawResponse: rawResponse)
            } catch {
                if isTerminated || Task.isCancelled {
                    await discardSession()
                    throw CancellationError()
                }
                let shouldRestart = Self.isProcessExit(error) && remainingRestarts > 0
                await discardSession()
                if shouldRestart {
                    remainingRestarts -= 1
                    continue
                }
                throw error
            }
        }
    }

    private func readySession() async throws -> any AppServerQuotaSession {
        try ensureActive()
        if let session {
            return session
        }

        let newSession = try await sessionFactory.makeSession()
        guard !isTerminated, !Task.isCancelled else {
            await newSession.terminate()
            throw CancellationError()
        }
        session = newSession
        try await newSession.launch()
        try ensureActive()
        try await newSession.initialize(clientInfo: Self.clientInfo)
        try ensureActive()
        try await newSession.sendInitialized()
        try ensureActive()
        return newSession
    }

    private func ensureActive() throws {
        guard !isTerminated else {
            throw CancellationError()
        }
        try Task.checkCancellation()
    }

    private func discardSession() async {
        guard let session else {
            return
        }
        self.session = nil
        await session.terminate()
    }

    private static func isProcessExit(_ error: any Error) -> Bool {
        if let error = error as? CodexRPCClientError {
            return error == .processExited
        }
        if let error = error as? CodexRPCLineTransportError {
            return error == .processExited
        }
        if let error = error as? CodexAppServerClientError {
            return error == .processExited || error == .partialEOF
        }
        return false
    }
}
