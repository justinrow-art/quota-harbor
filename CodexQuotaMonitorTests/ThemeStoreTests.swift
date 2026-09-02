import CryptoKit
import XCTest
@testable import CodexQuotaMonitor

@MainActor
final class ThemeStoreTests: XCTestCase {
    func testDefaultsExposeSixImmutableBuiltInsAndMorandiIsActive()
        throws
    {
        let harness = try makeHarness()

        XCTAssertEqual(harness.store.snapshot.builtIns.count, 6)
        XCTAssertTrue(harness.store.snapshot.customThemes.isEmpty)
        XCTAssertEqual(
            harness.store.snapshot.activeSelection,
            .builtIn(.morandi)
        )
    }

    func testSelectDuplicateSaveActivateDeleteAndReload() throws {
        let harness = try makeHarness(fixedUUID: testUUID)
        try harness.store.selectBuiltIn(.glass)
        let duplicate = try harness.store.duplicateBuiltIn(
            .morandi,
            named: "Copy"
        )

        XCTAssertEqual(duplicate.id, testUUID)
        XCTAssertEqual(
            harness.store.snapshot.activeSelection,
            .builtIn(.glass)
        )
        try harness.store.activateCustom(duplicate.id)
        XCTAssertThrowsError(try harness.store.deleteCustom(duplicate.id)) {
            XCTAssertEqual(
                $0 as? ThemeStoreError,
                .activeThemeCannotBeDeleted
            )
        }
        try harness.store.reset()
        try harness.store.deleteCustom(duplicate.id)

        let reloaded = try ThemeStore(
            persistence: ThemeStoreDiskPersistence(
                rootDirectory: harness.root
            )
        )
        XCTAssertEqual(reloaded.snapshot.activeSelection, .builtIn(.morandi))
        XCTAssertTrue(reloaded.snapshot.customThemes.isEmpty)
    }

    func testBuiltInCannotBeSavedAsMutableCustomTheme() throws {
        let harness = try makeHarness()

        XCTAssertThrowsError(
            try harness.store.saveCustom(
                BuiltInThemes.morandi.document,
                activate: true
            )
        ) { error in
            XCTAssertEqual(error as? ThemeStoreError, .builtInImmutable)
        }
    }

    func testFailedAtomicCommitKeepsMemoryAndDiskAtLastValidState() throws {
        let root = makeRoot()
        let disk = ThemeStoreDiskPersistence(rootDirectory: root)
        let switchable = SwitchableThemeStorePersistence(base: disk)
        let store = try ThemeStore(persistence: switchable)
        try store.selectBuiltIn(.glass)
        let before = store.snapshot
        let beforeManifest = try disk.loadManifest()
        switchable.shouldFailCommit = true

        XCTAssertThrowsError(try store.selectBuiltIn(.sketch)) { error in
            XCTAssertEqual(error as? ThemeStoreError, .persistenceFailed)
        }

        XCTAssertEqual(store.snapshot, before)
        XCTAssertEqual(try disk.loadManifest(), beforeManifest)
        XCTAssertEqual(
            try ThemeStore(persistence: disk).snapshot,
            before
        )
    }

    func testMalformedImportLeavesActiveThemeAndFilesUntouched() async throws {
        let harness = try makeHarness()
        try harness.store.selectBuiltIn(.glass)
        let before = harness.store.snapshot
        let beforeContents = try recursiveRelativePaths(at: harness.root)

        do {
            _ = try await harness.store.importTheme(Data("{".utf8))
            XCTFail("Expected import failure")
        } catch {
            XCTAssertEqual(
                error as? ThemeStoreError,
                .importFailed(.malformedJSON)
            )
        }

        XCTAssertEqual(harness.store.snapshot, before)
        XCTAssertEqual(
            try recursiveRelativePaths(at: harness.root),
            beforeContents
        )
    }

