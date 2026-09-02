import AppKit
import Foundation
import XCTest
@testable import CodexQuotaMonitor

final class ProviderCardPresentationTests: XCTestCase {
    private let text = LocalizedTextProvider(
        language: .english,
        systemLocale: Locale(identifier: "en_US")
    )
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testAllSixteenProviderSelectionsPreserveOrderWithoutDroppingOrDuplicatingCards() {
        let providerOrder: [ProviderID] = [
            .claudeCode,
            .codex,
            .kimiCode,
            .googleAntigravity,
        ]
        let presenter = ProviderDashboardCardPresenter(text: text)

        for mask in 0..<(1 << providerOrder.count) {
            let enabled = providerOrder.enumerated().compactMap {
                index, providerID in
                mask & (1 << index) == 0 ? nil : providerID
            }
            let context = "mask=\(mask), enabled=\(enabled)"
            let presentation = presenter.makePresentation(
                input: ProviderCardDashboardInput(
                    enabledProviders: enabled,
                    statesByProvider: Dictionary(
                        uniqueKeysWithValues: providerOrder.map {
                            ($0, ProviderPresentationState.loading)
                        }
                    ),
                    primaryMetricPreferences: [:]
                ),
                percentageMode: .remaining,
                now: now
            )

            XCTAssertEqual(
                presentation.cards.map(\.providerID),
                enabled,
                context
            )
            XCTAssertEqual(
                Set(presentation.cards.map(\.providerID)).count,
                enabled.count,
                context
            )
            XCTAssertEqual(
                presentation.cards.isEmpty,
                enabled.isEmpty,
                context
            )
            XCTAssertEqual(
                presentation.emptyState != nil,
                enabled.isEmpty,
                context
            )
        }
    }

    func testDashboardUsesEnabledProviderOrderAndIgnoresUnselectedStates()
        throws
    {
        let googleSnapshot = try XCTUnwrap(ProviderSnapshot(
            providerID: .googleAntigravity,
            metrics: [],
            capturedAt: now,
            runtimePresence: .application(installed: true, running: true)
        ))
        let presentation = ProviderDashboardCardPresenter(text: text)
            .makePresentation(
                input: ProviderCardDashboardInput(
                    enabledProviders: [.claudeCode, .codex],
                    statesByProvider: [
                        .googleAntigravity: .fresh(googleSnapshot),
                        .codex: .loading,
                        .claudeCode: .notConnected,
                        .kimiCode: .unsupported,
                    ],
                    primaryMetricPreferences: [:]
                ),
                percentageMode: .remaining,
                now: now
            )

        XCTAssertEqual(
            presentation.cards.map(\.providerID),
            [.claudeCode, .codex]
        )
        XCTAssertNil(presentation.emptyState)
        XCTAssertEqual(presentation.aggregateAvailability, .partial)
    }

    func testCodexAlwaysDelegatesItsBodyToLegacyQuotaView() {
        let states: [ProviderPresentationState] = [
            .loading,
            .notConnected,
            .unsupported,
            .failed(code: .connectorFailed),
        ]

        XCTAssertEqual(
            states.map {
                card(providerID: .codex, state: $0).content
            },
            Array(repeating: .codex, count: states.count)
        )
    }

    func testCodexSuppressesOuterUpdatedFooterWhileOtherProvidersKeepIt() {
        let codex = card(providerID: .codex, state: .loading)
        let claude = card(providerID: .claudeCode, state: .loading)

        XCTAssertFalse(codex.showsOuterLastUpdated)
        XCTAssertTrue(claude.showsOuterLastUpdated)
    }

