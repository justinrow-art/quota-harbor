import Foundation
import XCTest
@testable import CodexQuotaMonitor

@MainActor
final class ProviderRuntimeCompositionTests: XCTestCase {
    func testRuntimeStartNormalizesEmptySelectionAndStartsOnlyCodex()
        async throws
    {
        let settingsStore = try makeSettingsStore(enabledProviders: [])
        let connectors = ProviderID.allCases.map {
            RuntimeControlledConnector(providerID: $0)
        }
        let runtime = ProviderRuntimeCoordinator(
            hub: ProviderHub(
                store: ProviderDashboardStore(),
                connectors: connectors
            ),
            settingsStore: settingsStore,
            codexEvents: RuntimeCodexServiceRecorder()
        )

        runtime.start()
        await drainTasks()

        for connector in connectors {
            let startCount = await connector.startCount()
            XCTAssertEqual(
                startCount,
                connector.providerID == .codex ? 1 : 0
            )
        }
        await runtime.stopAndWait()
    }

    func testCodexEventsRemainRoutedAfterDisableAttempts()
        async throws
    {
        let settingsStore = try makeSettingsStore(
            enabledProviders: [.googleAntigravity]
        )
        let codexEvents = RuntimeCodexServiceRecorder()
        let runtime = ProviderRuntimeCoordinator(
            hub: ProviderHub(
                store: ProviderDashboardStore(),
                connectors: ProviderID.allCases.map {
                    RuntimeControlledConnector(providerID: $0)
                }
            ),
            settingsStore: settingsStore,
            codexEvents: codexEvents
        )
        runtime.start()

        await routeAllEvents(to: runtime)
        let initialEvents = await codexEvents.events()
        XCTAssertEqual(
            initialEvents,
            ["resign", "active", "trigger:panelOpened", "trigger:manual"]
        )

        var settings = settingsStore.settings
        settings.enabledProviders = []
        try settingsStore.replace(with: settings).get()
        await routeAllEvents(to: runtime)
        let eventsAfterDisable = await codexEvents.events()
        XCTAssertEqual(
            eventsAfterDisable,
            [
                "resign", "active", "trigger:panelOpened", "trigger:manual",
                "resign", "active", "trigger:panelOpened", "trigger:manual",
            ]
        )
        await runtime.stopAndWait()
    }

    func testManualRefreshStartsOptionalClaudeButNeverGoogleOrKimi()
        async throws
    {
        let settingsStore = try makeSettingsStore(
            enabledProviders: ProviderID.allCases
        )
        let dashboardStore = ProviderDashboardStore()
        let google = RuntimeControlledConnector(
            providerID: .googleAntigravity
        )
        let codex = RuntimeControlledConnector(providerID: .codex)
        let claude = RuntimeControlledConnector(providerID: .claudeCode)
        let kimi = RuntimeControlledConnector(providerID: .kimiCode)
        let codexEvents = RuntimeCodexServiceRecorder()
        let runtime = ProviderRuntimeCoordinator(
            hub: ProviderHub(
                store: dashboardStore,
                connectors: [google, codex, claude, kimi]
            ),
            settingsStore: settingsStore,
            codexEvents: codexEvents
        )
        runtime.start()
        await assertEventually {
            let codexStarts = await codex.startCount()
            let claudeStarts = await claude.startCount()
            return codexStarts == 1 && claudeStarts == 1
        }
        let statesBeforeRefresh = dashboardStore.statesByProvider
        let orderBeforeRefresh = dashboardStore.orderedVisibleProviders

        await runtime.manualRefresh()
        let googleStarts = await google.startCount()
        let codexStarts = await codex.startCount()
        let claudeStarts = await claude.startCount()
        let kimiStarts = await kimi.startCount()
        XCTAssertEqual(googleStarts, 0)
        XCTAssertEqual(codexStarts, 1)
        XCTAssertEqual(claudeStarts, 2)
        XCTAssertEqual(kimiStarts, 0)
        let events = await codexEvents.events()
        XCTAssertEqual(events, ["trigger:manual"])
        XCTAssertEqual(dashboardStore.statesByProvider, statesBeforeRefresh)
        XCTAssertEqual(
            dashboardStore.orderedVisibleProviders,
            orderBeforeRefresh
        )
        await runtime.stopAndWait()
    }

