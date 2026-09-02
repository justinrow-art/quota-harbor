import Foundation
import Observation

enum ProductionThemeSettingsError: Error, Equatable, Sendable {
    case themeNotFound
    case themePersistenceFailed
    case settingsPersistenceFailed
    case rollbackFailed
    case transferUnavailable
}

@MainActor
@Observable
final class ThemeRuntimeModel {
    private(set) var currentTheme: ThemeDocument
    private(set) var currentRasterData: Data?
    private(set) var selection: ThemeSelection
    private(set) var colorScheme: AppearanceColorScheme
    private(set) var density: AppearanceDensity
    private(set) var displayProfile: DisplayProfile
    private(set) var percentageMode: PercentageMode

    @ObservationIgnored private let themeStore: ThemeStore
    @ObservationIgnored private let settingsStore: SettingsStore
    @ObservationIgnored private let artworkLoader: BuiltInThemeArtworkLoader

    init(
        themeStore: ThemeStore,
        settingsStore: SettingsStore,
        artworkLoader: BuiltInThemeArtworkLoader = BuiltInThemeArtworkLoader()
    ) throws {
        self.themeStore = themeStore
        self.settingsStore = settingsStore
        self.artworkLoader = artworkLoader
        currentTheme = BuiltInThemes.morandi.document
        currentRasterData = nil
        selection = .builtIn(.morandi)
        colorScheme = .system
        density = .system
        displayProfile = .balanced
        percentageMode = .remaining

        let desired = Self.selection(
            for: settingsStore.settings.appearance.themeID,
            in: themeStore
        ) ?? .builtIn(.morandi)
        try transition(to: desired, canonicalizeAppearance: true)
    }

    func selectTheme(id: String) throws {
        guard let desired = Self.selection(for: id, in: themeStore) else {
            throw ProductionThemeSettingsError.themeNotFound
        }
        try transition(to: desired, canonicalizeAppearance: false)
    }

    func resetTheme() throws {
        try transition(
            to: .builtIn(.morandi),
            canonicalizeAppearance: false
        )
    }

    func setColorScheme(_ value: AppearanceColorScheme) throws {
        var candidate = settingsStore.settings
        candidate.appearance.colorScheme = value.rawValue
        guard candidate != settingsStore.settings else {
            colorScheme = value
            return
        }
        do {
            try settingsStore.replace(with: candidate).get()
        } catch {
            throw ProductionThemeSettingsError.settingsPersistenceFailed
        }
        colorScheme = value
    }

    func setDensity(_ value: AppearanceDensity) throws {
        var candidate = settingsStore.settings
        candidate.appearance.density = value.rawValue
        guard candidate != settingsStore.settings else {
            density = value
            return
        }
        do {
            try settingsStore.replace(with: candidate).get()
        } catch {
            throw ProductionThemeSettingsError.settingsPersistenceFailed
        }
        density = value
    }

    func setDisplayProfile(_ value: DisplayProfile) throws {
        var candidate = settingsStore.settings
        candidate.appearance.displayProfile = value
        guard candidate != settingsStore.settings else {
            displayProfile = value
            return
        }
        do {
            try settingsStore.replace(with: candidate).get()
        } catch {
            throw ProductionThemeSettingsError.settingsPersistenceFailed
        }
        displayProfile = value
    }

    func setPercentageMode(_ value: PercentageMode) throws {
        var candidate = settingsStore.settings
        candidate.percentageMode = value
        guard candidate != settingsStore.settings else {
            percentageMode = value
            return
        }
        do {
            try settingsStore.replace(with: candidate).get()
        } catch {
            throw ProductionThemeSettingsError.settingsPersistenceFailed
        }
        percentageMode = value
    }

    func reloadFromPersistence() {
        publishActualState()
    }

    func refreshSelectedThemeDocument() {
        currentRasterData = nil
        if let selectedDocument = themeStore.document(for: selection) {
            currentTheme = selectedDocument
            switch selection {
            case let .builtIn(id):
                currentRasterData = artworkLoader.data(for: id)
            case .custom:
                currentRasterData = selectedDocument.rasterReference.flatMap {
                    try? themeStore.rasterData(for: $0)
                }
            }
        }
        colorScheme = Self.colorScheme(
            for: settingsStore.settings.appearance.colorScheme
        )
        density = Self.density(
            for: settingsStore.settings.appearance.density
        )
        displayProfile = settingsStore.settings.appearance.displayProfile
        percentageMode = settingsStore.settings.percentageMode
    }

