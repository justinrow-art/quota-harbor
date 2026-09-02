import SwiftUI

struct ThemeEditorCopy {
    let text: LocalizedTextProvider

    var title: String { text.text(.themeEditorTitle) }
    var name: String { text.text(.themeEditorName) }
    var duplicateName: String { text.text(.themeEditorDuplicateName) }
    var duplicateBuiltIn: String { text.text(.themeEditorDuplicateBuiltIn) }
    var appearance: String { text.text(.themeEditorAppearance) }
    var background: String { text.text(.themeEditorBackground) }
    var backgroundType: String { text.text(.themeEditorBackgroundType) }
    var semanticColors: String { text.text(.themeEditorSemanticColors) }
    var geometry: String { text.text(.themeEditorGeometry) }
    var solidColorPlaceholder: String {
        text.text(.themeEditorSolidColorPlaceholder)
    }
    var gradientStopsPlaceholder: String {
        text.text(.themeEditorGradientStopsPlaceholder)
    }
    var colorHexPlaceholder: String {
        text.text(.themeEditorColorHexPlaceholder)
    }
    var raster: String { text.text(.themeEditorRaster) }
    var rasterNone: String { text.text(.themeEditorRasterNone) }
    var rasterSanitized: String { text.text(.themeEditorRasterSanitized) }
    var rasterPolicy: String { text.text(.themeEditorRasterPolicy) }
    var chooseImage: String { text.text(.actionChooseImage) }
    var remove: String { text.text(.actionRemove) }
    var transfer: String { text.text(.themeEditorTransfer) }
    var includeRaster: String { text.text(.themeEditorIncludeRaster) }
    var importTheme: String { text.text(.actionImport) }
    var exportTheme: String { text.text(.actionExport) }
    var resetToBuiltIn: String { text.text(.themeEditorResetToBuiltIn) }
    var preview: String { text.text(.themeEditorPreview) }
    var dataState: String { text.text(.themeEditorDataState) }
    var safeToSave: String { text.text(.themeEditorSafeToSave) }
    var cancel: String { text.text(.actionCancel) }
    var save: String { text.text(.actionSave) }
    var saveAndApply: String { text.text(.actionSaveAndApply) }

    func duplicateDefaultName(for name: String) -> String {
        text.text(.themeEditorDuplicateDefaultName, name)
    }

    func appearance(_ appearance: ThemeAppearance) -> String {
        text.text(appearance == .light ? .settingsLight : .settingsDark)
    }

    func backgroundKind(_ kind: ThemeEditorBackgroundKind) -> String {
        let key: LocalizationCatalogKey = switch kind {
        case .solid: .themeEditorSolid
        case .boundedGradient: .themeEditorGradient
        case .systemMaterial: .themeEditorSystemMaterial
        }
        return text.text(key)
    }

    func material(_ material: SystemThemeMaterial) -> String {
        let key: LocalizationCatalogKey = switch material {
        case .ultraThin: .themeEditorMaterialUltraThin
        case .thin: .themeEditorMaterialThin
        case .regular: .themeEditorMaterialRegular
        case .thick: .themeEditorMaterialThick
        case .ultraThick: .themeEditorMaterialUltraThick
        }
        return text.text(key)
    }

    func colorRole(_ role: ThemeEditorColorRole) -> String {
        role.title(using: text)
    }

    func numericField(_ field: ThemeEditorNumericField) -> String {
        field.title(using: text)
    }

    func availability(_ state: ThemeAvailabilityState) -> String {
        let key: LocalizationCatalogKey = switch state {
        case .loading: .themeStateLoading
        case .fresh: .themeStateFresh
        case .partial: .themeStatePartial
        case .stale: .themeStateStale
        case .unsupported: .themeStateUnsupported
        case .unavailable: .themeStateUnavailable
        }
        return text.text(key)
    }
}

