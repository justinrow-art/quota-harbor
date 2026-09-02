import Foundation
import Observation

@MainActor
protocol ThemeEditorManaging: AnyObject {
    func duplicateBuiltIn(
        _ id: BuiltInThemeID,
        named name: String
    ) throws -> ThemeDocument

    func saveCustom(_ document: ThemeDocument, activate: Bool) throws
    func reset() throws -> ThemeDocument
    func cancelDraft()
    func rasterData(for reference: SanitizedRasterReference) -> Data?
}

extension ThemeEditorManaging {
    func rasterData(for reference: SanitizedRasterReference) -> Data? { nil }
}

/// Production adapters may show file panels and invoke the raster/import
/// security pipeline. Tests inject a fake and never open a real panel.
@MainActor
protocol ThemeEditorPicking: AnyObject {
    func pickSanitizedRaster() async throws -> SanitizedRasterReference?
    func pickValidatedThemeForImport() async throws -> ThemeDocument?
    func exportTheme(
        _ document: ThemeDocument,
        includeRaster: Bool
    ) async throws -> Bool
    func rasterData(for reference: SanitizedRasterReference) -> Data?
}

extension ThemeEditorPicking {
    func rasterData(for reference: SanitizedRasterReference) -> Data? { nil }
}

enum ThemeEditorBackgroundKind: String, CaseIterable, Hashable, Sendable {
    case solid
    case boundedGradient
    case systemMaterial
}

enum ThemeEditorSaveError: Error, Equatable, Sendable {
    case savedButNotApplied
}

enum ThemeEditorOperationState: Equatable, Sendable {
    case duplicateUnavailable
    case duplicateFailed
    case imageUnsafe
    case saveSucceeded
    case saveApplied
    case savedNotApplied
    case saveFailed
    case resetSucceeded
    case resetFailed
    case importLoaded
    case importFailed
    case exportSucceeded
    case exportFailed

    func message(using text: LocalizedTextProvider) -> String {
        let key: LocalizationCatalogKey = switch self {
        case .duplicateUnavailable: .themeEditorDuplicateUnavailable
        case .duplicateFailed: .themeEditorDuplicateFailed
        case .imageUnsafe: .themeEditorImageUnsafe
        case .saveSucceeded: .themeEditorSaveSucceeded
        case .saveApplied: .themeEditorSaveApplied
        case .savedNotApplied: .themeEditorSavedNotApplied
        case .saveFailed: .themeEditorSaveFailed
        case .resetSucceeded: .themeEditorResetSucceeded
        case .resetFailed: .themeEditorResetFailed
        case .importLoaded: .themeEditorImportLoaded
        case .importFailed: .themeEditorImportFailed
        case .exportSucceeded: .themeEditorExportSucceeded
        case .exportFailed: .themeEditorExportFailed
        }
        return text.text(key)
    }
}

enum ThemeEditorColorRole: String, CaseIterable, Hashable, Sendable {
    case background
    case text
    case secondaryText
    case accent
    case healthy
    case warning
    case critical
    case stale
    case unavailable
    case border
    case focus

    func title(using text: LocalizedTextProvider) -> String {
        let key: LocalizationCatalogKey = switch self {
        case .background: .themeEditorColorBackground
        case .text: .themeEditorColorPrimaryText
        case .secondaryText: .themeEditorColorSecondaryText
        case .accent: .themeEditorColorAccent
        case .healthy: .themeEditorColorHealthy
        case .warning: .themeEditorColorWarning
        case .critical: .themeEditorColorCritical
        case .stale: .themeEditorColorStale
        case .unavailable: .themeEditorColorUnavailable
        case .border: .themeEditorColorBorder
        case .focus: .themeEditorColorFocusRing
        }
        return text.text(key)
    }

    var focusTarget: ThemeEditorFocusTarget {
        switch self {
        case .background: .background
        case .text: .text
        case .secondaryText: .secondaryText
        case .accent: .accent
        case .healthy: .healthy
        case .warning: .warning
        case .critical: .critical
        case .stale: .stale
        case .unavailable: .unavailable
        case .border: .border
        case .focus: .focus
        }
    }
}

enum ThemeEditorNumericField: String, CaseIterable, Hashable, Sendable {
    case cornerRadius
    case borderWidth
    case shadowRadius
    case materialOpacity
    case ornamentOpacity

    func title(using text: LocalizedTextProvider) -> String {
        let key: LocalizationCatalogKey = switch self {
        case .cornerRadius: .themeEditorGeometryCornerRadius
        case .borderWidth: .themeEditorGeometryBorderWidth
        case .shadowRadius: .themeEditorGeometryShadowRadius
        case .materialOpacity: .themeEditorGeometryMaterialOpacity
        case .ornamentOpacity: .themeEditorGeometryDecorativeOpacity
        }
        return text.text(key)
    }

