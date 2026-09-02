import Darwin
import Foundation

final class ClaudeStatusLineSettingsPOSIXStore {
    enum RecoveryCleanupPoint {
        case beforeBackupUnlink
        case beforeManifestUnlink
        case beforeMetadataDirectoryRemoval
    }

    struct Snapshot {
        let settings: Data?
        let settingsTooLarge: Bool
        let manifest: Data?
        let manifestTooLarge: Bool
        let backup: Data?
        let backupTooLarge: Bool
    }

    private static let appDirectoryName = "CodexQuotaMonitor"
    private static let metadataDirectoryName = "ClaudeStatusLineSettings"
    private static let settingsFileName = "settings.json"
    private static let manifestFileName = "manifest.json"
    private static let backupFileName = "settings.backup"

    private let configDirectoryURL: URL
    private let applicationSupportURL: URL
    private let configDirectory: ClaudeSettingsSecureDirectory
    private let applicationSupportDirectory: ClaudeSettingsSecureDirectory
    private let temporaryNameToken: () -> String
    private let recoveryCleanupHook: (RecoveryCleanupPoint) throws -> Void
    private var appDirectory: ClaudeSettingsSecureDirectory?
    private var metadataDirectory: ClaudeSettingsSecureDirectory?
    private var expectedRecovery: RecoveryState?

    private struct RecoveryState {
        let manifest: Data
        let backup: Data?
    }

    private struct CanonicalAnchors {
        let config: ClaudeSettingsSecureDirectory
        let applicationSupport: ClaudeSettingsSecureDirectory
        let app: ClaudeSettingsSecureDirectory?
        let metadata: ClaudeSettingsSecureDirectory?
    }

    init(
        location: ClaudeStatusLineSettingsLocation,
        applicationSupportURL: URL,
        temporaryNameToken: @escaping () -> String,
        recoveryCleanupHook: @escaping (
            RecoveryCleanupPoint
        ) throws -> Void = { _ in }
    ) throws {
        guard location.settingsURL.pathComponents
                == location.configDirectoryURL.pathComponents
                    + [Self.settingsFileName]
        else {
            throw ClaudeStatusLineSettingsInstallerError.unsafeLocation
        }
        configDirectoryURL = location.configDirectoryURL
        self.applicationSupportURL = applicationSupportURL
        configDirectory = try ClaudeSettingsSecureDirectory.openAbsolute(
            location.configDirectoryURL
        )
        applicationSupportDirectory = try ClaudeSettingsSecureDirectory
            .openAbsolute(applicationSupportURL)
        self.temporaryNameToken = temporaryNameToken
        self.recoveryCleanupHook = recoveryCleanupHook
        appDirectory = try applicationSupportDirectory.openChildIfPresent(
            named: Self.appDirectoryName,
            requireCurrentOwner: true
        )
        metadataDirectory = try appDirectory?.openChildIfPresent(
            named: Self.metadataDirectoryName,
            requireCurrentOwner: true
        )
    }

    func readSnapshot() throws -> Snapshot {
        let settings = try read(
            from: configDirectory,
            named: Self.settingsFileName,
            maximumBytes: ClaudeStatusLineSettingsPolicy
                .defaultMaximumSettingsBytes,
            requireCurrentOwner: true
        )
        let manifest: ClaudeSettingsBoundedRead
        let backup: ClaudeSettingsBoundedRead
        if let metadataDirectory {
            manifest = try read(
                from: metadataDirectory,
                named: Self.manifestFileName,
                maximumBytes: ClaudeStatusLineSettingsPolicy
                    .maximumManifestBytes,
                requireCurrentOwner: true
            )
            backup = try read(
                from: metadataDirectory,
                named: Self.backupFileName,
                maximumBytes: ClaudeStatusLineSettingsPolicy
                    .defaultMaximumSettingsBytes,
                requireCurrentOwner: true
            )
        } else {
            manifest = .missing
            backup = .missing
        }
        let snapshot = Snapshot(
            settings: settings.data,
            settingsTooLarge: settings.isTooLarge,
            manifest: manifest.data,
            manifestTooLarge: manifest.isTooLarge,
            backup: backup.data,
            backupTooLarge: backup.isTooLarge
        )
        expectedRecovery = snapshot.manifest.map {
            RecoveryState(manifest: $0, backup: snapshot.backup)
        }
        return snapshot
    }

