import Foundation

enum SettingsCapabilityLane: Equatable, Sendable {
    case rateLimits
    case tokenActivity
}

enum SettingsCapabilityState: Equatable, Sendable {
    case loading
    case fresh
    case stale
    case unsupported
    case unavailable
}

enum AppearanceColorScheme: String, CaseIterable, Equatable, Hashable, Sendable {
    case system
    case light
    case dark
}

enum AppearanceDensity: String, CaseIterable, Equatable, Hashable, Sendable {
    case system
    case comfortable
    case compact
}

struct SettingsCopy {
    let text: LocalizedTextProvider

    var tabGeneral: String { text.text(.settingsTabGeneral) }
    var tabAppearance: String { text.text(.settingsTabAppearance) }
    var tabAdvanced: String { text.text(.settingsTabAdvanced) }
    var groupMenuBar: String { text.text(.settingsGroupMenuBar) }
    var groupProviders: String { text.text(.settingsGroupProviders) }
    var providersExplanation: String {
        text.text(.settingsProvidersExplanation)
    }
    var providerConnection: String {
        text.text(.settingsProvidersConnection)
    }
    var providerQuota: String { text.text(.settingsProvidersQuota) }
    var providerAccount: String { text.text(.settingsProvidersAccount) }
    var providerLastUpdated: String {
        text.text(.settingsProvidersLastUpdated)
    }
    var providerPrimaryMetric: String {
        text.text(.settingsProvidersPrimaryMetric)
    }
    var providersEmptyRecovery: String {
        text.text(.settingsProvidersEmptyRecovery)
    }
    var moveUp: String { text.text(.actionMoveUp) }
    var moveDown: String { text.text(.actionMoveDown) }
    var confirm: String { text.text(.actionConfirm) }
    var cancel: String { text.text(.actionCancel) }
    var claudeRelayTitle: String { text.text(.settingsClaudeRelayTitle) }
    var claudeRelayExplanation: String {
        text.text(.settingsClaudeRelayExplanation)
    }
    var claudeRelayInstall: String {
        text.text(.settingsClaudeRelayInstall)
    }
    var claudeRelayRemove: String { text.text(.settingsClaudeRelayRemove) }

    func claudeRelayConfirmation(
        _ confirmation: ClaudeRelayPendingConfirmation
    ) -> String {
        text.text(
            confirmation == .install
                ? .settingsClaudeRelayConfirmInstall
                : .settingsClaudeRelayConfirmRemove
        )
    }

    func claudeRelayState(_ state: ClaudeRelaySettingsState) -> String {
        let key: LocalizationCatalogKey = switch state {
        case .loading: .commonLoading
        case .unavailable: .commonUnavailable
        case .notInstalled: .settingsClaudeRelayNotInstalled
        case .installed: .settingsClaudeRelayInstalled
        case .conflict: .settingsClaudeRelayConflict
        case .manualRecovery: .settingsClaudeRelayManualRecovery
        case .invalidSettings: .settingsClaudeRelayInvalid
        case .failed: .settingsClaudeRelayFailed
        }
        return text.text(key)
    }
    var automaticWindows: String { text.text(.settingsAutomaticWindows) }
    var statusItemDisplayMode: String {
        text.text(.settingsStatusItemDisplayMode)
    }
    var statusItemPrimaryProvider: String {
        text.text(.settingsStatusItemPrimaryProvider)
    }
    var statusItemAllProvidersExplanation: String {
        text.text(.settingsStatusItemAllProvidersExplanation)
    }
    var statusItemFullWarning: String {
        text.text(.settingsStatusItemFullWarning)
    }
    var statusItemPositionHelp: String {
        text.text(.settingsStatusItemPositionHelp)
    }
    var percentageDisplay: String { text.text(.settingsPercentageDisplay) }
    var groupRefreshSource: String { text.text(.settingsGroupRefreshSource) }
    var refreshScheduleExplanation: String {
        text.text(.settingsRefreshScheduleExplanation)
    }
    var refreshNow: String { text.text(.actionRefreshNow) }
    var groupDisplayLocation: String { text.text(.settingsGroupDisplayLocation) }
    var floatingCard: String { text.text(.settingsFloatingCard) }
    var groupLogin: String { text.text(.settingsGroupLogin) }
    var openLoginItems: String { text.text(.actionOpenLoginItems) }
    var groupLanguage: String { text.text(.settingsGroupLanguage) }
    var interfaceLanguage: String { text.text(.settingsInterfaceLanguage) }
    var groupTheme: String { text.text(.settingsGroupTheme) }
    var themeEnginePending: String { text.text(.settingsThemeEnginePending) }
    var openThemeEditor: String { text.text(.settingsOpenThemeEditor) }
    var groupAppearance: String { text.text(.settingsGroupAppearanceMode) }
    var colorScheme: String { text.text(.settingsColorScheme) }
    var density: String { text.text(.settingsInformationDensity) }
    var displayProfile: String { text.text(.settingsDisplayProfile) }
    var groupAccessibility: String { text.text(.settingsAccessibilityPreview) }
    var groupCapabilities: String { text.text(.settingsGroupCapabilities) }
    var installedCodexVersion: String { text.text(.settingsInstalledVersion) }
    var groupDiagnostics: String { text.text(.settingsRedactedDiagnostics) }
    var copyDiagnostics: String { text.text(.actionCopyDiagnostics) }
    var groupResetThemeFiles: String { text.text(.settingsGroupResetThemeFiles) }
    var resetSettings: String { text.text(.actionResetSettings) }
    var resetTheme: String { text.text(.actionResetTheme) }
    var importTheme: String { text.text(.actionImport) }
    var exportTheme: String { text.text(.actionExport) }

    func percentageMode(_ mode: PercentageMode) -> String {
        text.text(
            mode == .remaining
                ? .settingsPercentageRemaining
                : .settingsPercentageUsed
        )
    }

    func statusItemDisplayModeName(_ mode: StatusItemDisplayMode) -> String {
        let key: LocalizationCatalogKey = switch mode {
        case .automatic: .settingsStatusItemDisplayAutomatic
        case .primary: .settingsStatusItemDisplayPrimary
        case .full: .settingsStatusItemDisplayFull
        }
        return text.text(key)
    }

    func spacePolicy(_ policy: SpacePolicy) -> String {
        text.text(
            policy == .currentSpace
                ? .settingsCurrentSpace
                : .settingsAllSpaces
        )
    }

    func languageName(_ language: AppLanguage) -> String {
        let key: LocalizationCatalogKey = switch language {
            case .system: .languageSystem
            case .traditionalChinese: .languageTraditionalChinese
            case .simplifiedChinese: .languageSimplifiedChinese
            case .english: .languageEnglish
            case .japanese: .languageJapanese
            case .korean: .languageKorean
            case .spanish: .languageSpanish
            case .french: .languageFrench
            case .german: .languageGerman
        }
        return text.text(key)
    }

