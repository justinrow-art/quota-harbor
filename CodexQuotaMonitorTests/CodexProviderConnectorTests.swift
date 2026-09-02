import Foundation
import XCTest
@testable import CodexQuotaMonitor

@MainActor
final class CodexProviderConnectorTests: XCTestCase {
    func testCodexMapperMapsDynamicWindowsWithoutFixedDurationAssumptions() throws {
        let observedAt = Date(timeIntervalSince1970: 1_753_027_200)
        let catalog = try makeCodexRateCatalog(
            windows: [
                (bucket: "codex", slot: .secondary, duration: nil, used: 100, reset: nil),
                (bucket: "codex", slot: .primary, duration: 360, used: 25, reset: 1_753_030_800),
                (bucket: "alpha", slot: .secondary, duration: 10_080, used: 30, reset: nil),
                (bucket: "alpha", slot: .primary, duration: 60, used: 40, reset: nil),
                (bucket: "zeta", slot: .primary, duration: 720, used: 50, reset: nil),
            ],
            emptyBucketKeys: ["empty"]
        )
        let identity = try XCTUnwrap(
            MaskedAccountIdentity.maskingEmail("alice" + "@example.com")
        )

        let state = CodexProviderSnapshotMapper.map(
            rateState: .fresh(catalog, observedAt),
            usageState: .unsupported,
            accountState: .fresh(
                ProviderAccountSummary(maskedIdentity: identity),
                observedAt.addingTimeInterval(-60)
            )
        )

        guard case let .fresh(snapshot) = state else {
            return XCTFail("Expected fresh mapped snapshot")
        }
        XCTAssertEqual(snapshot.metrics.count, 5)
        XCTAssertEqual(Set(snapshot.metrics.map(\.metricKey)).count, 5)
        let expectedIdentities = [
            WindowIdentity(
                bucketKey: "codex",
                sourceSlot: .primary,
                durationMinutes: 360
            ),
            WindowIdentity(
                bucketKey: "codex",
                sourceSlot: .secondary,
                durationMinutes: nil
            ),
            WindowIdentity(
                bucketKey: "alpha",
                sourceSlot: .primary,
                durationMinutes: 60
            ),
            WindowIdentity(
                bucketKey: "alpha",
                sourceSlot: .secondary,
                durationMinutes: 10_080
            ),
            WindowIdentity(
                bucketKey: "zeta",
                sourceSlot: .primary,
                durationMinutes: 720
            ),
        ]
        XCTAssertEqual(
            snapshot.metrics.map(\.metricKey),
            try expectedIdentities.map {
                try XCTUnwrap(ProviderMetricKey.codexRateLimitWindow($0))
            }
        )
        XCTAssertEqual(
            snapshot.metrics.map(\.remainingFraction),
            [0.75, 0, 0.6, 0.7, 0.5]
        )
        XCTAssertEqual(
            snapshot.metrics.map(\.durationMinutes),
            [360, nil, 60, 10_080, 720]
        )
        XCTAssertEqual(
            snapshot.metrics.compactMap(\.resetAt),
            [Date(timeIntervalSince1970: 1_753_030_800)]
        )
        XCTAssertFalse(
            snapshot.metrics.contains {
                $0.metricKey.stableID.contains("five-hour")
                    || $0.metricKey.stableID.contains("weekly")
            }
        )
        XCTAssertEqual(snapshot.accountSummary?.maskedIdentity, identity)
        XCTAssertEqual(snapshot.tokenActivity, .unsupported)
        XCTAssertEqual(snapshot.capturedAt, observedAt)
    }

    func testCodexMapperMakesFreshTokenOnlySnapshotWhenRateIsUnavailable() {
        let capturedAt = Date(timeIntervalSince1970: 1_753_027_200)
        let usage = makeCodexUsageSnapshot(tokens: 42)

        let state = CodexProviderSnapshotMapper.map(
            rateState: .unavailable(.temporaryTransport),
            usageState: .fresh(usage, capturedAt),
            accountState: .unsupported
        )

        guard case let .fresh(snapshot) = state else {
            return XCTFail("Expected usable token lane to preserve snapshot")
        }
        XCTAssertEqual(snapshot.metrics, [])
        guard case let .fresh(activity, observedAt)? = snapshot.tokenActivity else {
            return XCTFail("Expected fresh token activity")
        }
        XCTAssertEqual(observedAt, capturedAt)
        XCTAssertEqual(activity.today.inputTokens, .notReturned)
        XCTAssertEqual(activity.today.outputTokens, .notReturned)
        XCTAssertEqual(activity.today.totalTokens, .available(42))
        XCTAssertEqual(activity.currentMonth.inputTokens, .notReturned)
        XCTAssertEqual(activity.currentMonth.outputTokens, .notReturned)
        XCTAssertEqual(activity.currentMonth.totalTokens, .partial(42, reason: "calendarGap"))
    }

