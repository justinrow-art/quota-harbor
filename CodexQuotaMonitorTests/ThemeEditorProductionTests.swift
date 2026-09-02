import CryptoKit
import XCTest
@testable import CodexQuotaMonitor

@MainActor
final class ThemeEditorProductionTests: XCTestCase {
    func testWindowControllerReusesAndFocusesOneWindowUntilItCloses() {
        let localizationModel = makeLocalizationModel()
        let factory = ThemeEditorWindowFactorySpy()
        var viewModelBuildCount = 0
        let controller = ThemeEditorWindowController(
            localizationModel: localizationModel,
            makeViewModel: {
                viewModelBuildCount += 1
                return Self.makeInertViewModel(
                    localizationModel: localizationModel
                )
            },
            windowFactory: factory.makeWindow
        )

        controller.show()
        controller.show()

        XCTAssertTrue(controller.isWindowOpen)
        XCTAssertEqual(viewModelBuildCount, 1)
        XCTAssertEqual(factory.windows.count, 1)
        XCTAssertEqual(factory.windows[0].showAndFocusCount, 2)

        factory.windows[0].simulateClose()
        XCTAssertFalse(controller.isWindowOpen)

        controller.show()
        XCTAssertEqual(viewModelBuildCount, 2)
        XCTAssertEqual(factory.windows.count, 2)
    }

    func testClosingEditorWindowCancelsTheOpenDraftExactlyOnce() {
        let localizationModel = makeLocalizationModel()
        let manager = CancelCountingThemeEditorManager()
        let viewModel = ThemeEditorViewModel(
            sourceTheme: BuiltInThemes.morandi.document,
            sourceBuiltInID: .morandi,
            manager: manager,
            picker: InertThemeEditorPicker(),
            localizationModel: localizationModel
        )
        let factory = ThemeEditorWindowFactorySpy()
        let controller = ThemeEditorWindowController(
            localizationModel: localizationModel,
            makeViewModel: { viewModel },
            windowFactory: factory.makeWindow
        )

        controller.show()
        factory.windows[0].simulateClose()

        XCTAssertEqual(manager.cancelCount, 1)
        XCTAssertTrue(viewModel.isCancelled)
    }

    func testOpenWindowUsesSharedLocalizationAndUpdatesTitleWithoutRebuild()
        async
    {
        let localizationModel = makeLocalizationModel(.english)
        let factory = ThemeEditorWindowFactorySpy()
        let controller = ThemeEditorWindowController(
            localizationModel: localizationModel,
            makeViewModel: {
                Self.makeInertViewModel(
                    localizationModel: localizationModel
                )
            },
            windowFactory: factory.makeWindow
        )

        controller.show()

        XCTAssertEqual(factory.windows.count, 1)
        XCTAssertTrue(factory.localizationModels[0] === localizationModel)
        XCTAssertTrue(
            factory.viewModels[0].localizationModel === localizationModel
        )
        XCTAssertEqual(
            factory.windows[0].titles.last,
            localizationModel.text.text(.themeEditorWindowTitle)
        )

        localizationModel.language = .japanese
        let didUpdate = await waitForWindowTitle(
            localizationModel.text.text(.themeEditorWindowTitle),
            in: factory.windows[0]
        )

        XCTAssertTrue(didUpdate)
        XCTAssertEqual(factory.windows.count, 1)
    }

    func testWindowControllerRejectsMismatchedLocalizationSources() {
        let controllerLocalization = makeLocalizationModel(.english)
        let viewModelLocalization = makeLocalizationModel(.japanese)
        let factory = ThemeEditorWindowFactorySpy()
        let controller = ThemeEditorWindowController(
            localizationModel: controllerLocalization,
            makeViewModel: {
                Self.makeInertViewModel(
                    localizationModel: viewModelLocalization
                )
            },
            windowFactory: factory.makeWindow
        )

        controller.show()

        XCTAssertFalse(controller.isWindowOpen)
        XCTAssertTrue(factory.windows.isEmpty)
    }

    func testDismissForTerminationClosesAndCancelsExactlyOnce() {
        let localizationModel = makeLocalizationModel()
        let manager = CancelCountingThemeEditorManager()
        let viewModel = ThemeEditorViewModel(
            sourceTheme: BuiltInThemes.morandi.document,
            sourceBuiltInID: .morandi,
            manager: manager,
            picker: InertThemeEditorPicker(),
            localizationModel: localizationModel
        )
        let factory = ThemeEditorWindowFactorySpy()
        let controller = ThemeEditorWindowController(
            localizationModel: localizationModel,
            makeViewModel: { viewModel },
            windowFactory: factory.makeWindow
        )
        controller.show()

        controller.dismissForTermination()
        controller.dismissForTermination()

        XCTAssertFalse(controller.isWindowOpen)
        XCTAssertEqual(factory.windows[0].closeCount, 1)
        XCTAssertEqual(manager.cancelCount, 1)
        XCTAssertTrue(viewModel.isCancelled)
    }

    func testTerminationDiscardsLateImportWithoutRefillingDraft() async {
        let localizationModel = makeLocalizationModel()
        let picker = SuspendedThemeEditorPicker()
        let manager = CancelCountingThemeEditorManager()
        let openingDraft = BuiltInThemes.morandi.document
        let imported = customDocument(id: UUID(), name: "Late import")
        let viewModel = ThemeEditorViewModel(
            sourceTheme: openingDraft,
            sourceBuiltInID: .morandi,
            manager: manager,
            picker: picker,
            localizationModel: localizationModel
        )
        let factory = ThemeEditorWindowFactorySpy()
        let controller = ThemeEditorWindowController(
            localizationModel: localizationModel,
            makeViewModel: { viewModel },
            windowFactory: factory.makeWindow
        )
        controller.show()
        let operation = Task { await viewModel.importTheme() }
        await picker.waitUntilImportStarted()

        controller.dismissForTermination()
        picker.resumeImport(returning: imported)
        await operation.value

        XCTAssertEqual(viewModel.draft, openingDraft)
        XCTAssertTrue(viewModel.isCancelled)
        XCTAssertFalse(viewModel.isBusy)
        XCTAssertNil(viewModel.operationState)
        XCTAssertEqual(manager.cancelCount, 1)
        XCTAssertEqual(factory.windows[0].closeCount, 1)
    }

