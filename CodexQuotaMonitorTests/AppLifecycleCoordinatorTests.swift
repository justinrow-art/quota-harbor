import AppKit
import Foundation
import XCTest
@testable import CodexQuotaMonitor

@MainActor
final class AppLifecycleCoordinatorTests: XCTestCase {
    func testColdLaunchCreatesAndStartsEveryOwnerExactlyOnce() async {
        let harness = LifecycleHarness()

        harness.coordinator.start()
        await assertEventually {
            await harness.refresh.eventsSnapshot() == ["start:1"]
        }

        XCTAssertEqual(harness.runtimeFactoryCount, 1)
        XCTAssertEqual(harness.panelFactoryCount, 1)
        XCTAssertEqual(harness.statusFactoryCount, 1)
        XCTAssertEqual(harness.settingsFactoryCount, 1)
        XCTAssertEqual(harness.monitorFactoryCount, 1)
        XCTAssertEqual(harness.monitor.startCount, 1)
        XCTAssertEqual(harness.status.configureCount, 1)
        XCTAssertTrue(harness.status.panel === harness.panel)
    }

    func testTenDuplicateStartCallbacksCreateNothingExtra() async {
        let harness = LifecycleHarness()

        for _ in 0..<10 {
            harness.coordinator.start()
        }
        await assertEventually {
            await harness.refresh.eventsSnapshot() == ["start:1"]
        }

        XCTAssertEqual(harness.runtimeFactoryCount, 1)
        XCTAssertEqual(harness.panelFactoryCount, 1)
        XCTAssertEqual(harness.statusFactoryCount, 1)
        XCTAssertEqual(harness.settingsFactoryCount, 1)
        XCTAssertEqual(harness.monitorFactoryCount, 1)
        XCTAssertEqual(harness.monitor.startCount, 1)
    }

    func testFinderSpotlightAndLaunchpadReopenQueuePanelOpenedCommands() async {
        let harness = LifecycleHarness()
        harness.coordinator.start()
        await assertEventually {
            await harness.refresh.eventsSnapshot() == ["start:1"]
        }

        for _ in 0..<3 {
            harness.coordinator.reopen()
        }

        XCTAssertEqual(harness.panel.showCount, 3)
        XCTAssertEqual(harness.panelFactoryCount, 1)
        await assertEventually {
            await harness.refresh.eventsSnapshot()
                == ["start:1", "panel", "panel", "panel"]
        }
    }

#if DEBUG
    func testDebugShowRoutesPanelOpenedButDebugHideDoesNot() async {
        let harness = LifecycleHarness()
        harness.coordinator.start()
        await assertEventually {
            await harness.refresh.eventsSnapshot() == ["start:1"]
        }

        harness.coordinator.debugShowPanel()
        harness.coordinator.debugHidePanel()

        XCTAssertEqual(harness.panel.showCount, 1)
        XCTAssertEqual(harness.panel.hideCount, 1)
        await assertEventually {
            await harness.refresh.eventsSnapshot() == ["start:1", "panel"]
        }
    }
#endif

    func testSettingsActionsReuseOnePresenter() {
        let harness = LifecycleHarness()
        harness.coordinator.start()

        for _ in 0..<4 {
            harness.status.invokeSettings()
        }
        harness.invokePanelSettings()

        XCTAssertEqual(harness.settingsFactoryCount, 1)
        XCTAssertEqual(harness.settingsPresenter.showCount, 5)
    }

    func testLateSettingsActionsDuringAndAfterTerminationDoNotReopenPresenter()
        async
    {
        let gate = AsyncGate()
        let refresh = RecordingRefreshLifecycle(startGate: gate)
        let harness = LifecycleHarness(refresh: refresh)
        var replyCount = 0
        harness.coordinator.start()
        await assertEventually {
            await refresh.eventsSnapshot() == ["start:1"]
        }

        harness.status.invokeSettings()
        harness.invokePanelSettings()
        XCTAssertEqual(harness.settingsPresenter.showCount, 2)

        harness.coordinator.terminate {
            replyCount += 1
        }
        harness.status.invokeSettings()
        harness.invokePanelSettings()
        XCTAssertEqual(harness.settingsPresenter.showCount, 2)

        await gate.open()
        await assertEventually { replyCount == 1 }
        harness.status.invokeSettings()
        harness.invokePanelSettings()
        XCTAssertEqual(harness.settingsPresenter.showCount, 2)
    }

    func testLateRefreshActionsDuringAndAfterTerminationDoNotRequestRefresh()
        async
    {
        let gate = AsyncGate()
        let refresh = RecordingRefreshLifecycle(startGate: gate)
        let harness = LifecycleHarness(refresh: refresh)
        var replyCount = 0
        harness.coordinator.start()
        await assertEventually {
            await refresh.eventsSnapshot() == ["start:1"]
        }

        harness.status.invokeRefresh()
        harness.invokePanelRefresh()
        XCTAssertEqual(harness.manualRefreshRequestCount, 2)

        harness.coordinator.terminate {
            replyCount += 1
        }
        harness.status.invokeRefresh()
        harness.invokePanelRefresh()
        XCTAssertEqual(harness.manualRefreshRequestCount, 2)

        await gate.open()
        await assertEventually { replyCount == 1 }
        harness.status.invokeRefresh()
        harness.invokePanelRefresh()
        XCTAssertEqual(harness.manualRefreshRequestCount, 2)
    }

    func testExplicitQuitActionRequestsNativeTerminationExactlyOnce() {
        let harness = LifecycleHarness()
        harness.coordinator.start()

        harness.status.invokeQuit()

        XCTAssertEqual(harness.quitRequestCount, 1)
    }

    func testScreenChangeOnlyClampsTheRetainedPanel() async {
        let harness = LifecycleHarness()
        harness.coordinator.start()
        await assertEventually {
            await harness.refresh.eventsSnapshot() == ["start:1"]
        }

        harness.coordinator.screenParametersChanged()

        XCTAssertEqual(harness.panel.clampCount, 1)
        XCTAssertEqual(harness.panel.persistCount, 0)
        let events = await harness.refresh.eventsSnapshot()
        XCTAssertEqual(events, ["start:1"])
    }

    func testNativeScreenNotificationClampsExactlyOnceAcrossAppDelegateAndMonitor() {
        let notificationCenter = NotificationCenter.default
        let workspaceCenter = NotificationCenter()
        let quotaStore = QuotaStore()
        let panel = FakeLifecyclePanel()
        let status = FakeStatusSurface()
        let settingsPresenter = FakeSettingsSurfacePresenter()
        let coordinator = AppLifecycleCoordinator(
            runtimeFactory: {
                AppLifecycleRuntime(
                    viewModel: QuotaViewModel(store: quotaStore),
                    initialRateState: quotaStore.rateState,
                    quotaStore: quotaStore,
                    settingsStore: nil,
                    refreshCoordinator: nil
                )
            },
            panelFactory: { _, _, _, _, _ in panel },
            statusControllerFactory: { installedPanel, actions in
                status.install(panel: installedPanel, actions: actions)
                return status
            },
            settingsPresenterFactory: { _ in settingsPresenter },
            lifecycleMonitorFactory: { callbacks in
                SessionLifecycleMonitor(
                    notificationCenter: notificationCenter,
                    workspaceNotificationCenter: workspaceCenter,
                    callbacks: callbacks
                )
            },
            requestQuit: {}
        )
        let appDelegate = AppDelegate(lifecycleCoordinator: coordinator)
        let application = NSApplication.shared
        let previousDelegate = application.delegate
        application.delegate = appDelegate
        defer {
            coordinator.terminate {}
            application.delegate = previousDelegate
        }
        appDelegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )

        notificationCenter.post(
            name: NSApplication.didChangeScreenParametersNotification,
            object: application
        )

        XCTAssertEqual(panel.clampCount, 1)
    }

    func testImmediateStartResignAndBecomeActiveCommandsStayOrdered() async {
        let harness = LifecycleHarness()

        harness.coordinator.start()
        harness.coordinator.sessionResigned()
        harness.coordinator.sessionBecameActive()

        await assertEventually {
            await harness.refresh.eventsSnapshot()
                == ["start:1", "resign", "active"]
        }
    }

    func testProviderRuntimeOwnsLifecycleEventsAndDrainWithoutLegacyRefresh()
        async
    {
        let stopGate = AsyncGate()
        let providerRuntime = RecordingProviderRuntime(stopGate: stopGate)
        let legacyRefresh = RecordingRefreshLifecycle()
        let harness = LifecycleHarness(
            refresh: legacyRefresh,
            providerRuntime: providerRuntime
        )
        var replyCount = 0

        harness.coordinator.start()
        harness.coordinator.sessionResigned()
        harness.coordinator.sessionBecameActive()
        harness.status.invokePrimaryShow()
        harness.status.invokeRefresh()
        harness.invokePanelRefresh()

        await assertEventually {
            providerRuntime.eventsSnapshot() == [
                "start",
                "resign",
                "active",
                "panel",
                "manual",
                "manual",
            ]
        }
        let legacyEventsBeforeStop = await legacyRefresh.eventsSnapshot()
        XCTAssertEqual(legacyEventsBeforeStop, [])

        harness.coordinator.terminate {
            replyCount += 1
        }
        await assertEventually {
            providerRuntime.eventsSnapshot().last == "stop-begin"
        }
        XCTAssertEqual(replyCount, 0)
        let legacyEventsDuringStop = await legacyRefresh.eventsSnapshot()
        XCTAssertEqual(legacyEventsDuringStop, [])

        await stopGate.open()
        await assertEventually { replyCount == 1 }
        let finalProviderEvent = providerRuntime.eventsSnapshot().last
        let legacyEventsAfterStop = await legacyRefresh.eventsSnapshot()
        XCTAssertEqual(finalProviderEvent, "stop-finished")
        XCTAssertEqual(legacyEventsAfterStop, [])
    }

    func testProviderRuntimeStartsAfterSelectionCommitBeforeResolutionOnlyOnce()
        async throws
    {
        let stopGate = AsyncGate()
        let providerRuntime = RecordingProviderRuntime(stopGate: stopGate)
        let harness = LifecycleHarness(
            providerRuntime: providerRuntime,
            includesPendingOnboarding: true
        )

        harness.coordinator.start()
        harness.coordinator.sessionResigned()
        harness.coordinator.sessionBecameActive()
        harness.status.invokePrimaryShow()
        harness.status.invokeRefresh()
        harness.invokePanelRefresh()
        await drainObservationTasks()

        XCTAssertEqual(harness.onboardingSurface.showCount, 1)
        XCTAssertEqual(providerRuntime.eventsSnapshot(), [])
        let controller = try XCTUnwrap(harness.onboardingController)
        await controller.load()

        XCTAssertTrue(controller.continueFromProviderSelection())
        await assertEventually {
            providerRuntime.eventsSnapshot() == ["start"]
        }
        XCTAssertTrue(controller.isPending)

        let panelShowCountBeforeReopen = harness.panel.showCount
        harness.coordinator.reopen()
        XCTAssertEqual(harness.onboardingSurface.showCount, 2)
        XCTAssertEqual(
            harness.panel.showCount,
            panelShowCountBeforeReopen
        )

        controller.goBack()
        XCTAssertTrue(controller.continueFromProviderSelection())
        XCTAssertEqual(providerRuntime.eventsSnapshot(), ["start"])

        harness.status.invokeRefresh()
        await assertEventually {
            providerRuntime.eventsSnapshot() == ["start", "manual"]
        }

        harness.coordinator.terminate {}
        await assertEventually {
            providerRuntime.eventsSnapshot().last == "stop-begin"
        }
        await stopGate.open()
    }

    func testProviderRuntimeStartsOnceWhenOnboardingResolvesBeforeSelectionCommit()
        async throws
    {
        let stopGate = AsyncGate()
        let providerRuntime = RecordingProviderRuntime(stopGate: stopGate)
        let harness = LifecycleHarness(
            providerRuntime: providerRuntime,
            includesPendingOnboarding: true
        )

        harness.coordinator.start()
        let controller = try XCTUnwrap(harness.onboardingController)
        await controller.load()

        let didCancel = await controller.cancel()
        XCTAssertTrue(didCancel)
        await assertEventually {
            providerRuntime.eventsSnapshot() == ["start"]
        }

        harness.coordinator.reopen()
        XCTAssertEqual(harness.onboardingSurface.showCount, 1)
        XCTAssertEqual(harness.panel.showCount, 1)
        XCTAssertEqual(providerRuntime.eventsSnapshot(), ["start"])

        harness.coordinator.terminate {}
        await assertEventually {
            providerRuntime.eventsSnapshot().last == "stop-begin"
        }
        await stopGate.open()
    }

    func testTerminationDrainsProviderRuntimeWhileOnboardingIsStillPending()
        async
    {
        let stopGate = AsyncGate()
        let providerRuntime = RecordingProviderRuntime(stopGate: stopGate)
        let harness = LifecycleHarness(
            providerRuntime: providerRuntime,
            includesPendingOnboarding: true
        )
        var replyCount = 0

        harness.coordinator.start()
        XCTAssertEqual(providerRuntime.eventsSnapshot(), [])
        harness.coordinator.terminate {
            replyCount += 1
        }

        await assertEventually {
            providerRuntime.eventsSnapshot() == ["stop-begin"]
        }
        XCTAssertEqual(replyCount, 0)
        await stopGate.open()
        await assertEventually { replyCount == 1 }
        XCTAssertEqual(
            providerRuntime.eventsSnapshot(),
            ["stop-begin", "stop-finished"]
        )
    }

    func testPendingOnboardingCommitStartsRuntimeThenReplaysInactiveSession()
        async throws
    {
        let stopGate = AsyncGate()
        let providerRuntime = RecordingProviderRuntime(stopGate: stopGate)
        let harness = LifecycleHarness(
            providerRuntime: providerRuntime,
            includesPendingOnboarding: true
        )

        harness.coordinator.start()
        harness.coordinator.sessionResigned()
        let controller = try XCTUnwrap(harness.onboardingController)
        await controller.load()
        XCTAssertTrue(controller.continueFromProviderSelection())

        await assertEventually {
            providerRuntime.eventsSnapshot() == ["start", "resign"]
        }

        controller.goBack()
        XCTAssertTrue(controller.continueFromProviderSelection())
        XCTAssertEqual(
            providerRuntime.eventsSnapshot(),
            ["start", "resign"]
        )

        harness.coordinator.terminate {}
        await assertEventually {
            providerRuntime.eventsSnapshot().last == "stop-begin"
        }
        await stopGate.open()
    }

    func testOnboardingReceivesLiveCodexDashboardState() throws {
        let harness = LifecycleHarness(
            includesProviderDashboardStore: true,
            includesPendingOnboarding: true
        )
        let generation = harness.providerDashboardStore.activate(.codex)
        let snapshot = try Self.providerSnapshot(.codex, remaining: 0.42)
        XCTAssertTrue(
            harness.providerDashboardStore.apply(
                .fresh(snapshot),
                for: generation
            )
        )

        harness.coordinator.start()
        let controller = try XCTUnwrap(harness.onboardingController)
        XCTAssertEqual(
            controller.providersPresentation.rows.first?.connectionState,
            .connected
        )

        XCTAssertTrue(
            harness.providerDashboardStore.apply(
                .stale(snapshot),
                for: generation
            )
        )
        XCTAssertEqual(
            controller.providersPresentation.rows.first?.connectionState,
            .stale
        )
    }

    func testOnboardingPreviewReadsLiveCodexCatalog() async throws {
        let harness = LifecycleHarness(includesPendingOnboarding: true)
        await prepareRatePublishing(harness)
        let controller = try XCTUnwrap(harness.onboardingController)
        XCTAssertEqual(controller.providersPresentation.preview.title, "Codex …")

        let catalog = try Self.catalog(usedPercent: 37)
        await publishRate(.fresh(catalog, Date()), to: harness)

        XCTAssertNotEqual(
            controller.providersPresentation.preview.title,
            "Codex …"
        )
        XCTAssertTrue(controller.providersPresentation.preview.title.contains("%"))
    }

    func testInactiveSessionSurfacesDoNotScheduleRefreshLifecycleWork() async {
        let harness = LifecycleHarness()
        harness.coordinator.start()
        harness.coordinator.sessionResigned()
        await assertEventually {
            await harness.refresh.eventsSnapshot() == ["start:1", "resign"]
        }

        harness.coordinator.reopen()
        harness.coordinator.screenParametersChanged()
        harness.status.invokeSettings()
        for _ in 0..<3 {
            harness.coordinator.sessionResigned()
        }

        let events = await harness.refresh.eventsSnapshot()
        XCTAssertEqual(events, ["start:1", "resign"])
    }

    func testPersistedLanguageChangeUpdatesSharedLocalizationModel() async {
        let harness = LifecycleHarness()
        harness.coordinator.start()
        var settings = harness.settingsStore.settings
        settings.language = .japanese

        if case let .failure(error) = harness.settingsStore.replace(with: settings) {
            XCTFail("Expected persisted language update to succeed, got \(error)")
        }

        await assertEventually {
            harness.localizationModel.language == .japanese
        }
        XCTAssertEqual(harness.localizationModel.language, .japanese)
    }

    func testNonCodexDashboardMutationDoesNotAffectCodexOnlyStatus() async throws {
        let harness = LifecycleHarness(includesProviderDashboardStore: true)
        let generation = harness.providerDashboardStore.activate(.claudeCode)
        harness.coordinator.start()
        XCTAssertEqual(harness.settingsStore.settings.enabledProviders, [.codex])
        XCTAssertEqual(harness.status.presentations.last?.title, "Codex …")

        XCTAssertTrue(harness.providerDashboardStore.apply(
            .fresh(try Self.providerSnapshot(.claudeCode, remaining: 0.42)),
            for: generation
        ))
        await drainObservationTasks()

        XCTAssertEqual(harness.status.presentations.last?.title, "Codex …")
    }

    func testPanelProviderCountTracksSelectableProvidersAcrossLegacySelections()
        async throws
    {
        let harness = LifecycleHarness(includesProviderDashboardStore: true)
        harness.coordinator.start()
        XCTAssertEqual(harness.panel.providerCounts, [1])

        var settings = harness.settingsStore.settings
        settings.enabledProviders = [.codex, .claudeCode, .kimiCode]
        try harness.settingsStore.replace(with: settings).get()
        await drainObservationTasks()
        XCTAssertEqual(
            harness.settingsStore.settings.enabledProviders,
            [.codex, .claudeCode]
        )
        XCTAssertEqual(harness.panel.providerCounts, [1, 2])

        settings = harness.settingsStore.settings
        settings.enabledProviders = [.claudeCode, .googleAntigravity]
        try harness.settingsStore.replace(with: settings).get()
        await drainObservationTasks()
        XCTAssertEqual(
            harness.settingsStore.settings.enabledProviders,
            [.codex, .claudeCode]
        )
        XCTAssertEqual(harness.panel.providerCounts, [1, 2])
    }

    func testNonCodexDashboardMutationDoesNotRequestPanelResize() async throws {
        let harness = LifecycleHarness(includesProviderDashboardStore: true)
        let generation = harness.providerDashboardStore.activate(.claudeCode)
        harness.coordinator.start()
        XCTAssertEqual(harness.panel.providerCounts, [1])

        XCTAssertTrue(harness.providerDashboardStore.apply(
            .fresh(try Self.providerSnapshot(.claudeCode, remaining: 0.42)),
            for: generation
        ))
        await drainObservationTasks()

        XCTAssertEqual(harness.panel.providerCounts, [1])
    }

    func testStatusObservationRearmsAcrossDashboardQuotaAndSettingsMutations()
        async throws
    {
        let harness = LifecycleHarness(includesProviderDashboardStore: true)
        let catalog = try Self.catalog(usedPercent: 37)
        let codexGeneration = harness.providerDashboardStore.activate(.codex)
        XCTAssertTrue(harness.providerDashboardStore.apply(
            .fresh(try Self.providerSnapshot(
                .codex,
                remaining: 0.1
            )),
            for: codexGeneration
        ))
        await harness.quotaStore.apply(RefreshPublication(
            sequence: 1,
            generation: Self.rateGeneration,
            change: .reset
        ))
        harness.coordinator.start()
        XCTAssertEqual(harness.status.presentations.last?.title, "Codex …")

        let countBeforeDashboard = harness.status.presentations.count
        XCTAssertTrue(harness.providerDashboardStore.apply(
            .fresh(try Self.providerSnapshot(.codex, remaining: 0.2)),
            for: codexGeneration
        ))
        await assertEventually {
            harness.status.presentations.count > countBeforeDashboard
        }
        XCTAssertEqual(harness.status.presentations.last?.title, "Codex …")

        let countBeforeQuota = harness.status.presentations.count
        await publishRate(
            .fresh(catalog, Date()),
            to: harness
        )
        await assertEventually {
            harness.status.presentations.count > countBeforeQuota
        }
        await assertEventually {
            harness.status.presentations.last?.title == "5h 63%"
        }

        var settings = harness.settingsStore.settings
        settings.language = .english
        settings.percentageMode = .used
        let countBeforeSettings = harness.status.presentations.count
        try harness.settingsStore.replace(with: settings).get()
        await assertEventually {
            harness.status.presentations.count > countBeforeSettings
        }
        XCTAssertEqual(harness.status.presentations.last?.title, "5h U37%")
    }

    func testStatusObservationAppliesDisplayModeAndPrimaryProvider()
        async throws
    {
        let harness = LifecycleHarness(includesProviderDashboardStore: true)
        let claudeGeneration = harness.providerDashboardStore.activate(
            .claudeCode
        )
        XCTAssertTrue(harness.providerDashboardStore.apply(
            .fresh(try Self.providerSnapshot(
                .claudeCode,
                remaining: 0.42
            )),
            for: claudeGeneration
        ))
        var settings = harness.settingsStore.settings
        settings.language = .english
        settings.enabledProviders = [.codex, .claudeCode]
        settings.statusItemDisplayMode = .automatic
        try harness.settingsStore.replace(with: settings).get()

        harness.coordinator.start()
        XCTAssertEqual(
            harness.status.presentations.last?.title,
            "Cx… · Cl42%"
        )

        settings = harness.settingsStore.settings
        settings.statusItemDisplayMode = .primary
        settings.primaryStatusItemProvider = .claudeCode
        let countBeforeClaudePrimary = harness.status.presentations.count
        try harness.settingsStore.replace(with: settings).get()
        await assertEventually {
            harness.status.presentations.count > countBeforeClaudePrimary
        }
        XCTAssertEqual(harness.status.presentations.last?.title, "Cl42%")

        settings = harness.settingsStore.settings
        settings.primaryStatusItemProvider = .codex
        let countBeforeCodexPrimary = harness.status.presentations.count
        try harness.settingsStore.replace(with: settings).get()
        await assertEventually {
            harness.status.presentations.count > countBeforeCodexPrimary
        }
        XCTAssertEqual(harness.status.presentations.last?.title, "Cx…")
    }

    func testUnsupportedProviderSelectionsKeepSelectableProviderStatus()
        async throws
    {
        let harness = LifecycleHarness(includesProviderDashboardStore: true)
        for (providerID, remaining) in [
            (ProviderID.googleAntigravity, 0.1),
            (.claudeCode, 0.3),
        ] {
            let generation = harness.providerDashboardStore.activate(providerID)
            XCTAssertTrue(harness.providerDashboardStore.apply(
                .fresh(try Self.providerSnapshot(
                    providerID,
                    remaining: remaining
                )),
                for: generation
            ))
        }
        var settings = harness.settingsStore.settings
        settings.enabledProviders = [
            .googleAntigravity,
            .claudeCode,
        ]
        try harness.settingsStore.replace(with: settings).get()
        XCTAssertEqual(
            harness.settingsStore.settings.enabledProviders,
            [.codex, .claudeCode]
        )

        harness.coordinator.start()
        XCTAssertEqual(harness.status.presentations.last?.title, "Cx… · Cl30%")

        settings = harness.settingsStore.settings
        settings.enabledProviders = [.claudeCode, .googleAntigravity]
        try harness.settingsStore.replace(with: settings).get()
        await drainObservationTasks()

        XCTAssertEqual(
            harness.settingsStore.settings.enabledProviders,
            [.codex, .claudeCode]
        )
        XCTAssertEqual(harness.status.presentations.last?.title, "Cx… · Cl30%")
    }

    func testTerminateIgnoresLateDashboardPublication() async throws {
        let harness = LifecycleHarness(includesProviderDashboardStore: true)
        let generation = harness.providerDashboardStore.activate(.codex)
        harness.coordinator.start()
        harness.coordinator.terminate {}
        let presentationCount = harness.status.presentations.count

        XCTAssertTrue(harness.providerDashboardStore.apply(
            .fresh(try Self.providerSnapshot(.codex, remaining: 0.4)),
            for: generation
        ))
        await drainObservationTasks()

        XCTAssertEqual(harness.status.presentations.count, presentationCount)
    }

    func testSingleCodexKeepsLegacyQuotaStoreAsPresentationSource()
        async throws
    {
        let harness = LifecycleHarness(includesProviderDashboardStore: true)
        let generation = harness.providerDashboardStore.activate(.codex)
        XCTAssertTrue(harness.providerDashboardStore.apply(
            .fresh(try Self.providerSnapshot(.codex, remaining: 0.99)),
            for: generation
        ))
        await harness.quotaStore.apply(RefreshPublication(
            sequence: 1,
            generation: Self.rateGeneration,
            change: .reset
        ))
        await publishRate(
            .fresh(try Self.catalog(usedPercent: 37), Date()),
            to: harness
        )
        harness.coordinator.start()

        XCTAssertEqual(harness.status.presentations.last?.title, "5h 63%")

        XCTAssertTrue(harness.providerDashboardStore.apply(
            .fresh(try Self.providerSnapshot(.codex, remaining: 0.88)),
            for: generation
        ))
        await drainObservationTasks()
        XCTAssertEqual(harness.status.presentations.last?.title, "5h 63%")

        await publishRate(
            .fresh(try Self.catalog(usedPercent: 49), Date()),
            to: harness
        )
        await assertEventually {
            harness.status.presentations.last?.title == "5h 51%"
        }
    }

    func testFreshFullCatalogRetiresOnlyMissingManualSelection() async throws {
        let clock = LifecycleSettingsClock(
            Date(timeIntervalSince1970: 1_700_000_000)
        )
        let harness = LifecycleHarness(settingsNow: clock.now)
        let liveSearch = WindowIdentity(
            bucketKey: "search",
            sourceSlot: .secondary,
            durationMinutes: 10_080
        )
        let missing = WindowIdentity(
            bucketKey: "removed",
            sourceSlot: .primary,
            durationMinutes: 300
        )
        var settings = harness.settingsStore.settings
        settings.menuBarMode = .manual([liveSearch, missing])
        try harness.settingsStore.replace(with: settings).get()
        await prepareRatePublishing(harness)
        let catalog = try Self.catalog(
            identities: [
                WindowIdentity(
                    bucketKey: "codex",
                    sourceSlot: .primary,
                    durationMinutes: 300
                ),
                liveSearch,
            ]
        )

        await publishRate(.fresh(catalog, clock.now()), to: harness)

        await assertEventually {
            harness.settingsStore.retiredWindowSelections.map(\.identity)
                == [missing]
        }
        XCTAssertEqual(
            harness.settingsStore.settings.menuBarMode,
            .manual([liveSearch, missing])
        )
    }

    func testFreshCatalogRestoresReturningSelectionWithinThirtyDays()
        async throws
    {
        let clock = LifecycleSettingsClock(
            Date(timeIntervalSince1970: 1_700_000_000)
        )
        let harness = LifecycleHarness(settingsNow: clock.now)
        let fiveHour = Self.identity(.primary, 300)
        let week = Self.identity(.secondary, 10_080)
        var settings = harness.settingsStore.settings
        settings.menuBarMode = .manual([fiveHour, week])
        try harness.settingsStore.replace(with: settings).get()
        await prepareRatePublishing(harness)

        await publishRate(
            .fresh(try Self.catalog(identities: [fiveHour]), clock.now()),
            to: harness
        )
        await assertEventually {
            harness.settingsStore.retiredWindowSelections.map(\.identity)
                == [week]
        }

        clock.advance(days: 29)
        await publishRate(
            .fresh(
                try Self.catalog(identities: [fiveHour, week]),
                clock.now()
            ),
            to: harness
        )

        await assertEventually {
            harness.settingsStore.retiredWindowSelections.isEmpty
        }
        XCTAssertEqual(
            harness.settingsStore.settings.menuBarMode,
            .manual([fiveHour, week])
        )
    }

    func testNewFreshCatalogExpiresSelectionAfterThirtyOneDays() async throws {
        let clock = LifecycleSettingsClock(
            Date(timeIntervalSince1970: 1_700_000_000)
        )
        let harness = LifecycleHarness(settingsNow: clock.now)
        let fiveHour = Self.identity(.primary, 300)
        let week = Self.identity(.secondary, 10_080)
        var settings = harness.settingsStore.settings
        settings.menuBarMode = .manual([fiveHour, week])
        try harness.settingsStore.replace(with: settings).get()
        await prepareRatePublishing(harness)
        let catalog = try Self.catalog(identities: [fiveHour])

        await publishRate(.fresh(catalog, clock.now()), to: harness)
        await assertEventually {
            harness.settingsStore.retiredWindowSelections.map(\.identity)
                == [week]
        }

        clock.advance(days: 31)
        await publishRate(.fresh(catalog, clock.now()), to: harness)

        await assertEventually {
            harness.settingsStore.settings.menuBarMode == .manual([fiveHour])
                && harness.settingsStore.retiredWindowSelections.isEmpty
        }
    }

    func testSettingsObservationDoesNotReconcileTheSameFreshSnapshotAgain()
        async throws
    {
        let clock = LifecycleSettingsClock(
            Date(timeIntervalSince1970: 1_700_000_000)
        )
        let harness = LifecycleHarness(settingsNow: clock.now)
        let fiveHour = Self.identity(.primary, 300)
        let week = Self.identity(.secondary, 10_080)
        var settings = harness.settingsStore.settings
        settings.menuBarMode = .manual([fiveHour, week])
        try harness.settingsStore.replace(with: settings).get()
        await prepareRatePublishing(harness)

        await publishRate(
            .fresh(try Self.catalog(identities: [fiveHour]), clock.now()),
            to: harness
        )
        await assertEventually {
            harness.settingsStore.retiredWindowSelections.map(\.identity)
                == [week]
        }
        await drainObservationTasks()

        clock.advance(days: 31)
        let presentationCount = harness.status.presentations.count
        settings = harness.settingsStore.settings
        settings.percentageMode = .used
        try harness.settingsStore.replace(with: settings).get()
        await assertEventually {
            harness.status.presentations.count > presentationCount
        }

        XCTAssertEqual(
            harness.settingsStore.settings.menuBarMode,
            .manual([fiveHour, week])
        )
        XCTAssertEqual(
            harness.settingsStore.retiredWindowSelections.map(\.identity),
            [week]
        )
    }

    func testNonFreshRateStatesNeverRetireManualSelections() async throws {
        let clock = LifecycleSettingsClock(
            Date(timeIntervalSince1970: 1_700_000_000)
        )
        let harness = LifecycleHarness(settingsNow: clock.now)
        let fiveHour = Self.identity(.primary, 300)
        let week = Self.identity(.secondary, 10_080)
        var settings = harness.settingsStore.settings
        settings.menuBarMode = .manual([fiveHour, week])
        try harness.settingsStore.replace(with: settings).get()
        await prepareRatePublishing(harness)
        let partialCatalog = try Self.catalog(identities: [fiveHour])
        let nonFreshStates: [CapabilityState<RateLimitCatalog>] = [
            .stale(partialCatalog, clock.now(), .stale),
            .unsupported,
            .unavailable(.temporaryTransport),
            .loading,
        ]

        for state in nonFreshStates {
            await publishRate(state, to: harness)
            await drainObservationTasks()
            XCTAssertEqual(
                harness.settingsStore.settings.menuBarMode,
                .manual([fiveHour, week])
            )
            XCTAssertTrue(
                harness.settingsStore.retiredWindowSelections.isEmpty
            )
        }
    }

    func testTerminateDuringBlockedStartPersistsStopsMonitorThenQueuesStopAndReply() async {
        let gate = AsyncGate()
        let refresh = RecordingRefreshLifecycle(startGate: gate)
        let harness = LifecycleHarness(refresh: refresh)
        var replyCount = 0
        harness.coordinator.start()
        await assertEventually {
            await refresh.eventsSnapshot() == ["start:1"]
        }

        harness.coordinator.terminate {
            replyCount += 1
        }

        XCTAssertEqual(harness.panel.persistCount, 1)
        XCTAssertEqual(harness.monitor.stopCount, 1)
        XCTAssertEqual(replyCount, 0)
        var events = await refresh.eventsSnapshot()
        XCTAssertEqual(events, ["start:1"])

        await gate.open()
        await assertEventually { replyCount == 1 }
        events = await refresh.eventsSnapshot()
        XCTAssertEqual(events, ["start:1", "stop"])
        XCTAssertEqual(harness.panel.persistCount, 1)
        XCTAssertEqual(harness.monitor.stopCount, 1)
    }

    func testStatusShowAfterTerminateHidesPanelAndDoesNotQueueRefresh() async {
        let gate = AsyncGate()
        let refresh = RecordingRefreshLifecycle(startGate: gate)
        let harness = LifecycleHarness(refresh: refresh)
        var replyCount = 0
        harness.coordinator.start()
        await assertEventually {
            await refresh.eventsSnapshot() == ["start:1"]
        }

        harness.coordinator.terminate {
            replyCount += 1
        }
        harness.status.invokePrimaryShow()

        XCTAssertFalse(harness.panel.isVisible)
        XCTAssertEqual(harness.panel.showCount, 1)
        XCTAssertEqual(harness.panel.hideCount, 1)
        let eventsWhileBlocked = await refresh.eventsSnapshot()
        XCTAssertEqual(eventsWhileBlocked, ["start:1"])

        await gate.open()
        await assertEventually { replyCount == 1 }
        let finalEvents = await refresh.eventsSnapshot()
        XCTAssertEqual(finalEvents, ["start:1", "stop"])
    }

    func testTerminateDismissesThemeEditorSynchronouslyBeforeBlockedRefreshCleanupAndReply()
        async
    {
        let gate = AsyncGate()
        let refresh = RecordingRefreshLifecycle(startGate: gate)
        let harness = LifecycleHarness(refresh: refresh)
        var replyCount = 0
        harness.coordinator.start()
        await assertEventually {
            await refresh.eventsSnapshot() == ["start:1"]
        }

        harness.coordinator.terminate {
            replyCount += 1
        }

        XCTAssertEqual(harness.themeEditorPresenter.dismissCount, 1)
        XCTAssertEqual(replyCount, 0)
        let eventsBeforeCleanup = await refresh.eventsSnapshot()
        XCTAssertEqual(eventsBeforeCleanup, ["start:1"])

        await gate.open()
        await assertEventually { replyCount == 1 }
        let eventsAfterCleanup = await refresh.eventsSnapshot()
        XCTAssertEqual(eventsAfterCleanup, ["start:1", "stop"])
        XCTAssertEqual(harness.themeEditorPresenter.dismissCount, 1)
    }

    func testDuplicateTerminateDoesNotRepeatCleanupOrReply() async {
        let harness = LifecycleHarness()
        var firstReplyCount = 0
        var secondReplyCount = 0
        harness.coordinator.start()

        harness.coordinator.terminate {
            firstReplyCount += 1
        }
        harness.coordinator.terminate {
            secondReplyCount += 1
        }

        await assertEventually { firstReplyCount == 1 }
        XCTAssertEqual(secondReplyCount, 0)
        XCTAssertEqual(harness.panel.persistCount, 1)
        XCTAssertEqual(harness.monitor.stopCount, 1)
        let events = await harness.refresh.eventsSnapshot()
        XCTAssertEqual(events, ["start:1", "stop"])
    }

    func testTerminateHidesTheRetainedSettingsWindow() {
        let harness = LifecycleHarness()
        harness.coordinator.start()

        harness.coordinator.terminate {}

        XCTAssertEqual(harness.settingsPresenter.hideCount, 1)
    }

    func testTwoCoordinatorsNeverShareLastGoodQuotaState() async throws {
        let first = LifecycleHarness()
        let second = LifecycleHarness()
        first.coordinator.start()
        second.coordinator.start()
        let generation = GenerationToken(auth: 1, session: 1, connection: 1)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let catalog = try Self.catalog(usedPercent: 37)

        await first.quotaStore.apply(
            RefreshPublication(
                sequence: 1,
                generation: generation,
                change: .reset
            )
        )
        await first.quotaStore.apply(
            RefreshPublication(
                sequence: 1,
                generation: generation,
                change: .rate(.fresh(catalog, date))
            )
        )

        XCTAssertFalse(first.quotaStore === second.quotaStore)
        XCTAssertEqual(first.quotaStore.rateState, .fresh(catalog, date))
        XCTAssertEqual(second.quotaStore.rateState, .loading)
        XCTAssertNil(second.quotaStore.rateLastSuccessAt)
    }

    func testMonitorStartStopTokensAreIdempotentAndScreenIsIndependent() {
        let notificationCenter = NotificationCenter()
        let workspaceCenter = NotificationCenter()
        let names = SessionLifecycleMonitor.NotificationNames.testing("tokens")
        var screens = 0
        var inactive = 0
        var active = 0
        let monitor = SessionLifecycleMonitor(
            notificationCenter: notificationCenter,
            workspaceNotificationCenter: workspaceCenter,
            names: names,
            callbacks: SessionLifecycleCallbacks(
                screenParametersChanged: { screens += 1 },
                effectiveSessionResigned: { inactive += 1 },
                effectiveSessionBecameActive: { active += 1 }
            )
        )

        monitor.start()
        monitor.start()
        notificationCenter.post(name: names.screenParametersChanged, object: nil)

        XCTAssertEqual(screens, 1)
        XCTAssertEqual(inactive, 0)
        XCTAssertEqual(active, 0)

        monitor.stop()
        monitor.stop()
        notificationCenter.post(name: names.screenParametersChanged, object: nil)
        workspaceCenter.post(name: names.systemWillSleep, object: nil)
        workspaceCenter.post(name: names.systemDidWake, object: nil)

        XCTAssertEqual(screens, 1)
        XCTAssertEqual(inactive, 0)
        XCTAssertEqual(active, 0)
    }

    func testMonitorDeduplicatesEffectiveSleepWakeEdges() {
        let notificationCenter = NotificationCenter()
        let workspaceCenter = NotificationCenter()
        let names = SessionLifecycleMonitor.NotificationNames.testing("sleep")
        var events: [String] = []
        let monitor = SessionLifecycleMonitor(
            notificationCenter: notificationCenter,
            workspaceNotificationCenter: workspaceCenter,
            names: names,
            callbacks: SessionLifecycleCallbacks(
                screenParametersChanged: {},
                effectiveSessionResigned: { events.append("resign") },
                effectiveSessionBecameActive: { events.append("active") }
            )
        )
        monitor.start()

        workspaceCenter.post(name: names.systemWillSleep, object: nil)
        workspaceCenter.post(name: names.systemWillSleep, object: nil)
        workspaceCenter.post(name: names.systemDidWake, object: nil)
        workspaceCenter.post(name: names.systemDidWake, object: nil)

        XCTAssertEqual(events, ["resign", "active"])
    }

    func testMonitorDoesNotWakeEffectiveSessionUntilNestedResignEnds() {
        let notificationCenter = NotificationCenter()
        let workspaceCenter = NotificationCenter()
        let names = SessionLifecycleMonitor.NotificationNames.testing("nested")
        var events: [String] = []
        let monitor = SessionLifecycleMonitor(
            notificationCenter: notificationCenter,
            workspaceNotificationCenter: workspaceCenter,
            names: names,
            callbacks: SessionLifecycleCallbacks(
                screenParametersChanged: {},
                effectiveSessionResigned: { events.append("resign") },
                effectiveSessionBecameActive: { events.append("active") }
            )
        )
        monitor.start()

        workspaceCenter.post(name: names.sessionDidResignActive, object: nil)
        workspaceCenter.post(name: names.systemWillSleep, object: nil)
        workspaceCenter.post(name: names.systemDidWake, object: nil)
        XCTAssertEqual(events, ["resign"])

        workspaceCenter.post(name: names.sessionDidBecomeActive, object: nil)
        workspaceCenter.post(name: names.sessionDidBecomeActive, object: nil)
        XCTAssertEqual(events, ["resign", "active"])
    }

    private func assertEventually(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping () async -> Bool
    ) async {
        for _ in 0..<1_000 {
            if await condition() {
                return
            }
            await Task.yield()
        }
        XCTFail("Condition did not become true", file: file, line: line)
    }

    private func prepareRatePublishing(_ harness: LifecycleHarness) async {
        await harness.quotaStore.apply(
            RefreshPublication(
                sequence: 1,
                generation: Self.rateGeneration,
                change: .reset
            )
        )
        harness.coordinator.start()
    }

    private func publishRate(
        _ state: CapabilityState<RateLimitCatalog>,
        to harness: LifecycleHarness
    ) async {
        await harness.quotaStore.apply(
            RefreshPublication(
                sequence: 1,
                generation: Self.rateGeneration,
                change: .rate(state)
            )
        )
    }

    private func drainObservationTasks() async {
        for _ in 0..<20 {
            await Task.yield()
        }
    }

    private static let rateGeneration = GenerationToken(
        auth: 1,
        session: 1,
        connection: 1
    )

    private static func identity(
        _ sourceSlot: SourceSlot,
        _ durationMinutes: Int64
    ) -> WindowIdentity {
        WindowIdentity(
            bucketKey: "codex",
            sourceSlot: sourceSlot,
            durationMinutes: durationMinutes
        )
    }

    private static func catalog(
        identities: [WindowIdentity]
    ) throws -> RateLimitCatalog {
        let windows = try identities.enumerated().map { index, identity in
            try RateLimitWindow(
                identity: identity,
                usedPercent: 10 + index,
                resetsAt: 1_700_100_000 + Int64(index)
            )
        }
        let grouped = Dictionary(grouping: windows) {
            $0.identity.bucketKey
        }
        let buckets = Dictionary(
            uniqueKeysWithValues: grouped.keys
                .filter { $0 != RateLimitCatalog.legacyBucketKey }
                .sorted()
                .map { bucketKey in
                    (
                        bucketKey,
                        RateLimitBucket(
                            bucketKey: bucketKey,
                            windows: grouped[bucketKey] ?? []
                        )
                    )
                }
        )
        return RateLimitCatalog(
            rateLimitsByLimitId: buckets,
            legacyBucket: RateLimitBucket(
                bucketKey: RateLimitCatalog.legacyBucketKey,
                windows: grouped[RateLimitCatalog.legacyBucketKey] ?? []
            )
        )
    }

    private static func catalog(usedPercent: Int) throws -> RateLimitCatalog {
        let window = try RateLimitWindow(
            identity: WindowIdentity(
                bucketKey: "codex",
                sourceSlot: .primary,
                durationMinutes: 300
            ),
            usedPercent: usedPercent,
            resetsAt: 1_700_100_000
        )
        let bucket = RateLimitBucket(bucketKey: "codex", windows: [window])
        return RateLimitCatalog(
            rateLimitsByLimitId: ["codex": bucket],
            legacyBucket: bucket
        )
    }

    private static func providerSnapshot(
        _ providerID: ProviderID,
        remaining: Double,
        metricKey: ProviderMetricKey? = nil
    ) throws -> ProviderSnapshot {
        let key = try XCTUnwrap(
            metricKey ?? ProviderMetricKey(
                providerID: providerID,
                stableID: "lifecycle-primary"
            )
        )
        let metric = try XCTUnwrap(ProviderMetric(
            providerID: providerID,
            metricKey: key,
            remainingFraction: remaining,
            resetAt: nil,
            durationMinutes: 300
        ))
        return try XCTUnwrap(ProviderSnapshot(
            providerID: providerID,
            metrics: [metric],
            capturedAt: Date()
        ))
    }
}

