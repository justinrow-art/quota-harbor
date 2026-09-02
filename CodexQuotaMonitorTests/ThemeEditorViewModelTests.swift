import XCTest
@testable import CodexQuotaMonitor

@MainActor
final class ThemeEditorViewModelTests: XCTestCase {
    private let duplicateID = UUID(
        uuidString: "ED170001-0000-4000-8000-000000000001"
    )!

    func testDuplicateCreatesEditableDraftWithoutSavingOrActivating() {
        let manager = ThemeEditorManagerSpy()
        let picker = ThemeEditorPickerSpy()
        let viewModel = makeViewModel(manager: manager, picker: picker)

        viewModel.duplicateBuiltIn(named: "我的莫蘭迪")

        XCTAssertEqual(manager.duplicateRequests.count, 1)
        XCTAssertEqual(manager.duplicateRequests.first?.id, .morandi)
        XCTAssertEqual(manager.duplicateRequests.first?.name, "我的莫蘭迪")
        XCTAssertEqual(viewModel.draft.id, duplicateID)
        XCTAssertEqual(viewModel.draft.name, "我的莫蘭迪")
        XCTAssertTrue(viewModel.isCustomDraft)
        XCTAssertTrue(manager.saveRequests.isEmpty)
    }

    func testDraftChangesDriveLivePreviewForEveryBackgroundModeAndColor() {
        let viewModel = makeViewModel()
        viewModel.selectedAppearance = .dark

        viewModel.setBackground(.solid("#101112"))
        XCTAssertEqual(
            viewModel.previewTheme.appearances.dark.background,
            .solid("#101112")
        )

        viewModel.setBackground(
            .boundedGradient(["#101112", "#202122", "#303132"])
        )
        XCTAssertEqual(
            viewModel.previewTheme.appearances.dark.background,
            .boundedGradient(["#101112", "#202122", "#303132"])
        )

        viewModel.setBackground(.systemMaterial(.thick))
        XCTAssertEqual(
            viewModel.previewTheme.appearances.dark.background,
            .systemMaterial(.thick)
        )

        for (index, role) in ThemeEditorColorRole.allCases.enumerated() {
            let value = String(format: "#%06X", 0x101010 + index * 0x010101)
            viewModel.setColor(value, role: role)
            XCTAssertEqual(viewModel.color(for: role), value)
            XCTAssertEqual(viewModel.previewTheme, viewModel.draft)
        }
    }

    func testGeometryBoundsRemainPreviewableButBlockSaving() {
        let manager = ThemeEditorManagerSpy()
        let viewModel = makeViewModel(manager: manager)
        viewModel.duplicateBuiltIn(named: "幾何測試")

        viewModel.setNumericValue(41, field: .cornerRadius)

        XCTAssertEqual(viewModel.previewTheme.geometry.cornerRadius, 41)
        XCTAssertFalse(viewModel.canSaveAsActive)
        XCTAssertEqual(
            viewModel.validationMessage,
            viewModel.localizationModel.text.text(
                .themeEditorInvalidRange,
                viewModel.localizationModel.text.text(
                    .themeEditorGeometryCornerRadius
                ),
                localizedEditorNumber(
                    0,
                    locale: viewModel.localizationModel.locale
                ),
                localizedEditorNumber(
                    40,
                    locale: viewModel.localizationModel.locale
                )
            )
        )

        viewModel.save(activate: true)
        XCTAssertTrue(manager.saveRequests.isEmpty)

        viewModel.setNumericValue(40, field: .cornerRadius)
        viewModel.setNumericValue(6, field: .borderWidth)
        viewModel.setNumericValue(40, field: .shadowRadius)
        viewModel.setNumericValue(1, field: .materialOpacity)
        viewModel.setNumericValue(1, field: .ornamentOpacity)
        XCTAssertTrue(viewModel.canSaveAsActive)
    }

    func testRasterChooseAndRemoveUseOnlyInjectedPicker() async {
        let picker = ThemeEditorPickerSpy()
        picker.rasterResult = SanitizedRasterReference(
            relativeIdentifier: String(repeating: "a", count: 64) + ".png",
            sha256: String(repeating: "a", count: 64)
        )
        let viewModel = makeViewModel(picker: picker)

        await viewModel.chooseRaster()

        XCTAssertEqual(picker.rasterPickCount, 1)
        XCTAssertEqual(viewModel.draft.rasterReference, picker.rasterResult)

        viewModel.removeRaster()
        XCTAssertNil(viewModel.draft.rasterReference)
    }

