#if DEBUG
import Foundation
import Observation

enum DebugThemePreviewState: String, CaseIterable, Hashable, Sendable {
    case loading
    case fresh
    case partial
    case stale
    case unsupported
    case error

    var themeAvailabilityState: ThemeAvailabilityState {
        switch self {
        case .loading: .loading
        case .fresh: .fresh
        case .partial: .partial
        case .stale: .stale
        case .unsupported: .unsupported
        case .error: .unavailable
        }
    }
}

struct DebugThemeStatePreview: Identifiable, Equatable, Sendable {
    var id: String { "\(themeID):\(state.rawValue)" }

    let themeID: String
    let state: DebugThemePreviewState
}

enum DebugThemeStatePreviewMatrix {
    static let themeIDs = BuiltInThemeID.allCases.map(\.rawValue)

    static let all = themeIDs.flatMap { themeID in
        DebugThemePreviewState.allCases.map { state in
            DebugThemeStatePreview(themeID: themeID, state: state)
        }
    }
}

@MainActor
@Observable
final class DebugUITestProbe: AppLifecycleRuntimeInstrumenting {
    private(set) var loginRegisterCount = 0
    private(set) var loginUnregisterCount = 0
    private(set) var fakeRefreshCount = 0
    private(set) var fakeSystemSettingsOpenerRequestCount = 0
    private(set) var productionSystemSettingsOpenerCount = 0
    private(set) var productionConnectionCount = 0
    private(set) var productionProcessCount = 0
    private(set) var ownerIdentities: [
        AppLifecycleOwnerKind: Set<ObjectIdentifier>
    ] = [:]

    func recordOwner(
        _ kind: AppLifecycleOwnerKind,
        identity: ObjectIdentifier
    ) {
        ownerIdentities[kind, default: []].insert(identity)
    }

    func ownerCount(_ kind: AppLifecycleOwnerKind) -> Int {
        ownerIdentities[kind]?.count ?? 0
    }

    func recordLoginRegister() {
        loginRegisterCount += 1
    }

    func recordLoginUnregister() {
        loginUnregisterCount += 1
    }

    func recordFakeRefresh() {
        fakeRefreshCount += 1
    }

    func recordFakeSystemSettingsOpenerRequest() {
        fakeSystemSettingsOpenerRequestCount += 1
    }

    func recordProductionSystemSettingsOpener() {
        productionSystemSettingsOpenerCount += 1
    }

    func recordProductionConnectionAndProcess() {
        productionConnectionCount += 1
        productionProcessCount += 1
    }
}

@MainActor
enum DebugUITestRuntimeFactory {
    nonisolated private static let now = Date(
        timeIntervalSince1970: 1_800_000_000
    )
    private static var probesBySession: [UUID: DebugUITestProbe] = [:]
    private static weak var activeProbe: DebugUITestProbe?

    @discardableResult
    static func prepareProbe(for launch: DebugUITestLaunch) -> DebugUITestProbe {
        if let existing = probesBySession[launch.sessionID] {
            activeProbe = existing
            return existing
        }
        let probe = DebugUITestProbe()
        probesBySession[launch.sessionID] = probe
        activeProbe = probe
        return probe
    }

    static func probe(for sessionID: UUID) -> DebugUITestProbe? {
        probesBySession[sessionID]
    }

    static func recordForbiddenProductionConnectionAndProcess() {
        activeProbe?.recordProductionConnectionAndProcess()
    }

    static func recordForbiddenProductionSystemSettingsOpener() {
        activeProbe?.recordProductionSystemSettingsOpener()
    }

