import Foundation
import XCTest
@testable import CodexQuotaMonitor

final class ClaudeProviderConnectorTests: XCTestCase {
    func testInitialPollMapsBothQuotaWindowsWithoutAnIdentity() async throws {
        let now = Date(timeIntervalSince1970: 1_753_027_200)
        let fiveHourReset = now.addingTimeInterval(3_600)
        let sevenDayReset = now.addingTimeInterval(86_400)
        let cache = ScriptedClaudeCacheLoader([
            makeCacheSnapshot(
                fiveHourUsed: 12.5,
                fiveHourReset: fiveHourReset,
                sevenDayUsed: 34,
                sevenDayReset: sevenDayReset,
                receivedAt: now
            ),
        ])
        let auth = ScriptedClaudeAuthFetcher([.connected])
        let sleeper = ManualClaudeProviderSleeper()
        let clock = LockedClaudeProviderClock(now)
        let recorder = ClaudeProviderStateRecorder()
        let connector = ClaudeProviderConnector(
            authFetcher: auth,
            cacheLoader: cache,
            sleeper: sleeper,
            now: { clock.now() }
        )

        let task = Task {
            try await connector.run { state in
                await recorder.append(state)
            }
        }
        try await waitUntil { await recorder.count() == 1 }

        let states = await recorder.states()
        let state = try XCTUnwrap(states.first)
        guard case let .fresh(snapshot) = state else {
            task.cancel()
            await sleeper.resumeAll()
            _ = await task.result
            return XCTFail("Expected a fresh Claude snapshot")
        }
        XCTAssertEqual(snapshot.providerID, .claudeCode)
        XCTAssertEqual(snapshot.capturedAt, now)
        XCTAssertEqual(snapshot.accountSummary, ProviderAccountSummary(maskedIdentity: nil))
        XCTAssertNil(snapshot.accountSummary?.maskedIdentity)
        XCTAssertNil(snapshot.runtimePresence)
        XCTAssertNil(snapshot.tokenActivity)
        XCTAssertEqual(snapshot.metrics.count, 2)
        XCTAssertEqual(snapshot.metrics.map(\.metricKey.stableID), ["five_hour", "seven_day"])
        XCTAssertEqual(snapshot.metrics[0].remainingFraction, 0.875, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.metrics[1].remainingFraction, 0.66, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.metrics.map(\.resetAt), [fiveHourReset, sevenDayReset])
        XCTAssertEqual(snapshot.metrics.map(\.durationMinutes), [300, 10_080])
        let authFetchCount = await auth.fetchCount()
        let cacheLoadCount = await cache.loadCount()
        let sleepDurations = await sleeper.recordedDurations()
        XCTAssertEqual(authFetchCount, 1)
        XCTAssertEqual(cacheLoadCount, 1)
        XCTAssertEqual(sleepDurations, [.seconds(30)])

        task.cancel()
        await sleeper.resumeAll()
        _ = await task.result
    }

    func testConnectedWithoutCachePublishesFreshEmptySnapshot() async throws {
        let now = Date(timeIntervalSince1970: 1_753_027_200)
        let auth = ScriptedClaudeAuthFetcher([.connected])
        let cache = ScriptedClaudeCacheLoader([nil])
        let sleeper = ManualClaudeProviderSleeper()
        let recorder = ClaudeProviderStateRecorder()
        let connector = ClaudeProviderConnector(
            authFetcher: auth,
            cacheLoader: cache,
            sleeper: sleeper,
            now: { now }
        )

        let task = run(connector, recorder: recorder)
        try await waitUntil { await recorder.count() == 1 }

        let states = await recorder.states()
        guard case let .fresh(snapshot) = try XCTUnwrap(states.first) else {
            await stop(task, sleeper: sleeper)
            return XCTFail("Missing relay data is not unsupported or zero quota")
        }
        XCTAssertEqual(snapshot.metrics, [])
        XCTAssertEqual(snapshot.capturedAt, now)
        XCTAssertEqual(
            snapshot.accountSummary,
            ProviderAccountSummary(maskedIdentity: nil)
        )
        await stop(task, sleeper: sleeper)
    }

    func testConnectedRejectsCacheReceivedInTheFuture() async throws {
        let now = Date(timeIntervalSince1970: 1_753_027_200)
        let futureCaches = [1.0, 86_400.0].map { offset in
            makeCacheSnapshot(
                fiveHourUsed: 25,
                fiveHourReset: now.addingTimeInterval(300),
                receivedAt: now.addingTimeInterval(offset)
            )
        }
        let auth = ScriptedClaudeAuthFetcher(
            [.connected],
            fallback: .connected
        )
        let cache = ScriptedClaudeCacheLoader(futureCaches)
        let sleeper = ManualClaudeProviderSleeper()
        let recorder = ClaudeProviderStateRecorder()
        let connector = ClaudeProviderConnector(
            authFetcher: auth,
            cacheLoader: cache,
            sleeper: sleeper,
            now: { now }
        )

        let task = run(connector, recorder: recorder)
        try await waitForPoll(1, recorder: recorder, sleeper: sleeper)
        await sleeper.resumeNext()
        try await waitForPoll(2, recorder: recorder, sleeper: sleeper)

        let states = await recorder.states()
        XCTAssertEqual(states.count, 2)
        for state in states {
            guard case let .fresh(snapshot) = state else {
                XCTFail("A connected provider without valid cache should stay fresh")
                continue
            }
            XCTAssertEqual(snapshot.metrics, [])
            XCTAssertEqual(snapshot.capturedAt, now)
        }
        await stop(task, sleeper: sleeper)
    }

