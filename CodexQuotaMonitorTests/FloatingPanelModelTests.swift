import AppKit
import Foundation
import XCTest
@testable import CodexQuotaMonitor

@MainActor
final class FloatingPanelModelTests: XCTestCase {
    func testCompactDisplayProfileShowsOnlyFiveHourWindowAndKeepsFreshness() {
        let quota = Self.quota(
            primary: (remaining: 80, duration: 10_080),
            secondary: (remaining: 40, duration: 300)
        )

        let presentation = CardDisplayProfilePresenter().makePresentation(
            profile: .compact,
            quota: quota
        )

        XCTAssertFalse(presentation.showsPlan)
        XCTAssertEqual(presentation.visibleWindowRoles, [.secondary])
        XCTAssertFalse(presentation.showsTokenActivity)
        XCTAssertTrue(presentation.showsFreshness)
    }

    func testBalancedDisplayProfileShowsPlanBothWindowsAndFreshness() {
        let quota = Self.quota(
            primary: (remaining: 80, duration: 300),
            secondary: (remaining: 40, duration: 10_080)
        )

        let presentation = CardDisplayProfilePresenter().makePresentation(
            profile: .balanced,
            quota: quota
        )

        XCTAssertTrue(presentation.showsPlan)
        XCTAssertEqual(presentation.visibleWindowRoles, [.primary, .secondary])
        XCTAssertFalse(presentation.showsTokenActivity)
        XCTAssertTrue(presentation.showsFreshness)
    }

    func testFullDisplayProfileAddsTokenActivityWithoutHidingFreshness() {
        let quota = Self.quota(
            primary: (remaining: 80, duration: 300),
            secondary: (remaining: 40, duration: 10_080)
        )

        let presentation = CardDisplayProfilePresenter().makePresentation(
            profile: .full,
            quota: quota
        )

        XCTAssertTrue(presentation.showsPlan)
        XCTAssertEqual(presentation.visibleWindowRoles, [.primary, .secondary])
        XCTAssertTrue(presentation.showsTokenActivity)
        XCTAssertTrue(presentation.showsFreshness)
    }

    func testCompactAdditionalBucketsExcludeSelectedAndUseOneDeterministicWindow()
        throws
    {
        let catalog = try Self.additionalBucketCatalog()
        let presenter = CardAdditionalBucketsPresenter(text: Self.keyText)

        let presentation = presenter.makePresentation(
            profile: .compact,
            catalog: catalog
        )

        XCTAssertEqual(presentation.map(\.label), ["Alpha", "zeta"])
        XCTAssertEqual(
            presentation.map { $0.windows.map(\.role) },
            [[.secondary], [.secondary]]
        )
        XCTAssertEqual(
            presentation.map { $0.windows.map(\.window.duration) },
            [[.fiveHours], [.weekly]]
        )

        let reordered = RateLimitCatalog(
            rateLimitsByLimitId: [
                "alpha": catalog.rateLimitsByLimitId["alpha"]!,
                "codex": catalog.rateLimitsByLimitId["codex"]!,
                "zeta": catalog.rateLimitsByLimitId["zeta"]!,
            ],
            legacyBucket: catalog.legacyBucket
        )
        XCTAssertEqual(
            presenter.makePresentation(profile: .compact, catalog: reordered),
            presentation
        )
    }

    func testBalancedAndFullAdditionalBucketsKeepEveryActualWindowWithoutSyntheticZero()
        throws
    {
        let base = try Self.additionalBucketCatalog()
        let empty = RateLimitBucket(
            bucketKey: " \n\t",
            limitName: "\u{0000}\n",
            windows: []
        )
        let catalog = RateLimitCatalog(
            rateLimitsByLimitId: base.rateLimitsByLimitId.merging(
                ["empty": empty],
                uniquingKeysWith: { current, _ in current }
            ),
            legacyBucket: base.legacyBucket
        )
        let presenter = CardAdditionalBucketsPresenter(text: Self.keyText)

        let balanced = presenter.makePresentation(
            profile: .balanced,
            catalog: catalog
        )
        let full = presenter.makePresentation(
            profile: .full,
            catalog: catalog
        )

        XCTAssertEqual(full, balanced)
        XCTAssertEqual(
            balanced.map(\.label),
            ["Alpha", "zeta"]
        )
        XCTAssertEqual(
            balanced[0].windows.map(\.role),
            [.secondary, .primary]
        )
        XCTAssertEqual(
            balanced[0].windows.map(\.window.duration),
            [.fiveHours, .custom(minutes: 360)]
        )
        XCTAssertEqual(
            balanced[1].windows.map(\.window.duration),
            [.weekly, .custom(minutes: nil)]
        )
        XCTAssertFalse(
            balanced.contains { $0.label == "settings.bucket.unnamed" }
        )
        XCTAssertFalse(
            balanced.flatMap(\.windows).contains {
                $0.window.usedPercent == 0
            }
        )
    }

    func testSafeBucketLabelPrefersNameStripsControlsAndBoundsOutput() {
        let presenter = SafeBucketLabelPresenter(text: Self.keyText)
        let longName = "\u{0000}" + String(repeating: "A", count: 40) + "\n"

        XCTAssertEqual(
            presenter.label(bucketKey: "fallback", limitName: longName),
            String(repeating: "A", count: 32) + "…"
        )
        XCTAssertEqual(
            presenter.label(
                bucketKey: "  safe\t-key  ",
                limitName: "\n\u{0000}"
            ),
            "safe-key"
        )
        XCTAssertEqual(
            presenter.label(bucketKey: " \n", limitName: nil),
            "settings.bucket.unnamed"
        )
    }