    func colorSchemeName(_ value: AppearanceColorScheme) -> String {
        let key: LocalizationCatalogKey = switch value {
            case .system: .settingsAppearanceSystem
            case .light: .settingsLight
            case .dark: .settingsDark
        }
        return text.text(key)
    }

    func densityName(_ value: AppearanceDensity) -> String {
        let key: LocalizationCatalogKey = switch value {
            case .system: .settingsAppearanceSystem
            case .comfortable: .settingsComfortable
            case .compact: .settingsCompact
        }
        return text.text(key)
    }

    func displayProfileName(_ value: DisplayProfile) -> String {
        let key: LocalizationCatalogKey = switch value {
            case .compact: .settingsDisplayProfileCompact
            case .balanced: .settingsDisplayProfileBalanced
            case .full: .settingsDisplayProfileFull
        }
        return text.text(key)
    }
}

enum AccessibilityPreviewBackgroundStyle: Equatable, Sendable {
    case translucent
    case opaque
}

struct AccessibilityPreviewPresentation: Equatable, Sendable {
    let colorScheme: AppearanceColorScheme
    let rowSpacing: Double
    let backgroundStyle: AccessibilityPreviewBackgroundStyle
    let usesHighContrastBorder: Bool
    let label: String
    let value: String
    let fallbackDescription: String
    let accessibilityLabel: String
    let accessibilityValue: String
}

struct AccessibilityPreviewPresenter {
    let text: LocalizedTextProvider

    init(
        text: LocalizedTextProvider = LocalizedTextProvider(
            language: .traditionalChinese,
            systemLocale: Locale(identifier: "zh_TW")
        )
    ) {
        self.text = text
    }

    func makePresentation(
        colorScheme: AppearanceColorScheme,
        density: AppearanceDensity,
        increaseContrast: Bool,
        reduceTransparency: Bool
    ) -> AccessibilityPreviewPresentation {
        let rowSpacing: Double = switch density {
        case .system:
            9
        case .comfortable:
            12
        case .compact:
            6
        }
        let fallbackDescription = switch (
            increaseContrast,
            reduceTransparency
        ) {
        case (true, true):
            text.text(.settingsAccessibilityBothFallbacks)
        case (true, false):
            text.text(.settingsAccessibilityIncreaseContrast)
        case (false, true):
            text.text(.settingsAccessibilityReduceTransparency)
        case (false, false):
            text.text(.settingsAccessibilityStandard)
        }
        let label = text.text(.settingsAccessibilityPreviewLabel)
        let value = text.text(.quotaRemainingPercent, Int64(72))

        return AccessibilityPreviewPresentation(
            colorScheme: colorScheme,
            rowSpacing: rowSpacing,
            backgroundStyle: reduceTransparency ? .opaque : .translucent,
            usesHighContrastBorder: increaseContrast,
            label: label,
            value: value,
            fallbackDescription: fallbackDescription,
            accessibilityLabel: label,
            accessibilityValue: text.text(
                .settingsAccessibilityValue,
                value,
                fallbackDescription
            )
        )
    }
}

struct SettingsWindowOption: Identifiable, Equatable, Sendable {
    var id: WindowIdentity { identity }

    let identity: WindowIdentity
    let title: String
    let isSelected: Bool
    let isEnabled: Bool
    let isAvailable: Bool
    let disabledExplanation: String?
}

struct SettingsPrimaryProviderOption: Identifiable, Equatable, Sendable {
    var id: ProviderID { providerID }

    let providerID: ProviderID
    let name: String
}

struct MenuBarSettingsPresentation: Equatable, Sendable {
    let usesAutomaticSelection: Bool
    let options: [SettingsWindowOption]
    let selectionLimitExplanation: String?
    let showsCodexWindowControls: Bool
    let statusItemDisplayMode: StatusItemDisplayMode
    let primaryProviderOptions: [SettingsPrimaryProviderOption]
    let selectedPrimaryProvider: ProviderID?
    let showsPrimaryProviderPicker: Bool
}

struct SettingsFreshnessPresentation: Equatable, Sendable {
    let rateText: String
    let usageText: String
    let sourceText: String
    let isRefreshing: Bool
}

struct LoginItemSettingsPresentation: Equatable, Sendable {
    let status: LoginItemStatus?
    let isLoading: Bool
    let isOn: Bool
    let canToggle: Bool
    let canOpenSystemSettings: Bool
    let title: String
    let detail: String
}

struct ThemeChoice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let isCustom: Bool
}

struct ThemeSettingsSnapshot: Equatable, Sendable {
    let choices: [ThemeChoice]
    let selectedThemeID: String?
    let selectedThemeDocument: ThemeDocument?
    let selectedThemeRasterData: Data?
    let allowsSelection: Bool
    let allowsReset: Bool
    let allowsImport: Bool
    let allowsExport: Bool
    let allowsCustomEditor: Bool
    let allowsColorScheme: Bool
    let allowsDensity: Bool
    let accessibilityFallbacksActive: Bool

    init(
        choices: [ThemeChoice],
        selectedThemeID: String?,
        selectedThemeDocument: ThemeDocument? = nil,
        selectedThemeRasterData: Data? = nil,
        allowsSelection: Bool = true,
        allowsReset: Bool = true,
        allowsImport: Bool = true,
        allowsExport: Bool = true,
        allowsCustomEditor: Bool = true,
        allowsColorScheme: Bool = true,
        allowsDensity: Bool = true,
        accessibilityFallbacksActive: Bool = true
    ) {
        self.choices = choices
        self.selectedThemeID = selectedThemeID
        self.selectedThemeDocument = selectedThemeDocument
        self.selectedThemeRasterData = selectedThemeRasterData
        self.allowsSelection = allowsSelection
        self.allowsReset = allowsReset
        self.allowsImport = allowsImport
        self.allowsExport = allowsExport
        self.allowsCustomEditor = allowsCustomEditor
        self.allowsColorScheme = allowsColorScheme
        self.allowsDensity = allowsDensity
        self.accessibilityFallbacksActive = accessibilityFallbacksActive
    }

    static let placeholder = ThemeSettingsSnapshot(
        choices: [
            ThemeChoice(id: "morandi", name: "", isCustom: false),
            ThemeChoice(id: "cyberpunk", name: "", isCustom: false),
            ThemeChoice(id: "warm-illustration", name: "", isCustom: false),
            ThemeChoice(id: "glass", name: "", isCustom: false),
            ThemeChoice(id: "sketch", name: "", isCustom: false),
            ThemeChoice(id: "cartoon", name: "", isCustom: false),
            ThemeChoice(id: "custom", name: "", isCustom: true),
        ],
        selectedThemeID: nil,
        allowsSelection: false,
        allowsReset: false,
        allowsImport: false,
        allowsExport: false,
        allowsCustomEditor: false,
        allowsColorScheme: false,
        allowsDensity: false,
        accessibilityFallbacksActive: false
    )
}

struct GeneralSettingsPresentation: Equatable, Sendable {
    let providers: ProviderSettingsPresentation
    let menuBar: MenuBarSettingsPresentation
    let percentageMode: PercentageMode
    let freshness: SettingsFreshnessPresentation
    let spacePolicy: SpacePolicy
    let loginItem: LoginItemSettingsPresentation
    let language: AppLanguage
}