    func testFirstAuthFailurePublishesFailedWithoutUsingCache() async throws {
        let now = Date(timeIntervalSince1970: 1_753_027_200)
        let cached = makeCacheSnapshot(
            fiveHourUsed: 25,
            fiveHourReset: now.addingTimeInterval(300),
            receivedAt: now
        )
        let auth = ScriptedClaudeAuthFetcher([
            .failed(code: .commandFailed),
        ])
        let cache = ScriptedClaudeCacheLoader([cached])
        let sleeper = ManualClaudeProviderSleeper()
        let recorder = ClaudeProviderStateRecorder()
        let connector = ClaudeProviderConnector(
            authFetcher: auth,
            cacheLoader: cache,
            sleeper: sleeper,
            now: { now }
        )

        let task = run(connector, recorder: recorder)
        try await waitUntil { await recorder.count() == 1 }

        let states = await recorder.states()
        XCTAssertEqual(states, [.failed(code: .connectorFailed)])
        await stop(task, sleeper: sleeper)
    }

    func testSingleLoopPollsCacheEveryThirtySecondsAndAuthEveryTenthTick() async throws {
        let now = Date(timeIntervalSince1970: 1_753_027_200)
        let events = ClaudeProviderEventLog()
        let auth = ScriptedClaudeAuthFetcher(
            [.connected, .connected],
            fallback: .connected,
            events: events
        )
        let cache = ScriptedClaudeCacheLoader(
            Array(repeating: nil, count: 11),
            events: events
        )
        let sleeper = ManualClaudeProviderSleeper()
        let recorder = ClaudeProviderStateRecorder()
        let connector = ClaudeProviderConnector(
            authFetcher: auth,
            cacheLoader: cache,
            sleeper: sleeper,
            now: { now }
        )

        let task = run(connector, recorder: recorder)
        try await waitForPoll(
            1,
            recorder: recorder,
            sleeper: sleeper
        )
        for poll in 2...10 {
            await sleeper.resumeNext()
            try await waitForPoll(
                poll,
                recorder: recorder,
                sleeper: sleeper
            )
        }

        let authCountBeforeTenthTick = await auth.fetchCount()
        let cacheCountBeforeTenthTick = await cache.loadCount()
        XCTAssertEqual(authCountBeforeTenthTick, 1)
        XCTAssertEqual(cacheCountBeforeTenthTick, 10)

        await sleeper.resumeNext()
        try await waitForPoll(
            11,
            recorder: recorder,
            sleeper: sleeper
        )

        let authCount = await auth.fetchCount()
        let cacheCount = await cache.loadCount()
        let durations = await sleeper.recordedDurations()
        let recordedEvents = await events.events()
        XCTAssertEqual(authCount, 2)
        XCTAssertEqual(cacheCount, 11)
        XCTAssertEqual(durations, Array(repeating: .seconds(30), count: 11))
        XCTAssertEqual(
            recordedEvents,
            ["auth", "cache"]
                + Array(repeating: "cache", count: 9)
                + ["auth", "cache"]
        )
        await stop(task, sleeper: sleeper)
    }

    func testCacheAtStaleBoundaryIsStaleAndYoungerCacheIsFresh() async throws {
        let now = Date(timeIntervalSince1970: 1_753_027_200)

        for (age, expectedFreshness) in [
            (899.999, "fresh"),
            (900.0, "stale"),
        ] {
            let cacheDate = now.addingTimeInterval(-age)
            let cached = makeCacheSnapshot(
                fiveHourUsed: 25,
                fiveHourReset: now.addingTimeInterval(300),
                receivedAt: cacheDate
            )
            let auth = ScriptedClaudeAuthFetcher([.connected])
            let cache = ScriptedClaudeCacheLoader([cached])
            let sleeper = ManualClaudeProviderSleeper()
            let recorder = ClaudeProviderStateRecorder()
            let connector = ClaudeProviderConnector(
                authFetcher: auth,
                cacheLoader: cache,
                sleeper: sleeper,
                now: { now }
            )

            let task = run(connector, recorder: recorder)
            try await waitUntil { await recorder.count() == 1 }
            let states = await recorder.states()
            let state = try XCTUnwrap(states.first)
            switch (expectedFreshness, state) {
            case ("fresh", .fresh), ("stale", .stale):
                break
            default:
                XCTFail("Expected \(expectedFreshness) at age \(age), got \(state)")
            }
            await stop(task, sleeper: sleeper)
        }
    }

