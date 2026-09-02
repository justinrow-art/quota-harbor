import CryptoKit
import XCTest
@testable import CodexQuotaMonitor

@MainActor
final class ThemeImportSecurityTests: XCTestCase {
    nonisolated(unsafe) private var temporaryDirectory: URL!

    override nonisolated func setUpWithError() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        temporaryDirectory = directory
    }

    override nonisolated func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    func testCurrentDocumentRoundTripsThroughStrictEnvelope() async throws {
        let document = ThemeImportTestFactory.customDocument()
        let service = ThemeImportExportService()
        let data = try service.exportTheme(
            document,
            rasterPNG: nil,
            includeRaster: false
        )

        let imported = try await service.prepareImport(
            data,
            stagingDirectory: temporaryDirectory
        )

        XCTAssertEqual(imported.document, document)
        XCTAssertNil(imported.sanitizedRaster)
    }

    func testPreviousSchemaMigratesSingleAppearanceToLightAndDark()
        async throws
    {
        let source = ThemeImportTestFactory.customDocument()
        let tokens = source.appearances.light
        let legacyTheme: [String: Any] = [
            "schemaVersion": 0,
            "id": source.id.uuidString,
            "name": source.name,
            "palette": ThemeImportTestFactory.jsonObject(tokens.palette),
            "background": ThemeImportTestFactory.jsonObject(tokens.background),
            "geometry": ThemeImportTestFactory.jsonObject(source.geometry),
            "ornamentOpacity": source.ornamentOpacity,
            "rasterReference": NSNull(),
        ]
        let data = try JSONSerialization.data(
            withJSONObject: [
                "formatVersion": 1,
                "theme": legacyTheme,
            ],
            options: [.sortedKeys]
        )

        let imported = try await ThemeImportExportService().prepareImport(
            data,
            stagingDirectory: temporaryDirectory
        )

        XCTAssertEqual(imported.document.schemaVersion, 1)
        XCTAssertEqual(imported.document.appearances.light, tokens)
        XCTAssertEqual(imported.document.appearances.dark, tokens)
    }

    func testOversizedAndTruncatedJSONFailBeforeMutation() async throws {
        let service = ThemeImportExportService()
        let oversized = Data(
            repeating: 0x20,
            count: ThemeImportExportService.maximumTransferBytes + 1
        )

        await assertImportError(.documentTooLarge(oversized.count)) {
            _ = try await service.prepareImport(
                oversized,
                stagingDirectory: temporaryDirectory
            )
        }
        await assertImportError(.malformedJSON) {
            _ = try await service.prepareImport(
                Data(#"{"formatVersion":1,"theme":{"#.utf8),
                stagingDirectory: temporaryDirectory
            )
        }
    }

    func testUnknownAndNewerFieldsFailClosed() async throws {
        let service = ThemeImportExportService()
        let valid = try service.exportTheme(
            ThemeImportTestFactory.customDocument(),
            rasterPNG: nil,
            includeRaster: false
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: valid) as? [String: Any]
        )
        object["script"] = "alert(1)"

        await assertImportError(.unknownField("script")) {
            _ = try await service.prepareImport(
                try JSONSerialization.data(withJSONObject: object),
                stagingDirectory: temporaryDirectory
            )
        }

        object.removeValue(forKey: "script")
        object["formatVersion"] = 2
        await assertImportError(.newerFormatVersion(2)) {
            _ = try await service.prepareImport(
                try JSONSerialization.data(withJSONObject: object),
                stagingDirectory: temporaryDirectory
            )
        }
    }

    func testUnsafeNamesTokensAndRasterIdentifiersAreRejected() async throws {
        let service = ThemeImportExportService()
        for unsafeName in [
            "https://example.com/theme",
            "<svg onload=alert(1)>",
            "<script>alert(1)</script>",
            "@font-face { src: url(file:///tmp/font); }",
            "../escape",
        ] {
            var document = ThemeImportTestFactory.customDocument()
            document.name = unsafeName
            let data = ThemeImportTestFactory.uncheckedEnvelope(document)
            await assertImportError(.unsafeText) {
                _ = try await service.prepareImport(
                    data,
                    stagingDirectory: temporaryDirectory
                )
            }
        }

        var invalidColor = ThemeImportTestFactory.customDocument()
        invalidColor.appearances.light.palette.text = "https://remote/color"
        await assertImportError(.invalidTheme) {
            _ = try await service.prepareImport(
                ThemeImportTestFactory.uncheckedEnvelope(invalidColor),
                stagingDirectory: temporaryDirectory
            )
        }

        var traversal = ThemeImportTestFactory.customDocument()
        traversal.rasterReference = SanitizedRasterReference(
            relativeIdentifier: "../outside.png",
            sha256: String(repeating: "a", count: 64)
        )
        await assertImportError(.invalidRasterReference) {
            _ = try await service.prepareImport(
                ThemeImportTestFactory.uncheckedEnvelope(traversal),
                stagingDirectory: temporaryDirectory
            )
        }
    }

    func testMissingRasterAndInvalidContrastAreRejected() async throws {
        var missing = ThemeImportTestFactory.customDocument()
        missing.rasterReference = SanitizedRasterReference(
            relativeIdentifier: String(repeating: "a", count: 64) + ".png",
            sha256: String(repeating: "a", count: 64)
        )
        await assertImportError(.missingRaster) {
            _ = try await ThemeImportExportService().prepareImport(
                ThemeImportTestFactory.uncheckedEnvelope(missing),
                stagingDirectory: temporaryDirectory
            )
        }

        var contrast = ThemeImportTestFactory.customDocument()
        contrast.appearances.light.palette.text =
            contrast.appearances.light.palette.background
        await assertImportError(.invalidTheme) {
            _ = try await ThemeImportExportService().prepareImport(
                ThemeImportTestFactory.uncheckedEnvelope(contrast),
                stagingDirectory: temporaryDirectory
            )
        }
    }

    func testExportOmitsRasterWithoutConsentAndRequiresItWithConsent() throws {
        var document = ThemeImportTestFactory.customDocument()
        let hash = String(repeating: "a", count: 64)
        document.rasterReference = SanitizedRasterReference(
            relativeIdentifier: hash + ".png",
            sha256: hash
        )
        let service = ThemeImportExportService()

        let withoutRaster = try service.exportTheme(
            document,
            rasterPNG: nil,
            includeRaster: false
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: withoutRaster)
                as? [String: Any]
        )
        let theme = try XCTUnwrap(object["theme"] as? [String: Any])
        XCTAssertNil(object["raster"])
        XCTAssertNil(theme["rasterReference"])

        XCTAssertThrowsError(
            try service.exportTheme(
                document,
                rasterPNG: nil,
                includeRaster: true
            )
        ) { error in
            XCTAssertEqual(
                error as? ThemeImportExportError,
                .missingRaster
            )
        }
    }

    func testRasterExportUsesItsDedicatedBoundInsteadOfMetadataLimit() throws {
        let raster = Data(
            repeating: 0xA5,
            count: ThemeImportExportService.maximumDocumentBytes + 1
        )
        let hash = SHA256.hash(data: raster)
            .map { String(format: "%02x", $0) }
            .joined()
        var document = ThemeImportTestFactory.customDocument()
        document.rasterReference = SanitizedRasterReference(
            relativeIdentifier: hash + ".png",
            sha256: hash
        )

        let exported = try ThemeImportExportService().exportTheme(
            document,
            rasterPNG: raster,
            includeRaster: true
        )

        XCTAssertGreaterThan(
            exported.count,
            ThemeImportExportService.maximumDocumentBytes
        )
        XCTAssertLessThanOrEqual(
            exported.count,
            ThemeImportExportService.maximumTransferBytes
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: exported) as? [String: Any]
        )
        XCTAssertNotNil(object["raster"])
    }

    func testRasterExportAboveSanitizerBoundFailsBeforeEncoding() {
        let raster = Data(
            repeating: 0xA5,
            count: ThemeImportExportService.maximumRasterBytes + 1
        )
        let hash = SHA256.hash(data: raster)
            .map { String(format: "%02x", $0) }
            .joined()
        var document = ThemeImportTestFactory.customDocument()
        document.rasterReference = SanitizedRasterReference(
            relativeIdentifier: hash + ".png",
            sha256: hash
        )

        XCTAssertThrowsError(
            try ThemeImportExportService().exportTheme(
                document,
                rasterPNG: raster,
                includeRaster: true
            )
        ) { error in
            XCTAssertEqual(
                error as? ThemeImportExportError,
                .rasterPayloadTooLarge(raster.count)
            )
        }
    }

    private func assertImportError(
        _ expected: ThemeImportExportError,
        operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(
                error as? ThemeImportExportError,
                expected,
                file: file,
                line: line
            )
        }
    }
}

enum ThemeImportTestFactory {
    static func customDocument(
        id: UUID = UUID(),
        name: String = "My Theme"
    ) -> ThemeDocument {
        let source = BuiltInThemes.morandi.document
        return ThemeDocument(
            schemaVersion: ThemeDocument.currentSchemaVersion,
            id: id,
            name: name,
            appearances: source.appearances,
            geometry: source.geometry,
            ornamentOpacity: source.ornamentOpacity,
            rasterReference: nil
        )
    }

    static func uncheckedEnvelope(_ document: ThemeDocument) -> Data {
        let themeData = try! ThemeCanonicalCodec.encode(document)
        let theme = try! JSONSerialization.jsonObject(with: themeData)
        return try! JSONSerialization.data(
            withJSONObject: [
                "formatVersion": 1,
                "theme": theme,
            ],
            options: [.sortedKeys]
        )
    }

    static func jsonObject<T: Encodable>(_ value: T) -> Any {
        let data = try! JSONEncoder().encode(value)
        return try! JSONSerialization.jsonObject(with: data)
    }
}
