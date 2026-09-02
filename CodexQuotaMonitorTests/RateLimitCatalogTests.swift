import Foundation
import XCTest
@testable import CodexQuotaMonitor

final class RateLimitCatalogTests: XCTestCase {
    func testRawResponsePreservesAllInstalledSchemaRateFields() throws {
        let response = try rawFixture(named: "rate_limit_catalog_full")
        let resetSummary = try XCTUnwrap(response.rateLimitResetCredits)
        let resetCredit = try XCTUnwrap(try XCTUnwrap(resetSummary.credits).first)

        XCTAssertEqual(resetSummary.availableCount, 2)
        XCTAssertEqual(resetCredit.id, "reset-credit-1")
        XCTAssertEqual(resetCredit.resetType, "codexRateLimits")
        XCTAssertEqual(resetCredit.status, "available")
        XCTAssertEqual(resetCredit.grantedAt, 1_700_000_000)
        XCTAssertEqual(resetCredit.expiresAt, 1_800_000_000)
        XCTAssertEqual(resetCredit.title, "Reset Codex limits")
        XCTAssertEqual(resetCredit.description, "One-time reset")

        let buckets = try XCTUnwrap(response.rateLimitsByLimitId)
        XCTAssertEqual(Set(buckets.keys), ["codex", "search"])

        let codex = try XCTUnwrap(buckets["codex"])
        XCTAssertEqual(codex.limitId, "codex-v2")
        XCTAssertEqual(codex.limitName, "Codex")
        XCTAssertEqual(codex.planType, "plus")
        XCTAssertEqual(codex.credits?.balance, "12.75")
        XCTAssertEqual(codex.credits?.hasCredits, true)
        XCTAssertEqual(codex.credits?.unlimited, false)
        XCTAssertEqual(codex.individualLimit?.limit, "200.00")
        XCTAssertEqual(codex.individualLimit?.used, "80.00")
        XCTAssertEqual(codex.individualLimit?.remainingPercent, 60)
        XCTAssertEqual(codex.individualLimit?.resetsAt, 1_728_000_000)
        XCTAssertEqual(codex.rateLimitReachedType, "rate_limit_reached")
        XCTAssertEqual(codex.primary?.usedPercent, 20)
        XCTAssertEqual(codex.secondary?.usedPercent, 40)
    }

    func testCatalogPreservesEveryBucketAndPrefersExactCodex() throws {
        let response = try rawFixture(named: "rate_limit_catalog_full")
        let catalog = try RateLimitCatalog(rawResponse: response)

        XCTAssertEqual(Set(catalog.rateLimitsByLimitId.keys), ["codex", "search"])
        XCTAssertEqual(catalog.rateLimitResetCredits, response.rateLimitResetCredits)
        XCTAssertEqual(catalog.legacyBucket.limitId, "legacy-id")
        XCTAssertEqual(catalog.legacyBucket.limitName, "Legacy limits")
        XCTAssertEqual(catalog.legacyBucket.planType, .free)

        let codex = try XCTUnwrap(catalog.rateLimitsByLimitId["codex"])
        XCTAssertEqual(codex.bucketKey, "codex")
        XCTAssertEqual(codex.limitId, "codex-v2")
        XCTAssertEqual(codex.limitName, "Codex")
        XCTAssertEqual(codex.planType, .plus)
        XCTAssertEqual(codex.credits?.balance, "12.75")
        XCTAssertEqual(codex.individualLimit?.remainingPercent, 60)
        XCTAssertEqual(codex.rateLimitReachedType, "rate_limit_reached")
        XCTAssertEqual(codex.windows.map(\.identity.sourceSlot), [.primary, .secondary])
        XCTAssertEqual(codex.windows.map(\.durationMinutes), [300, 10_080])
        XCTAssertEqual(codex.windows.map(\.remainingPercent), [80, 60])

        XCTAssertEqual(catalog.selectedBucket.bucketKey, "codex")
        XCTAssertEqual(
            catalog.selectionProvenance,
            .preferredBucket(bucketKey: "codex")
        )
    }