    func ensureRecoveryMetadata(
        manifest: Data,
        backup: Data?
    ) throws {
        guard manifest.count <= ClaudeStatusLineSettingsPolicy
            .maximumManifestBytes,
              backup.map({
                  $0.count <= ClaudeStatusLineSettingsPolicy
                      .defaultMaximumSettingsBytes
              }) ?? true
        else {
            throw ClaudeStatusLineSettingsInstallerError.unsafeLocation
        }
        let directory = try ensureMetadataDirectory()
        try ensureExact(
            manifest,
            in: directory,
            named: Self.manifestFileName,
            maximumBytes: ClaudeStatusLineSettingsPolicy.maximumManifestBytes
        )
        if let backup {
            try ensureExact(
                backup,
                in: directory,
                named: Self.backupFileName,
                maximumBytes: ClaudeStatusLineSettingsPolicy
                    .defaultMaximumSettingsBytes
            )
        } else {
            try requireMissing(
                in: directory,
                named: Self.backupFileName
            )
        }
        expectedRecovery = RecoveryState(manifest: manifest, backup: backup)
    }

    func normalizeExistingRecoveryMetadata(
        manifest: Data,
        backup: Data?
    ) throws {
        try ensureRecoveryMetadata(manifest: manifest, backup: backup)
    }

    func replaceSettings(
        with data: Data,
        expected: Data?
    ) throws -> Bool {
        guard data.count <= ClaudeStatusLineSettingsPolicy
            .defaultMaximumSettingsBytes else {
            throw ClaudeStatusLineSettingsInstallerError.unsafeLocation
        }
        let anchors = try reopenCanonicalAnchors(
            requireRecovery: expectedRecovery != nil
        )
        try validateExpectedRecovery(in: anchors.metadata)
        return try atomicReplace(
            data,
            in: anchors.config,
            named: Self.settingsFileName,
            expected: expected,
            maximumBytes: ClaudeStatusLineSettingsPolicy
                .defaultMaximumSettingsBytes
        )
    }

    func deleteSettings(expected: Data?) throws -> Bool {
        let anchors = try reopenCanonicalAnchors(
            requireRecovery: expectedRecovery != nil
        )
        try validateExpectedRecovery(in: anchors.metadata)
        guard try fileMatches(
            expected,
            in: anchors.config,
            named: Self.settingsFileName,
            maximumBytes: ClaudeStatusLineSettingsPolicy
                .defaultMaximumSettingsBytes,
            requireCurrentOwner: true
        ) else {
            return false
        }
        guard expected != nil else { return true }
        let result = Self.settingsFileName.withCString {
            Darwin.unlinkat(anchors.config.descriptor, $0, 0)
        }
        guard result == 0 else {
            if errno == ENOENT { return false }
            throw Self.posixError()
        }
        try Self.synchronize(anchors.config.descriptor)
        return true
    }

    func cleanupRecoveryMetadata(
        expectedManifest: Data,
        expectedBackup: Data?
    ) throws -> Bool {
        var anchors = try reopenCanonicalAnchors(requireRecovery: true)
        guard let initialMetadata = anchors.metadata,
              try recoveryMatches(
                  manifest: expectedManifest,
                  backup: expectedBackup,
                  in: initialMetadata
              ) else {
            return false
        }

        if expectedBackup != nil {
            try recoveryCleanupHook(.beforeBackupUnlink)
            anchors = try reopenCanonicalAnchors(requireRecovery: true)
            guard let metadata = anchors.metadata,
                  try recoveryMatches(
                      manifest: expectedManifest,
                      backup: expectedBackup,
                      in: metadata
                  ) else {
                return false
            }
            try unlinkKnownFile(
                in: metadata,
                named: Self.backupFileName
            )
        }
        try recoveryCleanupHook(.beforeManifestUnlink)
        anchors = try reopenCanonicalAnchors(requireRecovery: true)
        guard let metadata = anchors.metadata,
              try recoveryMatches(
                  manifest: expectedManifest,
                  backup: nil,
                  in: metadata
              ) else {
            return false
        }
        try unlinkKnownFile(
            in: metadata,
            named: Self.manifestFileName
        )

        try recoveryCleanupHook(.beforeMetadataDirectoryRemoval)
        anchors = try reopenCanonicalAnchors(requireRecovery: true)
        guard let appDirectory = anchors.app,
              let finalMetadata = anchors.metadata,
              try recoveryMatches(
                  manifest: nil,
                  backup: nil,
                  in: finalMetadata
              ) else {
            return false
        }
        let removeResult = Self.metadataDirectoryName.withCString {
            Darwin.unlinkat(appDirectory.descriptor, $0, AT_REMOVEDIR)
        }
        if removeResult == 0 {
            try Self.synchronize(appDirectory.descriptor)
        } else {
            let code = errno
            guard code == ENOTEMPTY || code == EEXIST || code == ENOENT else {
                throw ClaudeStatusLineSettingsInstallerError
                    .fileOperationFailed(code: code)
            }
        }
        return true
    }