    var permittedRange: ClosedRange<Double> {
        switch self {
        case .cornerRadius, .shadowRadius: 0 ... 40
        case .borderWidth: 0 ... 6
        case .materialOpacity, .ornamentOpacity: 0 ... 1
        }
    }

    var focusTarget: ThemeEditorFocusTarget {
        switch self {
        case .cornerRadius: .cornerRadius
        case .borderWidth: .borderWidth
        case .shadowRadius: .shadowRadius
        case .materialOpacity: .materialOpacity
        case .ornamentOpacity: .ornamentOpacity
        }
    }
}

enum ThemeEditorFocusTarget: String, CaseIterable, Hashable, Sendable {
    case name
    case duplicateName
    case duplicate
    case appearance
    case backgroundKind
    case backgroundValue
    case background
    case text
    case secondaryText
    case accent
    case healthy
    case warning
    case critical
    case stale
    case unavailable
    case border
    case focus
    case cornerRadius
    case borderWidth
    case shadowRadius
    case materialOpacity
    case ornamentOpacity
    case rasterChoose
    case rasterRemove
    case includeRaster
    case importTheme
    case exportTheme
    case reset
    case previewState
    case cancel
    case save
    case saveAndActivate
}

@MainActor
@Observable
final class ThemeEditorViewModel {
    static let keyboardFocusOrder = ThemeEditorFocusTarget.allCases

    var draft: ThemeDocument
    var selectedAppearance: ThemeAppearance = .light
    var previewAvailability: ThemeAvailabilityState = .fresh
    var includeRasterInExport = false
    private(set) var operationState: ThemeEditorOperationState?
    private(set) var isCancelled = false
    private(set) var isBusy = false
    private(set) var previewRasterData: Data?

    let localizationModel: AppLocalizationRuntimeModel

    @ObservationIgnored private let sourceBuiltInID: BuiltInThemeID?
    @ObservationIgnored private let manager: any ThemeEditorManaging
    @ObservationIgnored private let picker: any ThemeEditorPicking
    private var openingDraft: ThemeDocument
    private var openingRasterData: Data?
    private var operationGeneration: UInt64 = 0

    init(
        sourceTheme: ThemeDocument,
        sourceBuiltInID: BuiltInThemeID?,
        manager: any ThemeEditorManaging,
        picker: any ThemeEditorPicking,
        localizationModel: AppLocalizationRuntimeModel
    ) {
        draft = sourceTheme
        openingDraft = sourceTheme
        self.sourceBuiltInID = sourceBuiltInID
        self.manager = manager
        self.picker = picker
        self.localizationModel = localizationModel
        let rasterData = sourceTheme.rasterReference.flatMap {
            manager.rasterData(for: $0)
        }
        previewRasterData = rasterData
        openingRasterData = rasterData
    }

    var previewTheme: ThemeDocument { draft }

    var previewDisplayName: String {
        guard let builtIn = BuiltInThemes.all.first(where: {
            $0.document.id == draft.id
        }) else {
            return draft.name
        }
        let key: LocalizationCatalogKey = switch builtIn.id {
        case .morandi: .themeMorandi
        case .cyberpunk: .themeCyberpunk
        case .warmHandDrawn: .themeWarmHandDrawn
        case .glass: .themeGlass
        case .sketch: .themeSketch
        case .cartoonIllustration: .themeCartoonIllustration
        }
        return localizationModel.text.text(key)
    }

    var isCustomDraft: Bool {
        !BuiltInThemes.all.contains { $0.document.id == draft.id }
    }

    var backgroundKind: ThemeEditorBackgroundKind {
        switch draft.appearances[selectedAppearance].background {
        case .solid: .solid
        case .boundedGradient: .boundedGradient
        case .systemMaterial: .systemMaterial
        }
    }

    var canSaveAsActive: Bool {
        !isBusy && validationMessage == nil
    }

    var operationMessage: String? {
        operationState?.message(using: localizationModel.text)
    }