    func testCodexHeaderAlwaysUsesCanonicalQuotaState() throws {
        let catalog = RateLimitCatalog(
            rateLimitsByLimitId: [
                "codex": RateLimitBucket(
                    bucketKey: "codex",
                    windows: [try XCTUnwrap(RateLimitWindow(
                        identity: WindowIdentity(
                            bucketKey: "codex",
                            sourceSlot: .primary,
                            durationMinutes: 300
                        ),
                        usedPercent: 27,
                        resetsAt: nil
                    ))]
                ),
            ],
            legacyBucket: RateLimitBucket(
                bucketKey: RateLimitCatalog.legacyBucketKey,
                windows: []
            )
        )
        let quota = try NormalizedQuota(catalog: catalog)
        let oldDashboardSnapshot = try snapshot(
            providerID: .codex,
            metrics: []
        )
        let cases: [(
            dashboard: ProviderPresentationState,
            canonical: QuotaState,
            expectedText: String,
            expectedAvailability: ThemeAvailabilityState
        )] = [
            (.loading, .loaded(quota), text.text(.commonFresh), .fresh),
            (
                .stale(oldDashboardSnapshot),
                .loaded(quota),
                text.text(.commonFresh),
                .fresh
            ),
            (
                .fresh(oldDashboardSnapshot),
                .stale(quota, now.addingTimeInterval(-300)),
                text.text(.commonStale),
                .stale
            ),
            (
                .fresh(oldDashboardSnapshot),
                .unavailable(.versionUnsupported),
                text.text(.commonUnsupported),
                .unsupported
            ),
        ]

        for item in cases {
            let presentation = card(
                providerID: .codex,
                state: item.dashboard,
                codexQuotaState: item.canonical
            )

            XCTAssertEqual(presentation.stateText, item.expectedText)
            XCTAssertEqual(
                presentation.availability,
                item.expectedAvailability
            )
            XCTAssertEqual(presentation.content, .codex)
        }
    }

    func testEmptyDashboardPresentsNeutralSettingsRecovery() {
        let presentation = ProviderDashboardCardPresenter(text: text)
            .makePresentation(
                input: ProviderCardDashboardInput(
                    enabledProviders: [],
                    statesByProvider: [.codex: .loading],
                    primaryMetricPreferences: [:]
                ),
                percentageMode: .remaining,
                now: now
            )

        XCTAssertTrue(presentation.cards.isEmpty)
        XCTAssertNil(presentation.aggregateAvailability)
        XCTAssertEqual(
            presentation.emptyState,
            ProviderCardEmptyState(
                title: text.text(.statusProvidersEmptyTitle),
                detail: text.text(.statusProvidersEmptyToolTip),
                actionTitle: text.text(.actionSettings),
                accessibilityLabel: text.text(
                    .statusProvidersEmptyAccessibility
                )
            )
        )
    }

    func testGenuineZeroMetricIsNotPresentedAsMissingQuota() throws {
        let zeroMetric = try metric(
            providerID: .claudeCode,
            stableID: "five-hour",
            remainingFraction: 0,
            durationMinutes: 300
        )
        let zeroSnapshot = try snapshot(
            providerID: .claudeCode,
            metrics: [zeroMetric]
        )
        let noMetricSnapshot = try snapshot(
            providerID: .claudeCode,
            metrics: []
        )

        let zero = card(
            providerID: .claudeCode,
            state: .fresh(zeroSnapshot)
        )
        let missing = card(
            providerID: .claudeCode,
            state: .fresh(noMetricSnapshot)
        )

        XCTAssertEqual(
            zero.content,
            .metrics([
                ProviderCardMetricPresentation(
                    safeWindowOrdinal: 1,
                    title: text.text(.statusDetailedFiveHours),
                    percentage: 0,
                    progressFraction: 0,
                    displayText: text.text(
                        .quotaRemainingPercent,
                        Int64(0)
                    ),
                    detail: text.text(
                        .statusProviderMetricRemaining,
                        text.text(.statusDetailedFiveHours),
                        Int64(0)
                    )
                ),
            ])
        )
        XCTAssertEqual(
            missing.content,
            .message(text.text(.statusProviderClaudeWaitingRelay))
        )
    }

    func testMetricVisiblePercentageUsesLocalizedSelectedModeCopy() throws {
        let metric = try metric(
            providerID: .claudeCode,
            stableID: "window",
            remainingFraction: 0.25,
            durationMinutes: 300
        )
        let snapshot = try snapshot(
            providerID: .claudeCode,
            metrics: [metric]
        )

        guard case let .metrics(remaining) = card(
            providerID: .claudeCode,
            state: .fresh(snapshot),
            percentageMode: .remaining
        ).content,
            case let .metrics(used) = card(
                providerID: .claudeCode,
                state: .fresh(snapshot),
                percentageMode: .used
            ).content
        else {
            return XCTFail("Expected localized metrics")
        }

        XCTAssertEqual(
            remaining[0].displayText,
            text.text(.quotaRemainingPercent, Int64(25))
        )
        XCTAssertEqual(
            used[0].displayText,
            text.text(.quotaUsedPercent, Int64(75))
        )
    }