    func testImportAndExportRespectSeparateRasterConsent() async throws {
        let harness = try makeHarness()
        let document = ThemeImportTestFactory.customDocument()
        let data = try ThemeImportExportService().exportTheme(
            document,
            rasterPNG: nil,
            includeRaster: false
        )

        let importedID = try await harness.store.importTheme(data)
        XCTAssertEqual(importedID, document.id)
        XCTAssertEqual(
            harness.store.snapshot.activeSelection,
            .custom(document.id)
        )

        let exported = try harness.store.exportTheme(
            .custom(document.id),
            includeRaster: false
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: exported) as? [String: Any]
        )
        XCTAssertNil(object["raster"])
    }

    func testRasterReadRejectsSymlinkedParentDirectory() throws {
        let root = makeRoot()
        let live = root.appendingPathComponent("Current", isDirectory: true)
        let outside = root.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(
            at: live,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true
        )
        let data = Data("sanitized raster".utf8)
        let hash = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        try data.write(to: outside.appendingPathComponent(hash + ".png"))
        try FileManager.default.createSymbolicLink(
            at: live.appendingPathComponent("Rasters"),
            withDestinationURL: outside
        )
        let persistence = ThemeStoreDiskPersistence(rootDirectory: root)

        XCTAssertThrowsError(
            try persistence.rasterData(
                for: SanitizedRasterReference(
                    relativeIdentifier: hash + ".png",
                    sha256: hash
                )
            )
        )
    }

    func testPendingRasterAndActivationCommitAtomically() throws {
        let harness = try makeHarness(fixedUUID: testUUID)
        var document = try harness.store.duplicateBuiltIn(
            .morandi,
            named: "Raster custom"
        )
        let data = Data("already-sanitized-png".utf8)
        let hash = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        let pending = PendingSanitizedThemeRaster(
            reference: SanitizedRasterReference(
                relativeIdentifier: hash + ".png",
                sha256: hash
            ),
            pngData: data
        )
        document.rasterReference = pending.reference

        try harness.store.saveCustom(
            document,
            activate: true,
            pendingRaster: pending
        )

        XCTAssertEqual(
            harness.store.snapshot.activeSelection,
            .custom(document.id)
        )
        XCTAssertEqual(
            try harness.store.rasterData(for: pending.reference),
            data
        )
    }

    func testPendingRasterLargerThanTransferEnvelopeCommitsAtomically()
        throws
    {
        let harness = try makeHarness(fixedUUID: testUUID)
        var document = try harness.store.duplicateBuiltIn(
            .morandi,
            named: "Large raster custom"
        )
        let data = Data(
            repeating: 0xA5,
            count: ThemeImportExportService.maximumDocumentBytes + 1
        )
        let hash = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        let pending = PendingSanitizedThemeRaster(
            reference: SanitizedRasterReference(
                relativeIdentifier: hash + ".png",
                sha256: hash
            ),
            pngData: data
        )
        document.rasterReference = pending.reference

        try harness.store.saveCustom(
            document,
            activate: true,
            pendingRaster: pending
        )

        XCTAssertEqual(
            try harness.store.rasterData(for: pending.reference),
            data
        )
        XCTAssertEqual(
            harness.store.snapshot.activeSelection,
            .custom(document.id)
        )
    }

    func testPendingRasterHashMismatchLeavesStoreUntouched() throws {
        let harness = try makeHarness(fixedUUID: testUUID)
        var document = try harness.store.duplicateBuiltIn(
            .morandi,
            named: "Hash mismatch"
        )
        let before = harness.store.snapshot
        let invalidHash = String(repeating: "a", count: 64)
        let reference = SanitizedRasterReference(
            relativeIdentifier: invalidHash + ".png",
            sha256: invalidHash
        )
        document.rasterReference = reference

        XCTAssertThrowsError(
            try harness.store.saveCustom(
                document,
                activate: true,
                pendingRaster: PendingSanitizedThemeRaster(
                    reference: reference,
                    pngData: Data("different bytes".utf8)
                )
            )
        ) { error in
            XCTAssertEqual(error as? ThemeStoreError, .invalidTheme)
        }
        XCTAssertEqual(harness.store.snapshot, before)
        XCTAssertThrowsError(try harness.store.rasterData(for: reference))
    }

    func testPendingRasterFilenameMismatchLeavesStoreUntouched() throws {
        let harness = try makeHarness(fixedUUID: testUUID)
        var document = try harness.store.duplicateBuiltIn(
            .morandi,
            named: "Filename mismatch"
        )
        let before = harness.store.snapshot
        let data = Data("sanitized bytes".utf8)
        let hash = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        let reference = SanitizedRasterReference(
            relativeIdentifier: String(repeating: "b", count: 64) + ".png",
            sha256: hash
        )
        document.rasterReference = reference

        XCTAssertThrowsError(
            try harness.store.saveCustom(
                document,
                activate: true,
                pendingRaster: PendingSanitizedThemeRaster(
                    reference: reference,
                    pngData: data
                )
            )
        ) { error in
            XCTAssertEqual(error as? ThemeStoreError, .invalidTheme)
        }
        XCTAssertEqual(harness.store.snapshot, before)
        XCTAssertThrowsError(try harness.store.rasterData(for: reference))
    }

    func testFailedPendingRasterCommitKeepsManifestAndRasterOutOfLiveStore()
        throws
    {
        let root = makeRoot()
        let disk = ThemeStoreDiskPersistence(rootDirectory: root)
        let switchable = SwitchableThemeStorePersistence(base: disk)
        let store = try ThemeStore(
            persistence: switchable,
            makeUUID: { self.testUUID }
        )
        var document = try store.duplicateBuiltIn(
            .morandi,
            named: "Atomic failure"
        )
        let before = store.snapshot
        let data = Data("pending-but-never-live".utf8)
        let hash = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        let reference = SanitizedRasterReference(
            relativeIdentifier: hash + ".png",
            sha256: hash
        )
        document.rasterReference = reference
        switchable.shouldFailCommit = true

        XCTAssertThrowsError(
            try store.saveCustom(
                document,
                activate: true,
                pendingRaster: PendingSanitizedThemeRaster(
                    reference: reference,
                    pngData: data
                )
            )
        )

        XCTAssertEqual(store.snapshot, before)
        XCTAssertThrowsError(try disk.rasterData(for: reference))
    }

    private let testUUID = UUID(
        uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    )!

    private func makeHarness(
        fixedUUID: UUID? = nil
    ) throws -> (store: ThemeStore, root: URL) {
        let root = makeRoot()
        let persistence = ThemeStoreDiskPersistence(rootDirectory: root)
        let store = try ThemeStore(
            persistence: persistence,
            makeUUID: { fixedUUID ?? UUID() }
        )
        return (store, root)
    }

    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func recursiveRelativePaths(at root: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: root.path) else {
            return []
        }
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        )
        return (enumerator?.allObjects as? [URL] ?? [])
            .map { String($0.path.dropFirst(root.path.count + 1)) }
            .sorted()
    }
}