    var validationMessage: String? {
        let text = localizationModel.text
        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text.text(.themeEditorInvalidName)
        }
        if let error = validationError {
            return Self.message(for: error, text: text)
        }
        if !isCustomDraft {
            return text.text(.themeEditorBuiltInReadOnly)
        }
        return nil
    }

    func duplicateBuiltIn(named name: String) {
        guard let sourceBuiltInID else {
            operationState = .duplicateUnavailable
            return
        }
        do {
            let duplicate = try manager.duplicateBuiltIn(
                sourceBuiltInID,
                named: name
            )
            draft = duplicate
            openingDraft = duplicate
            let rasterData = duplicate.rasterReference.flatMap {
                manager.rasterData(for: $0)
            }
            previewRasterData = rasterData
            openingRasterData = rasterData
            operationState = nil
            isCancelled = false
        } catch {
            operationState = .duplicateFailed
        }
    }

    func rename(_ name: String) {
        draft.name = name
        operationState = nil
    }

    func setBackground(_ background: ThemeBackground) {
        var tokens = draft.appearances[selectedAppearance]
        tokens.background = background
        draft.appearances[selectedAppearance] = tokens
        operationState = nil
    }

    func selectBackgroundKind(_ kind: ThemeEditorBackgroundKind) {
        let paletteBackground = color(for: .background)
        switch kind {
        case .solid:
            setBackground(.solid(paletteBackground))
        case .boundedGradient:
            setBackground(
                .boundedGradient([paletteBackground, paletteBackground])
            )
        case .systemMaterial:
            setBackground(.systemMaterial(.regular))
        }
    }

    func color(for role: ThemeEditorColorRole) -> String {
        let palette = draft.appearances[selectedAppearance].palette
        return switch role {
        case .background: palette.background
        case .text: palette.text
        case .secondaryText: palette.secondaryText
        case .accent: palette.accent
        case .healthy: palette.healthy
        case .warning: palette.warning
        case .critical: palette.critical
        case .stale: palette.stale
        case .unavailable: palette.unavailable
        case .border: palette.border
        case .focus: palette.focus
        }
    }

    func setColor(_ value: String, role: ThemeEditorColorRole) {
        var tokens = draft.appearances[selectedAppearance]
        switch role {
        case .background: tokens.palette.background = value
        case .text: tokens.palette.text = value
        case .secondaryText: tokens.palette.secondaryText = value
        case .accent: tokens.palette.accent = value
        case .healthy: tokens.palette.healthy = value
        case .warning: tokens.palette.warning = value
        case .critical: tokens.palette.critical = value
        case .stale: tokens.palette.stale = value
        case .unavailable: tokens.palette.unavailable = value
        case .border: tokens.palette.border = value
        case .focus: tokens.palette.focus = value
        }
        draft.appearances[selectedAppearance] = tokens
        operationState = nil
    }

    func numericValue(for field: ThemeEditorNumericField) -> Double {
        switch field {
        case .cornerRadius: draft.geometry.cornerRadius
        case .borderWidth: draft.geometry.borderWidth
        case .shadowRadius: draft.geometry.shadowRadius
        case .materialOpacity: draft.geometry.materialOpacity
        case .ornamentOpacity: draft.ornamentOpacity
        }
    }

    func setNumericValue(_ value: Double, field: ThemeEditorNumericField) {
        switch field {
        case .cornerRadius: draft.geometry.cornerRadius = value
        case .borderWidth: draft.geometry.borderWidth = value
        case .shadowRadius: draft.geometry.shadowRadius = value
        case .materialOpacity: draft.geometry.materialOpacity = value
        case .ornamentOpacity: draft.ornamentOpacity = value
        }
        operationState = nil
    }

    func chooseRaster() async {
        guard let generation = beginAsyncOperation() else { return }
        defer { finishAsyncOperation(generation) }
        do {
            let raster = try await picker.pickSanitizedRaster()
            guard isCurrentOperation(generation), let raster else {
                return
            }
            draft.rasterReference = raster
            previewRasterData = picker.rasterData(for: raster)
            operationState = nil
        } catch {
            guard isCurrentOperation(generation) else { return }
            operationState = .imageUnsafe
        }
    }

    func removeRaster() {
        draft.rasterReference = nil
        previewRasterData = nil
        operationState = nil
    }

    func save(activate: Bool) {
        guard canSaveAsActive else {
            return
        }
        do {
            try manager.saveCustom(draft, activate: activate)
            openingDraft = draft
            openingRasterData = previewRasterData
            operationState = activate ? .saveApplied : .saveSucceeded
            isCancelled = false
        } catch ThemeEditorSaveError.savedButNotApplied {
            openingDraft = draft
            openingRasterData = previewRasterData
            operationState = .savedNotApplied
            isCancelled = false
        } catch {
            operationState = .saveFailed
        }
    }

    func reset() {
        do {
            let resetTheme = try manager.reset()
            draft = resetTheme
            openingDraft = resetTheme
            let rasterData = resetTheme.rasterReference.flatMap {
                manager.rasterData(for: $0)
            }
            previewRasterData = rasterData
            openingRasterData = rasterData
            operationState = .resetSucceeded
            isCancelled = false
        } catch {
            operationState = .resetFailed
        }
    }

    func importTheme() async {
        guard let generation = beginAsyncOperation() else { return }
        defer { finishAsyncOperation(generation) }
        do {
            let imported = try await picker.pickValidatedThemeForImport()
            guard isCurrentOperation(generation), let imported else {
                return
            }
            draft = imported
            previewRasterData = imported.rasterReference.flatMap {
                picker.rasterData(for: $0)
            }
            operationState = .importLoaded
            isCancelled = false
        } catch {
            guard isCurrentOperation(generation) else { return }
            operationState = .importFailed
        }
    }

    func exportTheme() async {
        guard let generation = beginAsyncOperation() else { return }
        defer { finishAsyncOperation(generation) }
        do {
            let exported = try await picker.exportTheme(
                draft,
                includeRaster: includeRasterInExport
            )
            guard isCurrentOperation(generation) else { return }
            operationState = exported ? .exportSucceeded : nil
        } catch {
            guard isCurrentOperation(generation) else { return }
            operationState = .exportFailed
        }
    }

    func cancel() {
        operationGeneration &+= 1
        isBusy = false
        manager.cancelDraft()
        draft = openingDraft
        previewRasterData = openingRasterData
        operationState = nil
        isCancelled = true
    }

    private func beginAsyncOperation() -> UInt64? {
        guard !isBusy else { return nil }
        isBusy = true
        return operationGeneration
    }

    private func isCurrentOperation(_ generation: UInt64) -> Bool {
        generation == operationGeneration && !isCancelled
    }

    private func finishAsyncOperation(_ generation: UInt64) {
        guard generation == operationGeneration else { return }
        isBusy = false
    }

    private var validationError: ThemeValidationError? {
        let context = ThemeResolutionContext(
            appearance: selectedAppearance,
            accessibility: ThemeAccessibilityPreferences(
                increaseContrast: false,
                reduceTransparency: false,
                reduceMotion: false,
                textScale: 1
            )
        )
        if case let .failure(error) = ThemeValidator(context: context)
            .validate(draft)
        {
            return error
        }
        return nil
    }

    private static func message(
        for error: ThemeValidationError,
        text: LocalizedTextProvider
    ) -> String {
        switch error {
        case let .outOfBounds(field), let .nonFiniteNumeric(field):
            let editorField = ThemeEditorNumericField(rawValue: field.rawValue)
            let title = editorField?.title(using: text)
                ?? text.text(.themeEditorGeometry)
            let range = editorField?.permittedRange ?? 0 ... 0
            return text.text(
                .themeEditorInvalidRange,
                title,
                number(range.lowerBound, text: text),
                number(range.upperBound, text: text)
            )
        case let .insufficientTextContrast(appearance, role):
            return text.text(
                .themeEditorInvalidContrast,
                appearanceTitle(appearance, text: text),
                textRoleTitle(role, text: text)
            )
        case let .invalidColor(appearance, role):
            return text.text(
                .themeEditorInvalidColor,
                appearanceTitle(appearance, text: text),
                colorRoleTitle(role, text: text)
            )
        case let .invalidGradientStopCount(appearance, count):
            return text.text(
                .themeEditorInvalidGradientStopCount,
                appearanceTitle(appearance, text: text),
                Int64(count)
            )
        case .unsupportedSchema:
            return text.text(.themeEditorUnsupportedVersion)
        }
    }

    private static func number(
        _ value: Double,
        text: LocalizedTextProvider
    ) -> String {
        value.formatted(
            .number
                .precision(.fractionLength(0 ... 2))
                .locale(text.locale.foundationLocale)
        )
    }

    private static func appearanceTitle(
        _ appearance: ThemeAppearance,
        text: LocalizedTextProvider
    ) -> String {
        text.text(appearance == .light ? .settingsLight : .settingsDark)
    }

    private static func textRoleTitle(
        _ role: ThemeTextRole,
        text: LocalizedTextProvider
    ) -> String {
        let key: LocalizationCatalogKey = switch role {
        case .primary: .themeEditorColorPrimaryText
        case .secondary: .themeEditorColorSecondaryText
        case .action: .themeEditorTextAction
        }
        return text.text(key)
    }

    private static func colorRoleTitle(
        _ role: ThemeColorRole,
        text: LocalizedTextProvider
    ) -> String {
        let key: LocalizationCatalogKey = switch role {
        case .background: .themeEditorColorBackground
        case .text: .themeEditorColorPrimaryText
        case .secondaryText: .themeEditorColorSecondaryText
        case .accent: .themeEditorColorAccent
        case .healthy: .themeEditorColorHealthy
        case .warning: .themeEditorColorWarning
        case .critical: .themeEditorColorCritical
        case .stale: .themeEditorColorStale
        case .unavailable: .themeEditorColorUnavailable
        case .border: .themeEditorColorBorder
        case .focus: .themeEditorColorFocusRing
        case .backgroundSurface: .themeEditorColorBackgroundSurface
        }
        return text.text(key)
    }
}
