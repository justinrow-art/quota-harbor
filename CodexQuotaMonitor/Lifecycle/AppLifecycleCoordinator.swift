import AppKit
import Observation

protocol RefreshLifecycleCoordinating: Sendable {
    func start(sessionGeneration: UInt64) async
    func sessionResigned() async
    func sessionBecameActive() async
    func panelOpened() async
    func stop() async
}

extension RefreshCoordinator: RefreshLifecycleCoordinating {
    func panelOpened() async {
        await trigger(.panelOpened)
    }
}

@MainActor
protocol LifecyclePanelPresenting: RetainedPanelPresenting {
    func persistCurrentFrame()
    func clampToScreen()
    func setSpacePolicy(_ policy: SpacePolicy)
    func setProviderCount(_ count: Int)
}

extension FloatingPanelController: LifecyclePanelPresenting {}

@MainActor
protocol StatusSurfaceControlling: AnyObject {
    func configure(initialPresentation: StatusItemPresentation)
    func updatePresentation(_ presentation: StatusItemPresentation)
    func showRecoverySurface()
}

extension StatusItemController: StatusSurfaceControlling {}

@MainActor
protocol SettingsSurfacePresenting: AnyObject {
    func showSettings()
    func hideSettings()
}

@MainActor
final class UnavailableSettingsSurfacePresenter: SettingsSurfacePresenting {
    func showSettings() {}
    func hideSettings() {}
}

enum AppLifecycleOwnerKind: String, CaseIterable, Equatable, Sendable {
    case panel
    case statusItem
    case settings
}

@MainActor
protocol AppLifecycleRuntimeInstrumenting: AnyObject {
    func recordOwner(
        _ kind: AppLifecycleOwnerKind,
        identity: ObjectIdentifier
    )
}

@MainActor
struct SettingsRuntimeDependencies {
    let localizationModel: AppLocalizationRuntimeModel
    let themeService: any ThemeSettingsServicing
    let themeRuntimeModel: ThemeRuntimeModel?
    let themeEditorPresenter: (any ThemeEditorPresenting)?
    let themeEditorMutations: ThemeEditorMutationRelay?
    let installedVersionProvider: any InstalledCodexVersionProviding
    let diagnosticsCopier: any DiagnosticsCopying
    let loginItemSettingsOpener: any LoginItemSettingsOpening
    let providerLinkOpener: any ProviderExternalLinkOpening
    let claudeRelayService: any ClaudeRelaySettingsServicing

    init(
        localizationModel: AppLocalizationRuntimeModel,
        themeService: any ThemeSettingsServicing,
        themeRuntimeModel: ThemeRuntimeModel? = nil,
        themeEditorPresenter: (any ThemeEditorPresenting)? = nil,
        themeEditorMutations: ThemeEditorMutationRelay? = nil,
        installedVersionProvider: any InstalledCodexVersionProviding,
        diagnosticsCopier: any DiagnosticsCopying,
        loginItemSettingsOpener: any LoginItemSettingsOpening,
        providerLinkOpener: any ProviderExternalLinkOpening =
            UnavailableProviderExternalLinkOpener(),
        claudeRelayService: any ClaudeRelaySettingsServicing =
            UnavailableClaudeRelaySettingsService()
    ) {
        self.localizationModel = localizationModel
        self.themeService = themeService
        self.themeRuntimeModel = themeRuntimeModel
        self.themeEditorPresenter = themeEditorPresenter
        self.themeEditorMutations = themeEditorMutations
        self.installedVersionProvider = installedVersionProvider
        self.diagnosticsCopier = diagnosticsCopier
        self.loginItemSettingsOpener = loginItemSettingsOpener
        self.providerLinkOpener = providerLinkOpener
        self.claudeRelayService = claudeRelayService
    }
}

struct AppLifecycleRuntime {
    let viewModel: QuotaViewModel
    let initialRateState: CapabilityState<RateLimitCatalog>
    let quotaStore: QuotaStore?
    let providerDashboardStore: ProviderDashboardStore?
    let settingsStore: SettingsStore?
    let providerRuntime: (any ProviderRuntimeCoordinating)?
    let refreshCoordinator: (any RefreshLifecycleCoordinating)?
    let loginItemService: (any LoginItemServicing)?
    let settingsDependencies: SettingsRuntimeDependencies?
    let instrumentation: (any AppLifecycleRuntimeInstrumenting)?

