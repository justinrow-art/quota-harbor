import Foundation
import Observation

private final class LocalizationBundleMarker: NSObject {}

enum SupportedAppLocale: String, CaseIterable, Equatable, Hashable, Sendable {
    case traditionalChinese = "zh-Hant"
    case simplifiedChinese = "zh-Hans"
    case english = "en"
    case japanese = "ja"
    case korean = "ko"
    case spanish = "es"
    case french = "fr"
    case german = "de"

    var foundationLocale: Locale {
        Locale(identifier: rawValue)
    }
}

enum LocalizationCatalogKey: String, CaseIterable, Equatable, Hashable, Sendable {
    case appName = "app.name"
    case appSettingsWindowTitle = "app.window.settings.title"
    case actionClose = "action.close"
    case actionHideFloatingCard = "action.hide_floating_card"
    case actionSkip = "action.skip"
    case actionCancel = "action.cancel"
    case actionSave = "action.save"
    case actionSaveAndApply = "action.save_and_apply"
    case actionRefresh = "action.refresh"
    case actionRetry = "action.retry"
    case actionRefreshNow = "action.refresh_now"
    case actionSettings = "action.settings"
    case actionSettingsMenu = "action.settings_menu"
    case actionQuit = "action.quit"
    case actionQuitApp = "action.quit_app"
    case actionChooseImage = "action.choose_image"
    case actionRemove = "action.remove"
    case actionImport = "action.import"
    case actionExport = "action.export"
    case actionResetSettings = "action.reset_settings"
    case actionResetTheme = "action.reset_theme"
    case actionCopyDiagnostics = "action.copy_diagnostics"
    case actionOpenLoginItems = "action.open_login_items"
    case actionNext = "action.next"
    case actionBack = "action.back"
    case actionMoveUp = "action.move_up"
    case actionMoveDown = "action.move_down"
    case actionOfficialUsage = "action.official_usage"
    case actionOfficialHelp = "action.official_help"
    case actionConfirm = "action.confirm"
    case commonLoading = "common.state.loading"
    case commonAvailable = "common.state.available"
    case commonFresh = "common.state.fresh"
    case commonPartial = "common.state.partial"
    case commonStale = "common.state.stale"
    case commonUnsupported = "common.state.unsupported"
    case commonUnavailable = "common.state.unavailable"
    case commonUnknown = "common.state.unknown"
    case commonNotReturned = "common.state.not_returned"
    case commonEnabled = "common.state.enabled"
    case commonDisabled = "common.state.disabled"
    case providerNameGoogleAntigravity = "provider.name.google_antigravity"
    case providerNameCodex = "provider.name.codex"
    case providerNameClaudeCode = "provider.name.claude_code"
    case providerNameKimiCode = "provider.name.kimi_code"
    case cardTitle = "card.title"
    case cardPlan = "card.plan"
    case cardPrimaryWindow = "card.window.primary"
    case cardSecondaryWindow = "card.window.secondary"
    case cardWindowTitle = "card.window.title"
    case cardUnavailableTitle = "card.unavailable.title"
    case cardUpdatedAt = "card.updated_at"
    case cardStaleUpdatedAt = "card.stale_updated_at"
    case cardTokenActivityAccessibilityRow =
        "card.token_activity.accessibility_row"
    case quotaRemainingPercent = "quota.percent.remaining"
    case quotaUsedPercent = "quota.percent.used"
    case quotaResetAt = "quota.reset_at"
    case quotaResetIn = "quota.reset_in"
    case quotaWindowAccessibilityValue = "quota.window.accessibility_value"
    case quotaWindowAccessibilityUsedValue = "quota.window.accessibility_used_value"
    case orbShowDetails = "orb.action.show_details"
    case orbCollapseDetails = "orb.action.collapse_details"
    case orbAccessibilityHint = "orb.accessibility.hint"
    case orbAccessibilityStaleValue = "orb.accessibility.stale_value"
    case orbAccessibilityMinimumRemaining = "orb.accessibility.minimum_remaining"
    case errorBinaryNotFound = "error.codex.binary_not_found"
    case errorTrustValidationFailed = "error.codex.trust_validation_failed"
    case errorVersionUnsupported = "error.codex.version_unsupported"
    case errorProcessLaunchFailed = "error.codex.launch_failed"
    case errorProcessExited = "error.codex.exited"
    case errorNoWindows = "error.quota.no_windows"
    case errorSchemaChanged = "error.quota.schema_changed"
    case errorTimeout = "error.codex.timeout"
    case errorTransport = "error.codex.transport"
    case errorAuthenticationRequired = "error.codex.authentication_required"
    case errorUnsupportedAuthMode = "error.codex.auth_mode_unsupported"
    case errorBackendUnavailable = "error.quota.backend_unavailable"
    case errorServerRejected = "error.quota.server_rejected"
    case errorStaleDataUnavailable = "error.quota.stale_data_unavailable"
    case onboardingTitle = "onboarding.title"
    case onboardingMenuBarResidency = "onboarding.menu_bar_residency"
    case onboardingReopen = "onboarding.reopen"
    case onboardingQuit = "onboarding.quit"
    case onboardingLoginItemTitle = "onboarding.login_item.title"
    case onboardingLoginItemExplanation = "onboarding.login_item.explanation"
    case onboardingEnabled = "onboarding.login_item.enabled"
    case onboardingRequiresApproval = "onboarding.login_item.requires_approval"
    case onboardingSavedDisabled = "onboarding.login_item.saved_disabled"
    case onboardingDeclined = "onboarding.login_item.declined"
    case onboardingServiceNotFound = "onboarding.error.service_not_found"
    case onboardingRegistrationFailed = "onboarding.error.registration_failed"
    case onboardingUnregistrationFailed = "onboarding.error.unregistration_failed"
    case onboardingPersistenceFailed = "onboarding.error.persistence_failed"
    case onboardingOperationWarning = "onboarding.operation_warning"
    case onboardingFinish = "onboarding.finish"
    case onboardingFinishAndEnable = "onboarding.finish_and_enable"
    case onboardingProvidersTitle = "onboarding.providers.title"
    case onboardingProvidersExplanation = "onboarding.providers.explanation"
    case onboardingConnectionsTitle = "onboarding.connections.title"
    case onboardingConnectionsExplanation = "onboarding.connections.explanation"
    case onboardingPreviewTitle = "onboarding.preview.title"
    case onboardingPreviewExplanation = "onboarding.preview.explanation"
    case onboardingStepCompleted = "onboarding.step.completed"
    case onboardingStepCurrent = "onboarding.step.current"
    case onboardingStepUpcoming = "onboarding.step.upcoming"
    case settingsTabGeneral = "settings.tab.general"
    case settingsTabAppearance = "settings.tab.appearance"
    case settingsTabAdvanced = "settings.tab.advanced"
    case settingsGroupMenuBar = "settings.group.menu_bar"
    case settingsGroupProviders = "settings.group.providers"
    case settingsProvidersExplanation = "settings.providers.explanation"
    case settingsProvidersConnection = "settings.providers.connection"
    case settingsProvidersQuota = "settings.providers.quota"
    case settingsProvidersAccount = "settings.providers.account"
    case settingsProvidersLastUpdated = "settings.providers.last_updated"
    case settingsProvidersPrimaryMetric = "settings.providers.primary_metric"
    case settingsProvidersEmptyRecovery = "settings.providers.empty_recovery"
    case settingsClaudeRelayTitle = "settings.claude_relay.title"
    case settingsClaudeRelayExplanation = "settings.claude_relay.explanation"
    case settingsClaudeRelayInstall = "settings.claude_relay.install"
    case settingsClaudeRelayRemove = "settings.claude_relay.remove"
    case settingsClaudeRelayConfirmInstall =
        "settings.claude_relay.confirm_install"
    case settingsClaudeRelayConfirmRemove =
        "settings.claude_relay.confirm_remove"
    case settingsClaudeRelayNotInstalled =
        "settings.claude_relay.state.not_installed"
    case settingsClaudeRelayInstalled =
        "settings.claude_relay.state.installed"
    case settingsClaudeRelayConflict = "settings.claude_relay.state.conflict"
    case settingsClaudeRelayManualRecovery =
        "settings.claude_relay.state.manual_recovery"
    case settingsClaudeRelayInvalid = "settings.claude_relay.state.invalid"
    case settingsClaudeRelayFailed = "settings.claude_relay.state.failed"
    case settingsAutomaticWindows = "settings.menu_bar.automatic"
    case settingsStatusItemDisplayMode =
        "settings.menu_bar.display_mode"
    case settingsStatusItemDisplayAutomatic =
        "settings.menu_bar.display_mode.automatic"
    case settingsStatusItemDisplayPrimary =
        "settings.menu_bar.display_mode.primary"
    case settingsStatusItemDisplayFull =
        "settings.menu_bar.display_mode.full"
    case settingsStatusItemPrimaryProvider =
        "settings.menu_bar.primary_provider"
    case settingsStatusItemAllProvidersExplanation =
        "settings.menu_bar.all_providers_explanation"
    case settingsStatusItemFullWarning =
        "settings.menu_bar.full_warning"
    case settingsStatusItemPositionHelp =
        "settings.menu_bar.position_help"
    case settingsPercentageDisplay = "settings.menu_bar.percentage_display"
    case settingsPercentageRemaining = "settings.percentage.remaining"
    case settingsPercentageUsed = "settings.percentage.used"
    case settingsSelectionFull = "settings.menu_bar.selection_full"
    case settingsSelectionLimit = "settings.menu_bar.selection_limit"
    case settingsWindowRetired = "settings.menu_bar.window_retired"
    case settingsWindowRetiredTitle = "settings.menu_bar.window_retired_title"
    case settingsWindowTitle = "settings.menu_bar.window_title"
    case settingsFiveHours = "settings.duration.five_hours"
    case settingsDaily = "settings.duration.daily"
    case settingsWeekly = "settings.duration.weekly"
    case settingsMinutes = "settings.duration.minutes"
    case settingsUsageWindow = "settings.duration.usage_window"
    case settingsUnnamedBucket = "settings.bucket.unnamed"
    case settingsGroupRefreshSource = "settings.group.refresh_source"
    case settingsRefreshScheduleExplanation =
        "settings.refresh.schedule_explanation"
    case settingsFreshnessNeverSucceeded = "settings.freshness.never_succeeded"
    case settingsFreshnessLastSucceeded = "settings.freshness.last_succeeded"
    case settingsSourceLocalAppServer = "settings.source.local_app_server"
    case settingsGroupDisplayLocation = "settings.group.display_location"
    case settingsFloatingCard = "settings.display.floating_card"
    case settingsCurrentSpace = "settings.display.current_space"
    case settingsAllSpaces = "settings.display.all_spaces"
    case settingsGroupLogin = "settings.group.login"
    case settingsLoginReading = "settings.login.reading"
    case settingsLoginEnabled = "settings.login.enabled"
    case settingsLoginDisabled = "settings.login.disabled"
    case settingsLoginRequiresApproval = "settings.login.requires_approval"
    case settingsLoginUnavailable = "settings.login.unavailable"
    case settingsGroupLanguage = "settings.group.language"
    case settingsInterfaceLanguage = "settings.language.interface"
    case languageSystem = "language.system"
    case languageTraditionalChinese = "language.zh_hant"
    case languageSimplifiedChinese = "language.zh_hans"
    case languageEnglish = "language.en"
    case languageJapanese = "language.ja"
    case languageKorean = "language.ko"
    case languageSpanish = "language.es"
    case languageFrench = "language.fr"
    case languageGerman = "language.de"
    case settingsGroupTheme = "settings.group.theme"
    case settingsCustomTheme = "settings.theme.custom"
    case settingsThemeEnginePending = "settings.theme.engine_pending"
    case settingsOpenThemeEditor = "settings.theme.open_editor"
    case settingsGroupAppearanceMode = "settings.group.appearance_mode"
    case settingsColorScheme = "settings.appearance.color_scheme"
    case settingsAppearanceSystem = "settings.appearance.system"
    case settingsLight = "settings.appearance.light"
    case settingsDark = "settings.appearance.dark"
    case settingsInformationDensity = "settings.appearance.density"
    case settingsComfortable = "settings.appearance.comfortable"
    case settingsCompact = "settings.appearance.compact"
    case settingsDisplayProfile = "settings.appearance.display_profile"
    case settingsDisplayProfileCompact = "settings.display_profile.compact"
    case settingsDisplayProfileBalanced = "settings.display_profile.balanced"
    case settingsDisplayProfileFull = "settings.display_profile.full"
    case settingsAccessibilityPreview = "settings.group.accessibility_preview"
    case settingsAccessibilityPreviewLabel = "settings.accessibility.preview_label"
    case settingsAccessibilityStandard = "settings.accessibility.standard"
    case settingsAccessibilityIncreaseContrast = "settings.accessibility.increase_contrast"
    case settingsAccessibilityReduceTransparency = "settings.accessibility.reduce_transparency"
    case settingsAccessibilityBothFallbacks = "settings.accessibility.both_fallbacks"
    case settingsAccessibilityValue = "settings.accessibility.value"
    case settingsGroupCapabilities = "settings.group.capabilities"
    case settingsRateLimits = "settings.capability.rate_limits"
    case settingsTokenActivity = "settings.capability.token_activity"
    case settingsCapabilityStale = "settings.capability.stale"
    case settingsCapabilityNotProvided = "settings.capability.not_provided"
    case settingsInstalledVersion = "settings.codex.installed_version"
    case settingsRedactedDiagnostics = "settings.group.redacted_diagnostics"
    case settingsGroupResetThemeFiles = "settings.group.reset_theme_files"
    case settingsOperationAppearanceFailed = "settings.operation.appearance_failed"
    case settingsOperationThemeApplyFailed = "settings.operation.theme_apply_failed"
    case settingsOperationLoginUnexpected = "settings.operation.login_unexpected"
    case settingsOperationThemeResetFailed = "settings.operation.theme_reset_failed"
    case settingsOperationThemeImportUnavailable = "settings.operation.theme_import_unavailable"
    case settingsOperationThemeExportUnavailable = "settings.operation.theme_export_unavailable"
    case settingsOperationSaveFailed = "settings.operation.save_failed"
    case settingsDiagnosticsAppVersion = "settings.diagnostics.app_version"
    case settingsDiagnosticsCodexVersion = "settings.diagnostics.codex_version"
    case settingsDiagnosticsSchemaVersion = "settings.diagnostics.schema_version"
    case settingsDiagnosticsSettingsHealth = "settings.diagnostics.settings_health"
    case settingsDiagnosticsRateState = "settings.diagnostics.rate_state"
    case settingsDiagnosticsUsageState = "settings.diagnostics.usage_state"
    case settingsDiagnosticsRateLastSuccess = "settings.diagnostics.rate_last_success"
    case settingsDiagnosticsUsageLastSuccess = "settings.diagnostics.usage_last_success"
    case settingsDiagnosticsLoginItem = "settings.diagnostics.login_item"
    case settingsHealthHealthy = "settings.health.healthy"
    case settingsHealthMigrated = "settings.health.migrated"
    case settingsHealthUsingDefaults = "settings.health.using_defaults"
    case settingsHealthKeptLastValid = "settings.health.kept_last_valid"
    case settingsHealthRecoveredBackup = "settings.health.recovered_backup"
    case settingsHealthRecoveredBackupWriteFailed = "settings.health.recovered_backup_write_failed"
    case settingsHealthWriteFailed = "settings.health.write_failed"
    case settingsLoginStateNotRegistered = "settings.login_state.not_registered"
    case settingsLoginStateRequiresApproval = "settings.login_state.requires_approval"
    case settingsLoginStateNotFound = "settings.login_state.not_found"
    case themeMorandi = "theme.builtin.morandi"
    case themeCyberpunk = "theme.builtin.cyberpunk"
    case themeWarmHandDrawn = "theme.builtin.warm_hand_drawn"
    case themeGlass = "theme.builtin.glass"
    case themeSketch = "theme.builtin.sketch"
    case themeCartoonIllustration = "theme.builtin.cartoon_illustration"
    case themeStateLoading = "theme.state.availability.loading"
    case themeStateFresh = "theme.state.availability.fresh"
    case themeStatePartial = "theme.state.availability.partial"
    case themeStateStale = "theme.state.availability.stale"
    case themeStateUnsupported = "theme.state.availability.unsupported"
    case themeStateUnavailable = "theme.state.availability.unavailable"
    case themeHealthHealthy = "theme.state.health.healthy"
    case themeHealthWarning = "theme.state.health.warning"
    case themeHealthCritical = "theme.state.health.critical"
    case themeEditorTitle = "theme.editor.title"
    case themeEditorName = "theme.editor.name"
    case themeEditorDuplicateName = "theme.editor.duplicate_name"
    case themeEditorDuplicateDefaultName = "theme.editor.duplicate_default_name"
    case themeEditorDuplicateBuiltIn = "theme.editor.duplicate_builtin"
    case themeEditorAppearance = "theme.editor.appearance"
    case themeEditorBackground = "theme.editor.background"
    case themeEditorBackgroundType = "theme.editor.background_type"
    case themeEditorSolid = "theme.editor.background.solid"
    case themeEditorGradient = "theme.editor.background.gradient"
    case themeEditorSystemMaterial = "theme.editor.background.system_material"
    case themeEditorSemanticColors = "theme.editor.semantic_colors"
    case themeEditorGeometry = "theme.editor.geometry"
    case themeEditorRaster = "theme.editor.raster"
    case themeEditorRasterNone = "theme.editor.raster.none"
    case themeEditorRasterSanitized = "theme.editor.raster.sanitized"
    case themeEditorRasterPolicy = "theme.editor.raster.policy"
    case themeEditorTransfer = "theme.editor.transfer"
    case themeEditorIncludeRaster = "theme.editor.include_raster"
    case themeEditorPreview = "theme.editor.preview"
    case themeEditorDataState = "theme.editor.data_state"
    case themeEditorSafeToSave = "theme.editor.safe_to_save"
    case themeEditorInvalidName = "theme.editor.error.invalid_name"
    case themeEditorInvalidRange = "theme.editor.error.invalid_range"
    case themeEditorInvalidContrast = "theme.editor.error.invalid_contrast"
    case themeEditorInvalidColor = "theme.editor.error.invalid_color"
    case themeEditorInvalidGradientStopCount = "theme.editor.error.invalid_gradient_stop_count"
    case themeEditorTextAction = "theme.editor.text_role.action"
    case themeEditorColorBackgroundSurface = "theme.editor.color_role.background_surface"
    case themeEditorUnsupportedVersion = "theme.editor.error.unsupported_version"
    case themeEditorWindowTitle = "theme.editor.window.title"
    case themeEditorPanelChooseImage = "theme.editor.panel.choose_image"
    case themeEditorPanelImportTheme = "theme.editor.panel.import_theme"
    case themeEditorPanelExportTheme = "theme.editor.panel.export_theme"
    case themeEditorResetToBuiltIn = "theme.editor.reset_to_builtin"
    case themeEditorMaterialUltraThin = "theme.editor.material.ultra_thin"
    case themeEditorMaterialThin = "theme.editor.material.thin"
    case themeEditorMaterialRegular = "theme.editor.material.regular"
    case themeEditorMaterialThick = "theme.editor.material.thick"
    case themeEditorMaterialUltraThick = "theme.editor.material.ultra_thick"
    case themeEditorColorBackground = "theme.editor.color.background"
    case themeEditorColorPrimaryText = "theme.editor.color.primary_text"
    case themeEditorColorSecondaryText = "theme.editor.color.secondary_text"
    case themeEditorColorAccent = "theme.editor.color.accent"
    case themeEditorColorHealthy = "theme.editor.color.healthy"
    case themeEditorColorWarning = "theme.editor.color.warning"
    case themeEditorColorCritical = "theme.editor.color.critical"
    case themeEditorColorStale = "theme.editor.color.stale"
    case themeEditorColorUnavailable = "theme.editor.color.unavailable"
    case themeEditorColorBorder = "theme.editor.color.border"
    case themeEditorColorFocusRing = "theme.editor.color.focus_ring"
    case themeEditorGeometryCornerRadius = "theme.editor.geometry.corner_radius"
    case themeEditorGeometryBorderWidth = "theme.editor.geometry.border_width"
    case themeEditorGeometryShadowRadius = "theme.editor.geometry.shadow_radius"
    case themeEditorGeometryMaterialOpacity = "theme.editor.geometry.material_opacity"
    case themeEditorGeometryDecorativeOpacity = "theme.editor.geometry.decorative_opacity"
    case themeEditorSolidColorPlaceholder = "theme.editor.placeholder.solid_color"
    case themeEditorGradientStopsPlaceholder = "theme.editor.placeholder.gradient_stops"
    case themeEditorColorHexPlaceholder = "theme.editor.placeholder.color_hex"
    case themeEditorDuplicateUnavailable = "theme.editor.operation.duplicate_unavailable"
    case themeEditorDuplicateFailed = "theme.editor.operation.duplicate_failed"
    case themeEditorImageUnsafe = "theme.editor.operation.image_unsafe"
    case themeEditorSaveSucceeded = "theme.editor.operation.save_succeeded"
    case themeEditorSaveApplied = "theme.editor.operation.save_applied"
    case themeEditorSavedNotApplied = "theme.editor.operation.saved_not_applied"
    case themeEditorSaveFailed = "theme.editor.operation.save_failed"
    case themeEditorResetSucceeded = "theme.editor.operation.reset_succeeded"
    case themeEditorResetFailed = "theme.editor.operation.reset_failed"
    case themeEditorImportLoaded = "theme.editor.operation.import_loaded"
    case themeEditorImportFailed = "theme.editor.operation.import_failed"
    case themeEditorExportSucceeded = "theme.editor.operation.export_succeeded"
    case themeEditorExportFailed = "theme.editor.operation.export_failed"
    case themeEditorBuiltInReadOnly = "theme.editor.builtin_read_only"
    case themeEditorPreviewAccessibilityLabel = "theme.editor.preview.accessibility_label"
    case themeEditorPreviewAccessibilityValue = "theme.editor.preview.accessibility_value"
    case activityGroupTitle = "activity.group.title"
    case activityColumnInput = "activity.column.input"
    case activityColumnOutput = "activity.column.output"
    case activityColumnTotal = "activity.column.total"
    case activityTodayUTC = "activity.today.utc"
    case activityMonthDerivedPartial = "activity.month.derived_partial"
    case activityCurrentMonthLocalSubtotal = "activity.month.local_subtotal"
    case activitySourceDisclosure = "activity.source.disclosure"
    case activityTokenCount = "activity.token_count"
    case activityTokenCountPartial = "activity.token_count.partial"
    case activityDateRange = "activity.date_range"
    case activityCoverageReported = "activity.coverage.reported"
    case activityCoveragePartial = "activity.coverage.partial"
    case activityCoverageUnknown = "activity.coverage.unknown"
    case activityPartialNotZero = "activity.partial.not_zero"
    case activityTotalOnlyAccessibilityRow =
        "activity.total_only.accessibility_row"
    case formatJustNow = "format.relative.just_now"
    case formatMinutesAgo = "format.relative.minutes_ago"
    case formatHoursAgo = "format.relative.hours_ago"
    case formatDaysAgo = "format.relative.days_ago"
    case statusLoadingToolTip = "status.loading.tooltip"
    case statusLoadingAccessibility = "status.loading.accessibility"
    case statusProvidersEmptyTitle = "status.providers.empty.title"
    case statusProvidersEmptyToolTip = "status.providers.empty.tooltip"
    case statusProvidersEmptyAccessibility = "status.providers.empty.accessibility"
    case statusProviderLine = "status.provider.line"
    case statusProviderNotConnected = "status.provider.not_connected"
    case statusProviderFailed = "status.provider.failed"
    case statusProviderWaitingSnapshot = "status.provider.waiting_snapshot"
    case statusProviderClaudeCLISignedIn =
        "status.provider.claude_cli_signed_in"
    case statusProviderClaudeCLINotSignedIn =
        "status.provider.claude_cli_not_signed_in"
    case statusProviderClaudeWaitingRelay =
        "status.provider.claude_waiting_relay"
    case statusProviderAppRunning = "status.provider.app_running"
    case statusProviderAppInstalled = "status.provider.app_installed"
    case statusProviderAppNotInstalled = "status.provider.app_not_installed"
    case statusProviderCommandAvailable = "status.provider.command_available"
    case statusProviderCommandUnavailable =
        "status.provider.command_unavailable"
    case statusProviderLocalAppOnly = "status.provider.local_app_only"
    case statusProviderLocalCLIOnly = "status.provider.local_cli_only"
    case statusProviderQuotaUnavailable = "status.provider.quota_unavailable"
    case statusProviderFreshDetail = "status.provider.fresh_detail"
    case statusProviderStaleDetail = "status.provider.stale_detail"
    case statusProviderMetricRemaining = "status.provider.metric.remaining"
    case statusProviderMetricRemainingReset = "status.provider.metric.remaining_reset"
    case statusProviderMetricUsed = "status.provider.metric.used"
    case statusProviderMetricUsedReset = "status.provider.metric.used_reset"
    case statusProviderWindowOrdinal = "status.provider.window_ordinal"
    case statusUnsupportedToolTip = "status.unsupported.tooltip"
    case statusUnsupportedAccessibility = "status.unsupported.accessibility"
    case statusManualUnavailableToolTip = "status.manual_unavailable.tooltip"
    case statusManualUnavailableAccessibility = "status.manual_unavailable.accessibility"
    case statusNoWindowsToolTip = "status.no_windows.tooltip"
    case statusNoWindowsAccessibility = "status.no_windows.accessibility"
    case statusCompactRemaining = "status.window.compact.remaining"
    case statusCompactUsed = "status.window.compact.used"
    case statusCompactFiveHours = "status.duration.compact.five_hours"
    case statusCompactWeek = "status.duration.compact.week"
    case statusCompactHours = "status.duration.compact.hours"
    case statusCompactMinutes = "status.duration.compact.minutes"
    case statusCompactWindow = "status.duration.compact.window"
    case statusCompactPair = "status.window.compact.pair"
    case statusDetailedFiveHours = "status.duration.detailed.five_hours"
    case statusDetailedWeek = "status.duration.detailed.week"
    case statusDetailedMinutes = "status.duration.detailed.minutes"
    case statusDetailedWindow = "status.duration.detailed.window"
    case statusDetailedRemaining = "status.window.detailed.remaining"
    case statusDetailedRemainingReset = "status.window.detailed.remaining_reset"
    case statusDetailedUsed = "status.window.detailed.used"
    case statusDetailedUsedReset = "status.window.detailed.used_reset"
    case statusDetailedPair = "status.window.detailed.pair"
    case statusSelectionManual = "status.selection.manual"
    case statusSelectionManualPartial = "status.selection.manual_partial"
    case statusSelectionPreferred = "status.selection.preferred"
    case statusSelectionFallback = "status.selection.fallback"
    case statusSelectionLegacy = "status.selection.legacy"
    case statusLoadedToolTip = "status.loaded.tooltip"
    case statusLoadedStaleToolTip = "status.loaded.stale.tooltip"
    case statusLoadedAccessibility = "status.loaded.accessibility"
    case statusLoadedStaleAccessibility = "status.loaded.stale.accessibility"
    case statusUnavailableUnauthenticated = "status.unavailable.unauthenticated"
    case statusUnavailableAuthMode = "status.unavailable.auth_mode"
    case statusUnavailableSchema = "status.unavailable.schema"
    case statusUnavailableTemporary = "status.unavailable.temporary"
    case statusUnavailableStale = "status.unavailable.stale"
    case statusUnavailableAccessibility = "status.unavailable.accessibility"
}