    func testRateLimitWindowRejectsUsedPercentOutsideClosedRange() {
        let identity = WindowIdentity(
            bucketKey: "codex",
            sourceSlot: .primary,
            durationMinutes: 300
        )

        for invalidPercent in [-1, 101] {
            XCTAssertThrowsError(
                try RateLimitWindow(
                    identity: identity,
                    usedPercent: invalidPercent,
                    resetsAt: nil
                )
            ) { error in
                XCTAssertEqual(
                    error as? QuotaNormalizationError,
                    .invalidUsedPercent(invalidPercent)
                )
            }
        }
    }

    func testMissingCodexUsesLexicographicallyFirstMapBucketWithTruthfulProvenance() throws {
        let response = try rawResponse(
            json: #"{"rateLimits":{"planType":"free","primary":{"usedPercent":90}},"rateLimitsByLimitId":{"zeta":{"planType":"team","primary":{"usedPercent":20,"windowDurationMins":60}},"alpha":{"planType":"pro","primary":{"usedPercent":10,"windowDurationMins":360}}}}"#
        )
        let catalog = try RateLimitCatalog(rawResponse: response)

        XCTAssertEqual(catalog.selectedBucket.bucketKey, "alpha")
        XCTAssertEqual(catalog.selectedBucket.planType, .pro)
        XCTAssertEqual(
            catalog.selectionProvenance,
            .deterministicFallback(bucketKey: "alpha")
        )
    }

