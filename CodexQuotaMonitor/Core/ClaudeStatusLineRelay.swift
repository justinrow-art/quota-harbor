import Foundation
import Darwin

struct ClaudeStatusLineQuotaWindow: Codable, Equatable, Sendable {
    // App-level JSON/Date safety bound, not a provider quota claim.
    static let maximumAcceptedResetEpoch = 253_402_300_799.0

    let usedPercentage: Double
    let resetAt: Date

    init?(usedPercentage: Double, resetAt: Date) {
        let resetEpoch = resetAt.timeIntervalSince1970
        guard usedPercentage.isFinite,
              (0...100).contains(usedPercentage),
              resetEpoch.isFinite,
              (0...Self.maximumAcceptedResetEpoch).contains(resetEpoch)
        else {
            return nil
        }
        self.usedPercentage = usedPercentage
        self.resetAt = resetAt
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case usedPercentage
        case resetAt
    }

    init(from decoder: any Decoder) throws {
        try StrictJSONKeys.requireOnly(
            CodingKeys.allCases.map(\.rawValue),
            from: decoder
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let usedPercentage = try container.decode(
            Double.self,
            forKey: .usedPercentage
        )
        let resetAt = try container.decode(Date.self, forKey: .resetAt)
        guard let value = Self(
            usedPercentage: usedPercentage,
            resetAt: resetAt
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .usedPercentage,
                in: container,
                debugDescription: "Quota window is outside the accepted range."
            )
        }
        self = value
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(usedPercentage, forKey: .usedPercentage)
        try container.encode(resetAt, forKey: .resetAt)
    }
}

struct ClaudeStatusLineSnapshot: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let fiveHour: ClaudeStatusLineQuotaWindow?
    let sevenDay: ClaudeStatusLineQuotaWindow?
    let receivedAt: Date

    init?(
        schemaVersion: Int = 1,
        fiveHour: ClaudeStatusLineQuotaWindow?,
        sevenDay: ClaudeStatusLineQuotaWindow?,
        receivedAt: Date
    ) {
        guard schemaVersion == 1,
              fiveHour != nil || sevenDay != nil,
              receivedAt.timeIntervalSince1970.isFinite
        else {
            return nil
        }
        self.schemaVersion = schemaVersion
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.receivedAt = receivedAt
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case fiveHour
        case sevenDay
        case receivedAt
    }

    init(from decoder: any Decoder) throws {
        try StrictJSONKeys.requireOnly(
            CodingKeys.allCases.map(\.rawValue),
            from: decoder
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(
            Int.self,
            forKey: .schemaVersion
        )
        let fiveHour = try container.decodeIfPresent(
            ClaudeStatusLineQuotaWindow.self,
            forKey: .fiveHour
        )
        let sevenDay = try container.decodeIfPresent(
            ClaudeStatusLineQuotaWindow.self,
            forKey: .sevenDay
        )
        let receivedAt = try container.decode(Date.self, forKey: .receivedAt)
        guard let value = Self(
            schemaVersion: schemaVersion,
            fiveHour: fiveHour,
            sevenDay: sevenDay,
            receivedAt: receivedAt
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Snapshot does not match schema version 1."
            )
        }
        self = value
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encodeIfPresent(fiveHour, forKey: .fiveHour)
        try container.encodeIfPresent(sevenDay, forKey: .sevenDay)
        try container.encode(receivedAt, forKey: .receivedAt)
    }
}

enum ClaudeStatusLineRelayResult: Equatable, Sendable {
    case noQuota
    case snapshot(ClaudeStatusLineSnapshot)
}

enum ClaudeStatusLineRelay {
    static let maximumInputBytes = 64 * 1_024

    static func parse(
        _ data: Data,
        receivedAt: Date
    ) -> ClaudeStatusLineRelayResult? {
        guard data.count <= maximumInputBytes,
              receivedAt.timeIntervalSince1970.isFinite,
              let payload = try? JSONDecoder().decode(
                  RelayPayload.self,
                  from: data
              )
        else {
            return nil
        }

        let fiveHour: ClaudeStatusLineQuotaWindow?
        if let raw = payload.rateLimits?.fiveHour {
            guard let value = raw.window else { return nil }
            fiveHour = value
        } else {
            fiveHour = nil
        }

        let sevenDay: ClaudeStatusLineQuotaWindow?
        if let raw = payload.rateLimits?.sevenDay {
            guard let value = raw.window else { return nil }
            sevenDay = value
        } else {
            sevenDay = nil
        }

        guard fiveHour != nil || sevenDay != nil else {
            return .noQuota
        }
        guard let snapshot = ClaudeStatusLineSnapshot(
            fiveHour: fiveHour,
            sevenDay: sevenDay,
            receivedAt: receivedAt
        ) else {
            return nil
        }
        return .snapshot(snapshot)
    }