    func testTerminationDiscardsLateRasterWithoutMutatingDraft() async {
        let localizationModel = makeLocalizationModel()
        let picker = SuspendedThemeEditorRasterPicker()
        let manager = CancelCountingThemeEditorManager()
        let openingDraft = BuiltInThemes.morandi.document
        let viewModel = ThemeEditorViewModel(
            sourceTheme: openingDraft,
            sourceBuiltInID: .morandi,
            manager: manager,
            picker: picker,
            localizationModel: localizationModel
        )
        let factory = ThemeEditorWindowFactorySpy()
        let controller = ThemeEditorWindowController(
            localizationModel: localizationModel,
            makeViewModel: { viewModel },
            windowFactory: factory.makeWindow
        )
        controller.show()
        let operation = Task { await viewModel.chooseRaster() }
        await picker.waitUntilRasterStarted()

        controller.dismissForTermination()
        picker.resumeRaster(
            returning: SanitizedRasterReference(
                relativeIdentifier: String(repeating: "b", count: 64) + ".png",
                sha256: String(repeating: "b", count: 64)
            )
        )
        await operation.value

        XCTAssertEqual(viewModel.draft, openingDraft)
        XCTAssertNil(viewModel.draft.rasterReference)
        XCTAssertTrue(viewModel.isCancelled)
        XCTAssertFalse(viewModel.isBusy)
        XCTAssertNil(viewModel.operationState)
        XCTAssertEqual(manager.cancelCount, 1)
        XCTAssertEqual(factory.windows[0].closeCount, 1)
    }

    func testPanelPromptsReadSharedLocalizationOnlyAtExplicitAction()
        async throws
    {
        let localizationModel = makeLocalizationModel(.english)
        let runner = ThemeEditorPanelRunnerSpy()
        let adapter = SystemThemeEditorPanelAdapter(
            localizationModel: localizationModel,
            runPanel: runner.run
        )

        XCTAssertTrue(adapter.localizationModel === localizationModel)
        XCTAssertTrue(runner.calls.isEmpty)

        _ = try await adapter.pickRasterSelection()
        XCTAssertEqual(
            runner.calls.last,
            .init(
                kind: .raster,
                prompt: localizationModel.text.text(
                    .themeEditorPanelChooseImage
                )
            )
        )

        localizationModel.language = .japanese
        _ = try await adapter.pickThemeImportData()
        XCTAssertEqual(
            runner.calls.last,
            .init(
                kind: .importTheme,
                prompt: localizationModel.text.text(
                    .themeEditorPanelImportTheme
                )
            )
        )

        localizationModel.language = .german
        _ = try await adapter.writeThemeExportData(Data())
        XCTAssertEqual(
            runner.calls.last,
            .init(
                kind: .exportTheme,
                prompt: localizationModel.text.text(
                    .themeEditorPanelExportTheme
                )
            )
        )
        XCTAssertEqual(runner.calls.count, 3)
    }

    func testSessionConstructionAndViewModelCreationDoNotInvokePanels() throws {
        let harness = try makeStoreHarness()
        let panels = ThemeEditorPanelAdapterSpy()
        let rasterPicker = ThemeRasterPickerSpy()
        let localizationModel = makeLocalizationModel(.english)
        let session = try ProductionThemeEditorSession(
            store: harness.store,
            localizationModel: localizationModel,
            panelAdapter: panels,
            rasterPicker: rasterPicker,
            stagingRoot: harness.root,
            stagingDirectory: harness.root.appendingPathComponent("Session"),
            makeUUID: { UUID() }
        )

        let viewModel = session.makeViewModel(
            sourceTheme: BuiltInThemes.morandi.document,
            sourceBuiltInID: .morandi
        )

        XCTAssertTrue(session.localizationModel === localizationModel)
        XCTAssertTrue(viewModel.localizationModel === localizationModel)
        XCTAssertEqual(panels.rasterPickCount, 0)
        XCTAssertEqual(panels.importPickCount, 0)
        XCTAssertEqual(panels.exportWriteCount, 0)
        XCTAssertEqual(rasterPicker.pickCount, 0)
    }

    func testSessionRejectsStagingOutsideOwnedRootWithoutDeletingIt()
        throws
    {
        let harness = try makeStoreHarness()
        let ownedRoot = harness.root.appendingPathComponent("OwnedStaging")
        let outside = harness.root.appendingPathComponent("External")
        let marker = outside.appendingPathComponent("keep.txt")
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true
        )
        try Data("keep".utf8).write(to: marker)

