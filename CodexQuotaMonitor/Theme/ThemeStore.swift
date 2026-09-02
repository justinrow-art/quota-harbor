import CryptoKit
import Darwin
import Foundation

enum ThemeSelection: Equatable, Hashable, Sendable {
    case builtIn(BuiltInThemeID)
    case custom(UUID)
}

extension ThemeSelection: Codable {
    private enum CodingKeys: String, CodingKey { case kind, id }
    private enum Kind: String, Codable { case builtIn, custom }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .builtIn:
            self = .builtIn(
                try container.decode(BuiltInThemeID.self, forKey: .id)
            )
        case .custom:
            self = .custom(
                try container.decode(UUID.self, forKey: .id)
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .builtIn(id):
            try container.encode(Kind.builtIn, forKey: .kind)
            try container.encode(id, forKey: .id)
        case let .custom(id):
            try container.encode(Kind.custom, forKey: .kind)
            try container.encode(id, forKey: .id)
        }
    }
}

struct ThemeStoreSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let builtIns: [BuiltInThemeID]
    var customThemes: [ThemeDocument]
    var activeSelection: ThemeSelection

    static let defaults = ThemeStoreSnapshot(
        schemaVersion: currentSchemaVersion,
        builtIns: BuiltInThemeID.allCases,
        customThemes: [],
        activeSelection: .builtIn(.morandi)
    )
}

/// Sanitized PNG bytes held outside the live store until the user saves.
struct PendingSanitizedThemeRaster: Equatable, Sendable {
    let reference: SanitizedRasterReference
    let pngData: Data

    var verifiedPNGData: Data? {
        guard !pngData.isEmpty,
              pngData.count <= ThemeRasterLimits.maximumInputBytes
        else {
            return nil
        }
        let digest = SHA256.hash(data: pngData)
            .map { String(format: "%02x", $0) }
            .joined()
        guard reference.sha256 == digest,
              reference.relativeIdentifier == digest + ".png"
        else {
            return nil
        }
        return pngData
    }
}

enum ThemeStoreError: Error, Equatable, Sendable {
    case builtInImmutable
    case themeNotFound
    case activeThemeCannotBeDeleted
    case duplicateThemeID
    case operationInProgress
    case invalidTheme
    case persistenceFailed
    case importFailed(ThemeImportExportError)
}

protocol ThemeStorePersisting: AnyObject {
    var rootDirectory: URL { get }
    func loadManifest() throws -> Data?
    func beginTransaction() throws -> URL
    func writeManifest(_ data: Data, in transaction: URL) throws
    func stageRaster(
        _ raster: PendingSanitizedThemeRaster,
        in transaction: URL
    ) throws
    func commit(_ transaction: URL) throws
    func rollback(_ transaction: URL)
    func rasterData(for reference: SanitizedRasterReference) throws -> Data
    func pruneRasters(
        in transaction: URL,
        keeping references: Set<String>
    ) throws
}

@MainActor
final class ThemeStore {
    private(set) var snapshot: ThemeStoreSnapshot

    private let persistence: any ThemeStorePersisting
    private let importExportService: ThemeImportExportService
    private let makeUUID: () -> UUID
    private var operationInProgress = false

    init(
        persistence: any ThemeStorePersisting = ThemeStoreDiskPersistence(),
        importExportService: ThemeImportExportService = ThemeImportExportService(),
        makeUUID: @escaping () -> UUID = UUID.init
    ) throws {
        self.persistence = persistence
        self.importExportService = importExportService
        self.makeUUID = makeUUID
        if let data = try persistence.loadManifest() {
            do {
                snapshot = try Self.decodeSnapshot(data)
                try Self.validateSnapshot(snapshot, persistence: persistence)
            } catch {
                throw ThemeStoreError.persistenceFailed
            }
        } else {
            snapshot = .defaults
        }
    }

    func document(for selection: ThemeSelection) -> ThemeDocument? {
        switch selection {
        case let .builtIn(id):
            BuiltInThemes.all.first(where: { $0.id == id })?.document
        case let .custom(id):
            snapshot.customThemes.first(where: { $0.id == id })
        }
    }