@MainActor
private final class LifecycleHarness {
    let quotaStore = QuotaStore()
    let providerDashboardStore = ProviderDashboardStore()
    let settingsStore: SettingsStore
    let localizationModel = AppLocalizationRuntimeModel(
        language: .system,
        systemLocale: Locale(identifier: "en_US")
    )
    let themeEditorPresenter = FakeLifecycleThemeEditorPresenter()
    let panel = FakeLifecyclePanel()
    let status = FakeStatusSurface()
    let settingsPresenter = FakeSettingsSurfacePresenter()
    let monitor = FakeSessionLifecycleMonitor()
    let onboardingSurface = FakeLifecycleOnboardingSurface()
    let refresh: RecordingRefreshLifecycle

    private(set) var runtimeFactoryCount = 0
    private(set) var panelFactoryCount = 0
    private(set) var statusFactoryCount = 0
    private(set) var settingsFactoryCount = 0
    private(set) var monitorFactoryCount = 0
    private(set) var quitRequestCount = 0
    private(set) var manualRefreshRequestCount = 0
    private(set) var onboardingController: OnboardingController?
    private var panelSettingsAction: (@MainActor () -> Void)?
    private var panelViewModel: QuotaViewModel?
    private let includesProviderDashboardStore: Bool
    private let providerRuntime: (any ProviderRuntimeCoordinating)?
    private let includesPendingOnboarding: Bool