    func testAutomaticWindowsUsesFiveHourThenWeeklyAndNeverExceedsTwo() throws {
        let catalog = try RateLimitCatalog(
            rawResponse: rawFixture(named: "rate_limit_catalog_full")
        )

        let windows = catalog.automaticWindows(limit: 20)

        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows.map(\.durationMinutes), [300, 10_080])
        XCTAssertEqual(windows.map(\.identity.bucketKey), ["codex", "codex"])
    }

    func testAutomaticWindowsSortsAndLimitsArtificialCatalogWithMoreThanThreeWindows() throws {
        let codex = RateLimitBucket(
            bucketKey: "codex",
            windows: [
                try makeWindow(sourceSlot: .secondary, durationMinutes: 60),
                try makeWindow(sourceSlot: .primary, durationMinutes: nil),
                try makeWindow(sourceSlot: .primary, durationMinutes: 10_080),
                try makeWindow(sourceSlot: .primary, durationMinutes: 360),
                try makeWindow(sourceSlot: .secondary, durationMinutes: 300)
            ]
        )
        let catalog = RateLimitCatalog(
            rateLimitsByLimitId: ["codex": codex],
            legacyBucket: RateLimitBucket(
                bucketKey: RateLimitCatalog.legacyBucketKey,
                windows: []
            )
        )

        let windows = catalog.automaticWindows(limit: 99)

        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows.map(\.durationMinutes), [300, 10_080])
    }

    func testNormalizedQuotaBuildsThroughCanonicalCatalog() throws {
        let response = try rawResponse(
            json: #"{"rateLimits":{"primary":{"usedPercent":1}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":2}},"other":{"primary":{"usedPercent":101}}}}"#
        )

        XCTAssertThrowsError(try NormalizedQuota(rawResponse: response)) { error in
            XCTAssertEqual(
                error as? QuotaNormalizationError,
                .invalidUsedPercent(101)
            )
        }
    }

    func testLegacyOnlyCatalogHasExplicitLegacyFallbackProvenance() throws {
        let catalog = try RateLimitCatalog(
            rawResponse: rawResponse(
                json: #"{"rateLimits":{"limitId":"legacy","limitName":"Historical","planType":"free","primary":{"usedPercent":25,"windowDurationMins":300}}}"#
            )
        )

        XCTAssertTrue(catalog.rateLimitsByLimitId.isEmpty)
        XCTAssertEqual(catalog.selectedBucket.bucketKey, RateLimitCatalog.legacyBucketKey)
        XCTAssertEqual(catalog.selectedBucket.limitId, "legacy")
        XCTAssertEqual(catalog.selectionProvenance, .legacyFallback)
        XCTAssertEqual(
            catalog.automaticWindows().map(\.identity.bucketKey),
            [RateLimitCatalog.legacyBucketKey]
        )
        XCTAssertEqual(
            catalog.liveWindowIdentities().map(\.bucketKey),
            [RateLimitCatalog.legacyBucketKey]
        )
    }

    func testLiveWindowIdentitiesExcludeLegacyWhenBucketMapIsAuthoritative()
        throws
    {
        let catalog = RateLimitCatalog(
            rateLimitsByLimitId: [
                "codex": RateLimitBucket(
                    bucketKey: "codex",
                    windows: [
                        try makeWindow(
                            bucketKey: "codex",
                            sourceSlot: .primary,
                            durationMinutes: 300
                        ),
                    ]
                ),
            ],
            legacyBucket: RateLimitBucket(
                bucketKey: RateLimitCatalog.legacyBucketKey,
                windows: [
                    try makeWindow(
                        bucketKey: RateLimitCatalog.legacyBucketKey,
                        sourceSlot: .primary,
                        durationMinutes: 300
                    ),
                ]
            )
        )

        XCTAssertEqual(
            catalog.liveWindowIdentities().map(\.bucketKey),
            ["codex"]
        )
    }

    func testWindowIdentityChangesForSlotOrDurationButNotUsageResetOrBucketName() throws {
        let original = try makeWindow(
            sourceSlot: .primary,
            durationMinutes: 300,
            usedPercent: 10,
            resetsAt: 1_000
        )
        let refreshed = try makeWindow(
            sourceSlot: .primary,
            durationMinutes: 300,
            usedPercent: 90,
            resetsAt: 2_000
        )
        let changedSlot = try makeWindow(
            sourceSlot: .secondary,
            durationMinutes: 300
        )
        let changedDuration = try makeWindow(
            sourceSlot: .primary,
            durationMinutes: 360
        )
        let renamedOriginal = RateLimitBucket(
            bucketKey: "codex",
            limitName: "Old name",
            windows: [original]
        )
        let renamedRefresh = RateLimitBucket(
            bucketKey: "codex",
            limitName: "New name",
            windows: [refreshed]
        )

        XCTAssertEqual(original.identity.schemaVersion, 1)
        XCTAssertEqual(original.identity, refreshed.identity)
        XCTAssertEqual(
            renamedOriginal.windows[0].identity,
            renamedRefresh.windows[0].identity
        )
        XCTAssertNotEqual(original.identity, changedSlot.identity)
        XCTAssertNotEqual(original.identity, changedDuration.identity)
        XCTAssertNotEqual(original.usedPercent, refreshed.usedPercent)
        XCTAssertNotEqual(original.resetsAt, refreshed.resetsAt)
        XCTAssertNotEqual(renamedOriginal.limitName, renamedRefresh.limitName)

        let encoded = try JSONEncoder().encode(original.identity)
        XCTAssertEqual(
            try JSONDecoder().decode(WindowIdentity.self, from: encoded),
            original.identity
        )
    }

    func testCatalogPreservesUnknownPositiveAndMissingDurations() throws {
        let catalog = try RateLimitCatalog(
            rawResponse: rawResponse(
                json: #"{"rateLimits":{"primary":null},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":40,"windowDurationMins":360},"secondary":{"usedPercent":20}}}}"#
            )
        )
        let codex = try XCTUnwrap(catalog.rateLimitsByLimitId["codex"])

        XCTAssertEqual(codex.windows.map(\.durationMinutes), [360, nil])
        XCTAssertEqual(
            codex.windows.map(\.identity.durationMinutes),
            [360, nil]
        )
    }

    func testAutomaticWindowsDoesNotFillPreferredBucketWithOtherBuckets() throws {
        let catalog = try RateLimitCatalog(
            rawResponse: rawResponse(
                json: #"{"rateLimits":{"primary":{"usedPercent":99}},"rateLimitsByLimitId":{"other":{"primary":{"usedPercent":1,"windowDurationMins":300},"secondary":{"usedPercent":2,"windowDurationMins":10080}},"codex":{"primary":{"usedPercent":3,"windowDurationMins":360}}}}"#
            )
        )

        let windows = catalog.automaticWindows()

        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].identity.bucketKey, "codex")
        XCTAssertEqual(windows[0].durationMinutes, 360)
    }

    func testAutomaticWindowsOrdersOtherDurationsBySlotThenDurationWithNilLast() throws {
        let windows = [
            try makeWindow(sourceSlot: .secondary, durationMinutes: 60),
            try makeWindow(sourceSlot: .primary, durationMinutes: nil),
            try makeWindow(sourceSlot: .primary, durationMinutes: 360)
        ]
        let catalog = artificialCatalog(windows: windows)

        let selected = catalog.automaticWindows(limit: 3)

        XCTAssertEqual(selected.count, 2)
        XCTAssertEqual(selected.map(\.identity.sourceSlot), [.primary, .primary])
        XCTAssertEqual(selected.map(\.durationMinutes), [360, nil])
    }

    func testResponseMapReorderingDoesNotChangeFallbackOrWindowOrder() throws {
        let first = try RateLimitCatalog(
            rawResponse: rawResponse(
                json: #"{"rateLimits":{"primary":{"usedPercent":99}},"rateLimitsByLimitId":{"zeta":{"primary":{"usedPercent":20,"windowDurationMins":60}},"alpha":{"primary":{"usedPercent":10,"windowDurationMins":360},"secondary":{"usedPercent":30}}}}"#
            )
        )
        let reordered = try RateLimitCatalog(
            rawResponse: rawResponse(
                json: #"{"rateLimits":{"primary":{"usedPercent":99}},"rateLimitsByLimitId":{"alpha":{"secondary":{"usedPercent":30},"primary":{"windowDurationMins":360,"usedPercent":10}},"zeta":{"primary":{"windowDurationMins":60,"usedPercent":20}}}}"#
            )
        )

        XCTAssertEqual(first.selectionProvenance, reordered.selectionProvenance)
        XCTAssertEqual(first.selectedBucket.bucketKey, "alpha")
        XCTAssertEqual(first.automaticWindows(), reordered.automaticWindows())
        XCTAssertEqual(
            first.automaticWindows().map(\.identity),
            reordered.automaticWindows().map(\.identity)
        )
    }

    func testResetCreditDetailsDistinguishUnknownFromFetchedEmptyList() throws {
        let unknown = try rawResponse(
            json: #"{"rateLimitResetCredits":{"availableCount":2,"credits":null},"rateLimits":{"primary":null}}"#
        )
        let fetchedEmpty = try rawResponse(
            json: #"{"rateLimitResetCredits":{"availableCount":0,"credits":[]},"rateLimits":{"primary":null}}"#
        )

        XCTAssertNil(unknown.rateLimitResetCredits?.credits)
        XCTAssertEqual(fetchedEmpty.rateLimitResetCredits?.credits, [])
    }

    private func rawFixture(named name: String) throws -> GetAccountRateLimitsRawResponse {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "json"))
        return try JSONDecoder().decode(
            GetAccountRateLimitsRawResponse.self,
            from: Data(contentsOf: url)
        )
    }

    private func rawResponse(json: String) throws -> GetAccountRateLimitsRawResponse {
        try JSONDecoder().decode(
            GetAccountRateLimitsRawResponse.self,
            from: Data(json.utf8)
        )
    }

    private func makeWindow(
        bucketKey: String = "codex",
        sourceSlot: SourceSlot,
        durationMinutes: Int64?,
        usedPercent: Int = 0,
        resetsAt: Int64? = nil
    ) throws -> RateLimitWindow {
        try RateLimitWindow(
            identity: WindowIdentity(
                bucketKey: bucketKey,
                sourceSlot: sourceSlot,
                durationMinutes: durationMinutes
            ),
            usedPercent: usedPercent,
            resetsAt: resetsAt
        )
    }

    private func artificialCatalog(windows: [RateLimitWindow]) -> RateLimitCatalog {
        RateLimitCatalog(
            rateLimitsByLimitId: [
                "codex": RateLimitBucket(
                    bucketKey: "codex",
                    windows: windows
                )
            ],
            legacyBucket: RateLimitBucket(
                bucketKey: RateLimitCatalog.legacyBucketKey,
                windows: []
            )
        )
    }
}