    private func ensureMetadataDirectory()
        throws -> ClaudeSettingsSecureDirectory {
        let anchors = try reopenCanonicalAnchors(requireRecovery: false)
        let app: ClaudeSettingsSecureDirectory
        if let canonicalApp = anchors.app {
            app = canonicalApp
        } else {
            app = try anchors.applicationSupport.openOrCreateChild(
                named: Self.appDirectoryName
            )
            appDirectory = app
        }
        try app.normalizeOwnedDirectoryPermissions()

        let metadata: ClaudeSettingsSecureDirectory
        if let canonicalMetadata = anchors.metadata {
            metadata = canonicalMetadata
        } else {
            metadata = try app.openOrCreateChild(
                named: Self.metadataDirectoryName
            )
            metadataDirectory = metadata
        }
        try metadata.normalizeOwnedDirectoryPermissions()
        return metadata
    }

    private func reopenCanonicalAnchors(
        requireRecovery: Bool
    ) throws -> CanonicalAnchors {
        let config = try ClaudeSettingsSecureDirectory.openAbsolute(
            configDirectoryURL
        )
        guard config.hasSameIdentity(as: configDirectory) else {
            throw ClaudeStatusLineSettingsInstallerError.unsafeLocation
        }
        let support = try ClaudeSettingsSecureDirectory.openAbsolute(
            applicationSupportURL
        )
        guard support.hasSameIdentity(as: applicationSupportDirectory) else {
            throw ClaudeStatusLineSettingsInstallerError.unsafeLocation
        }

        var canonicalApp: ClaudeSettingsSecureDirectory?
        if let appDirectory {
            guard let reopened = try support.openChildIfPresent(
                named: Self.appDirectoryName,
                requireCurrentOwner: true
            ), reopened.hasSameIdentity(as: appDirectory) else {
                throw ClaudeStatusLineSettingsInstallerError.unsafeLocation
            }
            canonicalApp = reopened
        }

        var canonicalMetadata: ClaudeSettingsSecureDirectory?
        if let metadataDirectory {
            guard let canonicalApp,
                  let reopened = try canonicalApp.openChildIfPresent(
                      named: Self.metadataDirectoryName,
                      requireCurrentOwner: true
                  ), reopened.hasSameIdentity(as: metadataDirectory)
            else {
                throw ClaudeStatusLineSettingsInstallerError.unsafeLocation
            }
            canonicalMetadata = reopened
        }
        if requireRecovery,
           (canonicalApp == nil || canonicalMetadata == nil) {
            throw ClaudeStatusLineSettingsInstallerError.unsafeLocation
        }
        return CanonicalAnchors(
            config: config,
            applicationSupport: support,
            app: canonicalApp,
            metadata: canonicalMetadata
        )
    }

    private func validateExpectedRecovery(
        in metadata: ClaudeSettingsSecureDirectory?
    ) throws {
        guard let expectedRecovery else { return }
        guard let metadata,
              try recoveryMatches(
                  manifest: expectedRecovery.manifest,
                  backup: expectedRecovery.backup,
                  in: metadata
              )
        else {
            throw ClaudeStatusLineSettingsInstallerError.unsafeLocation
        }
    }