enum AppLocaleMapping {
    static func supportedLocale(
        for language: AppLanguage,
        systemLocale: Locale
    ) -> SupportedAppLocale {
        switch language {
        case .traditionalChinese:
            return .traditionalChinese
        case .simplifiedChinese:
            return .simplifiedChinese
        case .english:
            return .english
        case .japanese:
            return .japanese
        case .korean:
            return .korean
        case .spanish:
            return .spanish
        case .french:
            return .french
        case .german:
            return .german
        case .system:
            return supportedSystemLocale(systemLocale)
        }
    }

    private static func supportedSystemLocale(
        _ locale: Locale
    ) -> SupportedAppLocale {
        let identifier = locale.identifier
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()

        if identifier.hasPrefix("zh") {
            if identifier.contains("hans")
                || identifier.contains("-cn")
                || identifier.contains("-sg")
            {
                return .simplifiedChinese
            }
            return .traditionalChinese
        }
        if identifier.hasPrefix("ja") { return .japanese }
        if identifier.hasPrefix("ko") { return .korean }
        if identifier.hasPrefix("en") { return .english }
        if identifier.hasPrefix("es") { return .spanish }
        if identifier.hasPrefix("fr") { return .french }
        if identifier.hasPrefix("de") { return .german }
        return .english
    }
}

