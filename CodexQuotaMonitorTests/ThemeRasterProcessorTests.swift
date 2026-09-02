import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import CodexQuotaMonitor

final class ThemeRasterProcessorTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var sourceDirectory: URL!
    private var themeDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        sourceDirectory = temporaryDirectory
            .appendingPathComponent("Sources", isDirectory: true)
        themeDirectory = temporaryDirectory
            .appendingPathComponent("AppThemes", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
        temporaryDirectory = nil
        sourceDirectory = nil
        themeDirectory = nil
    }

    func testExactlyOneSelectedRasterIsRequired() async throws {
        let first = try writeFixture(type: .png, name: "first.png")
        let second = try writeFixture(type: .jpeg, name: "second.jpg")
        let processor = makeProcessor()

        await assertThrows(.invalidRasterCount(0)) {
            _ = try await processor.sanitize(userSelections: [])
        }
        await assertThrows(.invalidRasterCount(2)) {
            _ = try await processor.sanitize(
                userSelections: [selected(first), selected(second)]
            )
        }
    }

    func testValidPNGIsReencodedDeterministicallyInsideThemeDirectory()
        async throws
    {
        let source = try writeFixture(type: .png, name: "private-source.png")
        let processor = makeProcessor()

        let first = try await processor.sanitize(
            userSelection: selected(source)
        )
        let firstData = try sanitizedData(for: first)
        let second = try await processor.sanitize(
            userSelection: selected(source)
        )
        let secondData = try sanitizedData(for: second)

        XCTAssertEqual(first, second)
        XCTAssertEqual(firstData, secondData)
        XCTAssertTrue(first.relativeIdentifier.hasSuffix(".png"))
        XCTAssertEqual(first.relativeIdentifier.count, 68)
        XCTAssertFalse(first.relativeIdentifier.contains("/"))
        XCTAssertFalse(first.relativeIdentifier.contains("private-source"))
        XCTAssertEqual(first.sha256 + ".png", first.relativeIdentifier)

        let output = outputURL(for: first)
        XCTAssertEqual(
            output.deletingLastPathComponent().standardizedFileURL,
            themeDirectory
                .appendingPathComponent("Rasters", isDirectory: true)
                .standardizedFileURL
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }

    func testValidJPEGIsConvertedToSingleFrameSRGBPNG() async throws {
        let source = try writeFixture(type: .jpeg, name: "fixture.jpg")

        let reference = try await makeProcessor()
            .sanitize(userSelection: selected(source))
        let data = try sanitizedData(for: reference)
        let imageSource = try XCTUnwrap(
            CGImageSourceCreateWithData(data as CFData, nil)
        )

        XCTAssertEqual(CGImageSourceGetCount(imageSource), 1)
        XCTAssertEqual(
            CGImageSourceGetType(imageSource) as String?,
            UTType.png.identifier
        )
        let image = try XCTUnwrap(
            CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        )
        XCTAssertEqual(
            image.colorSpace?.name as String?,
            CGColorSpace(name: CGColorSpace.sRGB)?.name as String?
        )
    }

    func testInputLargerThanSixteenMiBIsRejectedBeforeDecode() async throws {
        let source = sourceDirectory.appendingPathComponent("oversized.png")
        XCTAssertTrue(FileManager.default.createFile(atPath: source.path, contents: nil))
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: UInt64(ThemeRasterLimits.maximumInputBytes + 1))
        try handle.close()

        await assertThrows(
            .inputTooLarge(ThemeRasterLimits.maximumInputBytes + 1)
        ) {
            _ = try await makeProcessor().sanitize(
                userSelection: selected(source)
            )
        }
    }

    func testDecodedDimensionAbove4096IsRejectedBeforePixelAllocation()
        async throws
    {
        let source = try writeFixture(
            type: .png,
            name: "wide.png",
            width: ThemeRasterLimits.maximumDimension + 1,
            height: 1
        )

        await assertThrows(
            .decodedDimensionsExceeded(
                width: ThemeRasterLimits.maximumDimension + 1,
                height: 1
            )
        ) {
            _ = try await makeProcessor().sanitize(
                userSelection: selected(source)
            )
        }
    }

    func testCorruptImageIsRejectedWithoutWritingOutput() async throws {
        let source = sourceDirectory.appendingPathComponent("corrupt.png")
        try Data("not an image".utf8).write(to: source)

        await assertThrows(.invalidImage) {
            _ = try await makeProcessor().sanitize(
                userSelection: selected(source)
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: themeDirectory
                    .appendingPathComponent("Rasters", isDirectory: true)
                    .path
            )
        )
    }

    func testAnimatedImageIsRejectedByFrameCountBeforeFormat() async throws {
        let source = try writeAnimatedGIFFixture(name: "animated.gif")

        await assertThrows(.frameCountExceeded(2)) {
            _ = try await makeProcessor().sanitize(
                userSelection: selected(source)
            )
        }
    }

    func testUnsupportedSingleFrameFormatIsRejected() async throws {
        let source = try writeFixture(type: .gif, name: "single.gif")

        await assertThrows(.unsupportedFormat(UTType.gif.identifier)) {
            _ = try await makeProcessor().sanitize(
                userSelection: selected(source)
            )
        }
    }

    func testSymlinkAndNonRegularSourceAreRejected() async throws {
        let target = try writeFixture(type: .png, name: "target.png")
        let symlink = sourceDirectory.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: target
        )

        await assertThrows(.symbolicLinkNotAllowed) {
            _ = try await makeProcessor().sanitize(
                userSelection: selected(symlink)
            )
        }
        await assertThrows(.notRegularFile) {
            _ = try await makeProcessor().sanitize(
                userSelection: selected(sourceDirectory)
            )
        }
    }

    func testMovedOrDeletedSourceFailsClosed() async throws {
        let source = try writeFixture(type: .png, name: "removed.png")
        try FileManager.default.removeItem(at: source)

        await assertThrows(.sourceUnavailable) {
            _ = try await makeProcessor().sanitize(
                userSelection: selected(source)
            )
        }
    }

    func testSecurityScopeDenialFailsBeforeReadingAndSuccessfulScopeStops()
        async throws
    {
        let source = try writeFixture(type: .png, name: "scoped.png")
        let denied = ScopeRecorder(allowsAccess: false)

        await assertThrows(.securityScopeDenied) {
            _ = try await makeProcessor(scope: denied)
                .sanitize(userSelection: selected(source))
        }
        XCTAssertEqual(denied.startedURLs, [source])
        XCTAssertTrue(denied.stoppedURLs.isEmpty)

        let allowed = ScopeRecorder(allowsAccess: true)
        _ = try await makeProcessor(scope: allowed)
            .sanitize(userSelection: selected(source))
        XCTAssertEqual(allowed.startedURLs, [source])
        XCTAssertEqual(allowed.stoppedURLs, [source])
    }

    func testUnsandboxedOpenPanelSelectionUsesExplicitDirectAccessProof()
        async throws
    {
        let source = try writeFixture(type: .png, name: "direct.png")
        let deniedScope = ScopeRecorder(allowsAccess: false)
        let selection = ThemeRasterUserSelection
            .unsandboxedOpenPanelSelection(source)

        _ = try await makeProcessor(scope: deniedScope)
            .sanitize(userSelection: selection)

        XCTAssertTrue(deniedScope.startedURLs.isEmpty)
        XCTAssertTrue(deniedScope.stoppedURLs.isEmpty)
    }

    func testInjectedTimeoutAndCancellationCheckpointsLeaveNoOutput()
        async throws
    {
        let source = try writeFixture(type: .png, name: "checkpoint.png")
        for failure in [
            ThemeRasterProcessorError.timedOut,
            ThemeRasterProcessorError.cancelled,
        ] {
            let checkpoint = CheckpointRecorder(
                failureStage: .beforeDecode,
                failure: failure
            )
            await assertThrows(failure) {
                _ = try await makeProcessor(checkpoint: checkpoint)
                    .sanitize(userSelection: selected(source))
            }
            XCTAssertTrue(checkpoint.stages.contains(.beforeDecode))
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: themeDirectory
                    .appendingPathComponent("Rasters", isDirectory: true)
                    .path
            )
        )
    }

    func testBlockingRasterOperationTimesOutPromptlyAndLateResultNeverWrites()
        async throws
    {
        let source = try writeFixture(type: .png, name: "deadline.png")
        let operation = BlockingRasterOperation(
            delay: 0.75,
            result: try Data(contentsOf: source)
        )
        let checkpoint = CheckpointRecorder()
        let processor = makeDeadlineProcessor(
            processingDeadline: .milliseconds(80),
            checkpoint: checkpoint,
            rasterOperation: operation.run
        )
        let clock = ContinuousClock()
        let start = clock.now

        await assertThrows(.timedOut) {
            _ = try await processor.sanitize(
                userSelection: selected(source)
            )
        }

        let elapsed = start.duration(to: clock.now)
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(40))
        XCTAssertLessThan(elapsed, .milliseconds(500))
        XCTAssertFalse(checkpoint.stages.contains(.beforeWrite))
        XCTAssertFalse(rasterDirectoryExists())

        XCTAssertTrue(operation.waitUntilCompleted(timeout: 2))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(checkpoint.stages.contains(.beforeWrite))
        XCTAssertFalse(rasterDirectoryExists())
    }

    func testTaskCancellationWinsBlockedRasterOperationWithoutWriting()
        async throws
    {
        let source = try writeFixture(type: .png, name: "cancelled.png")
        let operation = BlockingRasterOperation(
            delay: 0.75,
            result: try Data(contentsOf: source)
        )
        let checkpoint = CheckpointRecorder()
        let processor = makeDeadlineProcessor(
            processingDeadline: .seconds(2),
            checkpoint: checkpoint,
            rasterOperation: { operation.run() }
        )
        let selection = selected(source)
        let task = Task {
            try await processor.sanitize(
                userSelection: selection
            )
        }
        XCTAssertTrue(operation.waitUntilStarted(timeout: 1))
        let clock = ContinuousClock()
        let cancellationStart = clock.now

        task.cancel()

        await assertThrows(.cancelled) {
            _ = try await task.value
        }
        XCTAssertLessThan(
            cancellationStart.duration(to: clock.now),
            .milliseconds(500)
        )
        XCTAssertFalse(checkpoint.stages.contains(.beforeWrite))
        XCTAssertFalse(rasterDirectoryExists())

        XCTAssertTrue(operation.waitUntilCompleted(timeout: 2))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(checkpoint.stages.contains(.beforeWrite))
        XCTAssertFalse(rasterDirectoryExists())
    }

    func testFastRasterOperationCommitsBeforeInjectedDeadline() async throws {
        let source = try writeFixture(type: .png, name: "fast-deadline.png")
        let sourceData = try Data(contentsOf: source)
        let checkpoint = CheckpointRecorder()
        let processor = makeDeadlineProcessor(
            processingDeadline: .milliseconds(500),
            checkpoint: checkpoint,
            rasterOperation: { sourceData }
        )

        let reference = try await processor.sanitize(
            userSelection: selected(source)
        )

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: outputURL(for: reference).path
        ))
        XCTAssertTrue(checkpoint.stages.contains(.beforeWrite))
    }

    func testEXIFGPSAndPrivateSourceMetadataAreStripped() async throws {
        let privateMarker = "/Users/private-account/Pictures/source.png"
        let source = try writeFixture(
            type: .png,
            name: "metadata.png",
            properties: [
                kCGImagePropertyExifDictionary: [
                    kCGImagePropertyExifUserComment: privateMarker,
                ],
                kCGImagePropertyGPSDictionary: [
                    kCGImagePropertyGPSLatitude: 25.033,
                    kCGImagePropertyGPSLongitude: 121.5654,
                ],
                kCGImagePropertyTIFFDictionary: [
                    kCGImagePropertyTIFFArtist: "Private Creator",
                ],
            ]
        )

        let reference = try await makeProcessor()
            .sanitize(userSelection: selected(source))
        let data = try sanitizedData(for: reference)
        let sanitizedSource = try XCTUnwrap(
            CGImageSourceCreateWithData(data as CFData, nil)
        )
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(sanitizedSource, 0, nil)
                as? [CFString: Any]
        )

        let exif = properties[kCGImagePropertyExifDictionary]
            as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary]
            as? [CFString: Any]

        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        XCTAssertNil(exif?[kCGImagePropertyExifUserComment])
        XCTAssertNil(tiff?[kCGImagePropertyTIFFArtist])
        XCTAssertFalse(dataContains(data, privateMarker))
        XCTAssertFalse(dataContains(data, "Private Creator"))
    }

    func testSymlinkedRasterDestinationCannotEscapeThemeDirectory()
        async throws
    {
        let source = try writeFixture(type: .png, name: "safe.png")
        let outside = temporaryDirectory
            .appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(
            at: themeDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: themeDirectory.appendingPathComponent("Rasters"),
            withDestinationURL: outside
        )

        await assertThrows(.unsafeDestination) {
            _ = try await makeProcessor().sanitize(
                userSelection: selected(source)
            )
        }
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: outside.path)
                .isEmpty
        )
    }

    func testDefaultDestinationIsApplicationSupportAppThemeDirectory() {
        let base = temporaryDirectory
            .appendingPathComponent("ApplicationSupport", isDirectory: true)
        let fileManager = FixedApplicationSupportFileManager(baseURL: base)

        XCTAssertEqual(
            ThemeRasterProcessor.defaultAppThemeDirectory(
                fileManager: fileManager
            ),
            base
                .appendingPathComponent("CodexQuotaMonitor", isDirectory: true)
                .appendingPathComponent("Themes", isDirectory: true)
        )
    }

    private func makeProcessor(
        scope: ScopeRecorder = ScopeRecorder(allowsAccess: true),
        checkpoint: CheckpointRecorder = CheckpointRecorder()
    ) -> ThemeRasterProcessor {
        ThemeRasterProcessor(
            appThemeDirectory: themeDirectory,
            securityScope: ThemeRasterSecurityScope(
                startAccessing: { scope.start($0) },
                stopAccessing: { scope.stop($0) }
            ),
            checkpoint: { try checkpoint.check($0) }
        )
    }

    private func makeDeadlineProcessor(
        processingDeadline: Duration,
        checkpoint: CheckpointRecorder,
        rasterOperation: @escaping @Sendable () throws -> Data
    ) -> ThemeRasterProcessor {
        ThemeRasterProcessor(
            appThemeDirectory: themeDirectory,
            securityScope: ThemeRasterSecurityScope(
                startAccessing: { _ in true },
                stopAccessing: { _ in }
            ),
            processingDeadline: processingDeadline,
            rasterOperation: { _, workerCheckpoint in
                try workerCheckpoint(.beforeDecode)
                let encoded = try rasterOperation()
                try workerCheckpoint(.afterDecode)
                try workerCheckpoint(.beforeEncode)
                return encoded
            },
            checkpoint: { try checkpoint.check($0) }
        )
    }

    private func selected(_ url: URL) -> ThemeRasterUserSelection {
        .securityScopedOpenPanelSelection(url)
    }

    private func sanitizedData(
        for reference: SanitizedRasterReference
    ) throws -> Data {
        try Data(contentsOf: outputURL(for: reference))
    }

    private func outputURL(for reference: SanitizedRasterReference) -> URL {
        themeDirectory
            .appendingPathComponent("Rasters", isDirectory: true)
            .appendingPathComponent(reference.relativeIdentifier)
    }

    private func rasterDirectoryExists() -> Bool {
        FileManager.default.fileExists(
            atPath: themeDirectory
                .appendingPathComponent("Rasters", isDirectory: true)
                .path
        )
    }

    private func writeFixture(
        type: UTType,
        name: String,
        width: Int = 8,
        height: Int = 6,
        properties: [CFString: Any] = [:]
    ) throws -> URL {
        let url = sourceDirectory.appendingPathComponent(name)
        let image = try makeImage(width: width, height: height)
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(
                url as CFURL,
                type.identifier as CFString,
                1,
                nil
            )
        )
        CGImageDestinationAddImage(
            destination,
            image,
            properties as CFDictionary
        )
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func writeAnimatedGIFFixture(name: String) throws -> URL {
        let url = sourceDirectory.appendingPathComponent(name)
        let image = try makeImage(width: 4, height: 4)
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.gif.identifier as CFString,
                2,
                nil
            )
        )
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        let colorSpace = try XCTUnwrap(
            CGColorSpace(name: CGColorSpace.displayP3)
        )
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(
            CGColor(
                colorSpace: colorSpace,
                components: [0.2, 0.4, 0.8, 1]
            )!
        )
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func dataContains(_ data: Data, _ text: String) -> Bool {
        data.range(of: Data(text.utf8)) != nil
    }

    private func assertThrows(
        _ expected: ThemeRasterProcessorError,
        operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(
                error as? ThemeRasterProcessorError,
                expected,
                file: file,
                line: line
            )
        }
    }
}

