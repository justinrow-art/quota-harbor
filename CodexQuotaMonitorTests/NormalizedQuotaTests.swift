import Foundation
import XCTest
@testable import CodexQuotaMonitor

final class NormalizedQuotaTests: XCTestCase {
    func testPrefersCodexBucketOverLegacySnapshot() throws {
        let quota = try normalizedFixture(named: "codex_bucket_priority")

        XCTAssertEqual(quota.planType, .plus)
        XCTAssertEqual(quota.primary?.usedPercent, 20)
        XCTAssertEqual(quota.primary?.remainingPercent, 80)
        XCTAssertEqual(quota.primary?.duration, .fiveHours)
        XCTAssertEqual(quota.secondary?.duration, .weekly)
    }

    func testFallsBackToLegacySnapshotWhenCodexBucketIsMissing() throws {
        let quota = try normalizedFixture(named: "legacy_fallback")

        XCTAssertEqual(quota.planType, .free)
        XCTAssertEqual(quota.primary?.remainingPercent, 75)
    }

    func testRejectsSnapshotWithNoWindows() throws {
        let raw = try fixture(named: "null_windows")

        XCTAssertThrowsError(try NormalizedQuota(rawResponse: raw)) { error in
            XCTAssertEqual(error as? QuotaNormalizationError, .noWindows)
        }
    }

    func testRejectsNegativeUsedPercent() throws {
        let raw = try fixture(named: "invalid_negative_percent")

        XCTAssertThrowsError(try NormalizedQuota(rawResponse: raw)) { error in
            XCTAssertEqual(error as? QuotaNormalizationError, .invalidUsedPercent(-1))
        }
    }

    func testRejectsUsedPercentAboveOneHundred() throws {
        let raw = try fixture(named: "invalid_over_percent")

        XCTAssertThrowsError(try NormalizedQuota(rawResponse: raw)) { error in
            XCTAssertEqual(error as? QuotaNormalizationError, .invalidUsedPercent(101))
        }
    }

    func testKeepsSixHourWindowAsCustomDuration() throws {
        let quota = try normalizedFixture(named: "unknown_360_window")

        XCTAssertEqual(quota.primary?.duration, .custom(minutes: 360))
        XCTAssertEqual(quota.primary?.remainingPercent, 60)
    }

    func testAcceptsOptionalWindowFields() throws {
        let quota = try normalizedFixture(named: "optional_reset_time")

        XCTAssertNil(quota.planType)
        XCTAssertNil(quota.primary?.resetsAt)
        XCTAssertEqual(quota.primary?.duration, .custom(minutes: nil))
    }

    func testPreservesUnknownPlanForForwardCompatibility() throws {
        let quota = try normalizedFixture(named: "unknown_plan_extra_keys")

        XCTAssertEqual(quota.planType, .unknown("future_ultra"))
    }

    func testIgnoresExtraResponseSnapshotAndWindowKeys() throws {
        let quota = try normalizedFixture(named: "unknown_plan_extra_keys")

        XCTAssertEqual(quota.primary?.remainingPercent, 67)
    }

    func testConvertsResetEpochSecondsToDate() throws {
        let quota = try normalizedFixture(named: "epoch_conversion")

        XCTAssertEqual(quota.primary?.resetsAt, Date(timeIntervalSince1970: 1_725_000_000))
    }

    func testCatalogInitializerUsesDeterministicSelectedBucketInsteadOfLegacy() throws {
        let selectedWindow = try RateLimitWindow(
            identity: WindowIdentity(
                bucketKey: "alpha",
                sourceSlot: .primary,
                durationMinutes: 300
            ),
            usedPercent: 10,
            resetsAt: nil
        )
        let legacyWindow = try RateLimitWindow(
            identity: WindowIdentity(
                bucketKey: RateLimitCatalog.legacyBucketKey,
                sourceSlot: .primary,
                durationMinutes: 300
            ),
            usedPercent: 99,
            resetsAt: nil
        )
        let selected = RateLimitBucket(
            bucketKey: "alpha",
            planType: .plus,
            windows: [selectedWindow]
        )
        let legacy = RateLimitBucket(
            bucketKey: RateLimitCatalog.legacyBucketKey,
            planType: .free,
            windows: [legacyWindow]
        )
        let catalog = RateLimitCatalog(
            rateLimitsByLimitId: ["alpha": selected],
            legacyBucket: legacy
        )

        let quota = try NormalizedQuota(catalog: catalog)

        XCTAssertEqual(quota.planType, .plus)
        XCTAssertEqual(quota.primary?.remainingPercent, 90)
    }

    private func normalizedFixture(named name: String) throws -> NormalizedQuota {
        try NormalizedQuota(rawResponse: fixture(named: name))
    }

    private func fixture(named name: String) throws -> GetAccountRateLimitsRawResponse {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "json"))
        return try JSONDecoder().decode(
            GetAccountRateLimitsRawResponse.self,
            from: Data(contentsOf: url)
        )
    }
}