        XCTAssertThrowsError(
            try ProductionThemeEditorSession(
                store: harness.store,
                localizationModel: makeLocalizationModel(),
                panelAdapter: ThemeEditorPanelAdapterSpy(),
                rasterPicker: ThemeRasterPickerSpy(),
                stagingRoot: ownedRoot,
                stagingDirectory: outside
            )
        ) { error in
            XCTAssertEqual(
                error as? ThemeEditorStagingError,
                .outsideOwnedRoot
            )
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func testImportChangesOnlyDraftAndCancelLeavesThemeStoreUntouched()
        async throws
    {
        let harness = try makeStoreHarness()
        let panels = ThemeEditorPanelAdapterSpy()
        let imported = customDocument(
            id: UUID(uuidString: "10000000-0000-4000-8000-000000000001")!,
            name: "Imported draft"
        )
        panels.importData = try ThemeImportExportService().exportTheme(
            imported,
            rasterPNG: nil,
            includeRaster: false
        )
        let session = try ProductionThemeEditorSession(
            store: harness.store,
            localizationModel: makeLocalizationModel(),
            panelAdapter: panels,
            rasterPicker: ThemeRasterPickerSpy(),
            stagingRoot: harness.root,
            stagingDirectory: harness.root.appendingPathComponent("Session"),
            makeUUID: { UUID() }
        )
        let viewModel = session.makeViewModel(
            sourceTheme: BuiltInThemes.morandi.document,
            sourceBuiltInID: .morandi
        )
        let before = harness.store.snapshot

        await viewModel.importTheme()

        XCTAssertEqual(viewModel.draft, imported)
        XCTAssertEqual(harness.store.snapshot, before)
        XCTAssertEqual(panels.importPickCount, 1)

        viewModel.cancel()
        XCTAssertEqual(harness.store.snapshot, before)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: session.stagingDirectory.path
            )
        )
    }

    func testPendingRasterCommitsWithThemeAndActivationInOneStoreSave()
        async throws
    {
        let harness = try makeStoreHarness()
        let panels = ThemeEditorPanelAdapterSpy()
        let rasterPicker = ThemeRasterPickerSpy()
        let pending = pendingRaster(Data("sanitized-png".utf8))
        rasterPicker.result = pending
        let customID = UUID(
            uuidString: "20000000-0000-4000-8000-000000000002"
        )!
        let session = try ProductionThemeEditorSession(
            store: harness.store,
            localizationModel: makeLocalizationModel(),
            panelAdapter: panels,
            rasterPicker: rasterPicker,
            stagingRoot: harness.root,
            stagingDirectory: harness.root.appendingPathComponent("Session"),
            makeUUID: { customID }
        )
        let viewModel = session.makeViewModel(
            sourceTheme: BuiltInThemes.morandi.document,
            sourceBuiltInID: .morandi
        )
        let before = harness.store.snapshot
        viewModel.duplicateBuiltIn(named: "Raster draft")

        await viewModel.chooseRaster()

        XCTAssertEqual(harness.store.snapshot, before)
        XCTAssertEqual(viewModel.draft.rasterReference, pending.reference)

        viewModel.save(activate: true)

        XCTAssertEqual(
            harness.store.snapshot.activeSelection,
            .custom(customID)
        )
        XCTAssertEqual(
            harness.store.snapshot.customThemes.first?.rasterReference,
            pending.reference
        )
        XCTAssertEqual(
            try harness.store.rasterData(for: pending.reference),
            pending.pngData
        )
    }

    func testPendingRasterDrivesLivePreviewAndRemoveRestoresFallback()
        async throws
    {
        let harness = try makeStoreHarness()
        let rasterPicker = ThemeRasterPickerSpy()
        let pending = pendingRaster(Data("live-preview-png".utf8))
        rasterPicker.result = pending
        let session = try ProductionThemeEditorSession(
            store: harness.store,
            localizationModel: makeLocalizationModel(),
            panelAdapter: ThemeEditorPanelAdapterSpy(),
            rasterPicker: rasterPicker,
            stagingRoot: harness.root,
            stagingDirectory: harness.root.appendingPathComponent("Session")
        )
        let viewModel = session.makeViewModel(
            sourceTheme: BuiltInThemes.morandi.document,
            sourceBuiltInID: .morandi
        )

        await viewModel.chooseRaster()

        XCTAssertEqual(viewModel.previewRasterData, pending.pngData)
        XCTAssertEqual(viewModel.draft.rasterReference, pending.reference)

        viewModel.removeRaster()

        XCTAssertNil(viewModel.previewRasterData)
        XCTAssertNil(viewModel.draft.rasterReference)
    }

    func testPendingRasterDigestMismatchNeverReachesLivePreview()
        async throws
    {
        let harness = try makeStoreHarness()
        let rasterPicker = ThemeRasterPickerSpy()
        let valid = pendingRaster(Data("expected-png".utf8))
        rasterPicker.result = PendingSanitizedThemeRaster(
            reference: valid.reference,
            pngData: Data("tampered-png".utf8)
        )
        let session = try ProductionThemeEditorSession(
            store: harness.store,
            localizationModel: makeLocalizationModel(),
            panelAdapter: ThemeEditorPanelAdapterSpy(),
            rasterPicker: rasterPicker,
            stagingRoot: harness.root,
            stagingDirectory: harness.root.appendingPathComponent("Session")
        )
        let viewModel = session.makeViewModel(
            sourceTheme: BuiltInThemes.morandi.document,
            sourceBuiltInID: .morandi
        )

        await viewModel.chooseRaster()

        XCTAssertNil(viewModel.previewRasterData)
        XCTAssertNil(viewModel.draft.rasterReference)
        XCTAssertEqual(viewModel.operationState, .imageUnsafe)
    }

    func testExportIncludesPendingRasterOnlyWithExplicitConsent()
        async throws
    {
        let harness = try makeStoreHarness()
        let panels = ThemeEditorPanelAdapterSpy()
        let rasterPicker = ThemeRasterPickerSpy()
        let pending = pendingRaster(Data("pending-export-png".utf8))
        rasterPicker.result = pending
        let session = try ProductionThemeEditorSession(
            store: harness.store,
            localizationModel: makeLocalizationModel(),
            panelAdapter: panels,
            rasterPicker: rasterPicker,
            stagingRoot: harness.root,
            stagingDirectory: harness.root.appendingPathComponent("Session"),
            makeUUID: {
                UUID(
                    uuidString: "30000000-0000-4000-8000-000000000003"
                )!
            }
        )
        let viewModel = session.makeViewModel(
            sourceTheme: BuiltInThemes.morandi.document,
            sourceBuiltInID: .morandi
        )
        viewModel.duplicateBuiltIn(named: "Export draft")
        await viewModel.chooseRaster()

        await viewModel.exportTheme()
        viewModel.includeRasterInExport = true
        await viewModel.exportTheme()

        XCTAssertEqual(panels.exportWriteCount, 2)
        let withoutConsent = try envelope(panels.exportedData[0])
        let withConsent = try envelope(panels.exportedData[1])
        XCTAssertNil(withoutConsent["raster"])
        XCTAssertNotNil(withConsent["raster"])
    }

    func testSessionCancelDiscardsLateRasterAndRemovesLateStaging()
        async throws
    {
        let harness = try makeStoreHarness()
        let staging = harness.root.appendingPathComponent("Session")
        let rasterPicker = SuspendedThemeRasterPicker()
        let session = try ProductionThemeEditorSession(
            store: harness.store,
            localizationModel: makeLocalizationModel(),
            panelAdapter: ThemeEditorPanelAdapterSpy(),
            rasterPicker: rasterPicker,
            stagingRoot: harness.root,
            stagingDirectory: staging
        )
        let before = harness.store.snapshot
        let pending = pendingRaster(Data("late-raster".utf8))
        let operation = Task {
            try await session.pickSanitizedRaster()
        }
        await rasterPicker.waitUntilStarted()

        session.cancelDraft()
        rasterPicker.resume(
            returning: pending,
            recreatingStagingAt: staging
        )

        let result = try await operation.value
        XCTAssertNil(result)
        XCTAssertEqual(harness.store.snapshot, before)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: staging.path)
        )
        var unsaved = customDocument(id: UUID(), name: "Late raster")
        unsaved.rasterReference = pending.reference
        XCTAssertThrowsError(
            try session.saveCustom(unsaved, activate: true)
        )
        XCTAssertEqual(harness.store.snapshot, before)
    }

    func testSessionCancelDiscardsLateImportBeforeStagingWork()
        async throws
    {
        let harness = try makeStoreHarness()
        let staging = harness.root.appendingPathComponent("Session")
        let panels = SuspendedThemeEditorPanelAdapter()
        let imported = customDocument(id: UUID(), name: "Late import")
        let data = try ThemeImportExportService().exportTheme(
            imported,
            rasterPNG: nil,
            includeRaster: false
        )
        let session = try ProductionThemeEditorSession(
            store: harness.store,
            localizationModel: makeLocalizationModel(),
            panelAdapter: panels,
            rasterPicker: ThemeRasterPickerSpy(),
            stagingRoot: harness.root,
            stagingDirectory: staging
        )
        let before = harness.store.snapshot
        let operation = Task {
            try await session.pickValidatedThemeForImport()
        }
        await panels.waitUntilImportStarted()

        session.cancelDraft()
        panels.resumeImport(returning: data)

        let result = try await operation.value
        XCTAssertNil(result)
        XCTAssertEqual(harness.store.snapshot, before)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: staging.path)
        )
    }

    func testWindowClosePreventsLateImportFromRefillingViewModelDraft()
        async
    {
        let localizationModel = makeLocalizationModel()
        let picker = SuspendedThemeEditorPicker()
        let manager = CancelCountingThemeEditorManager()
        let openingDraft = BuiltInThemes.morandi.document
        let imported = customDocument(id: UUID(), name: "Late view model")
        let viewModel = ThemeEditorViewModel(
            sourceTheme: openingDraft,
            sourceBuiltInID: .morandi,
            manager: manager,
            picker: picker,
            localizationModel: localizationModel
        )
        let factory = ThemeEditorWindowFactorySpy()
        let controller = ThemeEditorWindowController(
            localizationModel: localizationModel,
            makeViewModel: { viewModel },
            windowFactory: factory.makeWindow
        )
        controller.show()
        let operation = Task { await viewModel.importTheme() }
        await picker.waitUntilImportStarted()

        factory.windows[0].simulateClose()
        picker.resumeImport(returning: imported)
        await operation.value

        XCTAssertEqual(viewModel.draft, openingDraft)
        XCTAssertTrue(viewModel.isCancelled)
        XCTAssertFalse(viewModel.isBusy)
        XCTAssertNil(viewModel.operationMessage)
        XCTAssertEqual(manager.cancelCount, 1)
    }

    func testProductionCompositionUsesOwnedDirectChildStagingAndNoPanels()
        throws
    {
        let harness = try makeRuntimeHarness()
        let service = try ProductionThemeSettingsService(
            themeStore: harness.store,
            settingsStore: harness.settingsStore
        )
        let panels = ThemeEditorPanelAdapterSpy()
        let windows = ThemeEditorWindowFactorySpy()
        let localizationModel = makeLocalizationModel()
        let sessionID = UUID(
            uuidString: "40000000-0000-4000-8000-000000000004"
        )!

        let composition = try ProductionThemeEditorComposition.make(
            store: harness.store,
            runtimeModel: service.runtimeModel,
            stagingRoot: harness.root,
            panelAdapter: panels,
            windowFactory: windows.makeWindow,
            makeUUID: { sessionID },
            localizationModel: localizationModel
        )

        XCTAssertEqual(
            composition.stagingDirectory.deletingLastPathComponent(),
            harness.root.standardizedFileURL
        )
        XCTAssertEqual(
            composition.stagingDirectory.lastPathComponent,
            ".theme-editor-\(sessionID.uuidString)"
        )
        XCTAssertEqual(panels.rasterPickCount, 0)
        XCTAssertEqual(panels.importPickCount, 0)
        XCTAssertEqual(panels.exportWriteCount, 0)
        XCTAssertTrue(windows.windows.isEmpty)
        XCTAssertTrue(composition.localizationModel === localizationModel)
    }

    func testProductionPresenterStartImportOpensEditorAndInvokesImportPanel()
        async throws
    {
        let harness = try makeRuntimeHarness()
        let service = try ProductionThemeSettingsService(
            themeStore: harness.store,
            settingsStore: harness.settingsStore
        )
        let panels = ThemeEditorPanelAdapterSpy()
        let windows = ThemeEditorWindowFactorySpy()
        let composition = try ProductionThemeEditorComposition.make(
            store: harness.store,
            runtimeModel: service.runtimeModel,
            stagingRoot: harness.root,
            panelAdapter: panels,
            windowFactory: windows.makeWindow,
            localizationModel: makeLocalizationModel()
        )

        composition.presenter.startImport()

        let didInvokePanel = await waitUntil {
            panels.importPickCount == 1
        }
        XCTAssertTrue(didInvokePanel)
        XCTAssertEqual(windows.windows.count, 1)
    }

    func testProductionPresenterStartExportOpensEditorAndInvokesExportPanel()
        async throws
    {
        let harness = try makeRuntimeHarness()
        let service = try ProductionThemeSettingsService(
            themeStore: harness.store,
            settingsStore: harness.settingsStore
        )
        let panels = ThemeEditorPanelAdapterSpy()
        let windows = ThemeEditorWindowFactorySpy()
        let composition = try ProductionThemeEditorComposition.make(
            store: harness.store,
            runtimeModel: service.runtimeModel,
            stagingRoot: harness.root,
            panelAdapter: panels,
            windowFactory: windows.makeWindow,
            localizationModel: makeLocalizationModel()
        )

        composition.presenter.startExport()

        let didInvokePanel = await waitUntil {
            panels.exportWriteCount == 1
        }
        XCTAssertTrue(didInvokePanel)
        XCTAssertEqual(windows.windows.count, 1)
        XCTAssertFalse(panels.exportedData.first?.isEmpty ?? true)
    }

    func testEachCompositionOpenDraftsTheCurrentActiveSelection() throws {
        let harness = try makeRuntimeHarness()
        let service = try ProductionThemeSettingsService(
            themeStore: harness.store,
            settingsStore: harness.settingsStore
        )
        try service.selectTheme(id: BuiltInThemeID.glass.rawValue)
        let panels = ThemeEditorPanelAdapterSpy()
        let windows = ThemeEditorWindowFactorySpy()
        let localizationModel = makeLocalizationModel(.english)
        var identifiers = [
            UUID(uuidString: "50000000-0000-4000-8000-000000000005")!,
            UUID(uuidString: "60000000-0000-4000-8000-000000000006")!,
        ]
        let composition = try ProductionThemeEditorComposition.make(
            store: harness.store,
            runtimeModel: service.runtimeModel,
            stagingRoot: harness.root,
            panelAdapter: panels,
            windowFactory: windows.makeWindow,
            makeUUID: { identifiers.removeFirst() },
            localizationModel: localizationModel
        )

        composition.presenter.show()

        let builtInDraft = try XCTUnwrap(windows.viewModels.first)
        XCTAssertTrue(builtInDraft.localizationModel === localizationModel)
        XCTAssertTrue(windows.localizationModels[0] === localizationModel)
        XCTAssertEqual(builtInDraft.draft, BuiltInThemes.glass.document)
        builtInDraft.duplicateBuiltIn(named: "Glass copy")
        XCTAssertEqual(
            builtInDraft.draft.id,
            UUID(uuidString: "60000000-0000-4000-8000-000000000006")!
        )
        XCTAssertNil(builtInDraft.operationMessage)
        windows.windows[0].simulateClose()

        let custom = try harness.store.duplicateBuiltIn(
            .sketch,
            named: "Current custom"
        )
        try service.selectTheme(id: custom.id.uuidString)
        composition.presenter.show()

        let customDraft = try XCTUnwrap(windows.viewModels.last)
        XCTAssertEqual(customDraft.draft, custom)
        customDraft.duplicateBuiltIn(named: "Must not duplicate")
        XCTAssertEqual(customDraft.draft, custom)
        XCTAssertNotNil(customDraft.operationMessage)
        XCTAssertEqual(panels.rasterPickCount, 0)
        XCTAssertEqual(panels.importPickCount, 0)
        XCTAssertEqual(panels.exportWriteCount, 0)
    }

    func testProductionSaveActivateAndResetSynchronizeRuntimeAndSettings()
        throws
    {
        let harness = try makeRuntimeHarness()
        let service = try ProductionThemeSettingsService(
            themeStore: harness.store,
            settingsStore: harness.settingsStore
        )
        let windows = ThemeEditorWindowFactorySpy()
        var identifiers = [
            UUID(uuidString: "70000000-0000-4000-8000-000000000007")!,
            UUID(uuidString: "80000000-0000-4000-8000-000000000008")!,
        ]
        let composition = try ProductionThemeEditorComposition.make(
            store: harness.store,
            runtimeModel: service.runtimeModel,
            stagingRoot: harness.root,
            panelAdapter: ThemeEditorPanelAdapterSpy(),
            windowFactory: windows.makeWindow,
            makeUUID: { identifiers.removeFirst() },
            localizationModel: makeLocalizationModel()
        )
        var mutationCount = 0
        composition.mutations.setHandler { mutationCount += 1 }
        composition.presenter.show()
        let editor = try XCTUnwrap(windows.viewModels.first)
        editor.duplicateBuiltIn(named: "Synchronized custom")

        editor.save(activate: true)

        let customID = UUID(
            uuidString: "80000000-0000-4000-8000-000000000008"
        )!
        XCTAssertEqual(harness.store.snapshot.activeSelection, .custom(customID))
        XCTAssertEqual(service.runtimeModel.selection, .custom(customID))
        XCTAssertEqual(service.runtimeModel.currentTheme.id, customID)
        XCTAssertEqual(
            harness.settingsStore.settings.appearance.themeID,
            customID.uuidString
        )
        XCTAssertEqual(mutationCount, 1)

        editor.reset()

        XCTAssertEqual(harness.store.snapshot.activeSelection, .builtIn(.morandi))
        XCTAssertEqual(service.runtimeModel.selection, .builtIn(.morandi))
        XCTAssertEqual(
            service.runtimeModel.currentTheme,
            BuiltInThemes.morandi.document
        )
        XCTAssertEqual(
            harness.settingsStore.settings.appearance.themeID,
            BuiltInThemeID.morandi.rawValue
        )
        XCTAssertEqual(mutationCount, 2)
    }

    func testCompositionDraftUsesRuntimeSelectionWhenStoreActiveDiverges()
        throws
    {
        let harness = try makeRuntimeHarness()
        let service = try ProductionThemeSettingsService(
            themeStore: harness.store,
            settingsStore: harness.settingsStore
        )
        try harness.store.selectBuiltIn(.glass)
        XCTAssertEqual(service.runtimeModel.selection, .builtIn(.morandi))
        XCTAssertEqual(harness.store.snapshot.activeSelection, .builtIn(.glass))
        let windows = ThemeEditorWindowFactorySpy()
        let localizationModel = makeLocalizationModel(.english)
        let composition = try ProductionThemeEditorComposition.make(
            store: harness.store,
            runtimeModel: service.runtimeModel,
            stagingRoot: harness.root,
            panelAdapter: ThemeEditorPanelAdapterSpy(),
            windowFactory: windows.makeWindow,
            makeUUID: {
                UUID(
                    uuidString: "C0000000-0000-4000-8000-00000000000C"
                )!
            },
            localizationModel: localizationModel
        )

        composition.presenter.show()

        let editor = try XCTUnwrap(windows.viewModels.first)
        XCTAssertEqual(editor.draft, BuiltInThemes.morandi.document)
        XCTAssertEqual(
            editor.previewDisplayName,
            localizationModel.text.text(.themeMorandi)
        )
    }

    func testActivationFailureKeepsOldActiveTruthAndPreservesSavedDraft()
        throws
    {
        let harness = try makeRuntimeHarness()
        let service = try ProductionThemeSettingsService(
            themeStore: harness.store,
            settingsStore: harness.settingsStore
        )
        let windows = ThemeEditorWindowFactorySpy()
        var identifiers = [
            UUID(uuidString: "90000000-0000-4000-8000-000000000009")!,
            UUID(uuidString: "A0000000-0000-4000-8000-00000000000A")!,
        ]
        let composition = try ProductionThemeEditorComposition.make(
            store: harness.store,
            runtimeModel: service.runtimeModel,
            stagingRoot: harness.root,
            panelAdapter: ThemeEditorPanelAdapterSpy(),
            windowFactory: windows.makeWindow,
            makeUUID: { identifiers.removeFirst() },
            localizationModel: makeLocalizationModel()
        )
        composition.presenter.show()
        let editor = try XCTUnwrap(windows.viewModels.first)
        editor.duplicateBuiltIn(named: "Safely retained draft")
        let draft = editor.draft
        harness.settingsFiles.failNextWrite = true

        editor.save(activate: true)

        XCTAssertEqual(editor.operationState, .savedNotApplied)
        XCTAssertEqual(
            editor.operationMessage,
            editor.localizationModel.text.text(.themeEditorSavedNotApplied)
        )
        XCTAssertTrue(
            harness.store.snapshot.customThemes.contains(where: {
                $0.id == draft.id
            })
        )
        XCTAssertEqual(harness.store.snapshot.activeSelection, .builtIn(.morandi))
        XCTAssertEqual(service.runtimeModel.selection, .builtIn(.morandi))
        XCTAssertEqual(
            service.runtimeModel.currentTheme,
            BuiltInThemes.morandi.document
        )
        XCTAssertEqual(
            harness.settingsStore.settings.appearance.themeID,
            BuiltInThemeID.morandi.rawValue
        )
    }

    func testSavingActiveCustomWithoutActivationRefreshesRuntimeDocument()
        throws
    {
        let harness = try makeRuntimeHarness()
        let custom = try harness.store.duplicateBuiltIn(
            .cyberpunk,
            named: "Active before edit"
        )
        let service = try ProductionThemeSettingsService(
            themeStore: harness.store,
            settingsStore: harness.settingsStore
        )
        try service.selectTheme(id: custom.id.uuidString)
        try harness.store.selectBuiltIn(.glass)
        XCTAssertEqual(service.runtimeModel.selection, .custom(custom.id))
        XCTAssertEqual(harness.store.snapshot.activeSelection, .builtIn(.glass))
        let windows = ThemeEditorWindowFactorySpy()
        let composition = try ProductionThemeEditorComposition.make(
            store: harness.store,
            runtimeModel: service.runtimeModel,
            stagingRoot: harness.root,
            panelAdapter: ThemeEditorPanelAdapterSpy(),
            windowFactory: windows.makeWindow,
            makeUUID: {
                UUID(
                    uuidString: "B0000000-0000-4000-8000-00000000000B"
                )!
            },
            localizationModel: makeLocalizationModel()
        )
        composition.presenter.show()
        let editor = try XCTUnwrap(windows.viewModels.first)
        editor.rename("Edited active custom")

        editor.save(activate: false)

        XCTAssertEqual(
            harness.store.document(for: .custom(custom.id))?.name,
            "Edited active custom"
        )
        XCTAssertEqual(service.runtimeModel.selection, .custom(custom.id))
        XCTAssertEqual(
            service.runtimeModel.currentTheme.name,
            "Edited active custom"
        )
        XCTAssertEqual(
            harness.settingsStore.settings.appearance.themeID,
            custom.id.uuidString
        )
        XCTAssertEqual(harness.store.snapshot.activeSelection, .builtIn(.glass))
        XCTAssertEqual(editor.operationState, .saveSucceeded)
        XCTAssertEqual(
            editor.operationMessage,
            editor.localizationModel.text.text(.themeEditorSaveSucceeded)
        )
    }

    private static func makeInertViewModel(
        localizationModel: AppLocalizationRuntimeModel =
            AppLocalizationRuntimeModel(
                language: .traditionalChinese,
                systemLocale: Locale(identifier: "zh_Hant")
            )
    ) -> ThemeEditorViewModel {
        ThemeEditorViewModel(
            sourceTheme: BuiltInThemes.morandi.document,
            sourceBuiltInID: .morandi,
            manager: InertThemeEditorManager(),
            picker: InertThemeEditorPicker(),
            localizationModel: localizationModel
        )
    }

    private func makeLocalizationModel(
        _ language: AppLanguage = .traditionalChinese
    ) -> AppLocalizationRuntimeModel {
        AppLocalizationRuntimeModel(
            language: language,
            systemLocale: Locale(identifier: "zh_Hant")
        )
    }

    private func makeStoreHarness() throws -> (
        store: ThemeStore,
        root: URL
    ) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        return (
            try ThemeStore(
                persistence: ThemeStoreDiskPersistence(rootDirectory: root)
            ),
            root
        )
    }

    private func makeRuntimeHarness() throws -> EditorRuntimeHarness {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        let settingsFiles = EditorMemorySettingsFiles()
        let settingsStore = SettingsStore(
            fileURL: root.appendingPathComponent("settings.json"),
            fileStore: settingsFiles
        )
        var settings = settingsStore.settings
        settings.appearance.themeID = BuiltInThemeID.morandi.rawValue
        try settingsStore.replace(with: settings).get()
        let store = try ThemeStore(
            persistence: ThemeStoreDiskPersistence(
                rootDirectory: root.appendingPathComponent(
                    "ThemeStore",
                    isDirectory: true
                )
            )
        )
        return EditorRuntimeHarness(
            root: root,
            store: store,
            settingsStore: settingsStore,
            settingsFiles: settingsFiles
        )
    }

    private func pendingRaster(_ data: Data) -> PendingSanitizedThemeRaster {
        let hash = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return PendingSanitizedThemeRaster(
            reference: SanitizedRasterReference(
                relativeIdentifier: hash + ".png",
                sha256: hash
            ),
            pngData: data
        )
    }

    private func customDocument(id: UUID, name: String) -> ThemeDocument {
        let source = BuiltInThemes.morandi.document
        return ThemeDocument(
            schemaVersion: source.schemaVersion,
            id: id,
            name: name,
            appearances: source.appearances,
            geometry: source.geometry,
            ornamentOpacity: source.ornamentOpacity,
            rasterReference: nil
        )
    }

    private func envelope(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }
}