    func testHubWithoutCodexConnectorNeverFallsBackToRetainedConnectors()
        async throws
    {
        let settingsStore = try makeSettingsStore(
            enabledProviders: [.googleAntigravity]
        )
        let google = RuntimeControlledConnector(
            providerID: .googleAntigravity
        )
        let kimi = RuntimeControlledConnector(providerID: .kimiCode)
        let runtime = ProviderRuntimeCoordinator(
            hub: ProviderHub(
                store: ProviderDashboardStore(),
                connectors: [google, kimi]
            ),
            settingsStore: settingsStore,
            codexEvents: RuntimeCodexServiceRecorder()
        )
        runtime.start()
        await drainTasks()

        await runtime.manualRefresh()

        let googleStarts = await google.startCount()
        let kimiStarts = await kimi.startCount()
        XCTAssertEqual(googleStarts, 0)
        XCTAssertEqual(kimiStarts, 0)
        await runtime.stopAndWait()
    }

    func testTerminationWaitsForProviderHubDrainBeforeReply() async throws {
        let settingsStore = try makeSettingsStore(enabledProviders: [.codex])
        let connector = RuntimeControlledConnector(
            providerID: .codex,
            finishesOnCancellation: false
        )
        let runtime = ProviderRuntimeCoordinator(
            hub: ProviderHub(
                store: ProviderDashboardStore(),
                connectors: [connector]
            ),
            settingsStore: settingsStore,
            codexEvents: RuntimeCodexServiceRecorder()
        )
        let completion = RuntimeCompletionProbe()
        runtime.start()
        await assertEventually { await connector.startCount() == 1 }

        let stopTask = Task { @MainActor in
            await runtime.stopAndWait()
            await completion.markComplete()
        }
        await assertEventually { await connector.cancellationCount() == 1 }
        let completedBeforeDrain = await completion.isComplete()
        XCTAssertFalse(completedBeforeDrain)

        await connector.finish()
        await stopTask.value
        let completedAfterDrain = await completion.isComplete()
        XCTAssertTrue(completedAfterDrain)
    }

    func testStartDuringNonCooperativeStopCannotEscapeDrain()
        async throws
    {
        let settingsStore = try makeSettingsStore(
            enabledProviders: [.codex]
        )
        let connector = RuntimeControlledConnector(
            providerID: .codex,
            finishesOnCancellation: false
        )
        let runtime = ProviderRuntimeCoordinator(
            hub: ProviderHub(
                store: ProviderDashboardStore(),
                connectors: [connector]
            ),
            settingsStore: settingsStore,
            codexEvents: RuntimeCodexServiceRecorder()
        )
        let completion = RuntimeCompletionProbe()
        runtime.start()
        await assertEventually { await connector.startCount() == 1 }

        let stopTask = Task { @MainActor in
            await runtime.stopAndWait()
            await completion.markComplete()
        }
        await assertEventually { await connector.cancellationCount() == 1 }

        runtime.start()
        await drainTasks()
        let startsDuringStop = await connector.startCount()
        let completedDuringStop = await completion.isComplete()
        XCTAssertEqual(startsDuringStop, 1)
        XCTAssertFalse(completedDuringStop)

        await connector.finish()
        await stopTask.value
        let startsAfterStop = await connector.startCount()
        let completedAfterDrain = await completion.isComplete()
        XCTAssertEqual(startsAfterStop, 1)
        XCTAssertTrue(completedAfterDrain)
    }

    func testImmediateManualRefreshKeepsCodexOnlyAfterUnsafeUpdate()
        async throws
    {
        let settingsStore = try makeSettingsStore(
            enabledProviders: [.googleAntigravity, .kimiCode]
        )
        let dashboardStore = ProviderDashboardStore()
        let google = RuntimeControlledConnector(
            providerID: .googleAntigravity
        )
        let kimi = RuntimeControlledConnector(providerID: .kimiCode)
        let codex = RuntimeControlledConnector(providerID: .codex)
        let runtime = ProviderRuntimeCoordinator(
            hub: ProviderHub(
                store: dashboardStore,
                connectors: [google, codex, kimi]
            ),
            settingsStore: settingsStore,
            codexEvents: RuntimeCodexServiceRecorder()
        )
        runtime.start()
        await assertEventually { await codex.startCount() == 1 }

        var settings = settingsStore.settings
        settings.enabledProviders = [.googleAntigravity]
        try settingsStore.replace(with: settings).get()
        await runtime.manualRefresh()

        let googleStarts = await google.startCount()
        let kimiStarts = await kimi.startCount()
        XCTAssertEqual(googleStarts, 0)
        XCTAssertEqual(kimiStarts, 0)
        XCTAssertEqual(
            dashboardStore.orderedVisibleProviders,
            [.codex]
        )
        XCTAssertNotNil(dashboardStore.state(for: .codex))
        XCTAssertNil(dashboardStore.state(for: .kimiCode))
        await runtime.stopAndWait()
    }