    func testInvalidContrastStaysInPreviewAndExplainsWhyActivationIsBlocked() {
        let manager = ThemeEditorManagerSpy()
        let viewModel = makeViewModel(manager: manager)
        viewModel.selectedAppearance = .light

        viewModel.setBackground(.solid("#FFFFFF"))
        viewModel.setColor("#FFFFFF", role: .background)
        viewModel.setColor("#FFFFFF", role: .text)

        XCTAssertEqual(
            viewModel.previewTheme.appearances.light.palette.text,
            "#FFFFFF"
        )
        XCTAssertFalse(viewModel.canSaveAsActive)
        XCTAssertEqual(
            viewModel.validationMessage,
            viewModel.localizationModel.text.text(
                .themeEditorInvalidContrast,
                viewModel.localizationModel.text.text(.settingsLight),
                viewModel.localizationModel.text.text(
                    .themeEditorColorPrimaryText
                )
            )
        )

        viewModel.save(activate: true)
        XCTAssertTrue(manager.saveRequests.isEmpty)
    }

    func testSaveAndActivateUsesOneAtomicManagerRequest() {
        let manager = ThemeEditorManagerSpy()
        let viewModel = makeViewModel(manager: manager)
        viewModel.duplicateBuiltIn(named: "可儲存主題")

        viewModel.save(activate: false)
        viewModel.save(activate: true)

        XCTAssertEqual(manager.saveRequests.count, 2)
        XCTAssertFalse(manager.saveRequests[0].activate)
        XCTAssertTrue(manager.saveRequests[1].activate)
        XCTAssertEqual(manager.saveRequests[1].document.id, duplicateID)
        XCTAssertEqual(viewModel.operationState, .saveApplied)
        XCTAssertEqual(
            viewModel.operationMessage,
            viewModel.localizationModel.text.text(.themeEditorSaveApplied)
        )
    }

    func testResetImportAndExportFlowThroughInjectedBoundaries() async {
        let manager = ThemeEditorManagerSpy()
        let picker = ThemeEditorPickerSpy()
        manager.resetResult = BuiltInThemes.sketch.document
        var imported = BuiltInThemes.cyberpunk.document
        imported.name = "已驗證的匯入主題"
        picker.importResult = imported
        let viewModel = makeViewModel(manager: manager, picker: picker)

        viewModel.reset()
        XCTAssertEqual(manager.resetCount, 1)
        XCTAssertEqual(viewModel.draft, BuiltInThemes.sketch.document)

        await viewModel.importTheme()
        XCTAssertEqual(picker.importPickCount, 1)
        XCTAssertEqual(viewModel.draft, imported)

        viewModel.includeRasterInExport = true
        await viewModel.exportTheme()
        XCTAssertEqual(picker.exportRequests.count, 1)
        XCTAssertEqual(picker.exportRequests[0].document, imported)
        XCTAssertTrue(picker.exportRequests[0].includeRaster)
    }

    func testCancelRestoresOpeningDraftWithoutStoreMutation() {
        let manager = ThemeEditorManagerSpy()
        let picker = ThemeEditorPickerSpy()
        let viewModel = makeViewModel(manager: manager, picker: picker)
        let openingDraft = viewModel.draft

        viewModel.rename("未儲存變更")
        viewModel.setNumericValue(33, field: .cornerRadius)
        viewModel.cancel()

        XCTAssertEqual(viewModel.draft, openingDraft)
        XCTAssertTrue(viewModel.isCancelled)
        XCTAssertTrue(manager.saveRequests.isEmpty)
        XCTAssertEqual(manager.resetCount, 0)
        XCTAssertEqual(picker.rasterPickCount, 0)
        XCTAssertEqual(picker.importPickCount, 0)
        XCTAssertTrue(picker.exportRequests.isEmpty)
    }

    func testKeyboardFocusOrderIsStableAndCoversAllEditorActions() {
        let expected = [
            "name",
            "duplicateName",
            "duplicate",
            "appearance",
            "backgroundKind",
            "backgroundValue",
            "background",
            "text",
            "secondaryText",
            "accent",
            "healthy",
            "warning",
            "critical",
            "stale",
            "unavailable",
            "border",
            "focus",
            "cornerRadius",
            "borderWidth",
            "shadowRadius",
            "materialOpacity",
            "ornamentOpacity",
            "rasterChoose",
            "rasterRemove",
            "includeRaster",
            "importTheme",
            "exportTheme",
            "reset",
            "previewState",
            "cancel",
            "save",
            "saveAndActivate",
        ]

        XCTAssertEqual(
            ThemeEditorViewModel.keyboardFocusOrder.map(\.rawValue),
            expected
        )
        XCTAssertEqual(Set(expected).count, expected.count)
    }

