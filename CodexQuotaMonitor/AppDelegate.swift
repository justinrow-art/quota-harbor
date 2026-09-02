import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var lifecycleCoordinator: AppLifecycleCoordinator?
#if DEBUG
    private var debugControlWindowController:
        DebugUITestControlWindowController?
#endif

    override init() {
        super.init()
    }

    init(lifecycleCoordinator: AppLifecycleCoordinator) {
        self.lifecycleCoordinator = lifecycleCoordinator
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
#if DEBUG
        if lifecycleCoordinator == nil {
            let processInfo = ProcessInfo.processInfo
            guard DebugHostedXCTestStartupPolicy.shouldStart(
                arguments: processInfo.arguments,
                environment: processInfo.environment
            ) else {
                return
            }
        }
#endif
        if lifecycleCoordinator == nil {
            lifecycleCoordinator = makeLifecycleCoordinator()
        }
        lifecycleCoordinator?.start()
#if DEBUG
        showDebugUITestControlWindowIfNeeded()
#endif
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        lifecycleCoordinator?.reopen()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let lifecycleCoordinator else {
            return .terminateNow
        }
        lifecycleCoordinator.terminate {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func makeLifecycleCoordinator() -> AppLifecycleCoordinator {
        AppLifecycleCoordinator(
            runtimeFactory: { [unowned self] in
                makeRuntimeConfiguration()
            },
            panelFactory: { runtime, viewModel, persistFrame, showSettings, quit in
                FloatingPanelController(
                    viewModel: viewModel,
                    settingsStore: runtime.settingsStore,
                    providerDashboardStore: runtime.providerDashboardStore,
                    spacePolicy: runtime.settingsStore?.settings.spacePolicy
                        ?? .currentSpace,
                    themeID: runtime.settingsStore?.settings.appearance.themeID
                        ?? "system",
                    themeRuntimeModel: runtime.settingsDependencies?
                        .themeRuntimeModel,
                    localizationModel: runtime.settingsDependencies?
                        .localizationModel ?? AppLocalizationRuntimeModel(),
                    persistedFrame: runtime.settingsStore?.settings.panelFrame,
                    persistFrame: persistFrame,
                    showSettings: showSettings,
                    quit: quit
                )
            },
            statusControllerFactory: { panel, actions in
                StatusItemController(
                    statusItemFactory: {
                        AppKitStatusItemHandle()
                    },
                    panelFactory: {
                        panel
                    },
                    panelShown: actions.panelShown,
                    refresh: actions.refresh,
                    showSettings: actions.showSettings,
                    quit: actions.quit
                )
            },
            settingsPresenterFactory: { runtime in
                guard let dependencies = runtime.settingsDependencies,
                      let viewModel = Self.makeSettingsViewModel(
                          runtime: runtime
                      )
                else {
                    return UnavailableSettingsSurfacePresenter()
                }
                return SettingsWindowController(
                    viewModel: viewModel,
                    localizationModel: dependencies.localizationModel
                )
            },
            lifecycleMonitorFactory: { callbacks in
                SessionLifecycleMonitor(callbacks: callbacks)
            },
            onboardingFactory: { controller in
                OnboardingWindowController(
                    controller: controller
                )
            },
            requestQuit: {
                NSApplication.shared.terminate(nil)
            }
        )
    }

    static func makeSettingsViewModel(
        runtime: AppLifecycleRuntime,
        appVersion: String? = nil
    ) -> SettingsViewModel? {
        guard let settingsStore = runtime.settingsStore,
              let quotaStore = runtime.quotaStore,
              let loginItemService = runtime.loginItemService,
              let dependencies = runtime.settingsDependencies
        else {
            return nil
        }
        let resolvedAppVersion = appVersion ?? Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? ""
        let themeEditorPresenter = dependencies.themeEditorPresenter
        return SettingsViewModel(
            settingsStore: settingsStore,
            quotaStore: quotaStore,
            loginItemService: loginItemService,
            themeService: dependencies.themeService,
            installedVersionProvider: dependencies.installedVersionProvider,
            diagnosticsCopier: dependencies.diagnosticsCopier,
            localizationModel: dependencies.localizationModel,
            loginItemSettingsOpener: dependencies.loginItemSettingsOpener,
            providerDashboardStore: runtime.providerDashboardStore,
            providerLinkOpener: dependencies.providerLinkOpener,
            claudeRelayService: dependencies.claudeRelayService,
            requestRefresh: {
                runtime.viewModel.triggerRefresh()
            },
            openThemeEditor: {
                themeEditorPresenter?.show()
            },
            themeEditorMutations: dependencies.themeEditorMutations,
            appVersion: resolvedAppVersion
        )
    }

    private func makeRuntimeConfiguration() -> AppLifecycleRuntime {
#if DEBUG
        let processInfo = ProcessInfo.processInfo
        let selection = DebugRuntimeLaunchConfiguration.resolve(
            arguments: processInfo.arguments,
            environment: processInfo.environment
        )
        if case let .uiTesting(launch) = selection {
            DebugUITestRuntimeFactory.prepareProbe(for: launch)
        }
        return DebugRuntimeRouter.route(
            selection: selection,
            production: {
                guard LoginItemRuntimeGuard.allowsProductionService(
                    arguments: processInfo.arguments,
                    environment: processInfo.environment
                ) else {
                    return Self.unavailableRuntime()
                }
                return productionRuntime()
            },
            fixture: { fixture in
                fixtureRuntime(fixture)
            },
            uiTesting: { launch in
                DebugUITestRuntimeFactory.make(launch: launch)
            },
            invalid: {
                Self.unavailableRuntime()
            }
        )
#else
        let processInfo = ProcessInfo.processInfo
        guard LoginItemRuntimeGuard.allowsProductionService(
            arguments: processInfo.arguments,
            environment: processInfo.environment
        ) else {
            return Self.suppressedRuntime()
        }
        return productionRuntime()
#endif
    }

#if DEBUG
    private func showDebugUITestControlWindowIfNeeded() {
        let processInfo = ProcessInfo.processInfo
        guard case let .uiTesting(launch) =
            DebugRuntimeLaunchConfiguration.resolve(
                arguments: processInfo.arguments,
                environment: processInfo.environment
            ),
            let lifecycleCoordinator,
            let probe = DebugUITestRuntimeFactory.probe(
                for: launch.sessionID
            )
        else {
            return
        }
        let controller = DebugUITestControlWindowController(
            launch: launch,
            probe: probe,
            actions: DebugUITestControlActions(
                showPanel: { [weak lifecycleCoordinator] in
                    lifecycleCoordinator?.debugShowPanel()
                },
                hidePanel: { [weak lifecycleCoordinator] in
                    lifecycleCoordinator?.debugHidePanel()
                },
                reopen: { [weak lifecycleCoordinator] in
                    lifecycleCoordinator?.reopen()
                },
                showSettings: { [weak lifecycleCoordinator] in
                    lifecycleCoordinator?.debugShowSettings()
                },
                quit: { [weak lifecycleCoordinator] in
                    lifecycleCoordinator?.debugRequestQuit()
                }
            )
        )
        debugControlWindowController = controller
        controller.show()
    }
#endif

    private func productionRuntime() -> AppLifecycleRuntime {
#if DEBUG
        DebugUITestRuntimeFactory
            .recordForbiddenProductionConnectionAndProcess()
        DebugUITestRuntimeFactory
            .recordForbiddenProductionSystemSettingsOpener()
#endif
        let store = QuotaStore()
        let settingsStore = SettingsStore()
        let localizationModel = AppLocalizationRuntimeModel(
            language: settingsStore.settings.language,
            systemLocale: .current
        )
        let themeBootstrap = ProductionThemeRuntimeBootstrap.make(
            settingsStore: settingsStore,
            localizationModel: localizationModel
        )
        let client = CodexAppServerClient()
        let coordinator = RefreshCoordinator(client: client, publisher: store)
        let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support",
                isDirectory: true
            )
        let providerComposition = ProductionProviderComposition.make(
            quotaStore: store,
            settingsStore: settingsStore,
            codexService: coordinator,
            applicationSupportURL: applicationSupportURL
        )
        let viewModel = QuotaViewModel(
            store: store,
            requestManualRefresh: {
                Task {
                    await providerComposition.runtimeCoordinator
                        .manualRefresh()
                }
            }
        )
        return AppLifecycleRuntime(
            viewModel: viewModel,
            initialRateState: store.rateState,
            quotaStore: store,
            providerDashboardStore: providerComposition.dashboardStore,
            settingsStore: settingsStore,
            providerRuntime: providerComposition.runtimeCoordinator,
            refreshCoordinator: nil,
            loginItemService: MainAppLoginItemService.makeProduction(),
            settingsDependencies: SettingsRuntimeDependencies(
                localizationModel: localizationModel,
                themeService: themeBootstrap.themeService,
                themeRuntimeModel: themeBootstrap.runtimeModel,
                themeEditorPresenter:
                    themeBootstrap.themeEditorPresenter,
                themeEditorMutations:
                    themeBootstrap.themeEditorMutations,
                installedVersionProvider:
                    VerifiedInstalledCodexVersionProvider(),
                diagnosticsCopier: PasteboardDiagnosticsCopier(),
                loginItemSettingsOpener: SystemLoginItemSettingsOpener(),
                providerLinkOpener: SystemProviderExternalLinkOpener(),
                claudeRelayService:
                    ProductionClaudeRelaySettingsService.live()
            )
        )
    }

#if DEBUG
    private func fixtureRuntime(
        _ fixture: DebugQuotaFixture
    ) -> AppLifecycleRuntime {
        AppLifecycleRuntime(
            viewModel: fixture.makeViewModel(),
            initialRateState: fixture.makeRateState(),
            quotaStore: nil,
            settingsStore: nil,
            refreshCoordinator: nil,
            loginItemService: nil
        )
    }

    private static func unavailableRuntime() -> AppLifecycleRuntime {
        let now = Date()
        return AppLifecycleRuntime(
            viewModel: .debugFixture(
                state: .unavailable(.schemaChanged),
                lastUpdatedAt: nil,
                now: now
            ),
            initialRateState: .unavailable(.invalidSchema),
            quotaStore: nil,
            settingsStore: nil,
            refreshCoordinator: nil,
            loginItemService: nil
        )
    }
#endif

    private static func suppressedRuntime() -> AppLifecycleRuntime {
        let store = QuotaStore()
        return AppLifecycleRuntime(
            viewModel: QuotaViewModel(store: store),
            initialRateState: .unavailable(.invalidSchema),
            quotaStore: nil,
            settingsStore: nil,
            refreshCoordinator: nil,
            loginItemService: nil
        )
    }
}