    init(
        refresh: RecordingRefreshLifecycle = RecordingRefreshLifecycle(),
        settingsNow: @escaping @Sendable () -> Date = Date.init,
        includesProviderDashboardStore: Bool = false,
        providerRuntime: (any ProviderRuntimeCoordinating)? = nil,
        includesPendingOnboarding: Bool = false
    ) {
        self.refresh = refresh
        self.includesProviderDashboardStore = includesProviderDashboardStore
        self.providerRuntime = providerRuntime
        self.includesPendingOnboarding = includesPendingOnboarding
        settingsStore = SettingsStore(
            fileURL: URL(
                fileURLWithPath: "/tmp/lifecycle-settings-\(UUID().uuidString).json"
            ),
            fileStore: EmptySettingsFileStore(),
            now: settingsNow
        )
    }

    private lazy var runtimeViewModel = QuotaViewModel(
        store: quotaStore,
        requestManualRefresh: { [weak self] in
            self?.manualRefreshRequestCount += 1
        }
    )

    lazy var coordinator = AppLifecycleCoordinator(
        runtimeFactory: { [unowned self] in
            runtimeFactoryCount += 1
            return AppLifecycleRuntime(
                viewModel: runtimeViewModel,
                initialRateState: quotaStore.rateState,
                quotaStore: quotaStore,
                providerDashboardStore: includesProviderDashboardStore
                    ? providerDashboardStore
                    : nil,
                settingsStore: settingsStore,
                providerRuntime: providerRuntime,
                refreshCoordinator: refresh,
                loginItemService: includesPendingOnboarding
                    ? FakeLifecycleLoginItemService()
                    : nil,
                settingsDependencies: SettingsRuntimeDependencies(
                    localizationModel: localizationModel,
                    themeService: PlaceholderThemeSettingsService(),
                    themeEditorPresenter: themeEditorPresenter,
                    installedVersionProvider:
                        UnavailableInstalledCodexVersionProvider(),
                    diagnosticsCopier: NoopLifecycleDiagnosticsCopier(),
                    loginItemSettingsOpener:
                        UnavailableLoginItemSettingsOpener()
                )
            )
        },
        panelFactory: { [unowned self] _, viewModel, _, showSettings, _ in
            panelFactoryCount += 1
            panelSettingsAction = showSettings
            panelViewModel = viewModel
            return panel
        },
        statusControllerFactory: { [unowned self] panel, actions in
            statusFactoryCount += 1
            status.install(panel: panel, actions: actions)
            return status
        },
        settingsPresenterFactory: { [unowned self] _ in
            settingsFactoryCount += 1
            return settingsPresenter
        },
        lifecycleMonitorFactory: { [unowned self] callbacks in
            monitorFactoryCount += 1
            monitor.callbacks = callbacks
            return monitor
        },
        onboardingFactory: { [unowned self] controller in
            onboardingController = controller
            onboardingSurface.controller = controller
            return onboardingSurface
        },
        requestQuit: { [weak self] in
            self?.quitRequestCount += 1
        }
    )

