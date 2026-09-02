import Foundation
import XCTest
@testable import CodexQuotaMonitor

final class LocalizationCatalogTests: XCTestCase {
    private let requiredLocales: Set<String> = [
        "zh-Hant", "zh-Hans", "en", "ja", "ko", "es", "fr", "de"
    ]

    func testCatalogHasExactDeclaredStableKeyParityAndEightNonemptyLocales()
        throws
    {
        let strings = try catalogStrings()

        XCTAssertEqual(Set(strings.keys), Set(LocalizationCatalogKey.allCases.map(\.rawValue)))
        for (key, value) in strings {
            let entry = try XCTUnwrap(
                value as? [String: Any],
                "Invalid entry for \(key)"
            )
            let localizations = try XCTUnwrap(
                entry["localizations"] as? [String: Any],
                "Missing localizations for \(key)"
            )
            XCTAssertEqual(Set(localizations.keys), requiredLocales, key)
            for locale in requiredLocales {
                let localeEntry = try XCTUnwrap(
                    localizations[locale] as? [String: Any],
                    "Missing \(locale) for \(key)"
                )
                let stringUnit = try XCTUnwrap(
                    localeEntry["stringUnit"] as? [String: Any],
                    "Missing string unit for \(key)/\(locale)"
                )
                XCTAssertEqual(stringUnit["state"] as? String, "translated", key)
                let value = try XCTUnwrap(stringUnit["value"] as? String)
                XCTAssertFalse(
                    value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "Empty \(locale) value for \(key)"
                )
            }
        }
    }

    func testQuotaHarborVisibleBrandIsExactInEveryLocale() throws {
        let appNames = Dictionary(
            uniqueKeysWithValues: requiredLocales.map { ($0, "QuotaHarbor") }
        )
        XCTAssertEqual(try localizedValues(for: "app.name"), appNames)
        XCTAssertEqual(
            try localizedValues(for: "app.window.settings.title"),
            [
                "zh-Hant": "QuotaHarbor 設定",
                "zh-Hans": "QuotaHarbor 设置",
                "en": "QuotaHarbor Settings",
                "ja": "QuotaHarbor 設定",
                "ko": "QuotaHarbor 설정",
                "es": "Ajustes de QuotaHarbor",
                "fr": "Réglages de QuotaHarbor",
                "de": "QuotaHarbor-Einstellungen",
            ]
        )
        XCTAssertEqual(
            try localizedValues(for: "onboarding.title"),
            [
                "zh-Hant": "歡迎使用 QuotaHarbor",
                "zh-Hans": "欢迎使用 QuotaHarbor",
                "en": "Welcome to QuotaHarbor",
                "ja": "QuotaHarbor へようこそ",
                "ko": "QuotaHarbor에 오신 것을 환영합니다",
                "es": "Te damos la bienvenida a QuotaHarbor",
                "fr": "Bienvenue dans QuotaHarbor",
                "de": "Willkommen bei QuotaHarbor",
            ]
        )

        let quitTitles = try localizedValues(for: "action.quit_app")
            .mapValues { String(format: $0, "QuotaHarbor") }
        XCTAssertEqual(
            quitTitles,
            [
                "zh-Hant": "結束 QuotaHarbor",
                "zh-Hans": "退出 QuotaHarbor",
                "en": "Quit QuotaHarbor",
                "ja": "QuotaHarborを終了",
                "ko": "QuotaHarbor 종료",
                "es": "Salir de QuotaHarbor",
                "fr": "Quitter QuotaHarbor",
                "de": "QuotaHarbor beenden",
            ]
        )
        XCTAssertEqual(
            try localizedValues(for: "settings.diagnostics.app_version"),
            [
                "zh-Hant": "QuotaHarbor：%@",
                "zh-Hans": "QuotaHarbor：%@",
                "en": "QuotaHarbor: %@",
                "ja": "QuotaHarbor：%@",
                "ko": "QuotaHarbor: %@",
                "es": "QuotaHarbor: %@",
                "fr": "QuotaHarbor : %@",
                "de": "QuotaHarbor: %@",
            ]
        )
        XCTAssertEqual(
            try localizedValues(for: "theme.editor.window.title"),
            [
                "zh-Hant": "QuotaHarbor 主題編輯器",
                "zh-Hans": "QuotaHarbor 主题编辑器",
                "en": "QuotaHarbor Theme Editor",
                "ja": "QuotaHarbor テーマエディタ",
                "ko": "QuotaHarbor 테마 편집기",
                "es": "Editor de temas de QuotaHarbor",
                "fr": "Éditeur de thème de QuotaHarbor",
                "de": "Theme-Editor für QuotaHarbor",
            ]
        )
    }

