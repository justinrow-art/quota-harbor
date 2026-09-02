import Foundation
import XCTest
@testable import CodexQuotaMonitor

@MainActor
final class RefreshCoordinatorTests: XCTestCase {
    func testAccountReadRunsOncePerGenerationAcrossSameGenerationRefreshes() async throws {
        let fixtureEmail = "owner" + "@example.com"
        let account = try Self.accountResult(
            """
            {"account":{"type":"chatgpt","email":"\(fixtureEmail)","planType":"plus"},"requiresOpenaiAuth":false}
            """
        )
        let client = FakeRefreshClient(
            accountSteps: [.success(account)],
            rateSteps: [
                .success(try Self.rateCatalog(usedPercent: 10)),
                .success(try Self.rateCatalog(usedPercent: 20)),
            ],
            usageSteps: [
                .success(Self.usageSnapshot(lifetime: 100)),
                .success(Self.usageSnapshot(lifetime: 200)),
            ]
        )
        let harness = makeHarness(client: client)
        await harness.coordinator.start(sessionGeneration: 1)
        await assertEventually { await harness.coordinator.isIdleForTesting() }

        await harness.coordinator.trigger(.manual)
        await assertEventually { await harness.coordinator.isIdleForTesting() }

        let statistics = await client.statistics()
        let accountState = await harness.publisher.latestAccountState()
        XCTAssertEqual(statistics.connects, 1)
        XCTAssertEqual(statistics.accountReads, 1)
        XCTAssertEqual(
            accountState,
            .fresh(
                account.account!,
                Date(timeIntervalSince1970: 1_700_000_000)
            )
        )
        await harness.coordinator.stop()
    }

    func testNewAuthenticationGenerationRereadsAccountAndMapsRequiredAuth() async throws {
        let signedIn = try Self.accountResult(
            #"{"account":{"type":"apiKey"},"requiresOpenaiAuth":false}"#
        )
        let signedOut = try Self.accountResult(
            #"{"account":null,"requiresOpenaiAuth":true}"#
        )
        let client = FakeRefreshClient(
            accountSteps: [.success(signedIn), .success(signedOut)],
            rateSteps: [
                .success(try Self.rateCatalog(usedPercent: 10)),
                .success(try Self.rateCatalog(usedPercent: 20)),
            ],
            usageSteps: [
                .success(Self.usageSnapshot(lifetime: 100)),
                .success(Self.usageSnapshot(lifetime: 200)),
            ]
        )
        let harness = makeHarness(client: client)
        await harness.coordinator.start(sessionGeneration: 1)
        await assertEventually { await harness.coordinator.isIdleForTesting() }

        await harness.coordinator.authenticationChanged()
        await assertEventually {
            let statistics = await client.statistics()
            let isIdle = await harness.coordinator.isIdleForTesting()
            return statistics.accountReads == 2 && isIdle
        }

        let accountState = await harness.publisher.latestAccountState()
        XCTAssertEqual(accountState, .unavailable(.unauthenticated))
        await harness.coordinator.stop()
    }

    func testAccountAbsenceAndFailureStayIndependentFromUsableQuotaLanes() async throws {
        let absent = try Self.accountResult(
            #"{"account":null,"requiresOpenaiAuth":false}"#
        )
        let clients = [
            FakeRefreshClient(
                accountSteps: [.success(absent)],
                rateSteps: [.success(try Self.rateCatalog(usedPercent: 10))],
                usageSteps: [.success(Self.usageSnapshot(lifetime: 100))]
            ),
            FakeRefreshClient(
                accountSteps: [.failure(.serverError(code: 500))],
                rateSteps: [.success(try Self.rateCatalog(usedPercent: 20))],
                usageSteps: [.success(Self.usageSnapshot(lifetime: 200))]
            ),
        ]

        for (index, client) in clients.enumerated() {
            let harness = makeHarness(client: client)
            await harness.coordinator.start(sessionGeneration: UInt64(index + 1))
            await assertEventually { await harness.coordinator.isIdleForTesting() }

            let rateState = await harness.publisher.latestRateState()
            let usageState = await harness.publisher.latestUsageState()
            let statistics = await client.statistics()
            let accountState = await harness.publisher.latestAccountState()
            XCTAssertNotNil(rateState)
            XCTAssertNotNil(usageState)
            XCTAssertEqual(statistics.connects, 1)
            let expected: CapabilityState<ProviderAccountSummary> = index == 0
                ? .unsupported
                : .unavailable(.serverRejected)
            XCTAssertEqual(accountState, expected)
            await harness.coordinator.stop()
        }
    }

