import CryptoKit
import Foundation
import Observation
import XCTest
@testable import CodexQuotaMonitor

@MainActor
final class ProductionThemeRuntimeTests: XCTestCase {
    func testStartupCanonicalizesDefaultSystemThemeToMorandi() throws {
        let harness = try makeHarness()

        let service = try ProductionThemeSettingsService(
            themeStore: harness.themeStore,
            settingsStore: harness.settingsStore
        )

        XCTAssertEqual(
            harness.themeStore.snapshot.activeSelection,
            .builtIn(.morandi)
        )
        XCTAssertEqual(
            harness.settingsStore.settings.appearance.themeID,
            BuiltInThemeID.morandi.rawValue
        )
        XCTAssertEqual(service.runtimeModel.selection, .builtIn(.morandi))
        XCTAssertEqual(
            service.runtimeModel.currentTheme,
            BuiltInThemes.morandi.document
        )
        XCTAssertEqual(service.runtimeModel.colorScheme, .system)
        XCTAssertEqual(service.runtimeModel.density, .system)
    }

    func testStartupRestoresValidPersistedBuiltInSelection() throws {
        let harness = try makeHarness(
            appearance: AppearanceSettings(
                themeID: BuiltInThemeID.glass.rawValue,
                colorScheme: AppearanceColorScheme.dark.rawValue,
                density: AppearanceDensity.compact.rawValue,
                displayProfile: .full
            )
        )

        let service = try ProductionThemeSettingsService(
            themeStore: harness.themeStore,
            settingsStore: harness.settingsStore
        )

        XCTAssertEqual(
            harness.themeStore.snapshot.activeSelection,
            .builtIn(.glass)
        )
        XCTAssertEqual(service.runtimeModel.selection, .builtIn(.glass))
        XCTAssertEqual(service.runtimeModel.currentTheme, BuiltInThemes.glass.document)
        XCTAssertEqual(service.runtimeModel.colorScheme, .dark)
        XCTAssertEqual(service.runtimeModel.density, .compact)
        XCTAssertEqual(service.runtimeModel.displayProfile, .full)
    }

    func testDisplayProfileUpdatePublishesImmediatelyAndPersists() throws {
        let harness = try makeHarness()
        let service = try ProductionThemeSettingsService(
            themeStore: harness.themeStore,
            settingsStore: harness.settingsStore
        )

        try service.runtimeModel.setDisplayProfile(.compact)

        XCTAssertEqual(service.runtimeModel.displayProfile, .compact)
        XCTAssertEqual(
            harness.settingsStore.settings.appearance.displayProfile,
            .compact
        )
    }

    func testPercentageModeRestoresPublishesAndPersists() throws {
        let harness = try makeHarness()
        var settings = harness.settingsStore.settings
        settings.percentageMode = .used
        try harness.settingsStore.replace(with: settings).get()
        let service = try ProductionThemeSettingsService(
            themeStore: harness.themeStore,
            settingsStore: harness.settingsStore
        )

        XCTAssertEqual(service.runtimeModel.percentageMode, .used)

        try service.runtimeModel.setPercentageMode(.remaining)

        XCTAssertEqual(service.runtimeModel.percentageMode, .remaining)
        XCTAssertEqual(
            harness.settingsStore.settings.percentageMode,
            .remaining
        )
    }

    func testExternalSettingsReplacePublishesOnlyAfterExplicitRuntimeReload()
        throws
    {
        let harness = try makeHarness()
        let service = try ProductionThemeSettingsService(
            themeStore: harness.themeStore,
            settingsStore: harness.settingsStore
        )
        try service.runtimeModel.setDisplayProfile(.full)
        try service.runtimeModel.setPercentageMode(.used)
        var external = harness.settingsStore.settings
        external.appearance.displayProfile = .balanced
        external.percentageMode = .remaining

        try harness.settingsStore.replace(with: external).get()

        XCTAssertEqual(service.runtimeModel.displayProfile, .full)
        XCTAssertEqual(service.runtimeModel.percentageMode, .used)

        service.reloadRuntimeSettings()

        XCTAssertEqual(service.runtimeModel.displayProfile, .balanced)
        XCTAssertEqual(service.runtimeModel.percentageMode, .remaining)
    }

