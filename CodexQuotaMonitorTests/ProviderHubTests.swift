import Dispatch
import Foundation
import Testing
import XCTest
@testable import CodexQuotaMonitor

@MainActor
final class ProviderHubTests: XCTestCase {
    func testProviderMetricRequiresMatchingProviderAndFiniteUnitFraction() throws {
        let key = try XCTUnwrap(
            ProviderMetricKey(providerID: .codex, stableID: "five-hour")
        )

        XCTAssertNil(
            ProviderMetric(
                providerID: .claudeCode,
                metricKey: key,
                remainingFraction: 0.5,
                resetAt: nil
            )
        )
        for invalidFraction in [
            -0.01,
            1.01,
            Double.nan,
            Double.infinity,
            -Double.infinity,
        ] {
            XCTAssertNil(
                ProviderMetric(
                    providerID: .codex,
                    metricKey: key,
                    remainingFraction: invalidFraction,
                    resetAt: nil
                )
            )
        }

        let zero = try XCTUnwrap(
            ProviderMetric(
                providerID: .codex,
                metricKey: key,
                remainingFraction: 0,
                resetAt: nil
            )
        )
        XCTAssertEqual(zero.providerID, .codex)
        XCTAssertEqual(zero.metricKey, key)
        XCTAssertEqual(zero.remainingFraction, 0)
    }

    func testProviderMetricRejectsNonFiniteResetDate() throws {
        let key = try XCTUnwrap(
            ProviderMetricKey(providerID: .codex, stableID: "five-hour")
        )

        for invalidInterval in [
            Double.nan,
            Double.infinity,
            -Double.infinity,
        ] {
            XCTAssertNil(
                ProviderMetric(
                    providerID: .codex,
                    metricKey: key,
                    remainingFraction: 0.5,
                    resetAt: Date(
                        timeIntervalSinceReferenceDate: invalidInterval
                    )
                )
            )
        }
    }

    func testProviderMetricDurationIsOptionalAndMustBePositive() throws {
        let key = try XCTUnwrap(
            ProviderMetricKey(providerID: .codex, stableID: "dynamic-window")
        )
        let metricWithoutDuration = try XCTUnwrap(
            ProviderMetric(
                providerID: .codex,
                metricKey: key,
                remainingFraction: 0.5,
                resetAt: nil
            )
        )
        XCTAssertNil(metricWithoutDuration.durationMinutes)

        for invalidDuration: Int64 in [0, -1] {
            XCTAssertNil(
                ProviderMetric(
                    providerID: .codex,
                    metricKey: key,
                    remainingFraction: 0.5,
                    resetAt: nil,
                    durationMinutes: invalidDuration
                )
            )
        }

        let metric = try XCTUnwrap(
            ProviderMetric(
                providerID: .codex,
                metricKey: key,
                remainingFraction: 0.5,
                resetAt: nil,
                durationMinutes: 300
            )
        )
        XCTAssertEqual(metric.durationMinutes, 300)
    }

