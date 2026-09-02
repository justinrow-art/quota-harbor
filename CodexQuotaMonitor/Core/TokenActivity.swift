import Foundation

struct GetAccountTokenUsageRawResponse: Decodable, Equatable, Sendable {
    let summary: AccountTokenUsageSummaryRaw
    let dailyUsageBuckets: [AccountTokenUsageDayRaw]?
}

struct AccountTokenUsageSummaryRaw: Decodable, Equatable, Sendable {
    let lifetimeTokens: Int64?
    let peakDailyTokens: Int64?
    let longestRunningTurnSec: Int64?
    let currentStreakDays: Int64?
    let longestStreakDays: Int64?
}

struct AccountTokenUsageDayRaw: Decodable, Equatable, Sendable {
    let startDate: String
    let tokens: Int64
}

enum MetricAvailability<Value: Equatable & Sendable>: Equatable, Sendable {
    case available(Value)
    case partial(Value, reason: String)
    case notReturned
    case unavailable
}

struct TokenActivityDay: Equatable, Sendable {
    let rawDate: String
    let tokenCount: Int64
}

struct TokenActivityBreakdown: Equatable, Sendable {
    let inputTokens: MetricAvailability<Int64>
    let outputTokens: MetricAvailability<Int64>
    let totalTokens: MetricAvailability<Int64>
}

enum ActivityCoverage: Equatable, Sendable {
    case reportedRange
    case partial
    case unknown
}

struct TokenActivityPresentation: Equatable, Sendable {
    let utcToday: MetricAvailability<Int64>
    let currentMonthSubtotal: MetricAvailability<Int64>
    let rawDateRange: ClosedRange<String>?
    let uniqueDayCount: Int
    let coverage: ActivityCoverage

    var utcTodayBreakdown: TokenActivityBreakdown {
        TokenActivityBreakdown(
            inputTokens: .notReturned,
            outputTokens: .notReturned,
            totalTokens: utcToday
        )
    }

    var currentMonthBreakdown: TokenActivityBreakdown {
        TokenActivityBreakdown(
            inputTokens: .notReturned,
            outputTokens: .notReturned,
            totalTokens: currentMonthSubtotal
        )
    }
}

struct TokenActivitySnapshot: Equatable, Sendable {
    let lifetimeTokens: Int64?
    let peakDailyTokens: Int64?
    let longestRunningTurnSec: Int64?
    let currentStreakDays: Int64?
    let longestStreakDays: Int64?
    let daily: [TokenActivityDay]
    let dailyWasReturned: Bool

    init(rawResponse: GetAccountTokenUsageRawResponse) {
        lifetimeTokens = rawResponse.summary.lifetimeTokens
        peakDailyTokens = rawResponse.summary.peakDailyTokens
        longestRunningTurnSec = rawResponse.summary.longestRunningTurnSec
        currentStreakDays = rawResponse.summary.currentStreakDays
        longestStreakDays = rawResponse.summary.longestStreakDays
        daily = (rawResponse.dailyUsageBuckets ?? []).map {
            TokenActivityDay(rawDate: $0.startDate, tokenCount: $0.tokens)
        }
        dailyWasReturned = rawResponse.dailyUsageBuckets != nil
    }