    func testCardSourceRendersAdditionalCatalogBucketsInsideScrollableContent()
        throws
    {
        let source = try productionSource("UI/CardView.swift")

        XCTAssertTrue(source.contains("ScrollView"))
        XCTAssertTrue(source.contains("CardAdditionalBucketsPresenter"))
        XCTAssertTrue(source.contains("viewModel.rateCatalog"))
        XCTAssertTrue(
            source.contains(
                ".accessibilityIdentifier(\"quota.card.additional-buckets\")"
            )
        )
        XCTAssertTrue(source.contains("additionalBucketContent"))
    }

    func testCardHeaderBoundsLongTitleAndKeepsIconOnlyQuitSemantics()
        throws
    {
        let source = try productionSource("UI/CardView.swift")
        let titleStart = try XCTUnwrap(
            source.range(of: "Text(text.text(.cardTitle))")
        )
        let cueStart = try XCTUnwrap(
            source.range(
                of: "Image(systemName: currentCue.symbol.rawValue)",
                range: titleStart.upperBound..<source.endIndex
            )
        )
        let titleSegment = String(
            source[titleStart.lowerBound..<cueStart.lowerBound]
        )

        XCTAssertTrue(titleSegment.contains(".lineLimit(1)"))
        XCTAssertTrue(titleSegment.contains(".minimumScaleFactor("))
        XCTAssertTrue(titleSegment.contains(".layoutPriority(1)"))

        let quitStart = try XCTUnwrap(
            source.range(of: "Button(action: quit)")
        )
        let quitSegment = String(source[quitStart.lowerBound...])
        XCTAssertTrue(quitSegment.contains("Image(systemName: \"power\")"))
        XCTAssertTrue(quitSegment.contains(".help(text.text(.actionQuit))"))
        XCTAssertTrue(
            quitSegment.contains(
                ".accessibilityLabel(text.text(.actionQuit))"
            )
        )
        XCTAssertTrue(
            quitSegment.contains(
                ".accessibilityIdentifier(\"quota.card.quit\")"
            )
        )
        XCTAssertTrue(
            quitSegment.contains(
                ".keyboardShortcut(\"q\", modifiers: .command)"
            )
        )
        XCTAssertFalse(
            source.contains("Button(text.text(.actionQuit), action: quit)")
        )
    }

    func testCompactDisplayProfileUsesDeterministicFallbackWithoutFiveHourWindow() {
        let quota = Self.quota(
            primary: (remaining: 80, duration: 10_080),
            secondary: (remaining: 40, duration: 360)
        )

        XCTAssertEqual(
            CardDisplayProfilePresenter().makePresentation(
                profile: .compact,
                quota: quota
            ).visibleWindowRoles,
            [.primary]
        )
    }

    func testCardWindowPercentagePresentationKeepsValueProgressAndAXInMode() {
        let presenter = QuotaWindowPercentagePresenter(
            text: LocalizedTextProvider(
                language: .english,
                systemLocale: Locale(identifier: "en_US")
            )
        )
        let window = Self.window(duration: 300)

        let remaining = presenter.makePresentation(
            mode: .remaining,
            role: "Primary",
            window: window
        )
        XCTAssertEqual(remaining?.percent, 75)
        XCTAssertEqual(remaining?.progressValue, 75)
        XCTAssertEqual(remaining?.displayText, "75% remaining")
        XCTAssertEqual(
            remaining?.accessibilityValue,
            "Primary, 75 percent remaining"
        )

        let used = presenter.makePresentation(
            mode: .used,
            role: "Primary",
            window: window
        )
        XCTAssertEqual(used?.percent, 25)
        XCTAssertEqual(used?.progressValue, 25)
        XCTAssertEqual(used?.displayText, "25% used")
        XCTAssertEqual(
            used?.accessibilityValue,
            "Primary, 25 percent used"
        )
    }

    func testCardWindowPercentagePresentationDoesNotInventUnknownAsZero() {
        let presenter = QuotaWindowPercentagePresenter(
            text: LocalizedTextProvider(
                language: .english,
                systemLocale: Locale(identifier: "en_US")
            )
        )

        XCTAssertNil(
            presenter.makePresentation(
                mode: .used,
                role: "Primary",
                window: nil
            )
        )
    }

    func testCardTokenActivityFreshnessKeepsUsageLaneStatesDistinct() {
        let text = LocalizedTextProvider(locale: .english) { key, _ in
            key.rawValue
        }
        let presenter = CardTokenActivityFreshnessPresenter(text: text)
        let snapshot = Self.tokenActivitySnapshot()
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertEqual(
            presenter.makePresentation(usageState: .loading),
            CardTokenActivityFreshnessPresentation(
                state: .loading,
                text: "common.state.loading"
            )
        )
        XCTAssertEqual(
            presenter.makePresentation(usageState: .fresh(snapshot, now)),
            CardTokenActivityFreshnessPresentation(
                state: .fresh,
                text: "common.state.fresh"
            )
        )
        XCTAssertEqual(
            presenter.makePresentation(
                usageState: .stale(snapshot, now, .stale)
            ),
            CardTokenActivityFreshnessPresentation(
                state: .stale,
                text: "common.state.stale"
            )
        )
        XCTAssertEqual(
            presenter.makePresentation(usageState: .unsupported),
            CardTokenActivityFreshnessPresentation(
                state: .unsupported,
                text: "common.state.unsupported"
            )
        )
        XCTAssertEqual(
            presenter.makePresentation(
                usageState: .unavailable(.temporaryBackend)
            ),
            CardTokenActivityFreshnessPresentation(
                state: .unavailable,
                text: "common.state.unavailable"
            )
        )
    }