    private func recoveryMatches(
        manifest: Data?,
        backup: Data?,
        in metadata: ClaudeSettingsSecureDirectory
    ) throws -> Bool {
        let manifestMatches = try fileMatches(
            manifest,
            in: metadata,
            named: Self.manifestFileName,
            maximumBytes: ClaudeStatusLineSettingsPolicy.maximumManifestBytes,
            requireCurrentOwner: true
        )
        let backupMatches = try fileMatches(
            backup,
            in: metadata,
            named: Self.backupFileName,
            maximumBytes: ClaudeStatusLineSettingsPolicy
                .defaultMaximumSettingsBytes,
            requireCurrentOwner: true
        )
        return manifestMatches && backupMatches
    }

    private func ensureExact(
        _ expected: Data,
        in directory: ClaudeSettingsSecureDirectory,
        named name: String,
        maximumBytes: Int
    ) throws {
        switch try read(
            from: directory,
            named: name,
            maximumBytes: maximumBytes,
            requireCurrentOwner: true
        ) {
        case let .data(actual):
            guard actual == expected else {
                throw ClaudeStatusLineSettingsInstallerError.unsafeLocation
            }
            try normalizeOwnedFile(
                expected: expected,
                in: directory,
                named: name,
                maximumBytes: maximumBytes
            )
        case .tooLarge:
            throw ClaudeStatusLineSettingsInstallerError.unsafeLocation
        case .missing:
            try atomicCreate(
                expected,
                in: directory,
                named: name,
                maximumBytes: maximumBytes
            )
        }
    }

