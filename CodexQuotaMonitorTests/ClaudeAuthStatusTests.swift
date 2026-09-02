import Darwin
import Foundation
import XCTest
@testable import CodexQuotaMonitor

final class ClaudeAuthStatusTests: XCTestCase {
    private let executableURL = URL(fileURLWithPath: "/opt/local/bin/claude")

    func testClientBuildsExactBoundedRequestWithAllowlistedEnvironment() async {
        let rawMarker = "must-not-escape-the-runner"
        let fixtureHome = "/Users/" + "tester"
        let fixtureEmail = "person" + "@example.com"
        let runner = RecordingClaudeAuthRunner(
            outcome: .result(
                ClaudeAuthCommandResult(
                    exitCode: 0,
                    stdout: Data(
                        """
                        {"loggedIn":true,"email":"\(fixtureEmail)"}
                        """.utf8
                    ),
                    stderr: Data(rawMarker.utf8)
                )
            )
        )
        let environmentSource = [
            "HOME": fixtureHome,
            "PATH": "/usr/bin:/bin",
            "TMPDIR": "/private/tmp",
            "LANG": "en_US.UTF-8",
            "LC_ALL": "C",
            "CLAUDE_CONFIG_DIR": fixtureHome + "/custom-claude",
            "ANTHROPIC_API_KEY": rawMarker,
            "UNRELATED_SECRET": rawMarker,
        ]
        let client = ClaudeAuthStatusClient(
            executableURL: executableURL,
            environmentSource: environmentSource,
            runner: runner
        )

        let status = await client.fetch()
        XCTAssertEqual(status, .connected)
        let requests = await runner.requests()
        let request = try? XCTUnwrap(requests.first)
        XCTAssertEqual(request?.executableURL, executableURL)
        XCTAssertEqual(request?.arguments, ["auth", "status"])
        XCTAssertEqual(request?.timeout, .seconds(5))
        XCTAssertEqual(request?.maximumStdoutBytes, 65_536)
        XCTAssertEqual(request?.maximumStderrBytes, 65_536)
        XCTAssertEqual(
            request?.environment,
            [
                "HOME": fixtureHome,
                "PATH": "/usr/bin:/bin",
                "TMPDIR": "/private/tmp",
                "LANG": "en_US.UTF-8",
                "LC_ALL": "C",
                "CLAUDE_CONFIG_DIR": fixtureHome + "/custom-claude",
            ]
        )
    }

