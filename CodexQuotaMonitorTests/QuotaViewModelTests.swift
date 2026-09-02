import Foundation
import Observation
import XCTest
@testable import CodexQuotaMonitor

@MainActor
final class QuotaViewModelTests: XCTestCase {
    private let generation = GenerationToken(auth: 1, session: 1, connection: 1)

    func testInitialStoreStateIsPresentedAsLoading() {
        let store = QuotaStore()
        let viewModel = QuotaViewModel(store: store)

        XCTAssertEqual(viewModel.state, .loading)
        XCTAssertNil(viewModel.lastUpdatedAt)
        XCTAssertNil(viewModel.lastSuccessfulRefreshAt)
        XCTAssertFalse(viewModel.isManualRefreshInProgress)
    }

    func testFreshStoreValueUsesSelectedCatalogBucketAndSuccessDate() async throws {
        let store = QuotaStore()
        let date = Date(timeIntervalSince1970: 1_725_000_000)
        let catalog = try Self.catalog(
            selectedBucketKey: "alpha",
            selectedUsedPercent: 10,
            legacyUsedPercent: 99
        )
        await publish(.fresh(catalog, date), to: store)

        let viewModel = QuotaViewModel(store: store)

        guard case let .loaded(quota) = viewModel.state else {
            return XCTFail("Expected a loaded quota")
        }
        XCTAssertEqual(quota.planType, .plus)
        XCTAssertEqual(quota.primary?.remainingPercent, 90)
        XCTAssertEqual(viewModel.lastUpdatedAt, date)
        XCTAssertEqual(viewModel.lastSuccessfulRefreshAt, date)
    }

    func testStaleStoreValuePreservesQuotaAndOriginalSuccessDate() async throws {
        let store = QuotaStore()
        let date = Date(timeIntervalSince1970: 1_725_000_100)
        let catalog = try Self.catalog(selectedUsedPercent: 28)
        await publish(.stale(catalog, date, .stale), to: store)

        let viewModel = QuotaViewModel(store: store)

        guard case let .stale(quota, presentedDate) = viewModel.state else {
            return XCTFail("Expected a stale quota")
        }
        XCTAssertEqual(quota.primary?.remainingPercent, 72)
        XCTAssertEqual(presentedDate, date)
        XCTAssertEqual(viewModel.lastUpdatedAt, date)
    }

    func testOnlyFreshAndStaleStatesExposeTheReadOnlyRateCatalog() async throws {
        let catalog = try Self.catalog(selectedUsedPercent: 28)
        let date = Date(timeIntervalSince1970: 1_725_000_100)

        let freshStore = QuotaStore()
        await publish(.fresh(catalog, date), to: freshStore)
        XCTAssertEqual(QuotaViewModel(store: freshStore).rateCatalog, catalog)

        let staleStore = QuotaStore()
        await publish(.stale(catalog, date, .stale), to: staleStore)
        XCTAssertEqual(QuotaViewModel(store: staleStore).rateCatalog, catalog)

        for state: CapabilityState<RateLimitCatalog> in [
            .loading,
            .unsupported,
            .unavailable(.temporaryBackend),
        ] {
            let store = QuotaStore()
            await publish(state, to: store)
            XCTAssertNil(QuotaViewModel(store: store).rateCatalog)
        }
    }

    func testUnsupportedAndUnavailableCapabilitiesMapToTruthfulPresentationReasons() async throws {
        let cases: [(CapabilityState<RateLimitCatalog>, UnavailableReason)] = [
            (.unsupported, .versionUnsupported),
            (.unavailable(.unauthenticated), .authenticationRequired),
            (.unavailable(.unsupportedAuthMode), .unsupportedAuthMode),
            (.unavailable(.invalidSchema), .schemaChanged),
            (.unavailable(.temporaryTransport), .transportError),
            (.unavailable(.temporaryBackend), .backendUnavailable),
            (.unavailable(.serverRejected), .serverRejected),
            (.unavailable(.binaryNotFound), .binaryNotFound),
            (.unavailable(.trustValidationFailed), .trustValidationFailed),
            (.unavailable(.processLaunchFailed), .processLaunchFailed),
            (.unavailable(.stale), .staleDataUnavailable),
        ]

        for (state, expectedReason) in cases {
            let store = QuotaStore()
            await publish(state, to: store)

            XCTAssertEqual(
                QuotaViewModel(store: store).state,
                .unavailable(expectedReason)
            )
        }
    }

    func testCatalogWithoutWindowsMapsToNoWindows() async {
        let store = QuotaStore()
        let emptyBucket = RateLimitBucket(bucketKey: "codex", windows: [])
        let catalog = RateLimitCatalog(
            rateLimitsByLimitId: ["codex": emptyBucket],
            legacyBucket: emptyBucket
        )
        await publish(.fresh(catalog, Date()), to: store)

        XCTAssertEqual(
            QuotaViewModel(store: store).state,
            .unavailable(.noWindows)
        )
    }

    func testManualRefreshForwardsExactlyOnceAndProgressComesFromStore() async {
        let store = QuotaStore()
        await store.apply(resetPublication())
        var requestCount = 0
        let viewModel = QuotaViewModel(
            store: store,
            requestManualRefresh: { requestCount += 1 }
        )

        XCTAssertFalse(viewModel.isManualRefreshInProgress)
        viewModel.triggerRefresh()
        XCTAssertEqual(requestCount, 1)

        await store.apply(
            RefreshPublication(
                sequence: 1,
                generation: generation,
                change: .manualRefresh(true)
            )
        )
        XCTAssertTrue(viewModel.isManualRefreshInProgress)
    }