    func testPresentationSettingWriteFailureNeverPublishesCandidateValues()
        throws
    {
        let harness = try makeHarness()
        let service = try ProductionThemeSettingsService(
            themeStore: harness.themeStore,
            settingsStore: harness.settingsStore
        )

        harness.settingsFiles.failNextWriteURL = harness.settingsURL
        XCTAssertThrowsError(
            try service.runtimeModel.setDisplayProfile(.full)
        )
        XCTAssertEqual(service.runtimeModel.displayProfile, .balanced)
        XCTAssertEqual(
            harness.settingsStore.settings.appearance.displayProfile,
            .balanced
        )

        harness.settingsFiles.failNextWriteURL = harness.settingsURL
        XCTAssertThrowsError(
            try service.runtimeModel.setPercentageMode(.used)
        )
        XCTAssertEqual(service.runtimeModel.percentageMode, .remaining)
        XCTAssertEqual(
            harness.settingsStore.settings.percentageMode,
            .remaining
        )
    }

    func testStartupRestoresValidPersistedCustomSelection() throws {
        let harness = try makeHarness()
        let custom = try harness.themeStore.duplicateBuiltIn(
            .sketch,
            named: "已儲存的自訂素描"
        )
        var settings = harness.settingsStore.settings
        settings.appearance = AppearanceSettings(
            themeID: custom.id.uuidString,
            colorScheme: AppearanceColorScheme.light.rawValue,
            density: AppearanceDensity.comfortable.rawValue
        )
        try harness.settingsStore.replace(with: settings).get()

        let service = try ProductionThemeSettingsService(
            themeStore: harness.themeStore,
            settingsStore: harness.settingsStore
        )

        XCTAssertEqual(service.runtimeModel.selection, .custom(custom.id))
        XCTAssertEqual(service.runtimeModel.currentTheme, custom)
        XCTAssertEqual(
            harness.themeStore.snapshot.activeSelection,
            .custom(custom.id)
        )
        XCTAssertEqual(service.runtimeModel.colorScheme, .light)
        XCTAssertEqual(service.runtimeModel.density, .comfortable)
    }

    func testCustomRasterLoadsForRuntimeSettingsPreviewAndRestart() throws {
        let harness = try makeHarness()
        let morandiArtwork = Data("morandi-artwork".utf8)
        let artworkLoader = BuiltInThemeArtworkLoader { resourceName in
            resourceName == "theme-morandi-background.png"
                ? morandiArtwork
                : nil
        }
        var custom = try harness.themeStore.duplicateBuiltIn(
            .sketch,
            named: "Raster custom"
        )
        let pending = makePendingRaster()
        custom.rasterReference = pending.reference
        try harness.themeStore.saveCustom(
            custom,
            activate: false,
            pendingRaster: pending
        )
        var settings = harness.settingsStore.settings
        settings.appearance.themeID = custom.id.uuidString
        try harness.settingsStore.replace(with: settings).get()

        let service = try ProductionThemeSettingsService(
            themeStore: harness.themeStore,
            settingsStore: harness.settingsStore,
            artworkLoader: artworkLoader
        )

        XCTAssertEqual(
            service.runtimeModel.currentRasterData,
            pending.pngData
        )
        XCTAssertEqual(
            service.snapshot().selectedThemeRasterData,
            pending.pngData
        )

        let restartedStore = try ThemeStore(
            persistence: ThemeStoreDiskPersistence(
                rootDirectory: harness.themeRoot
            )
        )
        let restartedService = try ProductionThemeSettingsService(
            themeStore: restartedStore,
            settingsStore: harness.settingsStore,
            artworkLoader: artworkLoader
        )

        XCTAssertEqual(
            restartedService.runtimeModel.currentRasterData,
            pending.pngData
        )

        try restartedService.resetTheme()
        XCTAssertEqual(
            restartedService.runtimeModel.currentRasterData,
            morandiArtwork
        )
        XCTAssertEqual(
            restartedService.snapshot().selectedThemeRasterData,
            morandiArtwork
        )
    }