    func testClientRetainsOnlyAllowlistedEnvironmentAfterInitialization() {
        let fixtureHome = "/Users/" + "tester"
        let runner = RecordingClaudeAuthRunner(
            outcome: .result(
                ClaudeAuthCommandResult(
                    exitCode: 0,
                    stdout: Data(#"{}"#.utf8),
                    stderr: Data()
                )
            )
        )
        let client = ClaudeAuthStatusClient(
            executableURL: executableURL,
            environmentSource: [
                "HOME": fixtureHome,
                "ANTHROPIC_API_KEY": "must-be-discarded-immediately",
            ],
            runner: runner
        )

        let retainedEnvironments = Mirror(reflecting: client).children
            .compactMap { $0.value as? [String: String] }
        XCTAssertEqual(retainedEnvironments, [["HOME": fixtureHome]])
    }

    func testClientUsesLoggedInBooleanInsteadOfSuccessExitAlone() async {
        let cases: [(Int32, String, ClaudeAuthState)] = [
            (0, #"{"loggedIn":true}"#, .connected),
            (0, #"{"loggedIn":false}"#, .notConnected),
            (1, #"{"loggedIn":false}"#, .notConnected),
            (1, #"{"loggedIn":true}"#, .failed(code: .invalidResponse)),
        ]

        for (exitCode, payload, expected) in cases {
            let runner = RecordingClaudeAuthRunner(
                outcome: .result(
                    ClaudeAuthCommandResult(
                        exitCode: exitCode,
                        stdout: Data(payload.utf8),
                        stderr: Data()
                    )
                )
            )

            let status = await makeClient(runner: runner).fetch()
            XCTAssertEqual(status, expected)
        }
    }

    func testMissingOrNonBooleanLoggedInFailsClosed() async {
        let invalidPayloads = [
            #"{"future_schema":{"value":42}}"#,
            #"{"loggedIn":null}"#,
            #"{"loggedIn":"true"}"#,
        ]

        for exitCode: Int32 in [0, 1] {
            for payload in invalidPayloads {
                let runner = RecordingClaudeAuthRunner(
                    outcome: .result(
                        ClaudeAuthCommandResult(
                            exitCode: exitCode,
                            stdout: Data(payload.utf8),
                            stderr: Data()
                        )
                    )
                )

                let status = await makeClient(runner: runner).fetch()
                XCTAssertEqual(status, .failed(code: .invalidResponse))
            }
        }
    }

    func testUnexpectedExitAndRunnerFailureUseStableCommandFailure() async {
        let exitedRunner = RecordingClaudeAuthRunner(
            outcome: .result(
                ClaudeAuthCommandResult(
                    exitCode: 2,
                    stdout: Data("not retained".utf8),
                    stderr: Data("also not retained".utf8)
                )
            )
        )
        let failedRunner = RecordingClaudeAuthRunner(outcome: .failure)

        let exitedStatus = await makeClient(runner: exitedRunner).fetch()
        let failedStatus = await makeClient(runner: failedRunner).fetch()
        XCTAssertEqual(exitedStatus, .failed(code: .commandFailed))
        XCTAssertEqual(failedStatus, .failed(code: .commandFailed))
    }

    func testProcessOutputOverflowKeepsSpecificFailureCode() async {
        let runner = RecordingClaudeAuthRunner(
            outcome: .processError(.outputTooLarge)
        )
        let status = await makeClient(runner: runner).fetch()

        XCTAssertEqual(status, .failed(code: .outputTooLarge))
    }

    func testOversizedStdoutOrStderrFailsClosed() async {
        let oversized = Data(repeating: 0x41, count: 65_537)
        let cases = [
            ClaudeAuthCommandResult(
                exitCode: 0,
                stdout: oversized,
                stderr: Data()
            ),
            ClaudeAuthCommandResult(
                exitCode: 1,
                stdout: Data(#"{}"#.utf8),
                stderr: oversized
            ),
        ]

        for result in cases {
            let runner = RecordingClaudeAuthRunner(outcome: .result(result))
            let status = await makeClient(runner: runner).fetch()
            XCTAssertEqual(status, .failed(code: .outputTooLarge))
        }
    }

    func testExitZeroAndOneRequireValidTopLevelJSONObject() async {
        let invalidPayloads = [
            Data(),
            Data("not-json".utf8),
            Data(#"[]"#.utf8),
            Data(#"null"#.utf8),
            Data(#"42"#.utf8),
            Data(#""value""#.utf8),
        ]

        for exitCode: Int32 in [0, 1] {
            for payload in invalidPayloads {
                let runner = RecordingClaudeAuthRunner(
                    outcome: .result(
                        ClaudeAuthCommandResult(
                            exitCode: exitCode,
                            stdout: payload,
                            stderr: Data()
                        )
                    )
                )
                let status = await makeClient(runner: runner).fetch()
                XCTAssertEqual(status, .failed(code: .invalidResponse))
            }
        }
    }

    func testExactlyMaximumSizedJSONObjectIsAccepted() async {
        var payload = Data(#"{"loggedIn":true}"#.utf8)
        payload.append(
            Data(
                repeating: 0x20,
                count: 65_536 - payload.count
            )
        )
        let runner = RecordingClaudeAuthRunner(
            outcome: .result(
                ClaudeAuthCommandResult(
                    exitCode: 0,
                    stdout: payload,
                    stderr: Data()
                )
            )
        )

        let status = await makeClient(runner: runner).fetch()
        XCTAssertEqual(status, .connected)
    }

    func testInvalidExecutableURLsFailWithoutInvokingRunner() async {
        let invalidURLs = [
            URL(string: "https://example.com/claude")!,
            URL(string: "file:claude")!,
            URL(fileURLWithPath: "/", isDirectory: true),
        ]

        for executableURL in invalidURLs {
            let runner = RecordingClaudeAuthRunner(
                outcome: .result(
                    ClaudeAuthCommandResult(
                        exitCode: 0,
                        stdout: Data(#"{}"#.utf8),
                        stderr: Data()
                    )
                )
            )
            let client = ClaudeAuthStatusClient(
                executableURL: executableURL,
                environmentSource: [:],
                runner: runner
            )

            let status = await client.fetch()
            let requests = await runner.requests()
            XCTAssertEqual(status, .failed(code: .invalidExecutable))
            XCTAssertTrue(requests.isEmpty)
        }
    }

    private func makeClient(
        runner: RecordingClaudeAuthRunner
    ) -> ClaudeAuthStatusClient {
        ClaudeAuthStatusClient(
            executableURL: executableURL,
            environmentSource: [:],
            runner: runner
        )
    }
}

final class ClaudeAuthProcessRunnerTests: XCTestCase {
    func testRunnerDrainsBothPipesConcurrentlyAndAcceptsExactCaps() async throws {
        let session = FakeClaudeAuthProcessSession(
            stdoutChunks: [Data("12".utf8), Data("34".utf8)],
            stderrChunks: [Data("wxyz".utf8)],
            initialExitStatus: 7,
            requireConcurrentFirstReads: true
        )
        let runner = makeRunner(session: session)

        let result = try await runner.run(makeRequest())

        XCTAssertEqual(
            result,
            ClaudeAuthCommandResult(
                exitCode: 7,
                stdout: Data("1234".utf8),
                stderr: Data("wxyz".utf8)
            )
        )
        let snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.closeCount, 1)
        XCTAssertEqual(snapshot.terminateCount, 0)
        XCTAssertEqual(snapshot.killCount, 0)
        XCTAssertEqual(snapshot.exitCompletionCount, 1)
        XCTAssertEqual(snapshot.maximumReadSizes[.standardOutput], [4, 2, 1])
        XCTAssertEqual(snapshot.maximumReadSizes[.standardError], [4, 1])
    }

    func testEitherPipeOverflowThrowsStableRawFreeErrorAndReapsOnce() async {
        let rawMarker = "raw-output-must-not-escape"

        for overflowingPipe in ClaudeAuthProcessPipe.allCases {
            let session = FakeClaudeAuthProcessSession(
                stdoutChunks: overflowingPipe == .standardOutput
                    ? [Data("1234".utf8), Data(rawMarker.utf8)]
                    : [],
                stderrChunks: overflowingPipe == .standardError
                    ? [Data("1234".utf8), Data(rawMarker.utf8)]
                    : [],
                initialExitStatus: nil
            )
            let runner = makeRunner(session: session)

            do {
                _ = try await runner.run(makeRequest())
                XCTFail("Expected output overflow")
            } catch {
                XCTAssertEqual(
                    error as? ClaudeAuthProcessRunnerError,
                    .outputTooLarge
                )
                XCTAssertFalse(String(describing: error).contains(rawMarker))
            }

            let snapshot = await session.snapshot()
            XCTAssertEqual(snapshot.closeCount, 1)
            XCTAssertEqual(snapshot.terminateCount, 1)
            XCTAssertEqual(snapshot.killCount, 1)
            XCTAssertEqual(snapshot.exitCompletionCount, 1)
        }
    }

    func testTimeoutUsesRequestDurationThenTerminatesKillsAndReaps() async {
        let session = FakeClaudeAuthProcessSession(initialExitStatus: nil)
        let sleeper = ImmediateRecordingClaudeAuthSleeper()
        let runner = makeRunner(session: session, sleeper: sleeper)
        let timeout: Duration = .milliseconds(42)

        do {
            _ = try await runner.run(makeRequest(timeout: timeout))
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? ClaudeAuthProcessRunnerError, .timedOut)
        }

        let durations = await sleeper.recordedDurations()
        XCTAssertEqual(durations, [timeout])
        let snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.closeCount, 1)
        XCTAssertEqual(snapshot.terminateCount, 1)
        XCTAssertEqual(snapshot.killCount, 1)
        XCTAssertEqual(snapshot.exitCompletionCount, 1)
    }

    func testTimeoutSkipsKillWhenProcessExitsAfterTerminate() async {
        let session = FakeClaudeAuthProcessSession(
            initialExitStatus: nil,
            exitsOnTerminate: true
        )
        let runner = makeRunner(
            session: session,
            sleeper: ImmediateRecordingClaudeAuthSleeper()
        )

        do {
            _ = try await runner.run(makeRequest())
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? ClaudeAuthProcessRunnerError, .timedOut)
        }

        let snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.closeCount, 1)
        XCTAssertEqual(snapshot.terminateCount, 1)
        XCTAssertEqual(snapshot.killCount, 0)
        XCTAssertEqual(snapshot.exitCompletionCount, 1)
    }

    func testTaskCancellationCleansUpAndThrowsStableCancellation() async {
        let session = FakeClaudeAuthProcessSession(initialExitStatus: nil)
        let runner = makeRunner(session: session)
        let request = makeRequest()
        let task = Task {
            try await runner.run(request)
        }
        let didLaunch = await waitUntil {
            await session.snapshot().launchCount == 1
        }
        XCTAssertTrue(didLaunch)

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? ClaudeAuthProcessRunnerError, .cancelled)
        }
        let snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.closeCount, 1)
        XCTAssertEqual(snapshot.terminateCount, 1)
        XCTAssertEqual(snapshot.killCount, 1)
        XCTAssertEqual(snapshot.exitCompletionCount, 1)
    }

    func testCancellationDuringLaunchCleansUpAndReapsExactlyOnce() async {
        let session = FakeClaudeAuthProcessSession(
            initialExitStatus: nil,
            suspendLaunchUntilCleanup: true
        )
        let runner = makeRunner(session: session)
        let request = makeRequest()
        let task = Task {
            try await runner.run(request)
        }
        let launchIsSuspended = await waitUntil {
            await session.snapshot().launchCount == 1
        }
        XCTAssertTrue(launchIsSuspended)

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? ClaudeAuthProcessRunnerError, .cancelled)
        }
        let snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.closeCount, 1)
        XCTAssertEqual(snapshot.terminateCount, 1)
        XCTAssertEqual(snapshot.killCount, 1)
        XCTAssertEqual(snapshot.exitCompletionCount, 1)
    }

    func testCancellationBetweenFactoryAndLaunchCleansUpExactlyOnce() async {
        let session = FakeClaudeAuthProcessSession(
            initialExitStatus: nil,
            suspendLaunchUntilCleanup: true
        )
        let factory = CancellingClaudeAuthProcessSessionFactory(
            session: session
        )
        let runner = ClaudeAuthProcessRunner(
            sessionFactory: factory,
            sleeper: SuspendingClaudeAuthSleeper(),
            terminationGracePeriod: .milliseconds(10)
        )
        let request = makeRequest()
        let task = Task {
            try await runner.run(request)
        }

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? ClaudeAuthProcessRunnerError, .cancelled)
        }