    init(
        viewModel: QuotaViewModel,
        initialRateState: CapabilityState<RateLimitCatalog>,
        quotaStore: QuotaStore?,
        providerDashboardStore: ProviderDashboardStore? = nil,
        settingsStore: SettingsStore?,
        providerRuntime: (any ProviderRuntimeCoordinating)? = nil,
        refreshCoordinator: (any RefreshLifecycleCoordinating)?,
        loginItemService: (any LoginItemServicing)? = nil,
        settingsDependencies: SettingsRuntimeDependencies? = nil,
        instrumentation: (any AppLifecycleRuntimeInstrumenting)? = nil
    ) {
        self.viewModel = viewModel
        self.initialRateState = initialRateState
        self.quotaStore = quotaStore
        self.providerDashboardStore = providerDashboardStore
        self.settingsStore = settingsStore
        self.providerRuntime = providerRuntime
        self.refreshCoordinator = refreshCoordinator
        self.loginItemService = loginItemService
        self.settingsDependencies = settingsDependencies
        self.instrumentation = instrumentation
    }
}

struct AppLifecycleActions {
    let refresh: @MainActor () -> Void
    let panelShown: @MainActor () -> Void
    let showSettings: @MainActor () -> Void
    let quit: @MainActor () -> Void
}

@MainActor
final class AppLifecycleCoordinator {
    typealias RuntimeFactory = @MainActor () -> AppLifecycleRuntime
    typealias PanelFactory = @MainActor (
        AppLifecycleRuntime,
        QuotaViewModel,
        @escaping @MainActor (PersistedPanelFrame) -> Void,
        @escaping @MainActor () -> Void,
        @escaping @MainActor () -> Void
    ) -> any LifecyclePanelPresenting
    typealias StatusControllerFactory = @MainActor (
        any LifecyclePanelPresenting,
        AppLifecycleActions
    ) -> any StatusSurfaceControlling
    typealias SettingsPresenterFactory = @MainActor (
        AppLifecycleRuntime
    ) -> any SettingsSurfacePresenting
    typealias LifecycleMonitorFactory = @MainActor (
        SessionLifecycleCallbacks
    ) -> any SessionLifecycleMonitoring
    typealias OnboardingFactory = @MainActor (
        OnboardingController
    ) -> any OnboardingSurfacePresenting

    private enum Phase {
        case new
        case running
        case terminating
        case terminated
    }

    private enum RefreshCommand: Sendable {
        case start(sessionGeneration: UInt64)
        case sessionResigned
        case sessionBecameActive
        case panelOpened
        case manual
    }

    private let runtimeFactory: RuntimeFactory
    private let panelFactory: PanelFactory
    private let statusControllerFactory: StatusControllerFactory
    private let settingsPresenterFactory: SettingsPresenterFactory
    private let lifecycleMonitorFactory: LifecycleMonitorFactory
    private let onboardingFactory: OnboardingFactory?
    private let requestQuit: @MainActor () -> Void

    private var phase = Phase.new
    private var effectiveSessionActive = true
    private var observationGeneration: UInt64 = 0
    private var refreshTaskTail: Task<Void, Never>?
    private var reconciledFreshRateState: CapabilityState<RateLimitCatalog>?

    private var viewModel: QuotaViewModel?
    private var fallbackRateState: CapabilityState<RateLimitCatalog> = .loading
    private var quotaStore: QuotaStore?
    private var providerDashboardStore: ProviderDashboardStore?
    private var settingsStore: SettingsStore?
    private var localizationModel: AppLocalizationRuntimeModel?
    private var themeEditorPresenter: (any ThemeEditorPresenting)?
    private var providerRuntime: (any ProviderRuntimeCoordinating)?
    private var providerRuntimeStarted = false
    private var refreshCoordinator: (any RefreshLifecycleCoordinating)?
    private var panelController: (any LifecyclePanelPresenting)?
    private var lastPanelProviderCount: Int?
    private var statusItemController: (any StatusSurfaceControlling)?
    private var settingsPresenter: (any SettingsSurfacePresenting)?
    private var lifecycleMonitor: (any SessionLifecycleMonitoring)?
    private var onboardingSurface: (any OnboardingSurfacePresenting)?
    private var onboardingResolved = true
    private var onboardingProviderSelectionCommitted = false