    func testCardTokenAccessibilityRowUsesLocalizedTotalOnlySentenceWithoutZero()
    {
        let text = LocalizedTextProvider(locale: .english) { key, _ in
            switch key {
            case .activityTotalOnlyAccessibilityRow:
                "ROW[%1$@|%2$@=%3$@]"
            default:
                key.rawValue
            }
        }
        let period = SettingsTokenPeriodPresentation(
            title: "PERIOD",
            input: SettingsTokenMetricPresentation(
                state: .notReturned,
                text: "NOT RETURNED"
            ),
            output: SettingsTokenMetricPresentation(
                state: .notReturned,
                text: "NOT RETURNED"
            ),
            total: SettingsTokenMetricPresentation(
                state: .unavailable,
                text: "UNAVAILABLE"
            )
        )

        let label = TokenActivityTotalOnlyAccessibilityText(text: text).rowLabel(
            period,
            totalTitle: "TOTAL"
        )

        XCTAssertEqual(label, "ROW[PERIOD|TOTAL=UNAVAILABLE]")
        XCTAssertFalse(label.contains("INPUT"))
        XCTAssertFalse(label.contains("OUTPUT"))
        XCTAssertFalse(label.contains("=0"))
    }

    func testCardTokenGridRendersPeriodAndTotalOnlyAndKeepsMissingDataNote()
        throws
    {
        let source = try productionSource("UI/CardView.swift")
        let start = try XCTUnwrap(
            source.range(of: "private struct CardTokenActivityView")
        )
        let segment = String(source[start.lowerBound...])

        XCTAssertFalse(segment.contains("Text(presentation.inputTitle)"))
        XCTAssertFalse(segment.contains("Text(presentation.outputTitle)"))
        XCTAssertFalse(segment.contains("tokenMetric(period.input)"))
        XCTAssertFalse(segment.contains("tokenMetric(period.output)"))
        XCTAssertTrue(segment.contains("Text(presentation.totalTitle)"))
        XCTAssertTrue(segment.contains("tokenMetric(period.total)"))
        XCTAssertTrue(segment.contains("Text(presentation.missingDataNote)"))
        XCTAssertTrue(
            segment.contains("TokenActivityTotalOnlyAccessibilityText")
        )
    }

    func testHealthThresholdsAtFiftyOneFiftyTenAndNinePercent() {
        XCTAssertEqual(Self.orb(remaining: 51).health, .healthy)
        XCTAssertEqual(Self.orb(remaining: 50).health, .warning)
        XCTAssertEqual(Self.orb(remaining: 10).health, .warning)
        XCTAssertEqual(Self.orb(remaining: 9).health, .critical)
    }

    func testHealthUsesLowestRemainingAcrossAllWindowsIncludingCustomDuration() {
        let quota = Self.quota(
            primary: (remaining: 80, duration: 300),
            secondary: (remaining: 9, duration: 360)
        )

        let presentation = OrbPresentation(state: .loaded(quota))

        XCTAssertEqual(presentation.health, .critical)
        XCTAssertEqual(presentation.indicator, .none)
    }

    func testLoadingIsGrayWithLoadingIndicator() {
        XCTAssertEqual(
            OrbPresentation(state: .loading),
            OrbPresentation(health: .neutral, indicator: .loading)
        )
    }

    func testStaleKeepsHealthAndAddsOrangeIndicator() {
        let quota = Self.quota(primary: (remaining: 51, duration: 300))

        XCTAssertEqual(
            OrbPresentation(state: .stale(quota, Date(timeIntervalSince1970: 1))),
            OrbPresentation(health: .healthy, indicator: .stale)
        )
    }

    func testUnavailableIsGrayWithRedWarningIndicator() {
        XCTAssertEqual(
            OrbPresentation(state: .unavailable(.binaryNotFound)),
            OrbPresentation(health: .neutral, indicator: .unavailable)
        )
    }

    func testClampKeepsFrameInsideNegativeCoordinateVisibleFrame() {
        let visibleFrame = CGRect(x: -1_920, y: -100, width: 1_920, height: 1_080)
        let offscreen = CGRect(x: -100, y: 900, width: 272, height: 340)

        let clamped = PanelFrameGeometry.clamped(frame: offscreen, to: visibleFrame)

        XCTAssertEqual(clamped.maxX, visibleFrame.maxX)
        XCTAssertEqual(clamped.maxY, visibleFrame.maxY)
        XCTAssertTrue(visibleFrame.contains(clamped))
    }

    func testClampShrinksOversizedFrameWhenScreenBecomesSmaller() {
        let visibleFrame = CGRect(x: -100, y: -50, width: 200, height: 120)
        let oversized = CGRect(x: -500, y: -500, width: 272, height: 340)

        let clamped = PanelFrameGeometry.clamped(frame: oversized, to: visibleFrame)

        XCTAssertEqual(clamped, visibleFrame)
    }

    func testInitialFrameUsesSixteenPointUpperRightInset() {
        let visibleFrame = CGRect(x: -1_920, y: 0, width: 1_920, height: 1_080)

        let frame = PanelFrameGeometry.initialFrame(
            size: CGSize(width: 48, height: 48),
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(frame.maxX, visibleFrame.maxX - 16)
        XCTAssertEqual(frame.maxY, visibleFrame.maxY - 16)
    }

    func testPanelLayoutResolverUsesExactOneTwoThreeAndWideFourColumnSizes() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let cases: [(count: Int, columns: Int, rows: Int, size: CGSize)] = [
            (0, 1, 1, CGSize(width: 272, height: 340)),
            (1, 1, 1, CGSize(width: 272, height: 340)),
            (2, 2, 1, CGSize(width: 520, height: 340)),
            (3, 3, 1, CGSize(width: 768, height: 340)),
            (4, 4, 1, CGSize(width: 1_016, height: 340)),
        ]

        for item in cases {
            let layout = PanelLayoutResolver.resolve(
                providerCount: item.count,
                visibleFrame: visibleFrame
            )

            XCTAssertEqual(layout.providerCount, max(0, item.count))
            XCTAssertEqual(layout.columns, item.columns)
            XCTAssertEqual(layout.rows, item.rows)
            XCTAssertEqual(layout.size, item.size)
            XCTAssertFalse(layout.isConstrained)
        }
    }