        let snapshot = await session.snapshot()
        XCTAssertEqual(factory.makeCount, 1)
        XCTAssertEqual(snapshot.launchCount, 1)
        XCTAssertEqual(snapshot.closeCount, 1)
        XCTAssertEqual(snapshot.terminateCount, 1)
        XCTAssertEqual(snapshot.killCount, 1)
        XCTAssertEqual(snapshot.exitCompletionCount, 1)
    }

    func testLaunchFailureClosesHandlesAndDoesNotExposeRawError() async {
        let rawMarker = "raw-launch-error-must-not-escape"
        let session = FakeClaudeAuthProcessSession(
            initialExitStatus: nil,
            launchErrorDescription: rawMarker
        )
        let factory = CountingClaudeAuthProcessSessionFactory(session: session)
        let runner = ClaudeAuthProcessRunner(
            sessionFactory: factory,
            sleeper: SuspendingClaudeAuthSleeper(),
            terminationGracePeriod: .milliseconds(10)
        )

        do {
            _ = try await runner.run(makeRequest())
            XCTFail("Expected launch failure")
        } catch {
            XCTAssertEqual(error as? ClaudeAuthProcessRunnerError, .launchFailed)
            XCTAssertFalse(String(describing: error).contains(rawMarker))
        }

        let snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.closeCount, 1)
        XCTAssertEqual(snapshot.terminateCount, 1)
        XCTAssertEqual(snapshot.killCount, 1)
        XCTAssertEqual(snapshot.exitCompletionCount, 1)
        XCTAssertEqual(factory.makeCount, 1)
    }

    func testSignalTerminationIsNotMisreadAsAnExitCode() async {
        let session = FakeClaudeAuthProcessSession(
            initialExitStatus: nil,
            initialExit: .signal
        )
        let runner = makeRunner(session: session)

        do {
            _ = try await runner.run(makeRequest())
            XCTFail("Expected abnormal termination")
        } catch {
            XCTAssertEqual(
                error as? ClaudeAuthProcessRunnerError,
                .abnormalTermination
            )
        }

        let snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.closeCount, 1)
        XCTAssertEqual(snapshot.terminateCount, 0)
        XCTAssertEqual(snapshot.killCount, 0)
        XCTAssertEqual(snapshot.exitCompletionCount, 1)
    }

    private func makeRunner(
        session: FakeClaudeAuthProcessSession,
        sleeper: any ClaudeAuthProcessSleeping = SuspendingClaudeAuthSleeper()
    ) -> ClaudeAuthProcessRunner {
        ClaudeAuthProcessRunner(
            sessionFactory: FixedClaudeAuthProcessSessionFactory(
                session: session
            ),
            sleeper: sleeper,
            terminationGracePeriod: .milliseconds(10)
        )
    }

    private func makeRequest(
        timeout: Duration = .seconds(60)
    ) -> ClaudeAuthCommandRequest {
        ClaudeAuthCommandRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/fake-claude"),
            arguments: ["auth", "status"],
            timeout: timeout,
            maximumStdoutBytes: 4,
            maximumStderrBytes: 4,
            environment: ["HOME": "/Users/" + "tester"]
        )
    }

    private func waitUntil(
        maximumYields: Int = 1_000,
        _ condition: () async -> Bool
    ) async -> Bool {
        for _ in 0..<maximumYields {
            if await condition() {
                return true
            }
            await Task.yield()
        }
        return false
    }
}

