import Foundation
import XCTest
@testable import CodexQuotaMonitor

@MainActor
final class QuotaStoreTests: XCTestCase {
    private let generationA = GenerationToken(auth: 1, session: 2, connection: 3)
    private let generationB = GenerationToken(auth: 2, session: 1, connection: 1)

    func testInitialStateIsLoadingWithNoDatesOrManualProgress() {
        let store = QuotaStore()

        XCTAssertEqual(store.rateState, .loading)
        XCTAssertEqual(store.usageState, .loading)
        XCTAssertEqual(store.accountState, .loading)
        XCTAssertFalse(store.isManualRefreshInProgress)
        XCTAssertNil(store.rateLastSuccessAt)
        XCTAssertNil(store.usageLastSuccessAt)
    }

    func testAccountLaneUsesSameGenerationGuardAndResetContract() async {
        let store = QuotaStore()
        let account = ProviderAccountSummary(maskedIdentity: nil)
        let date = Date(timeIntervalSince1970: 1_700_000_050)
        await store.apply(Self.reset(1, generationA))

        await store.apply(Self.publication(
            1,
            generationA,
            .account(.fresh(account, date))
        ))
        XCTAssertEqual(store.accountState, .fresh(account, date))

        await store.apply(Self.publication(
            1,
            generationB,
            .account(.unavailable(.unauthenticated))
        ))
        XCTAssertEqual(store.accountState, .fresh(account, date))

        await store.apply(Self.reset(2, generationB))
        XCTAssertEqual(store.accountState, .loading)
    }

    func testRateAndUsageLanesAndSuccessDatesRemainIndependent() async throws {
        let store = QuotaStore()
        let rate = try Self.catalog(usedPercent: 15)
        let usage = Self.usage(lifetime: 123)
        let rateDate = Date(timeIntervalSince1970: 1_700_000_100)
        let usageDate = Date(timeIntervalSince1970: 1_700_000_200)
        await store.apply(Self.reset(1, generationA))

        await store.apply(Self.publication(
            1,
            generationA,
            .rate(.fresh(rate, rateDate))
        ))
        XCTAssertEqual(store.rateState, .fresh(rate, rateDate))
        XCTAssertEqual(store.usageState, .loading)
        XCTAssertEqual(store.rateLastSuccessAt, rateDate)
        XCTAssertNil(store.usageLastSuccessAt)

        await store.apply(Self.publication(
            1,
            generationA,
            .usage(.fresh(usage, usageDate))
        ))
        XCTAssertEqual(store.rateState, .fresh(rate, rateDate))
        XCTAssertEqual(store.usageState, .fresh(usage, usageDate))
        XCTAssertEqual(store.rateLastSuccessAt, rateDate)
        XCTAssertEqual(store.usageLastSuccessAt, usageDate)
    }

    func testStalePreservesValueDateAndFailure() async throws {
        let store = QuotaStore()
        let rate = try Self.catalog(usedPercent: 40)
        let date = Date(timeIntervalSince1970: 1_700_000_300)
        await store.apply(Self.reset(1, generationA))

        await store.apply(Self.publication(
            1,
            generationA,
            .rate(.stale(rate, date, .stale))
        ))

        XCTAssertEqual(store.rateState, .stale(rate, date, .stale))
        XCTAssertEqual(store.rateLastSuccessAt, date)
    }

    func testNonSuccessStatesDoNotOverwriteSameTupleSuccessDates() async throws {
        let store = QuotaStore()
        let rate = try Self.catalog(usedPercent: 25)
        let usage = Self.usage(lifetime: 456)
        let rateDate = Date(timeIntervalSince1970: 1_700_000_400)
        let usageDate = Date(timeIntervalSince1970: 1_700_000_500)
        await store.apply(Self.reset(1, generationA))
        await store.apply(Self.publication(1, generationA, .rate(.fresh(rate, rateDate))))
        await store.apply(Self.publication(1, generationA, .usage(.fresh(usage, usageDate))))

        await store.apply(Self.publication(
            1,
            generationA,
            .rate(.unavailable(.temporaryTransport))
        ))
        await store.apply(Self.publication(1, generationA, .usage(.unsupported)))
        XCTAssertEqual(store.rateLastSuccessAt, rateDate)
        XCTAssertEqual(store.usageLastSuccessAt, usageDate)

        await store.apply(Self.publication(1, generationA, .rate(.loading)))
        await store.apply(Self.publication(
            1,
            generationA,
            .usage(.unavailable(.temporaryBackend))
        ))
        XCTAssertEqual(store.rateLastSuccessAt, rateDate)
        XCTAssertEqual(store.usageLastSuccessAt, usageDate)
    }

    func testOnlyStrictlyNewerResetAtomicallyClearsTupleState() async throws {
        let store = QuotaStore()
        let rate = try Self.catalog(usedPercent: 30)
        let usage = Self.usage(lifetime: 789)
        let date = Date(timeIntervalSince1970: 1_700_000_600)
        await store.apply(Self.reset(5, generationA))
        await store.apply(Self.publication(5, generationA, .rate(.fresh(rate, date))))
        await store.apply(Self.publication(5, generationA, .usage(.fresh(usage, date))))
        await store.apply(Self.publication(5, generationA, .manualRefresh(true)))

        await store.apply(Self.reset(5, generationB))
        await store.apply(Self.reset(4, generationB))
        XCTAssertEqual(store.rateState, .fresh(rate, date))
        XCTAssertEqual(store.usageState, .fresh(usage, date))
        XCTAssertTrue(store.isManualRefreshInProgress)

        await store.apply(Self.reset(6, generationB))
        XCTAssertEqual(store.rateState, .loading)
        XCTAssertEqual(store.usageState, .loading)
        XCTAssertFalse(store.isManualRefreshInProgress)
        XCTAssertNil(store.rateLastSuccessAt)
        XCTAssertNil(store.usageLastSuccessAt)
    }