    func testPanelLayoutResolverUsesTwoByTwoForFourProvidersOnNarrowScreen() {
        let layout = PanelLayoutResolver.resolve(
            providerCount: 4,
            visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 800)
        )

        XCTAssertEqual(layout.columns, 2)
        XCTAssertEqual(layout.rows, 2)
        XCTAssertEqual(layout.size, CGSize(width: 520, height: 620))
        XCTAssertFalse(layout.isConstrained)
    }

    func testPanelLayoutResolverConstrainsTinyScreenInsideSixteenPointMargins() {
        let layout = PanelLayoutResolver.resolve(
            providerCount: 4,
            visibleFrame: CGRect(x: -300, y: -100, width: 200, height: 120)
        )

        XCTAssertEqual(layout.columns, 2)
        XCTAssertEqual(layout.rows, 2)
        XCTAssertEqual(layout.size, CGSize(width: 168, height: 88))
        XCTAssertTrue(layout.isConstrained)
        XCTAssertTrue(layout.usesVerticalSafetyScroll)
    }

    func testAllProviderSelectionsResolveAcrossWideMidAndTinyScreens() {
        let providerOrder: [ProviderID] = [
            .claudeCode,
            .codex,
            .kimiCode,
            .googleAntigravity,
        ]
        let screens: [(name: String, frame: CGRect)] = [
            ("wide", CGRect(x: 0, y: 0, width: 1_440, height: 900)),
            ("mid", CGRect(x: -800, y: 0, width: 800, height: 800)),
            ("tiny", CGRect(x: 0, y: -120, width: 200, height: 120)),
        ]

        for mask in 0..<(1 << providerOrder.count) {
            let enabled = providerOrder.enumerated().compactMap {
                index, providerID in
                mask & (1 << index) == 0 ? nil : providerID
            }
            for screen in screens {
                let layout = PanelLayoutResolver.resolve(
                    providerCount: enabled.count,
                    visibleFrame: screen.frame
                )
                let expectedGrid = expectedGrid(
                    providerCount: enabled.count,
                    screenName: screen.name
                )
                let preferredSize = expectedPreferredPanelSize(
                    providerCount: enabled.count,
                    screenName: screen.name
                )
                let availableSize = CGSize(
                    width: max(0, screen.frame.width - 32),
                    height: max(0, screen.frame.height - 32)
                )
                let expectedSize = CGSize(
                    width: min(preferredSize.width, availableSize.width),
                    height: min(preferredSize.height, availableSize.height)
                )
                let context = "mask=\(mask), providers=\(enabled), screen=\(screen.name)"

                XCTAssertEqual(layout.providerCount, enabled.count, context)
                XCTAssertEqual(layout.columns, expectedGrid.columns, context)
                XCTAssertEqual(layout.rows, expectedGrid.rows, context)
                XCTAssertEqual(layout.size, expectedSize, context)
                XCTAssertEqual(
                    layout.isConstrained,
                    expectedSize != preferredSize,
                    context
                )
                XCTAssertGreaterThanOrEqual(layout.size.width, 0, context)
                XCTAssertGreaterThanOrEqual(layout.size.height, 0, context)
            }
        }
    }

    func testDashboardLayoutMatrixPreservesOrderAndScrollIndicatorPolicy() {
        let providerOrder: [ProviderID] = [
            .claudeCode,
            .codex,
            .kimiCode,
            .googleAntigravity,
        ]
        let screens: [(name: String, frame: CGRect)] = [
            ("wide", CGRect(x: 0, y: 0, width: 1_440, height: 900)),
            ("mid", CGRect(x: 0, y: 0, width: 800, height: 800)),
            ("tiny", CGRect(x: 0, y: 0, width: 200, height: 120)),
        ]

        for mask in 0..<(1 << providerOrder.count) {
            let enabled = providerOrder.enumerated().compactMap {
                index, providerID in
                mask & (1 << index) == 0 ? nil : providerID
            }
            for screen in screens {
                let panelLayout = PanelLayoutResolver.resolve(
                    providerCount: enabled.count,
                    visibleFrame: screen.frame
                )
                for profile in DisplayProfile.allCases {
                    for accessibility in [false, true] {
                        let context = "mask=\(mask), providers=\(enabled), screen=\(screen.name), profile=\(profile), accessibility=\(accessibility)"
                        let presentation = CardDashboardLayoutPresenter()
                            .makePresentation(
                                enabledProviders: enabled,
                                panelLayout: panelLayout,
                                displayProfile: profile,
                                usesAccessibilityTextSize: accessibility
                            )

                        XCTAssertEqual(
                            presentation.orderedProviderIDs,
                            enabled,
                            context
                        )
                        XCTAssertEqual(
                            Set(presentation.orderedProviderIDs).count,
                            enabled.count,
                            context
                        )
                        XCTAssertEqual(
                            presentation.columns,
                            panelLayout.columns,
                            context
                        )
                        XCTAssertEqual(
                            presentation.sharedHeaderCount,
                            1,
                            context
                        )
                        XCTAssertTrue(
                            presentation.usesVerticalSafetyScroll,
                            context
                        )
                        XCTAssertEqual(
                            presentation.showsVerticalScrollIndicators,
                            profile == .full
                                || accessibility
                                || panelLayout.isConstrained,
                            context
                        )
                    }
                }
            }
        }
    }

    func testPreferredScreenUsesLargestCurrentFrameIntersectionIncludingNegativeCoordinates()
        throws
    {
        let negative = PanelScreenDescriptor(
            visibleFrame: CGRect(x: -1_200, y: 0, width: 1_200, height: 900),
            isMain: false
        )
        let main = PanelScreenDescriptor(
            visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            isMain: true
        )

        let selected = try XCTUnwrap(PanelFrameGeometry.preferredScreen(
            for: CGRect(x: -900, y: 100, width: 520, height: 340),
            screens: [main, negative]
        ))

        XCTAssertEqual(selected, negative)
    }

    func testPreferredScreenFallsBackToMainWhenFrameIntersectsNoScreen() throws {
        let first = PanelScreenDescriptor(
            visibleFrame: CGRect(x: -1_200, y: 0, width: 1_200, height: 900),
            isMain: false
        )
        let main = PanelScreenDescriptor(
            visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            isMain: true
        )

        let selected = try XCTUnwrap(PanelFrameGeometry.preferredScreen(
            for: CGRect(x: 8_000, y: 8_000, width: 272, height: 340),
            screens: [first, main]
        ))

        XCTAssertEqual(selected, main)
    }

    func testDashboardGridPolicyKeepsProviderOrderOneHeaderAndScrollSafety() {
        let providers: [ProviderID] = [
            .claudeCode,
            .codex,
            .kimiCode,
        ]
        let layout = PanelLayoutResolver.resolve(
            providerCount: providers.count,
            visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900)
        )

        let balanced = CardDashboardLayoutPresenter().makePresentation(
            enabledProviders: providers,
            panelLayout: layout,
            displayProfile: .balanced,
            usesAccessibilityTextSize: false
        )
        XCTAssertEqual(balanced.orderedProviderIDs, providers)
        XCTAssertEqual(balanced.columns, 3)
        XCTAssertEqual(balanced.sharedHeaderCount, 1)
        XCTAssertTrue(balanced.usesVerticalSafetyScroll)
        XCTAssertFalse(balanced.showsVerticalScrollIndicators)

        let full = CardDashboardLayoutPresenter().makePresentation(
            enabledProviders: providers,
            panelLayout: layout,
            displayProfile: .full,
            usesAccessibilityTextSize: false
        )
        XCTAssertTrue(full.showsVerticalScrollIndicators)

        let accessible = CardDashboardLayoutPresenter().makePresentation(
            enabledProviders: providers,
            panelLayout: layout,
            displayProfile: .balanced,
            usesAccessibilityTextSize: true
        )
        XCTAssertTrue(accessible.showsVerticalScrollIndicators)
    }

    func testAppLocalizationRuntimeModelUpdatesProviderAndSwiftUILocale() {
        let model = AppLocalizationRuntimeModel(
            language: .english,
            systemLocale: Locale(identifier: "de_DE")
        )

        XCTAssertEqual(model.text.text(.orbShowDetails), "Show Codex quota details")
        XCTAssertEqual(model.locale.identifier, "en")

        model.language = .japanese

        XCTAssertEqual(model.text.text(.orbShowDetails), "Codex 使用量の詳細を表示")
        XCTAssertEqual(model.locale.identifier, "ja")
    }

    func testDisplayTextDoesNotInventPlanOrDurationLabels() {
        let english = LocalizedTextProvider(
            language: .english,
            systemLocale: Locale(identifier: "en_US")
        )
        let display = QuotaDisplayText(text: english)

        XCTAssertEqual(QuotaDisplayText.plan(nil), "—")
        XCTAssertEqual(QuotaDisplayText.plan(.unknown("future")), "—")
        XCTAssertEqual(QuotaDisplayText.plan(.plus), "Plus")

        XCTAssertEqual(
            display.windowTitle(
                english.text(.cardPrimaryWindow),
                window: Self.window(duration: 300)
            ),
            "Primary (5h)"
        )
        XCTAssertEqual(
            display.windowTitle(
                english.text(.cardSecondaryWindow),
                window: Self.window(duration: 10_080)
            ),
            "Secondary (Week)"
        )
        XCTAssertEqual(
            display.windowTitle(
                english.text(.cardPrimaryWindow),
                window: Self.window(duration: 360)
            ),
            "Window (6h)"
        )
        XCTAssertEqual(
            display.windowTitle(
                english.text(.cardPrimaryWindow),
                window: Self.window(duration: 90)
            ),
            "Window (90m)"
        )
        XCTAssertEqual(
            display.windowTitle(
                english.text(.cardPrimaryWindow),
                window: Self.window(duration: nil)
            ),
            "Primary"
        )
    }

    func testAccessibilityTextUsesSelectedLanguageAndWholeQuotaSentence() {
        let quota = Self.quota(primary: (remaining: 72, duration: 300))
        let english = LocalizedTextProvider(
            language: .english,
            systemLocale: Locale(identifier: "en_US")
        )
        let japanese = LocalizedTextProvider(
            language: .japanese,
            systemLocale: Locale(identifier: "en_US")
        )
        let englishCopy = QuotaAccessibilityText(text: english)
        let japaneseCopy = QuotaAccessibilityText(text: japanese)

        XCTAssertEqual(
            englishCopy.orbActionLabel,
            "Show Codex quota details"
        )
        XCTAssertEqual(
            englishCopy.orbValue(for: .loaded(quota)),
            "72 percent minimum remaining"
        )
        XCTAssertEqual(
            englishCopy.windowAccessibilityValue(
                role: english.text(.cardPrimaryWindow),
                remainingPercent: 72
            ),
            "Primary, 72 percent remaining"
        )
        XCTAssertEqual(japaneseCopy.orbActionLabel, "Codex 使用量の詳細を表示")
    }

    func testOrbAccessibilityUsesSelectedUsedModeForLoadedAndStaleState() {
        let quota = Self.quota(
            primary: (remaining: 72, duration: 300),
            secondary: (remaining: 48, duration: 10_080)
        )
        let text = LocalizedTextProvider(
            language: .english,
            systemLocale: Locale(identifier: "en_US")
        )
        let accessibility = QuotaAccessibilityText(
            text: text,
            percentageMode: .used
        )
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(
            accessibility.orbValue(for: .loaded(quota)),
            "52% used"
        )
        XCTAssertEqual(
            accessibility.orbValue(for: .stale(quota, now)),
            "52% used, stale"
        )
    }

    func testWholeSentenceWrappersUseInjectedLookupInsteadOfConcatenation() {
        let text = LocalizedTextProvider(locale: .english) { key, _ in
            switch key {
            case .cardWindowTitle: "CARD[%2$@|%1$@]"
            case .statusCompactFiveHours: "DURATION"
            case .quotaResetIn: "RESET[%@]"
            case .orbAccessibilityMinimumRemaining: "MIN[%lld]"
            case .orbAccessibilityStaleValue: "STALE[%@]"
            case .commonLoading: "LOADING"
            case .commonUnavailable: "UNAVAILABLE"
            default: key.rawValue
            }
        }
        let display = QuotaDisplayText(text: text)
        let accessibility = QuotaAccessibilityText(text: text)
        let quota = Self.quota(primary: (remaining: 72, duration: 300))
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(
            display.windowTitle("ROLE", window: Self.window(duration: 300)),
            "CARD[DURATION|ROLE]"
        )
        XCTAssertEqual(
            display.reset(now.addingTimeInterval(3_600), now: now),
            "RESET[1 hour]"
        )
        XCTAssertEqual(
            accessibility.orbValue(for: .stale(quota, now)),
            "STALE[MIN[72]]"
        )
        XCTAssertEqual(accessibility.orbValue(for: .loading), "LOADING")
        XCTAssertEqual(
            accessibility.orbValue(for: .unavailable(.binaryNotFound)),
            "UNAVAILABLE"
        )
    }

    func testPastResetDoesNotProduceNegativeCountdown() {
        let now = Date(timeIntervalSince1970: 1_000)
        let display = QuotaDisplayText(
            text: LocalizedTextProvider(
                language: .english,
                systemLocale: Locale(identifier: "en_US")
            )
        )

        XCTAssertNil(
            display.reset(
                Date(timeIntervalSince1970: 999),
                now: now
            )
        )
    }

    func testResetCountdownUsesSelectedLanguageAndLocaleAwareDuration() {
        let now = Date(timeIntervalSince1970: 1_000)
        let english = QuotaDisplayText(
            text: LocalizedTextProvider(
                language: .english,
                systemLocale: Locale(identifier: "de_DE")
            )
        )
        let german = QuotaDisplayText(
            text: LocalizedTextProvider(
                language: .german,
                systemLocale: Locale(identifier: "en_US")
            )
        )

        XCTAssertEqual(
            english.reset(now.addingTimeInterval(3_600), now: now),
            "Resets in 1 hour"
        )
        XCTAssertEqual(
            german.reset(now.addingTimeInterval(3_600), now: now),
            "Zurücksetzung in 1 Stunde"
        )
    }

    func testTerminationCoordinatorWaitsForCleanupAndRepliesOnlyOnce() async {
        let cleanupGate = ManualGateForPanelTests()
        let counter = AsyncCounter()
        let coordinator = ApplicationTerminationCoordinator()
        var replyCount = 0
        let cleanup: @Sendable () async -> Void = {
            await counter.increment()
            await cleanupGate.wait()
        }
        let reply: @MainActor () -> Void = {
            replyCount += 1
        }

        coordinator.begin(cleanup: cleanup, reply: reply)
        coordinator.begin(cleanup: cleanup, reply: reply)
        await waitUntil { await counter.value() == 1 }
        XCTAssertEqual(replyCount, 0)

        await cleanupGate.open()
        await waitUntil { replyCount == 1 }
        coordinator.begin(cleanup: cleanup, reply: reply)
        for _ in 0..<10 {
            await Task.yield()
        }

        let cleanupCount = await counter.value()
        XCTAssertEqual(cleanupCount, 1)
        XCTAssertEqual(replyCount, 1)
    }