    func testBuiltInArtworkAndCustomRasterUseTheirOwnDataSources() throws {
        let harness = try makeHarness()
        let builtInArtwork = Data("built-in-artwork".utf8)
        let artworkLoader = BuiltInThemeArtworkLoader { _ in builtInArtwork }
        var custom = try harness.themeStore.duplicateBuiltIn(
            .sketch,
            named: "Raster custom"
        )
        let pending = makePendingRaster()
        custom.rasterReference = pending.reference
        try harness.themeStore.saveCustom(
            custom,
            activate: false,
            pendingRaster: pending
        )
        let service = try ProductionThemeSettingsService(
            themeStore: harness.themeStore,
            settingsStore: harness.settingsStore,
            artworkLoader: artworkLoader
        )

        XCTAssertEqual(
            service.runtimeModel.currentRasterData,
            builtInArtwork
        )

        try service.selectTheme(id: custom.id.uuidString)

        XCTAssertEqual(
            service.runtimeModel.currentRasterData,
            pending.pngData
        )
    }

    func testSwitchingFromPresentToMissingBuiltInArtworkClearsStaleData()
        throws
    {
        let harness = try makeHarness()
        let morandiArtwork = Data("morandi-artwork".utf8)
        let artworkLoader = BuiltInThemeArtworkLoader { resourceName in
            resourceName == "theme-morandi-background.png"
                ? morandiArtwork
                : nil
        }
        let service = try ProductionThemeSettingsService(
            themeStore: harness.themeStore,
            settingsStore: harness.settingsStore,
            artworkLoader: artworkLoader
        )

        XCTAssertEqual(
            service.runtimeModel.currentRasterData,
            morandiArtwork
        )

        try service.selectTheme(id: BuiltInThemeID.glass.rawValue)

        XCTAssertNil(service.runtimeModel.currentRasterData)
    }

    func testInvalidOrMissingCustomThemeFallsBackAndPersistsMorandi() throws {
        let missingID = UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
        let harness = try makeHarness(
            appearance: AppearanceSettings(
                themeID: missingID.uuidString,
                colorScheme: "future-scheme",
                density: "future-density"
            )
        )
        try harness.themeStore.selectBuiltIn(.cyberpunk)

        let service = try ProductionThemeSettingsService(
            themeStore: harness.themeStore,
            settingsStore: harness.settingsStore
        )

        XCTAssertEqual(service.runtimeModel.selection, .builtIn(.morandi))
        XCTAssertEqual(service.runtimeModel.colorScheme, .system)
        XCTAssertEqual(service.runtimeModel.density, .system)
        XCTAssertEqual(
            harness.settingsStore.settings.appearance,
            AppearanceSettings(
                themeID: BuiltInThemeID.morandi.rawValue,
                colorScheme: AppearanceColorScheme.system.rawValue,
                density: AppearanceDensity.system.rawValue
            )
        )
    }

    func testSnapshotContainsSixBuiltInsAndEveryCustomTheme() throws {
        let harness = try makeHarness()
        let custom = try harness.themeStore.duplicateBuiltIn(
            .sketch,
            named: "我的素描"
        )
        let service = try ProductionThemeSettingsService(
            themeStore: harness.themeStore,
            settingsStore: harness.settingsStore
        )

        let snapshot = service.snapshot()

        XCTAssertEqual(snapshot.choices.count, BuiltInThemes.all.count + 1)
        XCTAssertEqual(
            Array(snapshot.choices.prefix(6).map(\.id)),
            BuiltInThemes.all.map(\.id.rawValue)
        )
        XCTAssertEqual(
            snapshot.choices.last,
            ThemeChoice(
                id: custom.id.uuidString,
                name: "我的素描",
                isCustom: true
            )
        )
        XCTAssertEqual(snapshot.selectedThemeID, BuiltInThemeID.morandi.rawValue)
        XCTAssertEqual(
            snapshot.selectedThemeDocument,
            BuiltInThemes.morandi.document
        )
        XCTAssertTrue(snapshot.allowsSelection)
        XCTAssertTrue(snapshot.allowsReset)
        XCTAssertFalse(snapshot.allowsImport)
        XCTAssertFalse(snapshot.allowsExport)
        XCTAssertTrue(snapshot.allowsCustomEditor)
        XCTAssertTrue(snapshot.allowsColorScheme)
        XCTAssertTrue(snapshot.allowsDensity)
    }