private final class SwitchableThemeStorePersistence:
    ThemeStorePersisting
{
    let base: ThemeStoreDiskPersistence
    var shouldFailCommit = false

    init(base: ThemeStoreDiskPersistence) {
        self.base = base
    }

    var rootDirectory: URL { base.rootDirectory }

    func loadManifest() throws -> Data? { try base.loadManifest() }
    func beginTransaction() throws -> URL { try base.beginTransaction() }
    func writeManifest(_ data: Data, in transaction: URL) throws {
        try base.writeManifest(data, in: transaction)
    }
    func stageRaster(
        _ raster: PendingSanitizedThemeRaster,
        in transaction: URL
    ) throws {
        try base.stageRaster(raster, in: transaction)
    }
    func commit(_ transaction: URL) throws {
        if shouldFailCommit { throw TestCommitError.failed }
        try base.commit(transaction)
    }
    func rollback(_ transaction: URL) {
        base.rollback(transaction)
    }
    func rasterData(
        for reference: SanitizedRasterReference
    ) throws -> Data {
        try base.rasterData(for: reference)
    }
    func pruneRasters(
        in transaction: URL,
        keeping references: Set<String>
    ) throws {
        try base.pruneRasters(in: transaction, keeping: references)
    }

    private enum TestCommitError: Error { case failed }
}