    func testProductionCompositionStartsOnlyCodex()
        async throws
    {
        let settingsStore = try makeSettingsStore(
            enabledProviders: [.codex]
        )
        let quotaStore = QuotaStore()
        let codex = RuntimeCodexServiceRecorder()
        let composition = ProductionProviderComposition.make(
            quotaStore: quotaStore,
            settingsStore: settingsStore,
            codexService: codex
        )

        composition.runtimeCoordinator.start()
        await drainTasks()
        let initialCodexStarts = await codex.startCount()
        XCTAssertEqual(initialCodexStarts, 1)
        XCTAssertEqual(
            composition.dashboardStore.orderedVisibleProviders,
            [.codex]
        )

        await composition.runtimeCoordinator.manualRefresh()
        let refreshedCodexEvents = await codex.events()
        XCTAssertEqual(
            refreshedCodexEvents,
            ["start:1", "trigger:manual"]
        )
        XCTAssertEqual(
            composition.dashboardStore.orderedVisibleProviders,
            [.codex]
        )

        await composition.runtimeCoordinator.stopAndWait()
        await assertEventually { await codex.stopCount() == 1 }
    }

    func testProductionCompositionInjectsCodexAndClaudeConnectorsOnly()
        throws
    {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "CodexQuotaMonitor/Lifecycle/ProviderRuntimeCoordinator.swift"
            )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let composition = try XCTUnwrap(
            source.components(
                separatedBy: "struct ProductionProviderComposition"
            ).last
        )

        XCTAssertTrue(composition.contains("claudeAuthFetcher:"))
        XCTAssertTrue(composition.contains("claudeCacheLoader:"))
        XCTAssertTrue(composition.contains("ClaudeProviderConnector"))
        XCTAssertTrue(
            composition.contains(
                "connectors: [codexConnector, claudeConnector]"
            )
        )
        XCTAssertFalse(
            composition.contains("GoogleAntigravityProviderConnector")
        )
        XCTAssertFalse(composition.contains("KimiCodeProviderConnector"))
    }

    func testProductionCompositionUsesInjectedClaudeDependenciesWhenEnabled()
        async throws
    {
        let settingsStore = try makeSettingsStore(
            enabledProviders: [.codex, .claudeCode]
        )
        let auth = RuntimeClaudeAuthFetcher()
        let cache = RuntimeClaudeCacheLoader()
        let composition = ProductionProviderComposition.make(
            quotaStore: QuotaStore(),
            settingsStore: settingsStore,
            codexService: RuntimeCodexServiceRecorder(),
            applicationSupportURL: FileManager.default.temporaryDirectory,
            claudeAuthFetcher: auth,
            claudeCacheLoader: cache
        )

        composition.runtimeCoordinator.start()
        await assertEventually {
            let authFetches = await auth.fetchCount()
            let cacheLoads = await cache.loadCount()
            return authFetches == 1
                && cacheLoads == 1
                && composition.dashboardStore.orderedVisibleProviders
                    == [.codex, .claudeCode]
                && composition.dashboardStore.state(for: .claudeCode)
                    == .notConnected
        }

        await composition.runtimeCoordinator.stopAndWait()
    }

    private func routeAllEvents(
        to runtime: ProviderRuntimeCoordinator
    ) async {
        await runtime.sessionResigned()
        await runtime.sessionBecameActive()
        await runtime.panelOpened()
        await runtime.manualRefresh()
    }

    private func makeSettingsStore(
        enabledProviders: [ProviderID]
    ) throws -> SettingsStore {
        let store = SettingsStore(
            fileURL: URL(
                fileURLWithPath: "/tmp/provider-runtime-\(UUID().uuidString).json"
            ),
            fileStore: RuntimeSettingsFileStore()
        )
        var settings = store.settings
        settings.enabledProviders = enabledProviders
        try store.replace(with: settings).get()
        return store
    }

    private func assertEventually(
        _ condition: @escaping @MainActor @Sendable () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1_000 {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("Condition did not become true", file: file, line: line)
    }

    private func drainTasks() async {
        for _ in 0..<20 { await Task.yield() }
    }
}