    static func make(launch: DebugUITestLaunch) -> AppLifecycleRuntime {
        let probe = prepareProbe(for: launch)
        let catalog = makeCatalog(now: now)
        let usage = makeUsageSnapshot()
        let states = capabilityStates(
            preset: launch.preset,
            catalog: catalog,
            usage: usage
        )
        let quotaStore = QuotaStore(
            debugRateState: states.rate,
            debugUsageState: states.usage,
            rateLastSuccessAt: states.rateLastSuccessAt,
            usageLastSuccessAt: states.usageLastSuccessAt
        )
        let settingsStore = makeSettingsStore(
            launch: launch,
            availableWindows: catalog.selectedBucket.windows
        )
        let providerDashboardStore = makeProviderDashboardStore(
            enabledProviders: settingsStore.settings.enabledProviders,
            codexState: CodexProviderSnapshotMapper.map(
                rateState: states.rate,
                usageState: states.usage,
                accountState: .unsupported
            )
        )
        let loginItemService = DebugLoginItemService(
            status: launch.preset == .firstOnboarding
                || launch.preset == .onboardingUnchecked
                ? .notRegistered
                : .enabled,
            probe: probe
        )
        let refreshCoordinator = DebugRefreshLifecycleCoordinator(probe: probe)

        return AppLifecycleRuntime(
            viewModel: QuotaViewModel(
                store: quotaStore,
                requestManualRefresh: {
                    Task {
                        await refreshCoordinator.recordManualRefresh()
                    }
                },
                now: { now }
            ),
            initialRateState: quotaStore.rateState,
            quotaStore: quotaStore,
            providerDashboardStore: providerDashboardStore,
            settingsStore: settingsStore,
            refreshCoordinator: refreshCoordinator,
            loginItemService: loginItemService,
            settingsDependencies: SettingsRuntimeDependencies(
                localizationModel: AppLocalizationRuntimeModel(
                    language: settingsStore.settings.language,
                    systemLocale: .current
                ),
                themeService: DebugThemeSettingsService(),
                installedVersionProvider:
                    DebugInstalledCodexVersionProvider(),
                diagnosticsCopier: DebugDiagnosticsCopier(),
                loginItemSettingsOpener:
                    DebugLoginItemSettingsOpener(probe: probe),
                claudeRelayService: makeClaudeRelayService(
                    preset: launch.preset
                )
            ),
            instrumentation: probe
        )
    }

    private static func capabilityStates(
        preset: DebugUITestPreset,
        catalog: RateLimitCatalog,
        usage: TokenActivitySnapshot
    ) -> (
        rate: CapabilityState<RateLimitCatalog>,
        usage: CapabilityState<TokenActivitySnapshot>,
        rateLastSuccessAt: Date?,
        usageLastSuccessAt: Date?
    ) {
        let staleDate = now.addingTimeInterval(-1_800)
        switch preset {
        case .rateSupportedUsageUnsupported:
            return (.fresh(catalog, now), .unsupported, now, nil)
        case .rateUnsupportedUsageSupported:
            return (.unsupported, .fresh(usage, now), nil, now)
        case .stale:
            return (
                .stale(catalog, staleDate, .stale),
                .stale(usage, staleDate, .stale),
                staleDate,
                staleDate
            )
        case .invalid:
            return (
                .unavailable(.invalidSchema),
                .unavailable(.invalidSchema),
                nil,
                nil
            )
        case .firstOnboarding, .onboardingUnchecked, .statusPanel,
             .claudeEnabled,
             .settingsSingleton, .legacyRelayInstalled,
             .legacyRelayManualRecovery, .legacyRelayInvalid,
             .panelRecovery, .manualSelection, .quit,
             .retiredManualSelection, .themeStatePreviews:
            return (.fresh(catalog, now), .fresh(usage, now), now, now)
        }
    }

    private static func makeSettingsStore(
        launch: DebugUITestLaunch,
        availableWindows: [RateLimitWindow]
    ) -> SettingsStore {
        let fileStore = DebugMemorySettingsFileStore()
        let fileURL = URL(fileURLWithPath: "/debug-ui-tests")
            .appendingPathComponent(launch.sessionID.uuidString)
            .appendingPathComponent("settings.json")
        let store = SettingsStore(
            fileURL: fileURL,
            fileStore: fileStore,
            now: { now }
        )
        var settings = AppSettings.defaults
        settings.onboardingCompleted = launch.preset != .firstOnboarding
            && launch.preset != .onboardingUnchecked

        switch launch.preset {
        case .claudeEnabled:
            settings.enabledProviders = [.codex, .claudeCode]
        case .manualSelection:
            settings.menuBarMode = .manual(
                Array(availableWindows.prefix(2)).map(\.identity)
            )
        case .retiredManualSelection:
            settings.menuBarMode = .manual([
                WindowIdentity(
                    bucketKey: "codex",
                    sourceSlot: .primary,
                    durationMinutes: 360
                ),
            ])
        case .themeStatePreviews:
            settings.appearance = AppearanceSettings(
                themeID: "morandi",
                colorScheme: "dark",
                density: "comfortable"
            )
        case .firstOnboarding, .onboardingUnchecked, .statusPanel,
             .settingsSingleton, .legacyRelayInstalled,
             .legacyRelayManualRecovery, .legacyRelayInvalid,
             .panelRecovery, .quit, .rateSupportedUsageUnsupported,
             .rateUnsupportedUsageSupported, .stale, .invalid:
            break
        }

        if case .failure = store.replace(with: settings) {
            preconditionFailure("Debug UI test settings must be valid.")
        }
        if launch.preset == .retiredManualSelection {
            if case .failure = store.reconcileAvailableWindows(
                availableWindows.map(\.identity)
            ) {
                preconditionFailure(
                    "Debug retired selection must reconcile in memory."
                )
            }
        }
        return store
    }