@MainActor
private final class ThemeEditorWindowFactorySpy {
    private(set) var windows: [ThemeEditorWindowSpy] = []
    private(set) var viewModels: [ThemeEditorViewModel] = []
    private(set) var localizationModels: [AppLocalizationRuntimeModel] = []

    func makeWindow(
        viewModel: ThemeEditorViewModel,
        localizationModel: AppLocalizationRuntimeModel,
        didClose: @escaping @MainActor () -> Void
    ) -> any ThemeEditorWindowHandling {
        let window = ThemeEditorWindowSpy(didClose: didClose)
        viewModels.append(viewModel)
        localizationModels.append(localizationModel)
        windows.append(window)
        return window
    }
}

@MainActor
private struct EditorRuntimeHarness {
    let root: URL
    let store: ThemeStore
    let settingsStore: SettingsStore
    let settingsFiles: EditorMemorySettingsFiles
}

private final class EditorMemorySettingsFiles: SettingsFileStoring {
    var values: [URL: Data] = [:]
    var failNextWrite = false

    func read(from url: URL) throws -> Data? { values[url] }

    func write(
        _ data: Data,
        to url: URL,
        options: Data.WritingOptions
    ) throws {
        if failNextWrite {
            failNextWrite = false
            throw EditorMemorySettingsFileError.forcedFailure
        }
        values[url] = data
    }
}

