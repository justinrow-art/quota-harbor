import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ThemeRasterLimits {
    static let maximumInputBytes = 16 * 1_024 * 1_024
    static let maximumDimension = 4_096
    static let maximumDecodedPixels = maximumDimension * maximumDimension
    static let maximumFrameCount = 1
}

enum ThemeRasterProcessingStage: Equatable, Sendable {
    case beforePreflight
    case beforeDecode
    case afterDecode
    case beforeEncode
    case afterEncode
    case beforeWrite
    case afterWrite
}

enum ThemeRasterProcessorError: Error, Equatable, Sendable {
    case invalidRasterCount(Int)
    case nonFileURL
    case securityScopeDenied
    case sourceUnavailable
    case symbolicLinkNotAllowed
    case notRegularFile
    case inputTooLarge(Int)
    case invalidImage
    case frameCountExceeded(Int)
    case unsupportedFormat(String)
    case decodedDimensionsExceeded(width: Int, height: Int)
    case decodedPixelCountExceeded(Int)
    case decodeFailed
    case encodeFailed
    case outputTooLarge(Int)
    case unsafeDestination
    case writeFailed
    case timedOut
    case cancelled
}

struct ThemeRasterSecurityScope: Sendable {
    let startAccessing: @Sendable (URL) -> Bool
    let stopAccessing: @Sendable (URL) -> Void

    static let system = ThemeRasterSecurityScope(
        startAccessing: { $0.startAccessingSecurityScopedResource() },
        stopAccessing: { $0.stopAccessingSecurityScopedResource() }
    )
}

/// A file-picker boundary creates this value after the user chooses a file.
/// The processor deliberately accepts no bare URL so an unsandboxed readable
/// path cannot be mistaken for user consent.
struct ThemeRasterUserSelection: Sendable {
    fileprivate enum Access: Sendable {
        case directFromUnsandboxedOpenPanel
        case appOwnedImportedThemePayload
        case securityScoped
    }

    fileprivate let url: URL
    fileprivate let access: Access

    static func unsandboxedOpenPanelSelection(
        _ url: URL
    ) -> ThemeRasterUserSelection {
        ThemeRasterUserSelection(
            url: url,
            access: .directFromUnsandboxedOpenPanel
        )
    }

    static func securityScopedOpenPanelSelection(
        _ url: URL
    ) -> ThemeRasterUserSelection {
        ThemeRasterUserSelection(url: url, access: .securityScoped)
    }

    static func appOwnedImportedThemePayload(
        _ url: URL
    ) -> ThemeRasterUserSelection {
        ThemeRasterUserSelection(
            url: url,
            access: .appOwnedImportedThemePayload
        )
    }
}

