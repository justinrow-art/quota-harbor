import Darwin
import Foundation
import XCTest
@testable import CodexQuotaMonitor

final class ClaudeRelayCommandTests: XCTestCase {
    private let executable = "/Applications/CodexQuotaMonitor.app/Contents/MacOS/CodexQuotaMonitor"
    private let receivedAt = Date(timeIntervalSince1970: 1_753_000_000)

    func testOnlyExactFlagGrammarSelectsRelay() {
        XCTAssertEqual(
            CodexQuotaMonitorLaunchMode.resolve(
                arguments: [executable, "--claude-statusline-relay"]
            ),
            .claudeStatusLineRelay
        )

        for arguments in [
            ["--claude-statusline-relay"],
            [executable, "--claude-statusline-relay", "extra"],
            [executable, "extra", "--claude-statusline-relay"],
            [executable, "--claude-statusline-relay", "--claude-statusline-relay"],
        ] {
            XCTAssertEqual(
                CodexQuotaMonitorLaunchMode.resolve(arguments: arguments),
                .invalidHeadless
            )
        }
    }

    func testArgumentsWithoutExactFlagSelectApplication() {
        for arguments in [
            [],
            [executable],
            [executable, "-ApplePersistenceIgnoreState", "YES"],
            [executable, "--claude-statusline-relay=1"],
        ] {
            XCTAssertEqual(
                CodexQuotaMonitorLaunchMode.resolve(arguments: arguments),
                .application
            )
        }
    }

    func testExitCodesMatchStableHeadlessContract() {
        XCTAssertEqual(ClaudeRelayExit.success, 0)
        XCTAssertEqual(ClaudeRelayExit.usage, 64)
        XCTAssertEqual(ClaudeRelayExit.dataError, 65)
        XCTAssertEqual(ClaudeRelayExit.ioError, 74)
    }

    func testRelayAndInvalidRoutesNeverConstructApplication() {
        var applicationCount = 0
        var relayCount = 0

        let relayExit = CodexQuotaMonitorLaunchRouter.route(
            arguments: [executable, "--claude-statusline-relay"],
            application: { applicationCount += 1 },
            relay: {
                relayCount += 1
                return ClaudeRelayExit.ioError
            }
        )
        let invalidExit = CodexQuotaMonitorLaunchRouter.route(
            arguments: [executable, "--claude-statusline-relay", "extra"],
            application: { applicationCount += 1 },
            relay: {
                relayCount += 1
                return ClaudeRelayExit.success
            }
        )

        XCTAssertEqual(relayExit, ClaudeRelayExit.ioError)
        XCTAssertEqual(invalidExit, ClaudeRelayExit.usage)
        XCTAssertEqual(applicationCount, 0)
        XCTAssertEqual(relayCount, 1)
    }

    func testApplicationRouteDoesNotRunRelay() {
        var applicationCount = 0
        var relayCount = 0

        let exitCode = CodexQuotaMonitorLaunchRouter.route(
            arguments: [executable],
            application: { applicationCount += 1 },
            relay: {
                relayCount += 1
                return ClaudeRelayExit.success
            }
        )

        XCTAssertNil(exitCode)
        XCTAssertEqual(applicationCount, 1)
        XCTAssertEqual(relayCount, 0)
    }

    func testBoundedReaderAcceptsExactly64KiBAndProbesForOneMoreByte() throws {
        let data = Data(
            repeating: 0x61,
            count: ClaudeStatusLineRelay.maximumInputBytes
        )
        let input = RecordingClaudeRelayInput(data: data)

        let result = try ClaudeRelayBoundedReader(input: input).read()

        XCTAssertEqual(result, .data(data))
        XCTAssertEqual(input.deliveredByteCount, data.count)
        XCTAssertTrue(input.requestedCounts.allSatisfy { $0 <= 4_096 })
        XCTAssertEqual(input.requestedCounts.last, 1)
    }

    func testBoundedReaderRejectsByteBeyond64KiB() throws {
        let data = Data(
            repeating: 0x61,
            count: ClaudeStatusLineRelay.maximumInputBytes + 1
        )
        let input = RecordingClaudeRelayInput(data: data)

        let result = try ClaudeRelayBoundedReader(input: input).read()

        XCTAssertEqual(result, .tooLarge)
        XCTAssertEqual(
            input.deliveredByteCount,
            ClaudeStatusLineRelay.maximumInputBytes + 1
        )
    }