    func selectBuiltIn(_ id: BuiltInThemeID) throws {
        try ensureIdle()
        var candidate = snapshot
        candidate.activeSelection = .builtIn(id)
        try commit(candidate)
    }

    func duplicateBuiltIn(
        _ id: BuiltInThemeID,
        named name: String
    ) throws -> ThemeDocument {
        try ensureIdle()
        guard let source = document(for: .builtIn(id)) else {
            throw ThemeStoreError.themeNotFound
        }
        let duplicate = ThemeDocument(
            schemaVersion: ThemeDocument.currentSchemaVersion,
            id: makeUUID(),
            name: name,
            appearances: source.appearances,
            geometry: source.geometry,
            ornamentOpacity: source.ornamentOpacity,
            rasterReference: source.rasterReference
        )
        try validateCustom(duplicate)
        var candidate = snapshot
        candidate.customThemes.append(duplicate)
        try commit(candidate)
        return duplicate
    }

    func saveCustom(
        _ document: ThemeDocument,
        activate: Bool
    ) throws {
        try saveCustom(
            document,
            activate: activate,
            pendingRaster: nil
        )
    }

    func saveCustom(
        _ document: ThemeDocument,
        activate: Bool,
        pendingRaster: PendingSanitizedThemeRaster?
    ) throws {
        try ensureIdle()
        try validateCustom(document, pendingRaster: pendingRaster)
        var candidate = snapshot
        if let index = candidate.customThemes.firstIndex(where: {
            $0.id == document.id
        }) {
            candidate.customThemes[index] = document
        } else {
            candidate.customThemes.append(document)
        }
        if activate {
            candidate.activeSelection = .custom(document.id)
        }
        guard let pendingRaster else {
            try commit(candidate)
            return
        }

        let transaction: URL
        do {
            transaction = try persistence.beginTransaction()
        } catch {
            throw ThemeStoreError.persistenceFailed
        }
        do {
            try persistence.stageRaster(
                pendingRaster,
                in: transaction
            )
        } catch {
            persistence.rollback(transaction)
            throw ThemeStoreError.persistenceFailed
        }
        try commit(candidate, transaction: transaction)
    }

    func activateCustom(_ id: UUID) throws {
        try ensureIdle()
        guard snapshot.customThemes.contains(where: { $0.id == id }) else {
            throw ThemeStoreError.themeNotFound
        }
        var candidate = snapshot
        candidate.activeSelection = .custom(id)
        try commit(candidate)
    }

    func reset() throws {
        try ensureIdle()
        var candidate = snapshot
        candidate.activeSelection = .builtIn(.morandi)
        try commit(candidate)
    }

    func deleteCustom(_ id: UUID) throws {
        try ensureIdle()
        guard snapshot.activeSelection != .custom(id) else {
            throw ThemeStoreError.activeThemeCannotBeDeleted
        }
        guard let index = snapshot.customThemes.firstIndex(where: {
            $0.id == id
        }) else {
            throw ThemeStoreError.themeNotFound
        }
        var candidate = snapshot
        candidate.customThemes.remove(at: index)
        try commit(candidate)
    }

    func importTheme(_ data: Data) async throws -> UUID {
        try ensureIdle()
        operationInProgress = true
        defer { operationInProgress = false }

        let transaction: URL
        do {
            transaction = try persistence.beginTransaction()
        } catch {
            throw ThemeStoreError.persistenceFailed
        }
        var committed = false
        defer {
            if !committed { persistence.rollback(transaction) }
        }

        let prepared: PreparedThemeImport
        do {
            prepared = try await importExportService.prepareImport(
                data,
                stagingDirectory: transaction
            )
        } catch let error as ThemeImportExportError {
            throw ThemeStoreError.importFailed(error)
        } catch {
            throw ThemeStoreError.importFailed(.invalidDocument)
        }
        guard !Self.builtInDocumentIDs.contains(prepared.document.id) else {
            throw ThemeStoreError.builtInImmutable
        }
        guard !snapshot.customThemes.contains(where: {
            $0.id == prepared.document.id
        }) else {
            throw ThemeStoreError.duplicateThemeID
        }

        var candidate = snapshot
        candidate.customThemes.append(prepared.document)
        candidate.activeSelection = .custom(prepared.document.id)
        do {
            try commit(candidate, transaction: transaction)
            committed = true
            return prepared.document.id
        } catch let error as ThemeStoreError {
            throw error
        } catch {
            throw ThemeStoreError.persistenceFailed
        }
    }