    func invokePanelSettings() {
        panelSettingsAction?()
    }


    func invokePanelRefresh() {
        panelViewModel?.triggerRefresh()
    }
}

private actor FakeLifecycleLoginItemService: LoginItemServicing {
    func status() -> LoginItemStatus { .notRegistered }
    func register() throws {}
    func unregister() throws {}
}

@MainActor
private final class FakeLifecycleOnboardingSurface:
    OnboardingSurfacePresenting
{
    weak var controller: OnboardingController?
    private(set) var showCount = 0
    private(set) var hideCount = 0
    var isPending: Bool { controller?.isPending ?? true }

    func show() {
        showCount += 1
    }

    func hide() {
        hideCount += 1
    }

}

private struct EmptySettingsFileStore: SettingsFileStoring {
    func read(from url: URL) throws -> Data? {
        nil
    }

    func write(
        _ data: Data,
        to url: URL,
        options: Data.WritingOptions
    ) throws {}
}

@MainActor
private final class FakeLifecyclePanel: LifecyclePanelPresenting {
    private(set) var isVisible = false
    var isOnActiveSpace = true
    private(set) var showCount = 0
    private(set) var hideCount = 0
    private(set) var persistCount = 0
    private(set) var clampCount = 0
    private(set) var policies: [SpacePolicy] = []
    private(set) var providerCounts: [Int] = []