    func testTrustValidationFailureHasEightLocalizedMessages() throws {
        let strings = try catalogStrings()
        let entry = try XCTUnwrap(
            strings[LocalizationCatalogKey.errorTrustValidationFailed.rawValue]
                as? [String: Any]
        )
        let localizations = try XCTUnwrap(
            entry["localizations"] as? [String: Any]
        )

        XCTAssertEqual(Set(localizations.keys), requiredLocales)
        for locale in requiredLocales {
            let localeEntry = try XCTUnwrap(
                localizations[locale] as? [String: Any]
            )
            let unit = try XCTUnwrap(
                localeEntry["stringUnit"] as? [String: Any]
            )
            let value = try XCTUnwrap(unit["value"] as? String)
            XCTAssertFalse(
                value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                locale
            )
        }
    }

    func testServerRejectedHasEightLocalizedActionableMessages() throws {
        let strings = try catalogStrings()
        let entry = try XCTUnwrap(
            strings[LocalizationCatalogKey.errorServerRejected.rawValue]
                as? [String: Any]
        )
        let localizations = try XCTUnwrap(
            entry["localizations"] as? [String: Any]
        )

        XCTAssertEqual(Set(localizations.keys), requiredLocales)
        for locale in requiredLocales {
            let localeEntry = try XCTUnwrap(
                localizations[locale] as? [String: Any]
            )
            let unit = try XCTUnwrap(
                localeEntry["stringUnit"] as? [String: Any]
            )
            let value = try XCTUnwrap(unit["value"] as? String)
            XCTAssertFalse(
                value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                locale
            )
        }
    }

    func testCardTokenAccessibilityRowHasEightLocalizedWholeSentences()
        throws
    {
        let strings = try catalogStrings()
        let entry = try XCTUnwrap(
            strings["card.token_activity.accessibility_row"]
                as? [String: Any]
        )
        let localizations = try XCTUnwrap(
            entry["localizations"] as? [String: Any]
        )

        XCTAssertEqual(Set(localizations.keys), requiredLocales)
        for locale in requiredLocales {
            let localeEntry = try XCTUnwrap(
                localizations[locale] as? [String: Any]
            )
            let unit = try XCTUnwrap(
                localeEntry["stringUnit"] as? [String: Any]
            )
            let value = try XCTUnwrap(unit["value"] as? String)
            XCTAssertEqual(printfArguments(in: value).count, 7, locale)
            XCTAssertFalse(value.contains(" 0"), locale)
        }
    }

    func testTotalOnlyTokenAccessibilityRowHasEightLocalizedWholeSentences()
        throws
    {
        let values = try localizedValues(
            for: "activity.total_only.accessibility_row"
        )
        let expected: [String: String] = [
            "zh-Hant": "%@。%@：%@。",
            "zh-Hans": "%@。%@：%@。",
            "en": "%@. %@: %@.",
            "ja": "%@。%@：%@。",
            "ko": "%@. %@: %@.",
            "es": "%@. %@: %@.",
            "fr": "%@. %@ : %@.",
            "de": "%@. %@: %@.",
        ]

        XCTAssertEqual(values, expected)
        for (locale, value) in values {
            XCTAssertEqual(printfArguments(in: value).count, 3, locale)
        }
    }

    func testRefreshScheduleExplanationIsExactInEveryLocale() throws {
        XCTAssertEqual(
            try localizedValues(for: "settings.refresh.schedule_explanation"),
            [
                "zh-Hant": "接收變更通知，並每 5 分鐘自動同步；也可手動重新整理。",
                "zh-Hans": "接收变更通知，并每 5 分钟自动同步；也可手动刷新。",
                "en": "Receives change notifications and syncs automatically every 5 minutes; you can also refresh manually.",
                "ja": "変更通知を受信し、5分ごとに自動同期します。手動で更新することもできます。",
                "ko": "변경 알림을 받고 5분마다 자동으로 동기화하며, 수동으로 새로 고칠 수도 있습니다.",
                "es": "Recibe notificaciones de cambios y se sincroniza automáticamente cada 5 minutos; también puedes actualizar manualmente.",
                "fr": "Reçoit les notifications de modification et se synchronise automatiquement toutes les 5 minutes ; vous pouvez aussi actualiser manuellement.",
                "de": "Empfängt Änderungsmitteilungen und synchronisiert automatisch alle 5 Minuten; eine manuelle Aktualisierung ist ebenfalls möglich.",
            ]
        )
    }