#if DEBUG
    func testDebugFixtureParserRecognizesEveryState() {
        for fixture in DebugQuotaFixture.allCases {
            let selection = DebugFixtureConfiguration.resolve(
                arguments: [
                    "CodexQuotaMonitor",
                    "--quota-fixture",
                    fixture.rawValue,
                ],
                environment: [:]
            )

            XCTAssertEqual(selection, .fixture(fixture))
        }
    }

    func testDebugFixtureParserSupportsEnvironment() {
        XCTAssertEqual(
            DebugFixtureConfiguration.resolve(
                arguments: ["CodexQuotaMonitor"],
                environment: [
                    "CODEX_QUOTA_FIXTURE": "stale",
                ]
            ),
            .fixture(.stale)
        )
    }

    func testUnknownExplicitDebugFixtureFailsClosedInsteadOfUsingProduction() {
        XCTAssertEqual(
            DebugFixtureConfiguration.resolve(
                arguments: [
                    "CodexQuotaMonitor",
                    "--quota-fixture",
                    "unknown-state",
                ],
                environment: [:]
            ),
            .invalid
        )
    }

    func testNoDebugFixtureSelectsProduction() {
        XCTAssertEqual(
            DebugFixtureConfiguration.resolve(
                arguments: ["CodexQuotaMonitor"],
                environment: [:]
            ),
            .production
        )
    }

    func testDebugFixtureViewModelsAreDirectAndDeterministic() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertEqual(DebugQuotaFixture.loading.makeViewModel(now: now).state, .loading)
        XCTAssertEqual(
            Self.minimumRemaining(
                in: DebugQuotaFixture.loadedGreen.makeViewModel(now: now).state
            ),
            72
        )
        XCTAssertEqual(
            Self.minimumRemaining(
                in: DebugQuotaFixture.loadedYellow.makeViewModel(now: now).state
            ),
            50
        )
        XCTAssertEqual(
            Self.minimumRemaining(
                in: DebugQuotaFixture.loadedRed.makeViewModel(now: now).state
            ),
            9
        )

        let staleViewModel = DebugQuotaFixture.stale.makeViewModel(now: now)
        guard case let .stale(_, lastSuccess) = staleViewModel.state else {
            return XCTFail("Expected stale fixture")
        }
        XCTAssertEqual(lastSuccess, now.addingTimeInterval(-1_080))
        XCTAssertEqual(
            staleViewModel.lastUpdatedText(
                using: LocalizedTextProvider(
                    language: .english,
                    systemLocale: Locale(identifier: "en_US")
                )
            ),
            "18 minutes ago"
        )
        XCTAssertEqual(
            DebugQuotaFixture.unavailable.makeViewModel(now: now).state,
            .unavailable(.binaryNotFound)
        )
    }

    func testFloatingPanelControllerConfiguresRequiredPanelBehavior() {
        let viewModel = DebugQuotaFixture.loading.makeViewModel(
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let controller = FloatingPanelController(
            viewModel: viewModel,
            quit: {}
        )
        let panel = controller.panel

        XCTAssertEqual(panel.styleMask, .borderless)
        XCTAssertEqual(panel.level, .floating)
        XCTAssertFalse(panel.isOpaque)
        XCTAssertEqual(panel.backgroundColor, .clear)
        XCTAssertTrue(panel.isMovableByWindowBackground)
        XCTAssertFalse(panel.ignoresMouseEvents)
        XCTAssertEqual(
            panel.collectionBehavior,
            [.moveToActiveSpace, .fullScreenAuxiliary]
        )
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertEqual(panel.frame.size, FloatingPanelController.expandedSize)

        panel.close()
    }

    func testFloatingPanelControllerShowUsesExpandedCardSize() throws {
        try DebugVisibleSurfaceIsolationRequirement.requireCurrentProcessIsolation()
        let controller = FloatingPanelController(
            viewModel: DebugQuotaFixture.loading.makeViewModel(
                now: Date(timeIntervalSince1970: 1_800_000_000)
            ),
            quit: {}
        )

        controller.show()

        XCTAssertTrue(controller.panel.isVisible)
        XCTAssertEqual(
            controller.panel.frame.size,
            FloatingPanelController.expandedSize
        )
        controller.hide()
    }

    func testFloatingPanelControllerRetainsInjectedLocalizationRuntime() {
        let localizationModel = AppLocalizationRuntimeModel(
            language: .english,
            systemLocale: Locale(identifier: "en_US")
        )
        let controller = FloatingPanelController(
            viewModel: DebugQuotaFixture.loading.makeViewModel(),
            localizationModel: localizationModel,
            quit: {}
        )
        let retainedPanel = controller.panel

        XCTAssertIdentical(controller.localizationModel, localizationModel)
        localizationModel.language = .japanese
        XCTAssertIdentical(controller.panel, retainedPanel)
        XCTAssertEqual(
            controller.localizationModel.text.text(.actionRefresh),
            "更新"
        )
        controller.panel.close()
    }

    func testFloatingPanelRetainsLiveRuntimeForPersistedCustomTheme() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let settingsStore = SettingsStore(
            fileURL: root.appendingPathComponent("settings.json")
        )
        let themeStore = try ThemeStore(
            persistence: ThemeStoreDiskPersistence(
                rootDirectory: root.appendingPathComponent(
                    "ThemeStore",
                    isDirectory: true
                )
            )
        )
        let custom = try themeStore.duplicateBuiltIn(
            .cartoonIllustration,
            named: "自訂卡通"
        )
        var settings = settingsStore.settings
        settings.appearance.themeID = custom.id.uuidString
        try settingsStore.replace(with: settings).get()
        let service = try ProductionThemeSettingsService(
            themeStore: themeStore,
            settingsStore: settingsStore
        )

        let controller = FloatingPanelController(
            viewModel: DebugQuotaFixture.loading.makeViewModel(),
            themeID: custom.id.uuidString,
            themeRuntimeModel: service.runtimeModel,
            quit: {}
        )

        XCTAssertIdentical(
            controller.themeRuntimeModel,
            service.runtimeModel
        )
        XCTAssertEqual(
            controller.themeRuntimeModel?.currentTheme,
            custom
        )
        controller.panel.close()
    }

    func testFloatingPanelControllerHideAndShowReuseTheSamePanel() throws {
        try DebugVisibleSurfaceIsolationRequirement.requireCurrentProcessIsolation()
        let viewModel = DebugQuotaFixture.loading.makeViewModel(
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let controller = FloatingPanelController(
            viewModel: viewModel,
            quit: {}
        )
        let retainedPanel = controller.panel

        controller.show()
        controller.hide()
        controller.show()

        XCTAssertIdentical(controller.panel, retainedPanel)
        XCTAssertTrue(controller.panel.isVisible)
        XCTAssertFalse(controller.panel.isReleasedWhenClosed)
        controller.hide()
    }

    func testStandardCloseHidesBorderlessPanelAndReopenReusesIt() throws {
        try DebugVisibleSurfaceIsolationRequirement.requireCurrentProcessIsolation()
        let viewModel = DebugQuotaFixture.loading.makeViewModel(
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let controller = FloatingPanelController(
            viewModel: viewModel,
            quit: {}
        )
        let retainedPanel = controller.panel

        controller.show()
        retainedPanel.performClose(nil)

        XCTAssertFalse(retainedPanel.isVisible)
        controller.show()
        XCTAssertIdentical(controller.panel, retainedPanel)
        XCTAssertTrue(retainedPanel.isVisible)
        controller.hide()
    }

    func testCardSourceHasNoCollapseControlAndEscapeHidesCard() throws {
        let source = try productionSource("UI/CardView.swift")

        XCTAssertFalse(source.contains("Button(action: collapse)"))
        XCTAssertFalse(source.contains("quota.card.collapse"))
        XCTAssertTrue(source.contains(".onExitCommand(perform: hide)"))
    }

    func testFloatingPanelSourceHasNoRuntimeOrbOrExpansionState() throws {
        let source = try productionSource("UI/FloatingPanelController.swift")

        XCTAssertFalse(source.contains("OrbView("))
        XCTAssertFalse(source.contains("FloatingCardInteractionModel"))
        XCTAssertFalse(source.contains("interactionModel"))
    }

#endif

    private func waitUntil(
        description: String = "condition",
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () async -> Bool
    ) async {
        for _ in 0..<2_000 {
            if await condition() {
                return
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for \(description)", file: file, line: line)
    }

    private func productionSource(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CodexQuotaMonitor")
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func orb(remaining: Int) -> OrbPresentation {
        OrbPresentation(state: .loaded(quota(primary: (remaining, 300))))
    }

    private func expectedGrid(
        providerCount: Int,
        screenName: String
    ) -> (columns: Int, rows: Int) {
        switch providerCount {
        case 0, 1: (1, 1)
        case 2: (2, 1)
        case 3: (3, 1)
        default: screenName == "wide" ? (4, 1) : (2, 2)
        }
    }

    private func expectedPreferredPanelSize(
        providerCount: Int,
        screenName: String
    ) -> CGSize {
        switch providerCount {
        case 0, 1: CGSize(width: 272, height: 340)
        case 2: CGSize(width: 520, height: 340)
        case 3: CGSize(width: 768, height: 340)
        default: screenName == "wide"
            ? CGSize(width: 1_016, height: 340)
            : CGSize(width: 520, height: 620)
        }
    }

    private static func window(duration: Int64?) -> NormalizedWindow {
        quota(primary: (remaining: 75, duration: duration)).primary!
    }

    private static func quota(
        primary: (remaining: Int, duration: Int64?)? = nil,
        secondary: (remaining: Int, duration: Int64?)? = nil
    ) -> NormalizedQuota {
        try! NormalizedQuota(
            rawResponse: GetAccountRateLimitsRawResponse(
                rateLimits: RateLimitSnapshotRaw(
                    planType: "plus",
                    primary: primary.map {
                        RateLimitWindowRaw(
                            usedPercent: 100 - $0.remaining,
                            windowDurationMins: $0.duration,
                            resetsAt: 2_000
                        )
                    },
                    secondary: secondary.map {
                        RateLimitWindowRaw(
                            usedPercent: 100 - $0.remaining,
                            windowDurationMins: $0.duration,
                            resetsAt: nil
                        )
                    }
                ),
                rateLimitsByLimitId: nil
            )
        )
    }

    private static func tokenActivitySnapshot() -> TokenActivitySnapshot {
        TokenActivitySnapshot(
            rawResponse: GetAccountTokenUsageRawResponse(
                summary: AccountTokenUsageSummaryRaw(
                    lifetimeTokens: nil,
                    peakDailyTokens: nil,
                    longestRunningTurnSec: nil,
                    currentStreakDays: nil,
                    longestStreakDays: nil
                ),
                dailyUsageBuckets: nil
            )
        )
    }

    private static var keyText: LocalizedTextProvider {
        LocalizedTextProvider(locale: .english) { key, _ in
            key.rawValue
        }
    }

    private static func additionalBucketCatalog() throws -> RateLimitCatalog {
        let selected = RateLimitBucket(
            bucketKey: "codex",
            limitName: "Selected",
            windows: [
                try rateWindow(
                    bucket: "codex",
                    slot: .primary,
                    duration: 300,
                    used: 10
                ),
            ]
        )
        let alpha = RateLimitBucket(
            bucketKey: "alpha",
            limitName: "\nAlpha\t",
            windows: [
                try rateWindow(
                    bucket: "alpha",
                    slot: .primary,
                    duration: 360,
                    used: 20
                ),
                try rateWindow(
                    bucket: "alpha",
                    slot: .secondary,
                    duration: 300,
                    used: 30
                ),
            ]
        )
        let zeta = RateLimitBucket(
            bucketKey: "zeta",
            windows: [
                try rateWindow(
                    bucket: "zeta",
                    slot: .primary,
                    duration: nil,
                    used: 40
                ),
                try rateWindow(
                    bucket: "zeta",
                    slot: .secondary,
                    duration: 10_080,
                    used: 50
                ),
            ]
        )
        return RateLimitCatalog(
            rateLimitsByLimitId: [
                "zeta": zeta,
                "codex": selected,
                "alpha": alpha,
            ],
            legacyBucket: RateLimitBucket(
                bucketKey: RateLimitCatalog.legacyBucketKey,
                windows: []
            )
        )
    }

    private static func rateWindow(
        bucket: String,
        slot: SourceSlot,
        duration: Int64?,
        used: Int
    ) throws -> RateLimitWindow {
        try RateLimitWindow(
            identity: WindowIdentity(
                bucketKey: bucket,
                sourceSlot: slot,
                durationMinutes: duration
            ),
            usedPercent: used,
            resetsAt: nil
        )
    }

    private static func minimumRemaining(in state: QuotaState) -> Int? {
        let quota: NormalizedQuota
        switch state {
        case let .loaded(value), let .stale(value, _):
            quota = value
        case .loading, .unavailable:
            return nil
        }
        return [quota.primary, quota.secondary]
            .compactMap { $0?.remainingPercent }
            .min()
    }
}

private actor ManualGateForPanelTests {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let waiters = self.waiters
        self.waiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private actor AsyncCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}