struct LocalizedTextProvider {
    typealias Lookup = (
        LocalizationCatalogKey,
        SupportedAppLocale
    ) -> String

    let locale: SupportedAppLocale
    private let lookup: Lookup

    init(
        locale: SupportedAppLocale,
        lookup: @escaping Lookup
    ) {
        self.locale = locale
        self.lookup = lookup
    }

    init(
        language: AppLanguage,
        systemLocale: Locale,
        bundle: Bundle = .main
    ) {
        let locale = AppLocaleMapping.supportedLocale(
            for: language,
            systemLocale: systemLocale
        )
        self.locale = locale
        lookup = { key, selectedLocale in
            let localizedBundle = Self.localizedBundle(
                for: selectedLocale,
                preferred: bundle
            )
            return localizedBundle.localizedString(
                forKey: key.rawValue,
                value: nil,
                table: "Localizable"
            )
        }
    }

    private static func localizedBundle(
        for locale: SupportedAppLocale,
        preferred bundle: Bundle
    ) -> Bundle {
        let markerBundle = Bundle(for: LocalizationBundleMarker.self)
        var candidates = [bundle, markerBundle]
        if let appBundle = containingAppBundle(from: markerBundle.bundleURL) {
            candidates.append(appBundle)
        }
        candidates.append(contentsOf: Bundle.allBundles)

        for candidate in candidates {
            guard let path = candidate.path(
                forResource: locale.rawValue,
                ofType: "lproj"
            ), let languageBundle = Bundle(path: path) else {
                continue
            }
            return languageBundle
        }
        return bundle
    }