    func testClaudePrimaryPreferenceLeadsAndFallsBackToSecondMetric() throws {
        let short = try metric(
            providerID: .claudeCode,
            stableID: "short",
            remainingFraction: 0.25,
            durationMinutes: 300
        )
        let preferred = try metric(
            providerID: .claudeCode,
            stableID: "preferred",
            remainingFraction: 0.75,
            durationMinutes: 10_080
        )
        let extra = try metric(
            providerID: .claudeCode,
            stableID: "extra",
            remainingFraction: 0.5,
            durationMinutes: 1_440
        )
        let preference = try XCTUnwrap(PrimaryMetricPreference(
            providerID: .claudeCode,
            metricKey: preferred.metricKey
        ))

        let presentation = card(
            providerID: .claudeCode,
            state: .fresh(try snapshot(
                providerID: .claudeCode,
                metrics: [extra, short, preferred]
            )),
            preferences: [.claudeCode: preference]
        )

        guard case let .metrics(metrics) = presentation.content else {
            return XCTFail("Expected Claude metrics")
        }
        XCTAssertEqual(metrics.map(\.safeWindowOrdinal), [3, 1])
        XCTAssertEqual(metrics.map(\.percentage), [75, 25])
        XCTAssertEqual(
            metrics.map(\.title),
            [
                text.text(.statusDetailedWeek),
                text.text(.statusDetailedFiveHours),
            ]
        )
        XCTAssertFalse(metrics.map(\.detail).joined().contains("preferred"))
    }

    func testGoogleAndKimiShowOnlySupportedPresenceFacts() throws {
        let google = card(
            providerID: .googleAntigravity,
            state: .fresh(try snapshot(
                providerID: .googleAntigravity,
                runtimePresence: .application(
                    installed: true,
                    running: true
                )
            ))
        )
        let kimi = card(
            providerID: .kimiCode,
            state: .fresh(try snapshot(
                providerID: .kimiCode,
                runtimePresence: .command(available: true)
            ))
        )

        XCTAssertEqual(
            google.content,
            .message(text.text(.statusProviderAppRunning))
        )
        XCTAssertEqual(
            kimi.content,
            .message(text.text(.statusProviderCommandAvailable))
        )
    }

    func testPresenceHeaderLabelsStayShortAcrossEveryExplicitLanguage()
        throws
    {
        let states: [ProviderID: ProviderPresentationState] = [
            .googleAntigravity: .fresh(try snapshot(
                providerID: .googleAntigravity,
                runtimePresence: .application(
                    installed: true,
                    running: true
                )
            )),
            .claudeCode: .fresh(try snapshot(providerID: .claudeCode)),
            .kimiCode: .fresh(try snapshot(
                providerID: .kimiCode,
                runtimePresence: .command(available: true)
            )),
        ]
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

        for language in AppLanguage.allCases where language != .system {
            let localizedText = LocalizedTextProvider(
                language: language,
                systemLocale: Locale(identifier: "en_US")
            )
            let presentation = ProviderDashboardCardPresenter(
                text: localizedText
            ).makePresentation(
                input: ProviderCardDashboardInput(
                    enabledProviders: [
                        .googleAntigravity,
                        .claudeCode,
                        .kimiCode,
                    ],
                    statesByProvider: states,
                    primaryMetricPreferences: [:]
                ),
                percentageMode: .remaining,
                now: now
            )

            for card in presentation.cards {
                let width = (card.stateText as NSString).size(
                    withAttributes: [.font: font]
                ).width
                XCTAssertLessThanOrEqual(
                    width,
                    100,
                    "\(language) \(card.providerID): \(card.stateText)"
                )
                XCTAssertFalse(card.stateText.contains(";"))
                XCTAssertFalse(card.stateText.contains("；"))
            }
        }
    }