    init(
        runtimeFactory: @escaping RuntimeFactory,
        panelFactory: @escaping PanelFactory,
        statusControllerFactory: @escaping StatusControllerFactory,
        settingsPresenterFactory: @escaping SettingsPresenterFactory,
        lifecycleMonitorFactory: @escaping LifecycleMonitorFactory,
        onboardingFactory: OnboardingFactory? = nil,
        requestQuit: @escaping @MainActor () -> Void
    ) {
        self.runtimeFactory = runtimeFactory
        self.panelFactory = panelFactory
        self.statusControllerFactory = statusControllerFactory
        self.settingsPresenterFactory = settingsPresenterFactory
        self.lifecycleMonitorFactory = lifecycleMonitorFactory
        self.onboardingFactory = onboardingFactory
        self.requestQuit = requestQuit
    }

    func start() {
        guard phase == .new else {
            return
        }
        phase = .running

        let runtime = runtimeFactory()
        viewModel = runtime.viewModel
        fallbackRateState = runtime.initialRateState
        quotaStore = runtime.quotaStore
        providerDashboardStore = runtime.providerDashboardStore
        settingsStore = runtime.settingsStore
        localizationModel = runtime.settingsDependencies?.localizationModel
        localizationModel?.language = runtime.settingsStore?.settings.language
            ?? .system
        themeEditorPresenter = runtime.settingsDependencies?.themeEditorPresenter
        providerRuntime = runtime.providerRuntime
        refreshCoordinator = runtime.refreshCoordinator

        let settingsPresenter = settingsPresenterFactory(runtime)
        self.settingsPresenter = settingsPresenter
        runtime.instrumentation?.recordOwner(
            .settings,
            identity: ObjectIdentifier(settingsPresenter)
        )
        let panelController = panelFactory(
            runtime,
            makePanelViewModel(runtime: runtime),
            { [weak self] frame in
                self?.persistPanelFrame(frame)
            },
            { [weak self] in
                self?.showSettingsIfRunning()
            },
            { [weak self] in
                self?.requestQuit()
            }
        )
        self.panelController = panelController
        runtime.instrumentation?.recordOwner(
            .panel,
            identity: ObjectIdentifier(panelController)
        )
        syncPanelProviderCountIfNeeded()

        let actions = AppLifecycleActions(
            refresh: { [weak self] in
                self?.requestManualRefresh()
            },
            panelShown: { [weak self] in
                self?.panelWasShown()
            },
            showSettings: { [weak self] in
                self?.showSettingsIfRunning()
            },
            quit: { [weak self] in
                self?.requestQuit()
            }
        )
        let statusItemController = statusControllerFactory(
            panelController,
            actions
        )
        self.statusItemController = statusItemController
        runtime.instrumentation?.recordOwner(
            .statusItem,
            identity: ObjectIdentifier(statusItemController)
        )

        let lifecycleMonitor = lifecycleMonitorFactory(
            SessionLifecycleCallbacks(
                screenParametersChanged: { [weak self] in
                    self?.screenParametersChanged()
                },
                effectiveSessionResigned: { [weak self] in
                    self?.sessionResigned()
                },
                effectiveSessionBecameActive: { [weak self] in
                    self?.sessionBecameActive()
                }
            )
        )
        self.lifecycleMonitor = lifecycleMonitor

        statusItemController.configure(
            initialPresentation: makeStatusItemPresentation()
        )
        configureOnboardingIfNeeded(runtime: runtime)
        startProviderRuntimeWhenReady()
        beginStatusObservation()
        lifecycleMonitor.start()
        if providerRuntime == nil {
            enqueueRefresh(.start(sessionGeneration: 1))
        }
    }

    func reopen() {
        guard phase == .running else {
            return
        }
        if let onboardingSurface,
           !onboardingResolved,
           onboardingSurface.isPending
        {
            onboardingSurface.show()
        } else {
            statusItemController?.showRecoverySurface()
        }
    }

#if DEBUG
    func debugShowPanel() {
        guard phase == .running else { return }
        guard let panelController else { return }
        panelController.show()
        panelWasShown()
    }

