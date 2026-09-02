import Darwin
import Foundation

enum CodexQuotaMonitorLaunchMode: Equatable {
    case application
    case claudeStatusLineRelay
    case invalidHeadless

    private static let claudeStatusLineRelayFlag = "--claude-statusline-relay"

    static func resolve(arguments: [String]) -> Self {
        guard arguments.contains(claudeStatusLineRelayFlag) else {
            return .application
        }
        guard arguments.count == 2,
              arguments[0] != claudeStatusLineRelayFlag,
              arguments[1] == claudeStatusLineRelayFlag
        else {
            return .invalidHeadless
        }
        return .claudeStatusLineRelay
    }
}

protocol ClaudeRelayInputReading {
    func read(upToCount count: Int) throws -> Data?
}

protocol ClaudeRelayOutputWriting {
    func write(_ data: Data) throws
}

protocol ClaudeRelayPersisting {
    func persist(_ result: ClaudeStatusLineRelayResult) throws
}

extension ClaudeStatusLineCacheStore: ClaudeRelayPersisting {}

enum ClaudeRelayBoundedReadResult: Equatable {
    case data(Data)
    case tooLarge
}

private enum ClaudeRelayBoundedReaderError: Error {
    case emptyChunk
}

struct ClaudeRelayBoundedReader {
    private static let chunkSize = 4 * 1_024

    private let input: any ClaudeRelayInputReading

    init(input: any ClaudeRelayInputReading) {
        self.input = input
    }

    func read() throws -> ClaudeRelayBoundedReadResult {
        let maximumBytes = ClaudeStatusLineRelay.maximumInputBytes
        let probeLimit = maximumBytes + 1
        var data = Data()

        while data.count < probeLimit {
            let requestedCount = min(
                Self.chunkSize,
                probeLimit - data.count
            )
            guard let chunk = try input.read(upToCount: requestedCount) else {
                break
            }
            guard !chunk.isEmpty else {
                throw ClaudeRelayBoundedReaderError.emptyChunk
            }
            guard chunk.count <= requestedCount else {
                return .tooLarge
            }
            data.append(chunk)
        }

        guard data.count <= maximumBytes else {
            return .tooLarge
        }
        return .data(data)
    }
}

enum ClaudeRelayExit {
    static let success: Int32 = 0
    static let usage: Int32 = 64
    static let dataError: Int32 = 65
    static let ioError: Int32 = 74
}

enum CodexQuotaMonitorLaunchRouter {
    static func route(
        arguments: [String],
        application: () -> Void,
        relay: () -> Int32
    ) -> Int32? {
        switch CodexQuotaMonitorLaunchMode.resolve(arguments: arguments) {
        case .application:
            application()
            return nil
        case .claudeStatusLineRelay:
            return relay()
        case .invalidHeadless:
            return ClaudeRelayExit.usage
        }
    }
}

struct ClaudeRelayCommand {
    private let input: any ClaudeRelayInputReading
    private let output: any ClaudeRelayOutputWriting
    private let cache: any ClaudeRelayPersisting
    private let now: () -> Date

    init(
        input: any ClaudeRelayInputReading,
        output: any ClaudeRelayOutputWriting,
        cache: any ClaudeRelayPersisting,
        now: @escaping () -> Date
    ) {
        self.input = input
        self.output = output
        self.cache = cache
        self.now = now
    }

    func run() -> Int32 {
        let readResult: ClaudeRelayBoundedReadResult
        do {
            readResult = try ClaudeRelayBoundedReader(input: input).read()
        } catch {
            return ClaudeRelayExit.ioError
        }

        guard case let .data(data) = readResult else {
            return ClaudeRelayExit.dataError
        }
        guard let result = ClaudeStatusLineRelay.parse(
            data,
            receivedAt: now()
        ) else {
            return ClaudeRelayExit.dataError
        }

        do {
            try cache.persist(result)
            let renderedData = Data(ClaudeStatusLineRelay.render(result).utf8)
            try output.write(renderedData)
            return ClaudeRelayExit.success
        } catch {
            return ClaudeRelayExit.ioError
        }
    }
}

struct ClaudeRelayFileInput: ClaudeRelayInputReading {
    let handle: FileHandle

    func read(upToCount count: Int) throws -> Data? {
        try handle.read(upToCount: count)
    }
}

struct ClaudeRelayFileOutput: ClaudeRelayOutputWriting {
    let handle: FileHandle

    init(handle: FileHandle) throws {
        guard Darwin.fcntl(
            handle.fileDescriptor,
            F_SETNOSIGPIPE,
            1
        ) == 0 else {
            throw ClaudeRelayFileOutputError.cannotSuppressBrokenPipe
        }
        self.handle = handle
    }

    func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
    }
}