    func testCardsUseProviderSpecificNonQuotaSemanticsAndNeutralCues()
        throws
    {
        let google = card(
            providerID: .googleAntigravity,
            state: .fresh(try snapshot(
                providerID: .googleAntigravity,
                runtimePresence: .application(installed: true, running: true)
            ))
        )
        let googleMissing = card(
            providerID: .googleAntigravity,
            state: .fresh(try snapshot(
                providerID: .googleAntigravity,
                runtimePresence: .application(installed: false, running: false)
            ))
        )
        let claudeAwaiting = card(
            providerID: .claudeCode,
            state: .fresh(try snapshot(providerID: .claudeCode))
        )
        let claudeSignedOut = card(
            providerID: .claudeCode,
            state: .notConnected
        )
        let kimiMissing = card(
            providerID: .kimiCode,
            state: .notConnected
        )
        let codexAwaiting = card(
            providerID: .codex,
            state: .fresh(try snapshot(providerID: .codex))
        )

        XCTAssertEqual(
            google.stateText,
            text.text(.commonAvailable)
        )
        XCTAssertEqual(
            google.content,
            .message(text.text(.statusProviderAppRunning))
        )
        XCTAssertEqual(google.availability, .partial)
        XCTAssertEqual(
            googleMissing.stateText,
            text.text(.statusProviderNotConnected)
        )
        XCTAssertEqual(googleMissing.availability, .unavailable)
        XCTAssertEqual(
            googleMissing.content,
            .message(text.text(.statusProviderAppNotInstalled))
        )
        XCTAssertEqual(
            claudeAwaiting.stateText,
            text.text(.commonLoading)
        )
        XCTAssertEqual(
            claudeAwaiting.content,
            .message(
                "Claude Code CLI is signed in; waiting for the status line relay to provide a quota snapshot"
            )
        )
        XCTAssertEqual(claudeAwaiting.availability, .loading)
        XCTAssertEqual(
            claudeSignedOut.stateText,
            text.text(.statusProviderNotConnected)
        )
        XCTAssertEqual(
            claudeSignedOut.content,
            .message("Claude Code CLI is not signed in")
        )
        XCTAssertEqual(
            kimiMissing.stateText,
            text.text(.statusProviderNotConnected)
        )
        XCTAssertEqual(
            kimiMissing.content,
            .message(text.text(.statusProviderCommandUnavailable))
        )
        XCTAssertEqual(
            codexAwaiting.stateText,
            text.text(.commonLoading)
        )
        XCTAssertEqual(codexAwaiting.availability, .loading)
    }

    func testEveryProviderStateHasExplicitCopyAndStaleUsesCapturedAt()
        throws
    {
        let capturedAt = now.addingTimeInterval(-7_200)
        let freshSnapshot = try snapshot(
            providerID: .claudeCode,
            capturedAt: now
        )
        let staleSnapshot = try snapshot(
            providerID: .claudeCode,
            capturedAt: capturedAt
        )
        let states: [ProviderPresentationState] = [
            .loading,
            .fresh(freshSnapshot),
            .stale(staleSnapshot),
            .notConnected,
            .unsupported,
            .failed(code: .connectorFailed),
        ]
        let cards = states.map {
            card(providerID: .claudeCode, state: $0)
        }

        XCTAssertEqual(
            cards.map(\.stateText),
            [
                text.text(.commonLoading),
                text.text(.commonLoading),
                text.text(.commonStale),
                text.text(.statusProviderNotConnected),
                text.text(.commonUnsupported),
                text.text(.statusProviderFailed),
            ]
        )
        XCTAssertEqual(
            cards[1].lastUpdatedText,
            text.text(.cardUpdatedAt, text.text(.formatJustNow))
        )
        XCTAssertEqual(
            cards[2].lastUpdatedText,
            text.text(
                .cardStaleUpdatedAt,
                text.text(.formatHoursAgo, Int64(2))
            )
        )
        XCTAssertEqual(
            cards[0].lastUpdatedText,
            text.text(.cardUpdatedAt, "—")
        )
        XCTAssertEqual(
            cards[1].content,
            .message(text.text(.statusProviderClaudeWaitingRelay))
        )
        XCTAssertEqual(
            cards[3].content,
            .message(text.text(.statusProviderClaudeCLINotSignedIn))
        )
    }