    func testCommandRejectsNonEOFEmptyChunkAsIOFailure() {
        let input = ScriptedClaudeRelayInput(
            chunks: [
                Data(#"{}"#.utf8),
                Data(),
                Data(repeating: 0x61, count: 4_096),
            ]
        )
        let output = RecordingClaudeRelayOutput()
        let cache = RecordingClaudeRelayCache()

        let exitCode = makeCommand(
            input: input,
            output: output,
            cache: cache
        ).run()

        XCTAssertEqual(exitCode, ClaudeRelayExit.ioError)
        XCTAssertTrue(cache.persisted.isEmpty)
        XCTAssertTrue(output.writes.isEmpty)
    }

    func testBoundedReaderRejectsChunkLargerThanRequestedCount() throws {
        let input = ScriptedClaudeRelayInput(
            chunks: [Data(repeating: 0x61, count: 4_097)]
        )

        let result = try ClaudeRelayBoundedReader(input: input).read()

        XCTAssertEqual(result, .tooLarge)
    }

    func testCommandPersistsBeforeWritingAllowlistedOutput() throws {
        let events = RelayEventRecorder()
        let input = RecordingClaudeRelayInput(data: validPayload)
        let output = RecordingClaudeRelayOutput(events: events)
        let cache = RecordingClaudeRelayCache(events: events)

        let exitCode = makeCommand(
            input: input,
            output: output,
            cache: cache
        ).run()

        XCTAssertEqual(exitCode, ClaudeRelayExit.success)
        let snapshot = try XCTUnwrap(cache.persisted.first?.snapshot)
        XCTAssertEqual(snapshot.receivedAt, receivedAt)
        XCTAssertEqual(snapshot.fiveHour?.usedPercentage, 12)
        XCTAssertEqual(output.writes, [Data("5h 12%\n".utf8)])
        XCTAssertEqual(events.events, [.persist, .write])
    }

    func testCommandMapsDataAndIOFailuresToStableSilentExitCodes() {
        let malformedOutput = RecordingClaudeRelayOutput()
        let malformedExit = makeCommand(
            input: RecordingClaudeRelayInput(data: Data("raw-secret".utf8)),
            output: malformedOutput,
            cache: RecordingClaudeRelayCache()
        ).run()
        let oversizedOutput = RecordingClaudeRelayOutput()
        let oversizedExit = makeCommand(
            input: RecordingClaudeRelayInput(
                data: Data(
                    repeating: 0x61,
                    count: ClaudeStatusLineRelay.maximumInputBytes + 1
                )
            ),
            output: oversizedOutput,
            cache: RecordingClaudeRelayCache()
        ).run()
        let readFailureOutput = RecordingClaudeRelayOutput()
        let readFailureExit = makeCommand(
            input: RecordingClaudeRelayInput(
                data: Data(),
                failure: StubRelayError.failed
            ),
            output: readFailureOutput,
            cache: RecordingClaudeRelayCache()
        ).run()

        XCTAssertEqual(malformedExit, ClaudeRelayExit.dataError)
        XCTAssertEqual(oversizedExit, ClaudeRelayExit.dataError)
        XCTAssertEqual(readFailureExit, ClaudeRelayExit.ioError)
        XCTAssertTrue(malformedOutput.writes.isEmpty)
        XCTAssertTrue(oversizedOutput.writes.isEmpty)
        XCTAssertTrue(readFailureOutput.writes.isEmpty)
    }

    func testCommandMapsCacheAndOutputFailuresToIOError() {
        let cacheFailureOutput = RecordingClaudeRelayOutput()
        let cacheFailureExit = makeCommand(
            input: RecordingClaudeRelayInput(data: validPayload),
            output: cacheFailureOutput,
            cache: RecordingClaudeRelayCache(failure: StubRelayError.failed)
        ).run()
        let outputFailureCache = RecordingClaudeRelayCache()
        let outputFailureExit = makeCommand(
            input: RecordingClaudeRelayInput(data: validPayload),
            output: RecordingClaudeRelayOutput(failure: StubRelayError.failed),
            cache: outputFailureCache
        ).run()

        XCTAssertEqual(cacheFailureExit, ClaudeRelayExit.ioError)
        XCTAssertEqual(outputFailureExit, ClaudeRelayExit.ioError)
        XCTAssertTrue(cacheFailureOutput.writes.isEmpty)
        XCTAssertEqual(outputFailureCache.persisted.count, 1)
    }

    func testNoQuotaSucceedsWithoutOverwritingExistingCache() throws {
        try withTemporaryDirectory { rootURL in
            let store = try ClaudeRelayApplicationSupportCache(
                applicationSupportURL: rootURL
            ).prepareStore()
            let window = try XCTUnwrap(
                ClaudeStatusLineQuotaWindow(
                    usedPercentage: 42,
                    resetAt: Date(timeIntervalSince1970: 1_753_003_600)
                )
            )
            let snapshot = try XCTUnwrap(
                ClaudeStatusLineSnapshot(
                    fiveHour: window,
                    sevenDay: nil,
                    receivedAt: receivedAt
                )
            )
            try store.persist(.snapshot(snapshot))
            let originalData = try Data(contentsOf: store.fileURL)
            let output = RecordingClaudeRelayOutput()

            let exitCode = makeCommand(
                input: RecordingClaudeRelayInput(data: Data(#"{}"#.utf8)),
                output: output,
                cache: store
            ).run()

            XCTAssertEqual(exitCode, ClaudeRelayExit.success)
            XCTAssertEqual(try Data(contentsOf: store.fileURL), originalData)
            XCTAssertEqual(output.writes, [Data()])
        }
    }

    func testFileHandleAdaptersReadAndWriteWithoutUnboundedInputAPI() throws {
        try withTemporaryDirectory { rootURL in
            let inputURL = rootURL.appendingPathComponent("input")
            let outputURL = rootURL.appendingPathComponent("output")
            try Data("input-data".utf8).write(to: inputURL)
            try Data().write(to: outputURL)
            let inputHandle = try FileHandle(forReadingFrom: inputURL)
            let outputHandle = try FileHandle(forWritingTo: outputURL)
            defer {
                try? inputHandle.close()
                try? outputHandle.close()
            }

            let inputResult = try ClaudeRelayBoundedReader(
                input: ClaudeRelayFileInput(handle: inputHandle)
            ).read()
            try ClaudeRelayFileOutput(handle: outputHandle).write(
                Data("output-data".utf8)
            )
            try outputHandle.synchronize()

            XCTAssertEqual(inputResult, .data(Data("input-data".utf8)))
            XCTAssertEqual(
                try Data(contentsOf: outputURL),
                Data("output-data".utf8)
            )
        }
    }

    func testFileOutputSuppressesSIGPIPEAndMapsClosedPipeToIOError() throws {
        let pipe = Pipe()
        let output = try ClaudeRelayFileOutput(
            handle: pipe.fileHandleForWriting
        )
        defer {
            try? pipe.fileHandleForWriting.close()
            try? pipe.fileHandleForReading.close()
        }

        guard Darwin.fcntl(
            pipe.fileHandleForWriting.fileDescriptor,
            F_GETNOSIGPIPE
        ) == 1 else {
            XCTFail("relay output must suppress SIGPIPE before writing")
            return
        }
        try pipe.fileHandleForReading.close()

        let exitCode = ClaudeRelayCommand(
            input: RecordingClaudeRelayInput(data: validPayload),
            output: output,
            cache: RecordingClaudeRelayCache(),
            now: { self.receivedAt }
        ).run()

        XCTAssertEqual(exitCode, ClaudeRelayExit.ioError)
    }

    func testApplicationSupportCacheCreatesOnlyAppOwnedChild() throws {
        try withTemporaryDirectory { rootURL in
            let store = try ClaudeRelayApplicationSupportCache(
                applicationSupportURL: rootURL
            ).prepareStore()
            let repeatedStore = try ClaudeRelayApplicationSupportCache(
                applicationSupportURL: rootURL
            ).prepareStore()

            XCTAssertEqual(
                store.fileURL,
                rootURL
                    .appendingPathComponent("CodexQuotaMonitor", isDirectory: true)
                    .appendingPathComponent("claude-statusline-quota.json")
            )
            XCTAssertFalse(store.fileURL.path.contains("/.claude/"))
            XCTAssertEqual(repeatedStore.fileURL, store.fileURL)
            var isDirectory: ObjCBool = false
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: store.fileURL.deletingLastPathComponent().path,
                    isDirectory: &isDirectory
                )
            )
            XCTAssertTrue(isDirectory.boolValue)
            let attributes = try FileManager.default.attributesOfItem(
                atPath: store.fileURL.deletingLastPathComponent().path
            )
            let permissions = try XCTUnwrap(
                attributes[.posixPermissions] as? NSNumber
            ).intValue
            XCTAssertEqual(permissions & 0o077, 0)
        }
    }

    func testApplicationSupportCacheNormalizesExistingAppDirectoryTo0700() throws {
        try withTemporaryDirectory { rootURL in
            let appDirectoryURL = rootURL.appendingPathComponent(
                "CodexQuotaMonitor",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: appDirectoryURL,
                withIntermediateDirectories: false
            )
            XCTAssertEqual(Darwin.chmod(appDirectoryURL.path, mode_t(0o777)), 0)

            _ = try ClaudeRelayApplicationSupportCache(
                applicationSupportURL: rootURL
            ).prepareStore()

            let attributes = try FileManager.default.attributesOfItem(
                atPath: appDirectoryURL.path
            )
            let permissions = try XCTUnwrap(
                attributes[.posixPermissions] as? NSNumber
            ).intValue
            XCTAssertEqual(permissions & 0o777, 0o700)
        }
    }

    func testApplicationSupportCacheRejectsSymlinksWithoutTouchingTarget() throws {
        try withTemporaryDirectory { rootURL in
            let redirectedURL = rootURL.appendingPathComponent(
                "redirected",
                isDirectory: true
            )
            let supportURL = rootURL.appendingPathComponent(
                "Application Support",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: redirectedURL,
                withIntermediateDirectories: false
            )
            try FileManager.default.createDirectory(
                at: supportURL,
                withIntermediateDirectories: false
            )
            let sentinelURL = redirectedURL.appendingPathComponent("sentinel")
            let sentinel = Data("unchanged".utf8)
            try sentinel.write(to: sentinelURL)
            let childURL = supportURL.appendingPathComponent(
                "CodexQuotaMonitor",
                isDirectory: true
            )
            try FileManager.default.createSymbolicLink(
                at: childURL,
                withDestinationURL: redirectedURL
            )

            XCTAssertThrowsError(
                try ClaudeRelayApplicationSupportCache(
                    applicationSupportURL: supportURL
                ).prepareStore()
            )
            XCTAssertEqual(try Data(contentsOf: sentinelURL), sentinel)

            let linkedSupportURL = rootURL.appendingPathComponent(
                "linked-support",
                isDirectory: true
            )
            try FileManager.default.createSymbolicLink(
                at: linkedSupportURL,
                withDestinationURL: redirectedURL
            )
            XCTAssertThrowsError(
                try ClaudeRelayApplicationSupportCache(
                    applicationSupportURL: linkedSupportURL
                ).prepareStore()
            )
            XCTAssertEqual(try Data(contentsOf: sentinelURL), sentinel)
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: redirectedURL
                        .appendingPathComponent("CodexQuotaMonitor")
                        .path
                )
            )

            let realURL = rootURL.appendingPathComponent(
                "real",
                isDirectory: true
            )
            let realSupportURL = realURL.appendingPathComponent(
                "support",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: realSupportURL,
                withIntermediateDirectories: true
            )
            let linkURL = rootURL.appendingPathComponent(
                "link",
                isDirectory: true
            )
            try FileManager.default.createSymbolicLink(
                at: linkURL,
                withDestinationURL: realURL
            )
            XCTAssertThrowsError(
                try ClaudeRelayApplicationSupportCache(
                    applicationSupportURL: linkURL.appendingPathComponent(
                        "support",
                        isDirectory: true
                    )
                ).prepareStore()
            )
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: realSupportURL
                        .appendingPathComponent("CodexQuotaMonitor")
                        .path
                )
            )
        }
    }

    func testApplicationSupportCacheRejectsNonDirectories() throws {
        try withTemporaryDirectory { rootURL in
            let supportURL = rootURL.appendingPathComponent(
                "Application Support",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: supportURL,
                withIntermediateDirectories: false
            )
            try Data("not-a-directory".utf8).write(
                to: supportURL.appendingPathComponent("CodexQuotaMonitor")
            )

            XCTAssertThrowsError(
                try ClaudeRelayApplicationSupportCache(
                    applicationSupportURL: supportURL
                ).prepareStore()
            )

            let fileURL = rootURL.appendingPathComponent("support-file")
            try Data("not-a-directory".utf8).write(to: fileURL)
            XCTAssertThrowsError(
                try ClaudeRelayApplicationSupportCache(
                    applicationSupportURL: fileURL
                ).prepareStore()
            )
        }
    }

    private var validPayload: Data {
        Data(
            #"{"rate_limits":{"five_hour":{"used_percentage":12,"resets_at":1753003600}}}"#.utf8
        )
    }

    private func makeCommand(
        input: any ClaudeRelayInputReading,
        output: RecordingClaudeRelayOutput,
        cache: any ClaudeRelayPersisting
    ) -> ClaudeRelayCommand {
        ClaudeRelayCommand(
            input: input,
            output: output,
            cache: cache,
            now: { self.receivedAt }
        )
    }

    private func withTemporaryDirectory(
        _ body: (URL) throws -> Void
    ) throws {
        let rootURL = try canonicalTemporaryDirectory()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try body(rootURL)
    }

    private func canonicalTemporaryDirectory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.path
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let result = path.withCString { Darwin.realpath($0, &buffer) }
        guard result != nil else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let resolvedPath = String(
            decoding: buffer.prefix { $0 != 0 }.map {
                UInt8(bitPattern: $0)
            },
            as: UTF8.self
        )
        return URL(fileURLWithPath: resolvedPath, isDirectory: true)
    }
}