    func testUnavailableThemeTransfersThrowTypedErrors() throws {
        let harness = try makeHarness()
        let service = try ProductionThemeSettingsService(
            themeStore: harness.themeStore,
            settingsStore: harness.settingsStore
        )

        XCTAssertThrowsError(try service.importTheme()) { error in
            XCTAssertEqual(
                error as? ProductionThemeSettingsError,
                .transferUnavailable
            )
        }
        XCTAssertThrowsError(try service.exportTheme()) { error in
            XCTAssertEqual(
                error as? ProductionThemeSettingsError,
                .transferUnavailable
            )
        }
    }

    func testSelectBuiltInAndCustomSynchronizesBothStoresAndRuntime() throws {
        let harness = try makeHarness()
        let custom = try harness.themeStore.duplicateBuiltIn(
            .cartoonIllustration,
            named: "自訂卡通"
        )
        let service = try ProductionThemeSettingsService(
            themeStore: harness.themeStore,
            settingsStore: harness.settingsStore
        )

        try service.selectTheme(id: BuiltInThemeID.cyberpunk.rawValue)
        XCTAssertEqual(service.runtimeModel.selection, .builtIn(.cyberpunk))
        XCTAssertEqual(
            harness.settingsStore.settings.appearance.themeID,
            BuiltInThemeID.cyberpunk.rawValue
        )

        try service.selectTheme(id: custom.id.uuidString)
        XCTAssertEqual(service.runtimeModel.selection, .custom(custom.id))
        XCTAssertEqual(service.runtimeModel.currentTheme, custom)
        XCTAssertEqual(
            harness.themeStore.snapshot.activeSelection,
            .custom(custom.id)
        )
        XCTAssertEqual(
            harness.settingsStore.settings.appearance.themeID,
            custom.id.uuidString
        )
        XCTAssertEqual(service.snapshot().selectedThemeID, custom.id.uuidString)
    }

    func testResetSynchronizesMorandiAcrossBothStoresAndRuntime() throws {
        let harness = try makeHarness(
            appearance: AppearanceSettings(
                themeID: BuiltInThemeID.glass.rawValue,
                colorScheme: AppearanceColorScheme.light.rawValue,
                density: AppearanceDensity.comfortable.rawValue
            )
        )
        let service = try ProductionThemeSettingsService(
            themeStore: harness.themeStore,
            settingsStore: harness.settingsStore
        )

        try service.resetTheme()

        XCTAssertEqual(service.runtimeModel.selection, .builtIn(.morandi))
        XCTAssertEqual(
            harness.themeStore.snapshot.activeSelection,
            .builtIn(.morandi)
        )
        XCTAssertEqual(
            harness.settingsStore.settings.appearance.themeID,
            BuiltInThemeID.morandi.rawValue
        )
        XCTAssertEqual(service.runtimeModel.colorScheme, .light)
        XCTAssertEqual(service.runtimeModel.density, .comfortable)
    }