    private static func makeProviderDashboardStore(
        enabledProviders: [ProviderID],
        codexState: ProviderPresentationState
    ) -> ProviderDashboardStore {
        precondition(
            enabledProviders == [.codex]
                || enabledProviders == [.codex, .claudeCode],
            "Debug UI fixtures must preserve the selectable-provider contract."
        )
        let store = ProviderDashboardStore()
        let generation = store.activate(.codex)
        precondition(
            store.apply(codexState, for: generation),
            "Debug Codex state must match its active generation."
        )
        if enabledProviders.contains(.claudeCode) {
            let metricKey = ProviderMetricKey(
                providerID: .claudeCode,
                stableID: "five_hour"
            )!
            let metric = ProviderMetric(
                providerID: .claudeCode,
                metricKey: metricKey,
                remainingFraction: 0.64,
                resetAt: now.addingTimeInterval(7_200),
                durationMinutes: 300
            )!
            let snapshot = ProviderSnapshot(
                providerID: .claudeCode,
                metrics: [metric],
                capturedAt: now,
                accountSummary: ProviderAccountSummary(maskedIdentity: nil)
            )!
            let claudeGeneration = store.activate(.claudeCode)
            precondition(
                store.apply(.fresh(snapshot), for: claudeGeneration),
                "Debug Claude state must match its active generation."
            )
        }
        store.reconcileOrder(enabledProviders)
        return store
    }

    private static func makeClaudeRelayService(
        preset: DebugUITestPreset
    ) -> DebugClaudeRelaySettingsService {
        let state: ClaudeRelaySettingsState = switch preset {
        case .claudeEnabled:
            .notInstalled
        case .legacyRelayInstalled:
            .installed
        case .legacyRelayManualRecovery:
            .manualRecovery
        case .legacyRelayInvalid:
            .invalidSettings
        default:
            .unavailable
        }
        return DebugClaudeRelaySettingsService(state: state)
    }

    private static func makeCatalog(now: Date) -> RateLimitCatalog {
        let windows = [
            try! RateLimitWindow(
                identity: WindowIdentity(
                    bucketKey: "codex",
                    sourceSlot: .primary,
                    durationMinutes: 300
                ),
                usedPercent: 28,
                resetsAt: Int64(now.addingTimeInterval(7_200).timeIntervalSince1970)
            ),
            try! RateLimitWindow(
                identity: WindowIdentity(
                    bucketKey: "codex",
                    sourceSlot: .secondary,
                    durationMinutes: 10_080
                ),
                usedPercent: 20,
                resetsAt: Int64(now.addingTimeInterval(345_600).timeIntervalSince1970)
            ),
            try! RateLimitWindow(
                identity: WindowIdentity(
                    bucketKey: "codex",
                    sourceSlot: .primary,
                    durationMinutes: 1_440
                ),
                usedPercent: 35,
                resetsAt: Int64(now.addingTimeInterval(43_200).timeIntervalSince1970)
            ),
        ]
        return RateLimitCatalog(
            rateLimitsByLimitId: [
                "codex": RateLimitBucket(
                    bucketKey: "codex",
                    limitName: "Codex",
                    planType: .plus,
                    windows: windows
                ),
            ],
            legacyBucket: RateLimitBucket(
                bucketKey: RateLimitCatalog.legacyBucketKey,
                windows: []
            )
        )
    }