    func testTraditionalChineseFallbackAndBucketTermsAreExact() throws {
        let expected: [(key: String, value: String)] = [
            (
                "settings.accessibility.increase_contrast",
                "已啟用增加對比的替代顯示"
            ),
            (
                "settings.accessibility.reduce_transparency",
                "已啟用降低透明度的替代顯示"
            ),
            (
                "settings.accessibility.both_fallbacks",
                "已啟用增加對比與降低透明度的替代顯示"
            ),
            ("settings.bucket.unnamed", "未命名額度桶"),
            (
                "status.selection.fallback",
                "找不到 Codex 額度桶；依固定順序顯示 %@ 備援額度桶。"
            ),
        ]

        for (key, expectedValue) in expected {
            XCTAssertEqual(
                try localizedValues(for: key)["zh-Hant"],
                expectedValue,
                key
            )
        }
    }

    func testMenuBarDisplayCopyIsLocalizedInEveryExplicitLanguage() {
        for language in AppLanguage.allCases where language != .system {
            let copy = SettingsCopy(
                text: LocalizedTextProvider(
                    language: language,
                    systemLocale: Locale(identifier: "ar_SA")
                )
            )
            let labels = StatusItemDisplayMode.allCases.map {
                copy.statusItemDisplayModeName($0)
            }

            XCTAssertEqual(Set(labels).count, 3, "\(language)")
            XCTAssertTrue(
                labels.allSatisfy { !$0.isEmpty && !$0.contains("settings.") },
                "\(language): \(labels)"
            )
            XCTAssertTrue(
                copy.statusItemAllProvidersExplanation.count > 10,
                "\(language)"
            )
            XCTAssertTrue(copy.statusItemFullWarning.contains("macOS"))
            XCTAssertTrue(copy.statusItemPositionHelp.contains("Command"))
        }
    }

    func testFloatingCardCloseActionIsExactInEveryLocale() throws {
        XCTAssertEqual(
            try localizedValues(for: "action.hide_floating_card"),
            [
                "zh-Hant": "關閉浮動卡片",
                "zh-Hans": "关闭浮动卡片",
                "en": "Close Floating Card",
                "ja": "フローティングカードを閉じる",
                "ko": "플로팅 카드 닫기",
                "es": "Cerrar tarjeta flotante",
                "fr": "Fermer la carte flottante",
                "de": "Schwebende Karte schließen",
            ]
        )
    }

    func testClaudeRelayConsentDisclosesQuotaEligibilityInEveryLocale()
        throws
    {
        XCTAssertEqual(
            try localizedValues(
                for: "settings.claude_relay.confirm_install"
            ),
            [
                "zh-Hant": "額度欄位只適用 Claude.ai Pro／Max，且要等該工作階段完成第一次 API 回應；五小時／七天窗口可能各自缺席，其他帳號可能永遠不會顯示額度。確認後會先備份，再寫入 Claude Code 的 statusLine 設定。是否繼續？",
                "zh-Hans": "额度字段只适用于 Claude.ai Pro／Max，且要等该会话完成第一次 API 响应；五小时／七天窗口可能各自缺失，其他账号可能永远不会显示额度。确认后会先备份，再写入 Claude Code 的 statusLine 设置。是否继续？",
                "en": "Quota fields are available only to Claude.ai Pro/Max after that session’s first API response. Either the five-hour or seven-day window may be absent, and other accounts may never show quota. Confirming will back up, then write Claude Code’s statusLine setting. Continue?",
                "ja": "使用量フィールドは Claude.ai Pro／Max のみ対象で、そのセッションの最初の API 応答後に表示されます。5時間／7日間のどちらかがない場合があり、対象外のアカウントでは表示されないことがあります。確認するとバックアップ後に Claude Code の statusLine 設定を書き込みます。続けますか？",
                "ko": "할당량 필드는 Claude.ai Pro/Max에서만 해당 세션의 첫 API 응답 후 제공됩니다. 5시간/7일 창 중 하나가 없을 수 있으며 대상이 아닌 계정에는 할당량이 표시되지 않을 수 있습니다. 확인하면 백업 후 Claude Code statusLine 설정을 기록합니다. 계속할까요?",
                "es": "Los campos de cuota solo están disponibles para Claude.ai Pro/Max después de la primera respuesta de API de esa sesión. Puede faltar la ventana de 5 horas o de 7 días, y otras cuentas pueden no mostrar cuota nunca. Al confirmar se hará una copia y se escribirá statusLine de Claude Code. ¿Continuar?",
                "fr": "Les champs de quota sont réservés à Claude.ai Pro/Max après la première réponse API de la session. La fenêtre de 5 heures ou de 7 jours peut manquer, et les autres comptes peuvent ne jamais afficher de quota. La confirmation sauvegardera puis écrira le réglage statusLine de Claude Code. Continuer ?",
                "de": "Kontingentfelder sind nur für Claude.ai Pro/Max nach der ersten API-Antwort der Sitzung verfügbar. Das 5-Stunden- oder 7-Tage-Fenster kann fehlen; bei anderen Konten wird möglicherweise nie ein Kontingent angezeigt. Nach der Bestätigung wird Claude Codes statusLine gesichert und geschrieben. Fortfahren?",
            ]
        )
    }

