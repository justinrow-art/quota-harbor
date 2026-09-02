import Foundation
import AppKit
import XCTest
@testable import CodexQuotaMonitor

final class StatusItemPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testLoadingHasCompactTitleTooltipAndVoiceOverCopy() {
        let presentation = presenter(
            state: .loading,
            settings: settings(language: .english)
        )

        XCTAssertEqual(presentation.title, "Codex …")
        XCTAssertEqual(presentation.toolTip, "Loading Codex quota…")
        XCTAssertEqual(presentation.accessibilityLabel, "Codex quota is loading.")
        XCTAssertEqual(
            presentation.menu,
            StatusItemMenuPresentation(
                refreshTitle: "Refresh",
                settingsTitle: "Settings…",
                quitTitle: "Quit QuotaHarbor"
            )
        )
        XCTAssertFalse(presentation.isStale)
    }

    func testMenuCopyUsesSelectedLanguageAndAWholeParameterizedQuitTitle() {
        let japanese = presenter(
            state: .loading,
            settings: settings(language: .japanese)
        )

        XCTAssertEqual(japanese.menu.refreshTitle, "更新")
        XCTAssertEqual(japanese.menu.settingsTitle, "設定…")
        XCTAssertEqual(
            japanese.menu.quitTitle,
            "QuotaHarborを終了"
        )
    }

    func testLoadingUsesEveryExplicitAppLanguageInsteadOfFallingBackToEnglish() {
        let expectations: [(AppLanguage, String, String)] = [
            (.traditionalChinese, "正在載入 Codex 額度…", "正在載入 Codex 額度。"),
            (.simplifiedChinese, "正在载入 Codex 额度…", "正在载入 Codex 额度。"),
            (.english, "Loading Codex quota…", "Codex quota is loading."),
            (.japanese, "Codex 使用量を読み込み中…", "Codex 使用量を読み込んでいます。"),
            (.korean, "Codex 할당량 불러오는 중…", "Codex 할당량을 불러오는 중입니다."),
            (.spanish, "Cargando la cuota de Codex…", "La cuota de Codex se está cargando."),
            (.french, "Chargement du quota Codex…", "Le quota Codex est en cours de chargement."),
            (.german, "Codex-Kontingent wird geladen…", "Das Codex-Kontingent wird geladen."),
        ]

        for (language, toolTip, accessibilityLabel) in expectations {
            let presentation = presenter(
                state: .loading,
                settings: settings(language: language)
            )
            XCTAssertEqual(presentation.toolTip, toolTip, "\(language)")
            XCTAssertEqual(
                presentation.accessibilityLabel,
                accessibilityLabel,
                "\(language)"
            )
        }
    }

    func testSystemLanguageUsesSupportedSystemLocaleAndDefaultsToEnglish() {
        let japanese = StatusItemPresenter().makePresentation(
            catalog: .loading,
            settings: settings(language: .system),
            now: now,
            locale: Locale(identifier: "ja_JP")
        )
        let unsupportedSystemLocale = StatusItemPresenter().makePresentation(
            catalog: .loading,
            settings: settings(language: .system),
            now: now,
            locale: Locale(identifier: "ar_SA")
        )

        XCTAssertEqual(japanese.toolTip, "Codex 使用量を読み込み中…")
        XCTAssertEqual(
            unsupportedSystemLocale.toolTip,
            "Loading Codex quota…"
        )
    }

    func testExplicitLanguageOverloadUsesRequestedLanguageWithoutMutatingSettings() {
        let original = settings(language: .english)

        let presentation = StatusItemPresenter().makePresentation(
            catalog: .loading,
            settings: original,
            now: now,
            language: .japanese,
            systemLocale: Locale(identifier: "en_US")
        )

        XCTAssertEqual(presentation.toolTip, "Codex 使用量を読み込み中…")
        XCTAssertEqual(original.language, .english)
    }

    func testParameterizedWindowCopyIsLocalizedInAllEightLocales() throws {
        let reset = Int64(now.addingTimeInterval(3_600).timeIntervalSince1970)
        let catalog = try makeCatalog([
            window(.primary, 300, used: 27, resetsAt: reset),
        ])
        let expectations: [(AppLanguage, String, String)] = [
            (.traditionalChinese, "5h 73%", "由已用 27% 推算"),
            (.simplifiedChinese, "5h 73%", "由已用 27% 推算"),
            (.english, "5h 73%", "derived from 27% used"),
            (.japanese, "5時間 73%", "使用済み 27% から算出"),
            (.korean, "5시간 73%", "사용된 27%에서 계산"),
            (.spanish, "5 h 73%", "derivado del 27% usado"),
            (.french, "5 h 73%", "dérivé de 27% utilisés"),
            (.german, "5 Std. 73%", "aus 27% Verbrauch abgeleitet"),
        ]

        for (language, title, detailedMarker) in expectations {
            let presentation = presenter(
                state: .fresh(catalog, now),
                settings: settings(language: language)
            )
            XCTAssertEqual(presentation.title, title, "\(language)")
            XCTAssertTrue(
                presentation.toolTip.contains(detailedMarker),
                "\(language): \(presentation.toolTip)"
            )
            XCTAssertTrue(
                presentation.accessibilityLabel.contains(detailedMarker),
                "\(language): \(presentation.accessibilityLabel)"
            )
        }
    }

    func testAutomaticTraditionalChineseShowsFiveHourAndWeekTogether() throws {
        let catalog = try makeCatalog([
            window(.primary, 300, used: 27),
            window(.secondary, 10_080, used: 58),
        ])

        let presentation = presenter(
            state: .fresh(catalog, now),
            settings: settings(language: .traditionalChinese)
        )

        XCTAssertEqual(presentation.title, "5h 73% · 週 42%")
        XCTAssertTrue(presentation.toolTip.contains("5 小時窗口"))
        XCTAssertTrue(presentation.toolTip.contains("每週窗口"))
        XCTAssertFalse(presentation.isStale)
    }

    func testAutomaticShowsOnlyWeekWhenItIsTheOnlyWindow() throws {
        let catalog = try makeCatalog([
            window(.secondary, 10_080, used: 58),
        ])

        XCTAssertEqual(
            presenter(
                state: .fresh(catalog, now),
                settings: settings(language: .traditionalChinese)
            ).title,
            "週 42%"
        )
    }

    func testThreePlusAutomaticWindowsUseStableFiveHourThenWeekSelection() throws {
        let catalog = try makeCatalog([
            window(.primary, 360, used: 1),
            window(.secondary, 10_080, used: 58),
            window(.primary, 300, used: 27),
            window(.secondary, 90, used: 2),
        ])

        let title = presenter(
            state: .fresh(catalog, now),
            settings: settings(language: .english)
        ).title

        XCTAssertEqual(title, "5h 73% · Week 42%")
        XCTAssertFalse(title.contains("6h"))
        XCTAssertFalse(title.contains("90m"))
    }

    func testDualWindowTitleFitsACompactMenuBarWidthInEveryLanguage() throws {
        let catalog = try makeCatalog([
            window(.primary, 300, used: 27),
            window(.secondary, 10_080, used: 58),
        ])
        let font = NSFont.menuBarFont(ofSize: 0)

        for language in AppLanguage.allCases where language != .system {
            for mode in [PercentageMode.remaining, .used] {
                let title = presenter(
                    state: .fresh(catalog, now),
                    settings: settings(
                        language: language,
                        percentageMode: mode
                    )
                ).title
                let width = (title as NSString).size(
                    withAttributes: [.font: font]
                ).width

                XCTAssertLessThanOrEqual(
                    width,
                    190,
                    "Menu bar title is too wide for \(language): \(title)"
                )
            }
        }
    }

    func testUnknownPositiveDurationRemainsVisible() throws {
        let catalog = try makeCatalog([
            window(.primary, 360, used: 27),
        ])

        XCTAssertEqual(
            presenter(
                state: .fresh(catalog, now),
                settings: settings(language: .traditionalChinese)
            ).title,
            "6h 73%"
        )
    }

    func testRemainingAndUsedModesRenderBoundaryPercentagesTruthfully() throws {
        for used in [0, 7, 73, 100] {
            let catalog = try makeCatalog([
                window(.primary, 300, used: used),
            ])
            let remaining = presenter(
                state: .fresh(catalog, now),
                settings: settings(language: .english, percentageMode: .remaining)
            )
            let usedPresentation = presenter(
                state: .fresh(catalog, now),
                settings: settings(language: .english, percentageMode: .used)
            )

            XCTAssertEqual(remaining.title, "5h \(100 - used)%")
            XCTAssertEqual(usedPresentation.title, "5h U\(used)%")
            XCTAssertNotEqual(remaining.title, usedPresentation.title)
        }
    }

    func testUsedCompactModeIsDistinctAndLocalizedWithoutChangingDetailedMeaning()
        throws
    {
        let catalog = try makeCatalog([
            window(.primary, 300, used: 27),
        ])
        let expectations: [(AppLanguage, String, String)] = [
            (.traditionalChinese, "5h 用27%", "已用 27%"),
            (.simplifiedChinese, "5h 用27%", "已用 27%"),
            (.english, "5h U27%", "27% used"),
            (.japanese, "5時間 使用27%", "使用済み27%"),
            (.korean, "5시간 사용27%", "27% 사용"),
            (.spanish, "5 h U27%", "27% usado"),
            (.french, "5 h U27%", "27% utilisé"),
            (.german, "5 Std. V27%", "27% verbraucht"),
        ]

        for (language, expectedTitle, detailedMarker) in expectations {
            let presentation = presenter(
                state: .fresh(catalog, now),
                settings: settings(
                    language: language,
                    percentageMode: .used
                )
            )

            XCTAssertEqual(presentation.title, expectedTitle, "\(language)")
            XCTAssertTrue(
                presentation.toolTip.contains(detailedMarker),
                "\(language): \(presentation.toolTip)"
            )
            XCTAssertTrue(
                presentation.accessibilityLabel.contains(detailedMarker),
                "\(language): \(presentation.accessibilityLabel)"
            )
        }
    }

    func testStaleKeepsValuesAndAddsFreshnessWarning() throws {
        let catalog = try makeCatalog([
            window(.primary, 300, used: 27),
        ])

        let presentation = presenter(
            state: .stale(catalog, now.addingTimeInterval(-900), .stale),
            settings: settings(language: .english)
        )

        XCTAssertEqual(presentation.title, "5h 73%")
        XCTAssertTrue(presentation.isStale)
        XCTAssertTrue(presentation.toolTip.contains("may be out of date"))
        XCTAssertTrue(presentation.accessibilityLabel.contains("stale"))
    }

    func testUnsupportedAndUnavailableUseActionableTruthfulCopy() {
        let unsupported = presenter(
            state: .unsupported,
            settings: settings(language: .english)
        )
        let signedOut = presenter(
            state: .unavailable(.unauthenticated),
            settings: settings(language: .english)
        )
        let backend = presenter(
            state: .unavailable(.temporaryBackend),
            settings: settings(language: .english)
        )
        let rejected = presenter(
            state: .unavailable(.serverRejected),
            settings: settings(language: .english)
        )

        XCTAssertEqual(unsupported.title, "—")
        XCTAssertTrue(unsupported.toolTip.contains("does not support"))
        XCTAssertTrue(unsupported.accessibilityLabel.contains("Update Codex"))
        XCTAssertTrue(signedOut.toolTip.contains("Sign in"))
        XCTAssertTrue(backend.toolTip.contains("temporarily"))
        XCTAssertTrue(rejected.toolTip.contains("rejected"))
        XCTAssertTrue(rejected.toolTip.contains("Settings"))
        XCTAssertFalse(rejected.toolTip.contains("temporar"))
        XCTAssertFalse(signedOut.accessibilityLabel.contains("0%"))
    }

    func testUnsupportedAndUnavailableAreLocalizedInEveryExplicitLanguage() {
        let expectations: [(AppLanguage, String, String)] = [
            (.traditionalChinese, "不支援", "登入"),
            (.simplifiedChinese, "不支持", "登录"),
            (.english, "does not support", "Sign in"),
            (.japanese, "対応していません", "サインイン"),
            (.korean, "지원하지 않습니다", "로그인"),
            (.spanish, "no admite", "Inicia sesión"),
            (.french, "ne prend pas en charge", "Connectez-vous"),
            (.german, "unterstützt", "Melden Sie sich"),
        ]

        for (language, unsupportedMarker, unavailableMarker) in expectations {
            let unsupported = presenter(
                state: .unsupported,
                settings: settings(language: language)
            )
            let unavailable = presenter(
                state: .unavailable(.unauthenticated),
                settings: settings(language: language)
            )

            XCTAssertTrue(
                unsupported.toolTip.contains(unsupportedMarker),
                "\(language): \(unsupported.toolTip)"
            )
            XCTAssertTrue(
                unavailable.toolTip.contains(unavailableMarker),
                "\(language): \(unavailable.toolTip)"
            )
            XCTAssertFalse(unavailable.accessibilityLabel.contains("0%"))
        }
    }

    func testManualSelectionPreservesOrderAndNeverSubstitutes() throws {
        let fiveHour = identity(.primary, 300)
        let week = identity(.secondary, 10_080)
        let catalog = try makeCatalog([
            window(.primary, 300, used: 27),
            window(.secondary, 10_080, used: 58),
        ])

        let presentation = presenter(
            state: .fresh(catalog, now),
            settings: settings(
                language: .traditionalChinese,
                mode: .manual([week, fiveHour])
            )
        )

        XCTAssertEqual(presentation.title, "週 42% · 5h 73%")
    }

    func testPartiallyRetiredManualSelectionKeepsLiveWindowAndDisclosesItInEveryLanguage()
        throws
    {
        let retiredFiveHour = identity(.primary, 300)
        let liveWeek = identity(.secondary, 10_080)
        let catalog = try makeCatalog([
            window(.secondary, 10_080, used: 58),
        ])
        let expectations: [(AppLanguage, String)] = [
            (.traditionalChinese, "部分所選窗口目前未提供"),
            (.simplifiedChinese, "部分所选窗口当前不可用"),
            (.english, "some selected windows are currently unavailable"),
            (.japanese, "一部の選択したウィンドウは現在利用できません"),
            (.korean, "선택한 일부 기간은 현재 사용할 수 없습니다"),
            (.spanish, "algunas ventanas seleccionadas no están disponibles actualmente"),
            (.french, "certaines fenêtres sélectionnées sont actuellement indisponibles"),
            (.german, "einige ausgewählte Fenster sind derzeit nicht verfügbar"),
        ]

        for (language, unavailableMarker) in expectations {
            let presentation = presenter(
                state: .fresh(catalog, now),
                settings: settings(
                    language: language,
                    mode: .manual([retiredFiveHour, liveWeek])
                )
            )

            XCTAssertTrue(
                presentation.title.contains("42%"),
                "\(language): \(presentation.title)"
            )
            XCTAssertTrue(
                presentation.toolTip.contains(unavailableMarker),
                "\(language): \(presentation.toolTip)"
            )
            XCTAssertTrue(
                presentation.accessibilityLabel.contains(unavailableMarker),
                "\(language): \(presentation.accessibilityLabel)"
            )
        }
    }

    func testRetiredManualSelectionFailsClosedWithActionableTooltip() throws {
        let catalog = try makeCatalog([
            window(.primary, 300, used: 27),
        ])
        let retiredWeek = identity(.secondary, 10_080)

        let presentation = presenter(
            state: .fresh(catalog, now),
            settings: settings(
                language: .english,
                mode: .manual([retiredWeek])
            )
        )

        XCTAssertEqual(presentation.title, "—")
        XCTAssertTrue(presentation.toolTip.contains("Settings"))
        XCTAssertTrue(presentation.accessibilityLabel.contains("unavailable"))
        XCTAssertTrue(presentation.accessibilityLabel.contains("Settings"))
        XCTAssertFalse(presentation.title.contains("73"))
    }

    func testDuplicateManualIdentityCollisionFailsClosedInsteadOfLastWins() throws {
        let collisionIdentity = WindowIdentity(
            bucketKey: RateLimitCatalog.legacyBucketKey,
            sourceSlot: .primary,
            durationMinutes: 300
        )
        let keyedWindow = try RateLimitWindow(
            identity: collisionIdentity,
            usedPercent: 10,
            resetsAt: nil
        )
        let legacyWindow = try RateLimitWindow(
            identity: collisionIdentity,
            usedPercent: 90,
            resetsAt: nil
        )
        let catalog = RateLimitCatalog(
            rateLimitsByLimitId: [
                RateLimitCatalog.legacyBucketKey: RateLimitBucket(
                    bucketKey: RateLimitCatalog.legacyBucketKey,
                    windows: [keyedWindow]
                ),
            ],
            legacyBucket: RateLimitBucket(
                bucketKey: RateLimitCatalog.legacyBucketKey,
                windows: [legacyWindow]
            )
        )

        let presentation = presenter(
            state: .fresh(catalog, now),
            settings: settings(
                language: .english,
                mode: .manual([collisionIdentity])
            )
        )

        XCTAssertEqual(presentation.title, "—")
        XCTAssertTrue(presentation.toolTip.contains("Settings"))
        XCTAssertFalse(presentation.title.contains("10"))
        XCTAssertFalse(presentation.title.contains("90"))
    }

    func testNoWindowsAccessibilityIncludesRefreshRecovery() throws {
        let empty = try makeCatalog([])

        let presentation = presenter(
            state: .fresh(empty, now),
            settings: settings(language: .english)
        )

        XCTAssertEqual(presentation.title, "—")
        XCTAssertTrue(presentation.accessibilityLabel.contains("Refresh"))
    }

    func testInvalidManualSelectionCountFailsClosed() throws {
        let catalog = try makeCatalog([
            window(.primary, 300, used: 27),
            window(.secondary, 10_080, used: 58),
        ])
        let invalid = settings(
            language: .english,
            mode: .manual([
                identity(.primary, 300),
                identity(.secondary, 10_080),
                WindowIdentity(bucketKey: "other", sourceSlot: .primary, durationMinutes: 60),
            ])
        )

        XCTAssertEqual(
            presenter(state: .fresh(catalog, now), settings: invalid).title,
            "—"
        )
    }

    func testLongLocalizedCopyStaysInTooltipNotCompactTitle() throws {
        let catalog = try makeCatalog([
            window(.primary, 300, used: 27),
            window(.secondary, 10_080, used: 58),
        ])

        let presentation = presenter(
            state: .fresh(catalog, now),
            settings: settings(language: .traditionalChinese)
        )

        XCTAssertLessThan(presentation.title.count, 30)
        XCTAssertGreaterThan(presentation.toolTip.count, presentation.title.count)
        XCTAssertFalse(presentation.title.contains("資料來自"))
    }

    func testVoiceOverNamesBothWindowsValuesModeResetAndSource() throws {
        let reset = Int64(now.addingTimeInterval(3_600).timeIntervalSince1970)
        let catalog = try makeCatalog([
            window(.primary, 300, used: 27, resetsAt: reset),
            window(.secondary, 10_080, used: 58, resetsAt: reset),
        ])

        let label = presenter(
            state: .fresh(catalog, now),
            settings: settings(language: .traditionalChinese)
        ).accessibilityLabel

        XCTAssertTrue(label.contains("5 小時窗口"))
        XCTAssertTrue(label.contains("codex 額度桶"))
        XCTAssertTrue(label.contains("主要"))
        XCTAssertTrue(label.contains("剩餘 73%"))
        XCTAssertTrue(label.contains("由已用 27% 推算"))
        XCTAssertTrue(label.contains("每週窗口"))
        XCTAssertTrue(label.contains("次要"))
        XCTAssertTrue(label.contains("剩餘 42%"))
        XCTAssertTrue(label.contains("重設"))
        XCTAssertTrue(label.contains("本機 Codex"))
    }

    func testDeterministicFallbackDisclosesNonCodexBucketProvenance() throws {
        let alphaWindow = try window(
            .primary,
            300,
            used: 27,
            bucketKey: "alpha"
        )
        let catalog = try makeCatalog([alphaWindow], bucketKey: "alpha")

        let presentation = presenter(
            state: .fresh(catalog, now),
            settings: settings(language: .english)
        )

        XCTAssertTrue(presentation.toolTip.contains("alpha"))
        XCTAssertTrue(presentation.toolTip.contains("codex"))
        XCTAssertTrue(presentation.toolTip.contains("fallback"))
        XCTAssertTrue(presentation.accessibilityLabel.contains("alpha"))
    }

    func testUsedModeDoesNotClaimItsDirectValueWasDerived() throws {
        let catalog = try makeCatalog([
            window(.primary, 300, used: 27),
        ])

        let presentation = presenter(
            state: .fresh(catalog, now),
            settings: settings(language: .english, percentageMode: .used)
        )

        XCTAssertFalse(presentation.toolTip.contains("derived"))
        XCTAssertFalse(presentation.accessibilityLabel.contains("derived"))
    }

    func testDashboardSingleCodexPreservesExactLegacyPresentation() throws {
        let catalog = try makeCatalog([
            window(.primary, 300, used: 27),
            window(.secondary, 10_080, used: 58),
        ])
        let configured = settings(
            language: .traditionalChinese,
            mode: .manual([
                identity(.secondary, 10_080),
                identity(.primary, 300),
            ])
        )
        let legacy = presenter(
            state: .fresh(catalog, now),
            settings: configured
        )

        let dashboard = dashboardPresenter(
            states: [.codex: .failed(code: .connectorFailed)],
            codexState: .fresh(catalog, now),
            settings: configured
        )

        XCTAssertEqual(dashboard, legacy)
        XCTAssertEqual(dashboard.title, "週 42% · 5h 73%")
    }

    func testDashboardCodexSegmentAlwaysUsesCanonicalRateLane() throws {
        let catalog = try makeCatalog([
            window(.primary, 300, used: 27),
        ])
        let emptyCatalog = try makeCatalog([])
        let oldSnapshot = try providerSnapshot(
            .codex,
            fraction: 0.12,
            stableID: "old-dashboard-value"
        )
        let configured = settings(
            language: .english,
            enabledProviders: [.codex, .claudeCode]
        )
        let cases: [(
            dashboardState: ProviderPresentationState,
            rateState: CapabilityState<RateLimitCatalog>,
            expectedTitle: String,
            isStale: Bool
        )] = [
            (.loading, .fresh(catalog, now), "Cx73% · Cl…", false),
            (.stale(oldSnapshot), .fresh(catalog, now), "Cx73% · Cl…", false),
            (
                .fresh(oldSnapshot),
                .stale(catalog, now.addingTimeInterval(-300), .stale),
                "Cx73% · Cl…",
                true
            ),
            (.fresh(oldSnapshot), .loading, "Cx… · Cl…", false),
            (.fresh(oldSnapshot), .unsupported, "Cx— · Cl…", false),
            (
                .fresh(oldSnapshot),
                .fresh(emptyCatalog, now),
                "Cx— · Cl…",
                false
            ),
            (
                .fresh(oldSnapshot),
                .unavailable(.temporaryBackend),
                "Cx— · Cl…",
                false
            ),
            (
                .fresh(oldSnapshot),
                .unavailable(.unauthenticated),
                "Cx○ · Cl…",
                false
            ),
        ]

        for item in cases {
            let presentation = dashboardPresenter(
                states: [.codex: item.dashboardState],
                codexState: item.rateState,
                settings: configured
            )

            XCTAssertEqual(presentation.title, item.expectedTitle)
            XCTAssertEqual(presentation.isStale, item.isStale)
            XCTAssertFalse(presentation.title.contains("12%"))
        }

        let empty = dashboardPresenter(
            states: [.codex: .fresh(oldSnapshot)],
            codexState: .fresh(emptyCatalog, now),
            settings: configured
        )
        XCTAssertTrue(empty.toolTip.contains("No quota windows are available"))
        XCTAssertFalse(empty.toolTip.contains("waiting"))
    }

    func testDashboardCodexAutomaticDoesNotFallBackToAnotherBucket()
        throws
    {
        let otherWindow = try window(
            .primary,
            300,
            used: 12,
            bucketKey: "other"
        )
        let catalog = RateLimitCatalog(
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
        let presentation = dashboardPresenter(
            states: [:],
            codexState: .fresh(catalog, now),
            settings: settings(
                language: .english,
                enabledProviders: [.codex, .claudeCode]
            )
        )

        XCTAssertEqual(presentation.title, "Cx— · Cl…")
        XCTAssertTrue(
            presentation.toolTip.contains("No quota windows are available")
        )
        XCTAssertFalse(presentation.title.contains("88%"))
    }

    func testDashboardCodexManualRetiredWindowWinsOverEmptyCatalogCopy()
        throws
    {
        let emptyCatalog = try makeCatalog([])
        let retired = identity(.secondary, 10_080)
        let presentation = dashboardPresenter(
            states: [:],
            codexState: .fresh(emptyCatalog, now),
            settings: settings(
                language: .english,
                mode: .manual([retired]),
                enabledProviders: [.codex, .claudeCode]
            )
        )

        XCTAssertEqual(presentation.title, "Cx— · Cl…")
        XCTAssertTrue(presentation.toolTip.contains("Settings"))
        XCTAssertTrue(presentation.accessibilityLabel.contains("unavailable"))
        XCTAssertFalse(
            presentation.toolTip.contains("No quota windows are available")
        )
    }

    func testAutomaticTwoProvidersUsesReadableSegmentSeparator() throws {
        let states: [ProviderID: ProviderPresentationState] = [
            .codex: .fresh(try providerSnapshot(
                .codex,
                fraction: 0.73,
                stableID: "codex"
            )),
            .claudeCode: .fresh(try providerSnapshot(
                .claudeCode,
                fraction: 0.42,
                stableID: "claude"
            )),
        ]

        let presentation = dashboardPresenter(
            states: states,
            codexState: try codexRateState(remainingFraction: 0.73),
            settings: settings(
                language: .english,
                enabledProviders: [.codex, .claudeCode]
            )
        )

        XCTAssertEqual(presentation.title, "Cx73% · Cl42%")
    }

    func testPrimaryModeShowsSelectedProviderButKeepsEveryProviderInDetails()
        throws
    {
        let presentation = dashboardPresenter(
            states: [
                .codex: .fresh(try providerSnapshot(
                    .codex,
                    fraction: 0.73,
                    stableID: "codex"
                )),
                .claudeCode: .fresh(try providerSnapshot(
                    .claudeCode,
                    fraction: 0.42,
                    stableID: "claude"
                )),
            ],
            codexState: try codexRateState(remainingFraction: 0.73),
            settings: settings(
                language: .english,
                enabledProviders: [.codex, .claudeCode],
                statusItemDisplayMode: .primary,
                primaryStatusItemProvider: .claudeCode
            )
        )

        XCTAssertEqual(presentation.title, "Cl42%")
        for details in [
            presentation.toolTip,
            presentation.accessibilityLabel,
        ] {
            assertOrdered(["Codex", "Claude Code"], in: details)
            XCTAssertTrue(details.contains("73% remaining"))
            XCTAssertTrue(details.contains("42% remaining"))
        }
    }

    func testPrimaryModeFallsBackToFirstEnabledProviderWhenUnsetOrDisabled()
        throws
    {
        let states: [ProviderID: ProviderPresentationState] = [
            .claudeCode: .fresh(try providerSnapshot(
                .claudeCode,
                fraction: 0.42,
                stableID: "claude"
            )),
            .codex: .fresh(try providerSnapshot(
                .codex,
                fraction: 0.73,
                stableID: "codex"
            )),
        ]

        for configuredPrimary in [ProviderID?.none, .some(.kimiCode)] {
            let presentation = dashboardPresenter(
                states: states,
                codexState: try codexRateState(remainingFraction: 0.73),
                settings: settings(
                    language: .english,
                    enabledProviders: [.claudeCode, .codex],
                    statusItemDisplayMode: .primary,
                    primaryStatusItemProvider: configuredPrimary
                )
            )

            XCTAssertEqual(presentation.title, "Cl42%")
            assertOrdered(
                ["Claude Code", "Codex"],
                in: presentation.toolTip
            )
        }
    }

    func testFullModeUsesFormalProviderNamesWithoutPresenterTruncation()
        throws
    {
        let presentation = dashboardPresenter(
            states: [
                .codex: .fresh(try providerSnapshot(
                    .codex,
                    fraction: 0.73,
                    stableID: "codex"
                )),
                .claudeCode: .unsupported,
                .kimiCode: .notConnected,
            ],
            codexState: try codexRateState(remainingFraction: 0.73),
            settings: settings(
                language: .english,
                enabledProviders: [.codex, .claudeCode, .kimiCode],
                statusItemDisplayMode: .full
            )
        )

        XCTAssertEqual(
            presentation.title,
            "Codex 73% · Claude Code — · Kimi Code —"
        )
        XCTAssertEqual(presentation.toolTip, presentation.accessibilityLabel)
    }

    func testFullModeSingleCodexUsesFullPrefixWithCatalogSelection() throws {
        let catalog = try makeCatalog([
            window(.primary, 300, used: 27),
            window(.secondary, 10_080, used: 58),
        ])
        let state = CodexProviderSnapshotMapper.map(
            rateState: .fresh(catalog, now),
            usageState: .unsupported,
            accountState: .unsupported
        )
        let presentation = dashboardPresenter(
            states: [.codex: state],
            codexState: .fresh(catalog, now),
            settings: settings(
                language: .english,
                enabledProviders: [.codex],
                statusItemDisplayMode: .full
            )
        )

        XCTAssertEqual(presentation.title, "Codex 5h 73% · Week 42%")
    }

    func testPrimarySingleCodexManualWindowSelectionControlsTitleAndDetails()
        throws
    {
        let fiveHour = try window(.primary, 300, used: 27)
        let week = try window(.secondary, 10_080, used: 58)
        let catalog = try makeCatalog([fiveHour, week])
        let state = CodexProviderSnapshotMapper.map(
            rateState: .fresh(catalog, now),
            usageState: .unsupported,
            accountState: .unsupported
        )

        let fiveHourPresentation = dashboardPresenter(
            states: [.codex: state],
            codexState: .fresh(catalog, now),
            settings: settings(
                language: .english,
                mode: .manual([fiveHour.identity]),
                enabledProviders: [.codex],
                statusItemDisplayMode: .primary
            )
        )
        let weeklyPresentation = dashboardPresenter(
            states: [.codex: state],
            codexState: .fresh(catalog, now),
            settings: settings(
                language: .english,
                mode: .manual([week.identity]),
                enabledProviders: [.codex],
                statusItemDisplayMode: .primary
            )
        )

        XCTAssertEqual(fiveHourPresentation.title, "Cx73%")
        XCTAssertEqual(weeklyPresentation.title, "Cx42%")
        XCTAssertTrue(fiveHourPresentation.toolTip.contains("5-hour window"))
        XCTAssertFalse(fiveHourPresentation.toolTip.contains("Weekly window"))
        XCTAssertTrue(weeklyPresentation.toolTip.contains("Weekly window"))
        XCTAssertFalse(weeklyPresentation.toolTip.contains("5-hour window"))
    }

    func testFullSingleCodexManualWindowSelectionControlsTitleAndDetails()
        throws
    {
        let fiveHour = try window(.primary, 300, used: 27)
        let week = try window(.secondary, 10_080, used: 58)
        let catalog = try makeCatalog([fiveHour, week])
        let state = CodexProviderSnapshotMapper.map(
            rateState: .fresh(catalog, now),
            usageState: .unsupported,
            accountState: .unsupported
        )

        let fiveHourPresentation = dashboardPresenter(
            states: [.codex: state],
            codexState: .fresh(catalog, now),
            settings: settings(
                language: .english,
                mode: .manual([fiveHour.identity]),
                enabledProviders: [.codex],
                statusItemDisplayMode: .full
            )
        )
        let weeklyPresentation = dashboardPresenter(
            states: [.codex: state],
            codexState: .fresh(catalog, now),
            settings: settings(
                language: .english,
                mode: .manual([week.identity]),
                enabledProviders: [.codex],
                statusItemDisplayMode: .full
            )
        )

        XCTAssertEqual(fiveHourPresentation.title, "Codex 73%")
        XCTAssertEqual(weeklyPresentation.title, "Codex 42%")
        XCTAssertTrue(fiveHourPresentation.toolTip.contains("5-hour window"))
        XCTAssertFalse(fiveHourPresentation.toolTip.contains("Weekly window"))
        XCTAssertTrue(weeklyPresentation.toolTip.contains("Weekly window"))
        XCTAssertFalse(weeklyPresentation.toolTip.contains("5-hour window"))
    }

    func testPrimaryCodexAutomaticUsesCatalogPreferredBucketDespiteGenericPreference()
        throws
    {
        let fixture = try automaticCodexSelectionFixture()

        let presentation = dashboardPresenter(
            states: [.codex: fixture.state],
            codexState: .fresh(fixture.catalog, now),
            settings: settings(
                language: .english,
                enabledProviders: [.codex],
                preferences: [.codex: fixture.distractingPreference],
                statusItemDisplayMode: .primary
            )
        )

        XCTAssertEqual(presentation.title, "Cx 5h 73% · Week 42%")
        XCTAssertFalse(presentation.title.contains("99%"))
        XCTAssertTrue(
            presentation.toolTip.contains("Showing the codex quota bucket")
        )
        XCTAssertFalse(presentation.toolTip.contains("60-minute window"))
    }

    func testFullCodexAutomaticUsesCatalogPreferredBucketDespiteGenericPreference()
        throws
    {
        let fixture = try automaticCodexSelectionFixture()

        let presentation = dashboardPresenter(
            states: [.codex: fixture.state],
            codexState: .fresh(fixture.catalog, now),
            settings: settings(
                language: .english,
                enabledProviders: [.codex],
                preferences: [.codex: fixture.distractingPreference],
                statusItemDisplayMode: .full
            )
        )

        XCTAssertEqual(presentation.title, "Codex 5h 73% · Week 42%")
        XCTAssertFalse(presentation.title.contains("99%"))
        XCTAssertTrue(
            presentation.accessibilityLabel.contains(
                "Showing the codex quota bucket"
            )
        )
        XCTAssertFalse(
            presentation.accessibilityLabel.contains("60-minute window")
        )
    }

    func testPrimaryCodexPartialManualSelectionDisclosesRetiredWindow()
        throws
    {
        let retiredFiveHour = identity(.primary, 300)
        let liveWeek = try window(.secondary, 10_080, used: 58)
        let catalog = try makeCatalog([liveWeek])
        let state = CodexProviderSnapshotMapper.map(
            rateState: .fresh(catalog, now),
            usageState: .unsupported,
            accountState: .unsupported
        )

        let presentation = dashboardPresenter(
            states: [.codex: state],
            codexState: .fresh(catalog, now),
            settings: settings(
                language: .english,
                mode: .manual([retiredFiveHour, liveWeek.identity]),
                enabledProviders: [.codex],
                statusItemDisplayMode: .primary
            )
        )

        XCTAssertEqual(presentation.title, "Cx42%")
        for details in [
            presentation.toolTip,
            presentation.accessibilityLabel,
        ] {
            XCTAssertTrue(details.contains("Weekly window"))
            XCTAssertTrue(
                details.contains(
                    "some selected windows are currently unavailable"
                )
            )
        }
    }

    func testFullCodexRetiredManualSelectionUsesUnavailableRecoveryCopy()
        throws
    {
        let catalog = try makeCatalog([
            window(.primary, 300, used: 27),
        ])
        let state = CodexProviderSnapshotMapper.map(
            rateState: .fresh(catalog, now),
            usageState: .unsupported,
            accountState: .unsupported
        )

        let presentation = dashboardPresenter(
            states: [.codex: state],
            codexState: .fresh(catalog, now),
            settings: settings(
                language: .english,
                mode: .manual([identity(.secondary, 10_080)]),
                enabledProviders: [.codex],
                statusItemDisplayMode: .full
            )
        )

        XCTAssertEqual(presentation.title, "Codex —")
        XCTAssertTrue(
            presentation.toolTip.contains(
                "The selected quota window is unavailable"
            )
        )
        XCTAssertTrue(
            presentation.accessibilityLabel.contains(
                "The selected Codex quota window is unavailable"
            )
        )
        XCTAssertTrue(presentation.toolTip.contains("Settings"))
        XCTAssertTrue(presentation.accessibilityLabel.contains("Settings"))
        XCTAssertFalse(presentation.toolTip.contains("waiting"))
        XCTAssertFalse(presentation.accessibilityLabel.contains("waiting"))
    }

    func testDashboardUsesConfiguredOrderKeepsMissingLoadingAndHidesUnselected()
        throws
    {
        let states: [ProviderID: ProviderPresentationState] = [
            .googleAntigravity: .fresh(try providerSnapshot(
                .googleAntigravity,
                fraction: 0.99,
                stableID: "must-not-leak"
            )),
            .codex: .fresh(try providerSnapshot(
                .codex,
                fraction: 0.2,
                stableID: "codex-live"
            )),
            .claudeCode: .unsupported,
        ]
        let configured = settings(
            language: .english,
            enabledProviders: [.kimiCode, .codex, .claudeCode]
        )

        let presentation = dashboardPresenter(
            states: states,
            codexState: try codexRateState(remainingFraction: 0.2),
            settings: configured
        )

        XCTAssertEqual(presentation.title, "Ki… Cx20% Cl—")
        XCTAssertFalse(presentation.title.contains("G"))
        XCTAssertTrue(presentation.toolTip.hasPrefix("Kimi Code"))
    }

    func testTwoThroughFourProvidersRenderExactlyOneSegmentEach() throws {
        let allProviders = ProviderID.allCases
        let fractions = [0.1, 0.2, 0.3, 0.4]
        let states = try Dictionary(
            uniqueKeysWithValues: zip(allProviders, fractions).map {
                providerID, fraction in
                (
                    providerID,
                    ProviderPresentationState.fresh(
                        try providerSnapshot(
                            providerID,
                            fraction: fraction,
                            stableID: "primary"
                        )
                    )
                )
            }
        )

        let expectedTitles = [
            2: "G— · Cx20%",
            3: "G— Cx20% Cl30%",
            4: "G— Cx20% Cl30% Ki—",
        ]
        for count in 2...4 {
            let enabled = Array(allProviders.prefix(count))
            let presentation = dashboardPresenter(
                states: states,
                codexState: try codexRateState(remainingFraction: 0.2),
                settings: settings(
                    language: .english,
                    enabledProviders: enabled
                )
            )
            XCTAssertEqual(presentation.title, expectedTitles[count])
        }
    }

    func testClaudeLivePrimaryPreferenceWinsOverShortestWindow() throws {
        let short = try providerMetric(
            .claudeCode,
            fraction: 0.2,
            stableID: "short",
            durationMinutes: 300
        )
        let preferred = try providerMetric(
            .claudeCode,
            fraction: 0.8,
            stableID: "preferred-week",
            durationMinutes: 10_080
        )
        let preference = try XCTUnwrap(
            PrimaryMetricPreference(
                providerID: .claudeCode,
                metricKey: preferred.metricKey
            )
        )
        let snapshot = try providerSnapshot(
            .claudeCode,
            metrics: [short, preferred]
        )

        let presentation = dashboardPresenter(
            states: [.claudeCode: .fresh(snapshot), .codex: .unsupported],
            codexState: .unsupported,
            settings: settings(
                language: .english,
                enabledProviders: [.claudeCode, .codex],
                preferences: [.claudeCode: preference]
            )
        )

        XCTAssertEqual(presentation.title, "Cl80% · Cx—")
        XCTAssertTrue(presentation.toolTip.contains("Weekly window"))
    }

    @MainActor
    func testSingleClaudeShowsPreferredThenFallbackWindowUpToTwo() throws {
        let short = try providerMetric(
            .claudeCode,
            fraction: 0.2,
            stableID: "short",
            durationMinutes: 300
        )
        let preferred = try providerMetric(
            .claudeCode,
            fraction: 0.8,
            stableID: "preferred-week",
            durationMinutes: 10_080
        )
        let third = try providerMetric(
            .claudeCode,
            fraction: 0.4,
            stableID: "third",
            durationMinutes: 1_440
        )
        let preference = try XCTUnwrap(PrimaryMetricPreference(
            providerID: .claudeCode,
            metricKey: preferred.metricKey
        ))
        let states: [ProviderID: ProviderPresentationState] = [
            .claudeCode: .fresh(try providerSnapshot(
                .claudeCode,
                metrics: [third, short, preferred]
            )),
        ]

        for language in AppLanguage.allCases {
            let presentation = dashboardPresenter(
                states: states,
                settings: settings(
                    language: language,
                    enabledProviders: [.claudeCode],
                    preferences: [.claudeCode: preference]
                )
            )
            let visible = AppKitStatusItemHandle.visibleTitle(for: presentation)
            let width = (visible as NSString).size(
                withAttributes: [.font: NSFont.menuBarFont(ofSize: 0)]
            ).width

            XCTAssertTrue(presentation.title.hasPrefix("Cl"), "\(language)")
            XCTAssertEqual(
                presentation.title.filter { $0 == "%" }.count,
                2,
                "\(language): \(presentation.title)"
            )
            XCTAssertLessThanOrEqual(
                width,
                220,
                "\(language): \(visible)"
            )
        }

        let english = dashboardPresenter(
            states: states,
            settings: settings(
                language: .english,
                enabledProviders: [.claudeCode],
                preferences: [.claudeCode: preference]
            )
        )
        XCTAssertEqual(english.title, "Cl Week 80% · 5h 20%")
        assertOrdered(["Weekly window", "5-hour window"], in: english.toolTip)
        XCTAssertFalse(english.toolTip.contains("1440-minute"))
    }

    func testMissingPreferenceFallsBackByDurationThenStableIDDeterministically()
        throws
    {
        let metrics = try [
            providerMetric(
                .claudeCode,
                fraction: 0.1,
                stableID: "z-short",
                durationMinutes: 300
            ),
            providerMetric(
                .claudeCode,
                fraction: 0.2,
                stableID: "a-short",
                durationMinutes: 300
            ),
            providerMetric(
                .claudeCode,
                fraction: 0.3,
                stableID: "week",
                durationMinutes: 10_080
            ),
            providerMetric(
                .claudeCode,
                fraction: 0.4,
                stableID: "unknown-duration",
                durationMinutes: nil
            ),
        ]
        let missingKey = try XCTUnwrap(
            ProviderMetricKey(
                providerID: .claudeCode,
                stableID: "retired"
            )
        )
        let preference = try XCTUnwrap(
            PrimaryMetricPreference(
                providerID: .claudeCode,
                metricKey: missingKey
            )
        )
        let configured = settings(
            language: .english,
            enabledProviders: [.claudeCode, .kimiCode],
            preferences: [.claudeCode: preference]
        )

        for orderedMetrics in [metrics, metrics.reversed()] {
            let presentation = dashboardPresenter(
                states: [
                    .claudeCode: .fresh(try providerSnapshot(
                        .claudeCode,
                        metrics: Array(orderedMetrics)
                    )),
                    .kimiCode: .unsupported,
                ],
                settings: configured
            )

            XCTAssertEqual(presentation.title, "Cl20% · Ki—")
            XCTAssertFalse(presentation.toolTip.contains("a-short"))
        }
    }

    func testProviderStatesAndGenuineZeroHaveDistinctPresentations() throws {
        let zeroSnapshot = try providerSnapshot(
            .claudeCode,
            fraction: 0,
            stableID: "zero",
            durationMinutes: 300
        )
        let nonzeroSnapshot = try providerSnapshot(
            .claudeCode,
            fraction: 0.27,
            stableID: "stale",
            durationMinutes: 300
        )
        let emptySnapshot = try providerSnapshot(
            .claudeCode,
            metrics: []
        )
        let cases: [(ProviderPresentationState, String, Bool)] = [
            (.loading, "Cl…", false),
            (.fresh(zeroSnapshot), "Cl0%", false),
            (.stale(nonzeroSnapshot), "Cl27%", true),
            (.notConnected, "Cl○", false),
            (.unsupported, "Cl—", false),
            (.failed(code: .connectorFailed), "Cl!", false),
            (.fresh(emptySnapshot), "Cl…", false),
        ]
        let configured = settings(
            language: .english,
            enabledProviders: [.claudeCode]
        )
        var signatures: Set<String> = []

        for (state, title, isStale) in cases {
            let presentation = dashboardPresenter(
                states: [.claudeCode: state],
                settings: configured
            )
            XCTAssertEqual(presentation.title, title)
            XCTAssertEqual(presentation.isStale, isStale)
            signatures.insert(
                "\(presentation.title)|\(presentation.toolTip)|\(presentation.isStale)"
            )
        }

        XCTAssertEqual(signatures.count, cases.count)
    }

    func testPresenceOnlyProvidersAndAwaitingClaudeNeverManufactureZero()
        throws
    {
        let google = try XCTUnwrap(ProviderSnapshot(
            providerID: .googleAntigravity,
            metrics: [],
            capturedAt: now,
            runtimePresence: .application(installed: true, running: true)
        ))
        let claude = try providerSnapshot(.claudeCode, metrics: [])
        let kimi = try XCTUnwrap(ProviderSnapshot(
            providerID: .kimiCode,
            metrics: [],
            capturedAt: now,
            runtimePresence: .command(available: true)
        ))

        let presentation = dashboardPresenter(
            states: [
                .googleAntigravity: .fresh(google),
                .claudeCode: .fresh(claude),
                .kimiCode: .fresh(kimi),
            ],
            settings: settings(
                language: .english,
                enabledProviders: [
                    .googleAntigravity,
                    .claudeCode,
                    .kimiCode,
                ]
            )
        )

        XCTAssertEqual(presentation.title, "G● Cl… Ki○")
        XCTAssertFalse(presentation.title.contains("✓"))
        XCTAssertFalse(presentation.title.contains("0%"))
        XCTAssertTrue(
            presentation.toolTip.contains(
                "app is running; local app presence only; automated quota is unsupported"
            )
        )
        XCTAssertTrue(
            presentation.toolTip.contains(
                "Claude Code CLI is signed in; waiting for the status line relay to provide a quota snapshot"
            )
        )
        XCTAssertTrue(
            presentation.toolTip.contains(
                "command is available; local CLI presence only; automated quota is unsupported"
            )
        )
        XCTAssertEqual(presentation.toolTip, presentation.accessibilityLabel)
    }

    func testProviderSpecificAbsenceAndMissingCodexQuotaStayDiagnostic()
        throws
    {
        let codexWithoutQuota = try providerSnapshot(.codex, metrics: [])
        let presentation = dashboardPresenter(
            states: [
                .googleAntigravity: .notConnected,
                .codex: .fresh(codexWithoutQuota),
                .claudeCode: .notConnected,
                .kimiCode: .notConnected,
            ],
            settings: settings(
                language: .english,
                enabledProviders: ProviderID.allCases
            )
        )

        XCTAssertEqual(presentation.title, "G— Cx… Cl○ Ki—")
        XCTAssertFalse(presentation.title.contains("✓"))
        XCTAssertFalse(presentation.title.contains("%"))
        XCTAssertTrue(
            presentation.toolTip.contains(
                "app is not installed; local app presence only; automated quota is unsupported"
            )
        )
        XCTAssertTrue(
            presentation.toolTip.contains("Loading")
        )
        XCTAssertTrue(
            presentation.toolTip.contains("Claude Code CLI is not signed in")
        )
        XCTAssertTrue(
            presentation.toolTip.contains(
                "command is not installed or unavailable; local CLI presence only; automated quota is unsupported"
            )
        )
    }

    func testEmptyProviderSelectionKeepsNeutralSettingsRecoveryItem() {
        let presentation = dashboardPresenter(
            states: [:],
            settings: settings(
                language: .english,
                enabledProviders: []
            )
        )

        XCTAssertEqual(presentation.title, "AI")
        XCTAssertTrue(presentation.toolTip.contains("Settings"))
        XCTAssertTrue(presentation.accessibilityLabel.contains("Settings"))
        XCTAssertEqual(presentation.menu.settingsTitle, "Settings…")
        XCTAssertFalse(presentation.isStale)
    }

    @MainActor
    func testAutomaticStatusItemCoversAllSelectionsAndEightExplicitLanguages()
        throws
    {
        let languages: [AppLanguage] = [
            .traditionalChinese,
            .simplifiedChinese,
            .english,
            .japanese,
            .korean,
            .spanish,
            .french,
            .german,
        ]
        let providers = ProviderID.allCases
        let catalog = try makeCatalog([
            window(.primary, 300, used: 27),
        ])
        let codexState = CodexProviderSnapshotMapper.map(
            rateState: .fresh(catalog, now),
            usageState: .unsupported,
            accountState: .unsupported
        )
        guard case let .fresh(codexSnapshot) = codexState else {
            return XCTFail("Canonical Codex catalog did not map to a fresh snapshot")
        }
        let expectedCodexMetricKey = try XCTUnwrap(
            ProviderMetricKey.codexRateLimitWindow(
                try XCTUnwrap(catalog.selectedBucket.windows.first).identity
            )
        )
        XCTAssertEqual(
            codexSnapshot.metrics.map(\.metricKey),
            [expectedCodexMetricKey]
        )
        let googleSnapshot = try XCTUnwrap(ProviderSnapshot(
            providerID: .googleAntigravity,
            metrics: [],
            capturedAt: now,
            runtimePresence: .application(installed: true, running: true)
        ))
        let kimiSnapshot = try XCTUnwrap(ProviderSnapshot(
            providerID: .kimiCode,
            metrics: [],
            capturedAt: now,
            runtimePresence: .command(available: true)
        ))
        let states: [ProviderID: ProviderPresentationState] = [
            .googleAntigravity: .fresh(googleSnapshot),
            .codex: codexState,
            .claudeCode: .fresh(try providerSnapshot(
                .claudeCode,
                fraction: 0.42,
                stableID: "matrix-claude"
            )),
            .kimiCode: .fresh(kimiSnapshot),
        ]
        let font = NSFont.menuBarFont(ofSize: 0)

        for mask in 0..<(1 << providers.count) {
            let enabled = providers.enumerated().compactMap {
                index, providerID in
                mask & (1 << index) == 0 ? nil : providerID
            }
            for language in languages {
                let localizedText = LocalizedTextProvider(
                    language: language,
                    systemLocale: Locale(identifier: "en_US")
                )
                for percentageMode in PercentageMode.allCases {
                    let context = "mask=\(mask), enabled=\(enabled), language=\(language), percentage=\(percentageMode)"
                    let presentation = dashboardPresenter(
                        states: states,
                        codexState: .fresh(catalog, now),
                        settings: settings(
                            language: language,
                            percentageMode: percentageMode,
                            enabledProviders: enabled
                        )
                    )

                    XCTAssertFalse(presentation.title.isEmpty, context)
                    XCTAssertFalse(presentation.toolTip.isEmpty, context)
                    XCTAssertFalse(
                        presentation.accessibilityLabel.isEmpty,
                        context
                    )

                    if enabled.isEmpty {
                        XCTAssertEqual(
                            presentation.toolTip,
                            localizedText.text(.statusProvidersEmptyToolTip),
                            context
                        )
                        XCTAssertEqual(
                            presentation.accessibilityLabel,
                            localizedText.text(
                                .statusProvidersEmptyAccessibility
                            ),
                            context
                        )
                        for providerID in providers {
                            let name = localizedProviderName(
                                providerID,
                                text: localizedText
                            )
                            XCTAssertFalse(
                                titleContainsCompactProvider(
                                    providerID,
                                    in: presentation.title
                                ),
                                "\(context), empty title leaked \(providerID.compactIdentifier)"
                            )
                            XCTAssertFalse(
                                presentation.toolTip.contains(name),
                                "\(context), empty tooltip leaked \(name)"
                            )
                            XCTAssertFalse(
                                presentation.accessibilityLabel.contains(name),
                                "\(context), empty accessibility leaked \(name)"
                            )
                        }
                    } else {
                        for providerID in providers {
                            let name = localizedProviderName(
                                providerID,
                                text: localizedText
                            )
                            if enabled.contains(providerID) {
                                if enabled != [.codex] {
                                    XCTAssertTrue(
                                        titleContainsCompactProvider(
                                            providerID,
                                            in: presentation.title
                                        ),
                                        "\(context), title missing compact \(providerID.compactIdentifier): \(presentation.title)"
                                    )
                                }
                                XCTAssertTrue(
                                    presentation.toolTip.contains(name),
                                    "\(context), tooltip missing \(name): \(presentation.toolTip)"
                                )
                                XCTAssertTrue(
                                    presentation.accessibilityLabel.contains(name),
                                    "\(context), accessibility missing \(name): \(presentation.accessibilityLabel)"
                                )
                            } else {
                                XCTAssertFalse(
                                    titleContainsCompactProvider(
                                        providerID,
                                        in: presentation.title
                                    ),
                                    "\(context), title leaked disabled \(providerID.compactIdentifier): \(presentation.title)"
                                )
                                XCTAssertFalse(
                                    presentation.toolTip.contains(name),
                                    "\(context), tooltip leaked disabled \(name): \(presentation.toolTip)"
                                )
                                XCTAssertFalse(
                                    presentation.accessibilityLabel.contains(name),
                                    "\(context), accessibility leaked disabled \(name): \(presentation.accessibilityLabel)"
                                )
                            }
                        }

                        if enabled.contains(.codex) {
                            let expectedPercent = percentageMode == .remaining
                                ? 73
                                : 27
                            XCTAssertTrue(
                                presentation.title.contains(
                                    "\(expectedPercent)%"
                                ),
                                "\(context), Codex did not use the selected catalog window: \(presentation.title)"
                            )
                            XCTAssertFalse(
                                presentation.title.contains("Cx…"),
                                "\(context), canonical Codex metric resolved as loading"
                            )
                            XCTAssertTrue(
                                presentation.toolTip.contains(
                                    "\(expectedPercent)%"
                                ),
                                "\(context), Codex tooltip has the wrong percentage: \(presentation.toolTip)"
                            )
                            XCTAssertTrue(
                                presentation.accessibilityLabel.contains(
                                    "\(expectedPercent)%"
                                ),
                                "\(context), Codex accessibility has the wrong percentage: \(presentation.accessibilityLabel)"
                            )
                        }
                    }

                    if enabled.count >= 3 {
                        let visible = AppKitStatusItemHandle.visibleTitle(
                            for: presentation
                        )
                        let width = (visible as NSString).size(
                            withAttributes: [.font: font]
                        ).width
                        XCTAssertLessThanOrEqual(
                            width,
                            220,
                            "\(context), visible=\(visible), width=\(width)"
                        )
                    }
                }
            }
        }
    }

    @MainActor
    func testThreeAndFourProviderAutomaticTitlesFitEveryLanguageAndPercentageMode()
        throws
    {
        let font = NSFont.menuBarFont(ofSize: 0)

        for language in AppLanguage.allCases {
            for mode in PercentageMode.allCases {
                let fraction = mode == .remaining ? 1.0 : 0.0
                let states = try Dictionary(
                    uniqueKeysWithValues: ProviderID.allCases.map { providerID in
                        (
                            providerID,
                            ProviderPresentationState.stale(
                                try providerSnapshot(
                                    providerID,
                                    fraction: fraction,
                                    stableID: "worst-width",
                                    durationMinutes: 300
                                )
                            )
                        )
                    }
                )
                for count in 3...4 {
                    let enabled = Array(ProviderID.allCases.prefix(count))
                    let presentation = dashboardPresenter(
                        states: states,
                        settings: settings(
                            language: language,
                            percentageMode: mode,
                            enabledProviders: enabled
                        )
                    )
                    let visible = AppKitStatusItemHandle.visibleTitle(
                        for: presentation
                    )
                    let width = (visible as NSString).size(
                        withAttributes: [.font: font]
                    ).width

                    XCTAssertLessThanOrEqual(
                        width,
                        220,
                        "\(language), \(mode), \(count): \(visible)"
                    )
                    for providerID in enabled {
                        XCTAssertTrue(
                            visible.contains(providerID.compactIdentifier)
                        )
                    }
                }
            }
        }
    }

    func testDashboardTooltipAndVoiceOverContainSafeFullDetailsOnly()
        throws
    {
        let reset = now.addingTimeInterval(3_600)
        let codexMetric = try providerMetric(
            .codex,
            fraction: 0.73,
            stableID: "raw-secret-codex-bucket-base64",
            resetAt: reset,
            durationMinutes: 300
        )
        let claudeMetric = try providerMetric(
            .claudeCode,
            fraction: 0.42,
            stableID: "raw-secret-claude-window",
            durationMinutes: 10_080
        )
        let google = try XCTUnwrap(ProviderSnapshot(
            providerID: .googleAntigravity,
            metrics: [],
            capturedAt: now,
            runtimePresence: .application(installed: true, running: true)
        ))
        let presentation = dashboardPresenter(
            states: [
                .googleAntigravity: .fresh(google),
                .codex: .fresh(try providerSnapshot(
                    .codex,
                    metrics: [codexMetric]
                )),
                .claudeCode: .stale(try providerSnapshot(
                    .claudeCode,
                    metrics: [claudeMetric]
                )),
                .kimiCode: .failed(code: .connectorFailed),
            ],
            codexState: try codexRateState(
                remainingFraction: 0.73,
                resetAt: reset
            ),
            settings: settings(
                language: .english,
                enabledProviders: ProviderID.allCases
            )
        )

        for value in [presentation.toolTip, presentation.accessibilityLabel] {
            assertOrdered(
                ["Google Antigravity", "Codex", "Claude Code", "Kimi Code"],
                in: value
            )
            XCTAssertTrue(value.contains("5-hour window"))
            XCTAssertTrue(value.contains("73% remaining"))
            XCTAssertTrue(value.contains("1 hour"))
            XCTAssertTrue(value.contains("Weekly window"))
            XCTAssertTrue(value.contains("stale"))
            XCTAssertTrue(value.contains("failed"))
            XCTAssertFalse(value.contains("raw-secret"))
            XCTAssertFalse(value.contains("connector-failed"))
        }
    }

    func testDashboardUsedModeChangesValueAndExplainsMeaning() throws {
        let metric = try providerMetric(
            .codex,
            fraction: 0.73,
            stableID: "used-mode",
            durationMinutes: 300
        )
        let presentation = dashboardPresenter(
            states: [
                .codex: .fresh(try providerSnapshot(
                    .codex,
                    metrics: [metric]
                )),
                .claudeCode: .unsupported,
            ],
            codexState: try codexRateState(remainingFraction: 0.73),
            settings: settings(
                language: .english,
                percentageMode: .used,
                enabledProviders: [.codex, .claudeCode]
            )
        )

        XCTAssertEqual(presentation.title, "Cx27% · Cl—")
        XCTAssertTrue(presentation.toolTip.contains("27% used"))
        XCTAssertFalse(presentation.toolTip.contains("used-mode"))
    }

    private func presenter(
        state: CapabilityState<RateLimitCatalog>,
        settings: AppSettings
    ) -> StatusItemPresentation {
        StatusItemPresenter().makePresentation(
            catalog: state,
            settings: settings,
            now: now,
            locale: Locale(identifier: "en_US")
        )
    }

    private func dashboardPresenter(
        states: [ProviderID: ProviderPresentationState],
        codexState: CapabilityState<RateLimitCatalog> = .loading,
        settings: AppSettings
    ) -> StatusItemPresentation {
        StatusItemPresenter().makePresentation(
            dashboardStates: states,
            codexCatalog: codexState,
            settings: settings,
            now: now,
            locale: Locale(identifier: "en_US")
        )
    }

    private func codexRateState(
        remainingFraction: Double,
        durationMinutes: Int64? = 300,
        resetAt: Date? = nil
    ) throws -> CapabilityState<RateLimitCatalog> {
        let usedPercent = Int(((1 - remainingFraction) * 100).rounded())
        let catalog = try makeCatalog([
            window(
                .primary,
                durationMinutes,
                used: usedPercent,
                resetsAt: resetAt.map {
                    Int64($0.timeIntervalSince1970)
                }
            ),
        ])
        return .fresh(catalog, now)
    }

    private func settings(
        language: AppLanguage,
        percentageMode: PercentageMode = .remaining,
        mode: MenuBarMode = .automatic,
        enabledProviders: [ProviderID] = [.codex],
        preferences: [ProviderID: PrimaryMetricPreference] = [:],
        statusItemDisplayMode: StatusItemDisplayMode = .automatic,
        primaryStatusItemProvider: ProviderID? = nil
    ) -> AppSettings {
        var result = AppSettings.defaults
        result.language = language
        result.percentageMode = percentageMode
        result.menuBarMode = mode
        result.enabledProviders = enabledProviders
        result.primaryMetricPreferences = preferences
        result.statusItemDisplayMode = statusItemDisplayMode
        result.primaryStatusItemProvider = primaryStatusItemProvider
        return result
    }

    private func localizedProviderName(
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

    private func titleContainsCompactProvider(
        _ providerID: ProviderID,
        in title: String
    ) -> Bool {
        title.split { character in
            character == " " || character == "·"
        }.contains { segment in
            segment.hasPrefix(providerID.compactIdentifier)
        }
    }

    private func providerMetric(
        _ providerID: ProviderID,
        fraction: Double,
        stableID: String,
        resetAt: Date? = nil,
        durationMinutes: Int64? = 300
    ) throws -> ProviderMetric {
        let key = try XCTUnwrap(
            ProviderMetricKey(providerID: providerID, stableID: stableID)
        )
        return try XCTUnwrap(ProviderMetric(
            providerID: providerID,
            metricKey: key,
            remainingFraction: fraction,
            resetAt: resetAt,
            durationMinutes: durationMinutes
        ))
    }

    private func providerSnapshot(
        _ providerID: ProviderID,
        fraction: Double,
        stableID: String,
        durationMinutes: Int64? = 300
    ) throws -> ProviderSnapshot {
        try providerSnapshot(
            providerID,
            metrics: [providerMetric(
                providerID,
                fraction: fraction,
                stableID: stableID,
                durationMinutes: durationMinutes
            )]
        )
    }

    private func providerSnapshot(
        _ providerID: ProviderID,
        metrics: [ProviderMetric]
    ) throws -> ProviderSnapshot {
        try XCTUnwrap(ProviderSnapshot(
            providerID: providerID,
            metrics: metrics,
            capturedAt: now
        ))
    }

    private func assertOrdered(
        _ needles: [String],
        in value: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var lowerBound = value.startIndex
        for needle in needles {
            guard let range = value.range(
                of: needle,
                range: lowerBound..<value.endIndex
            ) else {
                return XCTFail(
                    "Missing ordered value \(needle) in \(value)",
                    file: file,
                    line: line
                )
            }
            lowerBound = range.upperBound
        }
    }

    private func makeCatalog(
        _ windows: [RateLimitWindow],
        bucketKey: String = "codex"
    ) throws -> RateLimitCatalog {
        let bucket = RateLimitBucket(bucketKey: bucketKey, windows: windows)
        return RateLimitCatalog(
            rateLimitsByLimitId: [bucketKey: bucket],
            legacyBucket: RateLimitBucket(
                bucketKey: RateLimitCatalog.legacyBucketKey,
                windows: []
            )
        )
    }

    private func automaticCodexSelectionFixture() throws -> (
        catalog: RateLimitCatalog,
        state: ProviderPresentationState,
        distractingPreference: PrimaryMetricPreference
    ) {
        let codexBucket = RateLimitBucket(
            bucketKey: "codex",
            windows: [
                try window(.primary, 300, used: 27),
                try window(.secondary, 10_080, used: 58),
            ]
        )
        let distractingWindow = try window(
            .primary,
            60,
            used: 1,
            bucketKey: "alpha"
        )
        let catalog = RateLimitCatalog(
            rateLimitsByLimitId: [
                "alpha": RateLimitBucket(
                    bucketKey: "alpha",
                    windows: [distractingWindow]
                ),
                "codex": codexBucket,
            ],
            legacyBucket: RateLimitBucket(
                bucketKey: RateLimitCatalog.legacyBucketKey,
                windows: []
            )
        )
        let metricKey = try XCTUnwrap(
            ProviderMetricKey.codexRateLimitWindow(
                distractingWindow.identity
            )
        )
        let preference = try XCTUnwrap(
            PrimaryMetricPreference(
                providerID: .codex,
                metricKey: metricKey
            )
        )
        let state = CodexProviderSnapshotMapper.map(
            rateState: .fresh(catalog, now),
            usageState: .unsupported,
            accountState: .unsupported
        )
        return (catalog, state, preference)
    }

    private func window(
        _ slot: SourceSlot,
        _ duration: Int64?,
        used: Int,
        resetsAt: Int64? = nil,
        bucketKey: String = "codex"
    ) throws -> RateLimitWindow {
        try RateLimitWindow(
            identity: WindowIdentity(
                bucketKey: bucketKey,
                sourceSlot: slot,
                durationMinutes: duration
            ),
            usedPercent: used,
            resetsAt: resetsAt
        )
    }

    private func identity(_ slot: SourceSlot, _ duration: Int64?) -> WindowIdentity {
        WindowIdentity(
            bucketKey: "codex",
            sourceSlot: slot,
            durationMinutes: duration
        )
    }
}