    private func transition(
        to desired: ThemeSelection,
        canonicalizeAppearance: Bool
    ) throws {
        let previous = themeStore.snapshot.activeSelection
        let changedThemeStore = previous != desired
        if changedThemeStore {
            do {
                try apply(desired)
            } catch {
                throw ProductionThemeSettingsError.themePersistenceFailed
            }
        }

        var candidate = settingsStore.settings
        candidate.appearance.themeID = Self.persistedID(for: desired)
        if canonicalizeAppearance {
            candidate.appearance.colorScheme = Self.colorScheme(
                for: candidate.appearance.colorScheme
            ).rawValue
            candidate.appearance.density = Self.density(
                for: candidate.appearance.density
            ).rawValue
        }

        if candidate != settingsStore.settings {
            do {
                try settingsStore.replace(with: candidate).get()
            } catch {
                guard changedThemeStore else {
                    publishActualState()
                    throw ProductionThemeSettingsError
                        .settingsPersistenceFailed
                }
                do {
                    try apply(previous)
                } catch {
                    throw ProductionThemeSettingsError.rollbackFailed
                }
                publishActualState()
                throw ProductionThemeSettingsError.settingsPersistenceFailed
            }
        }

        publishActualState()
    }

    private func apply(_ selection: ThemeSelection) throws {
        switch selection {
        case let .builtIn(id):
            try themeStore.selectBuiltIn(id)
        case let .custom(id):
            try themeStore.activateCustom(id)
        }
    }

    private func publishActualState() {
        selection = themeStore.snapshot.activeSelection
        refreshSelectedThemeDocument()
    }

    private static func selection(
        for persistedID: String,
        in themeStore: ThemeStore
    ) -> ThemeSelection? {
        if let builtIn = BuiltInThemeID(rawValue: persistedID) {
            return .builtIn(builtIn)
        }
        let migratedBuiltIn: BuiltInThemeID? = switch persistedID {
        case "warm-illustration": .warmHandDrawn
        case "cartoon": .cartoonIllustration
        default: nil
        }
        if let migratedBuiltIn {
            return .builtIn(migratedBuiltIn)
        }
        guard let id = UUID(uuidString: persistedID),
              themeStore.snapshot.customThemes.contains(where: {
                  $0.id == id
              })
        else {
            return nil
        }
        return .custom(id)
    }

    private static func persistedID(for selection: ThemeSelection) -> String {
        switch selection {
        case let .builtIn(id): id.rawValue
        case let .custom(id): id.uuidString
        }
    }

    private static func colorScheme(
        for persistedValue: String
    ) -> AppearanceColorScheme {
        AppearanceColorScheme(rawValue: persistedValue) ?? .system
    }

    private static func density(
        for persistedValue: String
    ) -> AppearanceDensity {
        AppearanceDensity(rawValue: persistedValue) ?? .system
    }
}