struct CustomThemeEditorView: View {
    @Bindable var viewModel: ThemeEditorViewModel
    @Bindable var localizationModel: AppLocalizationRuntimeModel
    let onClose: () -> Void

    @FocusState private var focusedField: ThemeEditorFocusTarget?
    @State private var duplicateName: String
    @State private var duplicateNameFollowsDefault = true

    init(
        viewModel: ThemeEditorViewModel,
        onClose: @escaping () -> Void = {}
    ) {
        self.viewModel = viewModel
        self.localizationModel = viewModel.localizationModel
        self.onClose = onClose
        _duplicateName = State(
            initialValue: ThemeEditorCopy(
                text: viewModel.localizationModel.text
            )
                .duplicateDefaultName(for: viewModel.previewDisplayName)
        )
    }

    private var copy: ThemeEditorCopy {
        ThemeEditorCopy(text: localizationModel.text)
    }

    var body: some View {
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    identitySection
                    backgroundSection
                    semanticColorsSection
                    geometrySection
                    rasterSection
                    transferSection
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 420, idealWidth: 480)

            previewColumn
                .frame(minWidth: 300, idealWidth: 360)
        }
        .safeAreaInset(edge: .bottom) { actionBar }
        .frame(minWidth: 820, minHeight: 650)
        .onAppear { focusedField = .name }
        .onChange(of: localizationModel.locale.identifier) {
            guard duplicateNameFollowsDefault else { return }
            duplicateName = copy.duplicateDefaultName(
                for: viewModel.previewDisplayName
            )
        }
        .environment(\.locale, localizationModel.locale)
        .accessibilityIdentifier("theme.editor")
    }

    private var identitySection: some View {
        GroupBox(copy.title) {
            VStack(alignment: .leading, spacing: 9) {
                TextField(
                    copy.name,
                    text: Binding(
                        get: { viewModel.draft.name },
                        set: { viewModel.rename($0) }
                    )
                )
                .focused($focusedField, equals: .name)
                .accessibilityIdentifier("theme.editor.name")

                HStack {
                    TextField(
                        copy.duplicateName,
                        text: Binding(
                            get: { duplicateName },
                            set: {
                                duplicateName = $0
                                duplicateNameFollowsDefault = false
                            }
                        )
                    )
                    .focused($focusedField, equals: .duplicateName)
                    .accessibilityIdentifier("theme.editor.duplicate-name")
                    Button(copy.duplicateBuiltIn) {
                        viewModel.duplicateBuiltIn(named: duplicateName)
                    }
                    .focused($focusedField, equals: .duplicate)
                    .accessibilityIdentifier("theme.editor.duplicate")
                }

                Picker(
                    copy.appearance,
                    selection: $viewModel.selectedAppearance
                ) {
                    Text(copy.appearance(.light)).tag(ThemeAppearance.light)
                    Text(copy.appearance(.dark)).tag(ThemeAppearance.dark)
                }
                .pickerStyle(.segmented)
                .focused($focusedField, equals: .appearance)
                .accessibilityIdentifier("theme.editor.appearance")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .focusSection()
    }

    private var backgroundSection: some View {
        GroupBox(copy.background) {
            VStack(alignment: .leading, spacing: 9) {
                Picker(
                    copy.backgroundType,
                    selection: Binding(
                        get: { viewModel.backgroundKind },
                        set: { viewModel.selectBackgroundKind($0) }
                    )
                ) {
                    Text(copy.backgroundKind(.solid))
                        .tag(ThemeEditorBackgroundKind.solid)
                    Text(copy.backgroundKind(.boundedGradient))
                        .tag(ThemeEditorBackgroundKind.boundedGradient)
                    Text(copy.backgroundKind(.systemMaterial))
                        .tag(ThemeEditorBackgroundKind.systemMaterial)
                }
                .pickerStyle(.segmented)
                .focused($focusedField, equals: .backgroundKind)
                .accessibilityIdentifier("theme.editor.background.kind")

                backgroundValueEditor
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .focusSection()
    }

    @ViewBuilder
    private var backgroundValueEditor: some View {
        switch viewModel.draft.appearances[viewModel.selectedAppearance]
            .background
        {
        case let .solid(value):
            TextField(
                copy.solidColorPlaceholder,
                text: Binding(
                    get: { value },
                    set: { viewModel.setBackground(.solid($0)) }
                )
            )
            .focused($focusedField, equals: .backgroundValue)
            .accessibilityLabel(copy.backgroundKind(.solid))
            .accessibilityHint(copy.solidColorPlaceholder)
            .accessibilityIdentifier("theme.editor.background.solid")
        case let .boundedGradient(colors):
            TextField(
                copy.gradientStopsPlaceholder,
                text: Binding(
                    get: { colors.joined(separator: ", ") },
                    set: { value in
                        viewModel.setBackground(
                            .boundedGradient(
                                value.split(separator: ",", omittingEmptySubsequences: false)
                                    .map {
                                        $0.trimmingCharacters(in: .whitespaces)
                                    }
                            )
                        )
                    }
                )
            )
            .focused($focusedField, equals: .backgroundValue)
            .accessibilityLabel(copy.backgroundKind(.boundedGradient))
            .accessibilityHint(copy.gradientStopsPlaceholder)
            .accessibilityIdentifier("theme.editor.background.gradient")
        case let .systemMaterial(material):
            Picker(
                copy.backgroundKind(.systemMaterial),
                selection: Binding(
                    get: { material },
                    set: { viewModel.setBackground(.systemMaterial($0)) }
                )
            ) {
                ForEach(SystemThemeMaterial.allCases, id: \.self) { item in
                    Text(copy.material(item)).tag(item)
                }
            }
            .focused($focusedField, equals: .backgroundValue)
            .accessibilityIdentifier("theme.editor.background.material")
        }
    }

    private var semanticColorsSection: some View {
        GroupBox(copy.semanticColors) {
            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                alignment: .leading,
                spacing: 9
            ) {
                ForEach(ThemeEditorColorRole.allCases, id: \.self) { role in
                    LabeledContent(copy.colorRole(role)) {
                        TextField(
                            copy.colorHexPlaceholder,
                            text: Binding(
                                get: { viewModel.color(for: role) },
                                set: { viewModel.setColor($0, role: role) }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 100)
                        .focused($focusedField, equals: role.focusTarget)
                        .accessibilityLabel(copy.colorRole(role))
                        .accessibilityHint(copy.colorHexPlaceholder)
                        .accessibilityIdentifier(
                            "theme.editor.color.\(role.rawValue)"
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .focusSection()
    }

    private var geometrySection: some View {
        GroupBox(copy.geometry) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                ForEach(ThemeEditorNumericField.allCases, id: \.self) { field in
                    GridRow {
                        Text(copy.numericField(field))
                        TextField(
                            rangeHint(for: field),
                            value: Binding(
                                get: { viewModel.numericValue(for: field) },
                                set: {
                                    viewModel.setNumericValue($0, field: field)
                                }
                            ),
                            format: .number.precision(.fractionLength(0 ... 2))
                        )
                        .frame(width: 110)
                        .focused($focusedField, equals: field.focusTarget)
                        .accessibilityLabel(copy.numericField(field))
                        .accessibilityHint(rangeHint(for: field))
                        .accessibilityIdentifier(
                            "theme.editor.geometry.\(field.rawValue)"
                        )
                        Text(rangeHint(for: field))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .focusSection()
    }

    private var rasterSection: some View {
        GroupBox(copy.raster) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(
                        viewModel.draft.rasterReference == nil
                            ? copy.rasterNone
                            : copy.rasterSanitized
                    )
                    .font(.subheadline)
                    Text(copy.rasterPolicy)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(copy.chooseImage) {
                    Task { await viewModel.chooseRaster() }
                }
                .focused($focusedField, equals: .rasterChoose)
                .accessibilityIdentifier("theme.editor.raster.choose")
                Button(copy.remove) { viewModel.removeRaster() }
                    .focused($focusedField, equals: .rasterRemove)
                    .disabled(viewModel.draft.rasterReference == nil)
                    .accessibilityIdentifier("theme.editor.raster.remove")
            }
            .frame(maxWidth: .infinity)
        }
        .focusSection()
    }

    private var transferSection: some View {
        GroupBox(copy.transfer) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(
                    copy.includeRaster,
                    isOn: $viewModel.includeRasterInExport
                )
                .focused($focusedField, equals: .includeRaster)
                .accessibilityIdentifier("theme.editor.include-raster")
                .disabled(viewModel.draft.rasterReference == nil)
                HStack {
                    Button(copy.importTheme) {
                        Task { await viewModel.importTheme() }
                    }
                    .focused($focusedField, equals: .importTheme)
                    .accessibilityIdentifier("theme.editor.import")
                    Button(copy.exportTheme) {
                        Task { await viewModel.exportTheme() }
                    }
                    .focused($focusedField, equals: .exportTheme)
                    .accessibilityIdentifier("theme.editor.export")
                    Spacer()
                    Button(copy.resetToBuiltIn) { viewModel.reset() }
                        .focused($focusedField, equals: .reset)
                        .accessibilityIdentifier("theme.editor.reset")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .focusSection()
    }

    private var previewColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(copy.preview)
                .font(.title2.weight(.semibold))
            Picker(
                copy.dataState,
                selection: $viewModel.previewAvailability
            ) {
                ForEach(ThemeAvailabilityState.allCases, id: \.self) { state in
                    Text(copy.availability(state)).tag(state)
                }
            }
            .focused($focusedField, equals: .previewState)
            .accessibilityIdentifier("theme.editor.preview.state")

            ThemePreviewView(
                theme: viewModel.previewTheme,
                rasterData: viewModel.previewRasterData,
                availability: viewModel.previewAvailability,
                health: previewHealth,
                displayName: viewModel.previewDisplayName,
                localizationModel: localizationModel
            )
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("theme.editor.preview")

            if let message = viewModel.validationMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("theme.editor.validation")
            } else {
                Label(copy.safeToSave, systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            }

            if let message = viewModel.operationMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("theme.editor.operation-message")
            }
            Spacer()
        }
        .padding(18)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var actionBar: some View {
        HStack {
            Spacer()
            Button(copy.cancel) {
                viewModel.cancel()
                onClose()
            }
            .focused($focusedField, equals: .cancel)
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("theme.editor.cancel")
            Button(copy.save) { viewModel.save(activate: false) }
                .focused($focusedField, equals: .save)
                .disabled(!viewModel.canSaveAsActive)
                .accessibilityIdentifier("theme.editor.save")
            Button(copy.saveAndApply) { viewModel.save(activate: true) }
                .focused($focusedField, equals: .saveAndActivate)
                .keyboardShortcut(.defaultAction)
                .disabled(!viewModel.canSaveAsActive)
                .accessibilityIdentifier("theme.editor.save-and-activate")
        }
        .padding(12)
        .background(.bar)
        .focusSection()
    }

    private var previewHealth: ThemeHealthState? {
        switch viewModel.previewAvailability {
        case .fresh: .healthy
        case .partial, .stale: .warning
        case .unavailable: .critical
        case .loading, .unsupported: nil
        }
    }

    private func rangeHint(for field: ThemeEditorNumericField) -> String {
        let range = field.permittedRange
        let format = FloatingPointFormatStyle<Double>.number
            .precision(.fractionLength(0 ... 2))
            .locale(localizationModel.locale)
        return "\(range.lowerBound.formatted(format))–"
            + "\(range.upperBound.formatted(format))"
    }
}
