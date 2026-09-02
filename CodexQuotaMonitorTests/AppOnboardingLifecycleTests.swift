import Foundation
import XCTest
@testable import CodexQuotaMonitor

@MainActor
final class AppOnboardingLifecycleTests: XCTestCase {
    func testTrustedFreshLaunchCreatesStatusBeforeExactlyOneOnboarding() {
        let harness = OnboardingLifecycleHarness()

        harness.coordinator.start()
        harness.coordinator.start()

        XCTAssertEqual(harness.events, ["status-configure", "onboarding-factory", "onboarding-show"])
        XCTAssertEqual(harness.onboardingFactoryCount, 1)
        XCTAssertEqual(harness.onboarding.showCount, 1)
        XCTAssertEqual(harness.status.configureCount, 1)
        XCTAssertEqual(harness.loginService.statusCallCount, 0)
    }

    func testCompletedSettingsSuppressOnboarding() throws {
        let harness = OnboardingLifecycleHarness()
        var settings = harness.settingsStore.settings
        settings.onboardingCompleted = true
        try harness.settingsStore.replace(with: settings).get()

        harness.coordinator.start()

        XCTAssertEqual(harness.onboardingFactoryCount, 0)
        XCTAssertEqual(harness.onboarding.showCount, 0)
        XCTAssertEqual(harness.status.configureCount, 1)
    }

    func testUsingDefaultsRecoveryIsUntrustedAndSuppressesOnboarding() {
        let files = LifecycleSettingsFiles()
        files.data[OnboardingLifecycleHarness.fileURL] = Data("corrupt".utf8)
        let harness = OnboardingLifecycleHarness(files: files)
        XCTAssertEqual(harness.settingsStore.recoveryState, .usingDefaults(.invalidData))

        harness.coordinator.start()

        XCTAssertEqual(harness.onboardingFactoryCount, 0)
        XCTAssertEqual(harness.onboarding.showCount, 0)
        XCTAssertEqual(harness.loginService.statusCallCount, 0)
    }

    func testFixtureRuntimeWithoutSettingsOrServiceSuppressesOnboarding() {
        let harness = OnboardingLifecycleHarness(includeProductionDependencies: false)

        harness.coordinator.start()

        XCTAssertEqual(harness.onboardingFactoryCount, 0)
        XCTAssertEqual(harness.onboarding.showCount, 0)
        XCTAssertEqual(harness.loginService.statusCallCount, 0)
    }

    func testPendingReopenShowsSameOnboardingThenResolvedReopenShowsPanel()
        async throws
    {
        let harness = OnboardingLifecycleHarness()
        harness.coordinator.start()

        harness.coordinator.reopen()

        XCTAssertEqual(harness.onboardingFactoryCount, 1)
        XCTAssertEqual(harness.onboarding.showCount, 2)
        XCTAssertEqual(harness.panel.showCount, 0)

        let controller = try XCTUnwrap(harness.onboardingController)
        await controller.load()
        let didCancel = await controller.cancel()
        XCTAssertTrue(didCancel)
        XCTAssertEqual(
            harness.onboarding.hideCount,
            0,
            "Resolved onboarding must keep its one-time result visible until the user closes it"
        )
        harness.coordinator.reopen()

        XCTAssertEqual(harness.onboarding.hideCount, 0)
        XCTAssertEqual(harness.onboarding.showCount, 2)
        XCTAssertEqual(harness.panel.showCount, 1)
    }

    func testCoordinatorInjectsLoginSettingsOpenerIntoOnboardingController()
        async throws
    {
        let harness = OnboardingLifecycleHarness(registrationFails: true)
        harness.coordinator.start()
        let controller = try XCTUnwrap(harness.onboardingController)
        await controller.load()

        XCTAssertTrue(controller.continueFromProviderSelection())
        XCTAssertTrue(controller.continueFromConnectionReview())
        await controller.finish()
        XCTAssertEqual(controller.state, .failed(.registration))

        controller.openLoginItemSystemSettings()
        XCTAssertEqual(harness.loginItemSettingsOpener.openCount, 1)
    }

    func testSettingsRuntimeDependenciesDefaultToUnavailableClaudeRelay() {
        let dependencies = makeSettingsRuntimeDependencies()

        XCTAssertTrue(
            dependencies.claudeRelayService
                is UnavailableClaudeRelaySettingsService
        )
    }