private extension ClaudeStatusLineRelayResult {
    var snapshot: ClaudeStatusLineSnapshot? {
        guard case let .snapshot(snapshot) = self else { return nil }
        return snapshot
    }
}

private final class RecordingClaudeRelayInput: ClaudeRelayInputReading {
    private let data: Data
    private let failure: (any Error)?
    private var offset = 0
    private(set) var requestedCounts: [Int] = []

    init(data: Data, failure: (any Error)? = nil) {
        self.data = data
        self.failure = failure
    }

    var deliveredByteCount: Int { offset }

    func read(upToCount count: Int) throws -> Data? {
        requestedCounts.append(count)
        if let failure { throw failure }
        guard offset < data.count else { return nil }
        let end = min(offset + count, data.count)
        defer { offset = end }
        return data.subdata(in: offset..<end)
    }
}

private final class ScriptedClaudeRelayInput: ClaudeRelayInputReading {
    private var chunks: [Data]

    init(chunks: [Data]) {
        self.chunks = chunks
    }

    func read(upToCount count: Int) throws -> Data? {
        guard !chunks.isEmpty else { return nil }
        return chunks.removeFirst()
    }
}

private final class RecordingClaudeRelayOutput: ClaudeRelayOutputWriting {
    private let failure: (any Error)?
    private let events: RelayEventRecorder?
    private(set) var writes: [Data] = []

    init(
        failure: (any Error)? = nil,
        events: RelayEventRecorder? = nil
    ) {
        self.failure = failure
        self.events = events
    }

    func write(_ data: Data) throws {
        if let failure { throw failure }
        events?.events.append(.write)
        writes.append(data)
    }
}

private final class RecordingClaudeRelayCache: ClaudeRelayPersisting {
    private let failure: (any Error)?
    private let events: RelayEventRecorder?
    private(set) var persisted: [ClaudeStatusLineRelayResult] = []

    init(
        failure: (any Error)? = nil,
        events: RelayEventRecorder? = nil
    ) {
        self.failure = failure
        self.events = events
    }

    func persist(_ result: ClaudeStatusLineRelayResult) throws {
        if let failure { throw failure }
        events?.events.append(.persist)
        persisted.append(result)
    }
}

private final class RelayEventRecorder {
    var events: [RelayEvent] = []
}

private enum RelayEvent: Equatable {
    case persist
    case write
}

private enum StubRelayError: Error {
    case failed
}
