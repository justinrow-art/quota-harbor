import Foundation
import XCTest
@testable import CodexQuotaMonitor

final class TokenActivityTests: XCTestCase {
    func testInstalledSchemaSummaryAndDailyRowsArePreserved() throws {
        let response = try rawFixture(named: "token_usage_full")

        XCTAssertEqual(response.summary.lifetimeTokens, 9_001)
        XCTAssertEqual(response.summary.peakDailyTokens, 1_440)
        XCTAssertEqual(response.summary.longestRunningTurnSec, 321)
        XCTAssertEqual(response.summary.currentStreakDays, 7)
        XCTAssertEqual(response.summary.longestStreakDays, 21)
        XCTAssertEqual(response.dailyUsageBuckets?.count, 13)
        XCTAssertEqual(response.dailyUsageBuckets?.first?.startDate, "2026-07-01")
        XCTAssertEqual(response.dailyUsageBuckets?.last?.tokens, 13)

        let snapshot = TokenActivitySnapshot(rawResponse: response)
        XCTAssertEqual(snapshot.lifetimeTokens, 9_001)
        XCTAssertEqual(snapshot.peakDailyTokens, 1_440)
        XCTAssertEqual(snapshot.longestRunningTurnSec, 321)
        XCTAssertEqual(snapshot.currentStreakDays, 7)
        XCTAssertEqual(snapshot.longestStreakDays, 21)
        XCTAssertTrue(snapshot.dailyWasReturned)
        XCTAssertEqual(snapshot.daily.map(\.rawDate), response.dailyUsageBuckets?.map(\.startDate))
        XCTAssertEqual(snapshot.daily.map(\.tokenCount), response.dailyUsageBuckets?.map(\.tokens))
    }

    func testOmittedAndNullDailyUsageRemainUnknownAndNeverBecomeZero() throws {
        for fixtureName in ["token_usage_omitted", "token_usage_null"] {
            let response = try rawFixture(named: fixtureName)
            XCTAssertNil(response.dailyUsageBuckets)

            let snapshot = TokenActivitySnapshot(rawResponse: response)
            let presentation = snapshot.derive(atUTC: utcDate(day: 13), calendar: utcCalendar())

            XCTAssertFalse(snapshot.dailyWasReturned)
            XCTAssertTrue(snapshot.daily.isEmpty)
            XCTAssertEqual(presentation.utcToday, .notReturned)
            XCTAssertEqual(presentation.currentMonthSubtotal, .notReturned)
            XCTAssertNil(presentation.rawDateRange)
            XCTAssertEqual(presentation.uniqueDayCount, 0)
            XCTAssertEqual(presentation.coverage, .unknown)
        }
    }

    func testReturnedEmptyDailyUsageIsKnownEmptyButNotNumericZero() throws {
        let snapshot = TokenActivitySnapshot(
            rawResponse: try rawFixture(named: "token_usage_empty")
        )
        let presentation = snapshot.derive(atUTC: utcDate(day: 13), calendar: utcCalendar())

        XCTAssertTrue(snapshot.dailyWasReturned)
        XCTAssertTrue(snapshot.daily.isEmpty)
        XCTAssertEqual(presentation.utcToday, .notReturned)
        XCTAssertEqual(presentation.currentMonthSubtotal, .notReturned)
        XCTAssertEqual(presentation.coverage, .reportedRange)
    }

    func testCompleteCurrentUTCMonthProducesAvailableTodayAndSubtotal() throws {
        let presentation = try presentation(fixture: "token_usage_full")

        XCTAssertEqual(presentation.utcToday, .available(13))
        XCTAssertEqual(presentation.currentMonthSubtotal, .available(91))
        XCTAssertEqual(presentation.rawDateRange, "2026-07-01"..."2026-07-13")
        XCTAssertEqual(presentation.uniqueDayCount, 13)
        XCTAssertEqual(presentation.coverage, .reportedRange)
    }

    func testMissingTodayIsNotReturnedAndMakesMonthPartialInsteadOfZero() throws {
        let rows = (1...12).map { row(day: $0, tokens: Int64($0)) }
        let presentation = try presentation(rows: rows)

        XCTAssertEqual(presentation.utcToday, .notReturned)
        assertPartial(presentation.currentMonthSubtotal, value: 78)
        XCTAssertEqual(presentation.coverage, .partial)
    }