private enum EditorMemorySettingsFileError: Error {
    case forcedFailure
}

@MainActor
private final class ThemeEditorWindowSpy: ThemeEditorWindowHandling {
    private let didClose: @MainActor () -> Void
    private(set) var showAndFocusCount = 0
    private(set) var closeCount = 0
    private(set) var titles: [String] = []

    init(didClose: @escaping @MainActor () -> Void) {
        self.didClose = didClose
    }

    func showAndFocus() { showAndFocusCount += 1 }
    func updateTitle(_ title: String) { titles.append(title) }
    func close() {
        closeCount += 1
        didClose()
    }
    func simulateClose() { didClose() }
}

@MainActor
private final class ThemeEditorPanelRunnerSpy {
    private(set) var calls: [ThemeEditorPanelRequest] = []

    func run(_ request: ThemeEditorPanelRequest) -> URL? {
        calls.append(request)
        return nil
    }
}

@MainActor
private final class ThemeEditorPanelAdapterSpy: ThemeEditorPanelAdapting {
    var importData: Data?
    var exportAccepted = true
    private(set) var rasterPickCount = 0
    private(set) var importPickCount = 0
    private(set) var exportWriteCount = 0
    private(set) var exportedData: [Data] = []

    func pickRasterSelection() async throws -> ThemeRasterUserSelection? {
        rasterPickCount += 1
        return nil
    }

