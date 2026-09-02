import Foundation

enum ThemeEditorStagingError: Error, Equatable, Sendable {
    case outsideOwnedRoot
}

struct ThemeEditorStagingLocation: Equatable, Sendable {
    let rootDirectory: URL
    let sessionDirectory: URL

    init(rootDirectory: URL, sessionDirectory: URL) throws {
        let root = rootDirectory.standardizedFileURL
        let session = sessionDirectory.standardizedFileURL
        guard session != root,
              session.deletingLastPathComponent() == root
        else {
            throw ThemeEditorStagingError.outsideOwnedRoot
        }
        self.rootDirectory = root
        self.sessionDirectory = session
    }

    func remove(fileManager: FileManager = .default) {
        guard sessionDirectory.deletingLastPathComponent() == rootDirectory
        else {
            return
        }
        try? fileManager.removeItem(at: sessionDirectory)
    }
}

@MainActor
protocol ThemeRasterPicking: AnyObject {
    func pickRaster() async throws -> PendingSanitizedThemeRaster?
}

@MainActor
final class ProductionThemeEditorSession:
    ThemeEditorManaging,
    ThemeEditorPicking
{
    var stagingDirectory: URL { stagingLocation.sessionDirectory }

    private let store: ThemeStore
    private let runtimeModel: ThemeRuntimeModel?
    let localizationModel: AppLocalizationRuntimeModel
    private let panelAdapter: any ThemeEditorPanelAdapting
    private let rasterPicker: any ThemeRasterPicking
    private let importExportService: ThemeImportExportService
    private let makeUUID: () -> UUID
    private let didMutateThemes: @MainActor () -> Void
    private let stagingLocation: ThemeEditorStagingLocation
    private var pendingRaster: PendingSanitizedThemeRaster?
    private var operationGeneration: UInt64 = 0

    init(
        store: ThemeStore,
        runtimeModel: ThemeRuntimeModel? = nil,
        localizationModel: AppLocalizationRuntimeModel,
        panelAdapter: any ThemeEditorPanelAdapting,
        rasterPicker: any ThemeRasterPicking,
        stagingRoot: URL,
        stagingDirectory: URL,
        importExportService: ThemeImportExportService = ThemeImportExportService(),
        makeUUID: @escaping () -> UUID = UUID.init,
        didMutateThemes: @escaping @MainActor () -> Void = {}
    ) throws {
        self.store = store
        self.runtimeModel = runtimeModel
        self.localizationModel = localizationModel
        self.panelAdapter = panelAdapter
        self.rasterPicker = rasterPicker
        stagingLocation = try ThemeEditorStagingLocation(
            rootDirectory: stagingRoot,
            sessionDirectory: stagingDirectory
        )
        self.importExportService = importExportService
        self.makeUUID = makeUUID
        self.didMutateThemes = didMutateThemes
    }

    func makeViewModel(
        sourceTheme: ThemeDocument,
        sourceBuiltInID: BuiltInThemeID?
    ) -> ThemeEditorViewModel {
        ThemeEditorViewModel(
            sourceTheme: sourceTheme,
            sourceBuiltInID: sourceBuiltInID,
            manager: self,
            picker: self,
            localizationModel: localizationModel
        )
    }

    func duplicateBuiltIn(
        _ id: BuiltInThemeID,
        named name: String
    ) throws -> ThemeDocument {
        invalidateOperationsAndDraftRaster()
        guard let source = BuiltInThemes.all.first(where: { $0.id == id })?
            .document
        else {
            throw ThemeStoreError.themeNotFound
        }
        return ThemeDocument(
            schemaVersion: ThemeDocument.currentSchemaVersion,
            id: makeUUID(),
            name: name,
            appearances: source.appearances,
            geometry: source.geometry,
            ornamentOpacity: source.ornamentOpacity,
            rasterReference: source.rasterReference
        )
    }

    func saveCustom(_ document: ThemeDocument, activate: Bool) throws {
        _ = beginOperation()
        let raster = pendingRaster.flatMap {
            $0.reference == document.rasterReference ? $0 : nil
        }
        try store.saveCustom(
            document,
            activate: activate && runtimeModel == nil,
            pendingRaster: raster
        )
        pendingRaster = nil
        removeStagingDirectory()
        if activate, let runtimeModel {
            do {
                try runtimeModel.selectTheme(id: document.id.uuidString)
            } catch {
                didMutateThemes()
                throw ThemeEditorSaveError.savedButNotApplied
            }
        } else {
            runtimeModel?.refreshSelectedThemeDocument()
        }
        didMutateThemes()
    }

    func reset() throws -> ThemeDocument {
        _ = beginOperation()
        if let runtimeModel {
            try runtimeModel.resetTheme()
        } else {
            try store.reset()
        }
        pendingRaster = nil
        removeStagingDirectory()
        didMutateThemes()
        return BuiltInThemes.morandi.document
    }

    func cancelDraft() {
        invalidateOperationsAndDraftRaster()
    }

    func pickSanitizedRaster() async throws -> SanitizedRasterReference? {
        let generation = beginOperation()
        let raster: PendingSanitizedThemeRaster?
        do {
            raster = try await rasterPicker.pickRaster()
        } catch {
            guard isCurrent(generation) else {
                removeStagingDirectory()
                return nil
            }
            throw error
        }
        guard isCurrent(generation) else {
            removeStagingDirectory()
            return nil
        }
        guard let raster else {
            return nil
        }
        guard raster.verifiedPNGData != nil else {
            throw ThemeStoreError.invalidTheme
        }
        pendingRaster = raster
        return raster.reference
    }

    func pickValidatedThemeForImport() async throws -> ThemeDocument? {
        let generation = beginOperation()
        let data: Data?
        do {
            data = try await panelAdapter.pickThemeImportData()
        } catch {
            guard isCurrent(generation) else {
                removeStagingDirectory()
                return nil
            }
            throw error
        }
        guard isCurrent(generation) else {
            removeStagingDirectory()
            return nil
        }
        guard let data else {
            return nil
        }
        removeStagingDirectory()
        defer { removeStagingDirectory() }
        let prepared: PreparedThemeImport
        do {
            prepared = try await importExportService.prepareImport(
                data,
                stagingDirectory: stagingDirectory
            )
        } catch {
            guard isCurrent(generation) else { return nil }
            throw error
        }
        guard isCurrent(generation) else { return nil }
        if let reference = prepared.sanitizedRaster {
            let url = stagingDirectory
                .appendingPathComponent("Rasters", isDirectory: true)
                .appendingPathComponent(reference.relativeIdentifier)
            pendingRaster = PendingSanitizedThemeRaster(
                reference: reference,
                pngData: try Data(contentsOf: url)
            )
        } else {
            pendingRaster = nil
        }
        return prepared.document
    }

    func exportTheme(
        _ document: ThemeDocument,
        includeRaster: Bool
    ) async throws -> Bool {
        let generation = beginOperation()
        let rasterData: Data?
        if includeRaster, let reference = document.rasterReference {
            if pendingRaster?.reference == reference {
                rasterData = pendingRaster?.pngData
            } else {
                rasterData = try store.rasterData(for: reference)
            }
        } else {
            rasterData = nil
        }
        let data = try importExportService.exportTheme(
            document,
            rasterPNG: rasterData,
            includeRaster: includeRaster
        )
        do {
            let exported = try await panelAdapter.writeThemeExportData(data)
            return isCurrent(generation) ? exported : false
        } catch {
            guard isCurrent(generation) else { return false }
            throw error
        }
    }

    func rasterData(for reference: SanitizedRasterReference) -> Data? {
        if pendingRaster?.reference == reference {
            return pendingRaster?.verifiedPNGData
        }
        return try? store.rasterData(for: reference)
    }

    private func beginOperation() -> UInt64 {
        operationGeneration &+= 1
        return operationGeneration
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        generation == operationGeneration
    }

    private func invalidateOperationsAndDraftRaster() {
        operationGeneration &+= 1
        pendingRaster = nil
        removeStagingDirectory()
    }

    private func removeStagingDirectory() {
        stagingLocation.remove()
    }
}