    func testAppearanceUpdatesPublishImmediatelyAndPersist() throws {
        let harness = try makeHarness()
        let service = try ProductionThemeSettingsService(
            themeStore: harness.themeStore,
            settingsStore: harness.settingsStore
        )

        let observationFired = ThemeRuntimeObservationFlag()
        withObservationTracking {
            _ = service.runtimeModel.colorScheme
            _ = service.runtimeModel.density
        } onChange: {
            observationFired.set()
        }

        try service.runtimeModel.setColorScheme(.dark)
        try service.runtimeModel.setDensity(.compact)

        XCTAssertTrue(observationFired.value)
        XCTAssertEqual(service.runtimeModel.colorScheme, .dark)
        XCTAssertEqual(service.runtimeModel.density, .compact)
        XCTAssertEqual(
            harness.settingsStore.settings.appearance.colorScheme,
            AppearanceColorScheme.dark.rawValue
        )
        XCTAssertEqual(
            harness.settingsStore.settings.appearance.density,
            AppearanceDensity.compact.rawValue
        )
    }

    func testSettingsWriteFailureRollsThemeStoreBackAndDoesNotPublish() throws {
        let harness = try makeHarness(
            appearance: AppearanceSettings(
                themeID: BuiltInThemeID.morandi.rawValue,
                colorScheme: AppearanceColorScheme.system.rawValue,
                density: AppearanceDensity.system.rawValue
            )
        )
        let service = try ProductionThemeSettingsService(
            themeStore: harness.themeStore,
            settingsStore: harness.settingsStore
        )
        harness.settingsFiles.failNextWriteURL = harness.settingsURL

        XCTAssertThrowsError(
            try service.selectTheme(id: BuiltInThemeID.glass.rawValue)
        ) { error in
            XCTAssertEqual(
                error as? ProductionThemeSettingsError,
                .settingsPersistenceFailed
            )
        }

        XCTAssertEqual(service.runtimeModel.selection, .builtIn(.morandi))
        XCTAssertEqual(
            harness.themeStore.snapshot.activeSelection,
            .builtIn(.morandi)
        )
        XCTAssertEqual(
            harness.settingsStore.settings.appearance.themeID,
            BuiltInThemeID.morandi.rawValue
        )
    }

    func testRollbackFailureKeepsLastPublishedRuntimeState() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let settingsURL = root.appendingPathComponent("settings.json")
        let settingsFiles = ThemeRuntimeMemorySettingsFiles()
        let settingsStore = SettingsStore(
            fileURL: settingsURL,
            fileStore: settingsFiles
        )
        var settings = settingsStore.settings
        settings.appearance.themeID = BuiltInThemeID.morandi.rawValue
        try settingsStore.replace(with: settings).get()
        let persistence = CountingThemeStorePersistence(
            base: ThemeStoreDiskPersistence(
                rootDirectory: root.appendingPathComponent(
                    "ThemeStore",
                    isDirectory: true
                )
            )
        )
        let themeStore = try ThemeStore(persistence: persistence)
        let service = try ProductionThemeSettingsService(
            themeStore: themeStore,
            settingsStore: settingsStore
        )
        settingsFiles.failNextWriteURL = settingsURL
        persistence.failCommitAttempts = [2]

        XCTAssertThrowsError(
            try service.selectTheme(id: BuiltInThemeID.glass.rawValue)
        ) { error in
            XCTAssertEqual(
                error as? ProductionThemeSettingsError,
                .rollbackFailed
            )
        }

        XCTAssertEqual(
            themeStore.snapshot.activeSelection,
            .builtIn(.glass),
            "The durable theme store exposes the rollback failure"
        )
        XCTAssertEqual(
            settingsStore.settings.appearance.themeID,
            BuiltInThemeID.morandi.rawValue
        )
        XCTAssertEqual(
            service.runtimeModel.selection,
            .builtIn(.morandi),
            "The UI must keep the last fully synchronized state"
        )
        XCTAssertEqual(
            service.runtimeModel.currentTheme,
            BuiltInThemes.morandi.document
        )

        service.runtimeModel.refreshSelectedThemeDocument()