    func exportTheme(
        _ selection: ThemeSelection,
        includeRaster: Bool
    ) throws -> Data {
        try ensureIdle()
        guard let document = document(for: selection) else {
            throw ThemeStoreError.themeNotFound
        }
        let raster: Data?
        if includeRaster, let reference = document.rasterReference {
            do {
                raster = try persistence.rasterData(for: reference)
            } catch {
                throw ThemeStoreError.persistenceFailed
            }
        } else {
            raster = nil
        }
        do {
            return try importExportService.exportTheme(
                document,
                rasterPNG: raster,
                includeRaster: includeRaster
            )
        } catch let error as ThemeImportExportError {
            throw ThemeStoreError.importFailed(error)
        }
    }

    func rasterData(
        for reference: SanitizedRasterReference
    ) throws -> Data {
        do {
            return try persistence.rasterData(for: reference)
        } catch {
            throw ThemeStoreError.persistenceFailed
        }
    }

    private func ensureIdle() throws {
        guard !operationInProgress else {
            throw ThemeStoreError.operationInProgress
        }
    }

    private func validateCustom(_ document: ThemeDocument) throws {
        try validateCustom(document, pendingRaster: nil)
    }

    private func validateCustom(
        _ document: ThemeDocument,
        pendingRaster: PendingSanitizedThemeRaster?
    ) throws {
        guard !Self.builtInDocumentIDs.contains(document.id) else {
            throw ThemeStoreError.builtInImmutable
        }
        do {
            _ = try importExportService.exportTheme(
                document,
                rasterPNG: nil,
                includeRaster: false
            )
            if let pendingRaster {
                guard document.rasterReference == pendingRaster.reference else {
                    throw ThemeStoreError.invalidTheme
                }
                try Self.validatePendingRaster(pendingRaster)
            } else {
                if let reference = document.rasterReference {
                    _ = try persistence.rasterData(for: reference)
                }
            }
        } catch {
            throw ThemeStoreError.invalidTheme
        }
    }

    private static func validatePendingRaster(
        _ raster: PendingSanitizedThemeRaster
    ) throws {
        guard raster.verifiedPNGData != nil else {
            throw ThemeStoreError.invalidTheme
        }
    }

    private func commit(
        _ candidate: ThemeStoreSnapshot,
        transaction existingTransaction: URL? = nil
    ) throws {
        try Self.validateSnapshot(candidate, persistence: nil)
        let transaction: URL
        do {
            transaction = try existingTransaction
                ?? persistence.beginTransaction()
        } catch {
            throw ThemeStoreError.persistenceFailed
        }
        var committed = false
        defer {
            if !committed { persistence.rollback(transaction) }
        }
        do {
            try persistence.writeManifest(
                Self.encodeSnapshot(candidate),
                in: transaction
            )
            let references = Set(
                candidate.customThemes.compactMap {
                    $0.rasterReference?.relativeIdentifier
                }
            )
            try persistence.pruneRasters(
                in: transaction,
                keeping: references
            )
            try persistence.commit(transaction)
            snapshot = candidate
            committed = true
        } catch let error as ThemeStoreError {
            throw error
        } catch {
            throw ThemeStoreError.persistenceFailed
        }
    }

    private static let builtInDocumentIDs = Set(
        BuiltInThemes.all.map(\.document.id)
    )

    private static func encodeSnapshot(
        _ snapshot: ThemeStoreSnapshot
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(snapshot)
    }

    private static func decodeSnapshot(_ data: Data) throws
        -> ThemeStoreSnapshot
    {
        try JSONDecoder().decode(ThemeStoreSnapshot.self, from: data)
    }