    func testCardAuthenticationRecoveryCopyIsActionableInEveryLocale() throws {
        XCTAssertEqual(
            try localizedValues(for: "error.codex.authentication_required"),
            [
                "zh-Hant": "請先登入 Codex，完成後再重新整理。",
                "zh-Hans": "请先登录 Codex，完成后再刷新。",
                "en": "Sign in to Codex, then refresh.",
                "ja": "Codex にサインインしてから更新してください。",
                "ko": "Codex에 로그인한 다음 새로 고치세요.",
                "es": "Inicia sesión en Codex y después actualiza.",
                "fr": "Connectez-vous à Codex, puis actualisez.",
                "de": "Melden Sie sich bei Codex an und aktualisieren Sie anschließend.",
            ]
        )
        XCTAssertEqual(
            try localizedValues(for: "error.codex.auth_mode_unsupported"),
            [
                "zh-Hant": "此 Codex 登入方式不提供額度；請在 Codex 切換登入方式後再重新整理。",
                "zh-Hans": "此 Codex 登录方式不提供额度；请在 Codex 切换登录方式后再刷新。",
                "en": "This Codex sign-in mode does not provide quota; switch sign-in modes in Codex, then refresh.",
                "ja": "この Codex サインイン方式では使用量を取得できません。Codex でサインイン方式を切り替えてから更新してください。",
                "ko": "이 Codex 로그인 방식은 할당량을 제공하지 않습니다. Codex에서 로그인 방식을 바꾼 다음 새로 고치세요.",
                "es": "Este método de inicio de sesión de Codex no proporciona cuota; cambia el método en Codex y después actualiza.",
                "fr": "Ce mode de connexion Codex ne fournit pas le quota ; changez de mode dans Codex, puis actualisez.",
                "de": "Diese Codex-Anmeldeart liefert kein Kontingent; wechseln Sie die Anmeldeart in Codex und aktualisieren Sie anschließend.",
            ]
        )
    }