    func testCodexMapperUsesConservativeStaleTopLevelForMixedUsableLanes() throws {
        let capturedAt = Date(timeIntervalSince1970: 1_753_027_200)
        let rateObservedAt = capturedAt.addingTimeInterval(-120)
        let usageObservedAt = capturedAt.addingTimeInterval(-60)
        let catalog = try makeCodexRateCatalog(
            windows: [
                (bucket: "codex", slot: .primary, duration: 300, used: 10, reset: nil),
            ]
        )
        let usage = makeCodexUsageSnapshot(tokens: 42)

        for (rateState, usageState) in [
            (
                CapabilityState.fresh(catalog, rateObservedAt),
                CapabilityState.stale(usage, usageObservedAt, .stale)
            ),
            (
                CapabilityState.stale(catalog, rateObservedAt, .stale),
                CapabilityState.fresh(usage, usageObservedAt)
            ),
        ] {
            let state = CodexProviderSnapshotMapper.map(
                rateState: rateState,
                usageState: usageState,
                accountState: .unsupported
            )

            guard case let .stale(snapshot) = state else {
                return XCTFail("Any usable stale lane must make the snapshot stale")
            }
            XCTAssertEqual(snapshot.capturedAt, rateObservedAt)
            switch snapshot.tokenActivity {
            case let .fresh(_, date)?, let .stale(_, date, _)? :
                XCTAssertEqual(date, usageObservedAt)
            default:
                XCTFail("Token lane did not preserve its own observation date")
            }
        }
    }

    func testCodexMapperUsesAccountUnauthenticatedWhenQuotaLanesUnsupported() {
        XCTAssertEqual(
            CodexProviderSnapshotMapper.map(
                rateState: .unsupported,
                usageState: .unsupported,
                accountState: .unavailable(.unauthenticated)
            ),
            .notConnected
        )
    }

    func testCodexMapperDoesNotCreateSnapshotFromFreshAccountOnly() {
        let account = ProviderAccountSummary(maskedIdentity: nil)

        XCTAssertEqual(
            CodexProviderSnapshotMapper.map(
                rateState: .unsupported,
                usageState: .unsupported,
                accountState: .fresh(
                    account,
                    Date(timeIntervalSince1970: 1_700_000_000)
                )
            ),
            .unsupported
        )
    }

    func testCodexMapperAccountStaleDoesNotChangeQuotaDateOrFreshness() throws {
        let rateObservedAt = Date(timeIntervalSince1970: 1_753_027_200)
        let accountObservedAt = rateObservedAt.addingTimeInterval(-3_600)
        let account = ProviderAccountSummary(
            maskedIdentity: try XCTUnwrap(
                MaskedAccountIdentity.maskingEmail("alice" + "@example.com")
            )
        )
        let catalog = try makeCodexRateCatalog(
            windows: [
                (bucket: "codex", slot: .primary, duration: 300, used: 20, reset: nil),
            ]
        )

        let state = CodexProviderSnapshotMapper.map(
            rateState: .fresh(catalog, rateObservedAt),
            usageState: .unsupported,
            accountState: .stale(account, accountObservedAt, .stale)
        )

        guard case let .fresh(snapshot) = state else {
            return XCTFail("Account staleness must not make fresh quota stale")
        }
        XCTAssertEqual(snapshot.capturedAt, rateObservedAt)
        XCTAssertEqual(snapshot.accountSummary, account)
    }