    func debugHidePanel() {
        guard phase == .running else { return }
        panelController?.hide()
    }

    func debugShowSettings() {
        guard phase == .running else { return }
        settingsPresenter?.showSettings()
    }

    func debugRequestQuit() {
        guard phase == .running else { return }
        requestQuit()
    }
#endif

    func screenParametersChanged() {
        guard phase == .running else {
            return
        }
        panelController?.clampToScreen()
    }

    func sessionResigned() {
        guard phase == .running, effectiveSessionActive else {
            return
        }
        effectiveSessionActive = false
        enqueueRefresh(.sessionResigned)
    }

    func sessionBecameActive() {
        guard phase == .running, !effectiveSessionActive else {
            return
        }
        effectiveSessionActive = true
        enqueueRefresh(.sessionBecameActive)
    }

    private func requestManualRefresh() {
        guard phase == .running else {
            return
        }
        if providerRuntime != nil {
            enqueueRefresh(.manual)
        } else {
            viewModel?.triggerRefresh()
        }
    }

    func terminate(reply: @escaping @MainActor () -> Void) {
        guard phase == .new || phase == .running else {
            return
        }
        phase = .terminating
        observationGeneration &+= 1
        panelController?.persistCurrentFrame()
        themeEditorPresenter?.dismissForTermination()
        settingsPresenter?.hideSettings()
        onboardingSurface?.hide()
        lifecycleMonitor?.stop()

        let previous = refreshTaskTail
        let providerRuntime = providerRuntime
        let refreshCoordinator = refreshCoordinator
        let cleanupTask = Task { [self] in
            await previous?.value
            if let providerRuntime {
                await providerRuntime.stopAndWait()
            } else if let refreshCoordinator {
                await refreshCoordinator.stop()
            }
            phase = .terminated
            reply()
        }
        refreshTaskTail = cleanupTask
    }

    private func enqueueRefresh(_ command: RefreshCommand) {
        guard phase == .running,
              providerRuntime != nil || refreshCoordinator != nil
        else {
            return
        }
        if providerRuntime != nil, !providerRuntimeStarted {
            return
        }
        let previous = refreshTaskTail
        let providerRuntime = providerRuntime
        let refreshCoordinator = refreshCoordinator
        refreshTaskTail = Task {
            await previous?.value
            if let providerRuntime {
                switch command {
                case .start:
                    return
                case .sessionResigned:
                    await providerRuntime.sessionResigned()
                case .sessionBecameActive:
                    await providerRuntime.sessionBecameActive()
                case .panelOpened:
                    await providerRuntime.panelOpened()
                case .manual:
                    await providerRuntime.manualRefresh()
                }
                return
            }
            guard let refreshCoordinator else { return }
            switch command {
            case let .start(sessionGeneration):
                await refreshCoordinator.start(
                    sessionGeneration: sessionGeneration
                )
            case .sessionResigned:
                await refreshCoordinator.sessionResigned()
            case .sessionBecameActive:
                await refreshCoordinator.sessionBecameActive()
            case .panelOpened:
                await refreshCoordinator.panelOpened()
            case .manual:
                return
            }
        }
    }

    private func panelWasShown() {
        guard phase == .running else {
            panelController?.hide()
            return
        }
        guard effectiveSessionActive else {
            return
        }
        enqueueRefresh(.panelOpened)
    }

    private func showSettingsIfRunning() {
        guard phase == .running else {
            return
        }
        settingsPresenter?.showSettings()
    }

    private func makePanelViewModel(
        runtime: AppLifecycleRuntime
    ) -> QuotaViewModel {
        guard let quotaStore = runtime.quotaStore else {
            return runtime.viewModel
        }
        return QuotaViewModel(
            store: quotaStore,
            requestManualRefresh: { [weak self] in
                self?.requestManualRefresh()
            }
        )
    }

    private func makeStatusItemPresentation() -> StatusItemPresentation {
        StatusItemPresenter().makePresentation(
            dashboardStates: providerDashboardStore?.statesByProvider ?? [:],
            codexCatalog: quotaStore?.rateState ?? fallbackRateState,
            settings: settingsStore?.settings ?? .defaults,
            now: Date(),
            locale: .current
        )
    }