    func testParameterizedSentencesRemainWholeAndPreservePlaceholders()
        throws
    {
        let strings = try catalogStrings()
        let expectedPlaceholders: [LocalizationCatalogKey: [String]] = [
            .actionQuitApp: ["@"],
            .cardWindowTitle: ["@", "@"],
            .cardUpdatedAt: ["@"],
            .cardStaleUpdatedAt: ["@"],
            .cardTokenActivityAccessibilityRow: [
                "@", "@", "@", "@", "@", "@", "@",
            ],
            .quotaRemainingPercent: ["lld"],
            .quotaUsedPercent: ["lld"],
            .quotaResetAt: ["@"],
            .quotaResetIn: ["@"],
            .quotaWindowAccessibilityValue: ["@", "lld"],
            .quotaWindowAccessibilityUsedValue: ["@", "lld"],
            .orbAccessibilityStaleValue: ["@"],
            .orbAccessibilityMinimumRemaining: ["lld"],
            .settingsWindowTitle: ["@", "@", "@"],
            .settingsWindowRetiredTitle: ["@"],
            .settingsMinutes: ["lld"],
            .settingsFreshnessNeverSucceeded: ["@", "@"],
            .settingsFreshnessLastSucceeded: ["@", "@", "@"],
            .settingsAccessibilityValue: ["@", "@"],
            .settingsDiagnosticsAppVersion: ["@"],
            .settingsDiagnosticsCodexVersion: ["@"],
            .settingsDiagnosticsSchemaVersion: ["lld"],
            .settingsDiagnosticsSettingsHealth: ["@"],
            .settingsDiagnosticsRateState: ["@"],
            .settingsDiagnosticsUsageState: ["@"],
            .settingsDiagnosticsRateLastSuccess: ["@"],
            .settingsDiagnosticsUsageLastSuccess: ["@"],
            .settingsDiagnosticsLoginItem: ["@"],
            .formatMinutesAgo: ["lld"],
            .formatHoursAgo: ["lld"],
            .formatDaysAgo: ["lld"],
            .activityTokenCount: ["@"],
            .activityTokenCountPartial: ["@"],
            .activityDateRange: ["@", "@"],
            .activityTotalOnlyAccessibilityRow: ["@", "@", "@"],
            .themeEditorDuplicateDefaultName: ["@"],
            .themeEditorInvalidContrast: ["@", "@"],
            .themeEditorInvalidRange: ["@", "@", "@"],
            .themeEditorInvalidColor: ["@", "@"],
            .themeEditorInvalidGradientStopCount: ["@", "lld"],
            .themeEditorPreviewAccessibilityLabel: ["@", "@"],
            .themeEditorPreviewAccessibilityValue: ["@", "@"],
            .statusCompactRemaining: ["@", "lld"],
            .statusCompactUsed: ["@", "lld"],
            .statusCompactHours: ["lld"],
            .statusCompactMinutes: ["lld"],
            .statusCompactPair: ["@", "@"],
            .statusDetailedMinutes: ["lld"],
            .statusDetailedRemaining: ["@", "@", "@", "lld", "lld"],
            .statusDetailedRemainingReset: ["@", "@", "@", "lld", "lld", "@"],
            .statusDetailedUsed: ["@", "@", "@", "lld"],
            .statusDetailedUsedReset: ["@", "@", "@", "lld", "@"],
            .statusDetailedPair: ["@", "@"],
            .statusSelectionPreferred: ["@"],
            .statusSelectionFallback: ["@"],
            .statusLoadedToolTip: ["@", "@"],
            .statusLoadedStaleToolTip: ["@", "@"],
            .statusLoadedAccessibility: ["@", "@"],
            .statusLoadedStaleAccessibility: ["@", "@"],
            .statusUnavailableAccessibility: ["@"],
            .statusProviderLine: ["@", "@"],
            .statusProviderFreshDetail: ["@"],
            .statusProviderStaleDetail: ["@"],
            .statusProviderMetricRemaining: ["@", "lld"],
            .statusProviderMetricRemainingReset: ["@", "lld", "@"],
            .statusProviderMetricUsed: ["@", "lld"],
            .statusProviderMetricUsedReset: ["@", "lld", "@"],
            .statusProviderWindowOrdinal: ["lld"],
        ]

        let parameterizedCatalogKeys = Set(try strings.compactMap { key, rawEntry in
            let entry = try XCTUnwrap(rawEntry as? [String: Any])
            let localizations = try XCTUnwrap(
                entry["localizations"] as? [String: Any]
            )
            let hasPlaceholder = try localizations.values.contains { rawLocale in
                let locale = try XCTUnwrap(rawLocale as? [String: Any])
                let unit = try XCTUnwrap(locale["stringUnit"] as? [String: Any])
                let value = try XCTUnwrap(unit["value"] as? String)
                return !printfArguments(in: value).isEmpty
            }
            return hasPlaceholder ? key : nil
        })
        XCTAssertEqual(
            parameterizedCatalogKeys,
            Set(expectedPlaceholders.keys.map(\.rawValue))
        )

        for (key, placeholders) in expectedPlaceholders {
            let entry = try XCTUnwrap(strings[key.rawValue] as? [String: Any])
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
            for locale in requiredLocales {
                let localeEntry = try XCTUnwrap(localizations[locale] as? [String: Any])
                let stringUnit = try XCTUnwrap(localeEntry["stringUnit"] as? [String: Any])
                let value = try XCTUnwrap(stringUnit["value"] as? String)
                XCTAssertEqual(
                    printfArguments(in: value),
                    placeholders.enumerated().map {
                        PrintfArgument(index: $0.offset + 1, type: $0.element)
                    },
                    "\(key.rawValue)/\(locale): \(value)"
                )
            }
        }
    }

