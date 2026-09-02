import Foundation
import XCTest
@testable import CodexQuotaMonitor

final class CapabilityStateTests: XCTestCase {
    func testSupportedCapabilityIsFreshWithExactValueAndDate() {
        let date = Date(timeIntervalSince1970: 1_700_000_000.125)
        let state: CapabilityState<String> = .fresh("supported", date)

        XCTAssertEqual(state, .fresh("supported", date))
    }

    func testMethodNotFoundIsUnsupportedAndNotAnyUnavailableFailure() {
        let methodNotFound: CapabilityState<Int> = .unsupported
        let failures: [CapabilityFailure] = [
            .unauthenticated,
            .unsupportedAuthMode,
            .invalidSchema,
            .temporaryTransport,
            .temporaryBackend,
            .serverRejected,
            .binaryNotFound,
            .trustValidationFailed,
            .processLaunchFailed,
            .stale
        ]

        for failure in failures {
            XCTAssertNotEqual(methodNotFound, .unavailable(failure))
        }
    }

    func testUnavailableCapabilityPreservesEveryFailureClassification() {
        let failures: [CapabilityFailure] = [
            .unauthenticated,
            .unsupportedAuthMode,
            .invalidSchema,
            .temporaryTransport,
            .temporaryBackend,
            .serverRejected,
            .binaryNotFound,
            .trustValidationFailed,
            .processLaunchFailed
        ]

        for failure in failures {
            let state: CapabilityState<Int> = .unavailable(failure)
            XCTAssertEqual(state, .unavailable(failure))
        }
    }

    func testStaleCapabilityPreservesLastGoodValueDateAndReason() {
        let lastSuccess = Date(timeIntervalSince1970: 1_800_000_000)
        let state: CapabilityState<Int> = .stale(42, lastSuccess, .stale)

        XCTAssertEqual(state, .stale(42, lastSuccess, .stale))
        XCTAssertNotEqual(state, .unavailable(.stale))
    }

    func testRateAndUsageCapabilityTransitionsRemainIndependent() {
        var rate: CapabilityState<String> = .fresh(
            "rate",
            Date(timeIntervalSince1970: 100)
        )
        var usage: CapabilityState<Int> = .fresh(
            200,
            Date(timeIntervalSince1970: 200)
        )

        rate = .unsupported
        XCTAssertEqual(rate, .unsupported)
        XCTAssertEqual(usage, .fresh(200, Date(timeIntervalSince1970: 200)))

        usage = .unavailable(.temporaryBackend)
        XCTAssertEqual(rate, .unsupported)
        XCTAssertEqual(usage, .unavailable(.temporaryBackend))
    }

    func testGenerationAdvancesOneAxisAndResetsOnlySubordinateAxes() throws {
        let token = GenerationToken(auth: 9, session: 8, connection: 7)

        XCTAssertEqual(
            try token.advanced(.auth),
            GenerationToken(auth: 10, session: 0, connection: 0)
        )
        XCTAssertEqual(
            try token.advanced(.session),
            GenerationToken(auth: 9, session: 9, connection: 0)
        )
        XCTAssertEqual(
            try token.advanced(.connection),
            GenerationToken(auth: 9, session: 8, connection: 8)
        )
    }

    func testGenerationAdvanceThrowsBeforeAnyAxisCanWrap() {
        let cases: [(GenerationToken, GenerationComponent)] = [
            (GenerationToken(auth: .max, session: 8, connection: 7), .auth),
            (GenerationToken(auth: 9, session: .max, connection: 7), .session),
            (GenerationToken(auth: 9, session: 8, connection: .max), .connection)
        ]

        for (token, component) in cases {
            XCTAssertThrowsError(try token.advanced(component)) { error in
                XCTAssertEqual(
                    error as? GenerationAdvanceError,
                    .overflow(component)
                )
            }
        }
    }

    func testAdvancedGenerationTuplesNeverAliasTheSourceOrEachOther() throws {
        let original = GenerationToken(auth: 1, session: 2, connection: 3)
        let tokens = try [
            original,
            original.advanced(.auth),
            original.advanced(.session),
            original.advanced(.connection)
        ]

        XCTAssertEqual(Set(tokens).count, tokens.count)
        XCTAssertEqual(Set(tokens), Set(tokens.reversed()))
    }
}