    func pickThemeImportData() async throws -> Data? {
        importPickCount += 1
        return importData
    }

    func writeThemeExportData(_ data: Data) async throws -> Bool {
        exportWriteCount += 1
        exportedData.append(data)
        return exportAccepted
    }
}

@MainActor
private final class ThemeRasterPickerSpy: ThemeRasterPicking {
    var result: PendingSanitizedThemeRaster?
    private(set) var pickCount = 0

    func pickRaster() async throws -> PendingSanitizedThemeRaster? {
        pickCount += 1
        return result
    }
}

@MainActor
private final class SuspendedThemeRasterPicker: ThemeRasterPicking {
    private var resultContinuation:
        CheckedContinuation<PendingSanitizedThemeRaster?, Never>?
    private var startContinuations: [CheckedContinuation<Void, Never>] = []
    private(set) var didStart = false

    func pickRaster() async throws -> PendingSanitizedThemeRaster? {
        await withCheckedContinuation { continuation in
            resultContinuation = continuation
            didStart = true
            let waiters = startContinuations
            startContinuations.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            startContinuations.append(continuation)
        }
    }

    func resume(
        returning result: PendingSanitizedThemeRaster?,
        recreatingStagingAt stagingDirectory: URL
    ) {
        try? FileManager.default.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true
        )
        try? Data("late artifact".utf8).write(
            to: stagingDirectory.appendingPathComponent("late.tmp")
        )
        resultContinuation?.resume(returning: result)
        resultContinuation = nil
    }
}