    func testThemeEditorCatalogContractUsesStableKeys() {
        let cases: [LocalizationCatalogKey] = [
            .themeEditorWindowTitle,
            .themeEditorPanelChooseImage,
            .themeEditorPanelImportTheme,
            .themeEditorPanelExportTheme,
            .themeEditorResetToBuiltIn,
            .themeEditorMaterialUltraThin,
            .themeEditorMaterialThin,
            .themeEditorMaterialRegular,
            .themeEditorMaterialThick,
            .themeEditorMaterialUltraThick,
            .themeEditorColorBackground,
            .themeEditorColorPrimaryText,
            .themeEditorColorSecondaryText,
            .themeEditorColorAccent,
            .themeEditorColorHealthy,
            .themeEditorColorWarning,
            .themeEditorColorCritical,
            .themeEditorColorStale,
            .themeEditorColorUnavailable,
            .themeEditorColorBorder,
            .themeEditorColorFocusRing,
            .themeEditorTextAction,
            .themeEditorColorBackgroundSurface,
            .themeEditorGeometryCornerRadius,
            .themeEditorGeometryBorderWidth,
            .themeEditorGeometryShadowRadius,
            .themeEditorGeometryMaterialOpacity,
            .themeEditorGeometryDecorativeOpacity,
            .themeEditorSolidColorPlaceholder,
            .themeEditorGradientStopsPlaceholder,
            .themeEditorColorHexPlaceholder,
            .themeEditorDuplicateUnavailable,
            .themeEditorDuplicateFailed,
            .themeEditorImageUnsafe,
            .themeEditorSaveSucceeded,
            .themeEditorSaveApplied,
            .themeEditorSavedNotApplied,
            .themeEditorSaveFailed,
            .themeEditorResetSucceeded,
            .themeEditorResetFailed,
            .themeEditorImportLoaded,
            .themeEditorImportFailed,
            .themeEditorExportSucceeded,
            .themeEditorExportFailed,
            .themeEditorBuiltInReadOnly,
            .themeEditorInvalidGradientStopCount,
            .themeEditorPreviewAccessibilityLabel,
            .themeEditorPreviewAccessibilityValue,
        ]

        XCTAssertEqual(Set(cases.map(\.rawValue)).count, cases.count)
    }

    private struct PrintfArgument: Equatable {
        let index: Int
        let type: String
    }

    private func printfArguments(in value: String) -> [PrintfArgument] {
        let pattern = #"%(?!%)(?:(\d+)\$)?(lld|@)"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(value.startIndex..., in: value)
        var nextUnpositionedIndex = 1
        let arguments = regex.matches(in: value, range: range).map { match in
            let positionalRange = match.range(at: 1)
            let index: Int
            if positionalRange.location == NSNotFound {
                index = nextUnpositionedIndex
                nextUnpositionedIndex += 1
            } else {
                index = Int((value as NSString).substring(with: positionalRange))!
            }
            return PrintfArgument(
                index: index,
                type: (value as NSString).substring(with: match.range(at: 2))
            )
        }
        return arguments.sorted {
            if $0.index != $1.index { return $0.index < $1.index }
            return $0.type < $1.type
        }
    }

    func testUTCActivityKeysCarryNonBillingTranslatorWarnings() throws {
        let strings = try catalogStrings()
        for key in [
            LocalizationCatalogKey.activityTodayUTC,
            .activityMonthDerivedPartial,
            .activityCurrentMonthLocalSubtotal,
            .activitySourceDisclosure,
        ] {
            let entry = try XCTUnwrap(strings[key.rawValue] as? [String: Any])
            let comment = try XCTUnwrap(entry["comment"] as? String)
            XCTAssertTrue(comment.contains("UTC"), key.rawValue)
            XCTAssertTrue(comment.lowercased().contains("billing"), key.rawValue)
            XCTAssertTrue(comment.lowercased().contains("activity"), key.rawValue)
        }

        let disclosure = try XCTUnwrap(
            strings[LocalizationCatalogKey.activitySourceDisclosure.rawValue]
                as? [String: Any]
        )
        let disclosureComment = try XCTUnwrap(disclosure["comment"] as? String)
            .lowercased()
        XCTAssertTrue(disclosureComment.contains("daily totals"))
        XCTAssertTrue(disclosureComment.contains("input/output"))
    }

    func testCheckedInGlossaryCoversRequiredTermsAndLocales() throws {
        let glossary = try String(contentsOf: glossaryURL(), encoding: .utf8)
        for term in [
            "quota window", "used", "remaining", "reset", "stale",
            "unsupported", "token activity", "derived", "partial",
            "not returned",
        ] {
            XCTAssertTrue(glossary.lowercased().contains(term), term)
        }
        for locale in requiredLocales {
            XCTAssertTrue(glossary.contains(locale), locale)
        }
        XCTAssertTrue(glossary.contains("不是帳務或計費資料"))
    }