    private func beginStatusObservation() {
        guard phase == .running,
              quotaStore != nil
                || providerDashboardStore != nil
                || settingsStore != nil
        else {
            return
        }
        let generation = observationGeneration
        withObservationTracking {
            _ = quotaStore?.rateState
            _ = providerDashboardStore?.orderedVisibleProviders
            _ = providerDashboardStore?.statesByProvider
            _ = settingsStore?.settings
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.phase == .running,
                      self.observationGeneration == generation
                else {
                    return
                }
                self.reconcileAvailableWindowsIfNeeded()
                self.panelController?.setSpacePolicy(
                    self.settingsStore?.settings.spacePolicy ?? .currentSpace
                )
                self.syncPanelProviderCountIfNeeded()
                self.localizationModel?.language =
                    self.settingsStore?.settings.language
                    ?? .system
                self.statusItemController?.updatePresentation(
                    self.makeStatusItemPresentation()
                )
                self.beginStatusObservation()
            }
        }
    }

    private func reconcileAvailableWindowsIfNeeded() {
        guard phase == .running,
              let settingsStore,
              let rateState = quotaStore?.rateState,
              case let .fresh(catalog, _) = rateState,
              reconciledFreshRateState != rateState
        else {
            return
        }
        reconciledFreshRateState = rateState
        _ = settingsStore.reconcileAvailableWindows(
            catalog.liveWindowIdentities()
        )
    }

    private func syncPanelProviderCountIfNeeded() {
        guard phase == .running, let panelController else {
            return
        }
        let count = settingsStore?.settings.enabledProviders.count ?? 1
        guard lastPanelProviderCount != count else {
            return
        }
        lastPanelProviderCount = count
        panelController.setProviderCount(count)
    }

    private func configureOnboardingIfNeeded(runtime: AppLifecycleRuntime) {
        guard let onboardingFactory,
              let settingsStore = runtime.settingsStore,
              let loginItemService = runtime.loginItemService,
              Self.isTrustedForOnboarding(settingsStore.recoveryState),
              !settingsStore.settings.onboardingCompleted
        else {
            onboardingResolved = true
            return
        }

        onboardingResolved = false
        let quotaStore = runtime.quotaStore
        let initialRateState = runtime.initialRateState
        let controller = OnboardingController(
            settingsStore: settingsStore,
            loginItemService: loginItemService,
            loginItemSettingsOpener: runtime.settingsDependencies?
                .loginItemSettingsOpener,
            providerDashboardStore: runtime.providerDashboardStore,
            codexCatalog: {
                quotaStore?.rateState ?? initialRateState
            },
            onProviderSelectionCommitted: { [weak self] _ in
                guard let self, phase == .running else {
                    return
                }
                onboardingProviderSelectionCommitted = true
                startProviderRuntimeWhenReady()
            },
            onResolved: { [weak self] _ in
                guard let self, phase == .running else {
                    return
                }
                onboardingResolved = true
                startProviderRuntimeWhenReady()
            }
        )
        let onboardingSurface = onboardingFactory(controller)
        self.onboardingSurface = onboardingSurface
        onboardingSurface.show()
    }

    private func startProviderRuntimeWhenReady() {
        guard phase == .running,
              onboardingResolved || onboardingProviderSelectionCommitted,
              !providerRuntimeStarted,
              let providerRuntime
        else {
            return
        }
        providerRuntimeStarted = true
        providerRuntime.start()
        if !effectiveSessionActive {
            enqueueRefresh(.sessionResigned)
        }
    }

    private static func isTrustedForOnboarding(
        _ recoveryState: SettingsRecoveryState
    ) -> Bool {
        if case .usingDefaults = recoveryState {
            return false
        }
        return true
    }

    private func persistPanelFrame(_ frame: PersistedPanelFrame) {
        guard let settingsStore else {
            return
        }
        var settings = settingsStore.settings
        guard settings.panelFrame != frame else {
            return
        }
        settings.panelFrame = frame
        _ = settingsStore.replace(with: settings)
    }
}