    private static func containingAppBundle(from url: URL) -> Bundle? {
        var candidate = url.standardizedFileURL
        while candidate.path != "/" {
            if candidate.pathExtension == "app" {
                return Bundle(url: candidate)
            }
            candidate.deleteLastPathComponent()
        }
        return nil
    }

    func text(
        _ key: LocalizationCatalogKey,
        _ arguments: CVarArg...
    ) -> String {
        let format = lookup(key, locale)
        guard !arguments.isEmpty else { return format }
        return String(
            format: format,
            locale: locale.foundationLocale,
            arguments: arguments
        )
    }
}

@MainActor
@Observable
final class AppLocalizationRuntimeModel {
    var language: AppLanguage
    var systemLocale: Locale

    init(
        language: AppLanguage = .system,
        systemLocale: Locale = .current
    ) {
        self.language = language
        self.systemLocale = systemLocale
    }

    var text: LocalizedTextProvider {
        LocalizedTextProvider(
            language: language,
            systemLocale: systemLocale
        )
    }

    var locale: Locale {
        text.locale.foundationLocale
    }
}

struct LocalizedValuePresenter: Sendable {
    let locale: SupportedAppLocale

    func integer(_ value: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale.foundationLocale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    func percent(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale.foundationLocale
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 0
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: Double(value) / 100))
            ?? "\(value)%"
    }

    func durationMinutes(_ minutes: Int64) -> String {
        guard minutes >= 0 else { return "—" }
        let formatter = DateComponentsFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.calendar?.locale = locale.foundationLocale
        formatter.allowedUnits = [.weekOfMonth, .day, .hour, .minute]
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 2
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: TimeInterval(minutes) * 60) ?? "—"
    }
}