    func testCodexObservationSourceSynchronouslyIncludesInitialStateAndChanges() async throws {
        let store = QuotaStore()
        let source = CodexQuotaObservationSource(store: store)
        let stream = source.makeStream()
        var iterator = stream.makeAsyncIterator()

        let initialValue = await iterator.next()
        let initial = try XCTUnwrap(initialValue)
        XCTAssertEqual(initial.accountState, .loading)
        XCTAssertEqual(initial.rateState, .loading)
        XCTAssertEqual(initial.usageState, .loading)

        let generation = GenerationToken(auth: 1, session: 1, connection: 1)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let catalog = try makeCodexRateCatalog(windows: [
            ("codex", .primary, 300, 25, nil),
        ])
        await store.apply(RefreshPublication(
            sequence: 1,
            generation: generation,
            change: .reset
        ))
        await store.apply(RefreshPublication(
            sequence: 1,
            generation: generation,
            change: .rate(.fresh(catalog, date))
        ))

        let changedValue = await iterator.next()
        let changed = try XCTUnwrap(changedValue)
        XCTAssertEqual(changed.rateState, .fresh(catalog, date))
    }

    func testCodexObservationSourceDeduplicatesEqualSnapshotsWithoutPolling() async {
        let store = QuotaStore()
        let source = CodexQuotaObservationSource(store: store)
        let recorder = CodexObservationRecorder()
        let task = Task {
            for await observation in source.makeStream() {
                await recorder.append(observation)
            }
        }
        await assertEventually { await recorder.count() == 1 }

        await store.apply(RefreshPublication(
            sequence: 1,
            generation: nil,
            change: .reset
        ))
        await drainTasks()
        let countAfterEqualReset = await recorder.count()
        XCTAssertEqual(countAfterEqualReset, 1)

        await store.apply(RefreshPublication(
            sequence: 1,
            generation: nil,
            change: .account(.unsupported)
        ))
        await assertEventually { await recorder.count() == 2 }
        task.cancel()
        await task.value
    }

    func testCodexObservationSourceTerminationBlocksOldCallbacks() async throws {
        let store = QuotaStore()
        let source = CodexQuotaObservationSource(store: store)
        let recorder = CodexObservationRecorder()
        let oldTask = Task {
            for await observation in source.makeStream() {
                await recorder.append(observation)
            }
        }
        await assertEventually { await recorder.count() == 1 }

        oldTask.cancel()
        await oldTask.value
        await store.apply(RefreshPublication(
            sequence: 1,
            generation: nil,
            change: .reset
        ))
        await store.apply(RefreshPublication(
            sequence: 1,
            generation: nil,
            change: .account(.unsupported)
        ))
        await drainTasks()
        let oldCount = await recorder.count()
        XCTAssertEqual(oldCount, 1)

        var newIterator = source.makeStream().makeAsyncIterator()
        let currentValue = await newIterator.next()
        let current = try XCTUnwrap(currentValue)
        XCTAssertEqual(current.accountState, .unsupported)
    }

    func testCodexConnectorContinuouslyMapsObservedStoreState() async throws {
        let store = QuotaStore()
        let source = CodexQuotaObservationSource(store: store)
        let coordinator = RecordingCodexRefreshCoordinator()
        let lifecycle = CodexConnectorLifecycle(coordinator: coordinator)
        let connector = CodexProviderConnector(
            observationSource: source,
            lifecycle: lifecycle
        )
        let recorder = ProviderStateRecorder()
        let task = Task {
            try await connector.run { state in
                await recorder.append(state)
            }
        }
        await assertEventually {
            let states = await recorder.states()
            return states.first == .loading
        }

        let generation = GenerationToken(auth: 1, session: 1, connection: 1)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let catalog = try makeCodexRateCatalog(windows: [
            ("codex", .primary, 300, 25, nil),
        ])
        await store.apply(RefreshPublication(
            sequence: 1,
            generation: generation,
            change: .reset
        ))
        await store.apply(RefreshPublication(
            sequence: 1,
            generation: generation,
            change: .account(.unavailable(.serverRejected))
        ))
        await store.apply(RefreshPublication(
            sequence: 1,
            generation: generation,
            change: .rate(.fresh(catalog, date))
        ))
        await assertEventually {
            let states = await recorder.states()
            guard case .fresh? = states.last else {
                return false
            }
            return true
        }

        task.cancel()
        _ = await task.result
        let statistics = await coordinator.statistics()
        XCTAssertEqual(statistics.startedSessions, [1])
        XCTAssertEqual(statistics.completedStops, 1)
    }