@MainActor
struct ProductionThemeEditorComposition {
    let presenter: any ThemeEditorPresenting
    let stagingDirectory: URL
    let mutations: ThemeEditorMutationRelay
    let localizationModel: AppLocalizationRuntimeModel

    static func make(
        store: ThemeStore,
        runtimeModel: ThemeRuntimeModel,
        stagingRoot: URL = defaultStagingRoot(),
        panelAdapter injectedPanelAdapter:
            (any ThemeEditorPanelAdapting)? = nil,
        windowFactory: ThemeEditorWindowController.WindowFactory? = nil,
        makeUUID: @escaping () -> UUID = UUID.init,
        mutations: ThemeEditorMutationRelay = ThemeEditorMutationRelay(),
        localizationModel: AppLocalizationRuntimeModel
    ) throws -> ProductionThemeEditorComposition {
        let root = stagingRoot.standardizedFileURL
        let stagingDirectory = root.appendingPathComponent(
            ".theme-editor-\(makeUUID().uuidString)",
            isDirectory: true
        )
        let panelAdapter = injectedPanelAdapter
            ?? SystemThemeEditorPanelAdapter(
                localizationModel: localizationModel
            )
        let rasterPicker = try ProductionThemeRasterPicker(
            panelAdapter: panelAdapter,
            stagingRoot: root,
            stagingDirectory: stagingDirectory
        )
        let session = try ProductionThemeEditorSession(
            store: store,
            runtimeModel: runtimeModel,
            localizationModel: localizationModel,
            panelAdapter: panelAdapter,
            rasterPicker: rasterPicker,
            stagingRoot: root,
            stagingDirectory: stagingDirectory,
            makeUUID: makeUUID,
            didMutateThemes: { mutations.notify() }
        )
        let makeViewModel: @MainActor () -> ThemeEditorViewModel? = {
            let selection = runtimeModel.selection
            guard let document = store.document(for: selection) else {
                return nil
            }
            let builtInID: BuiltInThemeID? = switch selection {
            case let .builtIn(id): id
            case .custom: nil
            }
            return session.makeViewModel(
                sourceTheme: document,
                sourceBuiltInID: builtInID
            )
        }
        let controller: ThemeEditorWindowController
        if let windowFactory {
            controller = ThemeEditorWindowController(
                localizationModel: localizationModel,
                makeViewModel: makeViewModel,
                windowFactory: windowFactory
            )
        } else {
            controller = ThemeEditorWindowController(
                localizationModel: localizationModel,
                makeViewModel: makeViewModel
            )
        }
        return ProductionThemeEditorComposition(
            presenter: controller,
            stagingDirectory: stagingDirectory,
            mutations: mutations,
            localizationModel: localizationModel
        )
    }

    static func defaultStagingRoot(
        fileManager: FileManager = .default
    ) -> URL {
        SettingsStore.defaultFileURL(fileManager: fileManager)
            .deletingLastPathComponent()
            .standardizedFileURL
    }
}