    func testNegativeSnapshotAgeIsNeverFresh() async throws {
        let start = Date(timeIntervalSince1970: 1_753_027_200)
        let clock = LockedClaudeProviderClock(start)
        let cached = makeCacheSnapshot(
            fiveHourUsed: 25,
            fiveHourReset: start.addingTimeInterval(300),
            receivedAt: start
        )
        let auth = ScriptedClaudeAuthFetcher(
            [.connected],
            fallback: .connected
        )
        let cache = ScriptedClaudeCacheLoader([cached, nil])
        let sleeper = ManualClaudeProviderSleeper()
        let recorder = ClaudeProviderStateRecorder()
        let connector = ClaudeProviderConnector(
            authFetcher: auth,
            cacheLoader: cache,
            sleeper: sleeper,
            now: { clock.now() }
        )

        let task = run(connector, recorder: recorder)
        try await waitForPoll(1, recorder: recorder, sleeper: sleeper)
        clock.set(start.addingTimeInterval(-1))
        await sleeper.resumeNext()
        try await waitForPoll(2, recorder: recorder, sleeper: sleeper)

        let states = await recorder.states()
        guard case .fresh = states[0] else {
            await stop(task, sleeper: sleeper)
            return XCTFail("The initial zero-age snapshot should be fresh")
        }
        guard case let .stale(snapshot) = states[1] else {
            await stop(task, sleeper: sleeper)
            return XCTFail("A negative snapshot age must never be fresh")
        }
        XCTAssertEqual(snapshot.capturedAt, start)
        XCTAssertEqual(snapshot.metrics.first?.remainingFraction, 0.75)
        await stop(task, sleeper: sleeper)
    }

    func testClockRollbackAcceptsValidCacheFromTheNewTimeline() async throws {
        let start = Date(timeIntervalSince1970: 1_753_027_200)
        let rolledBack = start.addingTimeInterval(-60)
        let initial = makeCacheSnapshot(
            fiveHourUsed: 20,
            fiveHourReset: start.addingTimeInterval(300),
            receivedAt: start
        )
        let validAfterRollback = makeCacheSnapshot(
            fiveHourUsed: 40,
            fiveHourReset: rolledBack.addingTimeInterval(300),
            receivedAt: rolledBack
        )
        let auth = ScriptedClaudeAuthFetcher(
            [.connected],
            fallback: .connected
        )
        let cache = ScriptedClaudeCacheLoader([
            initial,
            validAfterRollback,
        ])
        let sleeper = ManualClaudeProviderSleeper()
        let recorder = ClaudeProviderStateRecorder()
        let clock = LockedClaudeProviderClock(start)
        let connector = ClaudeProviderConnector(
            authFetcher: auth,
            cacheLoader: cache,
            sleeper: sleeper,
            now: { clock.now() }
        )

        let task = run(connector, recorder: recorder)
        try await waitForPoll(1, recorder: recorder, sleeper: sleeper)
        clock.set(rolledBack)
        await sleeper.resumeNext()
        try await waitForPoll(2, recorder: recorder, sleeper: sleeper)

        let states = await recorder.states()
        guard case let .fresh(snapshot) = states[1] else {
            await stop(task, sleeper: sleeper)
            return XCTFail("The new timeline's valid cache should be fresh")
        }
        XCTAssertEqual(snapshot.capturedAt, rolledBack)
        XCTAssertEqual(snapshot.metrics.first?.remainingFraction, 0.6)
        await stop(task, sleeper: sleeper)
    }

    func testOlderAndMissingCacheCannotReplaceNewestAcceptedSnapshot() async throws {
        let now = Date(timeIntervalSince1970: 1_753_027_200)
        let newer = makeCacheSnapshot(
            fiveHourUsed: 20,
            fiveHourReset: now.addingTimeInterval(300),
            receivedAt: now
        )
        let older = makeCacheSnapshot(
            fiveHourUsed: 80,
            fiveHourReset: now.addingTimeInterval(300),
            receivedAt: now.addingTimeInterval(-30)
        )
        let auth = ScriptedClaudeAuthFetcher([.connected], fallback: .connected)
        let cache = ScriptedClaudeCacheLoader([newer, older, nil])
        let sleeper = ManualClaudeProviderSleeper()
        let recorder = ClaudeProviderStateRecorder()
        let connector = ClaudeProviderConnector(
            authFetcher: auth,
            cacheLoader: cache,
            sleeper: sleeper,
            now: { now }
        )

        let task = run(connector, recorder: recorder)
        try await waitForPoll(1, recorder: recorder, sleeper: sleeper)
        for poll in 2...3 {
            await sleeper.resumeNext()
            try await waitForPoll(
                poll,
                recorder: recorder,
                sleeper: sleeper
            )
        }

        let states = await recorder.states()
        XCTAssertEqual(states.count, 3)
        for state in states {
            guard case let .fresh(snapshot) = state else {
                XCTFail("Expected last accepted snapshot to remain usable")
                continue
            }
            XCTAssertEqual(snapshot.capturedAt, now)
            let remaining = try XCTUnwrap(
                snapshot.metrics.first?.remainingFraction
            )
            XCTAssertEqual(
                remaining,
                0.8,
                accuracy: 0.000_001
            )
        }
        await stop(task, sleeper: sleeper)
    }