final class ClaudeAuthFoundationProcessSessionTests: XCTestCase {
    func testSessionConfiguresDirectProcessAndMarksOwnedDescriptorsCloseOnExec()
        async throws {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let request = makeFoundationRequest()
        let session = try ClaudeAuthFoundationProcessSession(
            request: request,
            process: process,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe
        )

        XCTAssertEqual(process.executableURL, request.executableURL)
        XCTAssertEqual(process.arguments, request.arguments)
        XCTAssertEqual(process.environment, request.environment)
        XCTAssertTrue(process.standardOutput as? Pipe === stdoutPipe)
        XCTAssertTrue(process.standardError as? Pipe === stderrPipe)
        let inputHandle = try XCTUnwrap(process.standardInput as? FileHandle)
        let descriptors = [
            stdoutPipe.fileHandleForReading.fileDescriptor,
            stdoutPipe.fileHandleForWriting.fileDescriptor,
            stderrPipe.fileHandleForReading.fileDescriptor,
            stderrPipe.fileHandleForWriting.fileDescriptor,
            inputHandle.fileDescriptor,
        ]
        for descriptor in descriptors {
            let flags = Darwin.fcntl(descriptor, F_GETFD)
            XCTAssertNotEqual(flags, -1)
            XCTAssertNotEqual(flags & FD_CLOEXEC, 0)
        }

        await session.closeOutputHandles()
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
        try? inputHandle.close()
    }