    func testExplicitLanguageAndSystemLocaleMappingIsDeterministic() {
        let mappings: [(AppLanguage, String)] = [
            (.traditionalChinese, "zh-Hant"),
            (.simplifiedChinese, "zh-Hans"),
            (.english, "en"),
            (.japanese, "ja"),
            (.korean, "ko"),
            (.spanish, "es"),
            (.french, "fr"),
            (.german, "de"),
        ]
        for (language, expected) in mappings {
            XCTAssertEqual(
                AppLocaleMapping.supportedLocale(
                    for: language,
                    systemLocale: Locale(identifier: "ar-SA")
                ).rawValue,
                expected
            )
        }

        XCTAssertEqual(
            AppLocaleMapping.supportedLocale(
                for: .system,
                systemLocale: Locale(identifier: "zh_TW")
            ),
            .traditionalChinese
        )
        XCTAssertEqual(
            AppLocaleMapping.supportedLocale(
                for: .system,
                systemLocale: Locale(identifier: "zh-Hans-SG")
            ),
            .simplifiedChinese
        )
        XCTAssertEqual(
            AppLocaleMapping.supportedLocale(
                for: .system,
                systemLocale: Locale(identifier: "fr-CA")
            ),
            .french
        )
        XCTAssertEqual(
            AppLocaleMapping.supportedLocale(
                for: .system,
                systemLocale: Locale(identifier: "ar-SA")
            ),
            .english
        )
    }

    func testSystemLanguageMapsEverySupportedLanguageFamily() {
        let mappings: [(String, SupportedAppLocale)] = [
            ("zh_TW", .traditionalChinese),
            ("zh-Hans-SG", .simplifiedChinese),
            ("en_US", .english),
            ("ja_JP", .japanese),
            ("ko_KR", .korean),
            ("es_ES", .spanish),
            ("fr_FR", .french),
            ("de_DE", .german),
            ("ar_SA", .english),
        ]

        for (identifier, expected) in mappings {
            XCTAssertEqual(
                AppLocaleMapping.supportedLocale(
                    for: .system,
                    systemLocale: Locale(identifier: identifier)
                ),
                expected,
                identifier
            )
        }
    }

    func testOnboardingCopyExplainsChatGPTPrerequisiteAndContextClick() {
        let traditionalChinese = OnboardingCopy(
            text: LocalizedTextProvider(
                language: .traditionalChinese,
                systemLocale: Locale(identifier: "zh_TW")
            )
        )
        XCTAssertTrue(
            traditionalChinese.residencyExplanation.contains("ChatGPT")
        )
        XCTAssertTrue(traditionalChinese.quitExplanation.contains("右鍵"))

        let english = OnboardingCopy(
            text: LocalizedTextProvider(
                language: .english,
                systemLocale: Locale(identifier: "en_US")
            )
        )
        XCTAssertTrue(
            english.residencyExplanation.localizedCaseInsensitiveContains(
                "ChatGPT"
            )
        )
        XCTAssertTrue(
            english.quitExplanation.localizedCaseInsensitiveContains(
                "right-click"
            )
        )
    }

    @MainActor
    func testSystemLanguageRuntimeCanRefreshItsLocaleWithoutChangingIdentity() {
        let model = AppLocalizationRuntimeModel(
            language: .system,
            systemLocale: Locale(identifier: "en_US")
        )
        let identity = ObjectIdentifier(model)

        XCTAssertEqual(model.locale.identifier, "en")
        model.systemLocale = Locale(identifier: "de_DE")

        XCTAssertEqual(ObjectIdentifier(model), identity)
        XCTAssertEqual(model.locale.identifier, "de")
        XCTAssertEqual(model.text.text(.settingsTabGeneral), "Allgemein")
    }

    func testLocaleAwareNumberPercentAndDurationFormatting() {
        let english = LocalizedValuePresenter(locale: .english)
        let german = LocalizedValuePresenter(locale: .german)
        let traditionalChinese = LocalizedValuePresenter(
            locale: .traditionalChinese
        )

        XCTAssertEqual(english.integer(12_345), "12,345")
        XCTAssertEqual(german.integer(12_345), "12.345")
        XCTAssertEqual(english.percent(72), "72%")
        XCTAssertEqual(german.percent(72), "72 %")
        XCTAssertEqual(traditionalChinese.durationMinutes(300), "5小時")
        XCTAssertEqual(english.durationMinutes(10_080), "1 week")
        XCTAssertEqual(german.durationMinutes(90), "1 Stunde und 30 Minuten")
    }

    func testTextProviderFormatsAWholeLocalizedSentenceUsingSelectedLocale() {
        let provider = LocalizedTextProvider(locale: .german) { key, locale in
            XCTAssertEqual(locale, .german)
            XCTAssertEqual(key, .settingsFreshnessLastSucceeded)
            return "%@: %@; letzte erfolgreiche Aktualisierung %@"
        }

        XCTAssertEqual(
            provider.text(
                .settingsFreshnessLastSucceeded,
                "Kontingent",
                "Aktuell",
                "gerade eben"
            ),
            "Kontingent: Aktuell; letzte erfolgreiche Aktualisierung gerade eben"
        )
    }

