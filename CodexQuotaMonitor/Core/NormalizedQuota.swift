import Foundation

struct GetAccountRateLimitsRawResponse: Decodable, Equatable, Sendable {
    let rateLimits: RateLimitSnapshotRaw
    let rateLimitsByLimitId: [String: RateLimitSnapshotRaw]?
    let rateLimitResetCredits: RateLimitResetCreditsSummaryRaw?

    init(
        rateLimits: RateLimitSnapshotRaw,
        rateLimitsByLimitId: [String: RateLimitSnapshotRaw]? = nil,
        rateLimitResetCredits: RateLimitResetCreditsSummaryRaw? = nil
    ) {
        self.rateLimits = rateLimits
        self.rateLimitsByLimitId = rateLimitsByLimitId
        self.rateLimitResetCredits = rateLimitResetCredits
    }
}

struct RateLimitResetCreditsSummaryRaw: Decodable, Equatable, Sendable {
    let availableCount: Int64
    let credits: [RateLimitResetCreditRaw]?
}

struct RateLimitResetCreditRaw: Decodable, Equatable, Sendable {
    let description: String?
    let expiresAt: Int64?
    let grantedAt: Int64
    let id: String
    let resetType: String
    let status: String
    let title: String?
}

struct RateLimitSnapshotRaw: Decodable, Equatable, Sendable {
    let planType: String?
    let primary: RateLimitWindowRaw?
    let secondary: RateLimitWindowRaw?
    let limitId: String?
    let limitName: String?
    let credits: CreditsSnapshotRaw?
    let individualLimit: SpendControlLimitSnapshotRaw?
    let rateLimitReachedType: String?

    init(
        planType: String?,
        primary: RateLimitWindowRaw?,
        secondary: RateLimitWindowRaw?,
        limitId: String? = nil,
        limitName: String? = nil,
        credits: CreditsSnapshotRaw? = nil,
        individualLimit: SpendControlLimitSnapshotRaw? = nil,
        rateLimitReachedType: String? = nil
    ) {
        self.planType = planType
        self.primary = primary
        self.secondary = secondary
        self.limitId = limitId
        self.limitName = limitName
        self.credits = credits
        self.individualLimit = individualLimit
        self.rateLimitReachedType = rateLimitReachedType
    }
}

struct CreditsSnapshotRaw: Decodable, Equatable, Sendable {
    let balance: String?
    let hasCredits: Bool
    let unlimited: Bool
}

struct SpendControlLimitSnapshotRaw: Decodable, Equatable, Sendable {
    let limit: String
    let remainingPercent: Int
    let resetsAt: Int64
    let used: String
}

struct RateLimitWindowRaw: Decodable, Equatable, Sendable {
    let usedPercent: Int
    let windowDurationMins: Int64?
    let resetsAt: Int64?
}

enum PlanType: Equatable, Sendable {
    case free
    case go
    case plus
    case pro
    case prolite
    case team
    case selfServeBusinessUsageBased
    case business
    case enterpriseCBPUsageBased
    case enterprise
    case edu
    case unknown(String)

    init(rawValue: String) {
        switch rawValue {
        case "free": self = .free
        case "go": self = .go
        case "plus": self = .plus
        case "pro": self = .pro
        case "prolite": self = .prolite
        case "team": self = .team
        case "self_serve_business_usage_based": self = .selfServeBusinessUsageBased
        case "business": self = .business
        case "enterprise_cbp_usage_based": self = .enterpriseCBPUsageBased
        case "enterprise": self = .enterprise
        case "edu": self = .edu
        default: self = .unknown(rawValue)
        }
    }
}

enum QuotaNormalizationError: Error, Equatable, Sendable {
    case invalidUsedPercent(Int)
    case noWindows
}

struct NormalizedQuota: Equatable, Sendable {
    let planType: PlanType?
    let primary: NormalizedWindow?
    let secondary: NormalizedWindow?

    init(rawResponse: GetAccountRateLimitsRawResponse) throws {
        let catalog = try RateLimitCatalog(rawResponse: rawResponse)
        try self.init(bucket: catalog.compatibilityBucket)
    }

    init(catalog: RateLimitCatalog) throws {
        try self.init(bucket: catalog.selectedBucket)
    }

    private init(bucket: RateLimitBucket) throws {
        guard !bucket.windows.isEmpty else {
            throw QuotaNormalizationError.noWindows
        }
        planType = bucket.planType
        primary = bucket.windows
            .first { $0.identity.sourceSlot == .primary }
            .map(NormalizedWindow.init(window:))
        secondary = bucket.windows
            .first { $0.identity.sourceSlot == .secondary }
            .map(NormalizedWindow.init(window:))
    }
}

struct NormalizedWindow: Equatable, Sendable {
    enum Duration: Equatable, Sendable {
        case fiveHours
        case weekly
        case custom(minutes: Int64?)
    }

    let usedPercent: Int
    let remainingPercent: Int
    let duration: Duration
    let resetsAt: Date?

    init(window: RateLimitWindow) {
        usedPercent = window.usedPercent
        remainingPercent = window.remainingPercent
        duration = switch window.durationMinutes {
        case 300: .fiveHours
        case 10_080: .weekly
        case let minutes: .custom(minutes: minutes)
        }
        resetsAt = window.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }
}
