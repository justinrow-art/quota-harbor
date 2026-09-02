import Foundation
import Observation

struct CodexQuotaObservation: Equatable, Sendable {
    let accountState: CapabilityState<ProviderAccountSummary>
    let rateState: CapabilityState<RateLimitCatalog>
    let usageState: CapabilityState<TokenActivitySnapshot>
}

@MainActor
protocol CodexQuotaObservationStreaming: Sendable {
    func makeStream() -> AsyncStream<CodexQuotaObservation>
}

protocol CodexRefreshCoordinating: Sendable {
    func start(sessionGeneration: UInt64) async
    func stop() async
}

extension RefreshCoordinator: CodexRefreshCoordinating {}

enum CodexConnectorLifecycleError: Error, Equatable, Sendable {
    case leaseExhausted
}

actor CodexConnectorLifecycle {
    private let coordinator: any CodexRefreshCoordinating
    private var nextLease: UInt64
    private var activeLease: UInt64?
    private var isStopping = false
    private var stopWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    init(
        coordinator: any CodexRefreshCoordinating,
        initialLease: UInt64 = 1
    ) {
        self.coordinator = coordinator
        nextLease = initialLease
    }

    func begin() async throws -> UInt64 {
        try await waitUntilStopped()
        try Task.checkCancellation()
        guard nextLease < UInt64.max else {
            activeLease = nil
            await stopCoordinator()
            throw CodexConnectorLifecycleError.leaseExhausted
        }

        let lease = nextLease
        nextLease += 1
        activeLease = lease
        await coordinator.start(sessionGeneration: lease)
        return lease
    }

    func finish(lease: UInt64) async {
        guard activeLease == lease else { return }
        activeLease = nil
        await stopCoordinator()
    }

#if DEBUG
    func pendingStopWaiterCountForTesting() -> Int {
        stopWaiters.count
    }
#endif

    private func waitUntilStopped() async throws {
        while isStopping {
            try Task.checkCancellation()
            let waiterID = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Void, Error>) in
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else if isStopping {
                        stopWaiters[waiterID] = continuation
                    } else {
                        continuation.resume()
                    }
                }
            } onCancel: {
                Task {
                    await self.cancelStopWaiter(id: waiterID)
                }
            }
        }
    }

    private func cancelStopWaiter(id: UUID) {
        stopWaiters.removeValue(forKey: id)?.resume(
            throwing: CancellationError()
        )
    }

    private func stopCoordinator() async {
        isStopping = true
        await coordinator.stop()
        isStopping = false
        let waiters = Array(stopWaiters.values)
        stopWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

struct CodexProviderConnector: ProviderConnector {
    let providerID: ProviderID = .codex

    private let observationSource: any CodexQuotaObservationStreaming
    private let lifecycle: CodexConnectorLifecycle

    init(
        observationSource: any CodexQuotaObservationStreaming,
        lifecycle: CodexConnectorLifecycle
    ) {
        self.observationSource = observationSource
        self.lifecycle = lifecycle
    }

    func run(
        publish: @escaping @Sendable (ProviderPresentationState) async -> Void
    ) async throws {
        let lease = try await lifecycle.begin()
        let stream = await observationSource.makeStream()

        for await observation in stream {
            if Task.isCancelled { break }
            await publish(
                CodexProviderSnapshotMapper.map(
                    rateState: observation.rateState,
                    usageState: observation.usageState,
                    accountState: observation.accountState
                )
            )
        }

        await lifecycle.finish(lease: lease)
        try Task.checkCancellation()
    }
}

@MainActor
final class CodexQuotaObservationSource: CodexQuotaObservationStreaming {
    private let store: QuotaStore
    private var subscriptions: [UUID: CodexQuotaObservationSubscription] = [:]

    init(store: QuotaStore) {
        self.store = store
    }

    func makeStream() -> AsyncStream<CodexQuotaObservation> {
        let pair = AsyncStream.makeStream(of: CodexQuotaObservation.self)
        let id = UUID()
        let subscription = CodexQuotaObservationSubscription(
            store: store,
            continuation: pair.continuation
        )
        subscriptions[id] = subscription
        pair.continuation.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.removeSubscription(id: id)
            }
        }
        subscription.start()
        return pair.stream
    }

    private func removeSubscription(id: UUID) {
        subscriptions.removeValue(forKey: id)?.cancel()
    }
}

@MainActor
private final class CodexQuotaObservationSubscription {
    private let store: QuotaStore
    private var continuation: AsyncStream<CodexQuotaObservation>.Continuation?
    private var lastObservation: CodexQuotaObservation?
    private var observationToken: UInt64 = 0
    private var isActive = true

    init(
        store: QuotaStore,
        continuation: AsyncStream<CodexQuotaObservation>.Continuation
    ) {
        self.store = store
        self.continuation = continuation
    }

    deinit {
        continuation?.finish()
    }

    func start() {
        observeAndYield()
    }

    func cancel() {
        guard isActive else { return }
        isActive = false
        continuation?.finish()
        continuation = nil
    }

    private func observeAndYield() {
        guard isActive,
              observationToken < UInt64.max
        else {
            cancel()
            return
        }
        observationToken += 1
        let token = observationToken
        let observation = withObservationTracking {
            CodexQuotaObservation(
                accountState: store.accountState,
                rateState: store.rateState,
                usageState: store.usageState
            )
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observationChanged(token: token)
            }
        }

        guard isActive, observationToken == token else { return }
        guard lastObservation != observation else { return }
        lastObservation = observation
        continuation?.yield(observation)
    }

    private func observationChanged(token: UInt64) {
        guard isActive, observationToken == token else { return }
        observeAndYield()
    }
}