    private func atomicCreate(
        _ data: Data,
        in directory: ClaudeSettingsSecureDirectory,
        named name: String,
        maximumBytes: Int
    ) throws {
        let temporaryName = try makeTemporaryName(for: name)
        let descriptor = try createTemporaryFile(
            in: directory,
            named: temporaryName
        )
        var descriptorIsOpen = true
        var shouldUnlink = true
        defer {
            if descriptorIsOpen { Darwin.close(descriptor) }
            if shouldUnlink {
                _ = temporaryName.withCString {
                    Darwin.unlinkat(directory.descriptor, $0, 0)
                }
            }
        }
        try Self.writeAll(data, to: descriptor)
        try Self.synchronize(descriptor)
        let closeResult = Darwin.close(descriptor)
        descriptorIsOpen = false
        guard closeResult == 0 else {
            throw Self.posixError()
        }

        let flags = UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)
        let result = temporaryName.withCString { temporaryPath in
            name.withCString { destinationPath in
                Darwin.renameatx_np(
                    directory.descriptor,
                    temporaryPath,
                    directory.descriptor,
                    destinationPath,
                    flags
                )
            }
        }
        if result != 0 {
            let code = errno
            if code == EEXIST {
                guard try fileMatches(
                   data,
                   in: directory,
                   named: name,
                   maximumBytes: maximumBytes,
                   requireCurrentOwner: true
                ) else {
                    throw ClaudeStatusLineSettingsInstallerError.unsafeLocation
                }
                return try normalizeOwnedFile(
                    expected: data,
                    in: directory,
                    named: name,
                    maximumBytes: maximumBytes
                )
            }
            throw ClaudeStatusLineSettingsInstallerError
                .fileOperationFailed(code: code)
        }
        shouldUnlink = false
        try Self.synchronize(directory.descriptor)
        try normalizeOwnedFile(
            expected: data,
            in: directory,
            named: name,
            maximumBytes: maximumBytes
        )
    }

    private func atomicReplace(
        _ data: Data,
        in directory: ClaudeSettingsSecureDirectory,
        named name: String,
        expected: Data?,
        maximumBytes: Int
    ) throws -> Bool {
        let temporaryName = try makeTemporaryName(for: name)
        let descriptor = try createTemporaryFile(
            in: directory,
            named: temporaryName
        )
        var descriptorIsOpen = true
        var shouldUnlink = true
        defer {
            if descriptorIsOpen { Darwin.close(descriptor) }
            if shouldUnlink {
                _ = temporaryName.withCString {
                    Darwin.unlinkat(directory.descriptor, $0, 0)
                }
            }
        }
        try Self.writeAll(data, to: descriptor)
        try Self.synchronize(descriptor)
        guard Darwin.close(descriptor) == 0 else {
            descriptorIsOpen = false
            throw Self.posixError()
        }
        descriptorIsOpen = false

        guard try fileMatches(
            expected,
            in: directory,
            named: name,
            maximumBytes: maximumBytes,
            requireCurrentOwner: true
        ) else {
            return false
        }
        // macOS has no content compare-and-swap rename. Keeping the anchored
        // descriptor open limits the residual race to this recheck/rename gap.
        var flags = UInt32(RENAME_NOFOLLOW_ANY)
        if expected == nil { flags |= UInt32(RENAME_EXCL) }
        let result = temporaryName.withCString { temporaryPath in
            name.withCString { destinationPath in
                Darwin.renameatx_np(
                    directory.descriptor,
                    temporaryPath,
                    directory.descriptor,
                    destinationPath,
                    flags
                )
            }
        }
        if result != 0 {
            let code = errno
            if code == EEXIST { return false }
            throw ClaudeStatusLineSettingsInstallerError
                .fileOperationFailed(code: code)
        }
        shouldUnlink = false
        try Self.synchronize(directory.descriptor)
        try normalizeOwnedFile(
            expected: data,
            in: directory,
            named: name,
            maximumBytes: maximumBytes
        )
        return true
    }

    private func createTemporaryFile(
        in directory: ClaudeSettingsSecureDirectory,
        named name: String
    ) throws -> Int32 {
        let descriptor = name.withCString {
            pointer in
            Self.retryOnEINTR {
                Darwin.openat(
                    directory.descriptor,
                    pointer,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    mode_t(0o600)
                )
            }
        }
        guard descriptor >= 0 else {
            let code = errno
            if code == EEXIST {
                throw ClaudeStatusLineSettingsInstallerError.unsafeLocation
            }
            throw Self.pathOperationError(code: code)
        }
        guard Self.retryOnEINTR({
            Darwin.fchmod(descriptor, mode_t(0o600))
        }) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw ClaudeStatusLineSettingsInstallerError
                .fileOperationFailed(code: code)
        }
        return descriptor
    }

    private func makeTemporaryName(for destination: String) throws -> String {
        let token = temporaryNameToken()
        guard Self.isSafeComponent(token) else {
            throw ClaudeStatusLineSettingsInstallerError.unsafeLocation
        }
        return ".\(destination).\(token).tmp"
    }

    private func normalizeOwnedFile(
        expected: Data,
        in directory: ClaudeSettingsSecureDirectory,
        named name: String,
        maximumBytes: Int
    ) throws {
        let descriptor = name.withCString {
            pointer in
            Self.retryOnEINTR {
                Darwin.openat(
                    directory.descriptor,
                    pointer,
                    O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                )
            }
        }
        guard descriptor >= 0 else {
            throw Self.pathOperationError(code: errno)
        }
        defer { Darwin.close(descriptor) }
        let actual = try Self.readDescriptor(
            descriptor,
            maximumBytes: maximumBytes,
            requireCurrentOwner: true
        )
        guard case let .data(data) = actual, data == expected else {
            throw ClaudeStatusLineSettingsInstallerError.unsafeLocation
        }
        guard Self.retryOnEINTR({
            Darwin.fchmod(descriptor, mode_t(0o600))
        }) == 0 else {
            throw Self.posixError()
        }
        var fileInfo = stat()
        guard Self.retryOnEINTR({
            Darwin.fstat(descriptor, &fileInfo)
        }) == 0 else {
            throw Self.posixError()
        }
        guard Self.isRegular(fileInfo),
              fileInfo.st_uid == geteuid(),
              fileInfo.st_mode & mode_t(0o777) == mode_t(0o600)
        else {
            throw ClaudeStatusLineSettingsInstallerError.unsafeLocation
        }
        try Self.synchronize(descriptor)
    }

    private func requireMissing(
        in directory: ClaudeSettingsSecureDirectory,
        named name: String
    ) throws {
        var fileInfo = stat()
        let result = name.withCString {
            pointer in
            Self.retryOnEINTR {
                Darwin.fstatat(
                    directory.descriptor,
                    pointer,
                    &fileInfo,
                    AT_SYMLINK_NOFOLLOW
                )
            }
        }
        if result == 0 {
            throw ClaudeStatusLineSettingsInstallerError.unsafeLocation
        }
        let code = errno
        guard code == ENOENT else {
            throw Self.pathOperationError(code: code)
        }
    }

    private func unlinkKnownFile(
        in directory: ClaudeSettingsSecureDirectory,
        named name: String
    ) throws {
        let result = name.withCString {
            Darwin.unlinkat(directory.descriptor, $0, 0)
        }
        guard result == 0 else { throw Self.posixError() }
        try Self.synchronize(directory.descriptor)
    }

    private func fileMatches(
        _ expected: Data?,
        in directory: ClaudeSettingsSecureDirectory,
        named name: String,
        maximumBytes: Int,
        requireCurrentOwner: Bool
    ) throws -> Bool {
        switch try read(
            from: directory,
            named: name,
            maximumBytes: maximumBytes,
            requireCurrentOwner: requireCurrentOwner
        ) {
        case .missing:
            return expected == nil
        case let .data(actual):
            return actual == expected
        case .tooLarge:
            return false
        }
    }

    private func read(
        from directory: ClaudeSettingsSecureDirectory,
        named name: String,
        maximumBytes: Int,
        requireCurrentOwner: Bool
    ) throws -> ClaudeSettingsBoundedRead {
        var fileInfo = stat()
        let inspectResult = name.withCString {
            pointer in
            Self.retryOnEINTR {
                Darwin.fstatat(
                    directory.descriptor,
                    pointer,
                    &fileInfo,
                    AT_SYMLINK_NOFOLLOW
                )
            }
        }
        if inspectResult != 0 {
            let code = errno
            guard code == ENOENT else {
                throw Self.pathOperationError(code: code)
            }
            return .missing
        }
        guard Self.isRegular(fileInfo) else {
            throw ClaudeStatusLineSettingsInstallerError.unsafeLocation
        }
        let descriptor = name.withCString {
            pointer in
            Self.retryOnEINTR {
                Darwin.openat(
                    directory.descriptor,
                    pointer,
                    O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                )
            }
        }
        guard descriptor >= 0 else {
            throw Self.pathOperationError(code: errno)
        }
        defer { Darwin.close(descriptor) }
        return try Self.readDescriptor(
            descriptor,
            maximumBytes: maximumBytes,
            requireCurrentOwner: requireCurrentOwner
        )
    }

    private static func readDescriptor(
        _ descriptor: Int32,
        maximumBytes: Int,
        requireCurrentOwner: Bool
    ) throws -> ClaudeSettingsBoundedRead {
        var fileInfo = stat()
        guard retryOnEINTR({
            Darwin.fstat(descriptor, &fileInfo)
        }) == 0 else {
            throw posixError()
        }
        guard isRegular(fileInfo),
              !requireCurrentOwner || fileInfo.st_uid == geteuid()
        else {
            throw ClaudeStatusLineSettingsInstallerError.unsafeLocation
        }
        guard fileInfo.st_size >= 0 else {
            throw ClaudeStatusLineSettingsInstallerError.unsafeLocation
        }
        if fileInfo.st_size > maximumBytes { return .tooLarge }

        var data = Data()
        data.reserveCapacity(min(Int(fileInfo.st_size), maximumBytes))
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while data.count <= maximumBytes {
            let allowed = min(buffer.count, maximumBytes + 1 - data.count)
            let count: Int = buffer.withUnsafeMutableBytes { bytes in
                guard let address = bytes.baseAddress else { return 0 }
                while true {
                    let result = Darwin.read(descriptor, address, allowed)
                    if result < 0, errno == EINTR { continue }
                    return result
                }
            }
            guard count >= 0 else { throw posixError() }
            if count == 0 { return .data(data) }
            data.append(contentsOf: buffer.prefix(count))
            if data.count > maximumBytes { return .tooLarge }
        }
        return .tooLarge
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
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw posixError() }
                offset += count
            }
        }
    }

    fileprivate static func synchronize(_ descriptor: Int32) throws {
        while Darwin.fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw posixError()
        }
    }

    fileprivate static func retryOnEINTR(
        _ operation: () -> Int32
    ) -> Int32 {
        while true {
            let result = operation()
            if result < 0, errno == EINTR { continue }
            return result
        }
    }

    fileprivate static func pathOperationError(
        code: Int32
    ) -> ClaudeStatusLineSettingsInstallerError {
        switch code {
        case ELOOP, ENOTDIR, ENOENT:
            .unsafeLocation
        default:
            .fileOperationFailed(code: code)
        }
    }

    fileprivate static func isSafeComponent(_ component: String) -> Bool {
        !component.isEmpty
            && component != "."
            && component != ".."
            && !component.contains("/")
            && !component.utf8.contains(0)
    }

    fileprivate static func isDirectory(_ fileInfo: stat) -> Bool {
        fileInfo.st_mode & S_IFMT == S_IFDIR
    }

    private static func isRegular(_ fileInfo: stat) -> Bool {
        fileInfo.st_mode & S_IFMT == S_IFREG
    }

    fileprivate static func posixError(
        code: Int32 = errno
    ) -> ClaudeStatusLineSettingsInstallerError {
        .fileOperationFailed(code: code)
    }
}