    func testSessionReadsEachPipeInRequestedBoundedChunks() async throws {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let session = try ClaudeAuthFoundationProcessSession(
            request: makeFoundationRequest(),
            process: Process(),
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe
        )
        try stdoutPipe.fileHandleForWriting.write(contentsOf: Data("abcde".utf8))
        try stderrPipe.fileHandleForWriting.write(contentsOf: Data("12345".utf8))
        try stdoutPipe.fileHandleForWriting.close()
        try stderrPipe.fileHandleForWriting.close()

        async let firstStdout = session.readChunk(
            from: .standardOutput,
            maximumBytes: 3
        )
        async let firstStderr = session.readChunk(
            from: .standardError,
            maximumBytes: 2
        )
        let chunks = try await (firstStdout, firstStderr)
        XCTAssertEqual(chunks.0, Data("abc".utf8))
        XCTAssertEqual(chunks.1, Data("12".utf8))
        let remainingStdout = try await session.readChunk(
            from: .standardOutput,
            maximumBytes: 3
        )
        let remainingStderr = try await session.readChunk(
            from: .standardError,
            maximumBytes: 3
        )
        XCTAssertEqual(remainingStdout, Data("de".utf8))
        XCTAssertEqual(remainingStderr, Data("345".utf8))
        let stdoutEOF = try await session.readChunk(
            from: .standardOutput,
            maximumBytes: 1
        )
        let stderrEOF = try await session.readChunk(
            from: .standardError,
            maximumBytes: 1
        )
        XCTAssertNil(stdoutEOF)
        XCTAssertNil(stderrEOF)
        await session.closeOutputHandles()
    }