enum SettingsProviderConnectionState: Equatable, Sendable {
    case loading
    case connected
    case stale
    case notConnected
    case unsupported
    case failed
}

enum SettingsProviderQuotaState: Equatable, Sendable {
    case loading
    case available
    case stale
    case awaitingSnapshot
    case unsupported
    case unavailable
}

struct SettingsProviderMetricOption: Identifiable, Equatable, Sendable {
    var id: ProviderMetricKey { metricKey }

    let metricKey: ProviderMetricKey
    let title: String
}

enum SettingsProviderLinkKind: Equatable, Sendable {
    case usage
    case help
}

struct SettingsProviderLinkPresentation: Identifiable, Equatable, Sendable {
    var id: String { "\(kind)-\(url.absoluteString)" }

    let kind: SettingsProviderLinkKind
    let title: String
    let url: URL
}

struct SettingsProviderRowPresentation: Identifiable, Equatable, Sendable {
    var id: ProviderID { providerID }

    let providerID: ProviderID
    let name: String
    let isEnabled: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let connectionState: SettingsProviderConnectionState
    let connectionDetail: String
    let quotaState: SettingsProviderQuotaState
    let quotaDetail: String
    let lastUpdatedText: String?
    let maskedIdentityText: String?
    let metricOptions: [SettingsProviderMetricOption]
    let selectedMetricKey: ProviderMetricKey?
    let links: [SettingsProviderLinkPresentation]
}

struct ProviderSettingsPresentation: Equatable, Sendable {
    let rows: [SettingsProviderRowPresentation]
    let preview: StatusItemPresentation
    let showsEmptySelectionRecovery: Bool
    let claudeRelay: ClaudeRelaySettingsPresentation
}

enum ClaudeRelaySettingsState: Equatable, Sendable {
    case loading
    case unavailable
    case notInstalled
    case installed
    case conflict
    case manualRecovery
    case invalidSettings
    case failed
}

enum ClaudeRelayPendingConfirmation: Equatable, Sendable {
    case install
    case remove
}

struct ClaudeRelaySettingsPresentation: Equatable, Sendable {
    let state: ClaudeRelaySettingsState
    let pendingConfirmation: ClaudeRelayPendingConfirmation?
    let isBusy: Bool

    var showsMaintenance: Bool {
        pendingConfirmation != nil
            || state == .installed
            || state == .conflict
            || state == .manualRecovery
            || state == .invalidSettings
            || state == .failed
    }

    static let unavailable = ClaudeRelaySettingsPresentation(
        state: .unavailable,
        pendingConfirmation: nil,
        isBusy: false
    )
}

struct AppearanceSettingsPresentation: Equatable, Sendable {
    let theme: ThemeSettingsSnapshot
    let colorScheme: AppearanceColorScheme
    let density: AppearanceDensity
    let displayProfile: DisplayProfile
    let allowsColorSchemeSelection: Bool
    let allowsDensitySelection: Bool
    let allowsDisplayProfileSelection: Bool
}

struct SettingsCapabilityRow: Identifiable, Equatable, Sendable {
    var id: SettingsCapabilityLane { lane }

    let lane: SettingsCapabilityLane
    let title: String
    let state: SettingsCapabilityState
    let detail: String
}

enum SettingsTokenMetricState: Equatable, Sendable {
    case available
    case partial
    case notReturned
    case unavailable
}

struct SettingsTokenMetricPresentation: Equatable, Sendable {
    let state: SettingsTokenMetricState
    let text: String
}

struct SettingsTokenPeriodPresentation: Equatable, Sendable {
    let title: String
    let input: SettingsTokenMetricPresentation
    let output: SettingsTokenMetricPresentation
    let total: SettingsTokenMetricPresentation
}

struct SettingsTokenActivityPresentation: Equatable, Sendable {
    let groupTitle: String
    let inputTitle: String
    let outputTitle: String
    let totalTitle: String
    let today: SettingsTokenPeriodPresentation
    let currentMonth: SettingsTokenPeriodPresentation
    let coverageText: String
    let dateRangeText: String?
    let disclosure: String
    let missingDataNote: String
}

struct TokenActivityTotalOnlyAccessibilityText {
    let text: LocalizedTextProvider

    func rowLabel(
        _ period: SettingsTokenPeriodPresentation,
        totalTitle: String
    ) -> String {
        text.text(
            .activityTotalOnlyAccessibilityRow,
            period.title,
            totalTitle,
            period.total.text
        )
    }
}

struct RedactedDisplayVersion: Equatable, Sendable {
    private let value: String?

    init(_ candidate: String) {
        let trimmed = candidate.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= 64,
              !trimmed.contains("\n"),
              !trimmed.contains("\r"),
              !trimmed.contains("/"),
              !trimmed.contains("\\"),
              trimmed.unicodeScalars.allSatisfy({ scalar in
                  CharacterSet.alphanumerics.contains(scalar)
                      || ".-_+ ()".unicodeScalars.contains(scalar)
              })
        else {
            value = nil
            return
        }
        value = trimmed
    }

    var renderedText: String {
        value ?? LocalizedTextProvider(
            language: .traditionalChinese,
            systemLocale: Locale(identifier: "zh_TW")
        ).text(.commonUnknown)
    }

    func renderedText(using text: LocalizedTextProvider) -> String {
        value ?? text.text(.commonUnknown)
    }
}

enum RedactedSettingsHealth: Equatable, Sendable {
    case healthy
    case migrated
    case usingDefaults
    case keptLastValid
    case recoveredFromBackup
    case recoveredFromBackupWriteFailed
    case writeFailed

    init(_ state: SettingsRecoveryState) {
        switch state {
        case .healthy: self = .healthy
        case .migrated: self = .migrated
        case .usingDefaults: self = .usingDefaults
        case .keptLastValid: self = .keptLastValid
        case .recoveredFromBackup: self = .recoveredFromBackup
        case .recoveredFromBackupWriteFailed:
            self = .recoveredFromBackupWriteFailed
        case .writeFailed: self = .writeFailed
        }
    }
}

enum RedactedLoginItemState: Equatable, Sendable {
    case loading
    case enabled
    case notRegistered
    case requiresApproval
    case notFound

    init(_ status: LoginItemStatus?) {
        switch status {
        case .none: self = .loading
        case .some(.enabled): self = .enabled
        case .some(.notRegistered): self = .notRegistered
        case .some(.requiresApproval): self = .requiresApproval
        case .some(.notFound): self = .notFound
        }
    }
}

struct RedactedDiagnosticsSnapshot: Equatable, Sendable {
    let appVersion: RedactedDisplayVersion
    let codexVersion: RedactedDisplayVersion
    let settingsSchemaVersion: Int
    let settingsHealth: RedactedSettingsHealth
    let rateState: SettingsCapabilityState
    let usageState: SettingsCapabilityState
    let rateLastSuccessAt: Date?
    let usageLastSuccessAt: Date?
    let loginItemState: RedactedLoginItemState
}