    func testLongStringPseudolocalizationIsDeterministicAndPreservesTokens() {
        let source = "Quota %@ has %lld percent remaining — reset soon"
        let first = LocalizationPseudolocalizer.expand(source)
        let second = LocalizationPseudolocalizer.expand(source)

        XCTAssertEqual(first, second)
        XCTAssertTrue(first.hasPrefix("［"))
        XCTAssertTrue(first.hasSuffix("］"))
        XCTAssertTrue(first.contains("%@"))
        XCTAssertTrue(first.contains("%lld"))
        XCTAssertGreaterThan(first.count, source.count * 13 / 10)
    }

    func testProductionSourceHasNoUnallowlistedHardCodedHanCopy() throws {
        let builtInNameLines: Set<String> = [
            #"name: "莫蘭迪","#,
            #"name: "賽博龐克","#,
            #"name: "溫暖手繪動畫","#,
            #"name: "玻璃感","#,
            #"name: "素描","#,
            #"name: "卡通插畫","#,
        ]
        var violations: [String] = []

        for file in try productionSwiftFiles() {
            let sourceRootName = productionSourceURL().lastPathComponent
            let rootIndex = try XCTUnwrap(
                file.pathComponents.lastIndex(of: sourceRootName)
            )
            let relative = file.pathComponents
                .dropFirst(rootIndex + 1)
                .joined(separator: "/")
            let source = try String(contentsOf: file, encoding: .utf8)
            for (offset, line) in source.split(
                separator: "\n",
                omittingEmptySubsequences: false
            ).enumerated() where line.range(
                of: #"[\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF]"#,
                options: .regularExpression
            ) != nil {
                if relative == "UI/DebugUITestControlWindow.swift" {
                    continue
                }
                if relative == "Theme/BuiltInThemes.swift",
                   builtInNameLines.contains(
                       line.trimmingCharacters(in: .whitespaces)
                   )
                {
                    continue
                }
                violations.append("\(relative):\(offset + 1):\(line)")
            }
        }

        XCTAssertEqual(violations, [], violations.joined(separator: "\n"))
    }

    func testProductionViewsHaveNoDirectVisibleStringLiterals() throws {
        let pattern = #"\b(?:Text|Button|GroupBox|Label|Picker)\(\s*\"([^\"]*)\""#
        let regex = try NSRegularExpression(pattern: pattern)
        var violations: [String] = []

        for file in try productionSwiftFiles()
            where file.lastPathComponent != "DebugUITestControlWindow.swift"
        {
            let source = try String(contentsOf: file, encoding: .utf8)
            let matches = regex.matches(
                in: source,
                range: NSRange(source.startIndex..., in: source)
            )
            for match in matches {
                let literal = (source as NSString).substring(
                    with: match.range(at: 1)
                )
                guard !literal.isEmpty else { continue }
                violations.append("\(file.lastPathComponent): \(literal)")
            }
        }

        XCTAssertEqual(violations, [], violations.joined(separator: "\n"))
    }

    private func catalogStrings() throws -> [String: Any] {
        let data = try Data(contentsOf: catalogURL())
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(root["sourceLanguage"] as? String, "zh-Hant")
        XCTAssertEqual(root["version"] as? String, "1.0")
        return try XCTUnwrap(root["strings"] as? [String: Any])
    }

    private func localizedValues(for key: String) throws -> [String: String] {
        let strings = try catalogStrings()
        let entry = try XCTUnwrap(strings[key] as? [String: Any])
        let localizations = try XCTUnwrap(
            entry["localizations"] as? [String: Any]
        )
        return try Dictionary(uniqueKeysWithValues: localizations.map {
            locale, rawEntry in
            let localeEntry = try XCTUnwrap(rawEntry as? [String: Any])
            let unit = try XCTUnwrap(
                localeEntry["stringUnit"] as? [String: Any]
            )
            return (locale, try XCTUnwrap(unit["value"] as? String))
        })
    }

    private func catalogURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CodexQuotaMonitor/Resources/Localizable.xcstrings")
    }

    private func productionSourceURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CodexQuotaMonitor")
    }

    private func productionSwiftFiles() throws -> [URL] {
        let root = productionSourceURL()
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey]
            )
        )
        return enumerator.compactMap { item in
            guard let url = item as? URL,
                  url.pathExtension == "swift"
            else {
                return nil
            }
            return url
        }
    }

    private func glossaryURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/localization-glossary.md")
    }
}