    func testSettingsRuntimeDependenciesDefaultToUnavailableProviderLinkOpener() {
        let dependencies = makeSettingsRuntimeDependencies()

        XCTAssertTrue(
            dependencies.providerLinkOpener
                is UnavailableProviderExternalLinkOpener
        )
    }

    func testSettingsViewModelDefaultsToUnavailableProviderLinkOpener() {
        let files = LifecycleSettingsFiles()
        let viewModel = SettingsViewModel(
            settingsStore: SettingsStore(
                fileURL: URL(
                    fileURLWithPath:
                        "/virtual/lifecycle-onboarding/default-provider-link.json"
                ),
                fileStore: files
            ),
            quotaStore: QuotaStore(),
            loginItemService: LifecycleLoginItemService(),
            themeService: PlaceholderThemeSettingsService(),
            installedVersionProvider:
                UnavailableInstalledCodexVersionProvider(),
            diagnosticsCopier: LifecycleOnboardingDiagnosticsCopier(),
            requestRefresh: {},
            appVersion: "test"
        )

        XCTAssertTrue(
            reflectedProviderLinkOpener(in: viewModel)
                is UnavailableProviderExternalLinkOpener
        )
    }

    func testAppDelegateInspectsRelayWithoutInstallingForEnabledClaude()
        async throws
    {
        let relay = LifecycleClaudeRelaySettingsService()
        let dependencies = makeSettingsRuntimeDependencies(
            claudeRelayService: relay
        )
        let files = LifecycleSettingsFiles()
        let settingsStore = SettingsStore(
            fileURL: URL(
                fileURLWithPath: "/virtual/lifecycle-onboarding/injected.json"
            ),
            fileStore: files
        )
        var settings = settingsStore.settings
        settings.enabledProviders = [.claudeCode]
        try settingsStore.replace(with: settings).get()
        let quotaStore = QuotaStore()
        let runtime = AppLifecycleRuntime(
            viewModel: QuotaViewModel(store: quotaStore),
            initialRateState: quotaStore.rateState,
            quotaStore: quotaStore,
            settingsStore: settingsStore,
            refreshCoordinator: nil,
            loginItemService: LifecycleLoginItemService(),
            settingsDependencies: dependencies
        )

        let viewModel = try XCTUnwrap(
            AppDelegate.makeSettingsViewModel(
                runtime: runtime,
                appVersion: "test"
            )
        )
        await viewModel.reloadLiveState()

        XCTAssertEqual(relay.inspectCount, 1)
        XCTAssertEqual(
            viewModel.presentation.general.providers.rows.map(\.providerID),
            [.codex, .claudeCode]
        )
        XCTAssertEqual(
            viewModel.presentation.general.providers.rows.map(\.isEnabled),
            [true, true]
        )
        XCTAssertEqual(
            viewModel.presentation.general.providers.claudeRelay.state,
            .notInstalled
        )
        XCTAssertFalse(
            viewModel.presentation.general.providers.claudeRelay
                .showsMaintenance
        )
    }

    func testAppDelegateSettingsViewModelUsesInjectedProviderLinkOpener()
        throws
    {
        let linkOpener = LifecycleProviderExternalLinkOpener()
        let dependencies = SettingsRuntimeDependencies(
            localizationModel: AppLocalizationRuntimeModel(),
            themeService: PlaceholderThemeSettingsService(),
            installedVersionProvider:
                UnavailableInstalledCodexVersionProvider(),
            diagnosticsCopier: LifecycleOnboardingDiagnosticsCopier(),
            loginItemSettingsOpener: LifecycleLoginItemSettingsOpener(),
            providerLinkOpener: linkOpener
        )
        let files = LifecycleSettingsFiles()
        let settingsStore = SettingsStore(
            fileURL: URL(
                fileURLWithPath: "/virtual/lifecycle-onboarding/provider-link.json"
            ),
            fileStore: files
        )
        let quotaStore = QuotaStore()
        let runtime = AppLifecycleRuntime(
            viewModel: QuotaViewModel(store: quotaStore),
            initialRateState: quotaStore.rateState,
            quotaStore: quotaStore,
            settingsStore: settingsStore,
            refreshCoordinator: nil,
            loginItemService: LifecycleLoginItemService(),
            settingsDependencies: dependencies
        )
        let viewModel = try XCTUnwrap(
            AppDelegate.makeSettingsViewModel(
                runtime: runtime,
                appVersion: "test"
            )
        )
        guard let routedOpener = reflectedProviderLinkOpener(
            in: viewModel
        ), (routedOpener as AnyObject) === linkOpener else {
            return XCTFail("Settings view model did not retain the injected opener")
        }
        let allowed = try XCTUnwrap(
            viewModel.presentation.general.providers.rows
                .first { $0.providerID == .codex }?.links.first
        )

        viewModel.openProviderLink(allowed)

        XCTAssertEqual(linkOpener.openedURLs, [allowed.url])
    }