struct RedactedDiagnosticsPresentation: Equatable, Sendable {
    let snapshot: RedactedDiagnosticsSnapshot
    let renderedText: String

    init(
        snapshot: RedactedDiagnosticsSnapshot,
        text: LocalizedTextProvider = LocalizedTextProvider(
            language: .traditionalChinese,
            systemLocale: Locale(identifier: "zh_TW")
        )
    ) {
        self.snapshot = snapshot
        renderedText = RedactedDiagnosticsRenderer.render(
            snapshot,
            text: text
        )
    }

    var copyText: String { renderedText }
}

private enum RedactedDiagnosticsRenderer {
    static func render(
        _ snapshot: RedactedDiagnosticsSnapshot,
        text: LocalizedTextProvider
    ) -> String {
        [
            text.text(
                .settingsDiagnosticsAppVersion,
                versionText(snapshot.appVersion, text: text)
            ),
            text.text(
                .settingsDiagnosticsCodexVersion,
                versionText(snapshot.codexVersion, text: text)
            ),
            text.text(
                .settingsDiagnosticsSchemaVersion,
                Int64(snapshot.settingsSchemaVersion)
            ),
            text.text(
                .settingsDiagnosticsSettingsHealth,
                settingsHealthText(snapshot.settingsHealth, text: text)
            ),
            text.text(
                .settingsDiagnosticsRateState,
                capabilityText(snapshot.rateState, text: text)
            ),
            text.text(
                .settingsDiagnosticsUsageState,
                capabilityText(snapshot.usageState, text: text)
            ),
            text.text(
                .settingsDiagnosticsRateLastSuccess,
                dateText(snapshot.rateLastSuccessAt, text: text)
            ),
            text.text(
                .settingsDiagnosticsUsageLastSuccess,
                dateText(snapshot.usageLastSuccessAt, text: text)
            ),
            text.text(
                .settingsDiagnosticsLoginItem,
                loginItemText(snapshot.loginItemState, text: text)
            ),
        ].joined(separator: "\n")
    }

    private static func versionText(
        _ version: RedactedDisplayVersion,
        text: LocalizedTextProvider
    ) -> String {
        version.renderedText(using: text)
    }

    private static func settingsHealthText(
        _ health: RedactedSettingsHealth,
        text: LocalizedTextProvider
    ) -> String {
        switch health {
        case .healthy: return text.text(.settingsHealthHealthy)
        case .migrated: return text.text(.settingsHealthMigrated)
        case .usingDefaults: return text.text(.settingsHealthUsingDefaults)
        case .keptLastValid:
            return text.text(.settingsHealthKeptLastValid)
        case .recoveredFromBackup:
            return text.text(.settingsHealthRecoveredBackup)
        case .recoveredFromBackupWriteFailed:
            return text.text(.settingsHealthRecoveredBackupWriteFailed)
        case .writeFailed: return text.text(.settingsHealthWriteFailed)
        }
    }

    private static func capabilityText(
        _ state: SettingsCapabilityState,
        text: LocalizedTextProvider
    ) -> String {
        switch state {
        case .loading: return text.text(.commonLoading)
        case .fresh: return text.text(.commonAvailable)
        case .stale: return text.text(.commonStale)
        case .unsupported: return text.text(.commonUnsupported)
        case .unavailable: return text.text(.commonUnavailable)
        }
    }

    private static func dateText(
        _ date: Date?,
        text: LocalizedTextProvider
    ) -> String {
        guard let date else { return text.text(.commonUnknown) }
        return ISO8601DateFormatter().string(from: date)
    }

    private static func loginItemText(
        _ state: RedactedLoginItemState,
        text: LocalizedTextProvider
    ) -> String {
        switch state {
        case .loading: return text.text(.commonLoading)
        case .enabled: return text.text(.commonEnabled)
        case .notRegistered:
            return text.text(.settingsLoginStateNotRegistered)
        case .requiresApproval:
            return text.text(.settingsLoginStateRequiresApproval)
        case .notFound: return text.text(.settingsLoginStateNotFound)
        }
    }
}

struct AdvancedSettingsPresentation: Equatable, Sendable {
    let capabilities: [SettingsCapabilityRow]
    let tokenActivity: SettingsTokenActivityPresentation
    let installedCodexVersion: String
    let diagnostics: RedactedDiagnosticsPresentation
}

struct SettingsPresentation: Equatable, Sendable {
    let general: GeneralSettingsPresentation
    let appearance: AppearanceSettingsPresentation
    let advanced: AdvancedSettingsPresentation
}

struct SafeBucketLabelPresenter {
    let text: LocalizedTextProvider

    func label(bucketKey: String, limitName: String? = nil) -> String {
        if let limitName, let label = sanitized(limitName) {
            return label
        }
        if let label = sanitized(bucketKey) {
            return label
        }
        return text.text(.settingsUnnamedBucket)
    }