    func testCodexConnectorStartsLeaseBeforeCapturingInitialObservation() async throws {
        let store = QuotaStore()
        let oldGeneration = GenerationToken(
            auth: 1,
            session: 1,
            connection: 1
        )
        let oldCatalog = try makeCodexRateCatalog(windows: [
            ("codex", .primary, 300, 10, nil),
        ])
        await store.apply(RefreshPublication(
            sequence: 1,
            generation: oldGeneration,
            change: .reset
        ))
        await store.apply(RefreshPublication(
            sequence: 1,
            generation: oldGeneration,
            change: .rate(
                .fresh(
                    oldCatalog,
                    Date(timeIntervalSince1970: 1_700_000_000)
                )
            )
        ))

        let connector = CodexProviderConnector(
            observationSource: CodexQuotaObservationSource(store: store),
            lifecycle: CodexConnectorLifecycle(
                coordinator: StoreResettingCodexRefreshCoordinator(
                    store: store,
                    resetSequence: 2
                )
            )
        )
        let recorder = ProviderStateRecorder()
        let task = Task {
            try await connector.run { state in
                await recorder.append(state)
            }
        }

        await assertEventually { await recorder.states().count >= 1 }
        let states = await recorder.states()
        XCTAssertEqual(
            states.first,
            .loading,
            "A new lease must not publish the pre-reset fresh snapshot"
        )

        task.cancel()
        _ = await task.result
    }

    func testCodexConnectorCancellationAwaitsCoordinatorStop() async {
        let gate = CodexTestGate()
        let coordinator = RecordingCodexRefreshCoordinator(stopGate: gate)
        let connector = CodexProviderConnector(
            observationSource: CodexQuotaObservationSource(store: QuotaStore()),
            lifecycle: CodexConnectorLifecycle(coordinator: coordinator)
        )
        let completion = CodexCompletionProbe()
        let task = Task {
            do {
                try await connector.run { _ in }
            } catch {
                // Cancellation is the expected test exit.
            }
            await completion.markCompleted()
        }
        await assertEventually {
            await coordinator.statistics().startedSessions == [1]
        }

        task.cancel()
        await assertEventually {
            await coordinator.statistics().startedStops == 1
        }
        let completedBeforeStop = await completion.isCompleted()
        XCTAssertFalse(completedBeforeStop)

        await gate.open()
        await task.value
        let completedAfterStop = await completion.isCompleted()
        let statistics = await coordinator.statistics()
        XCTAssertTrue(completedAfterStop)
        XCTAssertEqual(statistics.completedStops, 1)
    }

    func testCancelledBeginWaitingForStopNeverStartsOrLeaksWaiter() async throws {
        let stopGate = CodexTestGate()
        let coordinator = RecordingCodexRefreshCoordinator(stopGate: stopGate)
        let lifecycle = CodexConnectorLifecycle(coordinator: coordinator)
        let oldLease = try await lifecycle.begin()
        let oldFinishTask = Task {
            await lifecycle.finish(lease: oldLease)
        }
        await assertEventually {
            await coordinator.statistics().startedStops == 1
        }

        let secondCompleted = CodexCompletionProbe()
        let secondTask = Task {
            do {
                _ = try await lifecycle.begin()
            } catch {
                // Cancellation is the expected queued-begin exit.
            }
            await secondCompleted.markCompleted()
        }
        await assertEventually {
            await lifecycle.pendingStopWaiterCountForTesting() == 1
        }

        secondTask.cancel()
        await assertEventually {
            await lifecycle.pendingStopWaiterCountForTesting() == 0
        }
        await assertEventually { await secondCompleted.isCompleted() }
        let statisticsBeforeStopRelease = await coordinator.statistics()
        XCTAssertEqual(statisticsBeforeStopRelease.completedStops, 0)

        await stopGate.open()
        await oldFinishTask.value
        await secondTask.value
        let statistics = await coordinator.statistics()
        XCTAssertEqual(statistics.startedSessions, [1])
        XCTAssertEqual(statistics.startedStops, 1)
        XCTAssertEqual(statistics.completedStops, 1)
    }