enum LocalizationPseudolocalizer {
    static func expand(_ source: String) -> String {
        var result = "［"
        var index = source.startIndex
        while index < source.endIndex {
            if source[index] == "%",
               let end = printfTokenEnd(in: source, from: index)
            {
                result += String(source[index..<end])
                index = end
                continue
            }

            let character = source[index]
            result += expanded(character)
            index = source.index(after: index)
        }
        return result + "］"
    }

    private static func printfTokenEnd(
        in source: String,
        from start: String.Index
    ) -> String.Index? {
        var index = source.index(after: start)
        while index < source.endIndex {
            let character = source[index]
            if character == "@" || character == "d" || character == "f" {
                return source.index(after: index)
            }
            if !(character.isNumber || character == "$" || character == "l"
                || character == "." || character == "-")
            {
                return nil
            }
            index = source.index(after: index)
        }
        return nil
    }

    private static func expanded(_ character: Character) -> String {
        switch character {
        case "a": return "áá"
        case "e": return "éé"
        case "i": return "íí"
        case "o": return "óó"
        case "u": return "úú"
        case "A": return "ÁÁ"
        case "E": return "ÉÉ"
        case "I": return "ÍÍ"
        case "O": return "ÓÓ"
        case "U": return "ÚÚ"
        case " ": return " · "
        default: return String(character)
        }
    }
}
