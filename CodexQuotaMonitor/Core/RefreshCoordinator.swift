import Foundation

enum RefreshTrigger: Equatable, Sendable {
    case launch
    case timer
    case manual
    case panelOpened
    case rateNotification
    case wake
    case reconnect
}

struct RefreshScheduling: Sendable {
    let monotonicNow: @Sendable () async -> Duration
    let wallNow: @Sendable () async -> Date
    let sleep: @Sendable (Duration) async throws -> Void
    let jitterUnit: @Sendable () async -> Double

    static func live() -> RefreshScheduling {
        let clock = ContinuousClock()
        let origin = clock.now
        return RefreshScheduling(
            monotonicNow: { origin.duration(to: clock.now) },
            wallNow: Date.init,
            sleep: { try await Task.sleep(for: $0) },
            jitterUnit: { Double.random(in: 0...1) }
        )
    }
}

struct RefreshCoordinatorConfiguration: Sendable {
    let timerInterval: Duration
    let staleAfter: Duration
    let notificationDebounce: Duration
    let restartWindow: Duration
    let restartLimit: Int
    let backoffBase: Duration
    let backoffCap: Duration
    let jitterFraction: Double

    static let standard = RefreshCoordinatorConfiguration(
        timerInterval: .seconds(300),
        staleAfter: .seconds(900),
        notificationDebounce: .milliseconds(250),
        restartWindow: .seconds(900),
        restartLimit: 3,
        backoffBase: .seconds(1),
        backoffCap: .seconds(30),
        jitterFraction: 0.2
    )
}

enum RefreshChange: Equatable, Sendable {
    case reset
    case account(CapabilityState<ProviderAccountSummary>)
    case rate(CapabilityState<RateLimitCatalog>)
    case usage(CapabilityState<TokenActivitySnapshot>)
    case manualRefresh(Bool)
}

struct RefreshPublication: Equatable, Sendable {
    let sequence: UInt64
    let generation: GenerationToken?
    let change: RefreshChange
}

protocol RefreshPublishing: Sendable {
    func apply(_ publication: RefreshPublication) async
}

protocol RefreshClient: Sendable {
    func connect(session: UInt64) async throws -> GenerationToken
    func readAccount(
        generation: GenerationToken
    ) async throws -> CodexAccountReadResult
    func readRateLimits(
        generation: GenerationToken
    ) async throws -> RateLimitCatalog
    func readUsage(
        generation: GenerationToken
    ) async throws -> TokenActivitySnapshot
    func notifications() async -> AsyncStream<AppServerNotification>
    func disconnect() async
}

extension CodexAppServerClient: RefreshClient {}