    func testDebugUITestSettingsProviderLinksUseUnavailableOpener() throws {
        let runtime = DebugUITestRuntimeFactory.make(
            launch: DebugUITestLaunch(
                preset: .settingsSingleton,
                sessionID: UUID()
            )
        )
        let dependencies = try XCTUnwrap(runtime.settingsDependencies)
        guard dependencies.providerLinkOpener
                is UnavailableProviderExternalLinkOpener
        else {
            return XCTFail("UI fixtures must use the unavailable link opener")
        }
        let viewModel = try XCTUnwrap(
            AppDelegate.makeSettingsViewModel(
                runtime: runtime,
                appVersion: "test"
            )
        )
        guard let routedOpener = reflectedProviderLinkOpener(
            in: viewModel
        ), (routedOpener as AnyObject)
            === (dependencies.providerLinkOpener as AnyObject)
        else {
            return XCTFail("UI fixture settings did not retain its safe opener")
        }
        let allowed = try XCTUnwrap(
            viewModel.presentation.general.providers.rows
                .first { $0.providerID == .codex }?.links.first
        )

        viewModel.openProviderLink(allowed)
    }

    func testTerminationHidesPendingOnboardingAndNeverMutatesLoginItem() async {
        let harness = OnboardingLifecycleHarness()
        harness.coordinator.start()
        var replies = 0

        harness.coordinator.terminate {
            replies += 1
        }

        XCTAssertEqual(harness.onboarding.hideCount, 1)
        XCTAssertEqual(harness.loginService.statusCallCount, 0)
        XCTAssertEqual(harness.loginService.registerCount, 0)
        XCTAssertEqual(harness.loginService.unregisterCount, 0)
        await assertEventually { replies == 1 }
    }

    func testMigratedAndRecoveredSettingsRemainTrustedForOnboarding() throws {
        let legacyFiles = LifecycleSettingsFiles()
        legacyFiles.data[OnboardingLifecycleHarness.fileURL] = try JSONEncoder().encode(
            LifecycleLegacySettingsV1()
        )
        let migrated = OnboardingLifecycleHarness(files: legacyFiles)
        XCTAssertEqual(migrated.settingsStore.recoveryState, .migrated(fromVersion: 1))
        migrated.coordinator.start()
        XCTAssertEqual(migrated.onboardingFactoryCount, 1)

        let recoveredFiles = LifecycleSettingsFiles()
        let seed = OnboardingLifecycleHarness(files: recoveredFiles)
        try seed.settingsStore.replace(with: .defaults).get()
        var second = seed.settingsStore.settings
        second.language = .english
        try seed.settingsStore.replace(with: second).get()
        recoveredFiles.data[OnboardingLifecycleHarness.fileURL] = Data("corrupt".utf8)
        let recovered = OnboardingLifecycleHarness(files: recoveredFiles)
        guard case .recoveredFromBackup = recovered.settingsStore.recoveryState else {
            return XCTFail("Expected backup recovery")
        }
        recovered.coordinator.start()
        XCTAssertEqual(recovered.onboardingFactoryCount, 1)
    }

    private func assertEventually(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<1_000 {
            if condition() {
                return
            }
            await Task.yield()
        }
        XCTFail("Condition did not become true", file: file, line: line)
    }

    private func reflectedProviderLinkOpener(
        in viewModel: SettingsViewModel
    ) -> (any ProviderExternalLinkOpening)? {
        Mirror(reflecting: viewModel).children
            .first { $0.label == "providerLinkOpener" }?.value
            as? any ProviderExternalLinkOpening
    }