    func testLogoutClearsDataAndSameOldCacheCannotResurrectOnReconnect() async throws {
        let start = Date(timeIntervalSince1970: 1_753_027_200)
        let clock = LockedClaudeProviderClock(start)
        let oldCache = makeCacheSnapshot(
            fiveHourUsed: 20,
            fiveHourReset: start.addingTimeInterval(300),
            receivedAt: start
        )
        let newCache = makeCacheSnapshot(
            fiveHourUsed: 40,
            fiveHourReset: start.addingTimeInterval(600),
            receivedAt: start.addingTimeInterval(1)
        )
        let auth = ScriptedClaudeAuthFetcher([
            .connected,
            .notConnected,
            .connected,
        ], fallback: .connected)
        let cache = ScriptedClaudeCacheLoader(
            Array(repeating: oldCache, count: 21) + [newCache]
        )
        let sleeper = ManualClaudeProviderSleeper()
        let recorder = ClaudeProviderStateRecorder()
        let connector = ClaudeProviderConnector(
            authFetcher: auth,
            cacheLoader: cache,
            sleeper: sleeper,
            now: { clock.now() }
        )

        let task = run(connector, recorder: recorder)
        try await waitForPoll(1, recorder: recorder, sleeper: sleeper)
        for poll in 2...22 {
            if poll == 22 {
                clock.set(start.addingTimeInterval(1))
            }
            await sleeper.resumeNext()
            try await waitForPoll(
                poll,
                recorder: recorder,
                sleeper: sleeper
            )
        }

        let states = await recorder.states()
        XCTAssertEqual(states[10], .notConnected)
        guard case let .fresh(reconnected) = states[20] else {
            await stop(task, sleeper: sleeper)
            return XCTFail("Reconnect should be connected but awaiting newer relay data")
        }
        XCTAssertEqual(reconnected.metrics, [])
        guard case let .fresh(updated) = states[21] else {
            await stop(task, sleeper: sleeper)
            return XCTFail("New relay data should become visible")
        }
        let remaining = try XCTUnwrap(
            updated.metrics.first?.remainingFraction
        )
        XCTAssertEqual(
            remaining,
            0.6,
            accuracy: 0.000_001
        )
        XCTAssertEqual(updated.capturedAt, newCache.receivedAt)
        await stop(task, sleeper: sleeper)
    }

    func testInitialLogoutMarksExistingCacheOldBeforeReconnect() async throws {
        let start = Date(timeIntervalSince1970: 1_753_027_200)
        let oldCache = makeCacheSnapshot(
            fiveHourUsed: 20,
            fiveHourReset: start.addingTimeInterval(300),
            receivedAt: start
        )
        let auth = ScriptedClaudeAuthFetcher([
            .notConnected,
            .connected,
        ])
        let cache = ScriptedClaudeCacheLoader(
            Array(repeating: oldCache, count: 11)
        )
        let sleeper = ManualClaudeProviderSleeper()
        let recorder = ClaudeProviderStateRecorder()
        let connector = ClaudeProviderConnector(
            authFetcher: auth,
            cacheLoader: cache,
            sleeper: sleeper,
            now: { start }
        )

        let task = run(connector, recorder: recorder)
        try await waitForPoll(1, recorder: recorder, sleeper: sleeper)
        for poll in 2...11 {
            await sleeper.resumeNext()
            try await waitForPoll(
                poll,
                recorder: recorder,
                sleeper: sleeper
            )
        }

        let states = await recorder.states()
        XCTAssertEqual(states[0], .notConnected)
        guard case let .fresh(reconnected) = states[10] else {
            await stop(task, sleeper: sleeper)
            return XCTFail("Reconnect should await relay data newer than logout")
        }
        XCTAssertEqual(reconnected.metrics, [])
        await stop(task, sleeper: sleeper)
    }

    func testDelayedPreLogoutCacheCannotResurrectWhenLogoutPollHadNoCache()
        async throws
    {
        let logoutAt = Date(timeIntervalSince1970: 1_753_027_200)
        let preLogoutCache = makeCacheSnapshot(
            fiveHourUsed: 20,
            fiveHourReset: logoutAt.addingTimeInterval(300),
            receivedAt: logoutAt.addingTimeInterval(-1)
        )
        let auth = ScriptedClaudeAuthFetcher([
            .notConnected,
            .connected,
        ], fallback: .connected)
        let cache = ScriptedClaudeCacheLoader(
            [nil] + Array(repeating: preLogoutCache, count: 10)
        )
        let sleeper = ManualClaudeProviderSleeper()
        let recorder = ClaudeProviderStateRecorder()
        let connector = ClaudeProviderConnector(
            authFetcher: auth,
            cacheLoader: cache,
            sleeper: sleeper,
            now: { logoutAt }
        )

        let task = run(connector, recorder: recorder)
        try await waitForPoll(1, recorder: recorder, sleeper: sleeper)
        for poll in 2...11 {
            await sleeper.resumeNext()
            try await waitForPoll(
                poll,
                recorder: recorder,
                sleeper: sleeper
            )
        }

        let states = await recorder.states()
        XCTAssertEqual(states[0], .notConnected)
        guard case let .fresh(reconnected) = states[10] else {
            await stop(task, sleeper: sleeper)
            return XCTFail("Reconnect should reject relay data older than logout")
        }
        XCTAssertEqual(reconnected.metrics, [])
        XCTAssertEqual(reconnected.capturedAt, logoutAt)
        await stop(task, sleeper: sleeper)
    }