    func testRapidCodexReenableMakesOldCleanupUnableToStopNewLease() async {
        let coordinator = RecordingCodexRefreshCoordinator()
        let lifecycle = CodexConnectorLifecycle(coordinator: coordinator)
        let connector = CodexProviderConnector(
            observationSource: CodexQuotaObservationSource(store: QuotaStore()),
            lifecycle: lifecycle
        )
        let oldPublishGate = CodexTestGate()
        let oldPublishEntered = CodexCompletionProbe()
        let oldTask = Task {
            do {
                try await connector.run { _ in
                    await oldPublishEntered.markCompleted()
                    await oldPublishGate.wait()
                }
            } catch {
                // Cancellation is the expected test exit.
            }
        }
        await assertEventually { await oldPublishEntered.isCompleted() }
        oldTask.cancel()

        let newRecorder = ProviderStateRecorder()
        let newTask = Task {
            do {
                try await connector.run { state in
                    await newRecorder.append(state)
                }
            } catch {
                // Cancellation is the expected test exit.
            }
        }
        await assertEventually {
            await coordinator.statistics().startedSessions == [1, 2]
        }
        await oldPublishGate.open()
        await oldTask.value
        let statisticsBeforeNewCancellation = await coordinator.statistics()
        XCTAssertEqual(statisticsBeforeNewCancellation.startedStops, 0)

        newTask.cancel()
        await newTask.value
        let statistics = await coordinator.statistics()
        XCTAssertEqual(statistics.startedStops, 1)
        XCTAssertEqual(statistics.completedStops, 1)
    }

    func testCodexConnectorLeaseOverflowStopsSafelyWithoutWrapping() async {
        let coordinator = RecordingCodexRefreshCoordinator()
        let lifecycle = CodexConnectorLifecycle(
            coordinator: coordinator,
            initialLease: UInt64.max
        )

        do {
            _ = try await lifecycle.begin()
            XCTFail("Expected lease exhaustion")
        } catch {
            XCTAssertEqual(
                error as? CodexConnectorLifecycleError,
                .leaseExhausted
            )
        }
        let statistics = await coordinator.statistics()
        XCTAssertTrue(statistics.startedSessions.isEmpty)
        XCTAssertEqual(statistics.completedStops, 1)
    }


    func testCodexMapperMapsNoUsableLaneStatesByStablePrecedence() {
        typealias RateState = CapabilityState<RateLimitCatalog>
        typealias UsageState = CapabilityState<TokenActivitySnapshot>
        let cases: [(RateState, UsageState, ProviderPresentationState)] = [
            (.loading, .loading, .loading),
            (.unsupported, .loading, .loading),
            (.unavailable(.unauthenticated), .loading, .notConnected),
            (.unsupported, .unsupported, .unsupported),
            (
                .unavailable(.temporaryTransport),
                .unsupported,
                .failed(code: .connectorFailed)
            ),
            (
                .unsupported,
                .unavailable(.invalidSchema),
                .failed(code: .connectorFailed)
            ),
        ]

        for (rateState, usageState, expected) in cases {
            XCTAssertEqual(
                CodexProviderSnapshotMapper.map(
                    rateState: rateState,
                    usageState: usageState,
                    accountState: .unsupported
                ),
                expected
            )
        }
    }

    func testCodexMapperDoesNotLetAccountFailureReplaceUsableRateData() throws {
        let capturedAt = Date(timeIntervalSince1970: 1_753_027_200)
        let catalog = try makeCodexRateCatalog(
            windows: [
                (bucket: "codex", slot: .primary, duration: 300, used: 20, reset: nil),
            ]
        )

        let state = CodexProviderSnapshotMapper.map(
            rateState: .fresh(catalog, capturedAt),
            usageState: .unsupported,
            accountState: .unavailable(.temporaryBackend)
        )

        guard case let .fresh(snapshot) = state else {
            return XCTFail("Account failure must not replace usable rate data")
        }
        XCTAssertEqual(snapshot.metrics.first?.remainingFraction, 0.8)
        XCTAssertNil(snapshot.accountSummary)
        XCTAssertEqual(snapshot.tokenActivity, .unsupported)
    }


    private func drainTasks() async {
        for _ in 0..<10 {
            await Task.yield()
        }
    }