    func testHundredMixedTriggersRemainSingleFlightAndBounded() async throws {
        let firstRateGate = TestRefreshGate()
        let client = FakeRefreshClient(
            rateSteps: [
                .success(try Self.rateCatalog(usedPercent: 10), gate: firstRateGate),
                .success(try Self.rateCatalog(usedPercent: 11)),
                .success(try Self.rateCatalog(usedPercent: 12)),
                .success(try Self.rateCatalog(usedPercent: 13)),
            ],
            usageSteps: [
                .success(Self.usageSnapshot(lifetime: 100)),
                .success(Self.usageSnapshot(lifetime: 101)),
                .success(Self.usageSnapshot(lifetime: 102)),
            ]
        )
        let harness = makeHarness(client: client)
        await harness.coordinator.start(sessionGeneration: 1)
        await assertEventually {
            await client.statistics().rateReads == 1
        }

        let triggers = RefreshTrigger.allTestTriggers
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                group.addTask {
                    await harness.coordinator.trigger(
                        triggers[index % triggers.count]
                    )
                }
            }
        }
        await firstRateGate.open()
        await assertEventually {
            await harness.coordinator.isIdleForTesting()
        }

        let statistics = await client.statistics()
        XCTAssertEqual(statistics.maximumConcurrentReads, 1)
        XCTAssertLessThanOrEqual(statistics.rateReads, 3)
        XCTAssertLessThanOrEqual(statistics.usageReads, 2)
        await harness.coordinator.stop()
    }

    func testNotificationBurstDebouncesToRateOnly() async throws {
        let client = FakeRefreshClient(
            rateSteps: [
                .success(try Self.rateCatalog(usedPercent: 10)),
                .success(try Self.rateCatalog(usedPercent: 20)),
            ],
            usageSteps: [.success(Self.usageSnapshot(lifetime: 100))]
        )
        let harness = makeHarness(client: client)
        await harness.coordinator.start(sessionGeneration: 1)
        await assertEventually { await harness.coordinator.isIdleForTesting() }

        for _ in 0..<100 {
            await harness.coordinator.trigger(.rateNotification)
        }
        await assertEventually {
            await harness.clock.recordedCount(for: .milliseconds(20)) == 1
        }
        await harness.clock.release(.milliseconds(20))
        await assertEventually {
            let statistics = await client.statistics()
            let isIdle = await harness.coordinator.isIdleForTesting()
            return statistics.rateReads == 2 && isIdle
        }

        let statistics = await client.statistics()
        XCTAssertEqual(statistics.rateReads, 2)
        XCTAssertEqual(statistics.usageReads, 1)
        await harness.coordinator.stop()
    }

    func testNotificationsDuringRateReadAddOnlyOneDirtyAgainPass() async throws {
        let blockedRate = TestRefreshGate()
        let client = FakeRefreshClient(
            rateSteps: [
                .success(try Self.rateCatalog(usedPercent: 10)),
                .success(try Self.rateCatalog(usedPercent: 20), gate: blockedRate),
                .success(try Self.rateCatalog(usedPercent: 30)),
                .success(try Self.rateCatalog(usedPercent: 40)),
            ],
            usageSteps: [.success(Self.usageSnapshot(lifetime: 100))]
        )
        let harness = makeHarness(client: client)
        await harness.coordinator.start(sessionGeneration: 1)
        await assertEventually { await harness.coordinator.isIdleForTesting() }

        await client.emit(.rateLimitsUpdated)
        await assertEventually {
            await harness.clock.recordedCount(for: .milliseconds(20)) == 1
        }
        await harness.clock.release(.milliseconds(20))
        await assertEventually { await client.statistics().rateReads == 2 }
        for _ in 0..<100 {
            await harness.coordinator.trigger(.rateNotification)
        }
        await blockedRate.open()
        await assertEventually {
            let statistics = await client.statistics()
            let isIdle = await harness.coordinator.isIdleForTesting()
            return statistics.rateReads == 3 && isIdle
        }

        let statistics = await client.statistics()
        XCTAssertEqual(statistics.rateReads, 3)
        XCTAssertEqual(statistics.usageReads, 1)
        await harness.coordinator.stop()
    }

    func testExistingDebounceAndInFlightNotificationMergeIntoOneDirtyAgainPass() async throws {
        let blockedRate = TestRefreshGate()
        let client = FakeRefreshClient(
            rateSteps: [
                .success(try Self.rateCatalog(usedPercent: 10)),
                .success(try Self.rateCatalog(usedPercent: 20), gate: blockedRate),
                .success(try Self.rateCatalog(usedPercent: 30)),
                .success(try Self.rateCatalog(usedPercent: 40)),
            ],
            usageSteps: [
                .success(Self.usageSnapshot(lifetime: 100)),
                .success(Self.usageSnapshot(lifetime: 200)),
            ]
        )
        let harness = makeHarness(client: client)
        await harness.coordinator.start(sessionGeneration: 1)
        await assertEventually { await harness.coordinator.isIdleForTesting() }

        await harness.coordinator.trigger(.rateNotification)
        await assertEventually {
            await harness.clock.recordedCount(for: .milliseconds(20)) == 1
        }
        await harness.coordinator.trigger(.manual)
        await assertEventually { await client.statistics().rateReads == 2 }
        await harness.coordinator.trigger(.rateNotification)

        await harness.clock.release(.milliseconds(20))
        for _ in 0..<200 { await Task.yield() }
        await blockedRate.open()
        await assertEventually { await harness.coordinator.isIdleForTesting() }

        let statistics = await client.statistics()
        XCTAssertEqual(statistics.rateReads, 3)
        XCTAssertEqual(statistics.usageReads, 2)
        await harness.coordinator.stop()
    }

    func testTimerIsFiveMinutesAndPanelRefreshesOnlyStaleUsage() async throws {
        let successDate = Date(timeIntervalSince1970: 1_700_000_000)
        let client = FakeRefreshClient(
            rateSteps: [.success(try Self.rateCatalog(usedPercent: 10))],
            usageSteps: [
                .success(Self.usageSnapshot(lifetime: 100)),
                .failure(.invalidResponse),
            ]
        )
        let harness = makeHarness(client: client, wallNow: successDate)
        await harness.coordinator.start(sessionGeneration: 1)
        await assertEventually { await harness.coordinator.isIdleForTesting() }
        let recordedTimerCount = await harness.clock.recordedCount(for: .seconds(300))
        XCTAssertEqual(recordedTimerCount, 1)

        await harness.coordinator.trigger(.panelOpened)
        for _ in 0..<50 { await Task.yield() }
        let freshStatistics = await client.statistics()
        XCTAssertEqual(freshStatistics.usageReads, 1)

        await harness.clock.advanceMonotonic(by: .seconds(900))
        await harness.clock.setWall(successDate.addingTimeInterval(-5_000))
        await harness.coordinator.trigger(.panelOpened)
        await assertEventually {
            let statistics = await client.statistics()
            let isIdle = await harness.coordinator.isIdleForTesting()
            return statistics.usageReads == 2 && isIdle
        }

        let latestUsage = await harness.publisher.latestUsageState()
        guard case let .stale(snapshot, date, failure)? = latestUsage else {
            return XCTFail("Expected same-generation stale usage")
        }
        XCTAssertEqual(snapshot.lifetimeTokens, 100)
        XCTAssertEqual(date, successDate)
        XCTAssertEqual(failure, .stale)
        let staleStatistics = await client.statistics()
        XCTAssertEqual(staleStatistics.rateReads, 1)
        await harness.coordinator.stop()
    }

    func testPanelBurstDuringBlockedStaleUsageReadDoesNotQueueDuplicateUsage() async throws {
        let blockedUsage = TestRefreshGate()
        let client = FakeRefreshClient(
            rateSteps: [.success(try Self.rateCatalog(usedPercent: 10))],
            usageSteps: [
                .success(Self.usageSnapshot(lifetime: 100)),
                .success(
                    Self.usageSnapshot(lifetime: 200),
                    gate: blockedUsage
                ),
                .success(Self.usageSnapshot(lifetime: 300)),
            ]
        )
        let harness = makeHarness(client: client)
        await harness.coordinator.start(sessionGeneration: 1)
        await assertEventually { await harness.coordinator.isIdleForTesting() }
        await harness.clock.advanceMonotonic(by: .seconds(900))

        await harness.coordinator.trigger(.panelOpened)
        await assertEventually {
            let statistics = await client.statistics()
            return statistics.usageReads == 2 && statistics.activeReads == 1
        }
        for _ in 0..<100 {
            await harness.coordinator.trigger(.panelOpened)
        }

        await blockedUsage.open()
        await assertEventually { await harness.coordinator.isIdleForTesting() }

        let statistics = await client.statistics()
        XCTAssertEqual(statistics.rateReads, 1)
        XCTAssertEqual(statistics.usageReads, 2)
        await harness.coordinator.stop()
    }

    func testFullTriggersRemainPendingDuringBlockedPanelUsageRead() async throws {
        for fullTrigger in [RefreshTrigger.manual, .timer] {
            let blockedUsage = TestRefreshGate()
            let client = FakeRefreshClient(
                rateSteps: [
                    .success(try Self.rateCatalog(usedPercent: 10)),
                    .success(try Self.rateCatalog(usedPercent: 20)),
                ],
                usageSteps: [
                    .success(Self.usageSnapshot(lifetime: 100)),
                    .success(
                        Self.usageSnapshot(lifetime: 200),
                        gate: blockedUsage
                    ),
                    .success(Self.usageSnapshot(lifetime: 300)),
                ]
            )
            let harness = makeHarness(client: client)
            await harness.coordinator.start(sessionGeneration: 1)
            await assertEventually {
                await harness.coordinator.isIdleForTesting()
            }
            await harness.clock.advanceMonotonic(by: .seconds(900))
            await harness.coordinator.trigger(.panelOpened)
            await assertEventually {
                await client.statistics().usageReads == 2
            }

            await harness.coordinator.trigger(fullTrigger)
            for _ in 0..<20 {
                await harness.coordinator.trigger(.panelOpened)
            }
            await blockedUsage.open()
            await assertEventually {
                let statistics = await client.statistics()
                let isIdle = await harness.coordinator.isIdleForTesting()
                return statistics.rateReads == 2
                    && statistics.usageReads == 3
                    && isIdle
            }

            let statistics = await client.statistics()
            XCTAssertEqual(statistics.rateReads, 2)
            XCTAssertEqual(statistics.usageReads, 3)
            await harness.coordinator.stop()
        }
    }

    func testSessionInactivePerformsZeroReadsAndResumeDoesOneFullResync() async throws {
        let client = FakeRefreshClient(
            rateSteps: [
                .success(try Self.rateCatalog(usedPercent: 10)),
                .success(try Self.rateCatalog(usedPercent: 20)),
            ],
            usageSteps: [
                .success(Self.usageSnapshot(lifetime: 100)),
                .success(Self.usageSnapshot(lifetime: 200)),
            ]
        )
        let harness = makeHarness(client: client)
        await harness.coordinator.start(sessionGeneration: 4)
        await assertEventually { await harness.coordinator.isIdleForTesting() }
        await harness.coordinator.sessionResigned()
        let before = await client.statistics()

        for trigger in RefreshTrigger.allTestTriggers {
            await harness.coordinator.trigger(trigger)
        }
        await client.emit(.rateLimitsUpdated, count: 10)
        for _ in 0..<100 { await Task.yield() }
        let inactive = await client.statistics()
        XCTAssertEqual(inactive.rateReads, before.rateReads)
        XCTAssertEqual(inactive.usageReads, before.usageReads)
        XCTAssertEqual(inactive.connects, before.connects)

        await harness.coordinator.sessionBecameActive()
        await assertEventually {
            let statistics = await client.statistics()
            let isIdle = await harness.coordinator.isIdleForTesting()
            return statistics.rateReads == before.rateReads + 1
                && statistics.usageReads == before.usageReads + 1
                && isIdle
        }
        let resumed = await client.statistics()
        XCTAssertEqual(resumed.lastConnectedSession, 5)
        await harness.coordinator.stop()
    }

    func testRestartBudgetIsOnePerRateOnlyCycleAndThreePerFifteenMinutes()
        async throws
    {
        let failures = Array(
            repeating: FakeRefreshStep<RateLimitCatalog>.failure(.processExited),
            count: 9
        )
        let client = FakeRefreshClient(
            rateSteps: [
                .success(try Self.rateCatalog(usedPercent: 10)),
            ] + failures,
            usageSteps: [.success(Self.usageSnapshot(lifetime: 100))]
        )
        let harness = makeHarness(client: client)
        await harness.coordinator.start(sessionGeneration: 1)
        await assertEventually { await harness.coordinator.isIdleForTesting() }

        for (cycle, delay) in [1, 2, 4].enumerated() {
            await harness.coordinator.trigger(.rateNotification)
            await assertEventually {
                await harness.clock.recordedCount(for: .milliseconds(20))
                    == cycle + 1
            }
            await harness.clock.release(.milliseconds(20))
            await assertEventually {
                await harness.clock.recordedCount(for: .seconds(delay)) == 1
            }
            await harness.clock.release(.seconds(delay))
            await assertEventually { await harness.coordinator.isIdleForTesting() }
        }

        await harness.coordinator.trigger(.rateNotification)
        await assertEventually {
            await harness.clock.recordedCount(for: .milliseconds(20)) == 4
        }
        await harness.clock.release(.milliseconds(20))
        await assertEventually { await harness.coordinator.isIdleForTesting() }
        var statistics = await client.statistics()
        XCTAssertEqual(statistics.connects, 7)
        XCTAssertEqual(statistics.rateReads, 8)
        XCTAssertEqual(statistics.usageReads, 1)
        let firstBackoffSleeps = await harness.clock.recordedBackoffSleeps()
        XCTAssertEqual(firstBackoffSleeps, [.seconds(1), .seconds(2), .seconds(4)])

        await harness.clock.advanceMonotonic(by: .seconds(901))
        await harness.coordinator.trigger(.rateNotification)
        await assertEventually {
            await harness.clock.recordedCount(for: .milliseconds(20)) == 5
        }
        await harness.clock.release(.milliseconds(20))
        await assertEventually {
            await harness.clock.recordedCount(for: .seconds(1)) == 2
        }
        await harness.clock.release(.seconds(1))
        await assertEventually { await harness.coordinator.isIdleForTesting() }
        statistics = await client.statistics()
        XCTAssertEqual(statistics.connects, 9)
        XCTAssertEqual(statistics.rateReads, 10)
        XCTAssertEqual(statistics.usageReads, 1)
        await harness.coordinator.stop()
    }

    func testExhaustedRateRestartSalvagesUsageOnFreshGeneration() async {
        let client = FakeRefreshClient(
            rateSteps: [
                .failure(.timedOut),
                .failure(.timedOut),
            ],
            usageSteps: [
                .success(Self.usageSnapshot(lifetime: 222)),
            ]
        )
        let harness = makeHarness(client: client)

        await harness.coordinator.start(sessionGeneration: 1)
        await assertEventually {
            await harness.clock.recordedCount(for: .seconds(1)) == 1
        }
        await harness.clock.release(.seconds(1))
        await assertEventually {
            await harness.clock.recordedCount(for: .seconds(2)) == 1
        }
        await harness.clock.release(.seconds(2))
        await assertEventually { await harness.coordinator.isIdleForTesting() }

        let statistics = await client.statistics()
        XCTAssertEqual(statistics.connects, 3)
        XCTAssertEqual(statistics.rateReads, 2)
        XCTAssertEqual(statistics.usageReads, 1)
        let rateState = await harness.publisher.latestRateState()
        XCTAssertEqual(rateState, .unavailable(.temporaryTransport))
        guard case let .fresh(usage, _)? =
            await harness.publisher.latestUsageState()
        else {
            return XCTFail("Expected usage from the salvage generation")
        }
        XCTAssertEqual(usage.lifetimeTokens, 222)
        let ratePublication = await harness.publisher.latestRatePublication()
        let usagePublication = await harness.publisher.latestUsagePublication()
        XCTAssertNotNil(ratePublication?.generation)
        XCTAssertEqual(ratePublication?.generation, usagePublication?.generation)
        XCTAssertEqual(ratePublication?.sequence, usagePublication?.sequence)
        await harness.coordinator.stop()
    }

    func testExhaustedUsageRestartSalvagesRateOnFreshGeneration() async throws {
        let client = FakeRefreshClient(
            rateSteps: [
                .success(try Self.rateCatalog(usedPercent: 10)),
                .success(try Self.rateCatalog(usedPercent: 20)),
                .success(try Self.rateCatalog(usedPercent: 30)),
            ],
            usageSteps: [
                .failure(.timedOut),
                .failure(.timedOut),
            ]
        )
        let harness = makeHarness(client: client)

        await harness.coordinator.start(sessionGeneration: 1)
        await assertEventually {
            await harness.clock.recordedCount(for: .seconds(1)) == 1
        }
        await harness.clock.release(.seconds(1))
        await assertEventually {
            await harness.clock.recordedCount(for: .seconds(2)) == 1
        }
        await harness.clock.release(.seconds(2))
        await assertEventually { await harness.coordinator.isIdleForTesting() }

        let statistics = await client.statistics()
        XCTAssertEqual(statistics.connects, 3)
        XCTAssertEqual(statistics.rateReads, 3)
        XCTAssertEqual(statistics.usageReads, 2)
        guard case let .fresh(rate, _)? =
            await harness.publisher.latestRateState()
        else {
            return XCTFail("Expected rate data from the salvage generation")
        }
        XCTAssertEqual(rate.selectedBucket.windows.first?.usedPercent, 30)
        let usageState = await harness.publisher.latestUsageState()
        XCTAssertEqual(usageState, .unavailable(.temporaryTransport))
        let ratePublication = await harness.publisher.latestRatePublication()
        let usagePublication = await harness.publisher.latestUsagePublication()
        XCTAssertNotNil(ratePublication?.generation)
        XCTAssertEqual(ratePublication?.generation, usagePublication?.generation)
        XCTAssertEqual(ratePublication?.sequence, usagePublication?.sequence)
        await harness.coordinator.stop()
    }

    func testExhaustedRestartBudgetPublishesBothRequestedLanesUnavailable()
        async
    {
        let client = FakeRefreshClient(
            rateSteps: [
                .failure(.timedOut),
                .failure(.timedOut),
            ],
            usageSteps: [
                .success(Self.usageSnapshot(lifetime: 222)),
            ]
        )
        let clock = TestRefreshClock(
            wallNow: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let publisher = RecordingRefreshPublisher()
        let coordinator = makeCoordinator(
            client: client,
            publisher: publisher,
            clock: clock,
            restartLimit: 1
        )

        await coordinator.start(sessionGeneration: 1)
        await assertEventually {
            await clock.recordedCount(for: .seconds(1)) == 1
        }
        await clock.release(.seconds(1))
        await assertEventually { await coordinator.isIdleForTesting() }

        let statistics = await client.statistics()
        XCTAssertEqual(statistics.connects, 2)
        XCTAssertEqual(statistics.rateReads, 2)
        XCTAssertEqual(statistics.usageReads, 0)
        let rateState = await publisher.latestRateState()
        let usageState = await publisher.latestUsageState()
        XCTAssertEqual(rateState, .unavailable(.temporaryTransport))
        XCTAssertEqual(usageState, .unavailable(.temporaryTransport))
        let backoffs = await clock.recordedBackoffSleeps()
        XCTAssertEqual(backoffs, [.seconds(1)])
        await coordinator.stop()
    }

    func testSalvageConnectFailurePublishesBothRequestedLanesUnavailable()
        async
    {
        let secondRateGate = TestRefreshGate()
        let client = FakeRefreshClient(
            rateSteps: [
                .failure(.timedOut),
                .failure(.timedOut, gate: secondRateGate),
            ],
            usageSteps: [
                .success(Self.usageSnapshot(lifetime: 222)),
            ]
        )
        let harness = makeHarness(client: client)

        await harness.coordinator.start(sessionGeneration: 1)
        await assertEventually {
            await harness.clock.recordedCount(for: .seconds(1)) == 1
        }
        await harness.clock.release(.seconds(1))
        await assertEventually {
            let statistics = await client.statistics()
            return statistics.connects == 2
                && statistics.rateReads == 2
                && statistics.activeReads == 1
        }
        await client.enqueueConnectFailure(
            CodexAppServerClientError.processExited
        )
        await secondRateGate.open()
        await assertEventually {
            await harness.clock.recordedCount(for: .seconds(2)) == 1
        }
        await harness.clock.release(.seconds(2))
        await assertEventually { await harness.coordinator.isIdleForTesting() }

        let statistics = await client.statistics()
        XCTAssertEqual(statistics.connects, 3)
        XCTAssertEqual(statistics.rateReads, 2)
        XCTAssertEqual(statistics.usageReads, 0)
        let rateState = await harness.publisher.latestRateState()
        let usageState = await harness.publisher.latestUsageState()
        XCTAssertEqual(rateState, .unavailable(.temporaryTransport))
        XCTAssertEqual(usageState, .unavailable(.temporaryTransport))
        await harness.coordinator.stop()
    }

    func testUnsupportedAndSchemaFailuresDoNotRetryOrBlockOtherLane() async throws {
        let client = FakeRefreshClient(
            rateSteps: [
                .failure(.serverError(code: -32601)),
                .failure(.invalidResponse),
            ],
            usageSteps: [
                .success(Self.usageSnapshot(lifetime: 100)),
                .success(Self.usageSnapshot(lifetime: 200)),
            ]
        )
        let harness = makeHarness(client: client)
        await harness.coordinator.start(sessionGeneration: 1)
        await assertEventually { await harness.coordinator.isIdleForTesting() }
        let firstStatistics = await client.statistics()
        let firstRateState = await harness.publisher.latestRateState()
        XCTAssertEqual(firstStatistics.connects, 1)
        XCTAssertEqual(firstRateState, .unsupported)
        guard case let .fresh(usage, _)? = await harness.publisher.latestUsageState() else {
            return XCTFail("Usage lane should remain independent")
        }
        XCTAssertEqual(usage.lifetimeTokens, 100)

        await harness.coordinator.trigger(.manual)
        await assertEventually { await harness.coordinator.isIdleForTesting() }
        let secondStatistics = await client.statistics()
        let secondBackoffSleeps = await harness.clock.recordedBackoffSleeps()
        XCTAssertEqual(secondStatistics.connects, 1)
        XCTAssertEqual(secondBackoffSleeps, [])
        guard case .unavailable(.invalidSchema)? = await harness.publisher.latestRateState() else {
            return XCTFail("Expected non-retrying schema failure")
        }
        guard case let .fresh(secondUsage, _)? = await harness.publisher.latestUsageState() else {
            return XCTFail("Usage should still refresh")
        }
        XCTAssertEqual(secondUsage.lifetimeTokens, 200)
        await harness.coordinator.stop()
    }

    func testProductionConnectFailuresPublishTruthfulUnavailableReasonsWithoutRetry()
        async
    {
        let cases: [(any Error & Sendable, CapabilityFailure)] = [
            (CodexExecutableTrustError.missingPath, .binaryNotFound),
            (
                CodexExecutableTrustError.staticValidationFailed(.child),
                .trustValidationFailed
            ),
            (
                CodexTrustManifestLoadingError.invalidResource,
                .trustValidationFailed
            ),
            (AppServerProcessLaunchError.launchFailed, .processLaunchFailed),
        ]

        for (error, expectedFailure) in cases {
            let client = FakeRefreshClient(
                connectFailures: [error],
                rateSteps: [],
                usageSteps: []
            )
            let harness = makeHarness(client: client)

            await harness.coordinator.start(sessionGeneration: 1)
            await assertEventually {
                await harness.coordinator.isIdleForTesting()
            }

            let rateState = await harness.publisher.latestRateState()
            let usageState = await harness.publisher.latestUsageState()
            let statistics = await client.statistics()
            let backoffSleeps = await harness.clock.recordedBackoffSleeps()
            XCTAssertEqual(
                rateState,
                .unavailable(expectedFailure),
                "\(error)"
            )
            XCTAssertEqual(
                usageState,
                .unavailable(expectedFailure),
                "\(error)"
            )
            XCTAssertEqual(statistics.connects, 1, "\(error)")
            XCTAssertEqual(
                backoffSleeps,
                [],
                "\(error)"
            )
            await harness.coordinator.stop()
        }
    }

    func testUnrecognizedServerErrorCodeIsNeutralAndDoesNotRetry()
        async
    {
        let client = FakeRefreshClient(
            rateSteps: [.failure(.serverError(code: 401))],
            usageSteps: [.failure(.serverError(code: -32_000))]
        )
        let harness = makeHarness(client: client)

        await harness.coordinator.start(sessionGeneration: 1)
        await assertEventually { await harness.coordinator.isIdleForTesting() }

        let rateState = await harness.publisher.latestRateState()
        let usageState = await harness.publisher.latestUsageState()
        XCTAssertEqual(rateState, .unavailable(.serverRejected))
        XCTAssertEqual(usageState, .unavailable(.serverRejected))
        let statistics = await client.statistics()
        let backoffSleeps = await harness.clock.recordedBackoffSleeps()
        XCTAssertEqual(statistics.connects, 1)
        XCTAssertEqual(backoffSleeps, [])
        await harness.coordinator.stop()
    }

    func testSlowOldSuccessIsNeverPublishedAfterAuthenticationChange() async throws {
        let oldRateGate = TestRefreshGate()
        let oldGeneration = GenerationToken(auth: 0, session: 1, connection: 1)
        let firstNewGeneration = GenerationToken(auth: 1, session: 1, connection: 1)
        let secondNewGeneration = GenerationToken(auth: 1, session: 1, connection: 2)
        let client = FakeRefreshClient(
            generations: [oldGeneration, firstNewGeneration, secondNewGeneration],
            rateSteps: [
                .success(try Self.rateCatalog(usedPercent: 99), gate: oldRateGate),
                .failure(.processExited),
                .success(try Self.rateCatalog(usedPercent: 12)),
            ],
            usageSteps: [.success(Self.usageSnapshot(lifetime: 222))]
        )
        let harness = makeHarness(client: client)
        await harness.coordinator.start(sessionGeneration: 1)
        await assertEventually { await client.statistics().rateReads == 1 }

        await harness.coordinator.authenticationChanged()
        await assertEventually {
            await harness.clock.recordedCount(for: .seconds(1)) == 1
        }
        await harness.clock.release(.seconds(1))
        await assertEventually {
            await harness.publisher.ratePercents().contains(12)
        }
        await oldRateGate.open()
        for _ in 0..<200 { await Task.yield() }

        let percents = await harness.publisher.ratePercents()
        XCTAssertTrue(percents.contains(12))
        XCTAssertFalse(percents.contains(99))
        let usageLifetimes = await harness.publisher.usageLifetimes()
        XCTAssertEqual(usageLifetimes, [222])
        await harness.coordinator.stop()
    }

    func testSupersededLifecycleCannotDisconnectNewConnectionAfterResetPublicationResumes() async throws {
        let firstResetGate = TestRefreshGate()
        let publisher = BlockingFirstRefreshPublisher(gate: firstResetGate)
        let client = FakeRefreshClient(
            rateSteps: [.success(try Self.rateCatalog(usedPercent: 12))],
            usageSteps: [.success(Self.usageSnapshot(lifetime: 222))]
        )
        let clock = TestRefreshClock(
            wallNow: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let coordinator = makeCoordinator(
            client: client,
            publisher: publisher,
            clock: clock
        )

        let staleStart = Task {
            await coordinator.start(sessionGeneration: 1)
        }
        await assertEventually { await publisher.applicationCount() == 1 }

        await coordinator.authenticationChanged()
        await assertEventually {
            let statistics = await client.statistics()
            let isIdle = await coordinator.isIdleForTesting()
            return statistics.rateReads == 1
                && statistics.usageReads == 1
                && isIdle
        }
        let beforeRelease = await client.statistics()
        XCTAssertEqual(beforeRelease.disconnects, 1)
        XCTAssertEqual(beforeRelease.connects, 1)

        await firstResetGate.open()
        await staleStart.value
        for _ in 0..<100 { await Task.yield() }

        let afterRelease = await client.statistics()
        XCTAssertEqual(afterRelease.disconnects, 1)
        XCTAssertEqual(afterRelease.connects, 1)
        await coordinator.stop()
    }

    func testSupersededSlowConnectCannotDisconnectNewConnection() async throws {
        let oldConnectGate = TestRefreshGate()
        let oldGeneration = GenerationToken(auth: 0, session: 1, connection: 1)
        let newGeneration = GenerationToken(auth: 1, session: 1, connection: 1)
        let client = FakeRefreshClient(
            generations: [oldGeneration, newGeneration],
            connectGates: [oldConnectGate, nil],
            rateSteps: [.success(try Self.rateCatalog(usedPercent: 12))],
            usageSteps: [.success(Self.usageSnapshot(lifetime: 222))]
        )
        let harness = makeHarness(client: client)

        await harness.coordinator.start(sessionGeneration: 1)
        await assertEventually { await client.statistics().connects == 1 }
        await harness.coordinator.authenticationChanged()
        await assertEventually {
            let statistics = await client.statistics()
            let isIdle = await harness.coordinator.isIdleForTesting()
            return statistics.connects == 2
                && statistics.rateReads == 1
                && statistics.usageReads == 1
                && isIdle
        }
        let beforeRelease = await client.statistics()
        XCTAssertEqual(beforeRelease.disconnects, 2)

        await oldConnectGate.open()
        for _ in 0..<100 { await Task.yield() }

        let afterRelease = await client.statistics()
        XCTAssertEqual(afterRelease.disconnects, 2)
        XCTAssertEqual(afterRelease.connects, 2)
        await harness.coordinator.stop()
    }

    func testSupersededPublicationCannotOverwriteNewGenerationLastGoodUsage() async throws {
        let oldRatePublicationGate = TestRefreshGate()
        let publisher = BlockingFirstRateRefreshPublisher(
            gate: oldRatePublicationGate
        )
        let oldGeneration = GenerationToken(auth: 0, session: 1, connection: 1)
        let newGeneration = GenerationToken(auth: 1, session: 1, connection: 1)
        let client = FakeRefreshClient(
            generations: [oldGeneration, newGeneration],
            rateSteps: [
                .success(try Self.rateCatalog(usedPercent: 99)),
                .success(try Self.rateCatalog(usedPercent: 12)),
            ],
            usageSteps: [
                .success(Self.usageSnapshot(lifetime: 111)),
                .success(Self.usageSnapshot(lifetime: 222)),
                .success(Self.usageSnapshot(lifetime: 333)),
            ]
        )
        let clock = TestRefreshClock(
            wallNow: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let coordinator = makeCoordinator(
            client: client,
            publisher: publisher,
            clock: clock
        )

        await coordinator.start(sessionGeneration: 1)
        await assertEventually { await publisher.isBlockingOldRate() }
        await coordinator.authenticationChanged()
        await assertEventually {
            let statistics = await client.statistics()
            let isIdle = await coordinator.isIdleForTesting()
            return statistics.rateReads == 2
                && statistics.usageReads == 2
                && isIdle
        }

        await oldRatePublicationGate.open()
        for _ in 0..<200 { await Task.yield() }
        await coordinator.trigger(.panelOpened)
        for _ in 0..<200 { await Task.yield() }

        let statistics = await client.statistics()
        XCTAssertEqual(statistics.usageReads, 2)
        await coordinator.stop()
    }

    func testOldRateReadCannotClearNewLifecycleReadOwnership() async throws {
        let oldRateGate = TestRefreshGate()
        let newRateGate = TestRefreshGate()
        let oldGeneration = GenerationToken(auth: 0, session: 1, connection: 1)
        let newGeneration = GenerationToken(auth: 1, session: 1, connection: 1)
        let client = FakeRefreshClient(
            generations: [oldGeneration, newGeneration],
            rateSteps: [
                .success(try Self.rateCatalog(usedPercent: 99), gate: oldRateGate),
                .success(try Self.rateCatalog(usedPercent: 12), gate: newRateGate),
                .success(try Self.rateCatalog(usedPercent: 13)),
            ],
            usageSteps: [.success(Self.usageSnapshot(lifetime: 222))]
        )
        let harness = makeHarness(client: client)

        await harness.coordinator.start(sessionGeneration: 1)
        await assertEventually { await client.statistics().rateReads == 1 }
        await harness.coordinator.authenticationChanged()
        await assertEventually {
            let statistics = await client.statistics()
            return statistics.rateReads == 2 && statistics.activeReads == 2
        }

        await oldRateGate.open()
        await assertEventually { await client.statistics().activeReads == 1 }
        for _ in 0..<200 { await Task.yield() }
        await harness.coordinator.trigger(.rateNotification)
        for _ in 0..<200 { await Task.yield() }

        let debounceCount = await harness.clock.recordedCount(
            for: .milliseconds(20)
        )
        XCTAssertEqual(debounceCount, 0)
        if debounceCount > 0 {
            await harness.clock.release(.milliseconds(20))
        }

        await newRateGate.open()
        await assertEventually { await harness.coordinator.isIdleForTesting() }
        let statistics = await client.statistics()
        XCTAssertEqual(statistics.rateReads, 3)
        XCTAssertEqual(statistics.usageReads, 1)
        await harness.coordinator.stop()
    }

    func testCancelledRestartWaitingForJitterDoesNotConsumeBudget() async throws {
        let oldJitterGate = TestRefreshGate()
        let jitter = TestRefreshJitter(firstGate: oldJitterGate)
        let client = FakeRefreshClient(
            rateSteps: [
                .failure(.processExited),
                .failure(.processExited),
                .success(try Self.rateCatalog(usedPercent: 12)),
            ],
            usageSteps: [.success(Self.usageSnapshot(lifetime: 222))]
        )
        let clock = TestRefreshClock(
            wallNow: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let publisher = RecordingRefreshPublisher()
        let coordinator = makeCoordinator(
            client: client,
            publisher: publisher,
            clock: clock,
            restartLimit: 1,
            jitterUnit: { await jitter.next() }
        )

        await coordinator.start(sessionGeneration: 1)
        await assertEventually { await jitter.callCount() == 1 }
        await coordinator.authenticationChanged()
        await assertEventually { await client.statistics().rateReads >= 2 }
        await oldJitterGate.open()

        await assertEventually {
            await clock.recordedCount(for: .seconds(1)) == 1
        }
        await clock.release(.seconds(1))
        await assertEventually { await coordinator.isIdleForTesting() }

        let statistics = await client.statistics()
        XCTAssertEqual(statistics.connects, 3)
        XCTAssertEqual(statistics.rateReads, 3)
        XCTAssertEqual(statistics.usageReads, 1)
        await coordinator.stop()
    }

    private func makeHarness(
        client: FakeRefreshClient,
        wallNow: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> RefreshHarness {
        let clock = TestRefreshClock(wallNow: wallNow)
        let publisher = RecordingRefreshPublisher()
        return RefreshHarness(
            coordinator: makeCoordinator(
                client: client,
                publisher: publisher,
                clock: clock
            ),
            publisher: publisher,
            clock: clock
        )
    }

    private func makeCoordinator(
        client: FakeRefreshClient,
        publisher: any RefreshPublishing,
        clock: TestRefreshClock,
        restartLimit: Int = 3,
        jitterUnit: @escaping @Sendable () async -> Double = { 0 }
    ) -> RefreshCoordinator {
        let scheduling = RefreshScheduling(
            monotonicNow: { await clock.monotonicNow() },
            wallNow: { await clock.wallNow() },
            sleep: { try await clock.sleep(for: $0) },
            jitterUnit: jitterUnit
        )
        let configuration = RefreshCoordinatorConfiguration(
            timerInterval: .seconds(300),
            staleAfter: .seconds(900),
            notificationDebounce: .milliseconds(20),
            restartWindow: .seconds(900),
            restartLimit: restartLimit,
            backoffBase: .seconds(1),
            backoffCap: .seconds(30),
            jitterFraction: 0.2
        )
        return RefreshCoordinator(
            client: client,
            publisher: publisher,
            scheduling: scheduling,
            configuration: configuration
        )
    }

    private func assertEventually(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping @Sendable () async -> Bool
    ) async {
        for attempt in 0..<5_000 {
            if await condition() { return }
            if attempt.isMultiple(of: 100) {
                try? await Task.sleep(for: .milliseconds(1))
            } else {
                await Task.yield()
            }
        }
        XCTFail("Condition was not met", file: file, line: line)
    }

    private static func rateCatalog(usedPercent: Int) throws -> RateLimitCatalog {
        let window = try RateLimitWindow(
            identity: WindowIdentity(
                bucketKey: "codex",
                sourceSlot: .primary,
                durationMinutes: 300
            ),
            usedPercent: usedPercent,
            resetsAt: nil
        )
        let bucket = RateLimitBucket(bucketKey: "codex", windows: [window])
        return RateLimitCatalog(
            rateLimitsByLimitId: ["codex": bucket],
            legacyBucket: bucket
        )
    }

    private static func usageSnapshot(lifetime: Int64) -> TokenActivitySnapshot {
        TokenActivitySnapshot(
            rawResponse: GetAccountTokenUsageRawResponse(
                summary: AccountTokenUsageSummaryRaw(
                    lifetimeTokens: lifetime,
                    peakDailyTokens: nil,
                    longestRunningTurnSec: nil,
                    currentStreakDays: nil,
                    longestStreakDays: nil
                ),
                dailyUsageBuckets: []
            )
        )
    }

    private static func accountResult(
        _ json: String
    ) throws -> CodexAccountReadResult {
        try JSONDecoder().decode(
            CodexAccountReadResult.self,
            from: Data(json.utf8)
        )
    }
}

private struct RefreshHarness {
    let coordinator: RefreshCoordinator
    let publisher: RecordingRefreshPublisher
    let clock: TestRefreshClock
}

private extension RefreshTrigger {
    static let allTestTriggers: [RefreshTrigger] = [
        .launch, .timer, .manual, .panelOpened,
        .rateNotification, .wake, .reconnect,
    ]
}

private struct FakeRefreshStatistics: Sendable {
    let connects: Int
    let accountReads: Int
    let rateReads: Int
    let usageReads: Int
    let activeReads: Int
    let maximumConcurrentReads: Int
    let disconnects: Int
    let lastConnectedSession: UInt64?
}

private struct FakeRefreshStep<Value: Sendable>: Sendable {
    let result: Result<Value, CodexAppServerClientError>
    let gate: TestRefreshGate?

    static func success(
        _ value: Value,
        gate: TestRefreshGate? = nil
    ) -> Self {
        Self(result: .success(value), gate: gate)
    }

    static func failure(
        _ error: CodexAppServerClientError,
        gate: TestRefreshGate? = nil
    ) -> Self {
        Self(result: .failure(error), gate: gate)
    }
}

private actor FakeRefreshClient: RefreshClient {
    private var generations: [GenerationToken]
    private var connectGates: [TestRefreshGate?]
    private var connectFailures: [(any Error & Sendable)]
    private var accountSteps: [FakeRefreshStep<CodexAccountReadResult>]
    private var rateSteps: [FakeRefreshStep<RateLimitCatalog>]
    private var usageSteps: [FakeRefreshStep<TokenActivitySnapshot>]
    private let notificationStream: AsyncStream<AppServerNotification>
    private let notificationContinuation: AsyncStream<AppServerNotification>.Continuation
    private var connects = 0
    private var accountReads = 0
    private var rateReads = 0
    private var usageReads = 0
    private var activeReads = 0
    private var maximumConcurrentReads = 0
    private var disconnects = 0
    private var lastConnectedSession: UInt64?

    init(
        generations: [GenerationToken] = [],
        connectGates: [TestRefreshGate?] = [],
        connectFailures: [(any Error & Sendable)] = [],
        accountSteps: [FakeRefreshStep<CodexAccountReadResult>] = [],
        rateSteps: [FakeRefreshStep<RateLimitCatalog>],
        usageSteps: [FakeRefreshStep<TokenActivitySnapshot>]
    ) {
        self.generations = generations
        self.connectGates = connectGates
        self.connectFailures = connectFailures
        self.accountSteps = accountSteps
        self.rateSteps = rateSteps
        self.usageSteps = usageSteps
        let pair = AsyncStream.makeStream(of: AppServerNotification.self)
        notificationStream = pair.stream
        notificationContinuation = pair.continuation
    }

    func connect(session: UInt64) async throws -> GenerationToken {
        connects += 1
        lastConnectedSession = session
        let gate = connectGates.isEmpty ? nil : connectGates.removeFirst()
        let failure = connectFailures.isEmpty
            ? nil
            : connectFailures.removeFirst()
        let generation: GenerationToken
        if !generations.isEmpty {
            generation = generations.removeFirst()
        } else {
            generation = GenerationToken(
                auth: 0,
                session: session,
                connection: UInt64(connects)
            )
        }
        await gate?.wait()
        if let failure {
            throw failure
        }
        return generation
    }

    func readAccount(
        generation _: GenerationToken
    ) async throws -> CodexAccountReadResult {
        accountReads += 1
        guard !accountSteps.isEmpty else {
            return try JSONDecoder().decode(
                CodexAccountReadResult.self,
                from: Data(
                    #"{"account":null,"requiresOpenaiAuth":false}"#.utf8
                )
            )
        }
        let step = accountSteps.removeFirst()
        await step.gate?.wait()
        return try step.result.get()
    }

    func readRateLimits(
        generation _: GenerationToken
    ) async throws -> RateLimitCatalog {
        rateReads += 1
        activeReads += 1
        maximumConcurrentReads = max(maximumConcurrentReads, activeReads)
        defer { activeReads -= 1 }
        guard !rateSteps.isEmpty else { throw CodexAppServerClientError.invalidRequest }
        let step = rateSteps.removeFirst()
        await step.gate?.wait()
        return try step.result.get()
    }

    func readUsage(
        generation _: GenerationToken
    ) async throws -> TokenActivitySnapshot {
        usageReads += 1
        activeReads += 1
        maximumConcurrentReads = max(maximumConcurrentReads, activeReads)
        defer { activeReads -= 1 }
        guard !usageSteps.isEmpty else { throw CodexAppServerClientError.invalidRequest }
        let step = usageSteps.removeFirst()
        await step.gate?.wait()
        return try step.result.get()
    }

    func notifications() -> AsyncStream<AppServerNotification> {
        notificationStream
    }

    func disconnect() async {
        disconnects += 1
    }

    func emit(_ notification: AppServerNotification, count: Int = 1) {
        for _ in 0..<count { notificationContinuation.yield(notification) }
    }

    func enqueueConnectFailure(_ error: any Error & Sendable) {
        connectFailures.append(error)
    }

    func statistics() -> FakeRefreshStatistics {
        FakeRefreshStatistics(
            connects: connects,
            accountReads: accountReads,
            rateReads: rateReads,
            usageReads: usageReads,
            activeReads: activeReads,
            maximumConcurrentReads: maximumConcurrentReads,
            disconnects: disconnects,
            lastConnectedSession: lastConnectedSession
        )
    }
}

private actor RecordingRefreshPublisher: RefreshPublishing {
    private var publications: [RefreshPublication] = []

    func apply(_ publication: RefreshPublication) async {
        publications.append(publication)
    }

    func latestRateState() -> CapabilityState<RateLimitCatalog>? {
        publications.reversed().compactMap { publication in
            if case let .rate(state) = publication.change { return state }
            return nil
        }.first
    }

    func latestAccountState() -> CapabilityState<ProviderAccountSummary>? {
        publications.reversed().compactMap { publication in
            if case let .account(state) = publication.change { return state }
            return nil
        }.first
    }

    func latestUsageState() -> CapabilityState<TokenActivitySnapshot>? {
        publications.reversed().compactMap { publication in
            if case let .usage(state) = publication.change { return state }
            return nil
        }.first
    }

    func latestRatePublication() -> RefreshPublication? {
        publications.reversed().first { publication in
            if case .rate = publication.change { return true }
            return false
        }
    }

    func latestUsagePublication() -> RefreshPublication? {
        publications.reversed().first { publication in
            if case .usage = publication.change { return true }
            return false
        }
    }

    func ratePercents() -> [Int] {
        publications.compactMap { publication in
            guard case let .rate(state) = publication.change else { return nil }
            switch state {
            case let .fresh(catalog, _), let .stale(catalog, _, _):
                return catalog.selectedBucket.windows.first?.usedPercent
            case .loading, .unsupported, .unavailable:
                return nil
            }
        }
    }

    func usageLifetimes() -> [Int64] {
        publications.compactMap { publication in
            guard case let .usage(state) = publication.change else { return nil }
            switch state {
            case let .fresh(snapshot, _), let .stale(snapshot, _, _):
                return snapshot.lifetimeTokens
            case .loading, .unsupported, .unavailable:
                return nil
            }
        }
    }
}

private actor BlockingFirstRefreshPublisher: RefreshPublishing {
    private let gate: TestRefreshGate
    private var count = 0

    init(gate: TestRefreshGate) {
        self.gate = gate
    }

    func apply(_: RefreshPublication) async {
        count += 1
        if count == 1 {
            await gate.wait()
        }
    }

    func applicationCount() -> Int {
        count
    }
}

private actor BlockingFirstRateRefreshPublisher: RefreshPublishing {
    private let gate: TestRefreshGate
    private var isBlocking = false
    private var didBlock = false

    init(gate: TestRefreshGate) {
        self.gate = gate
    }

    func apply(_ publication: RefreshPublication) async {
        guard !didBlock,
              case .rate = publication.change else {
            return
        }
        didBlock = true
        isBlocking = true
        await gate.wait()
        isBlocking = false
    }

    func isBlockingOldRate() -> Bool {
        isBlocking
    }
}

private actor TestRefreshClock {
    private var monotonic: Duration = .zero
    private var wall: Date
    private var recorded: [Duration] = []
    private var permits: [Duration: Int] = [:]

    init(wallNow: Date) {
        wall = wallNow
    }

    func monotonicNow() -> Duration { monotonic }
    func wallNow() -> Date { wall }

    func advanceMonotonic(by duration: Duration) {
        monotonic += duration
    }

    func setWall(_ date: Date) {
        wall = date
    }

    func sleep(for duration: Duration) async throws {
        recorded.append(duration)
        while permits[duration, default: 0] == 0 {
            try await Task.sleep(for: .milliseconds(1))
        }
        permits[duration, default: 0] -= 1
    }

    func release(_ duration: Duration, count: Int = 1) {
        permits[duration, default: 0] += count
    }

    func recordedCount(for duration: Duration) -> Int {
        recorded.filter { $0 == duration }.count
    }

    func recordedBackoffSleeps() -> [Duration] {
        recorded.filter { $0 == .seconds(1) || $0 == .seconds(2) || $0 == .seconds(4) }
    }
}

private actor TestRefreshGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        pending.forEach { $0.resume() }
    }
}

private actor TestRefreshJitter {
    private let firstGate: TestRefreshGate
    private var calls = 0

    init(firstGate: TestRefreshGate) {
        self.firstGate = firstGate
    }

    func next() async -> Double {
        calls += 1
        if calls == 1 {
            await firstGate.wait()
        }
        return 0
    }

    func callCount() -> Int {
        calls
    }
}