private final class ThemeRasterOperationGate<Output: Sendable>:
    @unchecked Sendable
{
    typealias Outcome = Result<Output, Error>

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Output, Error>?
    private var pendingOutcome: Outcome?
    private var isResolved = false

    func install(_ continuation: CheckedContinuation<Output, Error>) {
        let pending: Outcome? = lock.withLock {
            if let pendingOutcome {
                self.pendingOutcome = nil
                return pendingOutcome
            }
            self.continuation = continuation
            return nil
        }
        if let pending {
            resume(continuation, with: pending)
        }
    }

    func resolve(_ outcome: Outcome) {
        let installed: CheckedContinuation<Output, Error>? = lock.withLock {
            guard !isResolved else {
                return nil
            }
            isResolved = true
            guard let continuation else {
                pendingOutcome = outcome
                return nil
            }
            self.continuation = nil
            return continuation
        }
        if let installed {
            resume(installed, with: outcome)
        }
    }

    private func resume(
        _ continuation: CheckedContinuation<Output, Error>,
        with outcome: Outcome
    ) {
        switch outcome {
        case let .success(output):
            continuation.resume(returning: output)
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }
}

struct ThemeRasterProcessor: @unchecked Sendable {
    typealias RasterOperation = @Sendable (
        URL,
        @Sendable (ThemeRasterProcessingStage) throws -> Void
    ) throws -> Data

    static let productionProcessingDeadline: Duration = .seconds(2)

    private let appThemeDirectory: URL
    private let fileManager: FileManager
    private let securityScope: ThemeRasterSecurityScope
    private let processingDeadline: Duration
    private let rasterOperation: RasterOperation
    private let checkpoint: @Sendable (ThemeRasterProcessingStage) throws -> Void

    init(
        appThemeDirectory: URL = Self.defaultAppThemeDirectory(),
        fileManager: FileManager = .default,
        securityScope: ThemeRasterSecurityScope = .system,
        processingDeadline: Duration = Self.productionProcessingDeadline,
        rasterOperation: RasterOperation? = nil,
        checkpoint: @escaping @Sendable (ThemeRasterProcessingStage) throws -> Void = { _ in
            guard !Task<Never, Never>.isCancelled else {
                throw ThemeRasterProcessorError.cancelled
            }
        }
    ) {
        self.appThemeDirectory = appThemeDirectory.standardizedFileURL
        self.fileManager = fileManager
        self.securityScope = securityScope
        self.processingDeadline = processingDeadline
        self.rasterOperation = rasterOperation ?? { sourceURL, checkpoint in
            try Self.processRaster(
                at: sourceURL,
                checkpoint: checkpoint
            )
        }
        self.checkpoint = checkpoint
    }

    func sanitize(
        userSelections: [ThemeRasterUserSelection]
    ) async throws -> SanitizedRasterReference {
        guard userSelections.count == 1 else {
            throw ThemeRasterProcessorError.invalidRasterCount(
                userSelections.count
            )
        }
        return try await sanitize(userSelection: userSelections[0])
    }

    func sanitize(
        userSelection: ThemeRasterUserSelection
    ) async throws -> SanitizedRasterReference {
        let sourceURL = userSelection.url
        guard sourceURL.isFileURL else {
            throw ThemeRasterProcessorError.nonFileURL
        }
        let scopeWasStarted: Bool
        switch userSelection.access {
        case .directFromUnsandboxedOpenPanel,
             .appOwnedImportedThemePayload:
            scopeWasStarted = false
        case .securityScoped:
            guard securityScope.startAccessing(sourceURL) else {
                throw ThemeRasterProcessorError.securityScopeDenied
            }
            scopeWasStarted = true
        }
        defer {
            if scopeWasStarted {
                securityScope.stopAccessing(sourceURL)
            }
        }

        try checkpoint(.beforePreflight)
        let sourceStatus = try fileStatus(at: sourceURL)
        let sourceKind = sourceStatus.st_mode & mode_t(S_IFMT)
        guard sourceKind != mode_t(S_IFLNK) else {
            throw ThemeRasterProcessorError.symbolicLinkNotAllowed
        }
        guard sourceKind == mode_t(S_IFREG) else {
            throw ThemeRasterProcessorError.notRegularFile
        }
        guard sourceStatus.st_size >= 0 else {
            throw ThemeRasterProcessorError.sourceUnavailable
        }
        let byteCount = Int(sourceStatus.st_size)
        guard byteCount <= ThemeRasterLimits.maximumInputBytes else {
            throw ThemeRasterProcessorError.inputTooLarge(byteCount)
        }

        let encoded = try await performRasterOperation(at: sourceURL)
        guard encoded.count <= ThemeRasterLimits.maximumInputBytes else {
            throw ThemeRasterProcessorError.outputTooLarge(encoded.count)
        }
        try checkpoint(.afterEncode)

        let digest = SHA256.hash(data: encoded)
            .map { String(format: "%02x", $0) }
            .joined()
        let relativeIdentifier = digest + ".png"
        let reference = SanitizedRasterReference(
            relativeIdentifier: relativeIdentifier,
            sha256: digest
        )

        try checkpoint(.beforeWrite)
        let rasterDirectory = try prepareRasterDirectory()
        let outputURL = rasterDirectory.appendingPathComponent(
            relativeIdentifier,
            isDirectory: false
        )
        try writeAtomically(encoded, to: outputURL)
        try checkpoint(.afterWrite)
        return reference
    }

    static func defaultAppThemeDirectory(
        fileManager: FileManager = .default
    ) -> URL {
        let base = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support",
                isDirectory: true
            )
        return base
            .appendingPathComponent("CodexQuotaMonitor", isDirectory: true)
            .appendingPathComponent("Themes", isDirectory: true)
    }

    private func performRasterOperation(at sourceURL: URL) async throws -> Data {
        guard !Task<Never, Never>.isCancelled else {
            throw ThemeRasterProcessorError.cancelled
        }

        let gate = ThemeRasterOperationGate<Data>()
        let operation = rasterOperation
        let checkpoint = checkpoint
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: processingDeadline)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                guard !Task<Never, Never>.isCancelled else {
                    gate.resolve(
                        .failure(ThemeRasterProcessorError.cancelled)
                    )
                    return
                }

                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        gate.resolve(
                            .success(
                                try operation(sourceURL, checkpoint)
                            )
                        )
                    } catch {
                        gate.resolve(.failure(error))
                    }
                }
                Task.detached(priority: .utility) {
                    do {
                        try await clock.sleep(until: deadline)
                    } catch {
                        return
                    }
                    gate.resolve(
                        .failure(ThemeRasterProcessorError.timedOut)
                    )
                }
            }
        } onCancel: {
            gate.resolve(.failure(ThemeRasterProcessorError.cancelled))
        }
    }

    private static func processRaster(
        at sourceURL: URL,
        checkpoint: @Sendable (
            ThemeRasterProcessingStage
        ) throws -> Void
    ) throws -> Data {
        let sourceOptions = [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithURL(
            sourceURL as CFURL,
            sourceOptions
        ) else {
            throw ThemeRasterProcessorError.invalidImage
        }
        let frameCount = CGImageSourceGetCount(imageSource)
        guard frameCount > 0 else {
            throw ThemeRasterProcessorError.invalidImage
        }
        guard frameCount == ThemeRasterLimits.maximumFrameCount else {
            throw ThemeRasterProcessorError.frameCountExceeded(frameCount)
        }
        guard let sourceType = CGImageSourceGetType(imageSource) as String?
        else {
            throw ThemeRasterProcessorError.invalidImage
        }
        let allowedTypes = [UTType.png.identifier, UTType.jpeg.identifier]
        guard allowedTypes.contains(sourceType) else {
            throw ThemeRasterProcessorError.unsupportedFormat(sourceType)
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(
            imageSource,
            0,
            nil
        ) as? [CFString: Any],
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?
                .intValue,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?
                .intValue,
            width > 0,
            height > 0
        else {
            throw ThemeRasterProcessorError.invalidImage
        }
        guard width <= ThemeRasterLimits.maximumDimension,
              height <= ThemeRasterLimits.maximumDimension
        else {
            throw ThemeRasterProcessorError.decodedDimensionsExceeded(
                width: width,
                height: height
            )
        }
        let (pixelCount, overflow) = width.multipliedReportingOverflow(
            by: height
        )
        guard !overflow,
              pixelCount <= ThemeRasterLimits.maximumDecodedPixels
        else {
            throw ThemeRasterProcessorError.decodedPixelCountExceeded(
                overflow ? .max : pixelCount
            )
        }

        try checkpoint(.beforeDecode)
        let decodeOptions = [
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
        guard let decoded = CGImageSourceCreateImageAtIndex(
            imageSource,
            0,
            decodeOptions
        ) else {
            throw ThemeRasterProcessorError.decodeFailed
        }
        try checkpoint(.afterDecode)

        let converted = try convertToSRGB(decoded)
        try checkpoint(.beforeEncode)
        return try encodeMetadataFreePNG(converted)
    }

    private func fileStatus(at url: URL) throws -> stat {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw ThemeRasterProcessorError.sourceUnavailable
        }
        return status
    }

    private static func convertToSRGB(_ image: CGImage) throws -> CGImage {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: image.width,
                  height: image.height,
                  bitsPerComponent: 8,
                  bytesPerRow: image.width * 4,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                      | CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            throw ThemeRasterProcessorError.decodeFailed
        }
        context.interpolationQuality = .high
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )
        guard let converted = context.makeImage() else {
            throw ThemeRasterProcessorError.decodeFailed
        }
        return converted
    }

    private static func encodeMetadataFreePNG(_ image: CGImage) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ThemeRasterProcessorError.encodeFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ThemeRasterProcessorError.encodeFailed
        }
        return output as Data
    }

    private func prepareRasterDirectory() throws -> URL {
        try ensureSafeDirectory(appThemeDirectory)
        let rasterDirectory = appThemeDirectory.appendingPathComponent(
            "Rasters",
            isDirectory: true
        )
        try ensureSafeDirectory(rasterDirectory)

        let resolvedRoot = appThemeDirectory.resolvingSymlinksInPath()
            .standardizedFileURL
        let resolvedRaster = rasterDirectory.resolvingSymlinksInPath()
            .standardizedFileURL
        guard resolvedRaster.deletingLastPathComponent() == resolvedRoot else {
            throw ThemeRasterProcessorError.unsafeDestination
        }
        return rasterDirectory
    }

    private func ensureSafeDirectory(_ url: URL) throws {
        var status = stat()
        if lstat(url.path, &status) == 0 {
            let kind = status.st_mode & mode_t(S_IFMT)
            guard kind != mode_t(S_IFLNK), kind == mode_t(S_IFDIR) else {
                throw ThemeRasterProcessorError.unsafeDestination
            }
            return
        }
        guard errno == ENOENT else {
            throw ThemeRasterProcessorError.unsafeDestination
        }
        do {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
        } catch {
            throw ThemeRasterProcessorError.unsafeDestination
        }
        guard lstat(url.path, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
        else {
            throw ThemeRasterProcessorError.unsafeDestination
        }
    }

    private func writeAtomically(_ data: Data, to outputURL: URL) throws {
        var status = stat()
        if lstat(outputURL.path, &status) == 0 {
            let kind = status.st_mode & mode_t(S_IFMT)
            guard kind == mode_t(S_IFREG),
                  let existing = try? Data(contentsOf: outputURL),
                  existing == data
            else {
                throw ThemeRasterProcessorError.unsafeDestination
            }
            return
        }
        guard errno == ENOENT else {
            throw ThemeRasterProcessorError.writeFailed
        }
        do {
            try data.write(to: outputURL, options: .atomic)
            guard try Data(contentsOf: outputURL) == data else {
                throw ThemeRasterProcessorError.writeFailed
            }
        } catch let error as ThemeRasterProcessorError {
            throw error
        } catch {
            throw ThemeRasterProcessorError.writeFailed
        }
    }
}