    private func assertEventually(
        _ condition: @escaping @MainActor @Sendable () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1_000 {
            if await condition() {
                return
            }
            await Task.yield()
        }
        XCTFail("Condition did not become true", file: file, line: line)
    }

    private func makeCodexRateCatalog(
        windows: [(
            bucket: String,
            slot: SourceSlot,
            duration: Int64?,
            used: Int,
            reset: Int64?
        )],
        emptyBucketKeys: [String] = []
    ) throws -> RateLimitCatalog {
        var buckets: [String: RateLimitBucket] = [:]
        for (bucketKey, rows) in Dictionary(grouping: windows, by: \.bucket) {
            let rateWindows = try rows.map { row in
                try RateLimitWindow(
                    identity: WindowIdentity(
                        bucketKey: row.bucket,
                        sourceSlot: row.slot,
                        durationMinutes: row.duration
                    ),
                    usedPercent: row.used,
                    resetsAt: row.reset
                )
            }
            buckets[bucketKey] = RateLimitBucket(
                bucketKey: rows[0].bucket,
                windows: rateWindows
            )
        }
        for bucketKey in emptyBucketKeys {
            buckets[bucketKey] = RateLimitBucket(
                bucketKey: bucketKey,
                windows: []
            )
        }
        return RateLimitCatalog(
            rateLimitsByLimitId: buckets,
            legacyBucket: RateLimitBucket(
                bucketKey: RateLimitCatalog.legacyBucketKey,
                windows: []
            )
        )
    }

    private func makeCodexUsageSnapshot(tokens: Int64) -> TokenActivitySnapshot {
        TokenActivitySnapshot(
            rawResponse: GetAccountTokenUsageRawResponse(
                summary: AccountTokenUsageSummaryRaw(
                    lifetimeTokens: tokens,
                    peakDailyTokens: tokens,
                    longestRunningTurnSec: nil,
                    currentStreakDays: nil,
                    longestStreakDays: nil
                ),
                dailyUsageBuckets: [
                    AccountTokenUsageDayRaw(
                        startDate: "2025-07-20",
                        tokens: tokens
                    ),
                ]
            )
        )
    }
}

private actor CodexObservationRecorder {
    private var observations: [CodexQuotaObservation] = []

    func append(_ observation: CodexQuotaObservation) {
        observations.append(observation)
    }

    func count() -> Int {
        observations.count
    }
}

private actor ProviderStateRecorder {
    private var recordedStates: [ProviderPresentationState] = []

    func append(_ state: ProviderPresentationState) {
        recordedStates.append(state)
    }

    func states() -> [ProviderPresentationState] {
        recordedStates
    }
}

private struct RecordingCodexCoordinatorStatistics: Sendable {
    let startedSessions: [UInt64]
    let startedStops: Int
    let completedStops: Int
}

private actor RecordingCodexRefreshCoordinator: CodexRefreshCoordinating {
    private let stopGate: CodexTestGate?
    private var startedSessions: [UInt64] = []
    private var startedStops = 0
    private var completedStops = 0

    init(stopGate: CodexTestGate? = nil) {
        self.stopGate = stopGate
    }

    func start(sessionGeneration: UInt64) async {
        startedSessions.append(sessionGeneration)
    }

    func stop() async {
        startedStops += 1
        await stopGate?.wait()
        completedStops += 1
    }

    func statistics() -> RecordingCodexCoordinatorStatistics {
        RecordingCodexCoordinatorStatistics(
            startedSessions: startedSessions,
            startedStops: startedStops,
            completedStops: completedStops
        )
    }
}

private actor StoreResettingCodexRefreshCoordinator:
    CodexRefreshCoordinating
{
    private let store: QuotaStore
    private let resetSequence: UInt64

    init(store: QuotaStore, resetSequence: UInt64) {
        self.store = store
        self.resetSequence = resetSequence
    }

    func start(sessionGeneration: UInt64) async {
        await store.apply(RefreshPublication(
            sequence: resetSequence,
            generation: nil,
            change: .reset
        ))
    }

    func stop() async {}
}

private actor CodexTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let resumptions = waiters
        waiters.removeAll()
        for continuation in resumptions {
            continuation.resume()
        }
    }
}

private actor CodexCompletionProbe {
    private var completed = false

    func markCompleted() {
        completed = true
    }

    func isCompleted() -> Bool {
        completed
    }
}