    func testOnlyLegalHistoricalRowsDoNotInventACurrentMonthGap() throws {
        let presentation = try presentation(
            rows: [#"{"startDate":"2026-06-30","tokens":42}"#]
        )

        XCTAssertEqual(presentation.utcToday, .notReturned)
        XCTAssertEqual(presentation.currentMonthSubtotal, .notReturned)
        XCTAssertEqual(presentation.rawDateRange, "2026-06-30"..."2026-06-30")
        XCTAssertEqual(presentation.uniqueDayCount, 1)
        XCTAssertEqual(presentation.coverage, .reportedRange)
    }

    func testUnorderedCompleteRowsStillDeriveDeterministically() throws {
        let rows = (1...13).reversed().map { row(day: $0, tokens: Int64($0)) }
        let presentation = try presentation(rows: Array(rows))

        XCTAssertEqual(presentation.utcToday, .available(13))
        XCTAssertEqual(presentation.currentMonthSubtotal, .available(91))
        XCTAssertEqual(presentation.rawDateRange, "2026-07-01"..."2026-07-13")
        XCTAssertEqual(presentation.coverage, .reportedRange)
    }

    func testDuplicateTodayIsExcludedRatherThanChosenOrSummed() throws {
        var rows = (1...12).map { row(day: $0, tokens: Int64($0)) }
        rows.append(row(day: 13, tokens: 13))
        rows.append(row(day: 13, tokens: 130))

        let presentation = try presentation(rows: rows)

        XCTAssertEqual(presentation.utcToday, .unavailable)
        assertPartial(presentation.currentMonthSubtotal, value: 78)
        XCTAssertEqual(presentation.uniqueDayCount, 13)
        XCTAssertEqual(presentation.coverage, .partial)
    }

    func testCalendarGapNeverImpliesAZeroUsageDay() throws {
        let rows = (1...11).map { row(day: $0, tokens: Int64($0)) }
            + [row(day: 13, tokens: 13)]
        let presentation = try presentation(rows: rows)

        XCTAssertEqual(presentation.utcToday, .available(13))
        assertPartial(presentation.currentMonthSubtotal, value: 79)
        XCTAssertEqual(presentation.coverage, .partial)
    }

    func testFutureRowsAreExcludedAndMarkOtherwiseCompleteSubtotalPartial() throws {
        let rows = (1...14).map { row(day: $0, tokens: Int64($0)) }
        let presentation = try presentation(rows: rows)

        XCTAssertEqual(presentation.utcToday, .available(13))
        assertPartial(presentation.currentMonthSubtotal, value: 91)
        XCTAssertEqual(presentation.rawDateRange, "2026-07-01"..."2026-07-14")
        XCTAssertEqual(presentation.uniqueDayCount, 14)
        XCTAssertEqual(presentation.coverage, .partial)
    }

    func testInvalidDatesAndNegativeCountsCannotProduceNumericUsage() throws {
        let rows = [
            #"{"startDate":"not-a-date","tokens":9}"#,
            row(day: 13, tokens: -1)
        ]
        let presentation = try presentation(rows: rows)

        XCTAssertEqual(presentation.utcToday, .unavailable)
        XCTAssertEqual(presentation.currentMonthSubtotal, .unavailable)
        XCTAssertEqual(presentation.rawDateRange, "2026-07-13"..."2026-07-13")
        XCTAssertEqual(presentation.uniqueDayCount, 1)
        XCTAssertEqual(presentation.coverage, .partial)
    }

    func testNearValidNonCanonicalDateIsRejectedByStrictYYYYMMDDParser() throws {
        let presentation = try presentation(
            rows: [#"{"startDate":"2026-+7-13","tokens":42}"#]
        )

        XCTAssertEqual(presentation.utcToday, .notReturned)
        XCTAssertEqual(presentation.currentMonthSubtotal, .unavailable)
        XCTAssertNil(presentation.rawDateRange)
        XCTAssertEqual(presentation.uniqueDayCount, 0)
        XCTAssertEqual(presentation.coverage, .partial)
    }

    func testInt64OverflowReturnsOnlyARepresentablePartialSubtotal() throws {
        let rows = [
            row(day: 1, tokens: .max),
            row(day: 2, tokens: 1)
        ]
        let presentation = try presentation(rows: rows)

        XCTAssertEqual(presentation.utcToday, .notReturned)
        assertPartial(
            presentation.currentMonthSubtotal,
            value: .max,
            reasonContains: "overflow"
        )
        XCTAssertEqual(presentation.coverage, .partial)
    }

    func testPartialMonthBeginningMidMonthStaysExplicitlyPartial() throws {
        let rows = (10...13).map { row(day: $0, tokens: Int64($0)) }
        let presentation = try presentation(rows: rows)

        XCTAssertEqual(presentation.utcToday, .available(13))
        assertPartial(presentation.currentMonthSubtotal, value: 46)
        XCTAssertEqual(presentation.coverage, .partial)
    }

    func testCombinedAnomalyFixturePreservesRawOrderAndReportsPartialCoverage() throws {
        let response = try rawFixture(named: "token_usage_anomalies")
        let snapshot = TokenActivitySnapshot(rawResponse: response)
        let presentation = snapshot.derive(atUTC: utcDate(day: 13), calendar: utcCalendar())

        XCTAssertEqual(snapshot.daily.first?.rawDate, "2026-07-13")
        XCTAssertEqual(snapshot.daily.last?.rawDate, "2026-07-02")
        XCTAssertEqual(presentation.utcToday, .available(1))
        assertPartial(presentation.currentMonthSubtotal, value: .max)
        XCTAssertEqual(presentation.rawDateRange, "2026-07-02"..."2026-07-14")
        XCTAssertEqual(presentation.uniqueDayCount, 5)
        XCTAssertEqual(presentation.coverage, .partial)
    }

    func testUnknownClassifiedTokenKeysAreIgnoredAndNotExposed() throws {
        let response = try rawResponse(
            json: #"{"summary":{"lifetimeTokens":42,"inputTokens":10,"outputTokens":20,"cachedTokens":30,"reasoningTokens":40},"dailyUsageBuckets":[{"startDate":"2026-07-13","tokens":42,"inputTokens":10,"outputTokens":20}]}"#
        )
        let snapshot = TokenActivitySnapshot(rawResponse: response)
        let summaryLabels = Set(Mirror(reflecting: response.summary).children.compactMap(\.label))
        let snapshotLabels = Set(Mirror(reflecting: snapshot).children.compactMap(\.label))

        XCTAssertEqual(response.summary.lifetimeTokens, 42)
        XCTAssertEqual(snapshot.daily, [TokenActivityDay(rawDate: "2026-07-13", tokenCount: 42)])
        XCTAssertTrue(summaryLabels.isDisjoint(with: ["inputTokens", "outputTokens", "cachedTokens", "reasoningTokens"]))
        XCTAssertTrue(snapshotLabels.isDisjoint(with: ["inputTokens", "outputTokens", "cachedTokens", "reasoningTokens"]))
    }

    func testAccountActivityBreakdownsNeverInventInputOrOutputCounts() throws {
        let presentation = try presentation(fixture: "token_usage_full")

        XCTAssertEqual(presentation.utcTodayBreakdown.inputTokens, .notReturned)
        XCTAssertEqual(presentation.utcTodayBreakdown.outputTokens, .notReturned)
        XCTAssertEqual(presentation.utcTodayBreakdown.totalTokens, .available(13))
        XCTAssertEqual(
            presentation.currentMonthBreakdown.inputTokens,
            .notReturned
        )
        XCTAssertEqual(
            presentation.currentMonthBreakdown.outputTokens,
            .notReturned
        )
        XCTAssertEqual(
            presentation.currentMonthBreakdown.totalTokens,
            .available(91)
        )
    }

    private func presentation(fixture name: String) throws -> TokenActivityPresentation {
        TokenActivitySnapshot(rawResponse: try rawFixture(named: name))
            .derive(atUTC: utcDate(day: 13), calendar: utcCalendar())
    }

    private func presentation(rows: [String]) throws -> TokenActivityPresentation {
        let json = #"{"summary":{},"dailyUsageBuckets":["# + rows.joined(separator: ",") + "]}"
        return TokenActivitySnapshot(rawResponse: try rawResponse(json: json))
            .derive(atUTC: utcDate(day: 13), calendar: utcCalendar())
    }

    private func assertPartial(
        _ availability: MetricAvailability<Int64>,
        value expectedValue: Int64,
        reasonContains expectedReason: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .partial(value, reason) = availability else {
            return XCTFail("Expected partial, got \(availability)", file: file, line: line)
        }
        XCTAssertEqual(value, expectedValue, file: file, line: line)
        XCTAssertFalse(reason.isEmpty, file: file, line: line)
        if let expectedReason {
            XCTAssertTrue(
                reason.split(separator: ",").contains(Substring(expectedReason)),
                "Expected reason \(expectedReason), got \(reason)",
                file: file,
                line: line
            )
        }
    }

    private func rawFixture(named name: String) throws -> GetAccountTokenUsageRawResponse {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "json"))
        return try JSONDecoder().decode(
            GetAccountTokenUsageRawResponse.self,
            from: Data(contentsOf: url)
        )
    }

    private func rawResponse(json: String) throws -> GetAccountTokenUsageRawResponse {
        try JSONDecoder().decode(
            GetAccountTokenUsageRawResponse.self,
            from: Data(json.utf8)
        )
    }

    private func row(day: Int, tokens: Int64) -> String {
        String(format: #"{"startDate":"2026-07-%02d","tokens":%lld}"#, day, tokens)
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func utcDate(day: Int) -> Date {
        utcCalendar().date(from: DateComponents(year: 2026, month: 7, day: day))!
    }
}