    func show() {
        showCount += 1
        isVisible = true
    }

    func hide() {
        hideCount += 1
        isVisible = false
    }

    func persistCurrentFrame() {
        persistCount += 1
    }

    func clampToScreen() {
        clampCount += 1
    }

    func setSpacePolicy(_ policy: SpacePolicy) {
        policies.append(policy)
    }

    func setProviderCount(_ count: Int) {
        providerCounts.append(count)
    }
}

@MainActor
private final class FakeStatusSurface: StatusSurfaceControlling {
    private(set) var panel: (any LifecyclePanelPresenting)?
    private var actions: AppLifecycleActions?
    private(set) var configureCount = 0
    private(set) var presentations: [StatusItemPresentation] = []

    func install(
        panel: any LifecyclePanelPresenting,
        actions: AppLifecycleActions
    ) {
        self.panel = panel
        self.actions = actions
    }

    func configure(initialPresentation: StatusItemPresentation) {
        configureCount += 1
        presentations.append(initialPresentation)
    }

    func updatePresentation(_ presentation: StatusItemPresentation) {
        presentations.append(presentation)
    }

    func showRecoverySurface() {
        panel?.show()
        actions?.panelShown()
    }

    func invokePrimaryShow() {
        panel?.show()
        actions?.panelShown()
    }

