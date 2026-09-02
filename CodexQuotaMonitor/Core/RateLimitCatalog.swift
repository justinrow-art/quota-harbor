enum SourceSlot: String, Codable, Hashable, Sendable {
    case primary
    case secondary
}

struct WindowIdentity: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let bucketKey: String
    let sourceSlot: SourceSlot
    let durationMinutes: Int64?

    init(
        schemaVersion: Int = 1,
        bucketKey: String,
        sourceSlot: SourceSlot,
        durationMinutes: Int64?
    ) {
        self.schemaVersion = schemaVersion
        self.bucketKey = bucketKey
        self.sourceSlot = sourceSlot
        self.durationMinutes = durationMinutes
    }
}

struct RateLimitWindow: Equatable, Sendable {
    let identity: WindowIdentity
    let usedPercent: Int
    let remainingPercent: Int
    let durationMinutes: Int64?
    let resetsAt: Int64?

    init(identity: WindowIdentity, usedPercent: Int, resetsAt: Int64?) throws {
        guard (0...100).contains(usedPercent) else {
            throw QuotaNormalizationError.invalidUsedPercent(usedPercent)
        }

        self.identity = identity
        self.usedPercent = usedPercent
        remainingPercent = 100 - usedPercent
        durationMinutes = identity.durationMinutes
        self.resetsAt = resetsAt
    }
}

struct RateLimitBucket: Equatable, Sendable {
    let bucketKey: String
    let limitId: String?
    let limitName: String?
    let planType: PlanType?
    let credits: CreditsSnapshotRaw?
    let individualLimit: SpendControlLimitSnapshotRaw?
    let rateLimitReachedType: String?
    let windows: [RateLimitWindow]

    init(
        bucketKey: String,
        limitId: String? = nil,
        limitName: String? = nil,
        planType: PlanType? = nil,
        credits: CreditsSnapshotRaw? = nil,
        individualLimit: SpendControlLimitSnapshotRaw? = nil,
        rateLimitReachedType: String? = nil,
        windows: [RateLimitWindow]
    ) {
        self.bucketKey = bucketKey
        self.limitId = limitId
        self.limitName = limitName
        self.planType = planType
        self.credits = credits
        self.individualLimit = individualLimit
        self.rateLimitReachedType = rateLimitReachedType
        self.windows = windows
    }

    init(bucketKey: String, rawSnapshot: RateLimitSnapshotRaw) throws {
        self.bucketKey = bucketKey
        limitId = rawSnapshot.limitId
        limitName = rawSnapshot.limitName
        planType = rawSnapshot.planType.map(PlanType.init(rawValue:))
        credits = rawSnapshot.credits
        individualLimit = rawSnapshot.individualLimit
        rateLimitReachedType = rawSnapshot.rateLimitReachedType

        var windows: [RateLimitWindow] = []
        if let primary = rawSnapshot.primary {
            try windows.append(
                RateLimitWindow(
                    identity: WindowIdentity(
                        bucketKey: bucketKey,
                        sourceSlot: .primary,
                        durationMinutes: primary.windowDurationMins
                    ),
                    usedPercent: primary.usedPercent,
                    resetsAt: primary.resetsAt
                )
            )
        }
        if let secondary = rawSnapshot.secondary {
            try windows.append(
                RateLimitWindow(
                    identity: WindowIdentity(
                        bucketKey: bucketKey,
                        sourceSlot: .secondary,
                        durationMinutes: secondary.windowDurationMins
                    ),
                    usedPercent: secondary.usedPercent,
                    resetsAt: secondary.resetsAt
                )
            )
        }
        self.windows = windows
    }
}

enum RateLimitSelectionProvenance: Equatable, Sendable {
    case preferredBucket(bucketKey: String)
    case deterministicFallback(bucketKey: String)
    case legacyFallback
}

struct RateLimitCatalog: Equatable, Sendable {
    static let legacyBucketKey = "__legacy__"

    let rateLimitsByLimitId: [String: RateLimitBucket]
    let legacyBucket: RateLimitBucket
    let rateLimitResetCredits: RateLimitResetCreditsSummaryRaw?
    let selectedBucket: RateLimitBucket
    let selectionProvenance: RateLimitSelectionProvenance

    var compatibilityBucket: RateLimitBucket {
        rateLimitsByLimitId["codex"] ?? legacyBucket
    }

    init(
        rateLimitsByLimitId: [String: RateLimitBucket],
        legacyBucket: RateLimitBucket,
        rateLimitResetCredits: RateLimitResetCreditsSummaryRaw? = nil
    ) {
        self.rateLimitsByLimitId = rateLimitsByLimitId
        self.legacyBucket = legacyBucket
        self.rateLimitResetCredits = rateLimitResetCredits

        let selection = Self.selection(
            rateLimitsByLimitId: rateLimitsByLimitId,
            legacyBucket: legacyBucket,
            preferredBucket: "codex"
        )
        selectedBucket = selection.bucket
        selectionProvenance = selection.provenance
    }