private final class ScopeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let allowsAccess: Bool
    private var started: [URL] = []
    private var stopped: [URL] = []

    init(allowsAccess: Bool) {
        self.allowsAccess = allowsAccess
    }

    var startedURLs: [URL] { lock.withLock { started } }
    var stoppedURLs: [URL] { lock.withLock { stopped } }

    func start(_ url: URL) -> Bool {
        lock.withLock { started.append(url) }
        return allowsAccess
    }

    func stop(_ url: URL) {
        lock.withLock { stopped.append(url) }
    }
}

private final class CheckpointRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let failureStage: ThemeRasterProcessingStage?
    private let failure: ThemeRasterProcessorError?
    private var recordedStages: [ThemeRasterProcessingStage] = []

    init(
        failureStage: ThemeRasterProcessingStage? = nil,
        failure: ThemeRasterProcessorError? = nil
    ) {
        self.failureStage = failureStage
        self.failure = failure
    }

    var stages: [ThemeRasterProcessingStage] {
        lock.withLock { recordedStages }
    }

    func check(_ stage: ThemeRasterProcessingStage) throws {
        lock.withLock { recordedStages.append(stage) }
        if stage == failureStage, let failure {
            throw failure
        }
    }
}

private final class BlockingRasterOperation: @unchecked Sendable {
    private let delay: TimeInterval
    private let result: Data
    private let started = DispatchSemaphore(value: 0)
    private let completed = DispatchSemaphore(value: 0)

    init(delay: TimeInterval, result: Data) {
        self.delay = delay
        self.result = result
    }

    func run() -> Data {
        started.signal()
        defer { completed.signal() }
        Thread.sleep(forTimeInterval: delay)
        return result
    }

    func waitUntilStarted(timeout: TimeInterval) -> Bool {
        started.wait(timeout: .now() + timeout) == .success
    }

    func waitUntilCompleted(timeout: TimeInterval) -> Bool {
        completed.wait(timeout: .now() + timeout) == .success
    }
}

private final class FixedApplicationSupportFileManager: FileManager,
    @unchecked Sendable
{
    private let baseURL: URL

    init(baseURL: URL) {
        self.baseURL = baseURL
        super.init()
    }

    override func urls(
        for directory: FileManager.SearchPathDirectory,
        in domainMask: FileManager.SearchPathDomainMask
    ) -> [URL] {
        directory == .applicationSupportDirectory ? [baseURL] : []
    }
}