    func testClockRollbackCannotResurrectDelayedPreLogoutCacheOnReconnect()
        async throws
    {
        let logoutAt = Date(timeIntervalSince1970: 1_753_027_200)
        let rolledBack = logoutAt.addingTimeInterval(-60)
        let preLogoutCache = makeCacheSnapshot(
            fiveHourUsed: 20,
            fiveHourReset: logoutAt.addingTimeInterval(300),
            receivedAt: logoutAt.addingTimeInterval(-120)
        )
        let clock = LockedClaudeProviderClock(logoutAt)
        let auth = ScriptedClaudeAuthFetcher([
            .notConnected,
            .connected,
        ], fallback: .connected)
        let cache = ScriptedClaudeCacheLoader(
            [nil] + Array(repeating: preLogoutCache, count: 10)
        )
        let sleeper = ManualClaudeProviderSleeper()
        let recorder = ClaudeProviderStateRecorder()
        let connector = ClaudeProviderConnector(
            authFetcher: auth,
            cacheLoader: cache,
            sleeper: sleeper,
            now: { clock.now() }
        )

        let task = run(connector, recorder: recorder)
        try await waitForPoll(1, recorder: recorder, sleeper: sleeper)
        clock.set(rolledBack)
        for poll in 2...11 {
            await sleeper.resumeNext()
            try await waitForPoll(
                poll,
                recorder: recorder,
                sleeper: sleeper
            )
        }

        let states = await recorder.states()
        XCTAssertEqual(states[0], .notConnected)
        guard case let .fresh(reconnected) = states[10] else {
            await stop(task, sleeper: sleeper)
            return XCTFail("Clock rollback must preserve the logout barrier")
        }
        XCTAssertEqual(reconnected.metrics, [])
        XCTAssertEqual(reconnected.capturedAt, rolledBack)
        await stop(task, sleeper: sleeper)
    }

    func testRepeatedLoggedOutAuthPollCannotLowerBarrierAfterClockRollback()
        async throws
    {
        let logoutAt = Date(timeIntervalSince1970: 1_753_027_200)
        let rolledBack = logoutAt.addingTimeInterval(-120)
        let reconnectAt = logoutAt.addingTimeInterval(-60)
        let preLogoutCache = makeCacheSnapshot(
            fiveHourUsed: 20,
            fiveHourReset: logoutAt.addingTimeInterval(300),
            receivedAt: reconnectAt
        )
        let clock = LockedClaudeProviderClock(logoutAt)
        let auth = ScriptedClaudeAuthFetcher([
            .notConnected,
            .notConnected,
            .connected,
        ], fallback: .connected)
        let cache = ScriptedClaudeCacheLoader(
            Array<ClaudeStatusLineSnapshot?>(repeating: nil, count: 11)
                + Array(repeating: preLogoutCache, count: 10)
        )
        let sleeper = ManualClaudeProviderSleeper()
        let recorder = ClaudeProviderStateRecorder()
        let connector = ClaudeProviderConnector(
            authFetcher: auth,
            cacheLoader: cache,
            sleeper: sleeper,
            now: { clock.now() }
        )

        let task = run(connector, recorder: recorder)
        try await waitForPoll(1, recorder: recorder, sleeper: sleeper)
        clock.set(rolledBack)
        for poll in 2...11 {
            await sleeper.resumeNext()
            try await waitForPoll(
                poll,
                recorder: recorder,
                sleeper: sleeper
            )
        }
        clock.set(reconnectAt)
        for poll in 12...21 {
            await sleeper.resumeNext()
            try await waitForPoll(
                poll,
                recorder: recorder,
                sleeper: sleeper
            )
        }

        let states = await recorder.states()
        XCTAssertEqual(states[0], .notConnected)
        XCTAssertEqual(states[10], .notConnected)
        guard case let .fresh(reconnected) = states[20] else {
            await stop(task, sleeper: sleeper)
            return XCTFail("Repeated logout polls must not lower the barrier")
        }
        XCTAssertEqual(reconnected.metrics, [])
        XCTAssertEqual(reconnected.capturedAt, reconnectAt)
        await stop(task, sleeper: sleeper)
    }

