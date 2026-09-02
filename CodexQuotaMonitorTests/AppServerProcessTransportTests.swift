import Darwin
import Foundation
import XCTest
@testable import CodexQuotaMonitor

@MainActor
final class AppServerProcessTransportTests: XCTestCase {
    func testProductionFactoryUsesDirectBinaryAndExactAppServerArguments() {
        let path = "/Applications/ChatGPT.app/Contents/Resources/codex"
        let transport = AppServerProcessTransport.makeProduction(binaryPath: path)

        XCTAssertEqual(transport.configuration.executableURL, URL(fileURLWithPath: path))
        XCTAssertEqual(transport.configuration.arguments, ["app-server", "--listen", "stdio://"])
    }

    func testSendFramesOneJSONValueWithExactlyOneLineFeed() {
        let line = Data(#"{"value":1}"#.utf8)

        XCTAssertEqual(
            AppServerProcessTransport.framedLineForSending(line),
            line + Data([0x0A])
        )
    }

    func testStdinWriterSuppressesSIGPIPEAndMapsClosedPipeToProcessExited() throws {
        let pipe = Pipe()
        let writer = try AppServerStdinWriter(
            fileHandle: pipe.fileHandleForWriting
        )
        defer {
            writer.close()
            try? pipe.fileHandleForReading.close()
        }

        XCTAssertEqual(
            Darwin.fcntl(writer.fileDescriptorForTesting, F_GETNOSIGPIPE),
            1
        )
        try pipe.fileHandleForReading.close()

        XCTAssertThrowsError(try writer.write(Data("{}\n".utf8))) { error in
            XCTAssertEqual(error as? CodexRPCLineTransportError, .processExited)
        }
    }

    func testCatEchoesSentJSONLine() async throws {
        let transport = AppServerProcessTransport(
            executableURL: URL(fileURLWithPath: "/bin/cat"),
            arguments: []
        )
        try await transport.launch()

        do {
            let sent = Data(#"{"echo":true}"#.utf8)
            try await transport.send(line: sent)
            let received = try await transport.receiveLine(maximumBytes: 1_024)
            XCTAssertEqual(received, sent)
        } catch {
            await transport.terminate()
            throw error
        }

        await transport.terminate()
        let isRunning = await transport.isRunningForTesting()
        XCTAssertFalse(isRunning)
    }

    func testFramerAccumulatesSplitLineAcrossChunks() throws {
        var framer = BoundedLineFramer()

        XCTAssertEqual(
            try framer.append(Data(#"{"value""#.utf8), maximumBytes: 64),
            []
        )
        XCTAssertEqual(
            try framer.append(Data(":1}\n".utf8), maximumBytes: 64),
            [Data(#"{"value":1}"#.utf8)]
        )
    }

    func testFramerReturnsMultipleLinesAndRetainsTrailingPartialLine() throws {
        var framer = BoundedLineFramer()

        XCTAssertEqual(
            try framer.append(Data("one\ntwo\npar".utf8), maximumBytes: 8),
            [Data("one".utf8), Data("two".utf8)]
        )
        XCTAssertEqual(
            try framer.append(Data("tial\n".utf8), maximumBytes: 8),
            [Data("partial".utf8)]
        )
    }

    func testFramerRejectsOversizeDuringAccumulationBeforeNewline() throws {
        var framer = BoundedLineFramer()
        XCTAssertEqual(
            try framer.append(Data("1234".utf8), maximumBytes: 4),
            []
        )

        XCTAssertThrowsError(
            try framer.append(Data("5".utf8), maximumBytes: 4)
        ) { error in
            XCTAssertEqual(error as? CodexRPCLineTransportError, .lineTooLong)
        }
    }

    func testFramerAcceptsExactlyMaximumBytesFollowedByLineFeed() throws {
        var framer = BoundedLineFramer()
        let maximumLengthLine = Data("1234".utf8)

        XCTAssertEqual(
            try framer.append(maximumLengthLine + Data([0x0A]), maximumBytes: 4),
            [maximumLengthLine]
        )
    }

    func testCancelledReceiveCanBeFollowedBySuccessfulSendAndReceive() async throws {
        let transport = AppServerProcessTransport(
            executableURL: URL(fileURLWithPath: "/bin/cat"),
            arguments: []
        )
        try await transport.launch()

        do {
            let blockedReceive = Task {
                try await transport.receiveLine(maximumBytes: 64)
            }
            let receiveWasRegistered = await waitForPendingReceive(on: transport)
            XCTAssertTrue(receiveWasRegistered)
            blockedReceive.cancel()
            do {
                _ = try await blockedReceive.value
                XCTFail("Expected receive cancellation")
            } catch is CancellationError {
                // Expected. The next receive must keep using this process generation.
            }

            let sent = Data(#"{"afterCancel":true}"#.utf8)
            try await transport.send(line: sent)
            let received = try await transport.receiveLine(maximumBytes: 64)
            XCTAssertEqual(received, sent)
        } catch {
            await transport.terminate()
            throw error
        }

        await transport.terminate()
        let isRunning = await transport.isRunningForTesting()
        XCTAssertFalse(isRunning)
    }

    func testImmediateChildExitMakesReceiveThrowProcessExited() async throws {
        let transport = AppServerProcessTransport(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["0"]
        )
        try await transport.launch()

        do {
            _ = try await transport.receiveLine(maximumBytes: 64)
            XCTFail("Expected process-exited error")
        } catch {
            XCTAssertEqual(error as? CodexRPCLineTransportError, .processExited)
        }

        await transport.terminate()
        let isRunning = await transport.isRunningForTesting()
        XCTAssertFalse(isRunning)
    }

    func testSendAfterChildExitThrowsProcessExited() async throws {
        let transport = AppServerProcessTransport(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["0"]
        )
        try await transport.launch()
        try await Task.sleep(for: .milliseconds(50))

        do {
            try await transport.send(line: Data("ignored".utf8))
            XCTFail("Expected process-exited error")
        } catch {
            XCTAssertEqual(error as? CodexRPCLineTransportError, .processExited)
        }

        await transport.terminate()
        let isRunning = await transport.isRunningForTesting()
        XCTAssertFalse(isRunning)
    }

    func testTerminateIsIdempotentAndReapsChild() async throws {
        let transport = AppServerProcessTransport(
            executableURL: URL(fileURLWithPath: "/bin/cat"),
            arguments: []
        )
        try await transport.launch()

        await transport.terminate()
        await transport.terminate()

        let isRunning = await transport.isRunningForTesting()
        XCTAssertFalse(isRunning)
    }

    private func waitForPendingReceive(
        on transport: AppServerProcessTransport,
        maximumYields: Int = 1_000
    ) async -> Bool {
        for _ in 0..<maximumYields {
            if await transport.pendingReceiveCountForTesting() > 0 {
                return true
            }
            await Task.yield()
        }
        return false
    }
}