    func invokeSettings() {
        actions?.showSettings()
    }

    func invokeRefresh() {
        actions?.refresh()
    }

    func invokeQuit() {
        actions?.quit()
    }
}

@MainActor
private final class FakeSettingsSurfacePresenter: SettingsSurfacePresenting {
    private(set) var showCount = 0
    private(set) var hideCount = 0

    func showSettings() {
        showCount += 1
    }

    func hideSettings() {
        hideCount += 1
    }
}

@MainActor
private final class FakeLifecycleThemeEditorPresenter: ThemeEditorPresenting {
    private(set) var dismissCount = 0

    func show() {}

    func dismissForTermination() {
        dismissCount += 1
    }
}

@MainActor
private final class NoopLifecycleDiagnosticsCopier: DiagnosticsCopying {
    func copy(_ text: String) {}
}

@MainActor
private final class FakeSessionLifecycleMonitor: SessionLifecycleMonitoring {
    var callbacks: SessionLifecycleCallbacks?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start() {
        startCount += 1
    }

    func stop() {
        stopCount += 1
    }
}

private actor RecordingRefreshLifecycle: RefreshLifecycleCoordinating {
    private let startGate: AsyncGate?
    private var events: [String] = []

    init(startGate: AsyncGate? = nil) {
        self.startGate = startGate
    }

    func start(sessionGeneration: UInt64) async {
        events.append("start:\(sessionGeneration)")
        if let startGate {
            await startGate.wait()
        }
    }

    func sessionResigned() async {
        events.append("resign")
    }

    func sessionBecameActive() async {
        events.append("active")
    }

    func panelOpened() async {
        events.append("panel")
    }

    func stop() async {
        events.append("stop")
    }

    func eventsSnapshot() -> [String] {
        events
    }
}

