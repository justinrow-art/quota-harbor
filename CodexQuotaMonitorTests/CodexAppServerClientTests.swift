import Foundation
import XCTest
@testable import CodexQuotaMonitor

@MainActor
final class CodexAppServerClientTests: XCTestCase {
    func testOutboundAllowlistContainsExactlyTheFiveApprovedMethods() {
        XCTAssertEqual(
            Set(AppServerOutboundMethod.allCases.map(\.rawValue)),
            Set([
                "initialize",
                "initialized",
                "account/read",
                "account/rateLimits/read",
                "account/usage/read",
            ])
        )
        XCTAssertEqual(AppServerOutboundMethod.allCases.count, 5)
    }

    func testReadAccountUsesRefreshFalseAndMasksChatGPTEmail() async throws {
        let rawEmail = "alice" + "@example.com"
        let connection = ScriptedAppServerConnection()
        let client = makeClient(connection: connection)
        let generation = try await client.connect(session: 7)

        let readTask = Task {
            try await client.readAccount(generation: generation)
        }
        let requests = try await waitForReadRequests(on: connection)
        let request = try XCTUnwrap(
            requests.first { $0.method == "account/read" }
        )
        let id = try XCTUnwrap(request.id)
        await connection.enqueueLine(
            """
            {"id":\(id),"result":{"account":{"type":"chatgpt","email":"\(rawEmail)","planType":"plus"},"requiresOpenaiAuth":true}}
            """
        )

        let result = try await readTask.value
        let identity = try XCTUnwrap(result.account?.maskedIdentity)
        let exposures = [
            identity.description,
            String(reflecting: result),
        ] + Mirror(reflecting: identity).children.map {
            String(describing: $0.value)
        }

        XCTAssertTrue(result.requiresOpenaiAuth)
        XCTAssertEqual(request.refreshToken, false)
        for exposure in exposures {
            XCTAssertFalse(exposure.contains(rawEmail))
            XCTAssertFalse(exposure.contains("alice"))
            XCTAssertFalse(exposure.contains("example.com"))
        }

        await client.disconnect()
    }

    func testAccountResultAcceptsMissingOrNullAccount() throws {
        for json in [
            #"{"requiresOpenaiAuth":true}"#,
            #"{"account":null,"requiresOpenaiAuth":false}"#,
        ] {
            let result = try JSONDecoder().decode(
                CodexAccountReadResult.self,
                from: Data(json.utf8)
            )

            XCTAssertNil(result.account)
        }
    }

    func testAccountResultPreservesConnectedAccountWithoutIdentity() throws {
        for json in [
            #"{"account":{"type":"apiKey"},"requiresOpenaiAuth":false}"#,
            #"{"account":{"type":"chatgpt","email":null,"planType":"team"},"requiresOpenaiAuth":true}"#,
            #"{"account":{"type":"amazonBedrock"},"requiresOpenaiAuth":false}"#,
            #"{"account":{"type":"amazonBedrock","credentialSource":"environment"},"requiresOpenaiAuth":false}"#,
        ] {
            let result = try JSONDecoder().decode(
                CodexAccountReadResult.self,
                from: Data(json.utf8)
            )

            XCTAssertNotNil(result.account)
            XCTAssertNil(result.account?.maskedIdentity)
        }
    }