    func testSessionAppliesKillRequestedBeforeLaunch() async throws {
        let process = Process()
        let request = ClaudeAuthCommandRequest(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["10"],
            timeout: .seconds(5),
            maximumStdoutBytes: 4,
            maximumStderrBytes: 4,
            environment: ["PATH": "/usr/bin:/bin"]
        )
        let session = try ClaudeAuthFoundationProcessSession(
            request: request,
            process: process
        )
        defer {
            if process.isRunning {
                process.terminate()
                if process.isRunning {
                    _ = Darwin.kill(process.processIdentifier, SIGKILL)
                }
            }
        }

        await session.sendTerminate()
        await session.sendKill()
        try await session.launch()

        let prelaunchSignalExit = await session.waitForExit(
            timeout: .seconds(1)
        )
        if prelaunchSignalExit == nil {
            if process.isRunning {
                process.terminate()
            }
            if await session.waitForExit(timeout: .milliseconds(250)) == nil,
               process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
            _ = await session.waitForExit(timeout: .seconds(1))
        }
        await session.closeOutputHandles()

        XCTAssertEqual(prelaunchSignalExit, .signal)
    }

    func testLaunchFailureClosesEveryOwnedDescriptorWithStableError() async throws {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let request = ClaudeAuthCommandRequest(
            executableURL: URL(
                fileURLWithPath: "/definitely/missing/claude-auth-test"
            ),
            arguments: ["auth", "status"],
            timeout: .seconds(5),
            maximumStdoutBytes: 4,
            maximumStderrBytes: 4,
            environment: [:]
        )
        let session = try ClaudeAuthFoundationProcessSession(
            request: request,
            process: process,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe
        )
        let inputHandle = try XCTUnwrap(process.standardInput as? FileHandle)
        let descriptors = [
            stdoutPipe.fileHandleForReading.fileDescriptor,
            stdoutPipe.fileHandleForWriting.fileDescriptor,
            stderrPipe.fileHandleForReading.fileDescriptor,
            stderrPipe.fileHandleForWriting.fileDescriptor,
            inputHandle.fileDescriptor,
        ]

        do {
            try await session.launch()
            XCTFail("Expected launch failure")
        } catch {
            XCTAssertEqual(
                error as? ClaudeAuthProcessRunnerError,
                .launchFailed
            )
        }

        for descriptor in descriptors {
            XCTAssertEqual(Darwin.fcntl(descriptor, F_GETFD), -1)
        }
        let terminalState = await session.waitForExit(timeout: nil)
        XCTAssertEqual(terminalState, .signal)
    }

    func testExitLatchTimeoutIgnoresCallerCancellationAndPublishesOnce() async {
        let latch = ClaudeAuthProcessExitLatch()
        let waitTask = Task {
            await latch.wait(timeout: .milliseconds(5))
        }
        waitTask.cancel()

        let timedOutExit = await waitTask.value
        XCTAssertNil(timedOutExit)

        latch.publish(.exit(1))
        latch.publish(.signal)
        let publishedExit = await latch.wait(timeout: nil)
        XCTAssertEqual(publishedExit, .exit(1))
    }