private enum ClaudeSettingsBoundedRead {
    case missing
    case data(Data)
    case tooLarge

    var data: Data? {
        guard case let .data(data) = self else { return nil }
        return data
    }

    var isTooLarge: Bool {
        if case .tooLarge = self { return true }
        return false
    }
}

private final class ClaudeSettingsSecureDirectory {
    let descriptor: Int32
    private let identity: ClaudeSettingsDirectoryIdentity

    init(
        descriptor: Int32,
        identity: ClaudeSettingsDirectoryIdentity
    ) {
        self.descriptor = descriptor
        self.identity = identity
    }

    deinit {
        Darwin.close(descriptor)
    }

    static func openAbsolute(_ url: URL) throws -> ClaudeSettingsSecureDirectory {
        let components = url.pathComponents
        guard url.isFileURL,
              url.host == nil,
              url.query == nil,
              url.fragment == nil,
              components.first == "/",
              components.count >= 2,
              components.dropFirst().allSatisfy(
                  ClaudeStatusLineSettingsPOSIXStore.isSafeComponent
              )
        else {
            throw ClaudeStatusLineSettingsInstallerError.unsafeLocation
        }

        var descriptor = ClaudeStatusLineSettingsPOSIXStore.retryOnEINTR {
            Darwin.open(
                "/",
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw ClaudeStatusLineSettingsPOSIXStore.posixError()
        }
        for component in components.dropFirst() {
            let nextDescriptor = component.withCString {
                pointer in
                ClaudeStatusLineSettingsPOSIXStore.retryOnEINTR {
                    Darwin.openat(
                        descriptor,
                        pointer,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
            }
            if nextDescriptor < 0 {
                let code = errno
                Darwin.close(descriptor)
                throw ClaudeStatusLineSettingsPOSIXStore.pathOperationError(
                    code: code
                )
            }
            Darwin.close(descriptor)
            descriptor = nextDescriptor
        }
        var fileInfo = stat()
        let statResult = ClaudeStatusLineSettingsPOSIXStore.retryOnEINTR {
            Darwin.fstat(descriptor, &fileInfo)
        }
        if statResult != 0 {
            let code = errno
            Darwin.close(descriptor)
            throw ClaudeStatusLineSettingsInstallerError
                .fileOperationFailed(code: code)
        }
        guard ClaudeStatusLineSettingsPOSIXStore.isDirectory(fileInfo) else {
            Darwin.close(descriptor)
            throw ClaudeStatusLineSettingsInstallerError.unsafeLocation
        }
        return ClaudeSettingsSecureDirectory(
            descriptor: descriptor,
            identity: ClaudeSettingsDirectoryIdentity(fileInfo)
        )
    }

    func openChildIfPresent(
        named name: String,
        requireCurrentOwner: Bool
    ) throws -> ClaudeSettingsSecureDirectory? {
        guard ClaudeStatusLineSettingsPOSIXStore.isSafeComponent(name) else {
            throw ClaudeStatusLineSettingsInstallerError.unsafeLocation
        }
        var fileInfo = stat()
        let inspectResult = name.withCString {
            pointer in
            ClaudeStatusLineSettingsPOSIXStore.retryOnEINTR {
                Darwin.fstatat(
                    descriptor,
                    pointer,
                    &fileInfo,
                    AT_SYMLINK_NOFOLLOW
                )
            }
        }
        if inspectResult != 0 {
            let code = errno
            guard code == ENOENT else {
                throw ClaudeStatusLineSettingsPOSIXStore.pathOperationError(
                    code: code
                )
            }
            return nil
        }
        guard ClaudeStatusLineSettingsPOSIXStore.isDirectory(fileInfo) else {
            throw ClaudeStatusLineSettingsInstallerError.unsafeLocation
        }
        let childDescriptor = name.withCString {
            pointer in
            ClaudeStatusLineSettingsPOSIXStore.retryOnEINTR {
                Darwin.openat(
                    descriptor,
                    pointer,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
        }
        guard childDescriptor >= 0 else {
            throw ClaudeStatusLineSettingsPOSIXStore.pathOperationError(
                code: errno
            )
        }
        var openedInfo = stat()
        let childStatResult = ClaudeStatusLineSettingsPOSIXStore.retryOnEINTR {
            Darwin.fstat(childDescriptor, &openedInfo)
        }
        if childStatResult != 0 {
            let code = errno
            Darwin.close(childDescriptor)
            throw ClaudeStatusLineSettingsInstallerError
                .fileOperationFailed(code: code)
        }
        guard ClaudeStatusLineSettingsPOSIXStore.isDirectory(openedInfo),
              !requireCurrentOwner || openedInfo.st_uid == geteuid()
        else {
            Darwin.close(childDescriptor)
            throw ClaudeStatusLineSettingsInstallerError.unsafeLocation
        }
        return ClaudeSettingsSecureDirectory(
            descriptor: childDescriptor,
            identity: ClaudeSettingsDirectoryIdentity(openedInfo)
        )
    }

    func openOrCreateChild(
        named name: String
    ) throws -> ClaudeSettingsSecureDirectory {
        if let existing = try openChildIfPresent(
            named: name,
            requireCurrentOwner: true
        ) {
            return existing
        }
        let createResult = name.withCString {
            pointer in
            ClaudeStatusLineSettingsPOSIXStore.retryOnEINTR {
                Darwin.mkdirat(descriptor, pointer, mode_t(0o700))
            }
        }
        if createResult != 0 {
            let code = errno
            guard code == EEXIST else {
                throw ClaudeStatusLineSettingsPOSIXStore.pathOperationError(
                    code: code
                )
            }
        }
        if createResult == 0 {
            try ClaudeStatusLineSettingsPOSIXStore.synchronize(descriptor)
        }
        guard let child = try openChildIfPresent(
            named: name,
            requireCurrentOwner: true
        ) else {
            throw ClaudeStatusLineSettingsInstallerError.unsafeLocation
        }
        try child.normalizeOwnedDirectoryPermissions()
        return child
    }

    func normalizeOwnedDirectoryPermissions() throws {
        var fileInfo = stat()
        guard ClaudeStatusLineSettingsPOSIXStore.retryOnEINTR({
            Darwin.fstat(descriptor, &fileInfo)
        }) == 0 else {
            throw ClaudeStatusLineSettingsPOSIXStore.posixError()
        }
        guard ClaudeStatusLineSettingsPOSIXStore.isDirectory(fileInfo),
              fileInfo.st_uid == geteuid()
        else {
            throw ClaudeStatusLineSettingsInstallerError.unsafeLocation
        }
        guard ClaudeStatusLineSettingsPOSIXStore.retryOnEINTR({
            Darwin.fchmod(descriptor, mode_t(0o700))
        }) == 0 else {
            throw ClaudeStatusLineSettingsPOSIXStore.posixError()
        }
        guard ClaudeStatusLineSettingsPOSIXStore.retryOnEINTR({
            Darwin.fstat(descriptor, &fileInfo)
        }) == 0 else {
            throw ClaudeStatusLineSettingsPOSIXStore.posixError()
        }
        guard ClaudeStatusLineSettingsPOSIXStore.isDirectory(fileInfo),
              fileInfo.st_uid == geteuid(),
              fileInfo.st_mode & mode_t(0o777) == mode_t(0o700)
        else {
            throw ClaudeStatusLineSettingsInstallerError.unsafeLocation
        }
        try ClaudeStatusLineSettingsPOSIXStore.synchronize(descriptor)
    }

    func hasSameIdentity(
        as other: ClaudeSettingsSecureDirectory
    ) -> Bool {
        identity == other.identity
    }
}

private struct ClaudeSettingsDirectoryIdentity: Equatable {
    let device: dev_t
    let inode: ino_t

    init(_ fileInfo: stat) {
        device = fileInfo.st_dev
        inode = fileInfo.st_ino
    }
}