    func testAccountResultRejectsUnknownOrMalformedBundledSchema() {
        let missingPlanEmail = "alice" + "@example.com"
        for json in [
            #"{"account":null}"#,
            #"{"account":{"type":"futureAuth"},"requiresOpenaiAuth":true}"#,
            """
            {"account":{"type":"chatgpt","email":"\(missingPlanEmail)"},"requiresOpenaiAuth":true}
            """,
            #"{"account":{"type":"chatgpt","email":"not-an-email","planType":"plus"},"requiresOpenaiAuth":true}"#,
            #"{"account":{"type":"chatgpt","email":42,"planType":"plus"},"requiresOpenaiAuth":true}"#,
            #"{"account":{"type":"amazonBedrock","credentialSource":42},"requiresOpenaiAuth":false}"#,
            #"{"account":{"type":"apiKey"},"requiresOpenaiAuth":"false"}"#,
        ] {
            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    CodexAccountReadResult.self,
                    from: Data(json.utf8)
                ),
                "Unexpectedly accepted \(json)"
            )
        }
    }

    func testConnectPerformsDynamicVerificationBeforeExactHandshake() async throws {
        let connection = ScriptedAppServerConnection()
        let client = makeClient(connection: connection)

        let generation = try await client.connect(session: 7)

        XCTAssertEqual(generation, GenerationToken(auth: 0, session: 7, connection: 1))
        let hasReader = await client.hasActiveReaderForTesting()
        let didReceive = await waitForReceiveCall(on: connection)
        XCTAssertTrue(hasReader)
        XCTAssertTrue(didReceive)
        let lifecycleEvents = await connection.lifecycleEvents()
        XCTAssertEqual(
            lifecycleEvents.filter { !$0.hasPrefix("receive") },
            ["launch", "verify", "send:initialize", "send:initialized"]
        )
        let sent = await connection.sentRequests()
        XCTAssertEqual(sent.map(\.method), ["initialize", "initialized"])
        XCTAssertEqual(sent.first?.id, 1)
        XCTAssertNil(sent.last?.id)

        await client.disconnect()
    }

    func testConnectPreservesProcessLaunchFailureForTruthfulClassification()
        async
    {
        let connection = FailingLaunchAppServerConnection(
            error: AppServerProcessLaunchError.launchFailed
        )
        let client = CodexAppServerClient(
            connectionFactory: SingleAppServerConnectionFactory(
                connection: connection
            )
        )

        do {
            _ = try await client.connect(session: 7)
            XCTFail("Expected process launch failure")
        } catch {
            XCTAssertEqual(
                error as? AppServerProcessLaunchError,
                .launchFailed
            )
        }
    }

    func testReaderDoesNotStartUntilDynamicVerificationCompletes() async throws {
        let verificationStarted = TestGate()
        let verificationRelease = TestGate()
        let connection = ScriptedAppServerConnection(
            configuration: .init(
                verificationStarted: verificationStarted,
                verificationRelease: verificationRelease
            )
        )
        let client = makeClient(connection: connection)
        let notifications = await client.notifications()
        let notificationTask = Task {
            var iterator = notifications.makeAsyncIterator()
            return await iterator.next()
        }

        let connectTask = Task {
            try await client.connect(session: 7)
        }
        await verificationStarted.wait()
        await connection.enqueueLine(
            #"{"method":"account/rateLimits/updated","params":{}}"#
        )
        for _ in 0..<100 { await Task.yield() }

        let receiveCallsBeforeVerification = await connection.receiveCallCount()
        XCTAssertEqual(receiveCallsBeforeVerification, 0)
        await verificationRelease.open()
        _ = try await connectTask.value
        let notification = await notificationTask.value
        XCTAssertEqual(
            notification,
            AppServerNotification.rateLimitsUpdated
        )
        let events = await connection.lifecycleEvents()
        let verifyIndex = try XCTUnwrap(events.firstIndex(of: "verify"))
        let receiveIndex = try XCTUnwrap(
            events.firstIndex { $0.hasPrefix("receive:") }
        )
        XCTAssertLessThan(verifyIndex, receiveIndex)

        await client.disconnect()
    }

    func testOlderConnectCannotOverwriteNewerSuccessfulConnection() async throws {
        let first = ScriptedAppServerConnection()
        let second = ScriptedAppServerConnection()
        let factory = OutOfOrderConnectionFactory(first: first, second: second)
        let client = CodexAppServerClient(
            connectionFactory: factory,
            requestTimeout: .seconds(1)
        )

        let olderConnect = Task {
            try await client.connect(session: 9)
        }
        await factory.waitUntilFirstCallIsBlocked()
        let newerGeneration = try await client.connect(session: 9)
        olderConnect.cancel()
        await factory.releaseFirstCall()

        do {
            _ = try await olderConnect.value
            XCTFail("Expected the superseded connect to be cancelled")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected superseded-connect error: \(error)")
        }

        let readTask = Task {
            try await client.readRateLimits(generation: newerGeneration)
        }
        let requests = try await waitForReadRequests(on: second)
        let id = try XCTUnwrap(
            requests.first { $0.method == "account/rateLimits/read" }?.id
        )
        await second.enqueueLine(Self.rateResponse(id: id, usedPercent: 31))
        let catalog = try await readTask.value
        XCTAssertEqual(catalog.selectedBucket.windows.first?.usedPercent, 31)
        let firstTerminationCount = await first.terminationCount()
        let secondTerminationCount = await second.terminationCount()
        XCTAssertEqual(firstTerminationCount, 1)
        XCTAssertEqual(secondTerminationCount, 0)

        await client.disconnect()
    }

    func testDisconnectCancelsConnectBlockedInFactoryWithoutLaunchingChild() async {
        let first = ScriptedAppServerConnection()
        let factory = OutOfOrderConnectionFactory(
            first: first,
            second: ScriptedAppServerConnection()
        )
        let client = CodexAppServerClient(connectionFactory: factory)
        let connectTask = Task {
            try await client.connect(session: 4)
        }
        await factory.waitUntilFirstCallIsBlocked()

        await client.disconnect()
        await factory.releaseFirstCall()

        do {
            _ = try await connectTask.value
            XCTFail("Expected disconnect to cancel the in-flight connect")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected disconnect error: \(error)")
        }
        let firstEvents = await first.lifecycleEvents()
        let firstTerminationCount = await first.terminationCount()
        XCTAssertFalse(firstEvents.contains("launch"))
        XCTAssertEqual(firstTerminationCount, 1)
    }

    func testSplitAndCoalescedInputCorrelatesTwoReorderedResponses() async throws {
        let connection = ScriptedAppServerConnection()
        let client = makeClient(connection: connection)
        let generation = try await client.connect(session: 1)

        let rateTask = Task {
            try await client.readRateLimits(generation: generation)
        }
        let usageTask = Task {
            try await client.readUsage(generation: generation)
        }
        let requests = try await waitForReadRequests(on: connection)
        let rateID = try XCTUnwrap(
            requests.first { $0.method == "account/rateLimits/read" }?.id
        )
        let usageID = try XCTUnwrap(
            requests.first { $0.method == "account/usage/read" }?.id
        )

        let combined = Data(
            (Self.usageResponse(id: usageID, lifetime: 900)
                + "\n"
                + Self.rateResponse(id: rateID, usedPercent: 23)
                + "\n").utf8
        )
        let splitIndex = combined.count / 3
        await connection.enqueueChunk(Data(combined.prefix(splitIndex)))
        await connection.enqueueChunk(Data(combined.dropFirst(splitIndex)))

        let usage = try await usageTask.value
        let rate = try await rateTask.value
        XCTAssertEqual(usage.lifetimeTokens, 900)
        XCTAssertEqual(rate.selectedBucket.windows.first?.usedPercent, 23)

        await client.disconnect()
    }

    func testContinuousReaderReceivesIdleAndInterleavedNotifications() async throws {
        let connection = ScriptedAppServerConnection()
        let client = makeClient(connection: connection)
        let notifications = await client.notifications()
        let notificationTask = Task { () -> [AppServerNotification] in
            var iterator = notifications.makeAsyncIterator()
            var values: [AppServerNotification] = []
            if let first = await iterator.next() { values.append(first) }
            if let second = await iterator.next() { values.append(second) }
            return values
        }
        let generation = try await client.connect(session: 2)

        await connection.enqueueLine(
            #"{"method":"account/rateLimits/updated","params":{}}"#
        )
        let rateTask = Task {
            try await client.readRateLimits(generation: generation)
        }
        let requests = try await waitForReadRequests(on: connection)
        let rateID = try XCTUnwrap(
            requests.first { $0.method == "account/rateLimits/read" }?.id
        )
        await connection.enqueueLine(
            #"{"method":"account/rateLimits/updated","params":{"ignored":true}}"#
        )
        await connection.enqueueLine(Self.rateResponse(id: rateID, usedPercent: 11))

        let catalog = try await rateTask.value
        XCTAssertEqual(catalog.selectedBucket.windows.first?.usedPercent, 11)
        let receivedNotifications = await notificationTask.value
        XCTAssertEqual(
            receivedNotifications,
            [
                AppServerNotification.rateLimitsUpdated,
                AppServerNotification.rateLimitsUpdated,
            ]
        )

        await client.disconnect()
    }

    func testAuthenticationNotificationInvalidatesPendingAndOldGeneration() async throws {
        let connection = ScriptedAppServerConnection()
        let client = makeClient(connection: connection)
        let notifications = await client.notifications()
        let notificationTask = Task {
            var iterator = notifications.makeAsyncIterator()
            return await iterator.next()
        }
        let generation = try await client.connect(session: 3)
        let rateTask = Task {
            try await client.readRateLimits(generation: generation)
        }
        _ = try await waitForReadRequests(on: connection)

        await connection.enqueueLine(
            #"{"method":"account/updated","params":{"authMode":"chatgpt"}}"#
        )

        await assertTaskError(rateTask, equals: .staleGeneration)
        let notification = await notificationTask.value
        XCTAssertEqual(notification, AppServerNotification.authenticationChanged)
        await assertRateError(
            from: client,
            generation: generation,
            equals: .staleGeneration
        )

        await client.disconnect()
    }

    func testMalformedLineTerminalizesAllPendingExactlyOnce() async throws {
        let connection = ScriptedAppServerConnection()
        let client = makeClient(connection: connection)
        let generation = try await client.connect(session: 1)
        let rateTask = Task {
            try await client.readRateLimits(generation: generation)
        }
        let usageTask = Task {
            try await client.readUsage(generation: generation)
        }
        _ = try await waitForReadRequests(on: connection)

        await connection.enqueueLine(#"{"id":BROKEN}"#)

        await assertTaskError(rateTask, equals: .malformedJSON)
        await assertTaskError(usageTask, equals: .malformedJSON)
        let pendingCount = await client.pendingRequestCountForTesting()
        let terminateCount = await connection.terminationCount()
        XCTAssertEqual(pendingCount, 0)
        XCTAssertEqual(terminateCount, 1)
        await assertRateError(
            from: client,
            generation: generation,
            equals: .malformedJSON
        )
    }

    func testOversizedLineTerminalizesConnection() async throws {
        let connection = ScriptedAppServerConnection()
        let client = makeClient(connection: connection)
        let generation = try await client.connect(session: 1)
        let task = Task {
            try await client.readRateLimits(generation: generation)
        }
        _ = try await waitForReadRequests(on: connection)

        await connection.enqueueChunk(
            Data(repeating: 0x20, count: CodexAppServerClient.maximumLineBytes + 1)
        )

        await assertTaskError(task, equals: .lineTooLong)
        let terminateCount = await connection.terminationCount()
        XCTAssertEqual(terminateCount, 1)
    }

    func testPartialEOFTerminalizesConnectionDistinctly() async throws {
        let connection = ScriptedAppServerConnection()
        let client = makeClient(connection: connection)
        let generation = try await client.connect(session: 1)
        let task = Task {
            try await client.readRateLimits(generation: generation)
        }
        _ = try await waitForReadRequests(on: connection)

        await connection.enqueueChunk(Data(#"{"id":2"#.utf8))
        await connection.finishOutput()

        await assertTaskError(task, equals: .partialEOF)
        let terminateCount = await connection.terminationCount()
        XCTAssertEqual(terminateCount, 1)
    }

    func testTimeoutTerminalizesConnectionAndCompletesPendingOnce() async throws {
        let connection = ScriptedAppServerConnection()
        let client = makeClient(
            connection: connection,
            requestTimeout: .milliseconds(20)
        )
        let generation = try await client.connect(session: 1)

        await assertRateError(
            from: client,
            generation: generation,
            equals: .timedOut
        )
        let pendingCount = await client.pendingRequestCountForTesting()
        let terminateCount = await connection.terminationCount()
        XCTAssertEqual(pendingCount, 0)
        XCTAssertEqual(terminateCount, 1)
    }

    func testSendFailureTerminalizesCurrentAndFutureRequests() async throws {
        let connection = ScriptedAppServerConnection(
            sendFailureMethod: "account/rateLimits/read"
        )
        let client = makeClient(connection: connection)
        let generation = try await client.connect(session: 1)

        await assertRateError(
            from: client,
            generation: generation,
            equals: .processExited
        )
        await assertRateError(
            from: client,
            generation: generation,
            equals: .processExited
        )
        let terminateCount = await connection.terminationCount()
        XCTAssertEqual(terminateCount, 1)
    }

    func testChildExitAtEveryHandshakeStageFailsClosed() async {
        let scenarios: [ScriptedAppServerConnection.Configuration] = [
            .init(launchError: .processExited),
            .init(verificationError: .processExited),
            .init(sendFailureMethod: "initialize"),
            .init(finishAfterInitializeSend: true),
            .init(sendFailureMethod: "initialized"),
        ]

        for configuration in scenarios {
            let connection = ScriptedAppServerConnection(configuration: configuration)
            let client = makeClient(
                connection: connection,
                requestTimeout: .milliseconds(100)
            )
            do {
                _ = try await client.connect(session: 1)
                XCTFail("Expected handshake failure for \(configuration)")
            } catch {
                XCTAssertEqual(error as? CodexAppServerClientError, .processExited)
            }
            let terminateCount = await connection.terminationCount()
            XCTAssertEqual(terminateCount, 1)
        }
    }

    func testCancellationRemovesPendingAndLateResponseIsIgnored() async throws {
        let connection = ScriptedAppServerConnection()
        let client = makeClient(connection: connection)
        let generation = try await client.connect(session: 1)
        let task = Task {
            try await client.readRateLimits(generation: generation)
        }
        let requests = try await waitForReadRequests(on: connection)
        let id = try XCTUnwrap(
            requests.first { $0.method == "account/rateLimits/read" }?.id
        )

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let pendingCount = await client.pendingRequestCountForTesting()
        XCTAssertEqual(pendingCount, 0)

        await connection.enqueueLine(Self.rateResponse(id: id, usedPercent: 44))
        await Task.yield()
        let hasReader = await client.hasActiveReaderForTesting()
        XCTAssertTrue(hasReader)
        await client.disconnect()
    }

    func testConnectionGenerationIncrementsAndResetsForNewSession() async throws {
        let first = ScriptedAppServerConnection()
        let second = ScriptedAppServerConnection()
        let third = ScriptedAppServerConnection()
        let factory = QueueAppServerConnectionFactory([first, second, third])
        let client = CodexAppServerClient(connectionFactory: factory)

        let firstGeneration = try await client.connect(session: 4)
        await client.disconnect()
        let secondGeneration = try await client.connect(session: 4)
        await client.disconnect()
        let thirdGeneration = try await client.connect(session: 5)

        XCTAssertEqual(firstGeneration, GenerationToken(auth: 0, session: 4, connection: 1))
        XCTAssertEqual(secondGeneration, GenerationToken(auth: 0, session: 4, connection: 2))
        XCTAssertEqual(thirdGeneration, GenerationToken(auth: 0, session: 5, connection: 1))
        await client.disconnect()
    }

    func testLateOldConnectionResponseCannotSatisfyReusedRequestID() async throws {
        let first = ScriptedAppServerConnection(
            configuration: .init(keepOutputOpenOnTerminate: true)
        )
        let second = ScriptedAppServerConnection()
        let client = CodexAppServerClient(
            connectionFactory: QueueAppServerConnectionFactory([first, second]),
            requestTimeout: .seconds(1)
        )
        let firstGeneration = try await client.connect(session: 8)
        let oldTask = Task {
            try await client.readRateLimits(generation: firstGeneration)
        }
        let oldRequests = try await waitForReadRequests(on: first)
        let oldID = try XCTUnwrap(
            oldRequests.first { $0.method == "account/rateLimits/read" }?.id
        )

        let secondGeneration = try await client.connect(session: 8)
        let newTask = Task {
            try await client.readRateLimits(generation: secondGeneration)
        }
        let newRequests = try await waitForReadRequests(on: second)
        let newID = try XCTUnwrap(
            newRequests.first { $0.method == "account/rateLimits/read" }?.id
        )
        XCTAssertEqual(oldID, newID)

        await first.enqueueLine(Self.rateResponse(id: oldID, usedPercent: 99))
        await second.enqueueLine(Self.rateResponse(id: newID, usedPercent: 12))

        do {
            _ = try await oldTask.value
            XCTFail("Expected old request cancellation")
        } catch is CancellationError {
            // Expected when connect() closes the old epoch.
        } catch {
            XCTFail("Unexpected old request error: \(error)")
        }
        let newCatalog = try await newTask.value
        XCTAssertEqual(newCatalog.selectedBucket.windows.first?.usedPercent, 12)
        await client.disconnect()
        await first.finishOutput()
    }

    func testStaleEpochCancellationCannotRemoveReusedRequestID() async throws {
        let first = ScriptedAppServerConnection()
        let second = ScriptedAppServerConnection()
        let client = CodexAppServerClient(
            connectionFactory: QueueAppServerConnectionFactory([first, second]),
            requestTimeout: .seconds(1)
        )
        let firstGeneration = try await client.connect(session: 8)
        let observedFirstEpoch = await client.activeConnectionEpochForTesting()
        let firstEpoch = try XCTUnwrap(observedFirstEpoch)
        await client.disconnect()

        let secondGeneration = try await client.connect(session: 8)
        let readTask = Task {
            try await client.readRateLimits(generation: secondGeneration)
        }
        let requests = try await waitForReadRequests(on: second)
        let reusedID = try XCTUnwrap(
            requests.first { $0.method == "account/rateLimits/read" }?.id
        )
        XCTAssertEqual(firstGeneration.connection, 1)
        XCTAssertEqual(reusedID, 2)

        await client.cancelRequestForTesting(id: reusedID, epoch: firstEpoch)
        let pendingCount = await client.pendingRequestCountForTesting()
        XCTAssertEqual(pendingCount, 1)
        await second.enqueueLine(Self.rateResponse(id: reusedID, usedPercent: 18))
        let catalog = try await readTask.value
        XCTAssertEqual(catalog.selectedBucket.windows.first?.usedPercent, 18)

        await client.disconnect()
    }

    func testProductionFactoryBuildsExactVerifiedPolicyWithoutLaunching() async throws {
        let bundle = try applicationBundle()
        let manifest = try CodexTrustManifest.bundled(in: bundle)
        let factory = ProductionCodexAppServerConnectionFactory(
            manifestLoader: {
                try CodexTrustManifest.bundled(in: bundle)
            }
        )
        let executablePath = manifest.parentPath + "/" + manifest.childRelativePath

        // Hosted CI has no official installation: verify the fail-closed path
        // there, and the full verified transport policy where it is installed.
        if !FileManager.default.fileExists(atPath: executablePath) {
            do {
                _ = try await factory.makeConnection()
                XCTFail("A missing official executable must not produce a connection")
            } catch {
                XCTAssertEqual(error as? CodexExecutableTrustError, .missingPath)
            }
            return
        }

        let connection = try await factory.makeConnection()
        let transport = try XCTUnwrap(connection as? AppServerProcessTransport)

        XCTAssertEqual(
            transport.configuration.executableURL.path,
            executablePath
        )
        XCTAssertEqual(transport.configuration.arguments, manifest.arguments)
        let environmentKeys = Set(
            transport.configuration.environment?.keys.map { $0 } ?? []
        )
        XCTAssertTrue(environmentKeys.isSubset(of: Set(manifest.environmentKeys)))
        let isRunning = await transport.isRunningForTesting()
        XCTAssertFalse(isRunning)
        await transport.terminate()
    }

    private func applicationBundle() throws -> Bundle {
        var candidate = Bundle(for: Self.self).bundleURL.standardizedFileURL
        while candidate.path != "/" {
            if candidate.pathExtension == "app" {
                return try XCTUnwrap(Bundle(url: candidate))
            }
            candidate.deleteLastPathComponent()
        }
        return try XCTUnwrap(nil as Bundle?)
    }

    private func makeClient(
        connection: ScriptedAppServerConnection,
        requestTimeout: Duration = .seconds(1)
    ) -> CodexAppServerClient {
        CodexAppServerClient(
            connectionFactory: QueueAppServerConnectionFactory([connection]),
            requestTimeout: requestTimeout,
            clientInfo: ClientInfo(name: "test-client", version: "1.2.3")
        )
    }

    private func waitForReadRequests(
        on connection: ScriptedAppServerConnection
    ) async throws -> [FakeSentRequest] {
        for _ in 0..<5_000 {
            let requests = await connection.sentRequests()
            let methods = Set(requests.map(\.method))
            if methods.contains("account/read")
                || methods.contains("account/rateLimits/read")
                || methods.contains("account/usage/read") {
                if methods.contains("account/rateLimits/read")
                    && methods.contains("account/usage/read") {
                    return requests
                }
                await Task.yield()
                let afterYield = await connection.sentRequests()
                if Set(afterYield.map(\.method)).isSuperset(
                    of: ["account/rateLimits/read", "account/usage/read"]
                ) {
                    return afterYield
                }
                return requests
            }
            await Task.yield()
        }
        throw TestFailure.requestsNotSent
    }

    private func waitForReceiveCall(
        on connection: ScriptedAppServerConnection
    ) async -> Bool {
        for _ in 0..<5_000 {
            if await connection.receiveCallCount() > 0 { return true }
            await Task.yield()
        }
        return false
    }

    private func assertRateError(
        from client: CodexAppServerClient,
        generation: GenerationToken,
        equals expected: CodexAppServerClientError
    ) async {
        do {
            _ = try await client.readRateLimits(generation: generation)
            XCTFail("Expected \(expected)")
        } catch {
            XCTAssertEqual(error as? CodexAppServerClientError, expected)
        }
    }

    private func assertTaskError<Value: Sendable>(
        _ task: Task<Value, any Error>,
        equals expected: CodexAppServerClientError
    ) async {
        do {
            _ = try await task.value
            XCTFail("Expected \(expected)")
        } catch {
            XCTAssertEqual(error as? CodexAppServerClientError, expected)
        }
    }

    private static func rateResponse(id: Int64, usedPercent: Int) -> String {
        """
        {"id":\(id),"result":{"rateLimits":{"planType":"plus","primary":{"usedPercent":\(usedPercent),"windowDurationMins":300,"resetsAt":null},"secondary":null},"rateLimitsByLimitId":{"codex":{"planType":"plus","primary":{"usedPercent":\(usedPercent),"windowDurationMins":300,"resetsAt":null},"secondary":null,"limitId":"codex","limitName":"Codex"}}}}
        """
    }

    private static func usageResponse(id: Int64, lifetime: Int64) -> String {
        """
        {"id":\(id),"result":{"summary":{"lifetimeTokens":\(lifetime),"peakDailyTokens":100,"longestRunningTurnSec":20,"currentStreakDays":2,"longestStreakDays":3},"dailyUsageBuckets":[]}}
        """
    }
}

private enum TestFailure: Error {
    case requestsNotSent
}

private struct SingleAppServerConnectionFactory: CodexAppServerConnectionFactory {
    let connection: any CodexAppServerConnection

    func makeConnection() async throws -> any CodexAppServerConnection {
        connection
    }
}

private actor FailingLaunchAppServerConnection: CodexAppServerConnection {
    private let error: any Error & Sendable

    init(error: any Error & Sendable) {
        self.error = error
    }

    func launch() async throws {
        throw error
    }

    func verifySpawnedProcess() async throws {}

    func send(line _: Data) async throws {}

    func receiveLine(maximumBytes _: Int) async throws -> Data? {
        nil
    }

    func terminate() async {}
}

private struct FakeSentRequest: Equatable, Sendable {
    let method: String
    let id: Int64?
    let refreshToken: Bool?
}

private actor QueueAppServerConnectionFactory: CodexAppServerConnectionFactory {
    private var connections: [ScriptedAppServerConnection]

    init(_ connections: [ScriptedAppServerConnection]) {
        self.connections = connections
    }

    func makeConnection() async throws -> any CodexAppServerConnection {
        guard !connections.isEmpty else {
            throw CodexRPCLineTransportError.processExited
        }
        return connections.removeFirst()
    }
}

private actor OutOfOrderConnectionFactory: CodexAppServerConnectionFactory {
    private let first: ScriptedAppServerConnection
    private let second: ScriptedAppServerConnection
    private let firstCallStarted = TestGate()
    private let firstCallRelease = TestGate()
    private var callCount = 0

    init(
        first: ScriptedAppServerConnection,
        second: ScriptedAppServerConnection
    ) {
        self.first = first
        self.second = second
    }

    func makeConnection() async throws -> any CodexAppServerConnection {
        callCount += 1
        if callCount == 1 {
            await firstCallStarted.open()
            await firstCallRelease.wait()
            return first
        }
        return second
    }

    func waitUntilFirstCallIsBlocked() async {
        await firstCallStarted.wait()
    }

    func releaseFirstCall() async {
        await firstCallRelease.open()
    }
}

private actor ScriptedAppServerConnection: CodexAppServerConnection {
    struct Configuration: CustomStringConvertible, Sendable {
        var launchError: CodexRPCLineTransportError?
        var verificationError: CodexRPCLineTransportError?
        var verificationStarted: TestGate?
        var verificationRelease: TestGate?
        var sendFailureMethod: String?
        var finishAfterInitializeSend = false
        var keepOutputOpenOnTerminate = false

        var description: String {
            "launch=\(String(describing: launchError)),verify=\(String(describing: verificationError)),send=\(String(describing: sendFailureMethod)),finish=\(finishAfterInitializeSend),open=\(keepOutputOpenOnTerminate)"
        }
    }

    private let configuration: Configuration
    private let chunks = FakeChunkQueue()
    private var framer = BoundedLineFramer()
    private var completedLines: [Data] = []
    private var sent: [FakeSentRequest] = []
    private var events: [String] = []
    private var receiveCalls = 0
    private var terminateCalls = 0
    private var isTerminated = false

    init(
        sendFailureMethod: String? = nil
    ) {
        self.init(
            configuration: Configuration(sendFailureMethod: sendFailureMethod)
        )
    }

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    func launch() async throws {
        events.append("launch")
        if let launchError = configuration.launchError {
            throw launchError
        }
    }

    func verifySpawnedProcess() async throws {
        events.append("verify")
        await configuration.verificationStarted?.open()
        await configuration.verificationRelease?.wait()
        if let verificationError = configuration.verificationError {
            throw verificationError
        }
    }

    func send(line: Data) async throws {
        guard !isTerminated else {
            throw CodexRPCLineTransportError.processExited
        }
        let object = try JSONSerialization.jsonObject(with: line)
        guard let dictionary = object as? [String: Any],
              let method = dictionary["method"] as? String else {
            throw CodexRPCLineTransportError.processExited
        }
        let id = (dictionary["id"] as? NSNumber)?.int64Value
        let params = dictionary["params"] as? [String: Any]
        sent.append(
            FakeSentRequest(
                method: method,
                id: id,
                refreshToken: params?["refreshToken"] as? Bool
            )
        )
        events.append("send:\(method)")

        if configuration.sendFailureMethod == method {
            throw CodexRPCLineTransportError.processExited
        }
        if method == "initialize", let id {
            if configuration.finishAfterInitializeSend {
                await chunks.finish()
            } else {
                await enqueueLineNow(#"{"id":\#(id),"result":{}}"#)
            }
        }
    }

    func receiveLine(maximumBytes: Int) async throws -> Data? {
        receiveCalls += 1
        events.append("receive:\(receiveCalls)")
        if !completedLines.isEmpty {
            return completedLines.removeFirst()
        }

        while true {
            guard let chunk = await chunks.next() else {
                if framer.bufferedByteCount > 0 {
                    throw CodexRPCLineTransportError.partialEOF
                }
                return nil
            }
            let lines = try framer.append(chunk, maximumBytes: maximumBytes)
            guard !lines.isEmpty else { continue }
            completedLines.append(contentsOf: lines.dropFirst())
            return lines[0]
        }
    }

    func terminate() async {
        guard !isTerminated else { return }
        isTerminated = true
        terminateCalls += 1
        if !configuration.keepOutputOpenOnTerminate {
            await chunks.finish()
        }
    }

    func enqueueLine(_ line: String) async {
        await enqueueLineNow(line)
    }

    func enqueueChunk(_ chunk: Data) async {
        await chunks.push(chunk)
    }

    func finishOutput() async {
        await chunks.finish()
    }

    func sentRequests() -> [FakeSentRequest] {
        sent
    }

    func lifecycleEvents() -> [String] {
        events
    }

    func receiveCallCount() -> Int {
        receiveCalls
    }

    func terminationCount() -> Int {
        terminateCalls
    }

    private func enqueueLineNow(_ line: String) async {
        await chunks.push(Data((line + "\n").utf8))
    }
}

private actor TestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending {
            waiter.resume()
        }
    }
}

private actor FakeChunkQueue {
    private var chunks: [Data] = []
    private var waiter: CheckedContinuation<Data?, Never>?
    private var isFinished = false

    func push(_ chunk: Data) {
        guard !isFinished else { return }
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: chunk)
        } else {
            chunks.append(chunk)
        }
    }

    func finish() {
        guard !isFinished else { return }
        isFinished = true
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: nil)
        }
    }

    func next() async -> Data? {
        if !chunks.isEmpty {
            return chunks.removeFirst()
        }
        if isFinished {
            return nil
        }
        return await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }
}