    func testValidationAndExistingOperationMessageFollowLiveLanguage() {
        let localizationModel = AppLocalizationRuntimeModel(
            language: .english,
            systemLocale: Locale(identifier: "en_US")
        )
        let manager = ThemeEditorManagerSpy()
        let viewModel = makeViewModel(
            manager: manager,
            localizationModel: localizationModel
        )

        viewModel.rename("   ")
        XCTAssertEqual(
            viewModel.validationMessage,
            localizationModel.text.text(.themeEditorInvalidName)
        )

        localizationModel.language = .japanese
        XCTAssertEqual(
            viewModel.validationMessage,
            localizationModel.text.text(.themeEditorInvalidName)
        )

        localizationModel.language = .english
        viewModel.rename("Editable")
        viewModel.duplicateBuiltIn(named: "Editable Copy")
        viewModel.save(activate: false)
        XCTAssertEqual(viewModel.operationState, .saveSucceeded)
        XCTAssertEqual(
            viewModel.operationMessage,
            localizationModel.text.text(.themeEditorSaveSucceeded)
        )

        localizationModel.language = .japanese
        XCTAssertEqual(viewModel.operationState, .saveSucceeded)
        XCTAssertEqual(
            viewModel.operationMessage,
            localizationModel.text.text(.themeEditorSaveSucceeded)
        )
    }

    func testSavedButNotAppliedIsTypedAndNeverClaimsSaveFailed() {
        let localizationModel = AppLocalizationRuntimeModel(
            language: .english,
            systemLocale: Locale(identifier: "en_US")
        )
        let manager = ThemeEditorManagerSpy()
        let viewModel = makeViewModel(
            manager: manager,
            localizationModel: localizationModel
        )
        viewModel.duplicateBuiltIn(named: "Durable Draft")
        manager.error = ThemeEditorSaveError.savedButNotApplied

        viewModel.save(activate: true)

        XCTAssertEqual(viewModel.operationState, .savedNotApplied)
        XCTAssertEqual(
            viewModel.operationMessage,
            localizationModel.text.text(.themeEditorSavedNotApplied)
        )
        XCTAssertNotEqual(
            viewModel.operationMessage,
            localizationModel.text.text(.themeEditorSaveFailed)
        )
        XCTAssertFalse(viewModel.isCancelled)
    }

    func testValidationUsesLocalizedRoleKeysWithoutFrozenCopy() {
        let localizationModel = AppLocalizationRuntimeModel(
            language: .english,
            systemLocale: Locale(identifier: "en_US")
        )
        let viewModel = makeViewModel(
            localizationModel: localizationModel
        )
        viewModel.duplicateBuiltIn(named: "Validation")
        viewModel.setNumericValue(41, field: .cornerRadius)

        XCTAssertEqual(
            viewModel.validationMessage,
            localizationModel.text.text(
                .themeEditorInvalidRange,
                localizationModel.text.text(
                    .themeEditorGeometryCornerRadius
                ),
                localizedEditorNumber(
                    0,
                    locale: localizationModel.locale
                ),
                localizedEditorNumber(
                    40,
                    locale: localizationModel.locale
                )
            )
        )

        localizationModel.language = .german
        XCTAssertEqual(
            viewModel.validationMessage,
            localizationModel.text.text(
                .themeEditorInvalidRange,
                localizationModel.text.text(
                    .themeEditorGeometryCornerRadius
                ),
                localizedEditorNumber(
                    0,
                    locale: localizationModel.locale
                ),
                localizedEditorNumber(
                    40,
                    locale: localizationModel.locale
                )
            )
        )
    }

    func testPreviewDisplayNameLocalizesBuiltInsButPreservesCustomNames() {
        let localizationModel = AppLocalizationRuntimeModel(
            language: .english,
            systemLocale: Locale(identifier: "en_US")
        )
        let viewModel = makeViewModel(
            localizationModel: localizationModel
        )

        XCTAssertEqual(
            viewModel.previewDisplayName,
            localizationModel.text.text(.themeMorandi)
        )

        localizationModel.language = .japanese
        XCTAssertEqual(
            viewModel.previewDisplayName,
            localizationModel.text.text(.themeMorandi)
        )

        viewModel.duplicateBuiltIn(named: "User Theme")
        localizationModel.language = .german
        XCTAssertEqual(viewModel.previewDisplayName, "User Theme")
    }