    private static func validateSnapshot(
        _ snapshot: ThemeStoreSnapshot,
        persistence: (any ThemeStorePersisting)?
    ) throws {
        guard snapshot.schemaVersion == ThemeStoreSnapshot.currentSchemaVersion,
              snapshot.builtIns == BuiltInThemeID.allCases,
              Set(snapshot.customThemes.map(\.id)).count
                == snapshot.customThemes.count,
              snapshot.customThemes.allSatisfy({
                  !builtInDocumentIDs.contains($0.id)
              })
        else {
            throw ThemeStoreError.invalidTheme
        }
        switch snapshot.activeSelection {
        case let .builtIn(id):
            guard BuiltInThemeID.allCases.contains(id) else {
                throw ThemeStoreError.invalidTheme
            }
        case let .custom(id):
            guard snapshot.customThemes.contains(where: { $0.id == id })
            else {
                throw ThemeStoreError.invalidTheme
            }
        }
        let service = ThemeImportExportService()
        for document in snapshot.customThemes {
            do {
                _ = try service.exportTheme(
                    document,
                    rasterPNG: nil,
                    includeRaster: false
                )
                if let reference = document.rasterReference,
                   let persistence
                {
                    _ = try persistence.rasterData(for: reference)
                }
            } catch {
                throw ThemeStoreError.invalidTheme
            }
        }
    }
}

final class ThemeStoreDiskPersistence: ThemeStorePersisting {
    let rootDirectory: URL
    private let fileManager: FileManager
    private let liveDirectoryName = "Current"