    func testLastUpdatedFormattingUsesInjectedClock() async throws {
        let date = Date(timeIntervalSince1970: 1_725_000_000)
        let clock = TestDateProvider(date)
        let store = QuotaStore()
        await publish(
            .fresh(try Self.catalog(selectedUsedPercent: 28), date),
            to: store
        )
        let viewModel = QuotaViewModel(store: store, now: clock.now)
        let english = LocalizedTextProvider(
            language: .english,
            systemLocale: Locale(identifier: "de_DE")
        )
        let german = LocalizedTextProvider(
            language: .german,
            systemLocale: Locale(identifier: "en_US")
        )

        XCTAssertEqual(viewModel.lastUpdatedText(using: english), "just now")
        clock.advance(by: 125)
        XCTAssertEqual(viewModel.lastUpdatedText(using: english), "2 minutes ago")
        XCTAssertEqual(viewModel.lastUpdatedText(using: german), "vor 2 Minuten")
        clock.advance(by: 7_200)
        XCTAssertEqual(viewModel.lastUpdatedText(using: english), "2 hours ago")
    }

    func testUsageLaneIsExposedWithoutChangingRatePresentation() async throws {
        let store = QuotaStore()
        let date = Date(timeIntervalSince1970: 1_725_000_200)
        let catalog = try Self.catalog(selectedUsedPercent: 28)
        let usage = Self.usage(lifetime: 12_345)
        await publish(.fresh(catalog, date), to: store)
        await store.apply(
            RefreshPublication(
                sequence: 1,
                generation: generation,
                change: .usage(.fresh(usage, date))
            )
        )
        let viewModel = QuotaViewModel(store: store)

        XCTAssertEqual(viewModel.usageState, .fresh(usage, date))
        guard case let .loaded(quota) = viewModel.state else {
            return XCTFail("Expected rate presentation to remain loaded")
        }
        XCTAssertEqual(quota.primary?.remainingPercent, 72)
        XCTAssertEqual(viewModel.lastUpdatedAt, date)
    }

    func testStoreMutationInvalidatesObservedViewModelState() async {
        let store = QuotaStore()
        await store.apply(resetPublication())
        let viewModel = QuotaViewModel(store: store)
        let invalidated = expectation(description: "state invalidated")

        withObservationTracking {
            _ = viewModel.state
        } onChange: {
            invalidated.fulfill()
        }

        await store.apply(
            RefreshPublication(
                sequence: 1,
                generation: generation,
                change: .rate(.unsupported)
            )
        )
        await fulfillment(of: [invalidated], timeout: 1)
    }

    private func publish(
        _ state: CapabilityState<RateLimitCatalog>,
        to store: QuotaStore
    ) async {
        await store.apply(resetPublication())
        await store.apply(
            RefreshPublication(
                sequence: 1,
                generation: generation,
                change: .rate(state)
            )
        )
    }

    private func resetPublication() -> RefreshPublication {
        RefreshPublication(
            sequence: 1,
            generation: generation,
            change: .reset
        )
    }

    private static func catalog(
        selectedBucketKey: String = "codex",
        selectedUsedPercent: Int,
        legacyUsedPercent: Int? = nil
    ) throws -> RateLimitCatalog {
        let selectedWindow = try RateLimitWindow(
            identity: WindowIdentity(
                bucketKey: selectedBucketKey,
                sourceSlot: .primary,
                durationMinutes: 300
            ),
            usedPercent: selectedUsedPercent,
            resetsAt: 1_725_010_000
        )
        let selectedBucket = RateLimitBucket(
            bucketKey: selectedBucketKey,
            planType: .plus,
            windows: [selectedWindow]
        )
        let legacyWindow = try RateLimitWindow(
            identity: WindowIdentity(
                bucketKey: RateLimitCatalog.legacyBucketKey,
                sourceSlot: .primary,
                durationMinutes: 300
            ),
            usedPercent: legacyUsedPercent ?? selectedUsedPercent,
            resetsAt: 1_725_010_000
        )
        let legacyBucket = RateLimitBucket(
            bucketKey: RateLimitCatalog.legacyBucketKey,
            planType: .free,
            windows: [legacyWindow]
        )
        return RateLimitCatalog(
            rateLimitsByLimitId: [selectedBucketKey: selectedBucket],
            legacyBucket: legacyBucket
        )
    }

    private static func usage(lifetime: Int64) -> TokenActivitySnapshot {
        TokenActivitySnapshot(
            rawResponse: GetAccountTokenUsageRawResponse(
                summary: AccountTokenUsageSummaryRaw(
                    lifetimeTokens: lifetime,
                    peakDailyTokens: nil,
                    longestRunningTurnSec: nil,
                    currentStreakDays: nil,
                    longestStreakDays: nil
                ),
                dailyUsageBuckets: nil
            )
        )
    }
}

private final class TestDateProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) {
        self.date = date
    }

    func now() -> Date {
        lock.withLock { date }
    }

    func advance(by seconds: TimeInterval) {
        lock.withLock {
            date = date.addingTimeInterval(seconds)
        }
    }
}
