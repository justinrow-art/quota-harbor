import Foundation
import XCTest
@testable import CodexQuotaMonitor

@MainActor
final class CodexRPCClientTests: XCTestCase {
    func testInitializeWaitsForMatchingIDAndEncodesClientInfo() async throws {
        let transport = FakeLineTransport(events: [
            .line(#"{"id":"unrelated","result":{}}"#),
            .line(#"{"id":999,"result":{}}"#),
            .line(#"{"id":1,"result":{}}"#),
        ])
        let client = CodexRPCClient(transport: transport, requestTimeout: .seconds(1))

        try await client.initialize(
            clientInfo: ClientInfo(name: "quota-monitor", version: "1.2.3", title: "Quota Monitor")
        )

        let request = try await sentObject(from: transport)
        XCTAssertEqual(request["method"] as? String, "initialize")
        XCTAssertEqual(request["id"] as? Int, 1)
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        let clientInfo = try XCTUnwrap(params["clientInfo"] as? [String: Any])
        XCTAssertEqual(clientInfo["name"] as? String, "quota-monitor")
        XCTAssertEqual(clientInfo["version"] as? String, "1.2.3")
        XCTAssertEqual(clientInfo["title"] as? String, "Quota Monitor")
    }

    func testSendInitializedWritesOnlyTheInitializedNotification() async throws {
        let transport = FakeLineTransport()
        let client = CodexRPCClient(transport: transport)

        try await client.sendInitialized()

        let notification = try await sentObject(from: transport)
        XCTAssertEqual(notification["method"] as? String, "initialized")
        XCTAssertNil(notification["id"])
    }

    func testReadRateLimitsUsesReadMethodAndDecodesResult() async throws {
        let transport = FakeLineTransport(events: [
            .line(Self.rateLimitsResponse(id: 1)),
        ])
        let client = CodexRPCClient(transport: transport, requestTimeout: .seconds(1))

        let response = try await client.readRateLimits()

        XCTAssertEqual(response.rateLimits.planType, "plus")
        XCTAssertEqual(response.rateLimits.primary?.usedPercent, 10)
        let request = try await sentObject(from: transport)
        XCTAssertEqual(request["method"] as? String, "account/rateLimits/read")
        XCTAssertEqual(request["id"] as? Int, 1)
        XCTAssertTrue(request["params"] == nil || request["params"] is NSNull)
    }

    func testNotificationIsIgnoredWhileWaitingForResponse() async throws {
        let transport = FakeLineTransport(events: [
            .line(#"{"method":"account/rateLimits/updated","params":{"secret":"ignored"}}"#),
            .line(Self.rateLimitsResponse(id: 1)),
        ])
        let client = CodexRPCClient(transport: transport, requestTimeout: .seconds(1))

        let response = try await client.readRateLimits()

        XCTAssertEqual(response.rateLimits.primary?.usedPercent, 10)
    }

    func testUnknownResponseIDIsIgnored() async throws {
        let transport = FakeLineTransport(events: [
            .line(Self.rateLimitsResponse(id: 42, usedPercent: 99)),
            .line(Self.rateLimitsResponse(id: 1, usedPercent: 17)),
        ])
        let client = CodexRPCClient(transport: transport, requestTimeout: .seconds(1))

        let response = try await client.readRateLimits()

        XCTAssertEqual(response.rateLimits.primary?.usedPercent, 17)
    }

    func testMalformedJSONFailsWithTypedError() async throws {
        let transport = FakeLineTransport(events: [.line(#"{"id":1,"result":BROKEN}"#)])
        let client = CodexRPCClient(transport: transport, requestTimeout: .seconds(1))

        await assertReadError(from: client, equals: .malformedJSON)
    }

    func testLineOverOneMiBFailsBeforeParsing() async throws {
        let oversizedLine = Data(repeating: 0x20, count: 1_048_577)
        let transport = FakeLineTransport(events: [.data(oversizedLine)])
        let client = CodexRPCClient(transport: transport, requestTimeout: .seconds(1))

        await assertReadError(from: client, equals: .lineTooLong)
        let requestedLimits = await transport.requestedMaximumBytes()
        XCTAssertEqual(requestedLimits, [1_048_576])
    }

    func testRequestTimesOutWithTypedError() async throws {
        let transport = FakeLineTransport()
        let client = CodexRPCClient(transport: transport, requestTimeout: .milliseconds(20))

        await assertReadError(from: client, equals: .timedOut)
    }

    func testProcessExitFailsPendingAndFutureRequestsWithTypedError() async throws {
        let transport = FakeLineTransport(events: [.endOfStream])
        let client = CodexRPCClient(transport: transport, requestTimeout: .seconds(1))

        await assertReadError(from: client, equals: .processExited)
        await assertReadError(from: client, equals: .processExited)
    }

    func testRequestSendProcessExitFailsCurrentAndFutureRequestsAsProcessExited() async throws {
        let transport = FakeLineTransport(
            sendError: CodexRPCLineTransportError.processExited
        )
        let client = CodexRPCClient(transport: transport, requestTimeout: .seconds(1))

        await assertReadError(from: client, equals: .processExited)
        await assertReadError(from: client, equals: .processExited)
    }

    func testInitializedSendLineTooLongPreservesTypedErrorWithoutUnderlyingContent() async throws {
        let transport = FakeLineTransport(
            sendError: CodexRPCLineTransportError.lineTooLong
        )
        let client = CodexRPCClient(transport: transport)

        do {
            try await client.sendInitialized()
            XCTFail("Expected line-too-long error")
        } catch {
            XCTAssertEqual(error as? CodexRPCClientError, .lineTooLong)
            XCTAssertFalse(String(reflecting: error).contains("CodexRPCLineTransportError"))
        }
    }

    func testErrorsDoNotExposeRawResponseLine() async throws {
        let sentinel = "RAW_SECRET_SENTINEL"
        let transport = FakeLineTransport(events: [
            .line(#"{"id":1,"result":"RAW_SECRET_SENTINEL"}"#),
        ])
        let client = CodexRPCClient(transport: transport, requestTimeout: .seconds(1))

        do {
            _ = try await client.readRateLimits()
            XCTFail("Expected invalid response")
        } catch {
            XCTAssertEqual(error as? CodexRPCClientError, .invalidResponse)
            XCTAssertFalse(String(reflecting: error).contains(sentinel))
        }
    }

    func testServerErrorDoesNotExposeMessageOrData() async throws {
        let sentinel = "RAW_RPC_ERROR_SENTINEL"
        let transport = FakeLineTransport(events: [
            .line(#"{"id":1,"error":{"code":-32000,"message":"RAW_RPC_ERROR_SENTINEL","data":{"private":"RAW_RPC_ERROR_SENTINEL"}}}"#),
        ])
        let client = CodexRPCClient(transport: transport, requestTimeout: .seconds(1))

        do {
            _ = try await client.readRateLimits()
            XCTFail("Expected server error")
        } catch {
            XCTAssertEqual(error as? CodexRPCClientError, .serverError(code: -32_000))
            XCTAssertFalse(String(reflecting: error).contains(sentinel))
        }
    }

    private func assertReadError(
        from client: CodexRPCClient,
        equals expectedError: CodexRPCClientError
    ) async {
        do {
            _ = try await client.readRateLimits()
            XCTFail("Expected \(expectedError)")
        } catch {
            XCTAssertEqual(error as? CodexRPCClientError, expectedError)
        }
    }

    private func sentObject(from transport: FakeLineTransport) async throws -> [String: Any] {
        let lines = await transport.sentLines()
        let line = try XCTUnwrap(lines.first)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: line) as? [String: Any]
        )
    }

    private static func rateLimitsResponse(id: Int, usedPercent: Int = 10) -> String {
        """
        {"id":\(id),"result":{"rateLimits":{"planType":"plus","primary":{"usedPercent":\(usedPercent),"windowDurationMins":300,"resetsAt":null},"secondary":null}}}
        """
    }
}

private actor FakeLineTransport: CodexRPCLineTransport {
    enum Event: Sendable {
        case data(Data)
        case endOfStream

        static func line(_ string: String) -> Event {
            .data(Data(string.utf8))
        }
    }

    private var events: [Event]
    private let sendError: (any Error & Sendable)?
    private var sent: [Data] = []
    private var maximumBytes: [Int] = []

    init(
        events: [Event] = [],
        sendError: (any Error & Sendable)? = nil
    ) {
        self.events = events
        self.sendError = sendError
    }

    func send(line: Data) async throws {
        if let sendError {
            throw sendError
        }
        sent.append(line)
    }

    func receiveLine(maximumBytes: Int) async throws -> Data? {
        self.maximumBytes.append(maximumBytes)
        guard !events.isEmpty else {
            try await ContinuousClock().sleep(for: .seconds(60))
            return nil
        }

        switch events.removeFirst() {
        case let .data(line): return line
        case .endOfStream: return nil
        }
    }

    func sentLines() -> [Data] {
        sent
    }

    func requestedMaximumBytes() -> [Int] {
        maximumBytes
    }
}
