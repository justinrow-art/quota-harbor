import SwiftUI

struct SettingsView: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        TabView {
            GeneralSettingsPane(viewModel: viewModel)
                .tabItem {
                    Label(viewModel.copy.tabGeneral, systemImage: "gearshape")
                }
            AppearanceSettingsPane(viewModel: viewModel)
                .tabItem {
                    Label(
                        viewModel.copy.tabAppearance,
                        systemImage: "paintpalette"
                    )
                }
            AdvancedSettingsPane(viewModel: viewModel)
                .tabItem {
                    Label(
                        viewModel.copy.tabAdvanced,
                        systemImage: "wrench.and.screwdriver"
                    )
                    .accessibilityIdentifier("settings.tab.advanced")
                }
        }
        .padding(16)
        .frame(minWidth: 700, minHeight: 560)
    }
}

private struct GeneralSettingsPane: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                providersGroup
                menuBarGroup
                refreshGroup
                locationGroup
                loginItemGroup
                languageGroup
                SettingsOperationMessage(message: viewModel.operationMessage)
            }
            .padding()
        }
    }

    private var providersGroup: some View {
        let providers = viewModel.presentation.general.providers
        return GroupBox(viewModel.copy.groupProviders) {
            VStack(alignment: .leading, spacing: 12) {
                Text(viewModel.copy.providersExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(providers.rows) { row in
                    providerRow(row)
                    if row.id != providers.rows.last?.id {
                        Divider()
                    }
                }

                if providers.showsEmptySelectionRecovery {
                    Label(
                        viewModel.copy.providersEmptyRecovery,
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("settings.provider.empty-recovery")
                }

            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .focusSection()
    }

    private func providerRow(
        _ row: SettingsProviderRowPresentation
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                if row.providerID == .codex {
                    Label(row.name, systemImage: "checkmark.circle.fill")
                        .accessibilityIdentifier(
                            "settings.provider.codex.fixed"
                        )
                } else {
                    Toggle(
                        row.name,
                        isOn: Binding(
                            get: { row.isEnabled },
                            set: {
                                viewModel.setProviderEnabled(
                                    row.providerID,
                                    enabled: $0
                                )
                            }
                        )
                    )
                    .accessibilityIdentifier(
                        "settings.provider.\(row.providerID.rawValue).enabled"
                    )
                }
                Spacer()
            }

            if row.isEnabled {
                providerStateLine(
                    label: viewModel.copy.providerConnection,
                    value: row.connectionDetail
                )
                providerStateLine(
                    label: viewModel.copy.providerQuota,
                    value: row.quotaDetail
                )
                if let identity = row.maskedIdentityText {
                    providerStateLine(
                        label: viewModel.copy.providerAccount,
                        value: identity
                    )
                }
                if let updated = row.lastUpdatedText {
                    providerStateLine(
                        label: viewModel.copy.providerLastUpdated,
                        value: updated
                    )
                }
                if !row.metricOptions.isEmpty,
                   let selected = row.selectedMetricKey
                {
                    Picker(
                        viewModel.copy.providerPrimaryMetric,
                        selection: Binding(
                            get: { selected },
                            set: {
                                viewModel.setPrimaryMetric(
                                    row.providerID,
                                    metricKey: $0
                                )
                            }
                        )
                    ) {
                        ForEach(row.metricOptions) { option in
                            Text(option.title).tag(option.metricKey)
                        }
                    }
                    .accessibilityIdentifier(
                        "settings.provider.\(row.providerID.rawValue).metric"
                    )
                }
                if !row.links.isEmpty {
                    HStack {
                        ForEach(row.links) { link in
                            Button(link.title) {
                                viewModel.openProviderLink(link)
                            }
                            .accessibilityIdentifier(
                                "settings.provider.\(row.providerID.rawValue).\(link.kind == .usage ? "usage" : "help")"
                            )
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.provider.row.\(row.providerID.rawValue)")
    }

    private func providerStateLine(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
        }
    }

    private var menuBarGroup: some View {
        let menuBar = viewModel.presentation.general.menuBar
        let preview = viewModel.presentation.general.providers.preview
        return GroupBox(viewModel.copy.groupMenuBar) {
            VStack(alignment: .leading, spacing: 8) {
                Picker(
                    viewModel.copy.statusItemDisplayMode,
                    selection: Binding(
                        get: { menuBar.statusItemDisplayMode },
                        set: { viewModel.setStatusItemDisplayMode($0) }
                    )
                ) {
                    ForEach(StatusItemDisplayMode.allCases, id: \.self) {
                        mode in
                        Text(viewModel.copy.statusItemDisplayModeName(mode))
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settings.menu.display-mode")

                if menuBar.showsPrimaryProviderPicker {
                    Picker(
                        viewModel.copy.statusItemPrimaryProvider,
                        selection: Binding<ProviderID?>(
                            get: { menuBar.selectedPrimaryProvider },
                            set: { providerID in
                                if let providerID {
                                    viewModel.setPrimaryStatusItemProvider(
                                        providerID
                                    )
                                }
                            }
                        )
                    ) {
                        ForEach(menuBar.primaryProviderOptions) { option in
                            Text(option.name)
                                .tag(Optional(option.providerID))
                        }
                    }
                    .accessibilityIdentifier("settings.menu.primary-provider")
                }

                Text(viewModel.copy.statusItemAllProvidersExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if menuBar.statusItemDisplayMode == .full {
                    Label(
                        viewModel.copy.statusItemFullWarning,
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("settings.menu.full-warning")
                }
                Label(
                    viewModel.copy.statusItemPositionHelp,
                    systemImage: "command"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("settings.menu.position-help")

                VStack(alignment: .leading, spacing: 4) {
                    Text(preview.title)
                        .font(.system(.headline, design: .monospaced))
                    Text(preview.toolTip)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("settings.provider.preview")
                .accessibilityLabel(preview.accessibilityLabel)

                if menuBar.showsCodexWindowControls {
                    Toggle(
                        viewModel.copy.automaticWindows,
                        isOn: Binding(
                            get: {
                                viewModel.presentation.general.menuBar
                                    .usesAutomaticSelection
                            },
                            set: { value in
                                viewModel.setAutomaticMenuBar(value)
                            }
                        )
                    )
                    .accessibilityIdentifier("settings.menu.automatic")
                    ForEach(
                        Array(
                            viewModel.presentation.general.menuBar.options
                                .enumerated()
                        ),
                        id: \.element.id
                    ) { index, option in
                        Toggle(
                            option.title,
                            isOn: Binding(
                                get: { option.isSelected },
                                set: { selected in
                                    viewModel.setMenuBarWindow(
                                        option.identity,
                                        selected: selected
                                    )
                                }
                            )
                        )
                        .accessibilityIdentifier(
                            "settings.menu.window.row.\(index)"
                        )
                        .disabled(!option.isEnabled)
                        .help(option.disabledExplanation ?? "")
                    }
                    if let explanation = menuBar.selectionLimitExplanation {
                        Label(explanation, systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier(
                                "settings.menu.selection-limit-explanation"
                            )
                    }
                }
                Picker(
                    viewModel.copy.percentageDisplay,
                    selection: Binding(
                        get: { viewModel.presentation.general.percentageMode },
                        set: { value in
                            viewModel.setPercentageMode(value)
                        }
                    )
                ) {
                    Text(viewModel.copy.percentageMode(.remaining))
                        .tag(PercentageMode.remaining)
                    Text(viewModel.copy.percentageMode(.used))
                        .tag(PercentageMode.used)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settings.percentage.mode")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .focusSection()
    }

    private var refreshGroup: some View {
        GroupBox(viewModel.copy.groupRefreshSource) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.presentation.general.freshness.rateText)
                    Text(viewModel.presentation.general.freshness.usageText)
                    Text(viewModel.presentation.general.freshness.sourceText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(viewModel.copy.refreshScheduleExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings.refresh.schedule")
                }
                Spacer()
                Button(viewModel.copy.refreshNow) { viewModel.refreshNow() }
                    .accessibilityIdentifier("settings.refresh.now")
                    .disabled(
                        viewModel.presentation.general.freshness.isRefreshing
                    )
            }
            .frame(maxWidth: .infinity)
        }
        .focusSection()
    }

    private var locationGroup: some View {
        GroupBox(viewModel.copy.groupDisplayLocation) {
            Picker(
                viewModel.copy.floatingCard,
                selection: Binding(
                    get: { viewModel.presentation.general.spacePolicy },
                    set: { value in
                        viewModel.setSpacePolicy(value)
                    }
                )
            ) {
                Text(viewModel.copy.spacePolicy(.currentSpace))
                    .tag(SpacePolicy.currentSpace)
                Text(viewModel.copy.spacePolicy(.allSpaces))
                    .tag(SpacePolicy.allSpaces)
            }
            .accessibilityIdentifier("settings.space.policy")
            .frame(maxWidth: .infinity)
        }
        .focusSection()
    }

    private var loginItemGroup: some View {
        GroupBox(viewModel.copy.groupLogin) {
            VStack(alignment: .leading, spacing: 5) {
                Toggle(
                    viewModel.presentation.general.loginItem.title,
                    isOn: Binding(
                        get: {
                            viewModel.presentation.general.loginItem.isOn
                        },
                        set: { enabled in
                            Task {
                                await viewModel.setLaunchAtLoginEnabled(enabled)
                            }
                        }
                    )
                )
                .accessibilityIdentifier("settings.login.toggle")
                .disabled(
                    !viewModel.presentation.general.loginItem.canToggle
                        || viewModel.isLoginItemOperationInProgress
                )
                Text(viewModel.presentation.general.loginItem.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if viewModel.presentation.general.loginItem
                    .canOpenSystemSettings
                {
                    Button(viewModel.copy.openLoginItems) {
                        viewModel.openLoginItemSystemSettings()
                    }
                    .accessibilityIdentifier("settings.login.open-system-settings")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .focusSection()
    }

    private var languageGroup: some View {
        GroupBox(viewModel.copy.groupLanguage) {
            Picker(
                viewModel.copy.interfaceLanguage,
                selection: Binding(
                    get: { viewModel.presentation.general.language },
                    set: { value in
                        viewModel.setLanguage(value)
                    }
                )
            ) {
                ForEach(AppLanguage.allCases, id: \.self) { language in
                    Text(viewModel.copy.languageName(language)).tag(language)
                }
            }
            .accessibilityIdentifier("settings.language.picker")
            .frame(maxWidth: .infinity)
        }
        .focusSection()
    }
}

private struct AppearanceSettingsPane: View {
    @Bindable var viewModel: SettingsViewModel
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceTransparency)
    private var reduceTransparency

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                themeGroup
                appearanceGroup
                accessibilityGroup
                SettingsOperationMessage(message: viewModel.operationMessage)
            }
            .padding()
        }
    }

    private var themeGroup: some View {
        GroupBox(viewModel.copy.groupTheme) {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    spacing: 10
                ) {
                    ForEach(
                        Array(
                            viewModel.presentation.appearance.theme.choices
                                .enumerated()
                        ),
                        id: \.element.id
                    ) { index, choice in
                        themeButton(choice, index: index)
                    }
                }
                if !viewModel.presentation.appearance.theme.allowsSelection {
                    Text(viewModel.copy.themeEnginePending)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ThemePreviewView(
                    theme: selectedPreviewTheme,
                    rasterData: viewModel.presentation.appearance.theme
                        .selectedThemeRasterData,
                    availability: .fresh,
                    health: .healthy,
                    displayName: selectedPreviewName,
                    localizationModel: viewModel.localizationModel
                )
                .frame(maxWidth: .infinity)
                .environment(\.colorScheme, previewColorScheme)
                .accessibilityIdentifier("settings.theme.preview")
                Button(viewModel.copy.openThemeEditor) {
                    viewModel.openThemeEditor()
                }
                    .accessibilityIdentifier("settings.theme.open-editor")
                    .disabled(
                        !viewModel.presentation.appearance.theme
                            .allowsCustomEditor
                    )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .focusSection()
    }

    private var selectedPreviewTheme: ThemeDocument {
        viewModel.presentation.appearance.theme.selectedThemeDocument
            ?? ThemeViewSupport.builtInTheme(
                for: viewModel.presentation.appearance.theme.selectedThemeID
            ).document
    }

    private var selectedPreviewName: String? {
        let theme = viewModel.presentation.appearance.theme
        return theme.choices.first { $0.id == theme.selectedThemeID }?.name
    }

    private func themeButton(_ choice: ThemeChoice, index: Int) -> some View {
        let isSelected = choice.id
            == viewModel.presentation.appearance.theme.selectedThemeID
        return Button {
            viewModel.selectTheme(choice.id)
        } label: {
            HStack {
                Image(
                    systemName: isSelected
                        ? "checkmark.circle.fill"
                        : "circle"
                )
                .accessibilityHidden(true)
                Text(choice.name)
                Spacer()
            }
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("settings.theme.choice.\(index)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .disabled(!viewModel.presentation.appearance.theme.allowsSelection)
    }

    private var appearanceGroup: some View {
        GroupBox(viewModel.copy.groupAppearance) {
            VStack {
                Picker(
                    viewModel.copy.colorScheme,
                    selection: Binding(
                        get: { viewModel.presentation.appearance.colorScheme },
                        set: { value in
                            viewModel.setColorScheme(value)
                        }
                    )
                ) {
                    ForEach(AppearanceColorScheme.allCases, id: \.self) {
                        value in
                        Text(viewModel.copy.colorSchemeName(value)).tag(value)
                    }
                }
                .accessibilityIdentifier("settings.appearance.color-scheme")
                .disabled(
                    !viewModel.presentation.appearance
                        .allowsColorSchemeSelection
                )
                Picker(
                    viewModel.copy.density,
                    selection: Binding(
                        get: { viewModel.presentation.appearance.density },
                        set: { value in
                            viewModel.setDensity(value)
                        }
                    )
                ) {
                    ForEach(AppearanceDensity.allCases, id: \.self) { value in
                        Text(viewModel.copy.densityName(value)).tag(value)
                    }
                }
                .accessibilityIdentifier("settings.appearance.density")
                .disabled(
                    !viewModel.presentation.appearance
                        .allowsDensitySelection
                )
                Picker(
                    viewModel.copy.displayProfile,
                    selection: Binding(
                        get: {
                            viewModel.presentation.appearance.displayProfile
                        },
                        set: { value in
                            viewModel.setDisplayProfile(value)
                        }
                    )
                ) {
                    ForEach(DisplayProfile.allCases, id: \.self) { value in
                        Text(viewModel.copy.displayProfileName(value))
                            .tag(value)
                    }
                }
                .accessibilityIdentifier("settings.appearance.display-profile")
                .disabled(
                    !viewModel.presentation.appearance
                        .allowsDisplayProfileSelection
                )
            }
            .frame(maxWidth: .infinity)
        }
        .focusSection()
    }

    private var accessibilityGroup: some View {
        GroupBox(viewModel.copy.groupAccessibility) {
            let preview = accessibilityPreview
            VStack(alignment: .leading, spacing: CGFloat(preview.rowSpacing)) {
                HStack(alignment: .firstTextBaseline) {
                    Label(preview.label, systemImage: "clock")
                        .font(.headline)
                    Spacer()
                    Text(preview.value)
                        .font(.title3.monospacedDigit().weight(.semibold))
                }
                Text(preview.fallbackDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if preview.backgroundStyle == .opaque {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(nsColor: .windowBackgroundColor))
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.thinMaterial)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        preview.usesHighContrastBorder
                            ? Color.primary
                            : Color.secondary.opacity(0.35),
                        lineWidth: preview.usesHighContrastBorder ? 2 : 1
                    )
            }
            .environment(\.colorScheme, previewColorScheme)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(preview.accessibilityLabel))
            .accessibilityValue(Text(preview.accessibilityValue))
        }
        .focusSection()
    }

    private var accessibilityPreview: AccessibilityPreviewPresentation {
        AccessibilityPreviewPresenter(
            text: viewModel.localizationModel.text
        ).makePresentation(
            colorScheme: viewModel.presentation.appearance.colorScheme,
            density: viewModel.presentation.appearance.density,
            increaseContrast: colorSchemeContrast == .increased,
            reduceTransparency: reduceTransparency
        )
    }

    private var previewColorScheme: ColorScheme {
        switch accessibilityPreview.colorScheme {
        case .system:
            systemColorScheme
        case .light:
            .light
        case .dark:
            .dark
        }
    }
}

private struct AdvancedSettingsPane: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        let providers = viewModel.presentation.general.providers
        let claudeIsEnabled = providers.rows.contains {
            $0.providerID == .claudeCode && $0.isEnabled
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                capabilityGroup
                tokenActivityGroup
                if claudeIsEnabled
                    || providers.claudeRelay.showsMaintenance
                {
                    claudeRelayMaintenanceGroup
                }
                diagnosticsGroup
                actionsGroup
                SettingsOperationMessage(message: viewModel.operationMessage)
            }
            .padding()
        }
    }

    private var tokenActivityGroup: some View {
        let activity = viewModel.presentation.advanced.tokenActivity
        return GroupBox(activity.groupTitle) {
            VStack(alignment: .leading, spacing: 10) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        Text("")
                        Text(activity.totalTitle)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                    tokenActivityRow(activity.today)
                    tokenActivityRow(activity.currentMonth)
                }
                Divider()
                Text(activity.coverageText)
                    .font(.caption)
                if let dateRangeText = activity.dateRangeText {
                    Text(dateRangeText)
                        .font(.caption)
                }
                Text(activity.disclosure)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(activity.missingDataNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .focusSection()
    }

    private func tokenActivityRow(
        _ period: SettingsTokenPeriodPresentation
    ) -> some View {
        GridRow {
            Text(period.title)
                .font(.callout.weight(.medium))
            tokenMetric(period.total)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tokenActivityTotalOnlyAccessibility.rowLabel(
            period,
            totalTitle: viewModel.presentation.advanced.tokenActivity.totalTitle
        ))
    }

    private func tokenMetric(
        _ metric: SettingsTokenMetricPresentation
    ) -> some View {
        Text(metric.text)
            .font(.system(.callout, design: .monospaced))
            .foregroundStyle(
                metric.state == .partial ? Color.orange : Color.primary
            )
    }

    private var tokenActivityTotalOnlyAccessibility:
        TokenActivityTotalOnlyAccessibilityText
    {
        TokenActivityTotalOnlyAccessibilityText(
            text: viewModel.localizationModel.text
        )
    }

    private var capabilityGroup: some View {
        GroupBox(viewModel.copy.groupCapabilities) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(viewModel.presentation.advanced.capabilities) { row in
                    HStack {
                        Text(row.title)
                        Spacer()
                        Label(
                            row.detail,
                            systemImage: SettingsViewCopy.capabilitySymbol(
                                row.state
                            )
                        )
                    }
                }
                Divider()
                LabeledContent(
                    viewModel.copy.installedCodexVersion,
                    value: viewModel.presentation.advanced.installedCodexVersion
                )
            }
            .frame(maxWidth: .infinity)
        }
        .focusSection()
    }

    private var claudeRelayMaintenanceGroup: some View {
        let relay = viewModel.presentation.general.providers.claudeRelay
        let stateCopy = viewModel.copy.claudeRelayState(relay.state)
        let manualRecoveryCopy = viewModel.copy.claudeRelayState(.manualRecovery)
        return GroupBox(viewModel.copy.claudeRelayTitle) {
            VStack(alignment: .leading, spacing: 7) {
                Text(viewModel.copy.claudeRelayExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if relay.state != .manualRecovery {
                    Text(stateCopy)
                        .font(.caption.weight(.medium))
                        .accessibilityIdentifier("settings.claude-relay.state")
                }
                if relay.state == .manualRecovery
                    || relay.state == .invalidSettings
                {
                    Label(
                        manualRecoveryCopy,
                        systemImage: "exclamationmark.shield.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(
                        "settings.claude-relay.manual-recovery-guidance"
                    )
                    .accessibilityLabel(manualRecoveryCopy)
                }

                if let confirmation = relay.pendingConfirmation {
                    Text(viewModel.copy.claudeRelayConfirmation(confirmation))
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier(
                            "settings.claude-relay.confirmation"
                        )
                    HStack {
                        Button(viewModel.copy.cancel) {
                            viewModel.cancelClaudeRelayChange()
                        }
                        .accessibilityIdentifier(
                            "settings.claude-relay.cancel"
                        )
                        Button(viewModel.copy.confirm) {
                            Task {
                                await viewModel.confirmClaudeRelayChange()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier(
                            "settings.claude-relay.confirm"
                        )
                    }
                } else if relay.state == .notInstalled {
                    Button(viewModel.copy.claudeRelayInstall) {
                        viewModel.requestClaudeRelayInstallation()
                    }
                    .accessibilityIdentifier("settings.claude-relay.install")
                } else if relay.state == .installed {
                    Button(viewModel.copy.claudeRelayRemove) {
                        viewModel.requestClaudeRelayRemoval()
                    }
                    .accessibilityIdentifier("settings.claude-relay.remove")
                }

                if relay.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityIdentifier(
                            "settings.claude-relay.progress"
                        )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(relay.isBusy)
        .focusSection()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.claude-relay.maintenance")
    }

    private var diagnosticsGroup: some View {
        GroupBox(viewModel.copy.groupDiagnostics) {
            VStack(alignment: .leading, spacing: 8) {
                ScrollView {
                    Text(
                        viewModel.presentation.advanced.diagnostics.renderedText
                    )
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("settings.diagnostics.text")
                }
                .frame(minHeight: 145)
                Button(viewModel.copy.copyDiagnostics) {
                    viewModel.copyDiagnostics()
                }
                .accessibilityIdentifier("settings.diagnostics.copy")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .focusSection()
    }

    private var actionsGroup: some View {
        GroupBox(viewModel.copy.groupResetThemeFiles) {
            HStack {
                Button(viewModel.copy.resetSettings) { viewModel.resetSettings() }
                    .accessibilityIdentifier("settings.reset.settings")
                Button(viewModel.copy.resetTheme) { viewModel.resetTheme() }
                    .accessibilityIdentifier("settings.reset.theme")
                    .disabled(
                        !viewModel.presentation.appearance.theme.allowsReset
                    )
                Spacer()
                Button(viewModel.copy.importTheme) { viewModel.importTheme() }
                    .accessibilityIdentifier("settings.theme.import")
                    .disabled(
                        !viewModel.presentation.appearance.theme.allowsImport
                    )
                Button(viewModel.copy.exportTheme) { viewModel.exportTheme() }
                    .accessibilityIdentifier("settings.theme.export")
                    .disabled(
                        !viewModel.presentation.appearance.theme.allowsExport
                    )
            }
            .frame(maxWidth: .infinity)
        }
        .focusSection()
    }
}

private struct SettingsOperationMessage: View {
    let message: String?

    @ViewBuilder
    var body: some View {
        if let message {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }
}

private enum SettingsViewCopy {
    static func capabilitySymbol(_ state: SettingsCapabilityState) -> String {
        switch state {
        case .loading: return "clock"
        case .fresh: return "checkmark.circle"
        case .stale: return "exclamationmark.triangle"
        case .unsupported: return "minus.circle"
        case .unavailable: return "xmark.circle"
        }
    }
}