        XCTAssertEqual(service.runtimeModel.selection, .builtIn(.morandi))
        XCTAssertEqual(
            service.runtimeModel.currentTheme,
            BuiltInThemes.morandi.document
        )
        XCTAssertEqual(
            themeStore.snapshot.activeSelection,
            .builtIn(.glass),
            "Refreshing the published document must not adopt divergent store truth"
        )
    }

    func testSafeBootstrapFallsBackWhenStartupSettingsWriteFails() throws {
        let harness = try makeHarness()
        harness.settingsFiles.failNextWriteURL = harness.settingsURL

        let bootstrap = ProductionThemeRuntimeBootstrap.make(
            settingsStore: harness.settingsStore,
            localizationModel: AppLocalizationRuntimeModel(),
            makeThemeStore: { harness.themeStore }
        )

        XCTAssertNil(bootstrap.runtimeModel)
        XCTAssertNil(bootstrap.themeEditorPresenter)
        XCTAssertFalse(bootstrap.themeService.snapshot().allowsSelection)
        XCTAssertFalse(
            bootstrap.themeService.snapshot().allowsCustomEditor
        )
        XCTAssertEqual(
            harness.settingsStore.settings.appearance.themeID,
            "system"
        )
    }

    func testBootstrapEnablesEditorAfterSuccessfulComposition() throws {
        let harness = try makeHarness()
        let presenter = ThemeRuntimeEditorPresenterSpy()
        var receivedStore: ThemeStore?
        let localizationModel = AppLocalizationRuntimeModel()
        var receivedLocalizationModel: AppLocalizationRuntimeModel?

        let bootstrap = ProductionThemeRuntimeBootstrap.make(
            settingsStore: harness.settingsStore,
            localizationModel: localizationModel,
            makeThemeStore: { harness.themeStore },
            makeThemeEditorPresenter: { store, _, _, receivedModel in
                receivedStore = store
                receivedLocalizationModel = receivedModel
                return presenter
            }
        )

        XCTAssertTrue(receivedStore === harness.themeStore)
        XCTAssertTrue(receivedLocalizationModel === localizationModel)
        XCTAssertTrue(bootstrap.localizationModel === localizationModel)
        XCTAssertTrue(bootstrap.themeEditorPresenter === presenter)
        XCTAssertNotNil(bootstrap.runtimeModel)
        XCTAssertTrue(
            bootstrap.themeService.snapshot().allowsCustomEditor
        )
    }

    func testBootstrapEnablesAndForwardsThemeTransfersWhenEditorExists()
        throws
    {
        let harness = try makeHarness()
        let presenter = ThemeRuntimeEditorPresenterSpy()
        let bootstrap = ProductionThemeRuntimeBootstrap.make(
            settingsStore: harness.settingsStore,
            localizationModel: AppLocalizationRuntimeModel(),
            makeThemeStore: { harness.themeStore },
            makeThemeEditorPresenter: { _, _, _, _ in presenter }
        )

        let snapshot = bootstrap.themeService.snapshot()
        XCTAssertTrue(snapshot.allowsImport)
        XCTAssertTrue(snapshot.allowsExport)

        try bootstrap.themeService.importTheme()
        try bootstrap.themeService.exportTheme()

        XCTAssertEqual(presenter.startImportCount, 1)
        XCTAssertEqual(presenter.startExportCount, 1)
    }

    func testBootstrapKeepsEditorDisabledWhenCompositionFails() throws {
        let harness = try makeHarness()

        let bootstrap = ProductionThemeRuntimeBootstrap.make(
            settingsStore: harness.settingsStore,
            localizationModel: AppLocalizationRuntimeModel(),
            makeThemeStore: { harness.themeStore },
            makeThemeEditorPresenter: { _, _, _, _ in
                throw ThemeRuntimeEditorCompositionError.forcedFailure
            }
        )

        XCTAssertNotNil(bootstrap.runtimeModel)
        XCTAssertNil(bootstrap.themeEditorPresenter)
        XCTAssertTrue(bootstrap.themeService.snapshot().allowsSelection)
        XCTAssertFalse(
            bootstrap.themeService.snapshot().allowsCustomEditor
        )
    }

    private func makeHarness(
        appearance: AppearanceSettings? = nil
    ) throws -> ThemeRuntimeHarness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let settingsURL = root.appendingPathComponent("settings.json")
        let settingsFiles = ThemeRuntimeMemorySettingsFiles()
        let settingsStore = SettingsStore(
            fileURL: settingsURL,
            fileStore: settingsFiles
        )
        if let appearance {
            var settings = settingsStore.settings
            settings.appearance = appearance
            try settingsStore.replace(with: settings).get()
        }
        let themeRoot = root.appendingPathComponent(
            "ThemeStore",
            isDirectory: true
        )
        let themeStore = try ThemeStore(
            persistence: ThemeStoreDiskPersistence(
                rootDirectory: themeRoot
            )
        )
        return ThemeRuntimeHarness(
            themeStore: themeStore,
            settingsStore: settingsStore,
            settingsFiles: settingsFiles,
            settingsURL: settingsURL,
            themeRoot: themeRoot
        )
    }

    private func makePendingRaster() -> PendingSanitizedThemeRaster {
        let data = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC"
                + "AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        )!
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
}