    private func sanitized(_ raw: String) -> String? {
        let visibleScalars = raw.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }
        let visible = String(String.UnicodeScalarView(visibleScalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !visible.isEmpty else { return nil }

        let limit = 32
        guard visible.count > limit else { return visible }
        return String(visible.prefix(limit)) + "…"
    }
}

struct SettingsPresenter {
    func makePresentation(
        settings: AppSettings,
        rateState: CapabilityState<RateLimitCatalog>,
        usageState: CapabilityState<TokenActivitySnapshot>,
        rateLastSuccessAt: Date?,
        usageLastSuccessAt: Date?,
        isRefreshing: Bool,
        loginItemStatus: LoginItemStatus?,
        theme: ThemeSettingsSnapshot,
        installedCodexVersion: String,
        recoveryState: SettingsRecoveryState,
        appVersion: String,
        now: Date,
        dashboardStates: [ProviderID: ProviderPresentationState] = [:],
        systemLocale: Locale = .current,
        claudeRelaySettings: ClaudeRelaySettingsPresentation = .unavailable,
        loginItemOperationRecoveryAvailable: Bool = false,
        text injectedText: LocalizedTextProvider? = nil
    ) -> SettingsPresentation {
        let text = injectedText ?? LocalizedTextProvider(
            language: settings.language,
            systemLocale: .current
        )
        let rateCapability = capabilityRow(
            lane: .rateLimits,
            state: rateState,
            text: text
        )
        let usageCapability = capabilityRow(
            lane: .tokenActivity,
            state: usageState,
            text: text
        )
        let tokenActivity = SettingsTokenActivityPresenter(
            text: text
        ).makePresentation(
            usageState: usageState,
            atUTC: now
        )
        let safeAppVersion = RedactedDisplayVersion(appVersion)
        let safeCodexVersion = RedactedDisplayVersion(installedCodexVersion)

        return SettingsPresentation(
            general: GeneralSettingsPresentation(
                providers: providerSettingsPresentation(
                    settings: settings,
                    dashboardStates: dashboardStates,
                    codexCatalog: rateState,
                    now: now,
                    systemLocale: systemLocale,
                    text: text,
                    claudeRelay: claudeRelaySettings
                ),
                menuBar: menuBarPresentation(
                    settings: settings,
                    rateState: rateState,
                    text: text
                ),
                percentageMode: settings.percentageMode,
                freshness: SettingsFreshnessPresentation(
                    rateText: freshnessText(
                        label: text.text(.settingsRateLimits),
                        state: rateCapability.state,
                        lastSuccessAt: rateLastSuccessAt,
                        now: now,
                        text: text
                    ),
                    usageText: freshnessText(
                        label: text.text(.settingsTokenActivity),
                        state: usageCapability.state,
                        lastSuccessAt: usageLastSuccessAt,
                        now: now,
                        text: text
                    ),
                    sourceText: text.text(.settingsSourceLocalAppServer),
                    isRefreshing: isRefreshing
                ),
                spacePolicy: settings.spacePolicy,
                loginItem: loginItemPresentation(
                    loginItemStatus,
                    operationRecoveryAvailable:
                        loginItemOperationRecoveryAvailable,
                    text: text
                ),
                language: settings.language
            ),
            appearance: AppearanceSettingsPresentation(
                theme: localizedThemeSnapshot(theme, text: text),
                colorScheme: AppearanceColorScheme(
                    rawValue: settings.appearance.colorScheme
                ) ?? .system,
                density: AppearanceDensity(
                    rawValue: settings.appearance.density
                ) ?? .system,
                displayProfile: settings.appearance.displayProfile,
                allowsColorSchemeSelection: true,
                allowsDensitySelection: true,
                allowsDisplayProfileSelection: true
            ),
            advanced: AdvancedSettingsPresentation(
                capabilities: [rateCapability, usageCapability],
                tokenActivity: tokenActivity,
                installedCodexVersion: safeCodexVersion.renderedText(
                    using: text
                ),
                diagnostics: RedactedDiagnosticsPresentation(
                    snapshot: RedactedDiagnosticsSnapshot(
                        appVersion: safeAppVersion,
                        codexVersion: safeCodexVersion,
                        settingsSchemaVersion: settings.schemaVersion,
                        settingsHealth: RedactedSettingsHealth(recoveryState),
                        rateState: rateCapability.state,
                        usageState: usageCapability.state,
                        rateLastSuccessAt: rateLastSuccessAt,
                        usageLastSuccessAt: usageLastSuccessAt,
                        loginItemState: RedactedLoginItemState(loginItemStatus)
                    ),
                    text: text
                )
            )
        )
    }

    func providerSettingsPresentation(
        settings: AppSettings,
        dashboardStates: [ProviderID: ProviderPresentationState],
        codexCatalog: CapabilityState<RateLimitCatalog>,
        now: Date,
        systemLocale: Locale,
        text: LocalizedTextProvider,
        claudeRelay: ClaudeRelaySettingsPresentation = .unavailable
    ) -> ProviderSettingsPresentation {
        let normalizedSettings = settings.normalizedForSelectableProviders()
        let enabledProviders = normalizedSettings.enabledProviders
        let enabledSet = Set(enabledProviders)
        let orderedProviders = enabledProviders
            + ProviderCatalog.selectableProviderIDs.filter {
                !enabledSet.contains($0)
            }
        let rows = orderedProviders.map { providerID in
            let enabledIndex = enabledProviders.firstIndex(of: providerID)
            return providerRow(
                providerID: providerID,
                isEnabled: enabledIndex != nil,
                enabledIndex: enabledIndex,
                enabledCount: enabledProviders.count,
                state: dashboardStates[providerID] ?? .loading,
                codexCatalog: codexCatalog,
                preference:
                    normalizedSettings.primaryMetricPreferences[providerID],
                now: now,
                text: text
            )
        }
        return ProviderSettingsPresentation(
            rows: rows,
            preview: StatusItemPresenter().makePresentation(
                dashboardStates: dashboardStates,
                codexCatalog: codexCatalog,
                settings: normalizedSettings,
                now: now,
                locale: systemLocale
            ),
            showsEmptySelectionRecovery: false,
            claudeRelay: claudeRelay
        )
    }

    private func providerRow(
        providerID: ProviderID,
        isEnabled: Bool,
        enabledIndex: Int?,
        enabledCount: Int,
        state: ProviderPresentationState,
        codexCatalog: CapabilityState<RateLimitCatalog>,
        preference: PrimaryMetricPreference?,
        now: Date,
        text: LocalizedTextProvider
    ) -> SettingsProviderRowPresentation {
        let snapshot: ProviderSnapshot?
        switch state {
        case let .fresh(value), let .stale(value): snapshot = value
        case .loading, .notConnected, .unsupported, .failed: snapshot = nil
        }
        let descriptor = ProviderCatalog.descriptor(for: providerID)
        let supportsQuota = descriptor?.capabilities.contains(.quotaWindows)
            == true
        // Codex window selection has its own automatic/manual controls. The
        // generic primary-metric picker would be a no-op for Codex.
        let metrics = supportsQuota && providerID != .codex
            ? snapshot?.metrics ?? []
            : []
        let selections = ProviderPrimaryMetricResolver().resolveMany(
            metrics: metrics,
            preference: preference,
            maximumCount: Int.max
        )
        let selected = ProviderPrimaryMetricResolver().resolve(
            metrics: metrics,
            preference: preference
        )
        let connection = providerConnectionPresentation(
            providerID: providerID,
            state: state,
            snapshot: snapshot,
            text: text
        )
        let quota = providerID == .codex
            ? codexQuotaPresentation(codexCatalog, text: text)
            : providerQuotaPresentation(
                providerID: providerID,
                state: state,
                snapshot: snapshot,
                supportsQuota: supportsQuota,
                text: text
            )
        let links = providerLinks(descriptor: descriptor, text: text)
        return SettingsProviderRowPresentation(
            providerID: providerID,
            name: providerName(providerID, text: text),
            isEnabled: isEnabled,
            canMoveUp: enabledIndex.map { $0 > 0 } ?? false,
            canMoveDown: enabledIndex.map { $0 + 1 < enabledCount } ?? false,
            connectionState: connection.state,
            connectionDetail: connection.detail,
            quotaState: quota.state,
            quotaDetail: quota.detail,
            lastUpdatedText: (providerID == .codex
                ? codexCatalogSuccessDate(codexCatalog)
                : snapshot?.capturedAt).map {
                    providerRelativeTime(from: $0, now: now, text: text)
                },
            maskedIdentityText: snapshot?.accountSummary?.maskedIdentity?
                .description,
            metricOptions: selections.map {
                SettingsProviderMetricOption(
                    metricKey: $0.metricKey,
                    title: providerMetricTitle($0, text: text)
                )
            },
            selectedMetricKey: selected?.metricKey,
            links: links
        )
    }

    private func codexCatalogSuccessDate(
        _ state: CapabilityState<RateLimitCatalog>
    ) -> Date? {
        switch state {
        case let .fresh(_, date), let .stale(_, date, _): date
        case .loading, .unsupported, .unavailable: nil
        }
    }