    init(
        rootDirectory: URL = ThemeRasterProcessor
            .defaultAppThemeDirectory()
            .appendingPathComponent("Store", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.fileManager = fileManager
    }

    func loadManifest() throws -> Data? {
        let live = liveDirectory
        guard fileManager.fileExists(atPath: live.path) else { return nil }
        try requireSafeDirectory(live)
        let manifest = live.appendingPathComponent("manifest.json")
        guard fileManager.fileExists(atPath: manifest.path) else {
            throw ThemeStoreDiskError.invalidStore
        }
        try requireRegularFile(manifest)
        return try Data(contentsOf: manifest)
    }

    func beginTransaction() throws -> URL {
        try ensureRootDirectory()
        let transaction = rootDirectory.appendingPathComponent(
            ".staging-\(UUID().uuidString)",
            isDirectory: true
        )
        if fileManager.fileExists(atPath: liveDirectory.path) {
            try requireSafeDirectory(liveDirectory)
            try fileManager.copyItem(at: liveDirectory, to: transaction)
        } else {
            try fileManager.createDirectory(
                at: transaction,
                withIntermediateDirectories: false
            )
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: transaction.path
        )
        let rasters = transaction.appendingPathComponent(
            "Rasters",
            isDirectory: true
        )
        if !fileManager.fileExists(atPath: rasters.path) {
            try fileManager.createDirectory(
                at: rasters,
                withIntermediateDirectories: false
            )
        }
        try requireSafeDirectory(transaction)
        try requireSafeDirectory(rasters)
        return transaction
    }

    func writeManifest(_ data: Data, in transaction: URL) throws {
        try requireOwnedTransaction(transaction)
        try data.write(
            to: transaction.appendingPathComponent("manifest.json"),
            options: .atomic
        )
    }

    func stageRaster(
        _ raster: PendingSanitizedThemeRaster,
        in transaction: URL
    ) throws {
        try requireOwnedTransaction(transaction)
        try validateReference(raster.reference)
        guard sha256(raster.pngData) == raster.reference.sha256 else {
            throw ThemeStoreDiskError.invalidStore
        }
        let rasterDirectory = transaction.appendingPathComponent(
            "Rasters",
            isDirectory: true
        )
        try requireSafeDirectory(rasterDirectory)
        let destination = rasterDirectory.appendingPathComponent(
            raster.reference.relativeIdentifier,
            isDirectory: false
        )
        if fileManager.fileExists(atPath: destination.path) {
            try requireRegularFile(destination)
            guard try Data(contentsOf: destination) == raster.pngData else {
                throw ThemeStoreDiskError.invalidStore
            }
            return
        }
        try raster.pngData.write(to: destination, options: .atomic)
        try requireRegularFile(destination)
        guard try Data(contentsOf: destination) == raster.pngData else {
            throw ThemeStoreDiskError.invalidStore
        }
    }

    func commit(_ transaction: URL) throws {
        try requireOwnedTransaction(transaction)
        try ensureRootDirectory()
        let rootDescriptor = open(
            rootDirectory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootDescriptor >= 0 else {
            throw ThemeStoreDiskError.commitFailed
        }
        defer { close(rootDescriptor) }

        let transactionName = transaction.lastPathComponent
        let result: Int32
        if fileManager.fileExists(atPath: liveDirectory.path) {
            result = transactionName.withCString { transactionName in
                liveDirectoryName.withCString { liveName in
                    renameatx_np(
                        rootDescriptor,
                        transactionName,
                        rootDescriptor,
                        liveName,
                        UInt32(RENAME_SWAP)
                    )
                }
            }
        } else {
            result = transactionName.withCString { transactionName in
                liveDirectoryName.withCString { liveName in
                    renameat(
                        rootDescriptor,
                        transactionName,
                        rootDescriptor,
                        liveName
                    )
                }
            }
        }
        guard result == 0 else {
            throw ThemeStoreDiskError.commitFailed
        }
        _ = fsync(rootDescriptor)
        if fileManager.fileExists(atPath: transaction.path) {
            try? fileManager.removeItem(at: transaction)
        }
    }

    func rollback(_ transaction: URL) {
        guard transaction.deletingLastPathComponent() == rootDirectory,
              transaction.lastPathComponent.hasPrefix(".staging-")
        else {
            return
        }
        try? fileManager.removeItem(at: transaction)
    }

    func rasterData(
        for reference: SanitizedRasterReference
    ) throws -> Data {
        try validateReference(reference)
        try requireSafeDirectory(liveDirectory)
        let rasterDirectory = liveDirectory
            .appendingPathComponent("Rasters", isDirectory: true)
        try requireSafeDirectory(rasterDirectory)
        let url = rasterDirectory
            .appendingPathComponent(reference.relativeIdentifier)
        try requireRegularFile(url)
        let data = try Data(contentsOf: url)
        guard sha256(data) == reference.sha256 else {
            throw ThemeStoreDiskError.invalidStore
        }
        return data
    }

    func pruneRasters(
        in transaction: URL,
        keeping references: Set<String>
    ) throws {
        try requireOwnedTransaction(transaction)
        let directory = transaction.appendingPathComponent(
            "Rasters",
            isDirectory: true
        )
        try requireSafeDirectory(directory)
        for item in try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) where !references.contains(item.lastPathComponent) {
            try fileManager.removeItem(at: item)
        }
    }

    private var liveDirectory: URL {
        rootDirectory.appendingPathComponent(
            liveDirectoryName,
            isDirectory: true
        )
    }

    private func ensureRootDirectory() throws {
        if !fileManager.fileExists(atPath: rootDirectory.path) {
            try fileManager.createDirectory(
                at: rootDirectory,
                withIntermediateDirectories: true
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: rootDirectory.path
            )
        }
        try requireSafeDirectory(rootDirectory)
    }

    private func requireOwnedTransaction(_ transaction: URL) throws {
        guard transaction.deletingLastPathComponent().standardizedFileURL
                == rootDirectory,
              transaction.lastPathComponent.hasPrefix(".staging-")
        else {
            throw ThemeStoreDiskError.invalidStore
        }
        try requireSafeDirectory(transaction)
    }

    private func requireSafeDirectory(_ url: URL) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
        else {
            throw ThemeStoreDiskError.invalidStore
        }
    }

    private func requireRegularFile(_ url: URL) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
        else {
            throw ThemeStoreDiskError.invalidStore
        }
    }

    private func validateReference(
        _ reference: SanitizedRasterReference
    ) throws {
        let hash = reference.sha256
        guard hash.count == 64,
              hash.unicodeScalars.allSatisfy({
                  (48 ... 57).contains($0.value)
                      || (97 ... 102).contains($0.value)
              }),
              reference.relativeIdentifier == hash + ".png"
        else {
            throw ThemeStoreDiskError.invalidStore
        }
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private enum ThemeStoreDiskError: Error {
        case invalidStore
        case commitFailed
    }
}
