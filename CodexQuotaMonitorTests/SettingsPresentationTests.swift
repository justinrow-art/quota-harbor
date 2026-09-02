import Darwin
import Foundation
import XCTest
@testable import CodexQuotaMonitor

@MainActor
final class SettingsPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testAutomaticAndManualWindowPresentationNeverSilentlyExceedsTwo() throws {
        let fiveHour = identity(.primary, 300)
        let week = identity(.secondary, 10_080)
        let daily = identity(.primary, 1_440, bucket: "other")
        let catalog = try makeCatalog([
            (fiveHour, 20),
            (week, 40),
            (daily, 60),
        ])
        var settings = AppSettings.defaults
        settings.menuBarMode = .manual([fiveHour, week])

        let result = SettingsPresenter().makePresentation(
            settings: settings,
            rateState: .fresh(catalog, now),
            usageState: .unsupported,
            rateLastSuccessAt: now,
            usageLastSuccessAt: nil,
            isRefreshing: false,
            loginItemStatus: .notRegistered,
            theme: .placeholder,
            installedCodexVersion: "26.7.1",
            recoveryState: .healthy,
            appVersion: "1.0",
            now: now
        )

        XCTAssertFalse(result.general.menuBar.usesAutomaticSelection)
        XCTAssertEqual(result.general.menuBar.options.filter(\.isSelected).count, 2)
        XCTAssertFalse(result.general.menuBar.options.first { $0.identity == daily }!.isEnabled)
        XCTAssertEqual(
            result.general.menuBar.selectionLimitExplanation,
            "最多選擇兩個窗口；請先取消一個已選窗口。"
        )
    }

    func testRetiredManualWindowRemainsVisibleSelectedAndCancelable() throws {
        let live = identity(.primary, 300)
        let retired = identity(.secondary, 10_080)
        let catalog = try makeCatalog([(live, 20)])
        var settings = AppSettings.defaults
        settings.menuBarMode = .manual([retired, live])

        let result = SettingsPresenter().makePresentation(
            settings: settings,
            rateState: .fresh(catalog, now),
            usageState: .unsupported,
            rateLastSuccessAt: now,
            usageLastSuccessAt: nil,
            isRefreshing: false,
            loginItemStatus: .notRegistered,
            theme: .placeholder,
            installedCodexVersion: "26.7.1",
            recoveryState: .healthy,
            appVersion: "1.0",
            now: now
        )

        let option = try XCTUnwrap(
            result.general.menuBar.options.first { $0.identity == retired }
        )
        XCTAssertTrue(option.isSelected)
        XCTAssertTrue(option.isEnabled)
        XCTAssertFalse(option.isAvailable)
        XCTAssertTrue(option.title.contains("目前未提供"))
    }

    func testWindowBucketLabelRemovesControlCharactersAndIsBounded() throws {
        let unsafeBucket = "codex\n\t\r" + String(repeating: "x", count: 200)
        let unsafe = identity(.primary, 300, bucket: unsafeBucket)
        let catalog = try makeCatalog([(unsafe, 20)])

        let result = SettingsPresenter().makePresentation(
            settings: .defaults,
            rateState: .fresh(catalog, now),
            usageState: .unsupported,
            rateLastSuccessAt: now,
            usageLastSuccessAt: nil,
            isRefreshing: false,
            loginItemStatus: .notRegistered,
            theme: .placeholder,
            installedCodexVersion: "26.7.1",
            recoveryState: .healthy,
            appVersion: "1.0",
            now: now
        )

        let title = try XCTUnwrap(result.general.menuBar.options.first?.title)
        XCTAssertFalse(title.contains("\n"))
        XCTAssertFalse(title.contains("\t"))
        XCTAssertFalse(title.contains("\r"))
        XCTAssertLessThanOrEqual(title.count, 64)
    }

    func testGeneralPresentationKeepsPercentageSpaceLanguageAndSeparateLaneFreshness() {
        var settings = AppSettings.defaults
        settings.percentageMode = .used
        settings.spacePolicy = .allSpaces
        settings.language = .japanese

        let result = SettingsPresenter().makePresentation(
            settings: settings,
            rateState: .unsupported,
            usageState: .unavailable(.temporaryBackend),
            rateLastSuccessAt: now.addingTimeInterval(-60),
            usageLastSuccessAt: now.addingTimeInterval(-120),
            isRefreshing: true,
            loginItemStatus: .requiresApproval,
            theme: .placeholder,
            installedCodexVersion: "26.7.1",
            recoveryState: .healthy,
            appVersion: "1.0",
            now: now
        )

        XCTAssertEqual(result.general.percentageMode, .used)
        XCTAssertEqual(result.general.spacePolicy, .allSpaces)
        XCTAssertEqual(result.general.language, .japanese)
        XCTAssertEqual(result.general.loginItem.status, .requiresApproval)
        XCTAssertEqual(
            result.general.loginItem.detail,
            LocalizedTextProvider(
                language: .japanese,
                systemLocale: Locale(identifier: "ja_JP")
            ).text(.settingsLoginRequiresApproval)
        )
        XCTAssertEqual(result.advanced.capabilities.map(\.lane), [.rateLimits, .tokenActivity])
        XCTAssertEqual(result.advanced.capabilities.map(\.state), [.unsupported, .unavailable])
        XCTAssertNotEqual(result.general.freshness.rateText, result.general.freshness.usageText)
        XCTAssertTrue(result.general.freshness.isRefreshing)
        XCTAssertEqual(
            result.general.freshness.sourceText,
            LocalizedTextProvider(
                language: .japanese,
                systemLocale: Locale(identifier: "ja_JP")
            ).text(.settingsSourceLocalAppServer)
        )
    }

    func testDiagnosticsRejectsPathNewlineAndCredentialCanariesAndViewerEqualsCopyText() {
        let fixturePath = "/Users/" + "alice/Codex.app"
        let result = SettingsPresenter().makePresentation(
            settings: .defaults,
            rateState: .unavailable(.unauthenticated),
            usageState: .loading,
            rateLastSuccessAt: nil,
            usageLastSuccessAt: nil,
            isRefreshing: false,
            loginItemStatus: .notFound,
            theme: .placeholder,
            installedCodexVersion: fixturePath + "\ntoken=secret",
            recoveryState: .usingDefaults(.invalidData),
            appVersion: String(repeating: "9", count: 200),
            now: now
        )

        let text = result.advanced.diagnostics.renderedText
        XCTAssertEqual(text, result.advanced.diagnostics.copyText)
        XCTAssertFalse(text.contains("/Users/"))
        XCTAssertFalse(text.contains("alice"))
        XCTAssertFalse(text.contains("token"))
        XCTAssertFalse(text.contains("secret"))
        XCTAssertFalse(text.contains("\n/"))
        XCTAssertTrue(text.contains("未知"))
        XCTAssertEqual(result.general.loginItem.status, .notFound)
        XCTAssertTrue(result.general.loginItem.canToggle)
        XCTAssertEqual(
            result.general.loginItem.detail,
            LocalizedTextProvider(
                language: .traditionalChinese,
                systemLocale: Locale(identifier: "zh_Hant_TW")
            )
                .text(.settingsLoginDisabled)
        )
    }

    func testPlaceholderThemeMakesNoFalseSelectionOrUnwiredClaims() {
        XCTAssertNil(ThemeSettingsSnapshot.placeholder.selectedThemeID)
        XCTAssertFalse(ThemeSettingsSnapshot.placeholder.allowsSelection)
        XCTAssertFalse(ThemeSettingsSnapshot.placeholder.allowsColorScheme)
        XCTAssertFalse(ThemeSettingsSnapshot.placeholder.allowsDensity)
        XCTAssertFalse(
            ThemeSettingsSnapshot.placeholder.accessibilityFallbacksActive
        )
    }

    func testAppLevelAppearanceRemainsWritableWithPlaceholderThemeService() {
        let files = SettingsPresentationFileStore()
        let store = SettingsStore(
            fileURL: URL(fileURLWithPath: "/settings-task7-appearance.json"),
            fileStore: files,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        let viewModel = SettingsViewModel(
            settingsStore: store,
            quotaStore: QuotaStore(),
            loginItemService: FakeSettingsLoginItemService(
                statuses: [.notRegistered]
            ),
            themeService: PlaceholderThemeSettingsService(),
            installedVersionProvider: FixedInstalledVersionProvider(),
            diagnosticsCopier: FakeDiagnosticsCopier(),
            requestRefresh: {},
            appVersion: "1.0"
        )

        for colorScheme in AppearanceColorScheme.allCases {
            viewModel.setColorScheme(colorScheme)
            XCTAssertEqual(
                store.settings.appearance.colorScheme,
                colorScheme.rawValue
            )
            XCTAssertEqual(
                viewModel.presentation.appearance.colorScheme,
                colorScheme
            )
        }
        for density in AppearanceDensity.allCases {
            viewModel.setDensity(density)
            XCTAssertEqual(store.settings.appearance.density, density.rawValue)
            XCTAssertEqual(viewModel.presentation.appearance.density, density)
        }
        for profile in DisplayProfile.allCases {
            viewModel.setDisplayProfile(profile)
            XCTAssertEqual(
                store.settings.appearance.displayProfile,
                profile
            )
            XCTAssertEqual(
                viewModel.presentation.appearance.displayProfile,
                profile
            )
        }
        XCTAssertTrue(
            viewModel.presentation.appearance.allowsColorSchemeSelection
        )
        XCTAssertTrue(viewModel.presentation.appearance.allowsDensitySelection)
        XCTAssertTrue(
            viewModel.presentation.appearance
                .allowsDisplayProfileSelection
        )
        XCTAssertNil(
            viewModel.presentation.appearance.theme.selectedThemeID
        )
    }

    func testAccessibilityPreviewReflectsAppearanceAndFallbackState() {
        let presenter = AccessibilityPreviewPresenter()

        let fallback = presenter.makePresentation(
            colorScheme: .dark,
            density: .comfortable,
            increaseContrast: true,
            reduceTransparency: true
        )
        XCTAssertEqual(fallback.colorScheme, .dark)
        XCTAssertEqual(fallback.rowSpacing, 12)
        XCTAssertEqual(fallback.backgroundStyle, .opaque)
        XCTAssertTrue(fallback.usesHighContrastBorder)
        XCTAssertEqual(fallback.label, "5 小時額度")
        XCTAssertEqual(fallback.value, "剩餘 72%")
        XCTAssertTrue(fallback.fallbackDescription.contains("增加對比"))
        XCTAssertTrue(fallback.fallbackDescription.contains("降低透明度"))
        XCTAssertEqual(fallback.accessibilityLabel, "5 小時額度")
        XCTAssertTrue(fallback.accessibilityValue.contains("剩餘 72%"))

        let standard = presenter.makePresentation(
            colorScheme: .light,
            density: .compact,
            increaseContrast: false,
            reduceTransparency: false
        )
        XCTAssertEqual(standard.colorScheme, .light)
        XCTAssertEqual(standard.rowSpacing, 6)
        XCTAssertEqual(standard.backgroundStyle, .translucent)
        XCTAssertFalse(standard.usesHighContrastBorder)
        XCTAssertEqual(standard.fallbackDescription, "使用標準外觀")
    }

    func testSettingsCopyRoutesEveryVisibleControlThroughProvider() {
        let copy = SettingsCopy(text: keyEchoProvider())

        XCTAssertEqual(copy.tabGeneral, "settings.tab.general")
        XCTAssertEqual(copy.tabAppearance, "settings.tab.appearance")
        XCTAssertEqual(copy.tabAdvanced, "settings.tab.advanced")
        XCTAssertEqual(copy.groupMenuBar, "settings.group.menu_bar")
        XCTAssertEqual(copy.automaticWindows, "settings.menu_bar.automatic")
        XCTAssertEqual(copy.percentageDisplay, "settings.menu_bar.percentage_display")
        XCTAssertEqual(copy.percentageMode(.remaining), "settings.percentage.remaining")
        XCTAssertEqual(copy.percentageMode(.used), "settings.percentage.used")
        XCTAssertEqual(copy.groupRefreshSource, "settings.group.refresh_source")
        XCTAssertEqual(
            copy.refreshScheduleExplanation,
            "settings.refresh.schedule_explanation"
        )
        XCTAssertEqual(copy.refreshNow, "action.refresh_now")
        XCTAssertEqual(copy.groupDisplayLocation, "settings.group.display_location")
        XCTAssertEqual(copy.floatingCard, "settings.display.floating_card")
        XCTAssertEqual(copy.spacePolicy(.currentSpace), "settings.display.current_space")
        XCTAssertEqual(copy.spacePolicy(.allSpaces), "settings.display.all_spaces")
        XCTAssertEqual(copy.groupLogin, "settings.group.login")
        XCTAssertEqual(copy.openLoginItems, "action.open_login_items")
        XCTAssertEqual(copy.groupLanguage, "settings.group.language")
        XCTAssertEqual(copy.interfaceLanguage, "settings.language.interface")
        XCTAssertEqual(copy.languageName(.german), "language.de")
        XCTAssertEqual(copy.groupTheme, "settings.group.theme")
        XCTAssertEqual(copy.openThemeEditor, "settings.theme.open_editor")
        XCTAssertEqual(copy.groupAppearance, "settings.group.appearance_mode")
        XCTAssertEqual(copy.colorScheme, "settings.appearance.color_scheme")
        XCTAssertEqual(copy.colorSchemeName(.system), "settings.appearance.system")
        XCTAssertEqual(copy.colorSchemeName(.dark), "settings.appearance.dark")
        XCTAssertEqual(copy.density, "settings.appearance.density")
        XCTAssertEqual(copy.densityName(.compact), "settings.appearance.compact")
        XCTAssertEqual(
            copy.displayProfile,
            "settings.appearance.display_profile"
        )
        XCTAssertEqual(
            copy.displayProfileName(.compact),
            "settings.display_profile.compact"
        )
        XCTAssertEqual(
            copy.displayProfileName(.balanced),
            "settings.display_profile.balanced"
        )
        XCTAssertEqual(
            copy.displayProfileName(.full),
            "settings.display_profile.full"
        )
        XCTAssertEqual(copy.groupAccessibility, "settings.group.accessibility_preview")
        XCTAssertEqual(copy.groupCapabilities, "settings.group.capabilities")
        XCTAssertEqual(copy.installedCodexVersion, "settings.codex.installed_version")
        XCTAssertEqual(copy.groupDiagnostics, "settings.group.redacted_diagnostics")
        XCTAssertEqual(copy.copyDiagnostics, "action.copy_diagnostics")
        XCTAssertEqual(copy.groupResetThemeFiles, "settings.group.reset_theme_files")
        XCTAssertEqual(copy.resetSettings, "action.reset_settings")
        XCTAssertEqual(copy.resetTheme, "action.reset_theme")
        XCTAssertEqual(copy.importTheme, "action.import")
        XCTAssertEqual(copy.exportTheme, "action.export")
    }

    func testInjectedProviderDrivesSettingsPresenterAndPreservesCustomThemeName()
        throws
    {
        let text = keyEchoProvider()
        let live = identity(.primary, 300)
        let retired = identity(.secondary, 10_080)
        let catalog = try makeCatalog([(live, 20)])
        var settings = AppSettings.defaults
        settings.language = .japanese
        settings.menuBarMode = .manual([retired])
        let customName = "Ma couleur 自訂"
        let theme = ThemeSettingsSnapshot(
            choices: [
                ThemeChoice(
                    id: BuiltInThemeID.morandi.rawValue,
                    name: "Persisted built-in name",
                    isCustom: false
                ),
                ThemeChoice(
                    id: UUID().uuidString,
                    name: customName,
                    isCustom: true
                ),
            ],
            selectedThemeID: BuiltInThemeID.morandi.rawValue,
            selectedThemeDocument: BuiltInThemes.morandi.document
        )

        let result = SettingsPresenter().makePresentation(
            settings: settings,
            rateState: .fresh(catalog, now),
            usageState: .unsupported,
            rateLastSuccessAt: nil,
            usageLastSuccessAt: nil,
            isRefreshing: false,
            loginItemStatus: .notRegistered,
            theme: theme,
            installedCodexVersion: "26.7.1",
            recoveryState: .healthy,
            appVersion: "1.0",
            now: now,
            text: text
        )

        XCTAssertEqual(
            result.general.menuBar.options.first(where: { !$0.isAvailable })?
                .title,
            "settings.menu_bar.window_retired_title"
        )
        XCTAssertEqual(
            result.general.loginItem.title,
            "settings.group.login"
        )
        XCTAssertEqual(
            result.general.loginItem.detail,
            "settings.login.disabled"
        )
        XCTAssertEqual(
            result.general.freshness.rateText,
            "settings.freshness.never_succeeded"
        )
        XCTAssertEqual(
            result.advanced.capabilities.map(\.detail),
            ["common.state.available", "settings.capability.not_provided"]
        )
        XCTAssertEqual(
            result.appearance.theme.choices.map(\.name),
            ["theme.builtin.morandi", customName]
        )
        XCTAssertEqual(
            result.appearance.theme.selectedThemeDocument,
            BuiltInThemes.morandi.document
        )
        XCTAssertTrue(
            result.advanced.diagnostics.renderedText.contains(
                "settings.diagnostics.app_version"
            )
        )
        XCTAssertTrue(
            result.advanced.diagnostics.renderedText.contains(
                "settings.diagnostics.login_item"
            )
        )
    }

    func testLocalizedThemeSnapshotPreservesSelectedRasterData() {
        let rasterData = Data([0x89, 0x50, 0x4E, 0x47])
        let theme = ThemeSettingsSnapshot(
            choices: [
                ThemeChoice(
                    id: BuiltInThemeID.morandi.rawValue,
                    name: "Persisted built-in name",
                    isCustom: false
                ),
            ],
            selectedThemeID: BuiltInThemeID.morandi.rawValue,
            selectedThemeDocument: BuiltInThemes.morandi.document,
            selectedThemeRasterData: rasterData
        )

        let result = SettingsPresenter().makePresentation(
            settings: .defaults,
            rateState: .loading,
            usageState: .unsupported,
            rateLastSuccessAt: nil,
            usageLastSuccessAt: nil,
            isRefreshing: false,
            loginItemStatus: .notRegistered,
            theme: theme,
            installedCodexVersion: "26.7.1",
            recoveryState: .healthy,
            appVersion: "1.0",
            now: now,
            text: keyEchoProvider()
        )

        XCTAssertEqual(
            result.appearance.theme.selectedThemeRasterData,
            rasterData
        )
    }

    func testAccessibilityPreviewUsesWholeLocalizedWrappers() {
        let preview = AccessibilityPreviewPresenter(
            text: keyEchoProvider()
        ).makePresentation(
            colorScheme: .dark,
            density: .compact,
            increaseContrast: true,
            reduceTransparency: true
        )

        XCTAssertEqual(preview.label, "settings.accessibility.preview_label")
        XCTAssertEqual(preview.value, "quota.percent.remaining")
        XCTAssertEqual(
            preview.fallbackDescription,
            "settings.accessibility.both_fallbacks"
        )
        XCTAssertEqual(
            preview.accessibilityValue,
            "settings.accessibility.value"
        )
    }

    func testSettingsOperationErrorsFollowRuntimeLanguage() {
        let localizationModel = AppLocalizationRuntimeModel(
            language: .japanese,
            systemLocale: Locale(identifier: "en_US")
        )
        let theme = FakeThemeSettingsService()
        theme.shouldFailAppearanceUpdates = true
        let harness = SettingsHarness(
            theme: theme,
            localizationModel: localizationModel
        )

        harness.viewModel.setColorScheme(.dark)
        XCTAssertEqual(
            harness.viewModel.operationMessage,
            "外観設定を適用できませんでした。前回の有効な値を保持しました。"
        )

        localizationModel.language = .german
        XCTAssertEqual(
            harness.viewModel.operationMessage,
            "Die Darstellungseinstellungen konnten nicht angewendet werden; der letzte gültige Wert wurde beibehalten."
        )

        harness.viewModel.setDensity(.compact)
        XCTAssertEqual(
            harness.viewModel.operationMessage,
            "Die Darstellungseinstellungen konnten nicht angewendet werden; der letzte gültige Wert wurde beibehalten."
        )
    }

    func testInitialLoginItemPresentationIsLoadingWithoutFalseNotFoundTruth() {
        let harness = SettingsHarness()
        let loginItem = harness.viewModel.presentation.general.loginItem

        XCTAssertTrue(loginItem.isLoading)
        XCTAssertNil(loginItem.status)
        XCTAssertFalse(loginItem.canToggle)
        XCTAssertFalse(loginItem.canOpenSystemSettings)
        XCTAssertEqual(loginItem.detail, "正在讀取")
    }

    func testExplicitIntentsReadLatestStoreAndOnlyChangeTheirOwnedField() {
        let harness = SettingsHarness()
        var external = harness.store.settings
        external.language = .french
        XCTAssertSuccess(harness.store.replace(with: external))

        harness.viewModel.setPercentageMode(.used)

        XCTAssertEqual(harness.store.settings.percentageMode, .used)
        XCTAssertEqual(harness.store.settings.language, .french)
        XCTAssertEqual(harness.store.settings.spacePolicy, .currentSpace)
    }

    func testManualWindowIntentHonorsMaximumWithoutReplacingExistingChoice() throws {
        let harness = SettingsHarness()
        let one = identity(.primary, 300)
        let two = identity(.secondary, 10_080)
        let three = identity(.primary, 1_440, bucket: "other")

        harness.viewModel.setAutomaticMenuBar(false)
        harness.viewModel.toggleMenuBarWindow(one)
        harness.viewModel.toggleMenuBarWindow(two)
        harness.viewModel.toggleMenuBarWindow(three)

        XCTAssertEqual(harness.store.settings.menuBarMode, .manual([one, two]))
    }

    func testWindowSelectionIntentIsIdempotentForRepeatedAccessibilityValues() {
        let harness = SettingsHarness()
        let identity = identity(.primary, 300)
        harness.viewModel.setAutomaticMenuBar(false)

        harness.viewModel.setMenuBarWindow(identity, selected: true)
        harness.viewModel.setMenuBarWindow(identity, selected: true)
        XCTAssertEqual(harness.store.settings.menuBarMode, .manual([identity]))

        harness.viewModel.setMenuBarWindow(identity, selected: false)
        harness.viewModel.setMenuBarWindow(identity, selected: false)
        XCTAssertEqual(harness.store.settings.menuBarMode, .manual([]))
    }

    func testLoginItemEnableReadsLiveTruthBeforeAndAfterMutation() async {
        let login = FakeSettingsLoginItemService(
            statuses: [.notRegistered, .requiresApproval]
        )
        let harness = SettingsHarness(login: login)

        await harness.viewModel.setLaunchAtLoginEnabled(true)

        XCTAssertEqual(login.statusCount, 2)
        XCTAssertEqual(login.registerCount, 1)
        XCTAssertEqual(login.unregisterCount, 0)
        XCTAssertEqual(
            harness.viewModel.presentation.general.loginItem.status,
            .requiresApproval
        )
        XCTAssertFalse(harness.store.settings.launchAtLoginUserDisabled)
    }

    func testLoginItemNotFoundCanRegisterWhenSystemCreatesRecord() async {
        let login = FakeSettingsLoginItemService(statuses: [.notFound, .enabled])
        let harness = SettingsHarness(login: login)

        await harness.viewModel.setLaunchAtLoginEnabled(true)

        XCTAssertEqual(login.statusCount, 2)
        XCTAssertEqual(login.registerCount, 1)
        XCTAssertEqual(login.unregisterCount, 0)
        XCTAssertEqual(
            harness.viewModel.presentation.general.loginItem.status,
            .enabled
        )
        XCTAssertFalse(harness.store.settings.launchAtLoginUserDisabled)
    }

    func testLoginItemNotFoundAfterRegisterOffersRetryAndSystemRecovery() async {
        let login = FakeSettingsLoginItemService(
            statuses: [.notFound, .notFound]
        )
        let harness = SettingsHarness(login: login)

        await harness.viewModel.setLaunchAtLoginEnabled(true)

        XCTAssertEqual(login.statusCount, 2)
        XCTAssertEqual(login.registerCount, 1)
        XCTAssertEqual(
            harness.viewModel.presentation.general.loginItem.status,
            .notFound
        )
        XCTAssertTrue(
            harness.viewModel.presentation.general.loginItem.canToggle
        )
        XCTAssertTrue(
            harness.viewModel.presentation.general.loginItem
                .canOpenSystemSettings
        )
        XCTAssertEqual(
            harness.viewModel.operationMessage,
            "目前版本無法建立登入項目"
        )

        harness.viewModel.openLoginItemSystemSettings()
        XCTAssertEqual(harness.opener.openCount, 1)
    }

    func testLoginItemStillNotRegisteredAfterRegisterOffersSystemRecovery() async {
        let login = FakeSettingsLoginItemService(
            statuses: [.notRegistered, .notRegistered]
        )
        let harness = SettingsHarness(login: login)

        await harness.viewModel.setLaunchAtLoginEnabled(true)

        XCTAssertEqual(login.statusCount, 2)
        XCTAssertEqual(login.registerCount, 1)
        XCTAssertEqual(
            harness.viewModel.presentation.general.loginItem.status,
            .notRegistered
        )
        XCTAssertTrue(
            harness.viewModel.presentation.general.loginItem
                .canOpenSystemSettings
        )
        XCTAssertEqual(
            harness.viewModel.operationMessage,
            "目前版本無法建立登入項目"
        )

        harness.viewModel.openLoginItemSystemSettings()
        XCTAssertEqual(harness.opener.openCount, 1)
    }

    func testRegisterThrowUsesGenericWarningButRendersPostOperationLiveTruth() async {
        let login = FakeSettingsLoginItemService(
            statuses: [.notRegistered, .enabled],
            registerShouldThrow: true
        )
        let harness = SettingsHarness(login: login)

        await harness.viewModel.setLaunchAtLoginEnabled(true)

        XCTAssertEqual(
            harness.viewModel.presentation.general.loginItem.status,
            .enabled
        )
        XCTAssertEqual(
            harness.viewModel.operationMessage,
            "系統回報過程異常；已依目前狀態顯示。"
        )
    }

    func testUnregisterThrowUsesGenericWarningButRendersPostOperationLiveTruth() async {
        let login = FakeSettingsLoginItemService(
            statuses: [.enabled, .notRegistered],
            unregisterShouldThrow: true
        )
        let harness = SettingsHarness(login: login)

        await harness.viewModel.setLaunchAtLoginEnabled(false)

        XCTAssertEqual(
            harness.viewModel.presentation.general.loginItem.status,
            .notRegistered
        )
        XCTAssertTrue(harness.store.settings.launchAtLoginUserDisabled)
        XCTAssertEqual(
            harness.viewModel.operationMessage,
            "系統回報過程異常；已依目前狀態顯示。"
        )
    }

    func testRequiresApprovalRecoveryOnlyRunsFromExplicitIntent() async {
        let login = FakeSettingsLoginItemService(statuses: [.requiresApproval])
        let opener = FakeLoginItemSettingsOpener()
        let harness = SettingsHarness(login: login, opener: opener)
        await harness.viewModel.reloadLiveState()

        XCTAssertTrue(
            harness.viewModel.presentation.general.loginItem
                .canOpenSystemSettings
        )
        XCTAssertEqual(opener.openCount, 0)

        harness.viewModel.openLoginItemSystemSettings()

        XCTAssertEqual(opener.openCount, 1)
    }

    func testRegisterFailureOffersOnlyExplicitSystemSettingsRecovery() async {
        let login = FakeSettingsLoginItemService(
            statuses: [.notRegistered, .notRegistered],
            registerShouldThrow: true
        )
        let opener = FakeLoginItemSettingsOpener()
        let harness = SettingsHarness(login: login, opener: opener)

        await harness.viewModel.setLaunchAtLoginEnabled(true)

        XCTAssertTrue(
            harness.viewModel.presentation.general.loginItem
                .canOpenSystemSettings
        )
        XCTAssertEqual(opener.openCount, 0)
        harness.viewModel.openLoginItemSystemSettings()
        XCTAssertEqual(opener.openCount, 1)
    }

    func testUnregisterFailureOffersOnlyExplicitSystemSettingsRecovery() async {
        let login = FakeSettingsLoginItemService(
            statuses: [.enabled, .enabled],
            unregisterShouldThrow: true
        )
        let opener = FakeLoginItemSettingsOpener()
        let harness = SettingsHarness(login: login, opener: opener)

        await harness.viewModel.setLaunchAtLoginEnabled(false)

        XCTAssertTrue(
            harness.viewModel.presentation.general.loginItem
                .canOpenSystemSettings
        )
        XCTAssertEqual(opener.openCount, 0)
        harness.viewModel.openLoginItemSystemSettings()
        XCTAssertEqual(opener.openCount, 1)
    }

    func testLiveReloadPreservesOperationRecovery() async {
        let login = FakeSettingsLoginItemService(
            statuses: [
                .notRegistered,
                .notRegistered,
                .notRegistered,
            ],
            registerShouldThrow: true
        )
        let opener = FakeLoginItemSettingsOpener()
        let harness = SettingsHarness(login: login, opener: opener)

        await harness.viewModel.setLaunchAtLoginEnabled(true)
        XCTAssertTrue(
            harness.viewModel.presentation.general.loginItem
                .canOpenSystemSettings
        )
        XCTAssertEqual(opener.openCount, 0)

        await harness.viewModel.reloadLiveState()

        XCTAssertTrue(
            harness.viewModel.presentation.general.loginItem
                .canOpenSystemSettings
        )
        XCTAssertEqual(opener.openCount, 0)
        harness.viewModel.openLoginItemSystemSettings()
        XCTAssertEqual(opener.openCount, 1)
    }

    func testSettingsWriteFailureKeepsLastValidValueAndShowsFixedWarning() {
        let harness = SettingsHarness()
        harness.files.failWrites = true

        harness.viewModel.setLanguage(.german)

        XCTAssertEqual(harness.store.settings.language, .system)
        XCTAssertEqual(
            harness.viewModel.operationMessage,
            "無法儲存設定；已保留上次有效值。"
        )
    }

    func testProductionThemeServiceOwnsColorSchemePersistence() {
        let theme = FakeThemeSettingsService()
        let harness = SettingsHarness(theme: theme)

        harness.viewModel.setColorScheme(.dark)

        XCTAssertEqual(theme.colorSchemes, [.dark])
        XCTAssertEqual(
            harness.store.settings.appearance.colorScheme,
            AppearanceColorScheme.system.rawValue,
            "A runtime-aware service owns the atomic settings write"
        )
    }

    func testColorSchemeServiceFailureKeepsLastValidValue() {
        let theme = FakeThemeSettingsService()
        theme.shouldFailAppearanceUpdates = true
        let harness = SettingsHarness(theme: theme)

        harness.viewModel.setColorScheme(.dark)

        XCTAssertEqual(theme.colorSchemes, [.dark])
        XCTAssertEqual(
            harness.store.settings.appearance.colorScheme,
            AppearanceColorScheme.system.rawValue
        )
        XCTAssertEqual(
            harness.viewModel.operationMessage,
            "無法套用外觀設定；已保留上次有效值。"
        )
    }

    func testProductionThemeServiceOwnsDensityPersistence() {
        let theme = FakeThemeSettingsService()
        let harness = SettingsHarness(theme: theme)

        harness.viewModel.setDensity(.compact)

        XCTAssertEqual(theme.densities, [.compact])
        XCTAssertEqual(
            harness.store.settings.appearance.density,
            AppearanceDensity.system.rawValue,
            "A runtime-aware service owns the atomic settings write"
        )
    }

    func testDensityServiceFailureKeepsLastValidValue() {
        let theme = FakeThemeSettingsService()
        theme.shouldFailAppearanceUpdates = true
        let harness = SettingsHarness(theme: theme)

        harness.viewModel.setDensity(.compact)

        XCTAssertEqual(theme.densities, [.compact])
        XCTAssertEqual(
            harness.store.settings.appearance.density,
            AppearanceDensity.system.rawValue
        )
        XCTAssertEqual(
            harness.viewModel.operationMessage,
            "無法套用外觀設定；已保留上次有效值。"
        )
    }

    func testThemeActionsRouteOnlyThroughInjectedThemeService() {
        let theme = FakeThemeSettingsService()
        let harness = SettingsHarness(theme: theme)

        harness.viewModel.selectTheme("glass")
        harness.viewModel.importTheme()
        harness.viewModel.exportTheme()
        harness.viewModel.resetTheme()

        XCTAssertEqual(theme.selected, ["glass"])
        XCTAssertEqual(theme.importCount, 1)
        XCTAssertEqual(theme.exportCount, 1)
        XCTAssertEqual(theme.resetCount, 1)
    }

    func testThemeEditorIntentRoutesOnlyWhenCapabilityAllowsIt() {
        let allowedRecorder = ThemeEditorActionRecorder()
        let allowed = SettingsHarness(
            openThemeEditor: { allowedRecorder.count += 1 }
        )

        allowed.viewModel.openThemeEditor()

        XCTAssertEqual(allowedRecorder.count, 1)

        let unavailableTheme = FakeThemeSettingsService()
        unavailableTheme.allowsCustomEditor = false
        let unavailableRecorder = ThemeEditorActionRecorder()
        let unavailable = SettingsHarness(
            theme: unavailableTheme,
            openThemeEditor: { unavailableRecorder.count += 1 }
        )

        unavailable.viewModel.openThemeEditor()

        XCTAssertEqual(unavailableRecorder.count, 0)
    }

    func testSettingsRuntimeDependenciesRetainsThemeEditorPresenter() {
        var presenter: FakeThemeEditorPresenter? = FakeThemeEditorPresenter()
        let localizationModel = AppLocalizationRuntimeModel()
        weak var weakPresenter: FakeThemeEditorPresenter?
        weakPresenter = presenter
        var dependencies: SettingsRuntimeDependencies? =
            SettingsRuntimeDependencies(
                localizationModel: localizationModel,
                themeService: FakeThemeSettingsService(),
                themeEditorPresenter: presenter,
                installedVersionProvider: FixedInstalledVersionProvider(),
                diagnosticsCopier: FakeDiagnosticsCopier(),
                loginItemSettingsOpener: FakeLoginItemSettingsOpener()
            )

        presenter = nil

        XCTAssertNotNil(dependencies?.themeEditorPresenter)
        XCTAssertTrue(dependencies?.localizationModel === localizationModel)
        XCTAssertNotNil(weakPresenter)

        dependencies = nil
        XCTAssertNil(weakPresenter)
    }

    func testThemeEditorMutationRefreshesCachedThemeSnapshot() {
        let theme = FakeThemeSettingsService()
        let mutations = ThemeEditorMutationRelay()
        let harness = SettingsHarness(
            theme: theme,
            themeEditorMutations: mutations
        )
        let newChoice = ThemeChoice(
            id: UUID().uuidString,
            name: "New custom",
            isCustom: true
        )
        theme.extraChoices = [newChoice]

        mutations.notify()

        XCTAssertTrue(
            harness.viewModel.presentation.appearance.theme.choices
                .contains(newChoice)
        )
    }

    func testResetSettingsPreservesConsentAppearanceAndNeverTouchesLoginItem() {
        let login = FakeSettingsLoginItemService(statuses: [.enabled])
        let theme = FakeThemeSettingsService()
        let harness = SettingsHarness(login: login, theme: theme)
        var changed = harness.store.settings
        changed.onboardingCompleted = true
        changed.launchAtLoginUserDisabled = true
        changed.language = .german
        changed.percentageMode = .used
        changed.appearance = AppearanceSettings(
            themeID: "custom-safe",
            colorScheme: "dark",
            density: "compact",
            displayProfile: .full
        )
        XCTAssertSuccess(harness.store.replace(with: changed))

        harness.viewModel.resetSettings()

        XCTAssertTrue(harness.store.settings.onboardingCompleted)
        XCTAssertTrue(harness.store.settings.launchAtLoginUserDisabled)
        XCTAssertEqual(harness.store.settings.appearance, changed.appearance)
        XCTAssertEqual(harness.store.settings.language, .system)
        XCTAssertEqual(harness.store.settings.percentageMode, .remaining)
        XCTAssertEqual(theme.runtimeReloadCount, 1)
        XCTAssertEqual(login.registerCount, 0)
        XCTAssertEqual(login.unregisterCount, 0)
        XCTAssertEqual(theme.resetCount, 0)
    }

    func testResetThemeIsSeparateAndNeverTouchesSettingsOrLoginItem() {
        let login = FakeSettingsLoginItemService(statuses: [.enabled])
        let theme = FakeThemeSettingsService()
        let harness = SettingsHarness(login: login, theme: theme)
        let before = harness.store.settings

        harness.viewModel.resetTheme()

        XCTAssertEqual(theme.resetCount, 1)
        XCTAssertEqual(harness.store.settings, before)
        XCTAssertEqual(login.registerCount, 0)
        XCTAssertEqual(login.unregisterCount, 0)
    }

    func testRefreshAndDiagnosticsCopyAreExplicitActions() {
        let harness = SettingsHarness()
        let diagnostics = harness.viewModel.presentation.advanced.diagnostics.renderedText

        harness.viewModel.refreshNow()
        harness.viewModel.copyDiagnostics()

        XCTAssertEqual(harness.refreshCount, 1)
        XCTAssertEqual(harness.copier.values, [diagnostics])
    }

    func testInstalledVersionBoundaryReturnsOnlyDisplayString() async {
        let provider: any InstalledCodexVersionProviding =
            FixedInstalledVersionProvider()
        let readVersion: @Sendable () async -> String = {
            await provider.installedVersion()
        }
        let version = await readVersion()

        XCTAssertEqual(version, "26.7.1")
    }

    func testDiagnosticsSnapshotAcceptsOnlyClosedRedactedFields() {
        let snapshot = RedactedDiagnosticsSnapshot(
            appVersion: RedactedDisplayVersion("1.0"),
            codexVersion: RedactedDisplayVersion("26.7.1"),
            settingsSchemaVersion: 3,
            settingsHealth: .healthy,
            rateState: .fresh,
            usageState: .unsupported,
            rateLastSuccessAt: now,
            usageLastSuccessAt: nil,
            loginItemState: .enabled
        )
        let diagnostics = RedactedDiagnosticsPresentation(snapshot: snapshot)

        XCTAssertEqual(diagnostics.snapshot, snapshot)
        XCTAssertEqual(diagnostics.copyText, diagnostics.renderedText)
    }

    func testTokenActivityDisplaysInputOutputAndTotalWithoutInventingBreakdown()
        throws
    {
        let rows = (1...13).map {
            String(
                format: #"{"startDate":"2026-07-%02d","tokens":%lld}"#,
                $0,
                Int64($0)
            )
        }
        let activity = try tokenActivityPresentation(rows: rows)

        XCTAssertEqual(activity.groupTitle, "Token 活動（非帳務）")
        XCTAssertEqual(activity.inputTitle, "輸入")
        XCTAssertEqual(activity.outputTitle, "輸出")
        XCTAssertEqual(activity.totalTitle, "總數")
        XCTAssertEqual(activity.today.title, "今日（UTC）Token 活動")
        XCTAssertEqual(activity.today.input.state, .notReturned)
        XCTAssertEqual(activity.today.input.text, "未回傳")
        XCTAssertEqual(activity.today.output.state, .notReturned)
        XCTAssertEqual(activity.today.output.text, "未回傳")
        XCTAssertEqual(activity.today.total.state, .available)
        XCTAssertEqual(activity.today.total.text, "13 個 Token")
        XCTAssertEqual(activity.currentMonth.input.state, .notReturned)
        XCTAssertEqual(activity.currentMonth.output.state, .notReturned)
        XCTAssertEqual(activity.currentMonth.total.state, .available)
        XCTAssertEqual(activity.currentMonth.total.text, "91 個 Token")
        XCTAssertTrue(activity.currentMonth.title.contains("本機加總"))
        XCTAssertTrue(activity.currentMonth.title.contains("UTC"))
        XCTAssertTrue(activity.disclosure.contains("每日總數加總"))
        XCTAssertTrue(activity.disclosure.contains("未提供輸入與輸出"))
        XCTAssertTrue(activity.disclosure.contains("不是帳單或計費資料"))
        XCTAssertEqual(
            activity.missingDataNote,
            "帳戶活動目前未提供輸入／輸出 Token；缺少的資料不視為零。"
        )
    }

    func testTokenActivityMissingDataNoteNamesUnavailableBreakdownInEveryLanguage()
    {
        let expectations: [(AppLanguage, String)] = [
            (
                .traditionalChinese,
                "帳戶活動目前未提供輸入／輸出 Token；缺少的資料不視為零。"
            ),
            (
                .simplifiedChinese,
                "帐户活动目前未提供输入/输出 Token；缺少的数据不视为零。"
            ),
            (
                .english,
                "Account activity currently does not provide input/output tokens; missing data is not treated as zero."
            ),
            (
                .japanese,
                "アカウントアクティビティでは現在、入力／出力トークンは提供されません。欠損データはゼロとして扱いません。"
            ),
            (
                .korean,
                "계정 활동은 현재 입력/출력 토큰을 제공하지 않으며, 누락된 데이터는 0으로 처리하지 않습니다."
            ),
            (
                .spanish,
                "La actividad de la cuenta no proporciona actualmente tokens de entrada/salida; los datos que faltan no se consideran cero."
            ),
            (
                .french,
                "L’activité du compte ne fournit actuellement pas les jetons d’entrée/sortie ; les données manquantes ne sont pas traitées comme égales à zéro."
            ),
            (
                .german,
                "Die Kontoaktivität liefert derzeit keine Eingabe-/Ausgabe-Token; fehlende Daten werden nicht als 0 gewertet."
            ),
        ]

        for (language, expected) in expectations {
            let presentation = SettingsTokenActivityPresenter(
                text: LocalizedTextProvider(
                    language: language,
                    systemLocale: Locale(identifier: "en_US")
                )
            ).makePresentation(
                usageState: .unsupported,
                atUTC: activityNow
            )

            XCTAssertEqual(
                presentation.missingDataNote,
                expected,
                "\(language)"
            )
        }
    }

    func testTokenActivityPartialMonthNeverRendersAsZero() throws {
        let rows = (10...13).map {
            String(
                format: #"{"startDate":"2026-07-%02d","tokens":%lld}"#,
                $0,
                Int64($0)
            )
        }
        let activity = try tokenActivityPresentation(rows: rows)

        XCTAssertEqual(activity.currentMonth.total.state, .partial)
        XCTAssertEqual(activity.currentMonth.total.text, "46 個 Token（部分資料）")
        XCTAssertNotEqual(activity.currentMonth.total.text, "0")
        XCTAssertTrue(activity.coverageText.contains("部分"))
    }

    func testTokenActivityReturnedEmptyMonthRemainsNotReturned() throws {
        let activity = try tokenActivityPresentation(rows: [])

        XCTAssertEqual(activity.today.total.state, .notReturned)
        XCTAssertEqual(activity.today.total.text, "未回傳")
        XCTAssertEqual(activity.currentMonth.total.state, .notReturned)
        XCTAssertEqual(activity.currentMonth.total.text, "未回傳")
    }

    func testUnavailableTokenActivityKeepsTotalUnavailable() {
        let activity = tokenActivityPresentation(
            usageState: .unavailable(.temporaryBackend)
        )

        XCTAssertEqual(activity.today.total.state, .unavailable)
        XCTAssertEqual(activity.today.total.text, "無法取得")
        XCTAssertEqual(activity.currentMonth.total.state, .unavailable)
        XCTAssertEqual(activity.currentMonth.total.text, "無法取得")
        XCTAssertEqual(activity.today.input.state, .notReturned)
        XCTAssertEqual(activity.today.output.state, .notReturned)
    }

    func testAllProviderSelectionsKeepCodexAndOnlyAllowOptionalClaude()
        throws
    {
        for mask in 0..<(1 << ProviderID.allCases.count) {
            let files = SettingsPresentationFileStore()
            let store = SettingsStore(
                fileURL: URL(
                    fileURLWithPath: "/provider-selection-\(mask).json"
                ),
                fileStore: files
            )
            let requestedProviders = ProviderID.allCases.enumerated()
                .compactMap { index, providerID in
                    mask & (1 << index) == 0 ? nil : providerID
                }
            let expectedEnabledProviders: [ProviderID] =
                requestedProviders.contains(.claudeCode)
                    ? [.codex, .claudeCode]
                    : [.codex]
            var settings = store.settings
            settings.enabledProviders = requestedProviders
            try store.replace(with: settings).get()

            let reloaded = SettingsStore(
                fileURL: URL(
                    fileURLWithPath: "/provider-selection-\(mask).json"
                ),
                fileStore: files
            )
            let presentation = makeSettingsPresentation(
                settings: reloaded.settings
            ).general.providers
            XCTAssertEqual(
                reloaded.settings.enabledProviders,
                expectedEnabledProviders
            )
            XCTAssertEqual(
                presentation.rows.map(\.providerID),
                [.codex, .claudeCode],
                "mask \(mask)"
            )
            XCTAssertEqual(
                presentation.rows.filter(\.isEnabled).map(\.providerID),
                expectedEnabledProviders,
                "mask \(mask)"
            )
        }
    }

    func testRetainedPresenceProviderDoesNotAppearInPublicSettings()
        throws
    {
        var settings = AppSettings.defaults
        settings.enabledProviders = [.googleAntigravity]
        let snapshot = try XCTUnwrap(
            ProviderSnapshot(
                providerID: .googleAntigravity,
                metrics: [],
                capturedAt: now,
                runtimePresence: .application(
                    installed: true,
                    running: true
                )
            )
        )

        let row = try XCTUnwrap(
            makeSettingsPresentation(
                settings: settings,
                dashboardStates: [.googleAntigravity: .fresh(snapshot)]
            ).general.providers.rows.first
        )

        XCTAssertEqual(row.providerID, .codex)
    }

    func testRetainedProviderMetricsDoNotCreatePublicSettingsRows()
        throws
    {
        var settings = AppSettings.defaults
        settings.enabledProviders = [.googleAntigravity, .kimiCode]
        let googleMetric = try makeProviderMetric(
            providerID: .googleAntigravity,
            stableID: "unexpected-google-quota",
            remainingFraction: 0.4,
            durationMinutes: 300
        )
        let kimiMetric = try makeProviderMetric(
            providerID: .kimiCode,
            stableID: "unexpected-kimi-quota",
            remainingFraction: 0.6,
            durationMinutes: 300
        )
        let google = try XCTUnwrap(ProviderSnapshot(
            providerID: .googleAntigravity,
            metrics: [googleMetric],
            capturedAt: now,
            runtimePresence: .application(installed: true, running: true)
        ))
        let kimi = try XCTUnwrap(ProviderSnapshot(
            providerID: .kimiCode,
            metrics: [kimiMetric],
            capturedAt: now,
            runtimePresence: .command(available: true)
        ))
        let rows = makeSettingsPresentation(
            settings: settings,
            dashboardStates: [
                .googleAntigravity: .fresh(google),
                .kimiCode: .fresh(kimi),
            ]
        ).general.providers.rows

        XCTAssertEqual(rows.map(\.providerID), [.codex, .claudeCode])
    }

    func testRetainedPresenceStatesRemainHiddenFromPublicSettings()
        throws
    {
        var settings = AppSettings.defaults
        settings.enabledProviders = [.googleAntigravity, .kimiCode]
        let installed = try XCTUnwrap(
            ProviderSnapshot(
                providerID: .googleAntigravity,
                metrics: [],
                capturedAt: now,
                runtimePresence: .application(
                    installed: true,
                    running: false
                )
            )
        )
        let command = try XCTUnwrap(
            ProviderSnapshot(
                providerID: .kimiCode,
                metrics: [],
                capturedAt: now,
                runtimePresence: .command(available: true)
            )
        )
        let result = makeSettingsPresentation(
            settings: settings,
            dashboardStates: [
                .googleAntigravity: .fresh(installed),
                .kimiCode: .fresh(command),
            ]
        ).general.providers
        XCTAssertEqual(result.rows.map(\.providerID), [.codex, .claudeCode])
    }

    func testRetainedProviderDashboardStatesRemainHiddenFromSettings()
        throws
    {
        var settings = AppSettings.defaults
        settings.language = .english
        settings.enabledProviders = ProviderID.allCases
        let claudeAwaiting = try XCTUnwrap(ProviderSnapshot(
            providerID: .claudeCode,
            metrics: [],
            capturedAt: now
        ))
        let providers = makeSettingsPresentation(
            settings: settings,
            dashboardStates: [
                .googleAntigravity: .notConnected,
                .codex: .fresh(try XCTUnwrap(ProviderSnapshot(
                    providerID: .codex,
                    metrics: [],
                    capturedAt: now
                ))),
                .claudeCode: .fresh(claudeAwaiting),
                .kimiCode: .notConnected,
            ]
        ).general.providers

        let codex = try XCTUnwrap(
            providers.rows.first { $0.providerID == .codex }
        )
        XCTAssertEqual(
            providers.rows.map(\.providerID),
            [.codex, .claudeCode]
        )
        XCTAssertEqual(codex.quotaState, .loading)
        XCTAssertEqual(codex.quotaDetail, "Loading…")
    }

    func testCodexSettingsQuotaUsesCanonicalRateLaneInsteadOfAggregateState()
        throws
    {
        var settings = AppSettings.defaults
        settings.language = .english
        settings.enabledProviders = [.codex]
        let oldMetric = try makeProviderMetric(
            providerID: .codex,
            stableID: "old-aggregate",
            remainingFraction: 0.12,
            durationMinutes: 60
        )
        let oldSnapshot = try XCTUnwrap(ProviderSnapshot(
            providerID: .codex,
            metrics: [oldMetric],
            capturedAt: now.addingTimeInterval(-7_200)
        ))
        let canonicalIdentity = identity(.primary, 300)
        let catalog = try makeCatalog([(canonicalIdentity, 27)])

        let unsupported = makeSettingsPresentation(
            settings: settings,
            rateState: .unsupported,
            dashboardStates: [.codex: .fresh(oldSnapshot)]
        ).general.providers.rows[0]
        XCTAssertEqual(unsupported.quotaState, .unsupported)
        XCTAssertTrue(unsupported.metricOptions.isEmpty)

        let fresh = makeSettingsPresentation(
            settings: settings,
            rateState: .fresh(catalog, now),
            dashboardStates: [.codex: .stale(oldSnapshot)]
        ).general.providers.rows[0]
        XCTAssertEqual(fresh.quotaState, .available)
        XCTAssertTrue(fresh.metricOptions.isEmpty)
        XCTAssertNil(fresh.selectedMetricKey)
        XCTAssertEqual(fresh.lastUpdatedText, "just now")

        let freshWhileAggregateLoads = makeSettingsPresentation(
            settings: settings,
            rateState: .fresh(catalog, now),
            dashboardStates: [.codex: .loading]
        ).general.providers.rows[0]
        XCTAssertEqual(freshWhileAggregateLoads.quotaState, .available)
        XCTAssertTrue(freshWhileAggregateLoads.metricOptions.isEmpty)

        let otherWindow = try RateLimitWindow(
            identity: identity(.primary, 300, bucket: "other"),
            usedPercent: 12,
            resetsAt: nil
        )
        let emptyPreferredCatalog = RateLimitCatalog(
            rateLimitsByLimitId: [
                "codex": RateLimitBucket(bucketKey: "codex", windows: []),
                "other": RateLimitBucket(
                    bucketKey: "other",
                    windows: [otherWindow]
                ),
            ],
            legacyBucket: RateLimitBucket(
                bucketKey: RateLimitCatalog.legacyBucketKey,
                windows: []
            )
        )
        let emptyPreferred = makeSettingsPresentation(
            settings: settings,
            rateState: .fresh(emptyPreferredCatalog, now)
        ).general.providers.rows[0]
        XCTAssertEqual(emptyPreferred.quotaState, .unavailable)
        XCTAssertTrue(
            emptyPreferred.quotaDetail.contains("No quota windows are available")
        )

        let fullyEmpty = makeSettingsPresentation(
            settings: settings,
            rateState: .fresh(try makeCatalog([]), now)
        ).general.providers.rows[0]
        XCTAssertEqual(fullyEmpty.quotaState, .unavailable)
        XCTAssertTrue(
            fullyEmpty.quotaDetail.contains("No quota windows are available")
        )

        let unsupportedAuth = makeSettingsPresentation(
            settings: settings,
            rateState: .unavailable(.unsupportedAuthMode)
        ).general.providers.rows[0]
        XCTAssertEqual(unsupportedAuth.quotaState, .unsupported)
    }

    func testProviderSettingsMasksIdentityAndHidesNoOpCodexMetricPicker()
        throws
    {
        let shortMetric = try makeProviderMetric(
            providerID: .codex,
            stableID: "short",
            remainingFraction: 0.8,
            durationMinutes: 300
        )
        let preferredMetric = try makeProviderMetric(
            providerID: .codex,
            stableID: "preferred",
            remainingFraction: 0.6,
            durationMinutes: 10_080
        )
        let preference = try XCTUnwrap(
            PrimaryMetricPreference(
                providerID: .codex,
                metricKey: preferredMetric.metricKey
            )
        )
        let masked = try XCTUnwrap(
            MaskedAccountIdentity.maskingEmail("alice" + "@example.com")
        )
        let snapshot = try XCTUnwrap(
            ProviderSnapshot(
                providerID: .codex,
                metrics: [preferredMetric, shortMetric],
                capturedAt: now,
                accountSummary: ProviderAccountSummary(
                    maskedIdentity: masked
                )
            )
        )
        var settings = AppSettings.defaults
        settings.enabledProviders = [.codex, .claudeCode]
        settings.primaryMetricPreferences = [.codex: preference]

        let result = makeSettingsPresentation(
            settings: settings,
            dashboardStates: [.codex: .fresh(snapshot)]
        ).general.providers
        let row = try XCTUnwrap(
            result.rows.first { $0.providerID == .codex }
        )
        XCTAssertEqual(row.maskedIdentityText, masked.description)
        XCTAssertFalse(row.maskedIdentityText?.contains("alice") ?? true)
        XCTAssertFalse(row.maskedIdentityText?.contains("example.com") ?? true)
        XCTAssertTrue(row.metricOptions.isEmpty)
        XCTAssertNil(row.selectedMetricKey)
        XCTAssertEqual(
            result.preview,
            StatusItemPresenter().makePresentation(
                dashboardStates: [.codex: .fresh(snapshot)],
                codexCatalog: .loading,
                settings: settings,
                now: now,
                locale: Locale(identifier: "zh_TW")
            )
        )
    }

    func testEmptyProviderSelectionPresentsFixedCodexRecovery() {
        var settings = AppSettings.defaults
        settings.enabledProviders = []

        let providers = makeSettingsPresentation(
            settings: settings
        ).general.providers

        XCTAssertFalse(providers.showsEmptySelectionRecovery)
        XCTAssertEqual(
            providers.rows.map(\.providerID),
            [.codex, .claudeCode]
        )
        XCTAssertEqual(
            providers.rows.filter(\.isEnabled).map(\.providerID),
            [.codex]
        )
        XCTAssertFalse(providers.preview.menu.settingsTitle.isEmpty)
    }

    func testPublicProviderPresentationKeepsCodexAndOptionalClaudeOnly() {
        var settings = AppSettings.defaults
        settings.enabledProviders = ProviderID.allCases
        settings.statusItemDisplayMode = .primary
        settings.primaryStatusItemProvider = .claudeCode

        let result = makeSettingsPresentation(settings: settings)

        XCTAssertEqual(
            result.general.providers.rows.map(\.providerID),
            [.codex, .claudeCode]
        )
        XCTAssertEqual(
            result.general.providers.rows.map(\.isEnabled),
            [true, true]
        )
        XCTAssertFalse(
            result.general.providers.showsEmptySelectionRecovery
        )
        XCTAssertEqual(
            result.general.menuBar.primaryProviderOptions.map(\.providerID),
            [.codex, .claudeCode]
        )
        XCTAssertEqual(
            result.general.menuBar.selectedPrimaryProvider,
            .claudeCode
        )
        XCTAssertTrue(result.general.menuBar.showsPrimaryProviderPicker)
    }

    func testMenuBarDisplayPresentationOffersEnabledClaudeAsPrimary() {
        var settings = AppSettings.defaults
        settings.language = .english
        settings.enabledProviders = [.claudeCode, .codex]
        settings.statusItemDisplayMode = .primary
        settings.primaryStatusItemProvider = .kimiCode

        let menuBar = makeSettingsPresentation(
            settings: settings
        ).general.menuBar

        XCTAssertEqual(menuBar.statusItemDisplayMode, .primary)
        XCTAssertEqual(
            menuBar.primaryProviderOptions.map(\.providerID),
            [.codex, .claudeCode]
        )
        XCTAssertEqual(
            menuBar.primaryProviderOptions.map(\.name),
            ["Codex", "Claude Code"]
        )
        XCTAssertEqual(menuBar.selectedPrimaryProvider, .codex)
        XCTAssertTrue(menuBar.showsPrimaryProviderPicker)
    }

    func testPrimaryProviderPickerIsVisibleOnlyInPrimaryMode() {
        for mode in StatusItemDisplayMode.allCases {
            var settings = AppSettings.defaults
            settings.enabledProviders = [.codex, .claudeCode]
            settings.statusItemDisplayMode = mode

            let menuBar = makeSettingsPresentation(
                settings: settings
            ).general.menuBar

            XCTAssertEqual(
                menuBar.showsPrimaryProviderPicker,
                mode == .primary,
                "Unexpected primary-provider picker visibility for \(mode)"
            )
        }
    }

    func testCodexWindowControlsRemainAvailableAfterDisableAttempt() {
        var settings = AppSettings.defaults
        settings.enabledProviders = [.claudeCode, .kimiCode]

        XCTAssertTrue(
            makeSettingsPresentation(settings: settings).general.menuBar
                .showsCodexWindowControls
        )

        settings.enabledProviders.append(.codex)
        XCTAssertTrue(
            makeSettingsPresentation(settings: settings).general.menuBar
                .showsCodexWindowControls
        )
    }

    func testStatusItemDisplayIntentsPersistOnlyOwnedFields() {
        let harness = SettingsHarness()
        let original = harness.store.settings

        harness.viewModel.setStatusItemDisplayMode(.primary)
        harness.viewModel.setPrimaryStatusItemProvider(.claudeCode)
        harness.viewModel.setPrimaryStatusItemProvider(.kimiCode)

        XCTAssertEqual(
            harness.store.settings.statusItemDisplayMode,
            .primary
        )
        XCTAssertEqual(
            harness.store.settings.primaryStatusItemProvider,
            nil
        )
        XCTAssertEqual(
            harness.store.settings.enabledProviders,
            original.enabledProviders
        )
        XCTAssertEqual(
            harness.store.settings.menuBarMode,
            original.menuBarMode
        )
        XCTAssertEqual(harness.store.settings.appearance, original.appearance)
    }

    func testProviderSelectionAndOrderingIntentsPersistOnlyTheirOwnedFields() {
        let harness = SettingsHarness()
        let original = harness.store.settings

        harness.viewModel.setProviderEnabled(.codex, enabled: false)
        harness.viewModel.setProviderEnabled(.claudeCode, enabled: true)
        harness.viewModel.setProviderEnabled(.codex, enabled: true)
        harness.viewModel.moveProvider(.codex, direction: .up)
        harness.viewModel.setProviderEnabled(.claudeCode, enabled: false)
        harness.viewModel.setProviderEnabled(.claudeCode, enabled: true)

        XCTAssertEqual(
            harness.store.settings.enabledProviders,
            [.codex, .claudeCode]
        )
        XCTAssertEqual(
            harness.store.settings.menuBarMode,
            original.menuBarMode
        )
        XCTAssertEqual(
            harness.store.settings.appearance,
            original.appearance
        )
    }

    func testSettingsViewModelKeepsCodexAndOnlyTogglesClaude() {
        let harness = SettingsHarness()

        harness.viewModel.setProviderEnabled(.codex, enabled: false)
        harness.viewModel.setProviderEnabled(.googleAntigravity, enabled: true)
        harness.viewModel.setProviderEnabled(.claudeCode, enabled: true)
        harness.viewModel.setProviderEnabled(.kimiCode, enabled: true)

        XCTAssertEqual(
            harness.store.settings.enabledProviders,
            [.codex, .claudeCode]
        )
        XCTAssertEqual(
            harness.viewModel.presentation.general.providers.rows
                .map(\.providerID),
            [.codex, .claudeCode]
        )
    }

    func testProviderLinkIntentAcceptsOnlyClosedCatalogURL() throws {
        let linkOpener = FakeProviderExternalLinkOpener()
        let harness = SettingsHarness(providerLinkOpener: linkOpener)
        let allowed = try XCTUnwrap(
            harness.viewModel.presentation.general.providers.rows
                .first { $0.providerID == .codex }?.links.first
        )
        let forged = SettingsProviderLinkPresentation(
            kind: .help,
            title: "forged",
            url: URL(string: "https://evil.example/steal")!
        )

        harness.viewModel.openProviderLink(forged)
        harness.viewModel.openProviderLink(allowed)

        XCTAssertEqual(linkOpener.openedURLs, [allowed.url])
    }

    func testPrimaryMetricIntentAcceptsOnlyPresentedProviderMetric() throws {
        let dashboard = ProviderDashboardStore()
        let metric = try makeProviderMetric(
            providerID: .claudeCode,
            stableID: "five-hour",
            remainingFraction: 0.7,
            durationMinutes: 300
        )
        let generation = dashboard.activate(.claudeCode)
        XCTAssertTrue(
            dashboard.apply(
                .fresh(
                    try XCTUnwrap(
                        ProviderSnapshot(
                            providerID: .claudeCode,
                            metrics: [metric],
                            capturedAt: now
                        )
                    )
                ),
                for: generation
            )
        )
        let harness = SettingsHarness(providerDashboardStore: dashboard)
        harness.viewModel.setProviderEnabled(.claudeCode, enabled: true)
        let forged = try XCTUnwrap(
            ProviderMetricKey(
                providerID: .claudeCode,
                stableID: "not-presented"
            )
        )

        harness.viewModel.setPrimaryMetric(.claudeCode, metricKey: forged)
        XCTAssertNil(
            harness.store.settings.primaryMetricPreferences[.claudeCode]
        )

        harness.viewModel.setPrimaryMetric(
            .claudeCode,
            metricKey: metric.metricKey
        )
        XCTAssertEqual(
            harness.store.settings.primaryMetricPreferences[.claudeCode]?
                .metricKey,
            metric.metricKey
        )
    }

    func testClaudeRelayReloadIsReadOnlyAndSelectionNeverInstalls() async {
        let relay = FakeClaudeRelaySettingsService(state: .notInstalled)
        let harness = SettingsHarness(claudeRelayService: relay)

        harness.viewModel.setProviderEnabled(.claudeCode, enabled: true)
        await harness.viewModel.reloadLiveState()

        XCTAssertEqual(relay.inspectCount, 1)
        XCTAssertEqual(relay.installCount, 0)
        XCTAssertEqual(relay.removeCount, 0)
        XCTAssertEqual(
            harness.viewModel.presentation.general.providers.claudeRelay.state,
            .notInstalled
        )
        XCTAssertFalse(
            harness.viewModel.presentation.general.providers.claudeRelay
                .showsMaintenance
        )
    }

    func testClaudeRelayInstallRequestCanBeCancelledWithoutMutation() async {
        let relay = FakeClaudeRelaySettingsService(state: .notInstalled)
        let harness = SettingsHarness(claudeRelayService: relay)
        harness.viewModel.setProviderEnabled(.claudeCode, enabled: true)
        await harness.viewModel.reloadLiveState()

        harness.viewModel.requestClaudeRelayInstallation()
        XCTAssertEqual(
            harness.viewModel.presentation.general.providers.claudeRelay
                .pendingConfirmation,
            .install
        )

        harness.viewModel.cancelClaudeRelayChange()
        XCTAssertNil(
            harness.viewModel.presentation.general.providers.claudeRelay
                .pendingConfirmation
        )
        XCTAssertEqual(relay.installCount, 0)
        XCTAssertEqual(relay.removeCount, 0)
    }

    func testClaudeRelayInstallRequiresClaudeAndSeparateConfirmation() async {
        let relay = FakeClaudeRelaySettingsService(state: .notInstalled)
        let harness = SettingsHarness(claudeRelayService: relay)
        await harness.viewModel.reloadLiveState()

        harness.viewModel.requestClaudeRelayInstallation()
        XCTAssertNil(
            harness.viewModel.presentation.general.providers.claudeRelay
                .pendingConfirmation
        )

        harness.viewModel.setProviderEnabled(.claudeCode, enabled: true)
        harness.viewModel.requestClaudeRelayInstallation()
        await harness.viewModel.confirmClaudeRelayChange()

        XCTAssertEqual(relay.installCount, 1)
        XCTAssertEqual(relay.removeCount, 0)
        XCTAssertEqual(
            harness.viewModel.presentation.general.providers.claudeRelay.state,
            .installed
        )
    }

    func testDisablingClaudeNeverRemovesInstalledRelay() async {
        let relay = FakeClaudeRelaySettingsService(state: .installed)
        let harness = SettingsHarness(claudeRelayService: relay)
        harness.viewModel.setProviderEnabled(.claudeCode, enabled: true)
        await harness.viewModel.reloadLiveState()

        harness.viewModel.setProviderEnabled(.claudeCode, enabled: false)

        XCTAssertEqual(harness.store.settings.enabledProviders, [.codex])
        XCTAssertEqual(relay.installCount, 0)
        XCTAssertEqual(relay.removeCount, 0)
        XCTAssertEqual(
            harness.viewModel.presentation.general.providers.claudeRelay.state,
            .installed
        )
        XCTAssertTrue(
            harness.viewModel.presentation.general.providers.claudeRelay
                .showsMaintenance
        )
    }

    func testManualRecoveryCopyIsActionableInChineseAndEnglish() {
        let expected: [(AppLanguage, String)] = [
            (
                .traditionalChinese,
                "需要手動復原。請保留復原檔案與備份，且不要公開備份內容。App 不會自動覆寫 Claude 設定；請依支援文件的手動復原流程處理。"
            ),
            (
                .english,
                "Manual recovery is required. Keep the recovery files and backup, and do not share the backup contents. The app will not overwrite Claude settings automatically; follow the support documentation’s manual recovery procedure."
            ),
        ]

        for (language, guidance) in expected {
            let copy = SettingsCopy(
                text: LocalizedTextProvider(
                    language: language,
                    systemLocale: Locale(identifier: "zh_TW")
                )
            )

            XCTAssertEqual(
                copy.claudeRelayState(.manualRecovery),
                guidance,
                "\(language)"
            )
            XCTAssertNotEqual(
                copy.claudeRelayState(.installed),
                guidance,
                "\(language)"
            )
        }

        XCTAssertTrue(
            ClaudeRelaySettingsPresentation(
                state: .manualRecovery,
                pendingConfirmation: nil,
                isBusy: false
            ).showsMaintenance
        )
    }

    func testInvalidClaudeRelayStateShowsStaticMaintenanceOnly() async {
        let relay = FakeClaudeRelaySettingsService(state: .invalidSettings)
        let harness = SettingsHarness(claudeRelayService: relay)
        await harness.viewModel.reloadLiveState()

        let presentation =
            harness.viewModel.presentation.general.providers.claudeRelay
        XCTAssertEqual(presentation.state, .invalidSettings)
        XCTAssertTrue(presentation.showsMaintenance)
        XCTAssertNil(presentation.pendingConfirmation)

        harness.viewModel.requestClaudeRelayRemoval()
        XCTAssertNil(
            harness.viewModel.presentation.general.providers.claudeRelay
                .pendingConfirmation
        )
        XCTAssertEqual(relay.installCount, 0)
        XCTAssertEqual(relay.removeCount, 0)
    }

    func testInstalledClaudeRelayRemovalRequiresSeparateConfirmation() async {
        let relay = FakeClaudeRelaySettingsService(state: .installed)
        let harness = SettingsHarness(claudeRelayService: relay)
        await harness.viewModel.reloadLiveState()

        harness.viewModel.requestClaudeRelayRemoval()
        XCTAssertTrue(
            harness.viewModel.presentation.general.providers.claudeRelay
                .showsMaintenance
        )
        XCTAssertEqual(
            harness.viewModel.presentation.general.providers.claudeRelay
                .pendingConfirmation,
            .remove
        )
        harness.viewModel.cancelClaudeRelayChange()
        XCTAssertEqual(relay.removeCount, 0)

        harness.viewModel.requestClaudeRelayRemoval()
        await harness.viewModel.confirmClaudeRelayChange()
        XCTAssertEqual(relay.removeCount, 1)
        XCTAssertEqual(
            harness.viewModel.presentation.general.providers.claudeRelay.state,
            .notInstalled
        )
    }

    func testCodexLastUpdatedUsesLocalizedRelativeTimeInEveryLanguage()
        throws
    {
        let capturedAt = now.addingTimeInterval(-7_200)
        let catalog = try makeCatalog([(identity(.primary, 300), 20)])

        for language in AppLanguage.allCases {
            var settings = AppSettings.defaults
            settings.language = language
            let row = try XCTUnwrap(
                makeSettingsPresentation(
                    settings: settings,
                    rateState: .fresh(catalog, capturedAt)
                ).general.providers.rows.first
            )
            let expected = LocalizedTextProvider(
                language: language,
                systemLocale: Locale(identifier: "zh_TW")
            ).text(.formatHoursAgo, Int64(2))

            XCTAssertEqual(row.lastUpdatedText, expected, "\(language)")
            XCTAssertFalse(row.lastUpdatedText?.contains("T") ?? true)
        }
    }

    func testProductionClaudeRelayAdapterInspectIsReadOnlyAndRoundTrips()
        async throws
    {
        let fileManager = FileManager.default
        let root = try canonicalTemporaryDirectory()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let config = root.appendingPathComponent("claude", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(
            at: config,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: support,
            withIntermediateDirectories: true
        )
        let settingsURL = config.appendingPathComponent("settings.json")
        let original = Data(#"{"theme":"night"}"#.utf8)
        try original.write(to: settingsURL)
        let location = ClaudeStatusLineSettingsLocation(
            configDirectoryURL: config,
            settingsURL: settingsURL
        )
        let service = try ProductionClaudeRelaySettingsService(
            location: location,
            applicationSupportURL: support,
            executableURL: URL(
                fileURLWithPath:
                    "/Applications/Codex Monitor.app/Contents/MacOS/Codex Monitor"
            ),
            temporaryNameToken: { "task5" }
        )
        let metadata = support
            .appendingPathComponent("CodexQuotaMonitor", isDirectory: true)
            .appendingPathComponent(
                "ClaudeStatusLineSettings",
                isDirectory: true
            )

        let initialState = await service.inspect()
        XCTAssertEqual(initialState, .notInstalled)
        XCTAssertEqual(try Data(contentsOf: settingsURL), original)
        XCTAssertFalse(fileManager.fileExists(atPath: metadata.path))

        let installedState = await service.install()
        let inspectedInstalledState = await service.inspect()
        XCTAssertEqual(installedState, .installed)
        XCTAssertEqual(inspectedInstalledState, .installed)
        XCTAssertTrue(fileManager.fileExists(atPath: metadata.path))

        let removedState = await service.remove()
        XCTAssertEqual(removedState, .notInstalled)
        XCTAssertEqual(try Data(contentsOf: settingsURL), original)
        XCTAssertFalse(fileManager.fileExists(atPath: metadata.path))
    }

    func testProductionClaudeRelayColdInspectClassifiesDriftAsManualRecovery()
        async throws
    {
        let fileManager = FileManager.default
        let root = try canonicalTemporaryDirectory()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let config = root.appendingPathComponent("claude", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(
            at: config,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: support,
            withIntermediateDirectories: true
        )
        let settingsURL = config.appendingPathComponent("settings.json")
        let original = Data(#"{"theme":"night"}"#.utf8)
        try original.write(to: settingsURL)
        let location = ClaudeStatusLineSettingsLocation(
            configDirectoryURL: config,
            settingsURL: settingsURL
        )
        let executableURL = URL(
            fileURLWithPath:
                "/Applications/Codex Monitor.app/Contents/MacOS/Codex Monitor"
        )
        let installerService = try ProductionClaudeRelaySettingsService(
            location: location,
            applicationSupportURL: support,
            executableURL: executableURL,
            temporaryNameToken: { "install" }
        )
        let installedState = await installerService.install()
        XCTAssertEqual(installedState, .installed)

        let recoveryStore = try ClaudeStatusLineSettingsPOSIXStore(
            location: location,
            applicationSupportURL: support,
            temporaryNameToken: { "inspect-fixture" }
        )
        let installedSnapshot = try recoveryStore.readSnapshot()
        XCTAssertNotNil(installedSnapshot.manifest)
        XCTAssertNotNil(installedSnapshot.backup)

        let drifted = Data(
            #"{"theme":"changed-after-install","statusLine":{"type":"command","command":"custom"}}"#
                .utf8
        )
        try drifted.write(to: settingsURL)
        let restartedService = try ProductionClaudeRelaySettingsService(
            location: location,
            applicationSupportURL: support,
            executableURL: executableURL,
            temporaryNameToken: { "inspect" }
        )

        let state = await restartedService.inspect()

        XCTAssertEqual(state, .manualRecovery)
        XCTAssertEqual(try Data(contentsOf: settingsURL), drifted)
        let afterInspect = try recoveryStore.readSnapshot()
        XCTAssertEqual(afterInspect.manifest, installedSnapshot.manifest)
        XCTAssertEqual(afterInspect.backup, installedSnapshot.backup)
    }

    func testProductionClaudeRelayFactoryFailsClosedForUnsafeLocation() async {
        let service = ProductionClaudeRelaySettingsService.live(
            environment: ["CLAUDE_CONFIG_DIR": "relative/path"],
            homeDirectoryURL: URL(fileURLWithPath: "/tmp/home", isDirectory: true),
            applicationSupportURL: URL(
                fileURLWithPath: "/tmp/support",
                isDirectory: true
            ),
            executableURL: URL(fileURLWithPath: "/tmp/CodexQuotaMonitor")
        )

        let state = await service.inspect()
        XCTAssertEqual(state, .unavailable)
    }

    private func makeSettingsPresentation(
        settings: AppSettings,
        rateState: CapabilityState<RateLimitCatalog> = .loading,
        dashboardStates: [ProviderID: ProviderPresentationState] = [:]
    ) -> SettingsPresentation {
        SettingsPresenter().makePresentation(
            settings: settings,
            rateState: rateState,
            usageState: .loading,
            rateLastSuccessAt: nil,
            usageLastSuccessAt: nil,
            isRefreshing: false,
            loginItemStatus: .notRegistered,
            theme: .placeholder,
            installedCodexVersion: "",
            recoveryState: .healthy,
            appVersion: "1.0",
            now: now,
            dashboardStates: dashboardStates,
            systemLocale: Locale(identifier: "zh_TW")
        )
    }

    private func canonicalTemporaryDirectory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.path
        guard let pointer = path.withCString({ realpath($0, nil) }) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { free(pointer) }
        return URL(
            fileURLWithPath: String(cString: pointer),
            isDirectory: true
        )
    }

    private func makeProviderMetric(
        providerID: ProviderID,
        stableID: String,
        remainingFraction: Double,
        durationMinutes: Int64
    ) throws -> ProviderMetric {
        let key = try XCTUnwrap(
            ProviderMetricKey(
                providerID: providerID,
                stableID: stableID
            )
        )
        return try XCTUnwrap(
            ProviderMetric(
                providerID: providerID,
                metricKey: key,
                remainingFraction: remainingFraction,
                resetAt: nil,
                durationMinutes: durationMinutes
            )
        )
    }

    private func identity(
        _ slot: SourceSlot,
        _ duration: Int64,
        bucket: String = "codex"
    ) -> WindowIdentity {
        WindowIdentity(
            bucketKey: bucket,
            sourceSlot: slot,
            durationMinutes: duration
        )
    }

    private func makeCatalog(
        _ values: [(WindowIdentity, Int)]
    ) throws -> RateLimitCatalog {
        let groups = Dictionary(grouping: values, by: { $0.0.bucketKey })
        let buckets = try groups.mapValues { values in
            RateLimitBucket(
                bucketKey: values[0].0.bucketKey,
                windows: try values.map { identity, used in
                    try RateLimitWindow(
                        identity: identity,
                        usedPercent: used,
                        resetsAt: nil
                    )
                }
            )
        }
        return RateLimitCatalog(
            rateLimitsByLimitId: buckets,
            legacyBucket: RateLimitBucket(
                bucketKey: RateLimitCatalog.legacyBucketKey,
                windows: []
            )
        )
    }

    private func tokenActivityPresentation(
        rows: [String]
    ) throws -> SettingsTokenActivityPresentation {
        let json = #"{"summary":{},"dailyUsageBuckets":["#
            + rows.joined(separator: ",") + "]}"
        let response = try JSONDecoder().decode(
            GetAccountTokenUsageRawResponse.self,
            from: Data(json.utf8)
        )
        return tokenActivityPresentation(
            usageState: .fresh(TokenActivitySnapshot(rawResponse: response), activityNow)
        )
    }

    private func tokenActivityPresentation(
        usageState: CapabilityState<TokenActivitySnapshot>
    ) -> SettingsTokenActivityPresentation {
        var settings = AppSettings.defaults
        settings.language = .traditionalChinese
        return SettingsPresenter().makePresentation(
            settings: settings,
            rateState: .unsupported,
            usageState: usageState,
            rateLastSuccessAt: nil,
            usageLastSuccessAt: activityNow,
            isRefreshing: false,
            loginItemStatus: .notRegistered,
            theme: .placeholder,
            installedCodexVersion: "26.7.1",
            recoveryState: .healthy,
            appVersion: "1.0",
            now: activityNow
        ).advanced.tokenActivity
    }

    private var activityNow: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(
            from: DateComponents(year: 2026, month: 7, day: 13)
        )!
    }
}

@MainActor
final class SettingsWindowControllerTests: XCTestCase {
    func testWindowTitleTracksSharedLocalizationModelWithoutRecreatingWindow()
        async
    {
        let localizationModel = AppLocalizationRuntimeModel(
            language: .english,
            systemLocale: Locale(identifier: "en_US")
        )
        let harness = SettingsHarness(localizationModel: localizationModel)
        let window = FakeSettingsWindow()
        var factoryCount = 0
        let controller = SettingsWindowController(
            viewModel: harness.viewModel,
            localizationModel: localizationModel,
            windowFactory: { _ in
                factoryCount += 1
                return window
            }
        )

        controller.showSettings()
        XCTAssertEqual(
            window.titles.last,
            localizationModel.text.text(.appSettingsWindowTitle)
        )

        localizationModel.language = .japanese
        for _ in 0..<20 where window.titles.last
            != localizationModel.text.text(.appSettingsWindowTitle)
        {
            await Task.yield()
        }

        XCTAssertEqual(factoryCount, 1)
        XCTAssertEqual(
            window.titles.last,
            localizationModel.text.text(.appSettingsWindowTitle)
        )
    }

    func testLoginStatusPublishesBeforeSlowInstalledVersionFinishes() async {
        let files = SettingsPresentationFileStore()
        let store = SettingsStore(
            fileURL: URL(fileURLWithPath: "/settings-task7-status-first.json"),
            fileStore: files
        )
        let versionProvider = DelayedInstalledVersionProvider()
        let viewModel = SettingsViewModel(
            settingsStore: store,
            quotaStore: QuotaStore(),
            loginItemService: FakeSettingsLoginItemService(statuses: [.enabled]),
            themeService: FakeThemeSettingsService(),
            installedVersionProvider: versionProvider,
            diagnosticsCopier: FakeDiagnosticsCopier(),
            requestRefresh: {},
            appVersion: "1.0"
        )

        let reload = Task { await viewModel.reloadLiveState() }
        let versionReadStarted = await waitForVersionRead(in: versionProvider)

        XCTAssertTrue(versionReadStarted)
        XCTAssertEqual(
            viewModel.presentation.general.loginItem.status,
            .enabled
        )
        XCTAssertFalse(
            viewModel.presentation.general.loginItem.isLoading
        )

        await versionProvider.release()
        await reload.value
    }

    func testRepeatedShowUsesOneRetainedWindowAndReloadsLiveState() async {
        let harness = SettingsHarness()
        let window = FakeSettingsWindow()
        var factoryCount = 0
        let controller = SettingsWindowController(
            viewModel: harness.viewModel,
            windowFactory: { _ in
                factoryCount += 1
                return window
            }
        )

        for _ in 0..<10 {
            controller.showSettings()
        }
        let observedReload = await waitForLoginItemStatus(
            .notRegistered,
            in: harness.viewModel
        )
        XCTAssertTrue(observedReload)

        XCTAssertEqual(factoryCount, 1)
        XCTAssertEqual(window.showCount, 10)
        XCTAssertGreaterThanOrEqual(harness.login.statusCount, 1)
    }

    func testTerminationHidesRetainedWindowWithoutReleasingIt() {
        let harness = SettingsHarness()
        let window = FakeSettingsWindow()
        var factoryCount = 0
        let controller = SettingsWindowController(
            viewModel: harness.viewModel,
            windowFactory: { _ in
                factoryCount += 1
                return window
            }
        )
        controller.showSettings()

        controller.hideSettings()
        controller.showSettings()

        XCTAssertEqual(factoryCount, 1)
        XCTAssertEqual(window.hideCount, 1)
        XCTAssertEqual(window.showCount, 2)
    }

    func testHideInvalidatesAnInFlightLiveReload() async {
        let files = SettingsPresentationFileStore()
        let store = SettingsStore(
            fileURL: URL(fileURLWithPath: "/settings-task7-hide.json"),
            fileStore: files
        )
        let quotaStore = QuotaStore()
        let login = BlockingSettingsLoginItemService()
        let theme = FakeThemeSettingsService()
        let viewModel = SettingsViewModel(
            settingsStore: store,
            quotaStore: quotaStore,
            loginItemService: login,
            themeService: theme,
            installedVersionProvider: FixedInstalledVersionProvider(),
            diagnosticsCopier: FakeDiagnosticsCopier(),
            requestRefresh: {},
            appVersion: "1.0"
        )
        let window = FakeSettingsWindow()
        let controller = SettingsWindowController(
            viewModel: viewModel,
            windowFactory: { _ in window }
        )

        controller.showSettings()
        await waitForPendingCall(1, in: login)
        controller.hideSettings()
        await login.resolve(call: 1, with: .enabled)
        await Task.yield()

        XCTAssertEqual(
            viewModel.presentation.general.loginItem.status,
            nil
        )
        XCTAssertTrue(viewModel.presentation.general.loginItem.isLoading)
    }

    func testOlderReloadCannotOverwriteNewerLiveTruth() async {
        let files = SettingsPresentationFileStore()
        let store = SettingsStore(
            fileURL: URL(fileURLWithPath: "/settings-task7-race.json"),
            fileStore: files
        )
        let login = BlockingSettingsLoginItemService()
        let viewModel = SettingsViewModel(
            settingsStore: store,
            quotaStore: QuotaStore(),
            loginItemService: login,
            themeService: FakeThemeSettingsService(),
            installedVersionProvider: FixedInstalledVersionProvider(),
            diagnosticsCopier: FakeDiagnosticsCopier(),
            requestRefresh: {},
            appVersion: "1.0"
        )
        let controller = SettingsWindowController(
            viewModel: viewModel,
            windowFactory: { _ in FakeSettingsWindow() }
        )

        controller.showSettings()
        await waitForPendingCall(1, in: login)
        controller.showSettings()
        await waitForPendingCall(2, in: login)
        await login.resolve(call: 2, with: .enabled)
        let observedNewTruth = await waitForLoginItemStatus(
            .enabled,
            in: viewModel
        )
        await login.resolve(call: 1, with: .notRegistered)
        let keptNewTruth = await loginItemStatusRemains(
            .enabled,
            in: viewModel
        )
        controller.hideSettings()

        XCTAssertTrue(observedNewTruth)
        XCTAssertTrue(keptNewTruth)
        XCTAssertEqual(
            viewModel.presentation.general.loginItem.status,
            .enabled
        )
    }
}

@MainActor
final class AppDelegateLifetimeTests: XCTestCase {
    func testRunBoundaryRetainsOwnerWhileOperationExecutes() {
        weak var weakProbe: AppDelegateLifetimeProbe?
        var observedInsideOperation = false

        autoreleasepool {
            let probe = AppDelegateLifetimeProbe()
            weakProbe = probe
            AppDelegateLifetime.run(retaining: probe) {
                observedInsideOperation = weakProbe != nil
            }
        }

        XCTAssertTrue(observedInsideOperation)
        XCTAssertNil(weakProbe)
    }
}

@MainActor
private final class SettingsHarness {
    let files = SettingsPresentationFileStore()
    let store: SettingsStore
    let quotaStore = QuotaStore()
    let login: FakeSettingsLoginItemService
    let theme: FakeThemeSettingsService
    let copier = FakeDiagnosticsCopier()
    let opener: FakeLoginItemSettingsOpener
    let providerDashboardStore: ProviderDashboardStore
    let refreshRecorder = SettingsRefreshRecorder()
    var refreshCount: Int { refreshRecorder.count }
    let viewModel: SettingsViewModel

    init(
        login: FakeSettingsLoginItemService = FakeSettingsLoginItemService(
            statuses: [.notRegistered]
        ),
        theme: FakeThemeSettingsService = FakeThemeSettingsService(),
        opener: FakeLoginItemSettingsOpener = FakeLoginItemSettingsOpener(),
        providerDashboardStore: ProviderDashboardStore = ProviderDashboardStore(),
        providerLinkOpener: FakeProviderExternalLinkOpener = FakeProviderExternalLinkOpener(),
        claudeRelayService: FakeClaudeRelaySettingsService = FakeClaudeRelaySettingsService(
            state: .unavailable
        ),
        localizationModel: AppLocalizationRuntimeModel = .init(
            language: .traditionalChinese,
            systemLocale: Locale(identifier: "zh_TW")
        ),
        openThemeEditor: @escaping @MainActor () -> Void = {},
        themeEditorMutations: ThemeEditorMutationRelay? = nil
    ) {
        self.login = login
        self.theme = theme
        self.opener = opener
        self.providerDashboardStore = providerDashboardStore
        store = SettingsStore(
            fileURL: URL(fileURLWithPath: "/settings-task7.json"),
            fileStore: files,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        viewModel = SettingsViewModel(
            settingsStore: store,
            quotaStore: quotaStore,
            loginItemService: login,
            themeService: theme,
            installedVersionProvider: FixedInstalledVersionProvider(),
            diagnosticsCopier: copier,
            localizationModel: localizationModel,
            loginItemSettingsOpener: opener,
            providerDashboardStore: providerDashboardStore,
            providerLinkOpener: providerLinkOpener,
            claudeRelayService: claudeRelayService,
            requestRefresh: { [refreshRecorder] in
                refreshRecorder.count += 1
            },
            openThemeEditor: openThemeEditor,
            themeEditorMutations: themeEditorMutations,
            appVersion: "1.0",
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
    }
}

private func keyEchoProvider() -> LocalizedTextProvider {
    LocalizedTextProvider(locale: .english) { key, _ in
        key.rawValue
    }
}

@MainActor
private final class SettingsRefreshRecorder {
    var count = 0
}

private final class SettingsPresentationFileStore: SettingsFileStoring {
    var values: [URL: Data] = [:]
    var failWrites = false

    func read(from url: URL) throws -> Data? {
        values[url]
    }

    func write(
        _ data: Data,
        to url: URL,
        options: Data.WritingOptions
    ) throws {
        if failWrites {
            throw SettingsPresentationFileError.failed
        }
        values[url] = data
    }
}

private enum SettingsPresentationFileError: Error {
    case failed
}

private final class FakeSettingsLoginItemService: LoginItemServicing, @unchecked Sendable {
    private let statuses: [LoginItemStatus]
    private var index = 0
    private(set) var statusCount = 0
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    private let registerShouldThrow: Bool
    private let unregisterShouldThrow: Bool

    init(
        statuses: [LoginItemStatus],
        registerShouldThrow: Bool = false,
        unregisterShouldThrow: Bool = false
    ) {
        self.statuses = statuses
        self.registerShouldThrow = registerShouldThrow
        self.unregisterShouldThrow = unregisterShouldThrow
    }

    func status() async -> LoginItemStatus {
        statusCount += 1
        defer { index += 1 }
        return statuses[min(index, statuses.count - 1)]
    }

    func register() async throws {
        registerCount += 1
        if registerShouldThrow {
            throw FakeLoginItemError.operation
        }
    }

    func unregister() async throws {
        unregisterCount += 1
        if unregisterShouldThrow {
            throw FakeLoginItemError.operation
        }
    }
}

private enum FakeLoginItemError: Error {
    case operation
}

private actor BlockingSettingsLoginItemService: LoginItemServicing {
    private var nextCall = 1
    private var continuations: [
        Int: CheckedContinuation<LoginItemStatus, Never>
    ] = [:]

    func status() async -> LoginItemStatus {
        let call = nextCall
        nextCall += 1
        return await withCheckedContinuation { continuation in
            continuations[call] = continuation
        }
    }

    func register() async throws {}
    func unregister() async throws {}

    func hasPending(call: Int) -> Bool {
        continuations[call] != nil
    }

    func resolve(call: Int, with status: LoginItemStatus) {
        continuations.removeValue(forKey: call)?.resume(returning: status)
    }
}

private actor DelayedInstalledVersionProvider:
    InstalledCodexVersionProviding
{
    private var started = false
    private var released = false

    func installedVersion() async -> String {
        started = true
        while !released {
            await Task.yield()
        }
        return "26.7.1"
    }

    func hasStarted() -> Bool { started }

    func release() {
        released = true
    }
}

private func waitForVersionRead(
    in provider: DelayedInstalledVersionProvider
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))

    while clock.now < deadline {
        if await provider.hasStarted() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return false
}

private func waitForPendingCall(
    _ call: Int,
    in service: BlockingSettingsLoginItemService,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))

    while clock.now < deadline {
        if await service.hasPending(call: call) {
            return
        }
        try? await Task.sleep(for: .milliseconds(1))
    }
    XCTFail("Expected pending status call \(call)", file: file, line: line)
}

@MainActor
private func waitForLoginItemStatus(
    _ expected: LoginItemStatus,
    in viewModel: SettingsViewModel
) async -> Bool {
    for _ in 0..<200 {
        if viewModel.presentation.general.loginItem.status == expected {
            return true
        }
        await Task.yield()
    }
    return false
}

@MainActor
private func loginItemStatusRemains(
    _ expected: LoginItemStatus,
    in viewModel: SettingsViewModel
) async -> Bool {
    for _ in 0..<200 {
        await Task.yield()
        guard viewModel.presentation.general.loginItem.status == expected else {
            return false
        }
    }
    return true
}

@MainActor
private final class FakeThemeSettingsService:
    ThemeSettingsServicing,
    ThemeAppearanceSettingsServicing,
    SettingsRuntimeReloading
{
    private(set) var resetCount = 0
    private(set) var selected: [String] = []
    private(set) var importCount = 0
    private(set) var exportCount = 0
    private(set) var colorSchemes: [AppearanceColorScheme] = []
    private(set) var densities: [AppearanceDensity] = []
    private(set) var displayProfiles: [DisplayProfile] = []
    private(set) var runtimeReloadCount = 0
    var shouldFailAppearanceUpdates = false
    var allowsCustomEditor = true
    var extraChoices: [ThemeChoice] = []

    func snapshot() -> ThemeSettingsSnapshot {
        ThemeSettingsSnapshot(
            choices: ThemeSettingsSnapshot.placeholder.choices + extraChoices,
            selectedThemeID: "morandi",
            allowsSelection: true,
            allowsReset: true,
            allowsImport: true,
            allowsExport: true,
            allowsCustomEditor: allowsCustomEditor,
            allowsColorScheme: true,
            allowsDensity: true,
            accessibilityFallbacksActive: true
        )
    }

    func selectTheme(id: String) throws {
        selected.append(id)
    }

    func resetTheme() throws {
        resetCount += 1
    }

    func importTheme() throws {
        importCount += 1
    }

    func exportTheme() throws {
        exportCount += 1
    }

    func setColorScheme(_ colorScheme: AppearanceColorScheme) throws {
        colorSchemes.append(colorScheme)
        if shouldFailAppearanceUpdates {
            throw FakeThemeSettingsServiceError.appearanceUpdateFailed
        }
    }

    func setDensity(_ density: AppearanceDensity) throws {
        densities.append(density)
        if shouldFailAppearanceUpdates {
            throw FakeThemeSettingsServiceError.appearanceUpdateFailed
        }
    }

    func setDisplayProfile(_ displayProfile: DisplayProfile) throws {
        displayProfiles.append(displayProfile)
        if shouldFailAppearanceUpdates {
            throw FakeThemeSettingsServiceError.appearanceUpdateFailed
        }
    }

    func reloadRuntimeSettings() {
        runtimeReloadCount += 1
    }
}

private enum FakeThemeSettingsServiceError: Error {
    case appearanceUpdateFailed
}

@MainActor
private final class FakeLoginItemSettingsOpener: LoginItemSettingsOpening {
    private(set) var openCount = 0

    func open() {
        openCount += 1
    }
}

@MainActor
private final class FakeProviderExternalLinkOpener:
    ProviderExternalLinkOpening
{
    private(set) var openedURLs: [URL] = []

    func open(_ url: URL) {
        openedURLs.append(url)
    }
}

@MainActor
private final class FakeClaudeRelaySettingsService:
    ClaudeRelaySettingsServicing
{
    private(set) var state: ClaudeRelaySettingsState
    private(set) var inspectCount = 0
    private(set) var installCount = 0
    private(set) var removeCount = 0

    init(state: ClaudeRelaySettingsState) {
        self.state = state
    }

    func inspect() async -> ClaudeRelaySettingsState {
        inspectCount += 1
        return state
    }

    func install() async -> ClaudeRelaySettingsState {
        installCount += 1
        state = .installed
        return state
    }

    func remove() async -> ClaudeRelaySettingsState {
        removeCount += 1
        state = .notInstalled
        return state
    }
}

private struct FixedInstalledVersionProvider: InstalledCodexVersionProviding {
    func installedVersion() async -> String { "26.7.1" }
}

@MainActor
private final class FakeDiagnosticsCopier: DiagnosticsCopying {
    private(set) var values: [String] = []

    func copy(_ text: String) {
        values.append(text)
    }
}

@MainActor
private final class FakeSettingsWindow: SettingsWindowHandling {
    private(set) var showCount = 0
    private(set) var hideCount = 0
    private(set) var titles: [String] = []

    func show() { showCount += 1 }
    func hide() { hideCount += 1 }
    func updateTitle(_ title: String) { titles.append(title) }
}

@MainActor
private final class ThemeEditorActionRecorder {
    var count = 0
}

@MainActor
private final class FakeThemeEditorPresenter: ThemeEditorPresenting {
    private(set) var dismissCount = 0

    func show() {}

    func dismissForTermination() {
        dismissCount += 1
    }
}

private final class AppDelegateLifetimeProbe {}

private func XCTAssertSuccess(
    _ result: Result<Void, SettingsStoreError>,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    if case let .failure(error) = result {
        XCTFail("Expected success, got \(error)", file: file, line: line)
    }
}
