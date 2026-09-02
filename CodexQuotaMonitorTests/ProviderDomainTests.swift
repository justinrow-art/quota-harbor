import Foundation
import XCTest
@testable import CodexQuotaMonitor

final class ProviderDomainTests: XCTestCase {
    func testProviderIDsHaveFixedProductOrder() {
        XCTAssertEqual(
            ProviderID.allCases,
            [.googleAntigravity, .codex, .claudeCode, .kimiCode]
        )
    }

    func testProviderIDsHaveStableRawAndCompactIdentifiers() {
        XCTAssertEqual(
            ProviderID.allCases.map(\.rawValue),
            ["google-antigravity", "codex", "claude-code", "kimi-code"]
        )
        XCTAssertEqual(
            ProviderID.allCases.map(\.compactIdentifier),
            ["G", "Cx", "Cl", "Ki"]
        )
    }

    func testSelectableProvidersAreFixedCodexAndOptionalClaudeOnly() {
        XCTAssertEqual(
            ProviderCatalog.selectableProviderIDs,
            [.codex, .claudeCode]
        )
    }

    func testProviderIDCodableRoundTripRejectsUnknownValues() throws {
        let encoded = try JSONEncoder().encode(ProviderID.allCases)

        XCTAssertEqual(
            try JSONDecoder().decode([ProviderID].self, from: encoded),
            ProviderID.allCases
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(ProviderID.self, from: Data("\"k3\"".utf8))
        )
    }

    func testProviderCapabilitiesDescribeSupportedFeaturesAndMetrics() throws {
        let metricKey = try XCTUnwrap(
            ProviderMetricKey(providerID: .codex, stableID: "five-hour-window")
        )
        let capabilities = try XCTUnwrap(
            ProviderCapabilities(
                providerID: .codex,
                capabilities: [.authenticationState, .quotaWindows, .tokenActivity],
                metricKeys: [metricKey]
            )
        )

        XCTAssertEqual(capabilities.providerID, .codex)
        XCTAssertEqual(
            capabilities.capabilities,
            [.authenticationState, .quotaWindows, .tokenActivity]
        )
        XCTAssertEqual(capabilities.metricKeys, [metricKey])
    }

    func testProviderCapabilitiesRejectMetricsOwnedByAnotherProvider() throws {
        let claudeMetric = try XCTUnwrap(
            ProviderMetricKey(providerID: .claudeCode, stableID: "status-line")
        )
        let capabilities: ProviderCapabilities? = ProviderCapabilities(
            providerID: .codex,
            capabilities: [.quotaWindows],
            metricKeys: [claudeMetric]
        )

        XCTAssertNil(capabilities)
    }

    func testProviderCapabilityCasesHaveStableOrder() {
        XCTAssertEqual(
            ProviderCapability.allCases,
            [
                .authenticationState,
                .quotaWindows,
                .tokenActivity,
                .localAppPresence,
                .officialUsageDestination,
                .statusLineRelay,
                .localCommandPresence,
            ]
        )
    }

    func testProviderCatalogHasFixedNonlocalizedDescriptors() throws {
        XCTAssertEqual(
            ProviderCatalog.descriptors.map(\.providerID),
            ProviderID.allCases
        )

        let google = try XCTUnwrap(
            ProviderCatalog.descriptor(for: .googleAntigravity)
        )
        XCTAssertEqual(
            google.capabilities,
            [.localAppPresence]
        )
        XCTAssertEqual(
            google.officialHelpURL.absoluteString,
            "https://www.antigravity.google/docs/settings"
        )
        XCTAssertNil(google.officialUsageDestinationURL)

        let codex = try XCTUnwrap(
            ProviderCatalog.descriptor(for: .codex)
        )
        XCTAssertEqual(
            codex.capabilities,
            [.authenticationState, .quotaWindows, .tokenActivity]
        )
        XCTAssertEqual(
            codex.officialHelpURL.absoluteString,
            "https://help.openai.com/en/articles/11369540-using-codex-with-your-chatgpt-plan"
        )
        XCTAssertNil(codex.officialUsageDestinationURL)

        let claude = try XCTUnwrap(
            ProviderCatalog.descriptor(for: .claudeCode)
        )
        XCTAssertEqual(
            claude.capabilities,
            [.authenticationState, .quotaWindows, .statusLineRelay]
        )
        XCTAssertEqual(
            claude.officialHelpURL.absoluteString,
            "https://code.claude.com/docs/en/statusline"
        )
        XCTAssertNil(claude.officialUsageDestinationURL)

        let kimi = try XCTUnwrap(
            ProviderCatalog.descriptor(for: .kimiCode)
        )
        XCTAssertEqual(
            kimi.capabilities,
            [.localCommandPresence, .officialUsageDestination]
        )
        XCTAssertEqual(
            kimi.officialHelpURL.absoluteString,
            "https://www.kimi.com/code/docs/en/"
        )
        XCTAssertEqual(
            kimi.officialUsageDestinationURL?.absoluteString,
            "https://www.kimi.com/code/console"
        )
    }

