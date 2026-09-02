import Foundation

enum ProviderID: String, Codable, CaseIterable, CodingKey, CodingKeyRepresentable, Equatable, Hashable, Sendable {
    case googleAntigravity = "google-antigravity"
    case codex = "codex"
    case claudeCode = "claude-code"
    case kimiCode = "kimi-code"

    var compactIdentifier: String {
        switch self {
        case .googleAntigravity: "G"
        case .codex: "Cx"
        case .claudeCode: "Cl"
        case .kimiCode: "Ki"
        }
    }
}

enum ProviderCapability: CaseIterable, Equatable, Hashable, Sendable {
    case authenticationState
    case quotaWindows
    case tokenActivity
    case localAppPresence
    case officialUsageDestination
    case statusLineRelay
    case localCommandPresence
}

struct ProviderDescriptor: Equatable, Sendable {
    let providerID: ProviderID
    let capabilities: Set<ProviderCapability>
    let officialHelpURL: URL
    let officialUsageDestinationURL: URL?
}

enum ProviderCatalog {
    static let selectableProviderIDs: [ProviderID] = [.codex, .claudeCode]

    static let descriptors: [ProviderDescriptor] = [
        ProviderDescriptor(
            providerID: .googleAntigravity,
            capabilities: [.localAppPresence],
            officialHelpURL: URL(
                string: "https://www.antigravity.google/docs/settings"
            )!,
            officialUsageDestinationURL: nil
        ),
        ProviderDescriptor(
            providerID: .codex,
            capabilities: [
                .authenticationState,
                .quotaWindows,
                .tokenActivity,
            ],
            officialHelpURL: URL(
                string: "https://help.openai.com/en/articles/11369540-using-codex-with-your-chatgpt-plan"
            )!,
            officialUsageDestinationURL: nil
        ),
        ProviderDescriptor(
            providerID: .claudeCode,
            capabilities: [
                .authenticationState,
                .quotaWindows,
                .statusLineRelay,
            ],
            officialHelpURL: URL(
                string: "https://code.claude.com/docs/en/statusline"
            )!,
            officialUsageDestinationURL: nil
        ),
        ProviderDescriptor(
            providerID: .kimiCode,
            capabilities: [
                .localCommandPresence,
                .officialUsageDestination,
            ],
            officialHelpURL: URL(
                string: "https://www.kimi.com/code/docs/en/"
            )!,
            officialUsageDestinationURL: URL(
                string: "https://www.kimi.com/code/console"
            )!
        ),
    ]

    static func descriptor(for providerID: ProviderID) -> ProviderDescriptor? {
        descriptors.first { $0.providerID == providerID }
    }

    static func isAllowedExternalURL(_ url: URL) -> Bool {
        allowedExternalURLStrings.contains(url.absoluteString)
    }

    private static let allowedExternalURLStrings = Set(
        descriptors.flatMap { descriptor in
            [descriptor.officialHelpURL, descriptor.officialUsageDestinationURL]
                .compactMap { $0?.absoluteString }
        }
    )
}

struct ProviderMetricKey: Codable, Equatable, Hashable, Sendable {
    let providerID: ProviderID
    let stableID: String

    init?(providerID: ProviderID, stableID: String) {
        guard Self.isValidStableID(stableID) else {
            return nil
        }
        self.providerID = providerID
        self.stableID = stableID
    }

    private enum CodingKeys: String, CodingKey {
        case providerID
        case stableID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let providerID = try container.decode(ProviderID.self, forKey: .providerID)
        let stableID = try container.decode(String.self, forKey: .stableID)
        guard let value = Self(providerID: providerID, stableID: stableID) else {
            throw DecodingError.dataCorruptedError(
                forKey: .stableID,
                in: container,
                debugDescription: "Metric stable ID must be nonempty and trimmed."
            )
        }
        self = value
    }