    func testProviderSnapshotRejectsMetricOwnedByAnotherProvider() throws {
        let key = try XCTUnwrap(
            ProviderMetricKey(providerID: .codex, stableID: "weekly")
        )
        let metric = try XCTUnwrap(
            ProviderMetric(
                providerID: .codex,
                metricKey: key,
                remainingFraction: 0.25,
                resetAt: nil
            )
        )

        XCTAssertNil(
            ProviderSnapshot(
                providerID: .claudeCode,
                metrics: [metric],
                capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )
    }

    func testProviderSnapshotRejectsDuplicateMetricKeys() throws {
        let key = try XCTUnwrap(
            ProviderMetricKey(providerID: .codex, stableID: "weekly")
        )
        let firstMetric = try XCTUnwrap(
            ProviderMetric(
                providerID: .codex,
                metricKey: key,
                remainingFraction: 0.25,
                resetAt: nil
            )
        )
        let secondMetric = try XCTUnwrap(
            ProviderMetric(
                providerID: .codex,
                metricKey: key,
                remainingFraction: 0.75,
                resetAt: nil
            )
        )

        XCTAssertNil(
            ProviderSnapshot(
                providerID: .codex,
                metrics: [firstMetric, secondMetric],
                capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )
    }

    func testProviderSnapshotRejectsNonFiniteCaptureDate() {
        for invalidInterval in [
            Double.nan,
            Double.infinity,
            -Double.infinity,
        ] {
            XCTAssertNil(
                ProviderSnapshot(
                    providerID: .codex,
                    metrics: [],
                    capturedAt: Date(
                        timeIntervalSinceReferenceDate: invalidInterval
                    )
                )
            )
        }
    }

    func testProviderSnapshotCarriesOptionalPresenceAccountAndTokenLanes() throws {
        let identity = try XCTUnwrap(
            MaskedAccountIdentity.maskingEmail("alice" + "@example.com")
        )
        let tokenActivity = ProviderTokenActivity(
            today: TokenActivityBreakdown(
                inputTokens: .notReturned,
                outputTokens: .notReturned,
                totalTokens: .available(120)
            ),
            currentMonth: TokenActivityBreakdown(
                inputTokens: .notReturned,
                outputTokens: .notReturned,
                totalTokens: .available(3_400)
            )
        )
        let observedAt = Date(timeIntervalSince1970: 1_700_000_100)
        let snapshot = try XCTUnwrap(
            ProviderSnapshot(
                providerID: .codex,
                metrics: [],
                capturedAt: Date(timeIntervalSince1970: 1_700_000_200),
                runtimePresence: .command(available: true),
                accountSummary: ProviderAccountSummary(
                    maskedIdentity: identity
                ),
                tokenActivity: .fresh(tokenActivity, observedAt)
            )
        )

        XCTAssertEqual(snapshot.runtimePresence, .command(available: true))
        XCTAssertEqual(snapshot.accountSummary?.maskedIdentity, identity)
        XCTAssertEqual(snapshot.tokenActivity, .fresh(tokenActivity, observedAt))
    }

    func testProviderSnapshotRejectsRunningApplicationThatIsNotInstalled() {
        XCTAssertNil(
            ProviderSnapshot(
                providerID: .googleAntigravity,
                metrics: [],
                capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                runtimePresence: .application(
                    installed: false,
                    running: true
                )
            )
        )
        XCTAssertNotNil(
            ProviderSnapshot(
                providerID: .googleAntigravity,
                metrics: [],
                capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                runtimePresence: .application(
                    installed: true,
                    running: true
                )
            )
        )
    }

    func testProviderSnapshotRejectsNonFiniteNestedTokenDates() {
        let activity = ProviderTokenActivity(
            today: TokenActivityBreakdown(
                inputTokens: .notReturned,
                outputTokens: .notReturned,
                totalTokens: .notReturned
            ),
            currentMonth: TokenActivityBreakdown(
                inputTokens: .notReturned,
                outputTokens: .notReturned,
                totalTokens: .notReturned
            )
        )

        for invalidInterval in [
            Double.nan,
            Double.infinity,
            -Double.infinity,
        ] {
            let invalidDate = Date(
                timeIntervalSinceReferenceDate: invalidInterval
            )
            XCTAssertNil(
                ProviderSnapshot(
                    providerID: .codex,
                    metrics: [],
                    capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    tokenActivity: .fresh(activity, invalidDate)
                )
            )
            XCTAssertNil(
                ProviderSnapshot(
                    providerID: .codex,
                    metrics: [],
                    capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    tokenActivity: .stale(activity, invalidDate, .stale)
                )
            )
        }
    }

    func testProviderSnapshotExistingInitializerRemainsSourceCompatible() {
        let snapshot = ProviderSnapshot(
            providerID: .codex,
            metrics: [],
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertNotNil(snapshot)
        XCTAssertNil(snapshot?.runtimePresence)
        XCTAssertNil(snapshot?.accountSummary)
        XCTAssertNil(snapshot?.tokenActivity)
    }

    func testTrueZeroSnapshotIsDistinctFromUnsupportedPresentation() throws {
        let key = try XCTUnwrap(
            ProviderMetricKey(providerID: .codex, stableID: "five-hour")
        )
        let metric = try XCTUnwrap(
            ProviderMetric(
                providerID: .codex,
                metricKey: key,
                remainingFraction: 0,
                resetAt: nil
            )
        )
        let snapshot = try XCTUnwrap(
            ProviderSnapshot(
                providerID: .codex,
                metrics: [metric],
                capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )

        XCTAssertNotEqual(
            ProviderPresentationState.fresh(snapshot),
            ProviderPresentationState.unsupported
        )
        XCTAssertNotEqual(
            ProviderPresentationState.stale(snapshot),
            ProviderPresentationState.notConnected
        )
    }

    func testStoreRejectsSnapshotPublishedForAnotherProvider() throws {
        let snapshot = try XCTUnwrap(
            ProviderSnapshot(
                providerID: .claudeCode,
                metrics: [],
                capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )
        let store = ProviderDashboardStore()
        let codexGeneration = store.activate(.codex)

        XCTAssertFalse(
            store.apply(.fresh(snapshot), for: codexGeneration)
        )
        XCTAssertEqual(store.state(for: .codex), .loading)
    }

    func testEmptySelectionStartsNoConnectors() async {
        let connectors = ProviderID.allCases.map {
            ControlledProviderConnector(providerID: $0)
        }
        let store = ProviderDashboardStore()
        let hub = ProviderHub(store: store, connectors: connectors)

        hub.reconcile(enabledProviders: [])
        await drainTasks()

        XCTAssertEqual(store.orderedVisibleProviders, [])
        for connector in connectors {
            let startCount = await connector.startCount()
            XCTAssertEqual(startCount, 0)
        }
    }

    func testEnabledProviderWithoutConnectorPublishesUnavailableFailure() {
        let store = ProviderDashboardStore()
        let hub = ProviderHub(store: store, connectors: [])

        hub.reconcile(enabledProviders: [.codex])

        guard case let .failed(code) = store.state(for: .codex) else {
            XCTFail("Expected connector-unavailable failure")
            return
        }
        XCTAssertEqual(code.rawValue, "connector-unavailable")
        XCTAssertEqual(store.orderedVisibleProviders, [.codex])
    }

    func testImmediateDisableBeforeTaskStartsDoesNotInvokeConnector() async {
        let connector = ControlledProviderConnector(providerID: .codex)
        let store = ProviderDashboardStore()
        let hub = ProviderHub(store: store, connectors: [connector])

        hub.reconcile(enabledProviders: [.codex])
        hub.reconcile(enabledProviders: [])
        await drainTasks()

        let startCount = await connector.startCount()
        let unfinishedRuns = await connector.unfinishedRunCount()
        XCTAssertEqual(startCount, 0)
        XCTAssertEqual(unfinishedRuns, 0)
    }

    func testImmediateDisableAndReenableStartsOnlyNewGeneration() async {
        let connector = ControlledProviderConnector(providerID: .codex)
        let store = ProviderDashboardStore()
        let hub = ProviderHub(store: store, connectors: [connector])

        hub.reconcile(enabledProviders: [.codex])
        hub.reconcile(enabledProviders: [])
        hub.reconcile(enabledProviders: [.codex])

        await assertEventually { await connector.startCount() >= 1 }
        await drainTasks()
        let startCount = await connector.startCount()
        XCTAssertEqual(startCount, 1)

        await connector.publish(.unsupported, runIndex: 0)
        await assertEventually {
            store.state(for: .codex) == .unsupported
        }

        hub.reconcile(enabledProviders: [])
        await assertEventually {
            await connector.unfinishedRunCount() == 0
        }
    }

    func testStopAndWaitDrainsRapidManualRefreshConnectorRuns() async {
        let connector = ControlledProviderConnector(
            providerID: .claudeCode,
            finishesOnCancellation: false
        )
        let store = ProviderDashboardStore()
        let hub = ProviderHub(store: store, connectors: [connector])

        hub.reconcile(enabledProviders: [.claudeCode])
        await assertEventually { await connector.startCount() == 1 }
        hub.manualRefreshNonCodexProviders(
            enabledProviders: [.claudeCode]
        )
        await assertEventually { await connector.startCount() == 2 }
        hub.manualRefreshNonCodexProviders(
            enabledProviders: [.claudeCode]
        )
        await assertEventually { await connector.startCount() == 3 }

        let completion = AsyncCompletionProbe()
        let stopTask = Task { @MainActor in
            await hub.stopAndWait()
            await completion.markComplete()
        }
        await assertEventually {
            await connector.cancellationCount() == 3
        }
        let completedBeforeRunsFinish = await completion.isComplete()
        XCTAssertFalse(completedBeforeRunsFinish)
        XCTAssertNil(store.state(for: .claudeCode))

        await connector.publish(.unsupported, runIndex: 0)
        await connector.publish(.unsupported, runIndex: 1)
        await connector.publish(.unsupported, runIndex: 2)
        await drainTasks()
        XCTAssertNil(store.state(for: .claudeCode))

        await connector.fail(runIndex: 0)
        await drainTasks()
        let completedAfterFirstRun = await completion.isComplete()
        XCTAssertFalse(completedAfterFirstRun)
        await connector.fail(runIndex: 1)
        await drainTasks()
        let completedAfterSecondRun = await completion.isComplete()
        XCTAssertFalse(completedAfterSecondRun)
        await connector.fail(runIndex: 2)
        await stopTask.value

        let completedAfterBothRuns = await completion.isComplete()
        let unfinishedRuns = await connector.unfinishedRunCount()
        XCTAssertTrue(completedAfterBothRuns)
        XCTAssertEqual(unfinishedRuns, 0)
    }

    func testManualRefreshPreservesSnapshotsOrderAndFencesOldTaskOutput()
        async throws
    {
        let google = ControlledProviderConnector(
            providerID: .googleAntigravity,
            finishesOnCancellation: false
        )
        let codex = ControlledProviderConnector(providerID: .codex)
        let claude = ControlledProviderConnector(providerID: .claudeCode)
        let kimi = ControlledProviderConnector(providerID: .kimiCode)
        let connectors = [google, codex, claude, kimi]
        let store = ProviderDashboardStore()
        let hub = ProviderHub(store: store, connectors: connectors)
        let enabled = ProviderID.allCases
        let googleSnapshot = try makeSnapshot(
            providerID: .googleAntigravity,
            remainingFraction: 0.8
        )
        let claudeSnapshot = try makeSnapshot(
            providerID: .claudeCode,
            remainingFraction: 0.7
        )
        let kimiSnapshot = try makeSnapshot(
            providerID: .kimiCode,
            remainingFraction: 0.6
        )

        hub.reconcile(enabledProviders: enabled)
        await assertEventually {
            for connector in connectors {
                if await connector.startCount() != 1 { return false }
            }
            return true
        }
        await google.publish(.fresh(googleSnapshot), runIndex: 0)
        await codex.publish(.unsupported, runIndex: 0)
        await claude.publish(.fresh(claudeSnapshot), runIndex: 0)
        await kimi.publish(.fresh(kimiSnapshot), runIndex: 0)
        await assertEventually {
            store.state(for: .googleAntigravity) == .fresh(googleSnapshot)
                && store.state(for: .codex) == .unsupported
                && store.state(for: .claudeCode) == .fresh(claudeSnapshot)
                && store.state(for: .kimiCode) == .fresh(kimiSnapshot)
        }
        let statesBeforeRefresh = store.statesByProvider

        hub.manualRefreshNonCodexProviders(enabledProviders: enabled)

        XCTAssertEqual(store.orderedVisibleProviders, enabled)
        XCTAssertEqual(store.statesByProvider, statesBeforeRefresh)
        await assertEventually {
            let googleStarts = await google.startCount()
            let codexStarts = await codex.startCount()
            let claudeStarts = await claude.startCount()
            let kimiStarts = await kimi.startCount()
            return googleStarts == 2
                && codexStarts == 1
                && claudeStarts == 2
                && kimiStarts == 2
        }

        await google.publish(.failed(code: .connectorFailed), runIndex: 0)
        await google.fail(runIndex: 0)
        await drainTasks()
        XCTAssertEqual(
            store.state(for: .googleAntigravity),
            .fresh(googleSnapshot)
        )
        XCTAssertEqual(store.state(for: .codex), .unsupported)
        XCTAssertEqual(
            store.state(for: .claudeCode),
            .fresh(claudeSnapshot)
        )
        XCTAssertEqual(
            store.state(for: .kimiCode),
            .fresh(kimiSnapshot)
        )

        let enabledAfterKimiDisable = enabled.filter { $0 != .kimiCode }
        hub.manualRefreshNonCodexProviders(
            enabledProviders: enabledAfterKimiDisable
        )
        await assertEventually {
            let googleStarts = await google.startCount()
            let claudeStarts = await claude.startCount()
            let kimiStarts = await kimi.startCount()
            return googleStarts == 3
                && claudeStarts == 3
                && kimiStarts == 2
        }
        XCTAssertNil(store.state(for: .kimiCode))
        XCTAssertEqual(
            store.orderedVisibleProviders,
            enabledAfterKimiDisable
        )

        let stopTask = Task { @MainActor in
            await hub.stopAndWait()
        }
        await google.fail(runIndex: 1)
        await google.fail(runIndex: 2)
        await stopTask.value
        await assertEventually {
            for connector in connectors {
                if await connector.unfinishedRunCount() != 0 { return false }
            }
            return true
        }
    }

    func testOnlyEnabledProvidersStartAndBeginLoadingInSettingsOrder() async {
        let connectors = ProviderID.allCases.map {
            ControlledProviderConnector(providerID: $0)
        }
        let store = ProviderDashboardStore()
        let hub = ProviderHub(store: store, connectors: connectors)
        let enabled: [ProviderID] = [.claudeCode, .codex]

        hub.reconcile(enabledProviders: enabled)

        XCTAssertEqual(store.orderedVisibleProviders, enabled)
        XCTAssertEqual(store.state(for: .claudeCode), .loading)
        XCTAssertEqual(store.state(for: .codex), .loading)
        XCTAssertNil(store.state(for: .googleAntigravity))
        XCTAssertNil(store.state(for: .kimiCode))
        await assertEventually {
            let codexStarts = await connectors[1].startCount()
            let claudeStarts = await connectors[2].startCount()
            return codexStarts == 1 && claudeStarts == 1
        }
        let googleStarts = await connectors[0].startCount()
        let kimiStarts = await connectors[3].startCount()
        XCTAssertEqual(googleStarts, 0)
        XCTAssertEqual(kimiStarts, 0)

        hub.reconcile(enabledProviders: [])
        await assertEventually {
            let codexCancellations = await connectors[1].cancellationCount()
            let claudeCancellations = await connectors[2].cancellationCount()
            return codexCancellations == 1 && claudeCancellations == 1
        }
    }

    func testLatePublishFromDisabledGenerationIsIgnored() async {
        let connector = ControlledProviderConnector(providerID: .codex)
        let store = ProviderDashboardStore()
        let hub = ProviderHub(store: store, connectors: [connector])

        hub.reconcile(enabledProviders: [.codex])
        await assertEventually { await connector.startCount() == 1 }

        hub.reconcile(enabledProviders: [])
        XCTAssertNil(store.state(for: .codex))

        await connector.publish(.unsupported)
        await drainTasks()

        XCTAssertNil(store.state(for: .codex))
    }

    func testConnectorErrorPublishesStableFailureCode() async {
        let connector = ControlledProviderConnector(providerID: .codex)
        let store = ProviderDashboardStore()
        let hub = ProviderHub(store: store, connectors: [connector])

        hub.reconcile(enabledProviders: [.codex])
        await assertEventually { await connector.startCount() == 1 }
        await connector.fail(runIndex: 0)

        await assertEventually {
            store.state(for: .codex) == .failed(code: .connectorFailed)
        }
        hub.reconcile(enabledProviders: [])
    }

    func testLateErrorFromOldGenerationCannotReplaceNewLoadingState() async {
        let connector = ControlledProviderConnector(
            providerID: .codex,
            finishesOnCancellation: false
        )
        let store = ProviderDashboardStore()
        let hub = ProviderHub(store: store, connectors: [connector])

        hub.reconcile(enabledProviders: [.codex])
        await assertEventually { await connector.startCount() == 1 }
        await connector.publish(.unsupported, runIndex: 0)
        await assertEventually {
            store.state(for: .codex) == .unsupported
        }

        hub.reconcile(enabledProviders: [])
        hub.reconcile(enabledProviders: [.codex])
        XCTAssertEqual(store.state(for: .codex), .loading)
        await assertEventually { await connector.startCount() == 2 }

        await connector.fail(runIndex: 0)
        await drainTasks()

        XCTAssertEqual(store.state(for: .codex), .loading)
        await connector.fail(runIndex: 1)
        await assertEventually {
            store.state(for: .codex) == .failed(code: .connectorFailed)
        }
        hub.reconcile(enabledProviders: [])
    }

    func testDisableInvalidatesBeforeCancellationAndRemovesAfterCancellation() async {
        let recorder = LifecycleEventRecorder()
        let dashboard = ProviderDashboardStore()
        let recordingStore = RecordingProviderDashboardStore(
            base: dashboard,
            recorder: recorder
        )
        let connector = ControlledProviderConnector(
            providerID: .codex,
            cancellationObserver: {
                recorder.record(.cancelled)
            }
        )
        let hub = ProviderHub(store: recordingStore, connectors: [connector])

        hub.reconcile(enabledProviders: [.codex])
        await assertEventually { await connector.startCount() == 1 }

        hub.reconcile(enabledProviders: [])

        XCTAssertEqual(
            recorder.events,
            [.invalidated, .cancelled, .removed]
        )
        XCTAssertNil(dashboard.state(for: .codex))
        await assertEventually { await connector.cancellationCount() == 1 }
    }

    func testSettingsObservationRunsOnlyNormalizedSelectableProviders() async {
        let settingsStore = SettingsStore(
            fileURL: URL(fileURLWithPath: "/provider-hub-settings.json"),
            fileStore: ProviderHubSettingsFileStore()
        )
        let connectors = ProviderID.allCases.map {
            ControlledProviderConnector(providerID: $0)
        }
        let dashboard = ProviderDashboardStore()
        let hub = ProviderHub(store: dashboard, connectors: connectors)

        hub.start(settingsStore: settingsStore)
        await assertEventually { await connectors[1].startCount() == 1 }

        var updatedSettings = settingsStore.settings
        updatedSettings.enabledProviders = [.kimiCode, .claudeCode]
        if case let .failure(error) = settingsStore.replace(with: updatedSettings) {
            XCTFail("Settings update failed: \(error)")
        }

        await assertEventually {
            dashboard.orderedVisibleProviders == [.codex, .claudeCode]
                && settingsStore.settings.enabledProviders
                    == [.codex, .claudeCode]
        }
        let googleStarts = await connectors[0].startCount()
        let claudeStarts = await connectors[2].startCount()
        let kimiStarts = await connectors[3].startCount()
        let codexCancellations = await connectors[1].cancellationCount()
        XCTAssertEqual(googleStarts, 0)
        XCTAssertEqual(claudeStarts, 1)
        XCTAssertEqual(kimiStarts, 0)
        XCTAssertEqual(codexCancellations, 0)

        updatedSettings = settingsStore.settings
        updatedSettings.enabledProviders = [.kimiCode]
        if case let .failure(error) = settingsStore.replace(with: updatedSettings) {
            XCTFail("Settings update failed: \(error)")
        }
        await assertEventually {
            let claudeCancellations = await connectors[2].cancellationCount()
            return dashboard.orderedVisibleProviders == [.codex]
                && settingsStore.settings.enabledProviders == [.codex]
                && claudeCancellations == 1
        }

        hub.stop()
        await assertEventually {
            await connectors[1].cancellationCount() == 1
        }
        XCTAssertEqual(dashboard.orderedVisibleProviders, [])
    }

    func testPersistedDisableAttemptKeepsExistingCodexGeneration()
        async throws
    {
        let settingsStore = SettingsStore(
            fileURL: URL(fileURLWithPath: "/provider-hub-rapid-settings.json"),
            fileStore: ProviderHubSettingsFileStore()
        )
        let connector = ControlledProviderConnector(
            providerID: .codex,
            finishesOnCancellation: false
        )
        let dashboard = ProviderDashboardStore()
        let hub = ProviderHub(store: dashboard, connectors: [connector])
        let oldSnapshot = try makeSnapshot(
            providerID: .codex,
            remainingFraction: 0.8
        )

        hub.start(settingsStore: settingsStore)
        await assertEventually { await connector.startCount() == 1 }
        await connector.publish(.fresh(oldSnapshot), runIndex: 0)
        await assertEventually {
            dashboard.state(for: .codex) == .fresh(oldSnapshot)
        }

        var settings = settingsStore.settings
        settings.enabledProviders = []
        try settingsStore.replace(with: settings).get()

        await assertEventually {
            settingsStore.settings.enabledProviders == [.codex]
                && dashboard.state(for: .codex) == .fresh(oldSnapshot)
        }
        let startCount = await connector.startCount()
        let cancellationCount = await connector.cancellationCount()
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(cancellationCount, 0)

        hub.stop()
        await connector.fail(runIndex: 0)
        await assertEventually { await connector.unfinishedRunCount() == 0 }
    }

    func testReenableStartsLoadingAndOldSnapshotCannotFlash() async throws {
        let connector = ControlledProviderConnector(
            providerID: .codex,
            finishesOnCancellation: false
        )
        let dashboard = ProviderDashboardStore()
        let hub = ProviderHub(store: dashboard, connectors: [connector])
        let oldSnapshot = try makeSnapshot(
            providerID: .codex,
            remainingFraction: 0.8
        )
        let newSnapshot = try makeSnapshot(
            providerID: .codex,
            remainingFraction: 0.4
        )

        hub.reconcile(enabledProviders: [.codex])
        await assertEventually { await connector.startCount() == 1 }
        await connector.publish(.fresh(oldSnapshot), runIndex: 0)
        await assertEventually {
            dashboard.state(for: .codex) == .fresh(oldSnapshot)
        }

        hub.reconcile(enabledProviders: [])
        XCTAssertNil(dashboard.state(for: .codex))
        hub.reconcile(enabledProviders: [.codex])
        XCTAssertEqual(dashboard.state(for: .codex), .loading)
        await assertEventually { await connector.startCount() == 2 }

        await connector.publish(.fresh(oldSnapshot), runIndex: 0)
        await drainTasks()
        XCTAssertEqual(dashboard.state(for: .codex), .loading)
        await connector.fail(runIndex: 0)

        await connector.publish(.fresh(newSnapshot), runIndex: 1)
        await assertEventually {
            dashboard.state(for: .codex) == .fresh(newSnapshot)
        }

        hub.reconcile(enabledProviders: [])
        await connector.fail(runIndex: 1)
        await assertEventually { await connector.unfinishedRunCount() == 0 }
    }

    func testOneProviderFailureDoesNotAffectAnotherProvider() async {
        let codex = ControlledProviderConnector(providerID: .codex)
        let claude = ControlledProviderConnector(providerID: .claudeCode)
        let dashboard = ProviderDashboardStore()
        let hub = ProviderHub(store: dashboard, connectors: [codex, claude])

        hub.reconcile(enabledProviders: [.codex, .claudeCode])
        await assertEventually {
            let codexStarts = await codex.startCount()
            let claudeStarts = await claude.startCount()
            return codexStarts == 1 && claudeStarts == 1
        }

        await codex.fail(runIndex: 0)
        await claude.publish(.notConnected)

        await assertEventually {
            dashboard.state(for: .codex) == .failed(code: .connectorFailed)
                && dashboard.state(for: .claudeCode) == .notConnected
        }
        XCTAssertEqual(
            dashboard.orderedVisibleProviders,
            [.codex, .claudeCode]
        )

        hub.reconcile(enabledProviders: [])
        await assertEventually { await claude.unfinishedRunCount() == 0 }
    }

    func testReorderPreservesStatesWithoutRestartingConnectors() async {
        let codex = ControlledProviderConnector(providerID: .codex)
        let claude = ControlledProviderConnector(providerID: .claudeCode)
        let dashboard = ProviderDashboardStore()
        let hub = ProviderHub(store: dashboard, connectors: [codex, claude])

        hub.reconcile(enabledProviders: [.codex, .claudeCode])
        await assertEventually {
            let codexStarts = await codex.startCount()
            let claudeStarts = await claude.startCount()
            return codexStarts == 1 && claudeStarts == 1
        }
        await codex.publish(.unsupported)
        await claude.publish(.notConnected)
        await assertEventually {
            dashboard.state(for: .codex) == .unsupported
                && dashboard.state(for: .claudeCode) == .notConnected
        }

        hub.reconcile(enabledProviders: [.claudeCode, .codex])

        XCTAssertEqual(
            dashboard.orderedVisibleProviders,
            [.claudeCode, .codex]
        )
        XCTAssertEqual(dashboard.state(for: .claudeCode), .notConnected)
        XCTAssertEqual(dashboard.state(for: .codex), .unsupported)
        let codexStarts = await codex.startCount()
        let claudeStarts = await claude.startCount()
        XCTAssertEqual(codexStarts, 1)
        XCTAssertEqual(claudeStarts, 1)

        hub.reconcile(enabledProviders: [])
        await assertEventually {
            let codexRuns = await codex.unfinishedRunCount()
            let claudeRuns = await claude.unfinishedRunCount()
            return codexRuns == 0 && claudeRuns == 0
        }
    }

    func testAllSixteenProviderSelectionsAreReconciled() async {
        let allProviders = ProviderID.allCases

        for mask in 0..<(1 << allProviders.count) {
            let enabled = allProviders.enumerated().compactMap { index, providerID in
                mask & (1 << index) == 0 ? nil : providerID
            }
            let connectors = allProviders.map {
                ControlledProviderConnector(providerID: $0)
            }
            let dashboard = ProviderDashboardStore()
            let hub = ProviderHub(store: dashboard, connectors: connectors)

            hub.reconcile(enabledProviders: enabled)

            XCTAssertEqual(
                dashboard.orderedVisibleProviders,
                enabled,
                "selection mask \(mask)"
            )
            for providerID in allProviders {
                XCTAssertEqual(
                    dashboard.state(for: providerID),
                    enabled.contains(providerID) ? .loading : nil,
                    "selection mask \(mask), provider \(providerID)"
                )
            }
            await assertEventually {
                for (index, connector) in connectors.enumerated() {
                    let starts = await connector.startCount()
                    let expected = mask & (1 << index) == 0 ? 0 : 1
                    if starts != expected {
                        return false
                    }
                }
                return true
            }

            hub.reconcile(enabledProviders: [])
            await assertEventually {
                for connector in connectors {
                    if await connector.unfinishedRunCount() != 0 {
                        return false
                    }
                }
                return true
            }
        }
    }

    func testHubDeinitCancelsOwnedTasksWithoutSuspendedContinuations() async {
        let connector = ControlledProviderConnector(providerID: .codex)
        let dashboard = ProviderDashboardStore()
        var hub: ProviderHub? = ProviderHub(
            store: dashboard,
            connectors: [connector]
        )
        weak var weakHub: ProviderHub?
        weakHub = hub

        hub?.reconcile(enabledProviders: [.codex])
        await assertEventually { await connector.startCount() == 1 }

        hub = nil

        XCTAssertNil(weakHub)
        await assertEventually {
            let cancellations = await connector.cancellationCount()
            let unfinishedRuns = await connector.unfinishedRunCount()
            return cancellations == 1 && unfinishedRuns == 0
        }
        await connector.fail(runIndex: 0)
    }

    func testImmediateHubDeinitBeforeTaskStartsDoesNotInvokeConnector() async {
        let connector = ControlledProviderConnector(providerID: .codex)
        let dashboard = ProviderDashboardStore()
        var hub: ProviderHub? = ProviderHub(
            store: dashboard,
            connectors: [connector]
        )

        hub?.reconcile(enabledProviders: [.codex])
        hub = nil
        await drainTasks()

        let startCount = await connector.startCount()
        let unfinishedRuns = await connector.unfinishedRunCount()
        XCTAssertEqual(startCount, 0)
        XCTAssertEqual(unfinishedRuns, 0)
    }

    func testNonCooperativeLatePublishAfterHubDeinitIsIgnored() async {
        let connector = ControlledProviderConnector(
            providerID: .codex,
            finishesOnCancellation: false
        )
        let dashboard = ProviderDashboardStore()
        var hub: ProviderHub? = ProviderHub(
            store: dashboard,
            connectors: [connector]
        )

        hub?.reconcile(enabledProviders: [.codex])
        await assertEventually { await connector.startCount() == 1 }

        hub = nil
        await connector.publish(.unsupported)
        await drainTasks()

        XCTAssertEqual(dashboard.state(for: .codex), .loading)

        await connector.fail(runIndex: 0)
        await drainTasks()
        let unfinishedRuns = await connector.unfinishedRunCount()
        XCTAssertEqual(unfinishedRuns, 0)
    }

    func testNonCooperativeLateErrorAfterHubDeinitIsIgnored() async {
        let connector = ControlledProviderConnector(
            providerID: .codex,
            finishesOnCancellation: false
        )
        let dashboard = ProviderDashboardStore()
        var hub: ProviderHub? = ProviderHub(
            store: dashboard,
            connectors: [connector]
        )

        hub?.reconcile(enabledProviders: [.codex])
        await assertEventually { await connector.startCount() == 1 }

        hub = nil
        await connector.fail(runIndex: 0)
        await drainTasks()

        XCTAssertEqual(dashboard.state(for: .codex), .loading)
        let unfinishedRuns = await connector.unfinishedRunCount()
        XCTAssertEqual(unfinishedRuns, 0)
    }

    func testApplyKeepsHubAliveThroughReentrantTeardown() async {
        let connector = ControlledProviderConnector(providerID: .codex)
        let probe = ProviderHubReentrantTeardownProbe()
        let dashboard = RecordingProviderDashboardStore(
            base: ProviderDashboardStore(),
            recorder: LifecycleEventRecorder(),
            beforeApply: { probe.releaseHubDuringApply() }
        )
        probe.retain(
            ProviderHub(store: dashboard, connectors: [connector])
        )

        probe.reconcile(enabledProviders: [.codex])
        await assertEventually { await connector.startCount() == 1 }

        await connector.publish(.unsupported)

        XCTAssertEqual(probe.releaseCompletedWithinApply, true)
        XCTAssertTrue(probe.waitForReleaseCompletion())
        await drainTasks()
        let unfinishedRuns = await connector.unfinishedRunCount()
        XCTAssertEqual(unfinishedRuns, 0)
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

    private func makeSnapshot(
        providerID: ProviderID,
        remainingFraction: Double
    ) throws -> ProviderSnapshot {
        let metricKey = try XCTUnwrap(
            ProviderMetricKey(providerID: providerID, stableID: "quota")
        )
        let metric = try XCTUnwrap(
            ProviderMetric(
                providerID: providerID,
                metricKey: metricKey,
                remainingFraction: remainingFraction,
                resetAt: nil
            )
        )
        return try XCTUnwrap(
            ProviderSnapshot(
                providerID: providerID,
                metrics: [metric],
                capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )
    }

}

private final class ProviderHubReentrantTeardownProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var hub: ProviderHub?
    private let releaseCompletion = DispatchSemaphore(value: 0)
    @MainActor private(set) var releaseCompletedWithinApply: Bool?

    @MainActor
    func retain(_ hub: ProviderHub) {
        lock.lock()
        self.hub = hub
        lock.unlock()
    }

    @MainActor
    func reconcile(enabledProviders: [ProviderID]) {
        lock.lock()
        let hub = hub
        lock.unlock()
        hub?.reconcile(enabledProviders: enabledProviders)
    }

    @MainActor
    func releaseHubDuringApply() {
        let releaseDuringApply = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { [self] in
            release()
            releaseDuringApply.signal()
            releaseCompletion.signal()
        }
        releaseCompletedWithinApply = releaseDuringApply.wait(
            timeout: .now() + .seconds(1)
        ) == .success
    }

    @MainActor
    func waitForReleaseCompletion() -> Bool {
        releaseCompletion.wait(timeout: .now() + .seconds(1)) == .success
    }

    private func release() {
        lock.lock()
        hub = nil
        lock.unlock()
    }
}

#if compiler(>=6.2)
// Xcode 16.4's Testing framework has no public process-exit observation
// macro. Keep these precondition tests enabled where the public API exists;
// the remaining test target still runs on the older toolchain.
@Suite("ProviderHub boundary preconditions")
struct ProviderHubBoundaryPreconditionTests {
    @Test("duplicate connector IDs fail with the hub contract")
    func duplicateConnectorIDsFailWithHubContract() async {
        let result = await #expect(
            processExitsWith: .failure,
            observing: [\.standardErrorContent]
        ) {
            await MainActor.run {
                let first = ControlledProviderConnector(providerID: .codex)
                let second = ControlledProviderConnector(providerID: .codex)
                _ = ProviderHub(
                    store: ProviderDashboardStore(),
                    connectors: [first, second]
                )
            }
        }
        guard let result else {
            return
        }
        let standardError = String(
            decoding: result.standardErrorContent,
            as: UTF8.self
        )
        #expect(
            standardError.contains(
                "ProviderHub connectors must use unique provider IDs."
            )
        )
    }

    @Test("duplicate enabled providers fail with the settings contract")
    func duplicateEnabledProvidersFailWithSettingsContract() async {
        let result = await #expect(
            processExitsWith: .failure,
            observing: [\.standardErrorContent]
        ) {
            await MainActor.run {
                let connector = ControlledProviderConnector(
                    providerID: .codex
                )
                let hub = ProviderHub(
                    store: ProviderDashboardStore(),
                    connectors: [connector]
                )
                hub.reconcile(enabledProviders: [.codex, .codex])
            }
        }
        guard let result else {
            return
        }
        let standardError = String(
            decoding: result.standardErrorContent,
            as: UTF8.self
        )
        #expect(
            standardError.contains(
                "ProviderHub enabled providers must be unique; "
                    + "SettingsStore validates this contract."
            )
        )
    }
}
#endif

private actor ControlledProviderConnector: ProviderConnector {
    nonisolated let providerID: ProviderID

    private struct Run {
        let publisher: @Sendable (ProviderPresentationState) async -> Void
        var continuation: CheckedContinuation<Void, Error>?
        var cancellationObserved = false
    }

    private var starts = 0
    private var cancellations = 0
    private var runs: [Run] = []
    private let finishesOnCancellation: Bool
    nonisolated private let cancellationObserver: (@Sendable () -> Void)?

    init(
        providerID: ProviderID,
        finishesOnCancellation: Bool = true,
        cancellationObserver: (@Sendable () -> Void)? = nil
    ) {
        self.providerID = providerID
        self.finishesOnCancellation = finishesOnCancellation
        self.cancellationObserver = cancellationObserver
    }

    func run(
        publish: @escaping @Sendable (ProviderPresentationState) async -> Void
    ) async throws {
        let runIndex = runs.count
        starts += 1
        runs.append(Run(publisher: publish))
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                runs[runIndex].continuation = continuation
            }
        } onCancel: {
            cancellationObserver?()
            Task { await self.cancelRun(at: runIndex) }
        }
    }