    func testCacheCreatedAfterLogoutPollIsAcceptedOnReconnect() async throws {
        let start = Date(timeIntervalSince1970: 1_753_027_200)
        let updatedAt = start.addingTimeInterval(1)
        let clock = LockedClaudeProviderClock(start)
        let oldCache = makeCacheSnapshot(
            fiveHourUsed: 20,
            fiveHourReset: start.addingTimeInterval(300),
            receivedAt: start
        )
        let newCache = makeCacheSnapshot(
            fiveHourUsed: 40,
            fiveHourReset: start.addingTimeInterval(600),
            receivedAt: updatedAt
        )
        let auth = ScriptedClaudeAuthFetcher([
            .notConnected,
            .connected,
        ], fallback: .connected)
        let cache = ScriptedClaudeCacheLoader(
            [oldCache] + Array(repeating: newCache, count: 10)
        )
        let sleeper = ManualClaudeProviderSleeper()
        let recorder = ClaudeProviderStateRecorder()
        let connector = ClaudeProviderConnector(
            authFetcher: auth,
            cacheLoader: cache,
            sleeper: sleeper,
            now: { clock.now() }
        )

        let task = run(connector, recorder: recorder)
        try await waitForPoll(1, recorder: recorder, sleeper: sleeper)
        clock.set(updatedAt)
        for poll in 2...11 {
            await sleeper.resumeNext()
            try await waitForPoll(
                poll,
                recorder: recorder,
                sleeper: sleeper
            )
        }

        let states = await recorder.states()
        XCTAssertEqual(states[0], .notConnected)
        guard case let .fresh(reconnected) = states[10] else {
            await stop(task, sleeper: sleeper)
            return XCTFail("Reconnect should accept relay data newer than logout")
        }
        XCTAssertEqual(reconnected.capturedAt, updatedAt)
        XCTAssertEqual(
            try XCTUnwrap(reconnected.metrics.first?.remainingFraction),
            0.6,
            accuracy: 0.000_001
        )
        await stop(task, sleeper: sleeper)
    }

    func testAcceptedPostLogoutCacheClearsBarrierBeforeConnectedClockRollback()
        async throws
    {
        let logoutAt = Date(timeIntervalSince1970: 1_753_027_200)
        let postLogoutAt = logoutAt.addingTimeInterval(1)
        let rolledBack = logoutAt.addingTimeInterval(-60)
        let postLogoutCache = makeCacheSnapshot(
            fiveHourUsed: 40,
            fiveHourReset: postLogoutAt.addingTimeInterval(300),
            receivedAt: postLogoutAt
        )
        let newTimelineCache = makeCacheSnapshot(
            fiveHourUsed: 20,
            fiveHourReset: rolledBack.addingTimeInterval(300),
            receivedAt: rolledBack
        )
        let clock = LockedClaudeProviderClock(logoutAt)
        let auth = ScriptedClaudeAuthFetcher([
            .notConnected,
            .connected,
        ], fallback: .connected)
        let cache = ScriptedClaudeCacheLoader(
            Array<ClaudeStatusLineSnapshot?>(repeating: nil, count: 10)
                + [postLogoutCache, newTimelineCache]
        )
        let sleeper = ManualClaudeProviderSleeper()
        let recorder = ClaudeProviderStateRecorder()
        let connector = ClaudeProviderConnector(
            authFetcher: auth,
            cacheLoader: cache,
            sleeper: sleeper,
            now: { clock.now() }
        )

        let task = run(connector, recorder: recorder)
        try await waitForPoll(1, recorder: recorder, sleeper: sleeper)
        clock.set(postLogoutAt)
        for poll in 2...11 {
            await sleeper.resumeNext()
            try await waitForPoll(
                poll,
                recorder: recorder,
                sleeper: sleeper
            )
        }

        var states = await recorder.states()
        guard case let .fresh(postLogout) = states[10] else {
            await stop(task, sleeper: sleeper)
            return XCTFail("Reconnect should accept the post-logout cache")
        }
        XCTAssertEqual(postLogout.capturedAt, postLogoutAt)
        XCTAssertEqual(postLogout.metrics.first?.remainingFraction, 0.6)

        clock.set(rolledBack)
        await sleeper.resumeNext()
        try await waitForPoll(12, recorder: recorder, sleeper: sleeper)

        states = await recorder.states()
        guard case let .fresh(newTimeline) = states[11] else {
            await stop(task, sleeper: sleeper)
            return XCTFail("Accepted post-logout data should clear the barrier")
        }
        XCTAssertEqual(newTimeline.capturedAt, rolledBack)
        XCTAssertEqual(newTimeline.metrics.first?.remainingFraction, 0.8)
        await stop(task, sleeper: sleeper)
    }

    func testFutureCacheDuringLogoutDoesNotPoisonValidCacheAfterReconnect() async throws {
        let now = Date(timeIntervalSince1970: 1_753_027_200)
        let validAt = now.addingTimeInterval(1)
        let clock = LockedClaudeProviderClock(now)
        let future = makeCacheSnapshot(
            fiveHourUsed: 90,
            fiveHourReset: now.addingTimeInterval(300),
            receivedAt: now.addingTimeInterval(86_400)
        )
        let valid = makeCacheSnapshot(
            fiveHourUsed: 40,
            fiveHourReset: now.addingTimeInterval(600),
            receivedAt: validAt
        )
        let auth = ScriptedClaudeAuthFetcher([
            .notConnected,
            .connected,
        ], fallback: .connected)
        let cache = ScriptedClaudeCacheLoader(
            [future]
                + Array(repeating: nil, count: 9)
                + [valid]
        )
        let sleeper = ManualClaudeProviderSleeper()
        let recorder = ClaudeProviderStateRecorder()
        let connector = ClaudeProviderConnector(
            authFetcher: auth,
            cacheLoader: cache,
            sleeper: sleeper,
            now: { clock.now() }
        )

        let task = run(connector, recorder: recorder)
        try await waitForPoll(1, recorder: recorder, sleeper: sleeper)
        clock.set(validAt)
        for poll in 2...11 {
            await sleeper.resumeNext()
            try await waitForPoll(
                poll,
                recorder: recorder,
                sleeper: sleeper
            )
        }

        let states = await recorder.states()
        XCTAssertEqual(states[0], .notConnected)
        guard case let .fresh(snapshot) = states[10] else {
            await stop(task, sleeper: sleeper)
            return XCTFail("Reconnect should publish the valid relay cache")
        }
        XCTAssertEqual(snapshot.capturedAt, validAt)
        XCTAssertEqual(snapshot.metrics.first?.remainingFraction, 0.6)
        await stop(task, sleeper: sleeper)
    }