private final class RuntimeSettingsFileStore: SettingsFileStoring {
    func read(from url: URL) throws -> Data? { nil }

    func write(
        _ data: Data,
        to url: URL,
        options: Data.WritingOptions
    ) throws {}
}

private actor RuntimeControlledConnector: ProviderConnector {
    nonisolated let providerID: ProviderID

    private struct Run {
        var continuation: CheckedContinuation<Void, Error>?
        var cancellationObserved = false
    }

    private let finishesOnCancellation: Bool
    private var starts = 0
    private var cancellations = 0
    private var runs: [Run] = []

    init(
        providerID: ProviderID,
        finishesOnCancellation: Bool = true
    ) {
        self.providerID = providerID
        self.finishesOnCancellation = finishesOnCancellation
    }

    func run(
        publish: @escaping @Sendable (ProviderPresentationState) async -> Void
    ) async throws {
        let runIndex = runs.count
        starts += 1
        runs.append(Run())
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                runs[runIndex].continuation = continuation
            }
        } onCancel: {
            Task { await self.cancel(runIndex: runIndex) }
        }
    }

    func startCount() -> Int { starts }
    func cancellationCount() -> Int { cancellations }

    func finish() {
        guard let runIndex = runs.firstIndex(where: {
            $0.continuation != nil
        }) else {
            return
        }
        runs[runIndex].continuation?.resume()
        runs[runIndex].continuation = nil
    }

    private func cancel(runIndex: Int) {
        guard runs.indices.contains(runIndex),
              !runs[runIndex].cancellationObserved
        else {
            return
        }
        runs[runIndex].cancellationObserved = true
        cancellations += 1
        guard finishesOnCancellation else { return }
        runs[runIndex].continuation?.resume(throwing: CancellationError())
        runs[runIndex].continuation = nil
    }
}

private actor RuntimeCompletionProbe {
    private var complete = false

    func markComplete() { complete = true }
    func isComplete() -> Bool { complete }
}

private actor RuntimeCodexServiceRecorder: CodexProviderRuntimeServicing {
    private var recordedEvents: [String] = []

    func start(sessionGeneration: UInt64) {
        recordedEvents.append("start:\(sessionGeneration)")
    }

    func stop() {
        recordedEvents.append("stop")
    }

    func sessionResigned() {
        recordedEvents.append("resign")
    }

    func sessionBecameActive() {
        recordedEvents.append("active")
    }

    func trigger(_ trigger: RefreshTrigger) {
        recordedEvents.append("trigger:\(trigger)")
    }

    func events() -> [String] { recordedEvents }
    func startCount() -> Int {
        recordedEvents.count { $0.hasPrefix("start:") }
    }
    func stopCount() -> Int {
        recordedEvents.count { $0 == "stop" }
    }
}

@MainActor
private final class RuntimeGooglePresenceReader:
    LocalApplicationPresenceReading
{
    private(set) var readCount = 0

    func presence(
        forBundleIdentifier bundleIdentifier: String
    ) -> LocalApplicationPresence {
        readCount += 1
        return LocalApplicationPresence(installed: false, running: false)
    }
}

private actor RuntimeKimiPresenceReader: LocalCommandPresenceReading {
    private var reads = 0

    func isCommandAvailable(named command: String) -> Bool {
        reads += 1
        return false
    }

    func readCount() -> Int { reads }
}

private actor RuntimeClaudeAuthFetcher: ClaudeAuthStatusFetching {
    private var fetches = 0

    func fetch() -> ClaudeAuthState {
        fetches += 1
        return .notConnected
    }

    func fetchCount() -> Int { fetches }
}

private actor RuntimeClaudeCacheLoader: ClaudeStatusLineCacheLoading {
    private var loads = 0

    func load() -> ClaudeStatusLineSnapshot? {
        loads += 1
        return nil
    }

    func loadCount() -> Int { loads }
}