    func startCount() -> Int {
        starts
    }

    func cancellationCount() -> Int {
        cancellations
    }

    func unfinishedRunCount() -> Int {
        runs.count { $0.continuation != nil }
    }

    func publish(
        _ state: ProviderPresentationState,
        runIndex: Int = 0
    ) async {
        guard runs.indices.contains(runIndex) else {
            return
        }
        await runs[runIndex].publisher(state)
    }

    func fail(runIndex: Int) {
        guard runs.indices.contains(runIndex) else {
            return
        }
        runs[runIndex].continuation?.resume(
            throwing: ControlledConnectorFailure.failed
        )
        runs[runIndex].continuation = nil
    }

    private func cancelRun(at runIndex: Int) {
        guard runs.indices.contains(runIndex),
              !runs[runIndex].cancellationObserved
        else {
            return
        }
        runs[runIndex].cancellationObserved = true
        cancellations += 1
        guard finishesOnCancellation else {
            return
        }
        runs[runIndex].continuation?.resume(throwing: CancellationError())
        runs[runIndex].continuation = nil
    }
}

private actor AsyncCompletionProbe {
    private var complete = false

    func markComplete() {
        complete = true
    }

    func isComplete() -> Bool {
        complete
    }
}

private enum ControlledConnectorFailure: Error {
    case failed
}