    func testDashboardCardKeepsOneScrollViewAndReusesLegacyCodexBody()
        throws
    {
        let source = try productionSource("UI/CardView.swift")

        XCTAssertEqual(occurrences(of: "ScrollView {", in: source), 1)
        XCTAssertTrue(
            source.contains(
                "dashboardInput: ProviderCardDashboardInput? = nil"
            )
        )
        XCTAssertTrue(source.contains("case .codex:"))
        XCTAssertTrue(source.contains("codexProviderContent"))
        XCTAssertTrue(source.contains("content"))
        XCTAssertTrue(source.contains("panelLayout: PanelLayout = .single"))
        XCTAssertTrue(source.contains("width: panelLayout.size.width"))
        XCTAssertTrue(source.contains("height: panelLayout.size.height"))
        XCTAssertTrue(source.contains("quota.card.provider."))
        XCTAssertTrue(source.contains("quota.card.empty.settings"))
        XCTAssertTrue(source.contains("if headerCue != nil"))
        XCTAssertTrue(
            source.contains(
                "guard !isDashboardEmpty else { return nil }"
            )
        )
        XCTAssertTrue(
            source.contains(
                "guard !isDashboardEmpty else { return .solid }"
            )
        )
    }

    @MainActor
    func testFloatingPanelRetainsProviderStoresForLiveObservation() {
        let settingsStore = SettingsStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathComponent("settings.json")
        )
        let dashboardStore = ProviderDashboardStore()
        let controller = FloatingPanelController(
            viewModel: DebugQuotaFixture.loading.makeViewModel(now: now),
            settingsStore: settingsStore,
            providerDashboardStore: dashboardStore,
            quit: {}
        )

        XCTAssertIdentical(controller.settingsStore, settingsStore)
        XCTAssertIdentical(controller.providerDashboardStore, dashboardStore)
        controller.panel.close()
    }

    func testProductionPanelFactoryWiresProviderRuntimeStores() throws {
        let source = try productionSource("AppDelegate.swift")

        XCTAssertTrue(
            source.contains("settingsStore: runtime.settingsStore")
        )
        XCTAssertTrue(
            source.contains(
                "providerDashboardStore: runtime.providerDashboardStore"
            )
        )
    }

    private func card(
        providerID: ProviderID,
        state: ProviderPresentationState,
        preferences: [ProviderID: PrimaryMetricPreference] = [:],
        percentageMode: PercentageMode = .remaining,
        codexQuotaState: QuotaState? = nil
    ) -> ProviderCardPresentation {
        ProviderDashboardCardPresenter(text: text).makePresentation(
            input: ProviderCardDashboardInput(
                enabledProviders: [providerID],
                statesByProvider: [providerID: state],
                primaryMetricPreferences: preferences,
                codexQuotaState: codexQuotaState
            ),
            percentageMode: percentageMode,
            now: now
        ).cards[0]
    }

    private func metric(
        providerID: ProviderID,
        stableID: String,
        remainingFraction: Double,
        durationMinutes: Int64?
    ) throws -> ProviderMetric {
        let key = try XCTUnwrap(ProviderMetricKey(
            providerID: providerID,
            stableID: stableID
        ))
        return try XCTUnwrap(ProviderMetric(
            providerID: providerID,
            metricKey: key,
            remainingFraction: remainingFraction,
            resetAt: nil,
            durationMinutes: durationMinutes
        ))
    }

    private func snapshot(
        providerID: ProviderID,
        metrics: [ProviderMetric] = [],
        capturedAt: Date? = nil,
        runtimePresence: ProviderRuntimePresence? = nil
    ) throws -> ProviderSnapshot {
        try XCTUnwrap(ProviderSnapshot(
            providerID: providerID,
            metrics: metrics,
            capturedAt: capturedAt ?? now,
            runtimePresence: runtimePresence
        ))
    }

    private func productionSource(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CodexQuotaMonitor")
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func occurrences(of needle: String, in source: String) -> Int {
        source.components(separatedBy: needle).count - 1
    }
}