    private func makeFoundationRequest() -> ClaudeAuthCommandRequest {
        ClaudeAuthCommandRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/fake-claude"),
            arguments: ["auth", "status"],
            timeout: .seconds(5),
            maximumStdoutBytes: 4,
            maximumStderrBytes: 4,
            environment: [
                "HOME": "/Users/" + "tester",
                "PATH": "/usr/bin:/bin",
            ]
        )
    }
}

private actor RecordingClaudeAuthRunner: ClaudeAuthCommandRunning {
    enum Outcome: Sendable {
        case result(ClaudeAuthCommandResult)
        case failure
        case processError(ClaudeAuthProcessRunnerError)
    }

    private let outcome: Outcome
    private var recordedRequests: [ClaudeAuthCommandRequest] = []

    init(outcome: Outcome) {
        self.outcome = outcome
    }

    func run(
        _ request: ClaudeAuthCommandRequest
    ) async throws -> ClaudeAuthCommandResult {
        recordedRequests.append(request)
        switch outcome {
        case let .result(result):
            return result
        case .failure:
            throw StubClaudeAuthRunnerError.failed
        case let .processError(error):
            throw error
        }
    }

    func requests() -> [ClaudeAuthCommandRequest] {
        recordedRequests
    }
}

private enum StubClaudeAuthRunnerError: Error {
    case failed
}

private struct FixedClaudeAuthProcessSessionFactory:
    ClaudeAuthProcessSessionCreating {
    let session: any ClaudeAuthProcessSession

    func makeSession(
        for request: ClaudeAuthCommandRequest
    ) throws -> any ClaudeAuthProcessSession {
        session
    }
}

private final class CountingClaudeAuthProcessSessionFactory:
    ClaudeAuthProcessSessionCreating,
    @unchecked Sendable {
    private let lock = NSLock()
    private let session: any ClaudeAuthProcessSession
    private var storedMakeCount = 0

    init(session: any ClaudeAuthProcessSession) {
        self.session = session
    }

    var makeCount: Int {
        lock.withLock { storedMakeCount }
    }

    func makeSession(
        for request: ClaudeAuthCommandRequest
    ) throws -> any ClaudeAuthProcessSession {
        lock.withLock {
            storedMakeCount += 1
        }
        return session
    }
}

private final class CancellingClaudeAuthProcessSessionFactory:
    ClaudeAuthProcessSessionCreating,
    @unchecked Sendable {
    private let lock = NSLock()
    private let session: any ClaudeAuthProcessSession
    private var storedMakeCount = 0

    init(session: any ClaudeAuthProcessSession) {
        self.session = session
    }

    var makeCount: Int {
        lock.withLock { storedMakeCount }
    }

    func makeSession(
        for request: ClaudeAuthCommandRequest
    ) throws -> any ClaudeAuthProcessSession {
        lock.withLock {
            storedMakeCount += 1
        }
        withUnsafeCurrentTask { task in
            task?.cancel()
        }
        return session
    }
}

private struct SuspendingClaudeAuthSleeper: ClaudeAuthProcessSleeping {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: .seconds(60))
    }
}

private actor ImmediateRecordingClaudeAuthSleeper: ClaudeAuthProcessSleeping {
    private var durations: [Duration] = []

    func sleep(for duration: Duration) async throws {
        durations.append(duration)
    }

    func recordedDurations() -> [Duration] {
        durations
    }
}

private actor TwoPipeReadBarrier {
    private var arrived: Set<ClaudeAuthProcessPipe> = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func arrive(from pipe: ClaudeAuthProcessPipe) async {
        arrived.insert(pipe)
        guard arrived.count == ClaudeAuthProcessPipe.allCases.count else {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
            return
        }
        let pendingWaiters = waiters
        waiters.removeAll()
        pendingWaiters.forEach { $0.resume() }
    }
}