@MainActor
private final class SuspendedThemeEditorPanelAdapter:
    ThemeEditorPanelAdapting
{
    private var importContinuation: CheckedContinuation<Data?, Never>?
    private var startContinuations: [CheckedContinuation<Void, Never>] = []
    private(set) var didStartImport = false

    func pickRasterSelection() async throws -> ThemeRasterUserSelection? {
        nil
    }

    func pickThemeImportData() async throws -> Data? {
        await withCheckedContinuation { continuation in
            importContinuation = continuation
            didStartImport = true
            let waiters = startContinuations
            startContinuations.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func writeThemeExportData(_ data: Data) async throws -> Bool { false }

    func waitUntilImportStarted() async {
        guard !didStartImport else { return }
        await withCheckedContinuation { continuation in
            startContinuations.append(continuation)
        }
    }

    func resumeImport(returning data: Data?) {
        importContinuation?.resume(returning: data)
        importContinuation = nil
    }
}

@MainActor
private final class SuspendedThemeEditorPicker: ThemeEditorPicking {
    private var importContinuation:
        CheckedContinuation<ThemeDocument?, Never>?
    private var startContinuations: [CheckedContinuation<Void, Never>] = []
    private(set) var didStartImport = false

    func pickSanitizedRaster() async throws -> SanitizedRasterReference? {
        nil
    }

    func pickValidatedThemeForImport() async throws -> ThemeDocument? {
        await withCheckedContinuation { continuation in
            importContinuation = continuation
            didStartImport = true
            let waiters = startContinuations
            startContinuations.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func exportTheme(
        _ document: ThemeDocument,
        includeRaster: Bool
    ) async throws -> Bool {
        false
    }

    func waitUntilImportStarted() async {
        guard !didStartImport else { return }
        await withCheckedContinuation { continuation in
            startContinuations.append(continuation)
        }
    }

    func resumeImport(returning document: ThemeDocument?) {
        importContinuation?.resume(returning: document)
        importContinuation = nil
    }
}

@MainActor
private final class SuspendedThemeEditorRasterPicker: ThemeEditorPicking {
    private var rasterContinuation:
        CheckedContinuation<SanitizedRasterReference?, Never>?
    private var startContinuations: [CheckedContinuation<Void, Never>] = []
    private(set) var didStartRaster = false

    func pickSanitizedRaster() async throws -> SanitizedRasterReference? {
        await withCheckedContinuation { continuation in
            rasterContinuation = continuation
            didStartRaster = true
            let waiters = startContinuations
            startContinuations.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func pickValidatedThemeForImport() async throws -> ThemeDocument? { nil }

    func exportTheme(
        _ document: ThemeDocument,
        includeRaster: Bool
    ) async throws -> Bool { false }

    func waitUntilRasterStarted() async {
        guard !didStartRaster else { return }
        await withCheckedContinuation { continuation in
            startContinuations.append(continuation)
        }
    }

    func resumeRaster(returning reference: SanitizedRasterReference?) {
        rasterContinuation?.resume(returning: reference)
        rasterContinuation = nil
    }
}

@MainActor
private final class InertThemeEditorManager: ThemeEditorManaging {
    func duplicateBuiltIn(
        _ id: BuiltInThemeID,
        named name: String
    ) throws -> ThemeDocument {
        BuiltInThemes.morandi.document
    }

    func saveCustom(_ document: ThemeDocument, activate: Bool) throws {}
    func reset() throws -> ThemeDocument { BuiltInThemes.morandi.document }
    func cancelDraft() {}
}

@MainActor
private final class CancelCountingThemeEditorManager: ThemeEditorManaging {
    private(set) var cancelCount = 0

    func duplicateBuiltIn(
        _ id: BuiltInThemeID,
        named name: String
    ) throws -> ThemeDocument {
        BuiltInThemes.morandi.document
    }

    func saveCustom(_ document: ThemeDocument, activate: Bool) throws {}
    func reset() throws -> ThemeDocument { BuiltInThemes.morandi.document }
    func cancelDraft() { cancelCount += 1 }
}

@MainActor
private final class InertThemeEditorPicker: ThemeEditorPicking {
    func pickSanitizedRaster() async throws -> SanitizedRasterReference? { nil }
    func pickValidatedThemeForImport() async throws -> ThemeDocument? { nil }
    func exportTheme(
        _ document: ThemeDocument,
        includeRaster: Bool
    ) async throws -> Bool { false }
}

@MainActor
private func waitForWindowTitle(
    _ expected: String,
    in window: ThemeEditorWindowSpy
) async -> Bool {
    for _ in 0..<50 {
        if window.titles.last == expected { return true }
        await Task.yield()
    }
    return false
}

@MainActor
private func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<50 {
        if condition() { return true }
        await Task.yield()
    }
    return false
}