    func testAuthFailureImmediatelyStalesLastSnapshotAndIgnoresNewCache() async throws {
        let start = Date(timeIntervalSince1970: 1_753_027_200)
        let clock = LockedClaudeProviderClock(start)
        let cached = makeCacheSnapshot(
            fiveHourUsed: 25,
            fiveHourReset: start.addingTimeInterval(300),
            receivedAt: start
        )
        let untrustedNewerCache = makeCacheSnapshot(
            fiveHourUsed: 80,
            fiveHourReset: start.addingTimeInterval(600),
            receivedAt: start.addingTimeInterval(1)
        )
        let auth = ScriptedClaudeAuthFetcher([
            .connected,
            .failed(code: .commandFailed),
        ])
        let cache = ScriptedClaudeCacheLoader(
            [cached]
                + Array(repeating: nil, count: 9)
                + [untrustedNewerCache]
        )
        let sleeper = ManualClaudeProviderSleeper()
        let recorder = ClaudeProviderStateRecorder()
        let connector = ClaudeProviderConnector(
            authFetcher: auth,
            cacheLoader: cache,
            sleeper: sleeper,
            now: { clock.now() }
        )

        let task = run(connector, recorder: recorder)
        try await waitForPoll(1, recorder: recorder, sleeper: sleeper)
        for poll in 2...10 {
            await sleeper.resumeNext()
            try await waitForPoll(
                poll,
                recorder: recorder,
                sleeper: sleeper
            )
        }
        clock.set(start.addingTimeInterval(300))
        await sleeper.resumeNext()
        try await waitForPoll(11, recorder: recorder, sleeper: sleeper)

        let states = await recorder.states()
        guard case let .stale(snapshot) = states[10] else {
            await stop(task, sleeper: sleeper)
            return XCTFail("Auth failure must immediately stale the last-good quota")
        }
        XCTAssertEqual(snapshot.capturedAt, start)
        XCTAssertEqual(snapshot.metrics.first?.remainingFraction, 0.75)
        await stop(task, sleeper: sleeper)
    }

    func testAuthFailureCanMakeLastConnectedEmptySnapshotStale() async throws {
        let start = Date(timeIntervalSince1970: 1_753_027_200)
        let clock = LockedClaudeProviderClock(start)
        let auth = ScriptedClaudeAuthFetcher([
            .connected,
            .failed(code: .commandFailed),
        ])
        let cache = ScriptedClaudeCacheLoader(Array(repeating: nil, count: 11))
        let sleeper = ManualClaudeProviderSleeper()
        let recorder = ClaudeProviderStateRecorder()
        let connector = ClaudeProviderConnector(
            authFetcher: auth,
            cacheLoader: cache,
            sleeper: sleeper,
            now: { clock.now() }
        )

        let task = run(connector, recorder: recorder)
        try await waitForPoll(1, recorder: recorder, sleeper: sleeper)
        for poll in 2...10 {
            await sleeper.resumeNext()
            try await waitForPoll(
                poll,
                recorder: recorder,
                sleeper: sleeper
            )
        }
        clock.set(start.addingTimeInterval(900))
        await sleeper.resumeNext()
        try await waitForPoll(11, recorder: recorder, sleeper: sleeper)

        let states = await recorder.states()
        guard case let .stale(snapshot) = states[10] else {
            await stop(task, sleeper: sleeper)
            return XCTFail("An empty connected snapshot still has freshness")
        }
        XCTAssertEqual(snapshot.metrics, [])
        XCTAssertEqual(snapshot.capturedAt, start)
        await stop(task, sleeper: sleeper)
    }

    func testCancellationDuringNoncooperativeAuthPublishesNothing() async throws {
        let auth = BlockingClaudeAuthFetcher()
        let cache = ScriptedClaudeCacheLoader([nil])
        let sleeper = ManualClaudeProviderSleeper()
        let recorder = ClaudeProviderStateRecorder()
        let connector = ClaudeProviderConnector(
            authFetcher: auth,
            cacheLoader: cache,
            sleeper: sleeper,
            now: { Date(timeIntervalSince1970: 1_753_027_200) }
        )
        let task = run(connector, recorder: recorder)
        try await waitUntil { await auth.hasEntered() }

        task.cancel()
        await auth.release(returning: .connected)
        _ = await task.result

        let states = await recorder.states()
        let cacheCount = await cache.loadCount()
        XCTAssertEqual(states, [])
        XCTAssertEqual(cacheCount, 0)
    }