@MainActor
final class ProductionThemeSettingsService:
    ThemeSettingsServicing,
    ThemeAppearanceSettingsServicing,
    PercentageModeSettingsServicing,
    SettingsRuntimeReloading
{
    let runtimeModel: ThemeRuntimeModel

    private let themeStore: ThemeStore
    private var allowsCustomEditor: Bool
    private weak var themeEditorPresenter: (any ThemeEditorPresenting)?

    init(
        themeStore: ThemeStore,
        settingsStore: SettingsStore,
        allowsCustomEditor: Bool = true,
        artworkLoader: BuiltInThemeArtworkLoader = BuiltInThemeArtworkLoader()
    ) throws {
        self.themeStore = themeStore
        self.allowsCustomEditor = allowsCustomEditor
        runtimeModel = try ThemeRuntimeModel(
            themeStore: themeStore,
            settingsStore: settingsStore,
            artworkLoader: artworkLoader
        )
    }

    func snapshot() -> ThemeSettingsSnapshot {
        let allowsTransfers = themeEditorPresenter != nil
        let builtIns = BuiltInThemes.all.map { theme in
            ThemeChoice(
                id: theme.id.rawValue,
                name: theme.document.name,
                isCustom: false
            )
        }
        let custom = themeStore.snapshot.customThemes.map { theme in
            ThemeChoice(
                id: theme.id.uuidString,
                name: theme.name,
                isCustom: true
            )
        }
        return ThemeSettingsSnapshot(
            choices: builtIns + custom,
            selectedThemeID: Self.persistedID(
                for: runtimeModel.selection
            ),
            selectedThemeDocument: runtimeModel.currentTheme,
            selectedThemeRasterData: runtimeModel.currentRasterData,
            allowsSelection: true,
            allowsReset: true,
            allowsImport: allowsTransfers,
            allowsExport: allowsTransfers,
            allowsCustomEditor: allowsCustomEditor,
            allowsColorScheme: true,
            allowsDensity: true,
            accessibilityFallbacksActive: true
        )
    }

    func selectTheme(id: String) throws {
        try runtimeModel.selectTheme(id: id)
    }

    func resetTheme() throws {
        try runtimeModel.resetTheme()
    }

    func setColorScheme(_ colorScheme: AppearanceColorScheme) throws {
        try runtimeModel.setColorScheme(colorScheme)
    }

    func setDensity(_ density: AppearanceDensity) throws {
        try runtimeModel.setDensity(density)
    }

    func setDisplayProfile(_ displayProfile: DisplayProfile) throws {
        try runtimeModel.setDisplayProfile(displayProfile)
    }

    func setPercentageMode(_ percentageMode: PercentageMode) throws {
        try runtimeModel.setPercentageMode(percentageMode)
    }

    func reloadRuntimeSettings() {
        runtimeModel.reloadFromPersistence()
    }

    func importTheme() throws {
        guard let themeEditorPresenter else {
            throw ProductionThemeSettingsError.transferUnavailable
        }
        themeEditorPresenter.startImport()
    }

    func exportTheme() throws {
        guard let themeEditorPresenter else {
            throw ProductionThemeSettingsError.transferUnavailable
        }
        themeEditorPresenter.startExport()
    }

    func setThemeEditorPresenter(
        _ presenter: (any ThemeEditorPresenting)?
    ) {
        themeEditorPresenter = presenter
        allowsCustomEditor = presenter != nil
    }

    private static func persistedID(for selection: ThemeSelection) -> String {
        switch selection {
        case let .builtIn(id): id.rawValue
        case let .custom(id): id.uuidString
        }
    }
}

@MainActor
struct ProductionThemeRuntimeBootstrap {
    let themeService: any ThemeSettingsServicing
    let runtimeModel: ThemeRuntimeModel?
    let themeEditorPresenter: (any ThemeEditorPresenting)?
    let themeEditorMutations: ThemeEditorMutationRelay?
    let localizationModel: AppLocalizationRuntimeModel

    static func make(
        settingsStore: SettingsStore,
        localizationModel: AppLocalizationRuntimeModel,
        makeThemeStore: @MainActor () throws -> ThemeStore = {
            try ThemeStore()
        },
        makeThemeEditorPresenter: @MainActor (
            ThemeStore,
            ThemeRuntimeModel,
            ThemeEditorMutationRelay,
            AppLocalizationRuntimeModel
        ) throws -> any ThemeEditorPresenting = {
            store, runtimeModel, mutations, localizationModel in
            try ProductionThemeEditorComposition.make(
                store: store,
                runtimeModel: runtimeModel,
                mutations: mutations,
                localizationModel: localizationModel
            ).presenter
        }
    ) -> ProductionThemeRuntimeBootstrap {
        do {
            let themeStore = try makeThemeStore()
            let service = try ProductionThemeSettingsService(
                themeStore: themeStore,
                settingsStore: settingsStore,
                allowsCustomEditor: false
            )
            let mutations = ThemeEditorMutationRelay()
            let themeEditorPresenter: (any ThemeEditorPresenting)?
            do {
                themeEditorPresenter = try makeThemeEditorPresenter(
                    themeStore,
                    service.runtimeModel,
                    mutations,
                    localizationModel
                )
            } catch {
                themeEditorPresenter = nil
            }
            service.setThemeEditorPresenter(themeEditorPresenter)
            return ProductionThemeRuntimeBootstrap(
                themeService: service,
                runtimeModel: service.runtimeModel,
                themeEditorPresenter: themeEditorPresenter,
                themeEditorMutations: themeEditorPresenter == nil
                    ? nil
                    : mutations,
                localizationModel: localizationModel
            )
        } catch {
            return ProductionThemeRuntimeBootstrap(
                themeService: PlaceholderThemeSettingsService(),
                runtimeModel: nil,
                themeEditorPresenter: nil,
                themeEditorMutations: nil,
                localizationModel: localizationModel
            )
        }
    }
}