@MainActor
private final class RecordingProviderDashboardStore: ProviderDashboardStoring {
    private let base: ProviderDashboardStore
    private let recorder: LifecycleEventRecorder
    private let beforeApply: (() -> Void)?

    init(
        base: ProviderDashboardStore,
        recorder: LifecycleEventRecorder,
        beforeApply: (() -> Void)? = nil
    ) {
        self.base = base
        self.recorder = recorder
        self.beforeApply = beforeApply
    }

    var orderedVisibleProviders: [ProviderID] {
        base.orderedVisibleProviders
    }

    func state(for providerID: ProviderID) -> ProviderPresentationState? {
        base.state(for: providerID)
    }

    func activate(_ providerID: ProviderID) -> ProviderGeneration {
        base.activate(providerID)
    }

    func invalidate(_ providerID: ProviderID) {
        base.invalidate(providerID)
        recorder.record(.invalidated)
    }

    func remove(_ providerID: ProviderID) {
        base.remove(providerID)
        recorder.record(.removed)
    }

    func reconcileOrder(_ providerIDs: [ProviderID]) {
        base.reconcileOrder(providerIDs)
    }

    func apply(
        _ state: ProviderPresentationState,
        for generation: ProviderGeneration
    ) -> Bool {
        beforeApply?()
        return base.apply(state, for: generation)
    }
}

private final class LifecycleEventRecorder: @unchecked Sendable {
    enum Event: Equatable {
        case invalidated
        case cancelled
        case removed
    }

    private let lock = NSLock()
    private var recordedEvents: [Event] = []

    var events: [Event] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }

    func record(_ event: Event) {
        lock.lock()
        recordedEvents.append(event)
        lock.unlock()
    }
}

private final class ProviderHubSettingsFileStore: SettingsFileStoring {
    private let lock = NSLock()
    private var dataByURL: [URL: Data] = [:]

    func read(from url: URL) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return dataByURL[url]
    }

    func write(
        _ data: Data,
        to url: URL,
        options: Data.WritingOptions
    ) throws {
        lock.lock()
        dataByURL[url] = data
        lock.unlock()
    }
}