    func testProviderCatalogAllowsOnlyExactOfficialURLs() throws {
        let allowedURLs = ProviderCatalog.descriptors.flatMap { descriptor in
            [descriptor.officialHelpURL, descriptor.officialUsageDestinationURL]
                .compactMap { $0 }
        }

        for url in allowedURLs {
            XCTAssertTrue(ProviderCatalog.isAllowedExternalURL(url))
        }

        for rawURL in [
            "https://www.antigravity.google/docs/settings/",
            "https://www.antigravity.google/docs/settings?source=app",
            "https://antigravity.google/docs/settings",
            "https://www.antigravity.google.evil.example/docs/settings",
            "http://www.antigravity.google/docs/settings",
            "https://antigravity.google/docs/plans",
            "https://help.openai.com/en/articles/11369540-using-codex-with-your-chatgpt-plan/",
            "https://help.openai.com/en/articles/11369540-using-codex-with-your-chatgpt-plan?source=app",
            "https://help.openai.com.evil.example/en/articles/11369540-using-codex-with-your-chatgpt-plan",
            "http://help.openai.com/en/articles/11369540-using-codex-with-your-chatgpt-plan",
            "https://code.claude.com/docs/en/statusline#setup",
            "https://www.kimi.com/code/console/",
            "https://www.kimi.com.evil.example/code/console",
            "http://www.kimi.com/code/console",
        ] {
            let url = try XCTUnwrap(URL(string: rawURL))
            XCTAssertFalse(
                ProviderCatalog.isAllowedExternalURL(url),
                "Unexpectedly allowed \(rawURL)"
            )
        }
    }

    func testCodexRateWindowMetricKeyIsDeterministicAndHasNoFixedWindowLabels() throws {
        let identity = WindowIdentity(
            schemaVersion: 3,
            bucketKey: "codex/team + beta",
            sourceSlot: .secondary,
            durationMinutes: 360
        )

        let first = try XCTUnwrap(
            ProviderMetricKey.codexRateLimitWindow(identity)
        )
        let second = try XCTUnwrap(
            ProviderMetricKey.codexRateLimitWindow(identity)
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.providerID, .codex)
        XCTAssertFalse(first.stableID.contains("five-hour"))
        XCTAssertFalse(first.stableID.contains("weekly"))
        XCTAssertFalse(first.stableID.contains("5h"))
        XCTAssertFalse(first.stableID.contains("week"))
    }

    func testCodexRateWindowMetricKeyUniquelyEncodesEveryIdentityComponent() throws {
        let baseline = WindowIdentity(
            schemaVersion: 1,
            bucketKey: "codex",
            sourceSlot: .primary,
            durationMinutes: nil
        )
        let identities = [
            baseline,
            WindowIdentity(
                schemaVersion: 2,
                bucketKey: "codex",
                sourceSlot: .primary,
                durationMinutes: nil
            ),
            WindowIdentity(
                schemaVersion: 1,
                bucketKey: "codex/team",
                sourceSlot: .primary,
                durationMinutes: nil
            ),
            WindowIdentity(
                schemaVersion: 1,
                bucketKey: "codex",
                sourceSlot: .secondary,
                durationMinutes: nil
            ),
            WindowIdentity(
                schemaVersion: 1,
                bucketKey: "codex",
                sourceSlot: .primary,
                durationMinutes: 0
            ),
            WindowIdentity(
                schemaVersion: 1,
                bucketKey: "codex",
                sourceSlot: .primary,
                durationMinutes: 300
            ),
        ]

        let keys = try identities.map {
            try XCTUnwrap(ProviderMetricKey.codexRateLimitWindow($0))
        }

        XCTAssertEqual(Set(keys).count, identities.count)
        XCTAssertNotEqual(keys[0], keys[4], "Unknown duration collided with zero")
    }