    static func isValidStableID(_ stableID: String) -> Bool {
        !stableID.isEmpty
            && stableID.trimmingCharacters(in: .whitespacesAndNewlines) == stableID
    }

    static func codexRateLimitWindow(
        _ identity: WindowIdentity
    ) -> ProviderMetricKey? {
        let bucketKey = Data(identity.bucketKey.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let duration = identity.durationMinutes.map { "m\($0)" } ?? "unknown"
        let stableID = [
            "rate-window-v1",
            "schema-\(identity.schemaVersion)",
            "bucket-\(bucketKey)",
            "slot-\(identity.sourceSlot.rawValue)",
            "duration-\(duration)",
        ].joined(separator: "/")
        return ProviderMetricKey(providerID: .codex, stableID: stableID)
    }
}

struct MaskedAccountIdentity: Equatable, Sendable, CustomStringConvertible {
    private let maskedValue: String

    var description: String {
        maskedValue
    }

    static func maskingEmail(_ rawEmail: String) -> MaskedAccountIdentity? {
        let bytes = Array(rawEmail.utf8)
        guard !bytes.isEmpty,
              bytes.count <= 320,
              bytes.allSatisfy({ (33...126).contains($0) })
        else {
            return nil
        }

        let parts = rawEmail.split(
            separator: "@",
            omittingEmptySubsequences: false
        )
        guard parts.count == 2 else { return nil }

        let local = parts[0]
        let domain = parts[1]
        guard !local.isEmpty,
              local.utf8.count <= 64,
              !domain.isEmpty,
              domain.utf8.count <= 255,
              !local.hasPrefix("."),
              !local.hasSuffix("."),
              !local.contains(".."),
              !domain.hasPrefix("."),
              !domain.hasSuffix("."),
              !domain.contains(".."),
              domain.utf8.allSatisfy({ byte in
                  (48...57).contains(byte)
                      || (65...90).contains(byte)
                      || (97...122).contains(byte)
                      || byte == 45
                      || byte == 46
              })
        else {
            return nil
        }

        let masked = "\(mask(local))@\(mask(domain))"
        guard !masked.contains(local),
              !masked.contains(domain),
              !masked.contains(rawEmail)
        else {
            return nil
        }
        return MaskedAccountIdentity(maskedValue: masked)
    }

    private static func mask(_ value: Substring) -> String {
        guard value.count > 1, let first = value.first else {
            return "•••"
        }
        return "\(first)•••"
    }
}

struct ProviderAccountSummary: Equatable, Sendable {
    let maskedIdentity: MaskedAccountIdentity?
}

struct ProviderCapabilities: Equatable, Hashable, Sendable {
    let providerID: ProviderID
    let capabilities: Set<ProviderCapability>
    let metricKeys: [ProviderMetricKey]

    init?(
        providerID: ProviderID,
        capabilities: Set<ProviderCapability>,
        metricKeys: [ProviderMetricKey]
    ) {
        guard metricKeys.allSatisfy({ $0.providerID == providerID }) else {
            return nil
        }
        self.providerID = providerID
        self.capabilities = capabilities
        self.metricKeys = metricKeys
    }
}

struct PrimaryMetricPreference: Codable, Equatable, Hashable, Sendable {
    let providerID: ProviderID
    let metricKey: ProviderMetricKey

    init?(providerID: ProviderID, metricKey: ProviderMetricKey) {
        guard providerID == metricKey.providerID else {
            return nil
        }
        self.providerID = providerID
        self.metricKey = metricKey
    }

    private enum CodingKeys: String, CodingKey {
        case providerID
        case metricKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let providerID = try container.decode(ProviderID.self, forKey: .providerID)
        let metricKey = try container.decode(ProviderMetricKey.self, forKey: .metricKey)
        guard let value = Self(providerID: providerID, metricKey: metricKey) else {
            throw DecodingError.dataCorruptedError(
                forKey: .metricKey,
                in: container,
                debugDescription: "Preference and metric providers must match."
            )
        }
        self = value
    }
}