    private func providerRelativeTime(
        from date: Date,
        now: Date,
        text: LocalizedTextProvider
    ) -> String {
        let elapsed = max(0, Int(now.timeIntervalSince(date)))
        switch elapsed {
        case 0..<60:
            return text.text(.formatJustNow)
        case 60..<3_600:
            return text.text(.formatMinutesAgo, Int64(elapsed / 60))
        case 3_600..<86_400:
            return text.text(.formatHoursAgo, Int64(elapsed / 3_600))
        default:
            return text.text(.formatDaysAgo, Int64(elapsed / 86_400))
        }
    }

    private func providerConnectionPresentation(
        providerID: ProviderID,
        state: ProviderPresentationState,
        snapshot: ProviderSnapshot?,
        text: LocalizedTextProvider
    ) -> (state: SettingsProviderConnectionState, detail: String) {
        switch state {
        case .loading:
            return (.loading, text.text(.commonLoading))
        case .notConnected:
            let key: LocalizationCatalogKey = switch providerID {
            case .googleAntigravity: .statusProviderAppNotInstalled
            case .codex: .statusProviderNotConnected
            case .claudeCode: .statusProviderClaudeCLINotSignedIn
            case .kimiCode: .statusProviderCommandUnavailable
            }
            return (.notConnected, text.text(key))
        case .unsupported:
            return (.unsupported, text.text(.commonUnsupported))
        case .failed:
            return (.failed, text.text(.statusProviderFailed))
        case .fresh, .stale:
            let freshPresentation: (
                state: SettingsProviderConnectionState,
                detail: String
            ) = switch snapshot?.runtimePresence {
            case .application(installed: true, running: true):
                (.connected, text.text(.statusProviderAppRunning))
            case .application(installed: true, running: false):
                (.notConnected, text.text(.statusProviderAppInstalled))
            case .command(available: true):
                (.notConnected, text.text(.statusProviderCommandAvailable))
            case .application, .command:
                (.notConnected, text.text(.statusProviderNotConnected))
            case nil:
                (
                    .connected,
                    text.text(
                        providerID == .claudeCode
                            ? .statusProviderClaudeCLISignedIn
                            : .commonAvailable
                    )
                )
            }
            if case .stale = state {
                return (
                    .stale,
                    text.text(
                        .statusProviderStaleDetail,
                        freshPresentation.detail
                    )
                )
            }
            return freshPresentation
        }
    }

    private func providerQuotaPresentation(
        providerID: ProviderID,
        state: ProviderPresentationState,
        snapshot: ProviderSnapshot?,
        supportsQuota: Bool,
        text: LocalizedTextProvider
    ) -> (state: SettingsProviderQuotaState, detail: String) {
        guard supportsQuota else {
            let key: LocalizationCatalogKey = providerID == .googleAntigravity
                ? .statusProviderLocalAppOnly
                : .statusProviderLocalCLIOnly
            return (.unsupported, text.text(key))
        }
        switch state {
        case .loading:
            return (.loading, text.text(.commonLoading))
        case .fresh where !(snapshot?.metrics.isEmpty ?? true):
            return (.available, text.text(.commonAvailable))
        case .stale where !(snapshot?.metrics.isEmpty ?? true):
            return (.stale, text.text(.commonStale))
        case .fresh, .stale:
            return (
                .awaitingSnapshot,
                text.text(
                    providerID == .claudeCode
                        ? .statusProviderClaudeWaitingRelay
                        : .statusProviderWaitingSnapshot
                )
            )
        case .unsupported:
            return (.unsupported, text.text(.commonUnsupported))
        case .notConnected where providerID == .claudeCode:
            return (
                .unavailable,
                text.text(.statusProviderClaudeCLINotSignedIn)
            )
        case .notConnected, .failed:
            return (.unavailable, text.text(.commonUnavailable))
        }
    }

    private func codexQuotaPresentation(
        _ state: CapabilityState<RateLimitCatalog>,
        text: LocalizedTextProvider
    ) -> (state: SettingsProviderQuotaState, detail: String) {
        switch state {
        case .loading:
            return (.loading, text.text(.commonLoading))
        case let .fresh(catalog, _):
            guard !catalog.selectedBucket.windows.isEmpty else {
                return (.unavailable, text.text(.statusNoWindowsToolTip))
            }
            return (.available, text.text(.commonAvailable))
        case let .stale(catalog, _, _):
            guard !catalog.selectedBucket.windows.isEmpty else {
                return (.unavailable, text.text(.statusNoWindowsToolTip))
            }
            return (.stale, text.text(.commonStale))
        case .unsupported, .unavailable(.unsupportedAuthMode):
            return (.unsupported, text.text(.commonUnsupported))
        case .unavailable:
            return (.unavailable, text.text(.commonUnavailable))
        }
    }

    private func providerLinks(
        descriptor: ProviderDescriptor?,
        text: LocalizedTextProvider
    ) -> [SettingsProviderLinkPresentation] {
        guard let descriptor else { return [] }
        var links: [SettingsProviderLinkPresentation] = []
        if let usageURL = descriptor.officialUsageDestinationURL,
           ProviderCatalog.isAllowedExternalURL(usageURL)
        {
            links.append(
                SettingsProviderLinkPresentation(
                    kind: .usage,
                    title: text.text(.actionOfficialUsage),
                    url: usageURL
                )
            )
        }
        if descriptor.officialHelpURL
            != descriptor.officialUsageDestinationURL,
           ProviderCatalog.isAllowedExternalURL(descriptor.officialHelpURL)
        {
            links.append(
                SettingsProviderLinkPresentation(
                    kind: .help,
                    title: text.text(.actionOfficialHelp),
                    url: descriptor.officialHelpURL
                )
            )
        }
        return links
    }

    private func providerMetricTitle(
        _ selection: ProviderPrimaryMetricSelection,
        text: LocalizedTextProvider
    ) -> String {
        switch selection.durationMinutes {
        case 300: return text.text(.settingsFiveHours)
        case 1_440: return text.text(.settingsDaily)
        case 10_080: return text.text(.settingsWeekly)
        case let minutes?: return text.text(.settingsMinutes, minutes)
        case nil:
            return text.text(
                .statusProviderWindowOrdinal,
                Int64(selection.safeWindowOrdinal)
            )
        }
    }

    private func providerName(
        _ providerID: ProviderID,
        text: LocalizedTextProvider
    ) -> String {
        let key: LocalizationCatalogKey = switch providerID {
        case .googleAntigravity: .providerNameGoogleAntigravity
        case .codex: .providerNameCodex
        case .claudeCode: .providerNameClaudeCode
        case .kimiCode: .providerNameKimiCode
        }
        return text.text(key)
    }