private enum ClaudeRelayFileOutputError: Error {
    case cannotSuppressBrokenPipe
}

struct ClaudeRelayApplicationSupportCache {
    private static let appDirectoryName = "CodexQuotaMonitor"
    private static let cacheFileName = "claude-statusline-quota.json"

    let applicationSupportURL: URL

    func prepareStore() throws -> ClaudeStatusLineCacheStore {
        let components = applicationSupportURL.pathComponents
        guard applicationSupportURL.isFileURL,
              components.first == "/",
              components.count >= 2,
              components.dropFirst().allSatisfy(Self.isSafePathComponent)
        else {
            throw ClaudeRelayApplicationSupportCacheError.unsafeLocation
        }

        var descriptor = Darwin.open(
            "/",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw Self.posixError()
        }
        defer { Darwin.close(descriptor) }

        for component in components.dropFirst() {
            let nextDescriptor = component.withCString {
                Darwin.openat(
                    descriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard nextDescriptor >= 0 else {
                throw ClaudeRelayApplicationSupportCacheError.unsafeLocation
            }
            Darwin.close(descriptor)
            descriptor = nextDescriptor
        }

        try Self.createAppDirectoryIfNeeded(
            parentDescriptor: descriptor
        )
        let appDescriptor = Self.appDirectoryName.withCString {
            Darwin.openat(
                descriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard appDescriptor >= 0 else {
            throw ClaudeRelayApplicationSupportCacheError.unsafeLocation
        }
        defer { Darwin.close(appDescriptor) }

        var directoryInfo = stat()
        guard Darwin.fstat(appDescriptor, &directoryInfo) == 0,
              Self.isDirectory(directoryInfo),
              directoryInfo.st_uid == Darwin.geteuid()
        else {
            throw ClaudeRelayApplicationSupportCacheError.unsafeLocation
        }
        guard Darwin.fchmod(appDescriptor, mode_t(0o700)) == 0 else {
            throw Self.posixError()
        }
        var normalizedDirectoryInfo = stat()
        guard Darwin.fstat(appDescriptor, &normalizedDirectoryInfo) == 0,
              Self.isDirectory(normalizedDirectoryInfo),
              normalizedDirectoryInfo.st_uid == Darwin.geteuid(),
              normalizedDirectoryInfo.st_mode & mode_t(0o777)
                == mode_t(0o700)
        else {
            throw ClaudeRelayApplicationSupportCacheError.unsafeLocation
        }

        return ClaudeStatusLineCacheStore(
            fileURL: applicationSupportURL
                .appendingPathComponent(
                    Self.appDirectoryName,
                    isDirectory: true
                )
                .appendingPathComponent(Self.cacheFileName)
        )
    }

    private static func createAppDirectoryIfNeeded(
        parentDescriptor: Int32
    ) throws {
        var fileInfo = stat()
        let status = appDirectoryName.withCString {
            Darwin.fstatat(
                parentDescriptor,
                $0,
                &fileInfo,
                AT_SYMLINK_NOFOLLOW
            )
        }
        if status == 0 {
            guard isDirectory(fileInfo) else {
                throw ClaudeRelayApplicationSupportCacheError.unsafeLocation
            }
            return
        }
        guard errno == ENOENT else {
            throw ClaudeRelayApplicationSupportCacheError.unsafeLocation
        }

        let createStatus = appDirectoryName.withCString {
            Darwin.mkdirat(parentDescriptor, $0, mode_t(0o700))
        }
        guard createStatus == 0 else {
            throw ClaudeRelayApplicationSupportCacheError.unsafeLocation
        }
    }

    private static func isSafePathComponent(_ component: String) -> Bool {
        !component.isEmpty
            && component != "/"
            && component != "."
            && component != ".."
            && !component.contains("/")
    }

    private static func isDirectory(_ fileInfo: stat) -> Bool {
        (fileInfo.st_mode & S_IFMT) == S_IFDIR
    }

    private static func posixError() -> ClaudeRelayApplicationSupportCacheError {
        .fileOperationFailed(code: errno)
    }
}

enum ClaudeRelayApplicationSupportCacheError: Error, Equatable {
    case unsafeLocation
    case fileOperationFailed(code: Int32)
}

enum ClaudeRelayProduction {
    static func run() -> Int32 {
        guard let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return ClaudeRelayExit.ioError
        }

        do {
            let cache = try ClaudeRelayApplicationSupportCache(
                applicationSupportURL: applicationSupportURL
            ).prepareStore()
            return ClaudeRelayCommand(
                input: ClaudeRelayFileInput(handle: .standardInput),
                output: try ClaudeRelayFileOutput(handle: .standardOutput),
                cache: cache,
                now: Date.init
            ).run()
        } catch {
            return ClaudeRelayExit.ioError
        }
    }
}