    func derive(
        atUTC now: Date,
        calendar _: Calendar
    ) -> TokenActivityPresentation {
        guard dailyWasReturned else {
            return TokenActivityPresentation(
                utcToday: .notReturned,
                currentMonthSubtotal: .notReturned,
                rawDateRange: nil,
                uniqueDayCount: 0,
                coverage: .unknown
            )
        }

        guard !daily.isEmpty else {
            return TokenActivityPresentation(
                utcToday: .notReturned,
                currentMonthSubtotal: .notReturned,
                rawDateRange: nil,
                uniqueDayCount: 0,
                coverage: .reportedRange
            )
        }

        let calendar = Self.utcCalendar()
        let today = calendar.startOfDay(for: now)
        let todayComponents = calendar.dateComponents([.year, .month, .day], from: today)

        var issues = Set<DerivationIssue>()
        var parsedRows: [ParsedRow] = []
        for day in daily {
            guard let date = Self.parseDate(day.rawDate, calendar: calendar) else {
                issues.insert(.invalidDate)
                continue
            }
            if day.tokenCount < 0 {
                issues.insert(.negativeCount)
            }
            if date > today {
                issues.insert(.futureDate)
            }
            parsedRows.append(ParsedRow(day: day, date: date))
        }

        let groups = Dictionary(grouping: parsedRows, by: \.date)
        if groups.values.contains(where: { $0.count > 1 }) {
            issues.insert(.duplicateDate)
        }

        let uniqueRawDates = Set(parsedRows.map(\.day.rawDate))
        let sortedRawDates = uniqueRawDates.sorted()
        let rawDateRange = sortedRawDates.first.flatMap { first in
            sortedRawDates.last.map { first...$0 }
        }

        let todayAvailability = Self.todayAvailability(
            rows: groups[today] ?? []
        )

        let eligibleRows = groups
            .compactMap { date, rows -> ParsedRow? in
                guard rows.count == 1, let row = rows.first else { return nil }
                guard row.day.tokenCount >= 0, date <= today else { return nil }
                let components = calendar.dateComponents([.year, .month], from: date)
                guard components.year == todayComponents.year,
                      components.month == todayComponents.month else {
                    return nil
                }
                return row
            }
            .sorted { $0.date < $1.date }

        let expectedDayCount = todayComponents.day ?? 0
        if !eligibleRows.isEmpty,
           Set(eligibleRows.map(\.date)).count != expectedDayCount {
            issues.insert(.calendarGap)
        }

        var subtotal: Int64 = 0
        var summedRowCount = 0
        for row in eligibleRows {
            let addition = subtotal.addingReportingOverflow(row.day.tokenCount)
            guard !addition.overflow else {
                issues.insert(.overflow)
                continue
            }
            subtotal = addition.partialValue
            summedRowCount += 1
        }

        let monthAvailability: MetricAvailability<Int64>
        if summedRowCount == 0 {
            let substantiveIssues = issues.subtracting([.calendarGap])
            monthAvailability = substantiveIssues.isEmpty ? .notReturned : .unavailable
        } else if issues.isEmpty {
            monthAvailability = .available(subtotal)
        } else {
            monthAvailability = .partial(
                subtotal,
                reason: issues
                    .sorted { $0.rawValue < $1.rawValue }
                    .map(\.rawValue)
                    .joined(separator: ",")
            )
        }

        return TokenActivityPresentation(
            utcToday: todayAvailability,
            currentMonthSubtotal: monthAvailability,
            rawDateRange: rawDateRange,
            uniqueDayCount: uniqueRawDates.count,
            coverage: issues.isEmpty ? .reportedRange : .partial
        )
    }

    private static func todayAvailability(
        rows: [ParsedRow]
    ) -> MetricAvailability<Int64> {
        guard !rows.isEmpty else { return .notReturned }
        guard rows.count == 1,
              let tokenCount = rows.first?.day.tokenCount,
              tokenCount >= 0 else {
            return .unavailable
        }
        return .available(tokenCount)
    }

    private static func parseDate(
        _ rawDate: String,
        calendar: Calendar
    ) -> Date? {
        let bytes = Array(rawDate.utf8)
        guard bytes.count == 10,
              bytes[4] == 45,
              bytes[7] == 45,
              bytes.enumerated().allSatisfy({ index, byte in
                  if index == 4 || index == 7 { return true }
                  return (48...57).contains(byte)
              }) else {
            return nil
        }
        let parts = rawDate.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[2].count == 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              let date = calendar.date(
                from: DateComponents(year: year, month: month, day: day)
              ) else {
            return nil
        }

        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        guard roundTrip.year == year,
              roundTrip.month == month,
              roundTrip.day == day else {
            return nil
        }
        return calendar.startOfDay(for: date)
    }

    private static func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}

private struct ParsedRow {
    let day: TokenActivityDay
    let date: Date
}

private enum DerivationIssue: String, Hashable {
    case calendarGap
    case duplicateDate
    case futureDate
    case invalidDate
    case negativeCount
    case overflow
}
