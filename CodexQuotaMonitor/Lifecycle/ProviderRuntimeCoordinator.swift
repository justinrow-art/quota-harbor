import Foundation

protocol CodexProviderRuntimeServicing: CodexRefreshCoordinating {
    func sessionResigned() async
    func sessionBecameActive() async
    func trigger(_ trigger: RefreshTrigger) async
}

extension RefreshCoordinator: CodexProviderRuntimeServicing {}

@MainActor
protocol ProviderRuntimeCoordinating: AnyObject, Sendable {
    func start()
    func sessionResigned() async
    func sessionBecameActive() async
    func panelOpened() async
    func manualRefresh() async
    func stopAndWait() async
}

@MainActor
final class ProviderRuntimeCoordinator: ProviderRuntimeCoordinating {
    private let hub: ProviderHub
    private let settingsStore: SettingsStore
    private let codexEvents: any CodexProviderRuntimeServicing
    private var isStarted = false
    private var lifecycleEpoch: UInt64 = 0
    private var stoppingEpoch: UInt64?

    init(
        hub: ProviderHub,
        settingsStore: SettingsStore,
        codexEvents: any CodexProviderRuntimeServicing
    ) {
        self.hub = hub
        self.settingsStore = settingsStore
        self.codexEvents = codexEvents
    }

    func start() {
        guard !isStarted, stoppingEpoch == nil else { return }
        lifecycleEpoch &+= 1
        isStarted = true
        hub.start(settingsStore: settingsStore)
    }

    func sessionResigned() async {
        guard shouldRouteCodexEvents else { return }
        await codexEvents.sessionResigned()
    }

    func sessionBecameActive() async {
        guard shouldRouteCodexEvents else { return }
        await codexEvents.sessionBecameActive()
    }

    func panelOpened() async {
        guard shouldRouteCodexEvents else { return }
        await codexEvents.trigger(.panelOpened)
    }

    func manualRefresh() async {
        guard isStarted else { return }
        let enabledProviders = settingsStore.settings.enabledProviders
        hub.manualRefreshNonCodexProviders(
            enabledProviders: enabledProviders
        )
        guard enabledProviders.contains(.codex) else {
            return
        }
        await codexEvents.trigger(.manual)
    }

    func stopAndWait() async {
        lifecycleEpoch &+= 1
        let epoch = lifecycleEpoch
        isStarted = false
        stoppingEpoch = epoch
        await hub.stopAndWait()
        guard stoppingEpoch == epoch else { return }
        stoppingEpoch = nil
    }

    private var shouldRouteCodexEvents: Bool {
        isStarted
            && settingsStore.settings.enabledProviders.contains(.codex)
    }
}

@MainActor
struct ProductionProviderComposition {
    let dashboardStore: ProviderDashboardStore
    let runtimeCoordinator: ProviderRuntimeCoordinator

    static func make(
        quotaStore: QuotaStore,
        settingsStore: SettingsStore,
        codexService: any CodexProviderRuntimeServicing,
        applicationSupportURL: URL? = nil,
        claudeAuthFetcher: (any ClaudeAuthStatusFetching)? = nil,
        claudeCacheLoader: (any ClaudeStatusLineCacheLoading)? = nil
    ) -> ProductionProviderComposition {
        let applicationSupportURL = applicationSupportURL
            ?? FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(
                    "Library/Application Support",
                    isDirectory: true
                )
        let codexConnector = CodexProviderConnector(
            observationSource: CodexQuotaObservationSource(store: quotaStore),
            lifecycle: CodexConnectorLifecycle(coordinator: codexService)
        )
        let claudeConnector = ClaudeProviderConnector(
            authFetcher: claudeAuthFetcher
                ?? LocatedClaudeAuthStatusFetcher.live(),
            cacheLoader: claudeCacheLoader
                ?? ClaudeStatusLineCacheStore(
                    fileURL: applicationSupportURL
                        .appendingPathComponent(
                            "CodexQuotaMonitor",
                            isDirectory: true
                        )
                        .appendingPathComponent(
                            "claude-statusline-quota.json",
                            isDirectory: false
                        )
                )
        )
        let dashboardStore = ProviderDashboardStore()
        let hub = ProviderHub(
            store: dashboardStore,
            connectors: [codexConnector, claudeConnector]
        )
        let runtimeCoordinator = ProviderRuntimeCoordinator(
            hub: hub,
            settingsStore: settingsStore,
            codexEvents: codexService
        )
        return ProductionProviderComposition(
            dashboardStore: dashboardStore,
            runtimeCoordinator: runtimeCoordinator
        )
    }
}