    func testNonResetRequiresExactSequenceAndEveryGenerationComponent() async throws {
        let store = QuotaStore()
        let value = try Self.catalog(usedPercent: 10)
        let date = Date(timeIntervalSince1970: 1_700_000_700)
        await store.apply(Self.reset(10, generationA))
        let wrongGenerations = [
            GenerationToken(auth: 9, session: generationA.session, connection: generationA.connection),
            GenerationToken(auth: generationA.auth, session: 9, connection: generationA.connection),
            GenerationToken(auth: generationA.auth, session: generationA.session, connection: 9),
        ]

        for generation in wrongGenerations {
            await store.apply(Self.publication(10, generation, .rate(.fresh(value, date))))
        }
        await store.apply(Self.publication(11, generationA, .rate(.fresh(value, date))))
        await store.apply(Self.publication(9, generationA, .rate(.fresh(value, date))))
        await store.apply(Self.publication(10, nil, .rate(.fresh(value, date))))
        XCTAssertEqual(store.rateState, .loading)

        await store.apply(Self.publication(10, generationA, .rate(.fresh(value, date))))
        XCTAssertEqual(store.rateState, .fresh(value, date))
    }

    func testNilGenerationAcceptsNonValueStatesButRejectsFreshAndStale() async throws {
        let store = QuotaStore()
        let rate = try Self.catalog(usedPercent: 50)
        let usage = Self.usage(lifetime: 900)
        let date = Date(timeIntervalSince1970: 1_700_000_800)
        await store.apply(Self.reset(1, nil))

        await store.apply(Self.publication(1, nil, .rate(.unsupported)))
        await store.apply(Self.publication(
            1,
            nil,
            .usage(.unavailable(.unauthenticated))
        ))
        await store.apply(Self.publication(1, nil, .manualRefresh(true)))
        XCTAssertEqual(store.rateState, .unsupported)
        XCTAssertEqual(store.usageState, .unavailable(.unauthenticated))
        XCTAssertTrue(store.isManualRefreshInProgress)

        await store.apply(Self.publication(1, nil, .rate(.fresh(rate, date))))
        await store.apply(Self.publication(
            1,
            nil,
            .usage(.stale(usage, date, .stale))
        ))
        XCTAssertEqual(store.rateState, .unsupported)
        XCTAssertEqual(store.usageState, .unavailable(.unauthenticated))
        XCTAssertNil(store.rateLastSuccessAt)
        XCTAssertNil(store.usageLastSuccessAt)

        await store.apply(Self.reset(2, generationB))
        await store.apply(Self.publication(2, generationB, .rate(.fresh(rate, date))))
        XCTAssertEqual(store.rateState, .fresh(rate, date))
    }

    func testAdversarialOldAndMismatchedPublicationsCannotReplaceNewTuple() async throws {
        let store = QuotaStore()
        let valueA = try Self.catalog(usedPercent: 99)
        let valueB = try Self.catalog(usedPercent: 12)
        let dateA = Date(timeIntervalSince1970: 1_700_000_900)
        let dateB = Date(timeIntervalSince1970: 1_700_001_000)
        await store.apply(Self.reset(1, generationA))
        await store.apply(Self.publication(1, generationA, .rate(.fresh(valueA, dateA))))
        await store.apply(Self.reset(2, generationB))

        await store.apply(Self.publication(1, generationA, .rate(.fresh(valueA, dateA))))
        await store.apply(Self.publication(2, generationA, .rate(.fresh(valueA, dateA))))
        await store.apply(Self.publication(3, generationB, .rate(.fresh(valueA, dateA))))
        await store.apply(Self.publication(2, nil, .rate(.fresh(valueA, dateA))))
        XCTAssertEqual(store.rateState, .loading)

        await store.apply(Self.publication(2, generationB, .rate(.fresh(valueB, dateB))))
        XCTAssertEqual(store.rateState, .fresh(valueB, dateB))
        XCTAssertEqual(store.rateLastSuccessAt, dateB)
    }

    private static func reset(
        _ sequence: UInt64,
        _ generation: GenerationToken?
    ) -> RefreshPublication {
        publication(sequence, generation, .reset)
    }

    private static func publication(
        _ sequence: UInt64,
        _ generation: GenerationToken?,
        _ change: RefreshChange
    ) -> RefreshPublication {
        RefreshPublication(
            sequence: sequence,
            generation: generation,
            change: change
        )
    }

    private static func catalog(usedPercent: Int) throws -> RateLimitCatalog {
        let window = try RateLimitWindow(
            identity: WindowIdentity(
                bucketKey: "codex",
                sourceSlot: .primary,
                durationMinutes: 300
            ),
            usedPercent: usedPercent,
            resetsAt: 1_700_100_000
        )
        let bucket = RateLimitBucket(bucketKey: "codex", windows: [window])
        return RateLimitCatalog(
            rateLimitsByLimitId: ["codex": bucket],
            legacyBucket: bucket
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