    private func menuBarPresentation(
        settings: AppSettings,
        rateState: CapabilityState<RateLimitCatalog>,
        text: LocalizedTextProvider
    ) -> MenuBarSettingsPresentation {
        let normalizedSettings = settings.normalizedForSelectableProviders()
        let catalog: RateLimitCatalog?
        switch rateState {
        case let .fresh(value, _), let .stale(value, _, _):
            catalog = value
        case .loading, .unsupported, .unavailable:
            catalog = nil
        }

        let usesAutomaticSelection: Bool
        let selected: [WindowIdentity]
        switch normalizedSettings.menuBarMode {
        case .automatic:
            usesAutomaticSelection = true
            selected = catalog?.automaticWindows().map(\.identity) ?? []
        case let .manual(values):
            usesAutomaticSelection = false
            selected = values
        }

        let selectedSet = Set(selected)
        let selectionIsFull = !usesAutomaticSelection && selected.count >= 2
        let liveWindows = allWindows(in: catalog)
        let liveIdentities = Set(liveWindows.map(\.identity))
        var options = liveWindows.map { window in
            let isSelected = selectedSet.contains(window.identity)
            let isEnabled = !usesAutomaticSelection
                && (isSelected || !selectionIsFull)
            return SettingsWindowOption(
                identity: window.identity,
                title: windowTitle(window.identity, text: text),
                isSelected: isSelected,
                isEnabled: isEnabled,
                isAvailable: true,
                disabledExplanation: selectionIsFull && !isSelected
                    ? text.text(.settingsSelectionFull)
                    : nil
            )
        }
        if !usesAutomaticSelection {
            for identity in selected where !liveIdentities.contains(identity) {
                options.append(
                    SettingsWindowOption(
                        identity: identity,
                        title: text.text(
                            .settingsWindowRetiredTitle,
                            windowTitle(identity, text: text)
                        ),
                        isSelected: true,
                        isEnabled: true,
                        isAvailable: false,
                        disabledExplanation: nil
                    )
                )
            }
        }

        return MenuBarSettingsPresentation(
            usesAutomaticSelection: usesAutomaticSelection,
            options: options,
            selectionLimitExplanation: selectionIsFull
                ? text.text(.settingsSelectionLimit)
                : nil,
            showsCodexWindowControls:
                true,
            statusItemDisplayMode: normalizedSettings.statusItemDisplayMode,
            primaryProviderOptions: normalizedSettings.enabledProviders.map {
                SettingsPrimaryProviderOption(
                    providerID: $0,
                    name: providerName($0, text: text)
                )
            },
            selectedPrimaryProvider:
                effectivePrimaryProvider(normalizedSettings) ?? .codex,
            showsPrimaryProviderPicker:
                normalizedSettings.enabledProviders.count > 1
                    && normalizedSettings.statusItemDisplayMode == .primary
        )
    }

    private func effectivePrimaryProvider(
        _ settings: AppSettings
    ) -> ProviderID? {
        if let configured = settings.primaryStatusItemProvider,
           settings.enabledProviders.contains(configured)
        {
            return configured
        }
        return settings.enabledProviders.first
    }

    private func allWindows(
        in catalog: RateLimitCatalog?
    ) -> [RateLimitWindow] {
        guard let catalog else { return [] }
        let buckets: [RateLimitBucket]
        if catalog.rateLimitsByLimitId.isEmpty {
            buckets = [catalog.legacyBucket]
        } else {
            buckets = catalog.rateLimitsByLimitId.keys.sorted().compactMap {
                catalog.rateLimitsByLimitId[$0]
            }
        }
        return buckets.flatMap { bucket in
            bucket.windows.sorted { lhs, rhs in
                if lhs.identity.sourceSlot != rhs.identity.sourceSlot {
                    return lhs.identity.sourceSlot == .primary
                }
                return (lhs.durationMinutes ?? Int64.max)
                    < (rhs.durationMinutes ?? Int64.max)
            }
        }
    }

    private func windowTitle(
        _ identity: WindowIdentity,
        text: LocalizedTextProvider
    ) -> String {
        let duration: String
        switch identity.durationMinutes {
        case 300: duration = text.text(.settingsFiveHours)
        case 1_440: duration = text.text(.settingsDaily)
        case 10_080: duration = text.text(.settingsWeekly)
        case let minutes?: duration = text.text(.settingsMinutes, minutes)
        case nil: duration = text.text(.settingsUsageWindow)
        }
        let slot = text.text(
            identity.sourceSlot == .primary
                ? .cardPrimaryWindow
                : .cardSecondaryWindow
        )
        return text.text(
            .settingsWindowTitle,
            SafeBucketLabelPresenter(text: text).label(
                bucketKey: identity.bucketKey
            ),
            duration,
            slot
        )
    }

    private func loginItemPresentation(
        _ status: LoginItemStatus?,
        operationRecoveryAvailable: Bool,
        text: LocalizedTextProvider
    ) -> LoginItemSettingsPresentation {
        guard let status else {
            return LoginItemSettingsPresentation(
                status: nil,
                isLoading: true,
                isOn: false,
                canToggle: false,
                canOpenSystemSettings: false,
                title: text.text(.settingsGroupLogin),
                detail: text.text(.settingsLoginReading)
            )
        }
        switch status {
        case .enabled:
            return LoginItemSettingsPresentation(
                status: status,
                isLoading: false,
                isOn: true,
                canToggle: true,
                canOpenSystemSettings: operationRecoveryAvailable,
                title: text.text(.settingsGroupLogin),
                detail: text.text(.settingsLoginEnabled)
            )
        case .notRegistered:
            return LoginItemSettingsPresentation(
                status: status,
                isLoading: false,
                isOn: false,
                canToggle: true,
                canOpenSystemSettings: operationRecoveryAvailable,
                title: text.text(.settingsGroupLogin),
                detail: text.text(.settingsLoginDisabled)
            )
        case .requiresApproval:
            return LoginItemSettingsPresentation(
                status: status,
                isLoading: false,
                isOn: true,
                canToggle: true,
                canOpenSystemSettings: true,
                title: text.text(.settingsGroupLogin),
                detail: text.text(.settingsLoginRequiresApproval)
            )
        case .notFound:
            return LoginItemSettingsPresentation(
                status: status,
                isLoading: false,
                isOn: false,
                canToggle: true,
                canOpenSystemSettings: operationRecoveryAvailable,
                title: text.text(.settingsGroupLogin),
                detail: text.text(.settingsLoginDisabled)
            )
        }
    }

    private func capabilityRow<Value>(
        lane: SettingsCapabilityLane,
        state: CapabilityState<Value>,
        text: LocalizedTextProvider
    ) -> SettingsCapabilityRow where Value: Equatable & Sendable {
        let title = text.text(
            lane == .rateLimits
                ? .settingsRateLimits
                : .settingsTokenActivity
        )
        switch state {
        case .loading:
            return SettingsCapabilityRow(
                lane: lane,
                title: title,
                state: .loading,
                detail: text.text(.commonLoading)
            )
        case .fresh:
            return SettingsCapabilityRow(
                lane: lane,
                title: title,
                state: .fresh,
                detail: text.text(.commonAvailable)
            )
        case .stale:
            return SettingsCapabilityRow(
                lane: lane,
                title: title,
                state: .stale,
                detail: text.text(.settingsCapabilityStale)
            )
        case .unsupported:
            return SettingsCapabilityRow(
                lane: lane,
                title: title,
                state: .unsupported,
                detail: text.text(.settingsCapabilityNotProvided)
            )
        case .unavailable:
            return SettingsCapabilityRow(
                lane: lane,
                title: title,
                state: .unavailable,
                detail: text.text(.commonUnavailable)
            )
        }
    }