private actor FakeClaudeAuthProcessSession: ClaudeAuthProcessSession {
    struct Snapshot: Sendable {
        let launchCount: Int
        let closeCount: Int
        let terminateCount: Int
        let killCount: Int
        let exitCompletionCount: Int
        let maximumReadSizes: [ClaudeAuthProcessPipe: [Int]]
    }

    private var chunks: [ClaudeAuthProcessPipe: [Data]]
    private let barrier: TwoPipeReadBarrier?
    private let exitsOnTerminate: Bool
    private let launchErrorDescription: String?
    private let suspendLaunchUntilCleanup: Bool
    private var exit: ClaudeAuthProcessExit?
    private var exitWaiters: [
        CheckedContinuation<ClaudeAuthProcessExit, Never>
    ] = []
    private var didPublishExit = false
    private var launchCount = 0
    private var closeCount = 0
    private var terminateCount = 0
    private var killCount = 0
    private var exitCompletionCount = 0
    private var maximumReadSizes: [ClaudeAuthProcessPipe: [Int]] = [:]
    private var pipesThatReachedBarrier: Set<ClaudeAuthProcessPipe> = []
    private var launchWaiter: CheckedContinuation<Void, any Error>?
    private var outputHandlesWereClosed = false

    init(
        stdoutChunks: [Data] = [],
        stderrChunks: [Data] = [],
        initialExitStatus: Int32?,
        initialExit: ClaudeAuthProcessExit? = nil,
        requireConcurrentFirstReads: Bool = false,
        exitsOnTerminate: Bool = false,
        launchErrorDescription: String? = nil,
        suspendLaunchUntilCleanup: Bool = false
    ) {
        chunks = [
            .standardOutput: stdoutChunks,
            .standardError: stderrChunks,
        ]
        barrier = requireConcurrentFirstReads ? TwoPipeReadBarrier() : nil
        self.exitsOnTerminate = exitsOnTerminate
        self.launchErrorDescription = launchErrorDescription
        self.suspendLaunchUntilCleanup = suspendLaunchUntilCleanup
        exit = initialExit ?? initialExitStatus.map(ClaudeAuthProcessExit.exit)
        if exit != nil {
            didPublishExit = true
            exitCompletionCount = 1
        }
    }

    func launch() async throws {
        launchCount += 1
        if let launchErrorDescription {
            throw RawFakeClaudeAuthProcessError(
                description: launchErrorDescription
            )
        }
        if suspendLaunchUntilCleanup {
            guard !outputHandlesWereClosed else {
                throw CancellationError()
            }
            try await withCheckedThrowingContinuation { continuation in
                launchWaiter = continuation
            }
        }
    }

    func readChunk(
        from pipe: ClaudeAuthProcessPipe,
        maximumBytes: Int
    ) async throws -> Data? {
        maximumReadSizes[pipe, default: []].append(maximumBytes)
        if let barrier, !pipesThatReachedBarrier.contains(pipe) {
            pipesThatReachedBarrier.insert(pipe)
            await barrier.arrive(from: pipe)
        }
        guard var pipeChunks = chunks[pipe], !pipeChunks.isEmpty else {
            return nil
        }
        let chunk = pipeChunks.removeFirst()
        chunks[pipe] = pipeChunks
        return chunk
    }

    func waitForExit(timeout: Duration?) async -> ClaudeAuthProcessExit? {
        if let exit {
            return exit
        }
        if timeout != nil {
            return nil
        }
        return await withCheckedContinuation { continuation in
            exitWaiters.append(continuation)
        }
    }

    func closeOutputHandles() {
        closeCount += 1
        outputHandlesWereClosed = true
        launchWaiter?.resume(throwing: CancellationError())
        launchWaiter = nil
    }

    func sendTerminate() {
        terminateCount += 1
        if exitsOnTerminate {
            publishExit(.signal)
        }
    }

    func sendKill() {
        killCount += 1
        publishExit(.signal)
    }

    func snapshot() -> Snapshot {
        Snapshot(
            launchCount: launchCount,
            closeCount: closeCount,
            terminateCount: terminateCount,
            killCount: killCount,
            exitCompletionCount: exitCompletionCount,
            maximumReadSizes: maximumReadSizes
        )
    }

    private func publishExit(_ newExit: ClaudeAuthProcessExit) {
        guard !didPublishExit else {
            return
        }
        didPublishExit = true
        exit = newExit
        exitCompletionCount += 1
        let waiters = exitWaiters
        exitWaiters.removeAll()
        waiters.forEach { $0.resume(returning: newExit) }
    }
}

private struct RawFakeClaudeAuthProcessError: Error, CustomStringConvertible {
    let description: String
}