    func testColorAndGradientValidationUseWholeLocalizedSentences() {
        let localizationModel = AppLocalizationRuntimeModel(
            language: .english,
            systemLocale: Locale(identifier: "en_US")
        )
        let viewModel = makeViewModel(
            localizationModel: localizationModel
        )
        viewModel.duplicateBuiltIn(named: "Validation")
        viewModel.selectedAppearance = .light
        viewModel.setColor("invalid", role: .accent)

        XCTAssertEqual(
            viewModel.validationMessage,
            localizationModel.text.text(
                .themeEditorInvalidColor,
                localizationModel.text.text(.settingsLight),
                localizationModel.text.text(.themeEditorColorAccent)
            )
        )

        viewModel.setColor("#88AACC", role: .accent)
        viewModel.setBackground(.boundedGradient(["#FFFFFF"]))
        XCTAssertEqual(
            viewModel.validationMessage,
            localizationModel.text.text(
                .themeEditorInvalidGradientStopCount,
                localizationModel.text.text(.settingsLight),
                Int64(1)
            )
        )
    }

    private func makeViewModel(
        manager: ThemeEditorManagerSpy = ThemeEditorManagerSpy(),
        picker: ThemeEditorPickerSpy = ThemeEditorPickerSpy(),
        localizationModel: AppLocalizationRuntimeModel =
            AppLocalizationRuntimeModel(
                language: .traditionalChinese,
                systemLocale: Locale(identifier: "zh_Hant")
            )
    ) -> ThemeEditorViewModel {
        manager.duplicateResultID = duplicateID
        return ThemeEditorViewModel(
            sourceTheme: BuiltInThemes.morandi.document,
            sourceBuiltInID: .morandi,
            manager: manager,
            picker: picker,
            localizationModel: localizationModel
        )
    }
}

private func localizedEditorNumber(
    _ value: Double,
    locale: Locale
) -> String {
    value.formatted(
        .number
            .precision(.fractionLength(0 ... 2))
            .locale(locale)
    )
}

@MainActor
private final class ThemeEditorManagerSpy: ThemeEditorManaging {
    struct DuplicateRequest: Equatable {
        let id: BuiltInThemeID
        let name: String
    }

    struct SaveRequest: Equatable {
        let document: ThemeDocument
        let activate: Bool
    }

    var duplicateResultID = UUID()
    var resetResult = BuiltInThemes.morandi.document
    var error: (any Error)?
    private(set) var duplicateRequests: [DuplicateRequest] = []
    private(set) var saveRequests: [SaveRequest] = []
    private(set) var resetCount = 0

    func duplicateBuiltIn(
        _ id: BuiltInThemeID,
        named name: String
    ) throws -> ThemeDocument {
        duplicateRequests.append(DuplicateRequest(id: id, name: name))
        if let error { throw error }
        let source = BuiltInThemes.all.first { $0.id == id }!.document
        return ThemeDocument(
            schemaVersion: source.schemaVersion,
            id: duplicateResultID,
            name: name,
            appearances: source.appearances,
            geometry: source.geometry,
            ornamentOpacity: source.ornamentOpacity,
            rasterReference: source.rasterReference
        )
    }

    func saveCustom(_ document: ThemeDocument, activate: Bool) throws {
        if let error { throw error }
        saveRequests.append(SaveRequest(document: document, activate: activate))
    }

    func reset() throws -> ThemeDocument {
        if let error { throw error }
        resetCount += 1
        return resetResult
    }

    func cancelDraft() {}
}

@MainActor
private final class ThemeEditorPickerSpy: ThemeEditorPicking {
    struct ExportRequest: Equatable {
        let document: ThemeDocument
        let includeRaster: Bool
    }

    var rasterResult: SanitizedRasterReference?
    var importResult: ThemeDocument?
    var error: (any Error)?
    private(set) var rasterPickCount = 0
    private(set) var importPickCount = 0
    private(set) var exportRequests: [ExportRequest] = []

    func pickSanitizedRaster() async throws -> SanitizedRasterReference? {
        rasterPickCount += 1
        if let error { throw error }
        return rasterResult
    }

    func pickValidatedThemeForImport() async throws -> ThemeDocument? {
        importPickCount += 1
        if let error { throw error }
        return importResult
    }

    func exportTheme(
        _ document: ThemeDocument,
        includeRaster: Bool
    ) async throws -> Bool {
        if let error { throw error }
        exportRequests.append(
            ExportRequest(document: document, includeRaster: includeRaster)
        )
        return true
    }
}