    private static func makeUsageSnapshot() -> TokenActivitySnapshot {
        TokenActivitySnapshot(
            rawResponse: GetAccountTokenUsageRawResponse(
                summary: AccountTokenUsageSummaryRaw(
                    lifetimeTokens: 1_250_000,
                    peakDailyTokens: 84_000,
                    longestRunningTurnSec: 420,
                    currentStreakDays: 7,
                    longestStreakDays: 21
                ),
                dailyUsageBuckets: [
                    AccountTokenUsageDayRaw(
                        startDate: "2027-01-15",
                        tokens: 42_000
                    ),
                ]
            )
        )
    }
}

final class DebugMemorySettingsFileStore: SettingsFileStoring {
    private var values: [URL: Data] = [:]

    func read(from url: URL) throws -> Data? {
        values[url]
    }

    func write(
        _ data: Data,
        to url: URL,
        options: Data.WritingOptions
    ) throws {
        values[url] = data
    }
}

@MainActor
final class DebugClaudeRelaySettingsService: ClaudeRelaySettingsServicing {
    private var state: ClaudeRelaySettingsState

    init(state: ClaudeRelaySettingsState) {
        self.state = state
    }

    func inspect() async -> ClaudeRelaySettingsState {
        state
    }

    func install() async -> ClaudeRelaySettingsState {
        guard state == .notInstalled else {
            return .unavailable
        }
        state = .installed
        return state
    }

    func remove() async -> ClaudeRelaySettingsState {
        if state == .installed {
            state = .notInstalled
        }
        return state
    }
}

actor DebugLoginItemService: LoginItemServicing {
    private var currentStatus: LoginItemStatus
    private let probe: DebugUITestProbe

    init(status: LoginItemStatus, probe: DebugUITestProbe) {
        currentStatus = status
        self.probe = probe
    }

    func status() async -> LoginItemStatus {
        currentStatus
    }

    func register() async throws {
        await probe.recordLoginRegister()
        currentStatus = .enabled
    }

    func unregister() async throws {
        await probe.recordLoginUnregister()
        currentStatus = .notRegistered
    }
}

actor DebugRefreshLifecycleCoordinator: RefreshLifecycleCoordinating {
    private let probe: DebugUITestProbe

    init(probe: DebugUITestProbe) {
        self.probe = probe
    }

    func start(sessionGeneration: UInt64) async {
        await probe.recordFakeRefresh()
    }
    func sessionResigned() async {}
    func sessionBecameActive() async {
        await probe.recordFakeRefresh()
    }
    func panelOpened() async {}
    func stop() async {}

    func recordManualRefresh() async {
        await probe.recordFakeRefresh()
    }
}

@MainActor
final class DebugThemeSettingsService: ThemeSettingsServicing {
    private var selectedThemeID = "morandi"

    func snapshot() -> ThemeSettingsSnapshot {
        ThemeSettingsSnapshot(
            choices: ThemeSettingsSnapshot.placeholder.choices,
            selectedThemeID: selectedThemeID,
            allowsSelection: true,
            allowsReset: true,
            allowsImport: false,
            allowsExport: false,
            allowsCustomEditor: false,
            allowsColorScheme: true,
            allowsDensity: true,
            accessibilityFallbacksActive: false
        )
    }

    func selectTheme(id: String) throws {
        selectedThemeID = id
    }

    func resetTheme() throws {
        selectedThemeID = "morandi"
    }

    func importTheme() throws {}
    func exportTheme() throws {}
}

struct DebugInstalledCodexVersionProvider: InstalledCodexVersionProviding {
    func installedVersion() async -> String {
        "0.0-ui-fixture"
    }
}

@MainActor
final class DebugDiagnosticsCopier: DiagnosticsCopying {
    private(set) var copiedValues: [String] = []

    func copy(_ text: String) {
        copiedValues.append(text)
    }
}

@MainActor
final class DebugLoginItemSettingsOpener: LoginItemSettingsOpening {
    private(set) var openCount = 0
    private let probe: DebugUITestProbe

    init(probe: DebugUITestProbe) {
        self.probe = probe
    }

    func open() {
        openCount += 1
        probe.recordFakeSystemSettingsOpenerRequest()
    }
}
#endif