    init(rawResponse: GetAccountRateLimitsRawResponse) throws {
        var buckets: [String: RateLimitBucket] = [:]
        for bucketKey in (rawResponse.rateLimitsByLimitId ?? [:]).keys.sorted() {
            if let snapshot = rawResponse.rateLimitsByLimitId?[bucketKey] {
                buckets[bucketKey] = try RateLimitBucket(
                    bucketKey: bucketKey,
                    rawSnapshot: snapshot
                )
            }
        }

        let legacyBucket = try RateLimitBucket(
            bucketKey: Self.legacyBucketKey,
            rawSnapshot: rawResponse.rateLimits
        )

        rateLimitsByLimitId = buckets
        self.legacyBucket = legacyBucket
        rateLimitResetCredits = rawResponse.rateLimitResetCredits

        let selection = Self.selection(
            rateLimitsByLimitId: buckets,
            legacyBucket: legacyBucket,
            preferredBucket: "codex"
        )
        selectedBucket = selection.bucket
        selectionProvenance = selection.provenance
    }

    func automaticWindows(
        preferredBucket: String = "codex",
        limit: Int = 2
    ) -> [RateLimitWindow] {
        guard limit > 0 else { return [] }

        let bucket = Self.selection(
            rateLimitsByLimitId: rateLimitsByLimitId,
            legacyBucket: legacyBucket,
            preferredBucket: preferredBucket
        ).bucket

        return Array(
            sortedWindows(in: bucket)
                .prefix(min(limit, 2))
        )
    }

    func sortedWindows(in bucket: RateLimitBucket) -> [RateLimitWindow] {
        bucket.windows.sorted(by: Self.windowComesBefore)
    }

    func liveWindowIdentities() -> [WindowIdentity] {
        let buckets: [RateLimitBucket]
        if rateLimitsByLimitId.isEmpty {
            buckets = [legacyBucket]
        } else {
            buckets = rateLimitsByLimitId.keys.sorted().compactMap {
                rateLimitsByLimitId[$0]
            }
        }
        return buckets.flatMap { bucket in
            sortedWindows(in: bucket).map(\.identity)
        }
    }

    private static func windowComesBefore(
        _ lhs: RateLimitWindow,
        _ rhs: RateLimitWindow
    ) -> Bool {
        let lhsDurationPriority = durationPriority(lhs.durationMinutes)
        let rhsDurationPriority = durationPriority(rhs.durationMinutes)
        if lhsDurationPriority != rhsDurationPriority {
            return lhsDurationPriority < rhsDurationPriority
        }

        let lhsSlot = slotOrder(lhs.identity.sourceSlot)
        let rhsSlot = slotOrder(rhs.identity.sourceSlot)
        if lhsSlot != rhsSlot {
            return lhsSlot < rhsSlot
        }

        if lhs.durationMinutes != rhs.durationMinutes {
            switch (lhs.durationMinutes, rhs.durationMinutes) {
            case let (lhsMinutes?, rhsMinutes?): return lhsMinutes < rhsMinutes
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): break
            }
        }

        return identityComesBefore(lhs.identity, rhs.identity)
    }

    private static func durationPriority(_ durationMinutes: Int64?) -> Int {
        switch durationMinutes {
        case 300: 0
        case 10_080: 1
        default: 2
        }
    }

    private static func slotOrder(_ sourceSlot: SourceSlot) -> Int {
        switch sourceSlot {
        case .primary: 0
        case .secondary: 1
        }
    }

    private static func identityComesBefore(
        _ lhs: WindowIdentity,
        _ rhs: WindowIdentity
    ) -> Bool {
        if lhs.schemaVersion != rhs.schemaVersion {
            return lhs.schemaVersion < rhs.schemaVersion
        }
        if lhs.bucketKey != rhs.bucketKey {
            return lhs.bucketKey < rhs.bucketKey
        }
        if lhs.sourceSlot != rhs.sourceSlot {
            return slotOrder(lhs.sourceSlot) < slotOrder(rhs.sourceSlot)
        }
        switch (lhs.durationMinutes, rhs.durationMinutes) {
        case let (lhsMinutes?, rhsMinutes?): return lhsMinutes < rhsMinutes
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return false
        }
    }

    private static func selection(
        rateLimitsByLimitId: [String: RateLimitBucket],
        legacyBucket: RateLimitBucket,
        preferredBucket: String
    ) -> (bucket: RateLimitBucket, provenance: RateLimitSelectionProvenance) {
        if let preferred = rateLimitsByLimitId[preferredBucket] {
            return (
                preferred,
                .preferredBucket(bucketKey: preferredBucket)
            )
        }
        if let fallbackKey = rateLimitsByLimitId.keys.sorted().first,
           let fallback = rateLimitsByLimitId[fallbackKey] {
            return (
                fallback,
                .deterministicFallback(bucketKey: fallbackKey)
            )
        }
        return (legacyBucket, .legacyFallback)
    }
}