    private func makeSettingsRuntimeDependencies(
        claudeRelayService: (any ClaudeRelaySettingsServicing)? = nil
    ) -> SettingsRuntimeDependencies {
        if let claudeRelayService {
            return SettingsRuntimeDependencies(
                localizationModel: AppLocalizationRuntimeModel(),
                themeService: PlaceholderThemeSettingsService(),
                installedVersionProvider:
                    UnavailableInstalledCodexVersionProvider(),
                diagnosticsCopier: LifecycleOnboardingDiagnosticsCopier(),
                loginItemSettingsOpener: LifecycleLoginItemSettingsOpener(),
                claudeRelayService: claudeRelayService
            )
        }
        return SettingsRuntimeDependencies(
            localizationModel: AppLocalizationRuntimeModel(),
            themeService: PlaceholderThemeSettingsService(),
            installedVersionProvider:
                UnavailableInstalledCodexVersionProvider(),
            diagnosticsCopier: LifecycleOnboardingDiagnosticsCopier(),
            loginItemSettingsOpener: LifecycleLoginItemSettingsOpener()
        )
    }
}

@MainActor
private final class OnboardingLifecycleHarness {
    static let fileURL = URL(fileURLWithPath: "/virtual/lifecycle-onboarding/settings.json")

    let quotaStore = QuotaStore()
    let settingsStore: SettingsStore
    let loginService: LifecycleLoginItemService
    let loginItemSettingsOpener = LifecycleLoginItemSettingsOpener()
    let panel = LifecycleOnboardingPanel()
    let status = LifecycleOnboardingStatus()
    let onboarding = FakeOnboardingSurface()
    let monitor = LifecycleOnboardingMonitor()
    var events: [String] = []
    private(set) var onboardingFactoryCount = 0
    private(set) var onboardingController: OnboardingController?

    private let includeProductionDependencies: Bool

    init(
        files: LifecycleSettingsFiles = LifecycleSettingsFiles(),
        includeProductionDependencies: Bool = true,
        registrationFails: Bool = false
    ) {
        loginService = LifecycleLoginItemService(
            registrationFails: registrationFails
        )
        settingsStore = SettingsStore(
            fileURL: Self.fileURL,
            fileStore: files
        )
        self.includeProductionDependencies = includeProductionDependencies
    }

    lazy var coordinator = AppLifecycleCoordinator(
        runtimeFactory: { [unowned self] in
            AppLifecycleRuntime(
                viewModel: QuotaViewModel(store: quotaStore),
                initialRateState: quotaStore.rateState,
                quotaStore: quotaStore,
                settingsStore: includeProductionDependencies ? settingsStore : nil,
                refreshCoordinator: nil,
                loginItemService: includeProductionDependencies ? loginService : nil,
                settingsDependencies: includeProductionDependencies
                    ? SettingsRuntimeDependencies(
                        localizationModel: AppLocalizationRuntimeModel(),
                        themeService: PlaceholderThemeSettingsService(),
                        installedVersionProvider:
                            UnavailableInstalledCodexVersionProvider(),
                        diagnosticsCopier:
                            LifecycleOnboardingDiagnosticsCopier(),
                        loginItemSettingsOpener: loginItemSettingsOpener
                    )
                    : nil
            )
        },
        panelFactory: { [unowned self] _, _, _, _, _ in panel },
        statusControllerFactory: { [unowned self] installedPanel, actions in
            status.panel = installedPanel
            status.actions = actions
            status.onConfigure = { [weak self] in
                self?.events.append("status-configure")
            }
            return status
        },
        settingsPresenterFactory: { _ in
            LifecycleOnboardingSettingsPresenter()
        },
        lifecycleMonitorFactory: { [unowned self] callbacks in
            monitor.callbacks = callbacks
            return monitor
        },
        onboardingFactory: { [unowned self] controller in
            onboardingFactoryCount += 1
            events.append("onboarding-factory")
            onboardingController = controller
            onboarding.controller = controller
            onboarding.onShow = { [weak self] in
                self?.events.append("onboarding-show")
            }
            return onboarding
        },
        requestQuit: {}
    )
}