    static func render(_ result: ClaudeStatusLineRelayResult) -> String {
        guard case let .snapshot(snapshot) = result else { return "" }
        var segments: [String] = []
        if let window = snapshot.fiveHour {
            segments.append("5h \(format(window.usedPercentage))%")
        }
        if let window = snapshot.sevenDay {
            segments.append("7d \(format(window.usedPercentage))%")
        }
        return segments.isEmpty ? "" : segments.joined(separator: " · ") + "\n"
    }

    private static func format(_ value: Double) -> String {
        String(
            format: "%.15g",
            locale: Locale(identifier: "en_US_POSIX"),
            value
        )
    }
}

struct ClaudeStatusLineCacheStore: Sendable {
    static let maximumCacheBytes = 64 * 1_024

    let fileURL: URL

    func load() -> ClaudeStatusLineSnapshot? {
        do {
            return try withAnchoredParentDirectory {
                parentDescriptor,
                fileName in
                let descriptor = fileName.withCString {
                    Darwin.openat(
                        parentDescriptor,
                        $0,
                        O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard descriptor >= 0 else {
                    return nil
                }
                let handle = FileHandle(
                    fileDescriptor: descriptor,
                    closeOnDealloc: true
                )
                defer { try? handle.close() }

                var fileInfo = stat()
                guard Darwin.fstat(descriptor, &fileInfo) == 0,
                      Self.isRegularFile(fileInfo),
                      fileInfo.st_size >= 0,
                      fileInfo.st_size <= Self.maximumCacheBytes
                else {
                    return nil
                }
                guard let data = try? handle.read(
                    upToCount: Self.maximumCacheBytes + 1
                ), data.count <= Self.maximumCacheBytes else {
                    return nil
                }
                return try? JSONDecoder().decode(
                    ClaudeStatusLineSnapshot.self,
                    from: data
                )
            }
        } catch {
            return nil
        }
    }

    func persist(_ result: ClaudeStatusLineRelayResult) throws {
        guard case let .snapshot(snapshot) = result else { return }
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= Self.maximumCacheBytes else {
            throw ClaudeStatusLineCacheStoreError.encodedSnapshotTooLarge
        }

        try withAnchoredParentDirectory { parentDescriptor, fileName in
            try Self.validateDestinationIfPresent(
                parentDescriptor: parentDescriptor,
                fileName: fileName
            )
            let temporaryName = ".\(fileName).\(UUID().uuidString).tmp"
            var shouldRemoveTemporaryFile = false
            defer {
                if shouldRemoveTemporaryFile {
                    _ = temporaryName.withCString {
                        Darwin.unlinkat(parentDescriptor, $0, 0)
                    }
                }
            }

            let descriptor = temporaryName.withCString {
                Darwin.openat(
                    parentDescriptor,
                    $0,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    mode_t(0o600)
                )
            }
            guard descriptor >= 0 else {
                throw Self.posixError(operation: "create temporary cache")
            }
            shouldRemoveTemporaryFile = true

            var shouldCloseDescriptor = true
            defer {
                if shouldCloseDescriptor {
                    Darwin.close(descriptor)
                }
            }
            guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
                throw Self.posixError(
                    operation: "set temporary cache permissions"
                )
            }
            try Self.writeAll(data, to: descriptor)
            guard Darwin.fsync(descriptor) == 0 else {
                throw Self.posixError(operation: "synchronize temporary cache")
            }
            guard Darwin.close(descriptor) == 0 else {
                shouldCloseDescriptor = false
                throw Self.posixError(operation: "close temporary cache")
            }
            shouldCloseDescriptor = false

            try Self.validateDestinationIfPresent(
                parentDescriptor: parentDescriptor,
                fileName: fileName
            )
            let renameResult = temporaryName.withCString { temporaryPath in
                fileName.withCString { destinationPath in
                    Darwin.renameatx_np(
                        parentDescriptor,
                        temporaryPath,
                        parentDescriptor,
                        destinationPath,
                        UInt32(RENAME_NOFOLLOW_ANY)
                    )
                }
            }
            guard renameResult == 0 else {
                throw Self.posixError(operation: "replace quota cache")
            }
            shouldRemoveTemporaryFile = false
        }
    }

    private func withAnchoredParentDirectory<Value>(
        _ body: (_ descriptor: Int32, _ fileName: String) throws -> Value
    ) throws -> Value {
        let components = fileURL.pathComponents
        guard fileURL.isFileURL,
              components.first == "/",
              components.count >= 2,
              let fileName = components.last,
              Self.isSafePathComponent(fileName),
              components.dropFirst().dropLast().allSatisfy(
                  Self.isSafePathComponent
              )
        else {
            throw ClaudeStatusLineCacheStoreError.unsafeCacheTarget
        }

        var descriptor = Darwin.open(
            "/",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw Self.posixError(operation: "open filesystem root")
        }
        defer { Darwin.close(descriptor) }

        for component in components.dropFirst().dropLast() {
            let nextDescriptor = component.withCString {
                Darwin.openat(
                    descriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard nextDescriptor >= 0 else {
                throw ClaudeStatusLineCacheStoreError.unsafeCacheTarget
            }
            Darwin.close(descriptor)
            descriptor = nextDescriptor
        }
        return try body(descriptor, fileName)
    }

    private static func validateDestinationIfPresent(
        parentDescriptor: Int32,
        fileName: String
    ) throws {
        var fileInfo = stat()
        let status = fileName.withCString {
            Darwin.fstatat(
                parentDescriptor,
                $0,
                &fileInfo,
                AT_SYMLINK_NOFOLLOW
            )
        }
        if status == 0 {
            guard Self.isRegularFile(fileInfo) else {
                throw ClaudeStatusLineCacheStoreError.unsafeCacheTarget
            }
            return
        }
        guard errno == ENOENT else {
            throw Self.posixError(operation: "inspect quota cache")
        }
    }

    private static func isSafePathComponent(_ component: String) -> Bool {
        !component.isEmpty
            && component != "/"
            && component != "."
            && component != ".."
            && !component.contains("/")
    }

    private static func isRegularFile(_ fileInfo: stat) -> Bool {
        (fileInfo.st_mode & S_IFMT) == S_IFREG
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0, errno == EINTR {
                    continue
                }
                guard count > 0 else {
                    throw posixError(operation: "write temporary cache")
                }
                offset += count
            }
        }
    }

    private static func posixError(
        operation: String
    ) -> ClaudeStatusLineCacheStoreError {
        .fileOperationFailed(operation: operation, code: errno)
    }
}

enum ClaudeStatusLineCacheStoreError: Error, Equatable, Sendable {
    case encodedSnapshotTooLarge
    case unsafeCacheTarget
    case fileOperationFailed(operation: String, code: Int32)
}

private struct RelayPayload: Decodable {
    let rateLimits: RelayRateLimits?