actor RefreshCoordinator {
    private struct Lanes: OptionSet, Sendable {
        let rawValue: UInt8

        static let rate = Lanes(rawValue: 1 << 0)
        static let usage = Lanes(rawValue: 1 << 1)
        static let full: Lanes = [.rate, .usage]
    }

    private struct LastGood<Value: Equatable & Sendable>: Sendable {
        let value: Value
        let wallDate: Date
        let monotonicDate: Duration
        let generation: GenerationToken
    }

    private struct RateReadOwner: Equatable, Sendable {
        let epoch: UInt64
        let generation: GenerationToken
    }

    private enum FailureDisposition: Sendable {
        case superseded
        case unsupported
        case unavailable(
            CapabilityFailure,
            restartable: Bool,
            invalidatesConnection: Bool
        )
    }

    private enum RateOutcome: Sendable {
        case success(RateLimitCatalog)
        case failure(FailureDisposition)
    }

    private enum UsageOutcome: Sendable {
        case success(TokenActivitySnapshot)
        case failure(FailureDisposition)
    }

    private enum AttemptResult: Sendable {
        case completed(rate: RateOutcome?, usage: UsageOutcome?)
        case restart(lane: Lanes, failure: CapabilityFailure)
        case superseded
    }

    private struct Superseded: Error {}

    private let client: any RefreshClient
    private let publisher: any RefreshPublishing
    private let scheduling: RefreshScheduling
    private let configuration: RefreshCoordinatorConfiguration

    private var isStarted = false
    private var isSessionActive = false
    private var sessionGeneration: UInt64 = 0
    private var lifecycleEpoch: UInt64 = 0

    private var publicationSequence: UInt64 = 0
    private var currentGeneration: GenerationToken?
    private var lastRateGood: LastGood<RateLimitCatalog>?
    private var lastUsageGood: LastGood<TokenActivitySnapshot>?

    private var pendingLanes: Lanes = []
    private var activeCycleLanes: Lanes = []
    private var cycleTask: Task<Void, Never>?
    private var activeCycleID: UInt64?
    private var nextCycleID: UInt64 = 1
    private var timerTask: Task<Void, Never>?
    private var notificationTask: Task<Void, Never>?
    private var notificationDebounceTask: Task<Void, Never>?
    private var activeDebounceID: UInt64?
    private var nextDebounceID: UInt64 = 1

    private var rateReadOwner: RateReadOwner?
    private var rateDirtyAgainRequested = false
    private var rateDirtyAgainUsed = false
    private var manualRefreshActive = false
    private var restartTimestamps: [Duration] = []

    init(
        client: any RefreshClient,
        publisher: any RefreshPublishing,
        scheduling: RefreshScheduling = .live(),
        configuration: RefreshCoordinatorConfiguration = .standard
    ) {
        self.client = client
        self.publisher = publisher
        self.scheduling = scheduling
        self.configuration = configuration
    }

    func start(sessionGeneration: UInt64) async {
        if isStarted,
           isSessionActive,
           self.sessionGeneration == sessionGeneration {
            return
        }
        guard let epoch = beginLifecycle(
            started: true,
            active: true,
            sessionGeneration: sessionGeneration
        ) else { return }

        guard await resetPublication(generation: nil, epoch: epoch) else {
            return
        }
        await client.disconnect()
        guard isCurrentLifecycle(epoch) else { return }
        startNotificationListener(epoch: epoch)
        startTimer(epoch: epoch)
        enqueue(.full, epoch: epoch)
    }

    func trigger(_ trigger: RefreshTrigger) async {
        guard isStarted, isSessionActive else { return }
        let epoch = lifecycleEpoch
        switch trigger {
        case .rateNotification:
            handleRateNotification(epoch: epoch)
        case .panelOpened:
            let now = await scheduling.monotonicNow()
            guard isCurrentLifecycle(epoch) else { return }
            if usageNeedsRefresh(at: now),
               !activeCycleLanes.contains(.usage),
               !pendingLanes.contains(.usage)
            {
                enqueue(.usage, epoch: epoch)
            }
        case .manual:
            manualRefreshActive = true
            await publishManualRefresh(true, epoch: epoch)
            guard isCurrentLifecycle(epoch) else { return }
            enqueue(.full, epoch: epoch)
        case .launch, .timer, .wake, .reconnect:
            enqueue(.full, epoch: epoch)
        }
    }

    func authenticationChanged() async {
        guard isStarted, isSessionActive else { return }
        guard let epoch = beginLifecycle(
            started: true,
            active: true,
            sessionGeneration: sessionGeneration
        ) else { return }
        guard await resetPublication(generation: nil, epoch: epoch) else {
            return
        }
        await client.disconnect()
        guard isCurrentLifecycle(epoch) else { return }
        startNotificationListener(epoch: epoch)
        startTimer(epoch: epoch)
        enqueue(.full, epoch: epoch)
    }

    func sessionResigned() async {
        guard isStarted, isSessionActive else { return }
        guard let epoch = beginLifecycle(
            started: true,
            active: false,
            sessionGeneration: sessionGeneration
        ) else { return }
        guard await resetPublication(generation: nil, epoch: epoch) else {
            return
        }
        await client.disconnect()
    }

    func sessionBecameActive() async {
        guard isStarted, !isSessionActive else { return }
        guard sessionGeneration < UInt64.max else {
            await stop()
            return
        }
        let nextSession = sessionGeneration + 1
        guard let epoch = beginLifecycle(
            started: true,
            active: true,
            sessionGeneration: nextSession
        ) else { return }
        guard await resetPublication(generation: nil, epoch: epoch) else {
            return
        }
        await client.disconnect()
        guard isCurrentLifecycle(epoch) else { return }
        startNotificationListener(epoch: epoch)
        startTimer(epoch: epoch)
        enqueue(.full, epoch: epoch)
    }

    func stop() async {
        guard isStarted else { return }
        guard let epoch = beginLifecycle(
            started: false,
            active: false,
            sessionGeneration: sessionGeneration
        ) else { return }
        guard await resetPublication(generation: nil, epoch: epoch) else {
            return
        }
        await client.disconnect()
    }

    func isIdleForTesting() -> Bool {
        cycleTask == nil
            && pendingLanes.isEmpty
            && notificationDebounceTask == nil
            && rateReadOwner == nil
    }

    private func beginLifecycle(
        started: Bool,
        active: Bool,
        sessionGeneration: UInt64
    ) -> UInt64? {
        guard lifecycleEpoch < UInt64.max else {
            isStarted = false
            isSessionActive = false
            cancelOwnedTasks()
            return nil
        }
        lifecycleEpoch += 1
        isStarted = started
        isSessionActive = active
        self.sessionGeneration = sessionGeneration
        cancelOwnedTasks()
        pendingLanes = []
        activeCycleLanes = []
        currentGeneration = nil
        lastRateGood = nil
        lastUsageGood = nil
        rateReadOwner = nil
        rateDirtyAgainRequested = false
        rateDirtyAgainUsed = false
        manualRefreshActive = false
        return lifecycleEpoch
    }

    private func cancelOwnedTasks() {
        cycleTask?.cancel()
        cycleTask = nil
        activeCycleID = nil
        activeCycleLanes = []
        timerTask?.cancel()
        timerTask = nil
        notificationTask?.cancel()
        notificationTask = nil
        notificationDebounceTask?.cancel()
        notificationDebounceTask = nil
        activeDebounceID = nil
    }

    private func startNotificationListener(epoch: UInt64) {
        guard notificationTask == nil else { return }
        let client = self.client
        notificationTask = Task { [weak self] in
            let notifications = await client.notifications()
            for await notification in notifications {
                guard !Task.isCancelled else { return }
                await self?.received(notification, epoch: epoch)
            }
        }
    }

    private func received(
        _ notification: AppServerNotification,
        epoch: UInt64
    ) async {
        guard isCurrentLifecycle(epoch) else { return }
        switch notification {
        case .rateLimitsUpdated:
            handleRateNotification(epoch: epoch)
        case .authenticationChanged:
            await authenticationChanged()
        }
    }

    private func startTimer(epoch: UInt64) {
        guard timerTask == nil else { return }
        let interval = configuration.timerInterval
        let sleep = scheduling.sleep
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await sleep(interval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self?.timerFired(epoch: epoch)
            }
        }
    }

    private func timerFired(epoch: UInt64) {
        guard isCurrentLifecycle(epoch) else { return }
        enqueue(.full, epoch: epoch)
    }

    private func handleRateNotification(epoch: UInt64) {
        guard isCurrentLifecycle(epoch) else { return }
        if rateReadOwner != nil {
            if !rateDirtyAgainUsed {
                rateDirtyAgainRequested = true
            }
            return
        }
        guard notificationDebounceTask == nil else { return }
        guard let debounceID = takeDebounceID() else { return }
        activeDebounceID = debounceID
        let delay = configuration.notificationDebounce
        let sleep = scheduling.sleep
        notificationDebounceTask = Task { [weak self] in
            do {
                try await sleep(delay)
            } catch {
                return
            }
            await self?.debounceFired(id: debounceID, epoch: epoch)
        }
    }

    private func debounceFired(id: UInt64, epoch: UInt64) {
        guard activeDebounceID == id else { return }
        notificationDebounceTask = nil
        activeDebounceID = nil
        guard isCurrentLifecycle(epoch) else { return }
        if rateReadOwner != nil {
            if !rateDirtyAgainUsed {
                rateDirtyAgainRequested = true
            }
            return
        }
        enqueue(.rate, epoch: epoch)
    }

    private func enqueue(_ lanes: Lanes, epoch: UInt64) {
        guard isCurrentLifecycle(epoch), !lanes.isEmpty else { return }
        pendingLanes.formUnion(lanes)
        guard cycleTask == nil, let cycleID = takeCycleID() else { return }
        activeCycleID = cycleID
        cycleTask = Task { [weak self] in
            await self?.drainCycles(id: cycleID, epoch: epoch)
        }
    }

    private func drainCycles(id: UInt64, epoch: UInt64) async {
        while isCurrentLifecycle(epoch), !pendingLanes.isEmpty {
            let lanes = pendingLanes
            pendingLanes = []
            activeCycleLanes = lanes
            await performCycle(lanes: lanes, epoch: epoch)
            guard isCurrentLifecycle(epoch), activeCycleID == id else {
                return
            }
            activeCycleLanes = []
        }
        guard activeCycleID == id else { return }
        activeCycleID = nil
        cycleTask = nil
        if manualRefreshActive {
            manualRefreshActive = false
            await publishManualRefresh(false, epoch: epoch)
        }
    }

    private func performCycle(lanes: Lanes, epoch: UInt64) async {
        var didRestart = false
        rateDirtyAgainRequested = false
        rateDirtyAgainUsed = false

        while isCurrentLifecycle(epoch) {
            let generation: GenerationToken
            do {
                generation = try await ensureConnected(epoch: epoch)
            } catch is Superseded {
                return
            } catch {
                let disposition = classify(error)
                if case .unavailable(_, true, _) = disposition,
                   !didRestart,
                   await restartConnection(epoch: epoch) {
                    didRestart = true
                    continue
                }
                await publishFailure(
                    disposition,
                    lanes: lanes,
                    generation: currentGeneration,
                    epoch: epoch
                )
                return
            }

            let attempt = await collectAttempt(
                lanes: lanes,
                generation: generation,
                epoch: epoch
            )
            switch attempt {
            case .superseded:
                return
            case let .restart(lane, failure):
                if !didRestart {
                    if await restartConnection(epoch: epoch) {
                        didRestart = true
                        continue
                    }
                    await retireConnection(epoch: epoch)
                    await publishUnavailable(
                        failure,
                        lanes: lanes,
                        generation: nil,
                        epoch: epoch
                    )
                    return
                }
                await salvageComplement(
                    requestedLanes: lanes,
                    failedLane: lane,
                    failure,
                    epoch: epoch
                )
                return
            case let .completed(rate, usage):
                await publishCompleted(
                    rate: rate,
                    usage: usage,
                    generation: generation,
                    epoch: epoch
                )
                return
            }
        }
    }

    private func salvageComplement(
        requestedLanes: Lanes,
        failedLane: Lanes,
        _ failure: CapabilityFailure,
        epoch: UInt64
    ) async {
        let complement = requestedLanes.subtracting(failedLane)
        guard !complement.isEmpty else {
            await retireConnection(epoch: epoch)
            await publishUnavailable(
                failure,
                lanes: failedLane,
                generation: nil,
                epoch: epoch
            )
            return
        }
        guard await restartConnection(epoch: epoch) else {
            await retireConnection(epoch: epoch)
            await publishUnavailable(
                failure,
                lanes: requestedLanes,
                generation: nil,
                epoch: epoch
            )
            return
        }

        let generation: GenerationToken
        do {
            generation = try await ensureConnected(epoch: epoch)
        } catch is Superseded {
            return
        } catch {
            await publishFailure(
                classify(error),
                lanes: requestedLanes,
                generation: currentGeneration,
                epoch: epoch
            )
            return
        }

        let attempt = await collectAttempt(
            lanes: complement,
            generation: generation,
            epoch: epoch
        )
        switch attempt {
        case .superseded:
            return
        case let .restart(_, salvageFailure):
            await retireConnection(epoch: epoch)
            await publishUnavailable(
                salvageFailure,
                lanes: requestedLanes,
                generation: nil,
                epoch: epoch
            )
        case let .completed(rate, usage):
            let failedDisposition = FailureDisposition.unavailable(
                failure,
                restartable: false,
                invalidatesConnection: false
            )
            await publishCompleted(
                rate: failedLane.contains(.rate)
                    ? .failure(failedDisposition)
                    : rate,
                usage: failedLane.contains(.usage)
                    ? .failure(failedDisposition)
                    : usage,
                generation: generation,
                epoch: epoch
            )
        }
    }

    private func ensureConnected(epoch: UInt64) async throws -> GenerationToken {
        if let currentGeneration { return currentGeneration }
        let generation = try await client.connect(session: sessionGeneration)
        guard isCurrentLifecycle(epoch) else {
            throw Superseded()
        }
        guard await resetPublication(
            generation: generation,
            epoch: epoch
        ) else {
            throw Superseded()
        }
        guard isCurrentLifecycle(epoch), currentGeneration == generation else {
            throw Superseded()
        }
        await readAndPublishAccount(
            generation: generation,
            epoch: epoch
        )
        guard isCurrentLifecycle(epoch), currentGeneration == generation else {
            throw Superseded()
        }
        return generation
    }

    private func readAndPublishAccount(
        generation: GenerationToken,
        epoch: UInt64
    ) async {
        let state: CapabilityState<ProviderAccountSummary>
        do {
            let result = try await client.readAccount(generation: generation)
            guard isCurrent(epoch: epoch, generation: generation) else {
                return
            }
            if let account = result.account {
                let date = await scheduling.wallNow()
                guard isCurrent(epoch: epoch, generation: generation) else {
                    return
                }
                state = .fresh(account, date)
            } else if result.requiresOpenaiAuth {
                state = .unavailable(.unauthenticated)
            } else {
                state = .unsupported
            }
        } catch {
            guard isCurrent(epoch: epoch, generation: generation) else {
                return
            }
            switch classify(error) {
            case .superseded:
                return
            case .unsupported:
                state = .unsupported
            case let .unavailable(failure, _, _):
                state = .unavailable(failure)
            }
        }
        await publish(
            .account(state),
            generation: generation,
            epoch: epoch
        )
    }

    private func collectAttempt(
        lanes: Lanes,
        generation: GenerationToken,
        epoch: UInt64
    ) async -> AttemptResult {
        var rateOutcome: RateOutcome?
        var usageOutcome: UsageOutcome?

        if lanes.contains(.rate) {
            let owner = RateReadOwner(epoch: epoch, generation: generation)
            rateReadOwner = owner
            rateOutcome = await readRate(generation: generation, epoch: epoch)
            if rateReadOwner == owner {
                rateReadOwner = nil
            }
            guard isCurrent(epoch: epoch, generation: generation) else {
                return .superseded
            }
            if case let .failure(disposition)? = rateOutcome {
                if case .superseded = disposition { return .superseded }
                if case let .unavailable(failure, true, _) = disposition {
                    return .restart(lane: .rate, failure: failure)
                }
            } else if rateDirtyAgainRequested, !rateDirtyAgainUsed {
                rateDirtyAgainRequested = false
                rateDirtyAgainUsed = true
                rateReadOwner = owner
                rateOutcome = await readRate(
                    generation: generation,
                    epoch: epoch
                )
                if rateReadOwner == owner {
                    rateReadOwner = nil
                }
                guard isCurrent(epoch: epoch, generation: generation) else {
                    return .superseded
                }
                if case let .failure(disposition)? = rateOutcome {
                    if case .superseded = disposition { return .superseded }
                    if case let .unavailable(failure, true, _) = disposition {
                        return .restart(lane: .rate, failure: failure)
                    }
                }
            }
        }

        if lanes.contains(.usage) {
            usageOutcome = await readUsage(
                generation: generation,
                epoch: epoch
            )
            guard isCurrent(epoch: epoch, generation: generation) else {
                return .superseded
            }
            if case let .failure(disposition)? = usageOutcome {
                if case .superseded = disposition { return .superseded }
                if case let .unavailable(failure, true, _) = disposition {
                    return .restart(lane: .usage, failure: failure)
                }
            }
        }
        return .completed(rate: rateOutcome, usage: usageOutcome)
    }

    private func readRate(
        generation: GenerationToken,
        epoch: UInt64
    ) async -> RateOutcome {
        do {
            let value = try await client.readRateLimits(generation: generation)
            guard isCurrent(epoch: epoch, generation: generation) else {
                return .failure(.superseded)
            }
            return .success(value)
        } catch {
            guard isCurrent(epoch: epoch, generation: generation) else {
                return .failure(.superseded)
            }
            return .failure(classify(error))
        }
    }

    private func readUsage(
        generation: GenerationToken,
        epoch: UInt64
    ) async -> UsageOutcome {
        do {
            let value = try await client.readUsage(generation: generation)
            guard isCurrent(epoch: epoch, generation: generation) else {
                return .failure(.superseded)
            }
            return .success(value)
        } catch {
            guard isCurrent(epoch: epoch, generation: generation) else {
                return .failure(.superseded)
            }
            return .failure(classify(error))
        }
    }

    private func publishCompleted(
        rate: RateOutcome?,
        usage: UsageOutcome?,
        generation: GenerationToken,
        epoch: UInt64
    ) async {
        guard isCurrent(epoch: epoch, generation: generation) else { return }
        let monotonicNow = await scheduling.monotonicNow()
        guard isCurrent(epoch: epoch, generation: generation) else { return }
        let wallNow = await scheduling.wallNow()
        guard isCurrent(epoch: epoch, generation: generation) else { return }

        if let rate {
            await publishRateOutcome(
                rate,
                generation: generation,
                monotonicNow: monotonicNow,
                wallNow: wallNow,
                epoch: epoch
            )
            guard isCurrent(epoch: epoch, generation: generation) else {
                return
            }
        }
        if let usage {
            await publishUsageOutcome(
                usage,
                generation: generation,
                monotonicNow: monotonicNow,
                wallNow: wallNow,
                epoch: epoch
            )
            guard isCurrent(epoch: epoch, generation: generation) else {
                return
            }
        }
        await markStaleIfNeeded(
            monotonicNow: monotonicNow,
            generation: generation,
            epoch: epoch
        )
    }

    private func publishRateOutcome(
        _ outcome: RateOutcome,
        generation: GenerationToken,
        monotonicNow: Duration,
        wallNow: Date,
        epoch: UInt64
    ) async {
        switch outcome {
        case let .success(value):
            lastRateGood = LastGood(
                value: value,
                wallDate: wallNow,
                monotonicDate: monotonicNow,
                generation: generation
            )
            await publish(
                .rate(.fresh(value, wallNow)),
                generation: generation,
                epoch: epoch
            )
        case let .failure(disposition):
            await publishRateFailure(
                disposition,
                generation: generation,
                epoch: epoch
            )
        }
    }

    private func publishUsageOutcome(
        _ outcome: UsageOutcome,
        generation: GenerationToken,
        monotonicNow: Duration,
        wallNow: Date,
        epoch: UInt64
    ) async {
        switch outcome {
        case let .success(value):
            lastUsageGood = LastGood(
                value: value,
                wallDate: wallNow,
                monotonicDate: monotonicNow,
                generation: generation
            )
            await publish(
                .usage(.fresh(value, wallNow)),
                generation: generation,
                epoch: epoch
            )
        case let .failure(disposition):
            await publishUsageFailure(
                disposition,
                generation: generation,
                epoch: epoch
            )
        }
    }

    private func publishRateFailure(
        _ disposition: FailureDisposition,
        generation: GenerationToken,
        epoch: UInt64
    ) async {
        switch disposition {
        case .superseded:
            return
        case .unsupported:
            lastRateGood = nil
            await publish(.rate(.unsupported), generation: generation, epoch: epoch)
        case let .unavailable(failure, _, _):
            guard lastRateGood?.generation == generation else {
                await publish(
                    .rate(.unavailable(failure)),
                    generation: generation,
                    epoch: epoch
                )
                return
            }
        }
    }

    private func publishUsageFailure(
        _ disposition: FailureDisposition,
        generation: GenerationToken,
        epoch: UInt64
    ) async {
        switch disposition {
        case .superseded:
            return
        case .unsupported:
            lastUsageGood = nil
            await publish(.usage(.unsupported), generation: generation, epoch: epoch)
        case let .unavailable(failure, _, _):
            guard lastUsageGood?.generation == generation else {
                await publish(
                    .usage(.unavailable(failure)),
                    generation: generation,
                    epoch: epoch
                )
                return
            }
        }
    }

    private func markStaleIfNeeded(
        monotonicNow: Duration,
        generation: GenerationToken,
        epoch: UInt64
    ) async {
        if let lastRateGood,
           lastRateGood.generation == generation,
           monotonicNow - lastRateGood.monotonicDate >= configuration.staleAfter {
            await publish(
                .rate(.stale(
                    lastRateGood.value,
                    lastRateGood.wallDate,
                    .stale
                )),
                generation: generation,
                epoch: epoch
            )
        }
        if let lastUsageGood,
           lastUsageGood.generation == generation,
           monotonicNow - lastUsageGood.monotonicDate >= configuration.staleAfter {
            await publish(
                .usage(.stale(
                    lastUsageGood.value,
                    lastUsageGood.wallDate,
                    .stale
                )),
                generation: generation,
                epoch: epoch
            )
        }
    }

    private func publishFailure(
        _ disposition: FailureDisposition,
        lanes: Lanes,
        generation: GenerationToken?,
        epoch: UInt64
    ) async {
        switch disposition {
        case .superseded:
            return
        case .unsupported:
            if lanes.contains(.rate) {
                await publish(.rate(.unsupported), generation: generation, epoch: epoch)
            }
            if lanes.contains(.usage) {
                await publish(.usage(.unsupported), generation: generation, epoch: epoch)
            }
        case let .unavailable(failure, _, invalidatesConnection):
            if invalidatesConnection {
                await retireConnection(epoch: epoch)
            }
            await publishUnavailable(
                failure,
                lanes: lanes,
                generation: invalidatesConnection ? nil : generation,
                epoch: epoch
            )
        }
    }

    private func publishUnavailable(
        _ failure: CapabilityFailure,
        lanes: Lanes,
        generation: GenerationToken?,
        epoch: UInt64
    ) async {
        if lanes.contains(.rate) {
            await publish(
                .rate(.unavailable(failure)),
                generation: generation,
                epoch: epoch
            )
        }
        if lanes.contains(.usage) {
            await publish(
                .usage(.unavailable(failure)),
                generation: generation,
                epoch: epoch
            )
        }
    }

    private func restartConnection(epoch: UInt64) async -> Bool {
        guard let delay = await takeRestartDelay(epoch: epoch) else {
            return false
        }
        await retireConnection(epoch: epoch)
        guard isCurrentLifecycle(epoch) else { return false }
        do {
            try await scheduling.sleep(delay)
        } catch {
            return false
        }
        return isCurrentLifecycle(epoch)
    }

    private func takeRestartDelay(epoch: UInt64) async -> Duration? {
        let unit = min(1, max(0, await scheduling.jitterUnit()))
        guard isCurrentLifecycle(epoch) else { return nil }
        let now = await scheduling.monotonicNow()
        guard isCurrentLifecycle(epoch) else { return nil }
        restartTimestamps.removeAll { timestamp in
            now >= timestamp && now - timestamp >= configuration.restartWindow
        }
        guard configuration.restartLimit > 0,
              restartTimestamps.count < configuration.restartLimit else {
            return nil
        }
        let exponent = restartTimestamps.count
        restartTimestamps.append(now)
        let base = configuration.backoffBase.secondsDouble
        let cap = configuration.backoffCap.secondsDouble
        let exponential = base * pow(2, Double(exponent))
        let jittered = exponential * (1 + configuration.jitterFraction * unit)
        return .seconds(min(cap, max(0, jittered)))
    }

    private func retireConnection(epoch: UInt64) async {
        guard isCurrentLifecycle(epoch) else { return }
        guard await resetPublication(generation: nil, epoch: epoch),
              isCurrentLifecycle(epoch) else {
            return
        }
        await client.disconnect()
    }

    private func resetPublication(
        generation: GenerationToken?,
        epoch: UInt64
    ) async -> Bool {
        guard lifecycleEpoch == epoch else { return false }
        guard publicationSequence < UInt64.max else {
            isStarted = false
            isSessionActive = false
            cancelOwnedTasks()
            return false
        }
        publicationSequence += 1
        currentGeneration = generation
        lastRateGood = nil
        lastUsageGood = nil
        let sequence = publicationSequence
        await publisher.apply(
            RefreshPublication(
                sequence: sequence,
                generation: generation,
                change: .reset
            )
        )
        guard lifecycleEpoch == epoch,
              publicationSequence == sequence,
              currentGeneration == generation else {
            return false
        }
        if manualRefreshActive {
            await publisher.apply(
                RefreshPublication(
                    sequence: sequence,
                    generation: generation,
                    change: .manualRefresh(true)
                )
            )
            guard lifecycleEpoch == epoch,
                  publicationSequence == sequence,
                  currentGeneration == generation else {
                return false
            }
        }
        return true
    }

    private func publish(
        _ change: RefreshChange,
        generation: GenerationToken?,
        epoch: UInt64
    ) async {
        guard isCurrentLifecycle(epoch), currentGeneration == generation else {
            return
        }
        await publisher.apply(
            RefreshPublication(
                sequence: publicationSequence,
                generation: generation,
                change: change
            )
        )
    }

    private func publishManualRefresh(_ active: Bool, epoch: UInt64) async {
        guard isCurrentLifecycle(epoch) else { return }
        await publisher.apply(
            RefreshPublication(
                sequence: publicationSequence,
                generation: currentGeneration,
                change: .manualRefresh(active)
            )
        )
    }

    private func usageNeedsRefresh(at now: Duration) -> Bool {
        guard let lastUsageGood,
              lastUsageGood.generation == currentGeneration else {
            return true
        }
        return now - lastUsageGood.monotonicDate >= configuration.staleAfter
    }

    private func classify(_ error: any Error) -> FailureDisposition {
        if error is CancellationError || error is Superseded {
            return .superseded
        }
        if let trustError = error as? CodexExecutableTrustError {
            let failure: CapabilityFailure = switch trustError {
            case .missingPath: .binaryNotFound
            default: .trustValidationFailed
            }
            return .unavailable(
                failure,
                restartable: false,
                invalidatesConnection: false
            )
        }
        if error is CodexTrustManifestLoadingError {
            return .unavailable(
                .trustValidationFailed,
                restartable: false,
                invalidatesConnection: false
            )
        }
        if error is AppServerProcessLaunchError {
            return .unavailable(
                .processLaunchFailed,
                restartable: false,
                invalidatesConnection: false
            )
        }
        guard let error = error as? CodexAppServerClientError else {
            return .unavailable(
                .temporaryBackend,
                restartable: false,
                invalidatesConnection: false
            )
        }
        switch error {
        case .staleGeneration:
            return .superseded
        case let .serverError(code) where code == -32601:
            return .unsupported
        case .invalidRequest, .lineTooLong, .malformedJSON, .invalidResponse:
            return .unavailable(
                .invalidSchema,
                restartable: false,
                invalidatesConnection: false
            )
        case .processExited, .partialEOF, .timedOut,
             .transportFailure, .notConnected:
            return .unavailable(
                .temporaryTransport,
                restartable: true,
                invalidatesConnection: true
            )
        case .serverError:
            return .unavailable(
                .serverRejected,
                restartable: false,
                invalidatesConnection: false
            )
        }
    }

    private func isCurrentLifecycle(_ epoch: UInt64) -> Bool {
        isStarted && isSessionActive && lifecycleEpoch == epoch
    }

    private func isCurrent(
        epoch: UInt64,
        generation: GenerationToken
    ) -> Bool {
        isCurrentLifecycle(epoch) && currentGeneration == generation
    }

    private func takeCycleID() -> UInt64? {
        guard nextCycleID < UInt64.max else { return nil }
        let value = nextCycleID
        nextCycleID += 1
        return value
    }

    private func takeDebounceID() -> UInt64? {
        guard nextDebounceID < UInt64.max else { return nil }
        let value = nextDebounceID
        nextDebounceID += 1
        return value
    }
}

private extension Duration {
    var secondsDouble: Double {
        let components = self.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