@MainActor
private final class LifecycleLoginItemService: LoginItemServicing {
    private(set) var statusCallCount = 0
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    private let registrationFails: Bool

    init(registrationFails: Bool = false) {
        self.registrationFails = registrationFails
    }

    func status() async -> LoginItemStatus {
        statusCallCount += 1
        return .notRegistered
    }

    func register() async throws {
        registerCount += 1
        if registrationFails {
            throw LifecycleLoginItemFailure.registration
        }
    }

    func unregister() async throws {
        unregisterCount += 1
    }
}

@MainActor
private final class FakeOnboardingSurface: OnboardingSurfacePresenting {
    weak var controller: OnboardingController?
    var isPending: Bool { controller?.isPending ?? true }
    private(set) var showCount = 0
    private(set) var hideCount = 0
    var onShow: (() -> Void)?

    func show() {
        showCount += 1
        onShow?()
    }

    func hide() {
        hideCount += 1
    }

}

private enum LifecycleLoginItemFailure: Error {
    case registration
}

@MainActor
private final class LifecycleLoginItemSettingsOpener:
    LoginItemSettingsOpening
{
    private(set) var openCount = 0

    func open() {
        openCount += 1
    }
}

@MainActor
private final class LifecycleOnboardingDiagnosticsCopier: DiagnosticsCopying {
    func copy(_ text: String) {}
}

@MainActor
private final class LifecycleProviderExternalLinkOpener:
    ProviderExternalLinkOpening
{
    private(set) var openedURLs: [URL] = []

    func open(_ url: URL) {
        openedURLs.append(url)
    }
}

@MainActor
private final class LifecycleClaudeRelaySettingsService:
    ClaudeRelaySettingsServicing
{
    private(set) var inspectCount = 0

    func inspect() async -> ClaudeRelaySettingsState {
        inspectCount += 1
        return .notInstalled
    }

    func install() async -> ClaudeRelaySettingsState { .installed }
    func remove() async -> ClaudeRelaySettingsState { .notInstalled }
}

@MainActor
private final class LifecycleOnboardingPanel: LifecyclePanelPresenting {
    private(set) var isVisible = false
    var isOnActiveSpace = true
    private(set) var showCount = 0

    func show() {
        showCount += 1
        isVisible = true
    }

    func hide() {
        isVisible = false
    }

    func persistCurrentFrame() {}
    func clampToScreen() {}
    func setSpacePolicy(_ policy: SpacePolicy) {}
    func setProviderCount(_ count: Int) {}
}

@MainActor
private final class LifecycleOnboardingStatus: StatusSurfaceControlling {
    var panel: (any LifecyclePanelPresenting)?
    var actions: AppLifecycleActions?
    var onConfigure: (() -> Void)?
    private(set) var configureCount = 0

    func configure(initialPresentation: StatusItemPresentation) {
        configureCount += 1
        onConfigure?()
    }

    func updatePresentation(_ presentation: StatusItemPresentation) {}

    func showRecoverySurface() {
        panel?.show()
    }
}

@MainActor
private final class LifecycleOnboardingSettingsPresenter: SettingsSurfacePresenting {
    func showSettings() {}
    func hideSettings() {}
}

@MainActor
private final class LifecycleOnboardingMonitor: SessionLifecycleMonitoring {
    var callbacks = SessionLifecycleCallbacks(
        screenParametersChanged: {},
        effectiveSessionResigned: {},
        effectiveSessionBecameActive: {}
    )

    func start() {}
    func stop() {}
}

private final class LifecycleSettingsFiles: SettingsFileStoring {
    var data: [URL: Data] = [:]

    func read(from url: URL) throws -> Data? {
        data[url]
    }

    func write(
        _ data: Data,
        to url: URL,
        options: Data.WritingOptions
    ) throws {
        self.data[url] = data
    }
}

private struct LifecycleLegacySettingsV1: Encodable {
    let schemaVersion = 1
    let menuBarMode = MenuBarMode.automatic
    let percentageMode = PercentageMode.remaining
    let spacePolicy = SpacePolicy.currentSpace
    let launchAtLoginUserDisabled = false
    let language = AppLanguage.system
    let appearance = AppearanceSettings(
        themeID: "system",
        colorScheme: "system",
        density: "system"
    )
    let panelFrame: PersistedPanelFrame? = nil
}