@MainActor
private final class RecordingProviderRuntime: ProviderRuntimeCoordinating {
    private let stopGate: AsyncGate
    private var events: [String] = []

    init(stopGate: AsyncGate) {
        self.stopGate = stopGate
    }

    func start() {
        events.append("start")
    }

    func sessionResigned() async {
        events.append("resign")
    }

    func sessionBecameActive() async {
        events.append("active")
    }

    func panelOpened() async {
        events.append("panel")
    }

    func manualRefresh() async {
        events.append("manual")
    }

    func stopAndWait() async {
        events.append("stop-begin")
        await stopGate.wait()
        events.append("stop-finished")
    }

    func eventsSnapshot() -> [String] {
        events
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else {
            return
        }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        guard !isOpen else {
            return
        }
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

private final class LifecycleSettingsClock: @unchecked Sendable {
    private var date: Date

    init(_ date: Date) {
        self.date = date
    }

    func now() -> Date {
        date
    }

    func advance(days: Int) {
        date = date.addingTimeInterval(TimeInterval(days) * 86_400)
    }
}

private extension SessionLifecycleMonitor.NotificationNames {
    static func testing(_ prefix: String) -> Self {
        Self(
            screenParametersChanged: Notification.Name("\(prefix).screen"),
            systemWillSleep: Notification.Name("\(prefix).sleep"),
            systemDidWake: Notification.Name("\(prefix).wake"),
            sessionDidResignActive: Notification.Name("\(prefix).resign"),
            sessionDidBecomeActive: Notification.Name("\(prefix).active")
        )
    }
}