@MainActor
private struct ThemeRuntimeHarness {
    let themeStore: ThemeStore
    let settingsStore: SettingsStore
    let settingsFiles: ThemeRuntimeMemorySettingsFiles
    let settingsURL: URL
    let themeRoot: URL
}

private final class ThemeRuntimeMemorySettingsFiles: SettingsFileStoring {
    var data: [URL: Data] = [:]
    var failNextWriteURL: URL?

    func read(from url: URL) throws -> Data? {
        data[url]
    }

    func write(
        _ data: Data,
        to url: URL,
        options: Data.WritingOptions
    ) throws {
        if failNextWriteURL == url {
            failNextWriteURL = nil
            throw ThemeRuntimeFileError.forcedWriteFailure
        }
        self.data[url] = data
    }
}

private enum ThemeRuntimeFileError: Error {
    case forcedWriteFailure
}

private final class CountingThemeStorePersistence: ThemeStorePersisting {
    let base: ThemeStoreDiskPersistence
    var failCommitAttempts: Set<Int> = []
    private var commitAttempt = 0

    init(base: ThemeStoreDiskPersistence) {
        self.base = base
    }

    var rootDirectory: URL { base.rootDirectory }

    func loadManifest() throws -> Data? {
        try base.loadManifest()
    }

    func beginTransaction() throws -> URL {
        try base.beginTransaction()
    }

    func writeManifest(_ data: Data, in transaction: URL) throws {
        try base.writeManifest(data, in: transaction)
    }

    func stageRaster(
        _ raster: PendingSanitizedThemeRaster,
        in transaction: URL
    ) throws {
        try base.stageRaster(raster, in: transaction)
    }

    func commit(_ transaction: URL) throws {
        commitAttempt += 1
        if failCommitAttempts.contains(commitAttempt) {
            throw CountingThemeStorePersistenceError.forcedCommitFailure
        }
        try base.commit(transaction)
    }

    func rollback(_ transaction: URL) {
        base.rollback(transaction)
    }

    func rasterData(
        for reference: SanitizedRasterReference
    ) throws -> Data {
        try base.rasterData(for: reference)
    }

    func pruneRasters(
        in transaction: URL,
        keeping references: Set<String>
    ) throws {
        try base.pruneRasters(in: transaction, keeping: references)
    }
}

private enum CountingThemeStorePersistenceError: Error {
    case forcedCommitFailure
}

private final class ThemeRuntimeObservationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.withLock { storage }
    }

    func set() {
        lock.withLock { storage = true }
    }
}

@MainActor
private final class ThemeRuntimeEditorPresenterSpy: ThemeEditorPresenting {
    private(set) var startImportCount = 0
    private(set) var startExportCount = 0

    func show() {}
    func startImport() { startImportCount += 1 }
    func startExport() { startExportCount += 1 }
    func dismissForTermination() {}
}

private enum ThemeRuntimeEditorCompositionError: Error {
    case forcedFailure
}