    private func freshnessText(
        label: String,
        state: SettingsCapabilityState,
        lastSuccessAt: Date?,
        now: Date,
        text: LocalizedTextProvider
    ) -> String {
        let stateText: String
        switch state {
        case .loading: stateText = text.text(.commonLoading)
        case .fresh: stateText = text.text(.commonFresh)
        case .stale: stateText = text.text(.commonStale)
        case .unsupported: stateText = text.text(.commonUnsupported)
        case .unavailable: stateText = text.text(.commonUnavailable)
        }
        guard let lastSuccessAt else {
            return text.text(
                .settingsFreshnessNeverSucceeded,
                label,
                stateText
            )
        }
        let seconds = max(0, Int(now.timeIntervalSince(lastSuccessAt)))
        let relative: String
        if seconds < 60 {
            relative = text.text(.formatJustNow)
        } else if seconds < 3_600 {
            relative = text.text(
                .formatMinutesAgo,
                Int64(seconds / 60)
            )
        } else {
            relative = text.text(
                .formatHoursAgo,
                Int64(seconds / 3_600)
            )
        }
        return text.text(
            .settingsFreshnessLastSucceeded,
            label,
            stateText,
            relative
        )
    }

    private func localizedThemeSnapshot(
        _ snapshot: ThemeSettingsSnapshot,
        text: LocalizedTextProvider
    ) -> ThemeSettingsSnapshot {
        let choices = snapshot.choices.map { choice in
            guard !choice.isCustom else {
                if choice.id == "custom" {
                    return ThemeChoice(
                        id: choice.id,
                        name: text.text(.settingsCustomTheme),
                        isCustom: true
                    )
                }
                return choice
            }
            guard let key = builtInThemeKey(choice.id) else { return choice }
            return ThemeChoice(
                id: choice.id,
                name: text.text(key),
                isCustom: false
            )
        }
        return ThemeSettingsSnapshot(
            choices: choices,
            selectedThemeID: snapshot.selectedThemeID,
            selectedThemeDocument: snapshot.selectedThemeDocument,
            selectedThemeRasterData: snapshot.selectedThemeRasterData,
            allowsSelection: snapshot.allowsSelection,
            allowsReset: snapshot.allowsReset,
            allowsImport: snapshot.allowsImport,
            allowsExport: snapshot.allowsExport,
            allowsCustomEditor: snapshot.allowsCustomEditor,
            allowsColorScheme: snapshot.allowsColorScheme,
            allowsDensity: snapshot.allowsDensity,
            accessibilityFallbacksActive:
                snapshot.accessibilityFallbacksActive
        )
    }

    private func builtInThemeKey(
        _ rawID: String
    ) -> LocalizationCatalogKey? {
        switch rawID {
        case BuiltInThemeID.morandi.rawValue: .themeMorandi
        case BuiltInThemeID.cyberpunk.rawValue: .themeCyberpunk
        case BuiltInThemeID.warmHandDrawn.rawValue, "warm-illustration":
            .themeWarmHandDrawn
        case BuiltInThemeID.glass.rawValue: .themeGlass
        case BuiltInThemeID.sketch.rawValue: .themeSketch
        case BuiltInThemeID.cartoonIllustration.rawValue, "cartoon":
            .themeCartoonIllustration
        default: nil
        }
    }

}

struct SettingsTokenActivityPresenter {
    let text: LocalizedTextProvider

    func makePresentation(
        usageState: CapabilityState<TokenActivitySnapshot>,
        atUTC now: Date
    ) -> SettingsTokenActivityPresentation {
        let activity: TokenActivityPresentation
        switch usageState {
        case let .fresh(snapshot, _), let .stale(snapshot, _, _):
            activity = snapshot.derive(
                atUTC: now,
                calendar: Calendar(identifier: .gregorian)
            )
        case .loading, .unsupported, .unavailable:
            activity = TokenActivityPresentation(
                utcToday: .unavailable,
                currentMonthSubtotal: .unavailable,
                rawDateRange: nil,
                uniqueDayCount: 0,
                coverage: .unknown
            )
        }

        return SettingsTokenActivityPresentation(
            groupTitle: text.text(.activityGroupTitle),
            inputTitle: text.text(.activityColumnInput),
            outputTitle: text.text(.activityColumnOutput),
            totalTitle: text.text(.activityColumnTotal),
            today: period(
                title: text.text(.activityTodayUTC),
                breakdown: activity.utcTodayBreakdown
            ),
            currentMonth: period(
                title: text.text(.activityCurrentMonthLocalSubtotal),
                breakdown: activity.currentMonthBreakdown
            ),
            coverageText: coverageText(activity.coverage),
            dateRangeText: activity.rawDateRange.map {
                text.text(.activityDateRange, $0.lowerBound, $0.upperBound)
            },
            disclosure: text.text(.activitySourceDisclosure),
            missingDataNote: text.text(.activityPartialNotZero)
        )
    }

    private func period(
        title: String,
        breakdown: TokenActivityBreakdown
    ) -> SettingsTokenPeriodPresentation {
        SettingsTokenPeriodPresentation(
            title: title,
            input: metric(breakdown.inputTokens),
            output: metric(breakdown.outputTokens),
            total: metric(breakdown.totalTokens)
        )
    }

    private func metric(
        _ availability: MetricAvailability<Int64>
    ) -> SettingsTokenMetricPresentation {
        switch availability {
        case let .available(value):
            return SettingsTokenMetricPresentation(
                state: .available,
                text: tokenCount(value, partial: false)
            )
        case let .partial(value, _):
            return SettingsTokenMetricPresentation(
                state: .partial,
                text: tokenCount(value, partial: true)
            )
        case .notReturned:
            return SettingsTokenMetricPresentation(
                state: .notReturned,
                text: text.text(.commonNotReturned)
            )
        case .unavailable:
            return SettingsTokenMetricPresentation(
                state: .unavailable,
                text: text.text(.commonUnavailable)
            )
        }
    }

    private func tokenCount(_ value: Int64, partial: Bool) -> String {
        let number = LocalizedValuePresenter(locale: text.locale).integer(value)
        return text.text(
            partial ? .activityTokenCountPartial : .activityTokenCount,
            number
        )
    }

    private func coverageText(_ coverage: ActivityCoverage) -> String {
        switch coverage {
        case .reportedRange:
            text.text(.activityCoverageReported)
        case .partial:
            text.text(.activityCoveragePartial)
        case .unknown:
            text.text(.activityCoverageUnknown)
        }
    }
}