    func testMaskedAccountIdentityMasksImmediatelyWithoutRetainingRawEmail() throws {
        let rawEmail = "alice" + "@" + "example.com"
        let identity = try XCTUnwrap(
            MaskedAccountIdentity.maskingEmail(rawEmail)
        )
        let summary = ProviderAccountSummary(maskedIdentity: identity)
        let exposures = [
            identity.description,
            String(reflecting: identity),
        ] + Mirror(reflecting: identity).children.map {
            String(describing: $0.value)
        }

        XCTAssertEqual(summary.maskedIdentity, identity)
        XCTAssertNotEqual(identity.description, rawEmail)
        for secret in [rawEmail, "alice", "example.com"] {
            for exposure in exposures {
                XCTAssertFalse(
                    exposure.contains(secret),
                    "Identity exposure leaked \(secret)"
                )
            }
        }
        XCTAssertFalse(MaskedAccountIdentity.self is any Encodable.Type)
        XCTAssertFalse(MaskedAccountIdentity.self is any Decodable.Type)
    }

    func testMaskedAccountIdentityRejectsMalformedAndOversizedEmail() {
        let separator = "@"
        for rawEmail in [
            "",
            "alice",
            separator + "example.com",
            "alice" + separator,
            "alice" + separator + separator + "example.com",
            " alice" + separator + "example.com",
            "alice" + separator + "example.com ",
            "alice\n" + separator + "example.com",
            ".alice" + separator + "example.com",
            "alice." + separator + "example.com",
            "alice..smith" + separator + "example.com",
            "alice" + separator + ".example.com",
            "alice" + separator + "example.com.",
            "alice" + separator + "example..com",
            String(repeating: "a", count: 65) + separator + "example.com",
            "alice" + separator + String(repeating: "d", count: 256),
            String(repeating: "a", count: 321) + separator + "example.com",
        ] {
            XCTAssertNil(
                MaskedAccountIdentity.maskingEmail(rawEmail),
                "Unexpectedly accepted \(rawEmail.prefix(32))"
            )
        }
    }

    func testConnectedAccountSummaryMayHaveNoIdentity() {
        let summary = ProviderAccountSummary(maskedIdentity: nil)

        XCTAssertNil(summary.maskedIdentity)
    }

    func testProviderMetricKeyRequiresNonemptyTrimmedStableID() {
        XCTAssertNotNil(
            ProviderMetricKey(providerID: .codex, stableID: "five-hour-window")
        )
        XCTAssertNil(ProviderMetricKey(providerID: .codex, stableID: ""))
        XCTAssertNil(ProviderMetricKey(providerID: .codex, stableID: "   "))
        XCTAssertNil(
            ProviderMetricKey(providerID: .codex, stableID: " five-hour-window")
        )
        XCTAssertNil(
            ProviderMetricKey(providerID: .codex, stableID: "five-hour-window\n")
        )
    }

    func testProviderMetricKeyDecodingRejectsInvalidStableID() throws {
        let invalidValues = ["", " ", " status-line", "status-line\n"]

        for stableID in invalidValues {
            let data = try JSONSerialization.data(
                withJSONObject: [
                    "providerID": "claude-code",
                    "stableID": stableID,
                ]
            )

            XCTAssertThrowsError(
                try JSONDecoder().decode(ProviderMetricKey.self, from: data)
            )
        }
    }

    func testPrimaryMetricPreferenceCodableRoundTrip() throws {
        let metricKey = try XCTUnwrap(
            ProviderMetricKey(providerID: .claudeCode, stableID: "status-line")
        )
        let preference = try XCTUnwrap(
            PrimaryMetricPreference(
                providerID: .claudeCode,
                metricKey: metricKey
            )
        )

        let encoded = try JSONEncoder().encode(preference)

        XCTAssertEqual(
            try JSONDecoder().decode(PrimaryMetricPreference.self, from: encoded),
            preference
        )
    }

    func testPrimaryMetricPreferenceRejectsMismatchedProvider() throws {
        let claudeMetric = try XCTUnwrap(
            ProviderMetricKey(providerID: .claudeCode, stableID: "status-line")
        )
        let preference: PrimaryMetricPreference? = PrimaryMetricPreference(
            providerID: .codex,
            metricKey: claudeMetric
        )

        XCTAssertNil(preference)
    }

    func testPrimaryMetricPreferenceDecodingRejectsMismatchedProvider() throws {
        let data = try JSONSerialization.data(
            withJSONObject: [
                "providerID": "codex",
                "metricKey": [
                    "providerID": "claude-code",
                    "stableID": "status-line",
                ],
            ]
        )

        XCTAssertThrowsError(
            try JSONDecoder().decode(PrimaryMetricPreference.self, from: data)
        )
    }
}