    private func run(
        _ connector: ClaudeProviderConnector,
        recorder: ClaudeProviderStateRecorder
    ) -> Task<Void, Error> {
        Task {
            try await connector.run { state in
                await recorder.append(state)
            }
        }
    }

    private func stop(
        _ task: Task<Void, Error>,
        sleeper: ManualClaudeProviderSleeper
    ) async {
        task.cancel()
        await sleeper.resumeAll()
        _ = await task.result
    }

    private func waitForPoll(
        _ poll: Int,
        recorder: ClaudeProviderStateRecorder,
        sleeper: ManualClaudeProviderSleeper
    ) async throws {
        try await waitUntil {
            let recordedPolls = await recorder.count()
            let recordedSleeps = await sleeper.recordedCount()
            return recordedPolls >= poll && recordedSleeps >= poll
        }
    }

    private func makeCacheSnapshot(
        fiveHourUsed: Double? = nil,
        fiveHourReset: Date? = nil,
        sevenDayUsed: Double? = nil,
        sevenDayReset: Date? = nil,
        receivedAt: Date
    ) -> ClaudeStatusLineSnapshot {
        let fiveHour: ClaudeStatusLineQuotaWindow? = if let fiveHourUsed,
                                                        let fiveHourReset {
            ClaudeStatusLineQuotaWindow(
                usedPercentage: fiveHourUsed,
                resetAt: fiveHourReset
            )
        } else {
            nil
        }
        let sevenDay: ClaudeStatusLineQuotaWindow? = if let sevenDayUsed,
                                                        let sevenDayReset {
            ClaudeStatusLineQuotaWindow(
                usedPercentage: sevenDayUsed,
                resetAt: sevenDayReset
            )
        } else {
            nil
        }
        return ClaudeStatusLineSnapshot(
            fiveHour: fiveHour,
            sevenDay: sevenDay,
            receivedAt: receivedAt
        )!
    }

    private func waitUntil(
        _ predicate: @escaping @Sendable () async -> Bool
    ) async throws {
        for _ in 0..<2_000 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Timed out waiting for asynchronous condition")
        throw CancellationError()
    }
}

private actor ScriptedClaudeAuthFetcher: ClaudeAuthStatusFetching {
    private var states: [ClaudeAuthState]
    private let fallback: ClaudeAuthState
    private let eventLog: ClaudeProviderEventLog?
    private var count = 0

    init(
        _ states: [ClaudeAuthState],
        fallback: ClaudeAuthState = .failed(code: .commandFailed),
        events: ClaudeProviderEventLog? = nil
    ) {
        self.states = states
        self.fallback = fallback
        eventLog = events
    }

    func fetch() async -> ClaudeAuthState {
        await eventLog?.append("auth")
        count += 1
        return states.isEmpty ? fallback : states.removeFirst()
    }

    func fetchCount() -> Int { count }
}

private actor ScriptedClaudeCacheLoader: ClaudeStatusLineCacheLoading {
    private var snapshots: [ClaudeStatusLineSnapshot?]
    private let eventLog: ClaudeProviderEventLog?
    private var count = 0

    init(
        _ snapshots: [ClaudeStatusLineSnapshot?],
        events: ClaudeProviderEventLog? = nil
    ) {
        self.snapshots = snapshots
        eventLog = events
    }

    func load() async -> ClaudeStatusLineSnapshot? {
        await eventLog?.append("cache")
        count += 1
        return snapshots.isEmpty ? nil : snapshots.removeFirst()
    }

    func loadCount() -> Int { count }
}

private actor ManualClaudeProviderSleeper: ClaudeProviderSleeping {
    private var durations: [Duration] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func sleep(for duration: Duration) async throws {
        durations.append(duration)
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        try Task.checkCancellation()
    }

    func recordedDurations() -> [Duration] { durations }

    func recordedCount() -> Int { durations.count }

    func resumeNext() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }

    func resumeAll() {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

private final class LockedClaudeProviderClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        lock.withLock { value }
    }

    func set(_ newValue: Date) {
        lock.withLock { value = newValue }
    }
}

private actor ClaudeProviderStateRecorder {
    private var recordedStates: [ProviderPresentationState] = []

    func append(_ state: ProviderPresentationState) {
        recordedStates.append(state)
    }

    func states() -> [ProviderPresentationState] { recordedStates }
    func count() -> Int { recordedStates.count }
}

private actor ClaudeProviderEventLog {
    private var recordedEvents: [String] = []

    func append(_ event: String) {
        recordedEvents.append(event)
    }

    func events() -> [String] { recordedEvents }
}

private actor BlockingClaudeAuthFetcher: ClaudeAuthStatusFetching {
    private var entered = false
    private var continuation: CheckedContinuation<ClaudeAuthState, Never>?

    func fetch() async -> ClaudeAuthState {
        entered = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func hasEntered() -> Bool { entered }

    func release(returning state: ClaudeAuthState) {
        continuation?.resume(returning: state)
        continuation = nil
    }
}