    private enum CodingKeys: String, CodingKey {
        case rateLimits = "rate_limits"
    }
}

private struct RelayRateLimits: Decodable {
    let fiveHour: RelayQuotaWindow?
    let sevenDay: RelayQuotaWindow?

    private enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }
}

private struct RelayQuotaWindow: Decodable {
    let usedPercentage: Double
    let resetEpoch: Double

    var window: ClaudeStatusLineQuotaWindow? {
        guard resetEpoch.isFinite,
              (0...ClaudeStatusLineQuotaWindow.maximumAcceptedResetEpoch)
                .contains(resetEpoch)
        else {
            return nil
        }
        return ClaudeStatusLineQuotaWindow(
            usedPercentage: usedPercentage,
            resetAt: Date(timeIntervalSince1970: resetEpoch)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case usedPercentage = "used_percentage"
        case resetEpoch = "resets_at"
    }
}

private enum StrictJSONKeys {
    static func requireOnly(
        _ allowedKeys: [String],
        from decoder: any Decoder
    ) throws {
        let container = try decoder.container(
            keyedBy: DynamicCodingKey.self
        )
        let allowed = Set(allowedKeys)
        guard container.allKeys.allSatisfy({
            allowed.contains($0.stringValue)
        }) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Snapshot contains an unknown field."
                )
            )
        }
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}
