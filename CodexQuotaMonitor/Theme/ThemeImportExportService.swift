import CryptoKit
import Foundation

enum ThemeImportExportError: Error, Equatable, Sendable {
    case documentTooLarge(Int)
    case rasterPayloadTooLarge(Int)
    case malformedJSON
    case unknownField(String)
    case newerFormatVersion(Int)
    case unsupportedFormatVersion(Int)
    case newerThemeSchema(Int)
    case unsupportedThemeSchema(Int)
    case invalidDocument
    case unsafeText
    case invalidTheme
    case invalidRasterReference
    case missingRaster
    case unexpectedRaster
    case invalidRasterPayload
    case rasterHashMismatch
}

struct PreparedThemeImport: Equatable, Sendable {
    let document: ThemeDocument
    let sanitizedRaster: SanitizedRasterReference?
}

struct ThemeImportExportService: Sendable {
    static let currentFormatVersion = 1
    static let maximumDocumentBytes = 1 * 1_024 * 1_024
    static let maximumRasterBytes = ThemeRasterLimits.maximumInputBytes
    static let maximumEncodedRasterBytes =
        ((maximumRasterBytes + 2) / 3) * 4
    static let maximumTransferBytes = maximumDocumentBytes
        + maximumEncodedRasterBytes + 1_024

    func prepareImport(
        _ data: Data,
        stagingDirectory: URL
    ) async throws -> PreparedThemeImport {
        guard data.count <= Self.maximumTransferBytes else {
            throw ThemeImportExportError.documentTooLarge(data.count)
        }
        let root: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: data)
                    as? [String: Any]
            else {
                throw ThemeImportExportError.malformedJSON
            }
            root = object
        } catch let error as ThemeImportExportError {
            throw error
        } catch {
            throw ThemeImportExportError.malformedJSON
        }

        try requireKeys(
            root,
            required: ["formatVersion", "theme"],
            optional: ["raster"]
        )
        try validateEnvelopeSize(data: data, root: root)
        let formatVersion = try integer(root["formatVersion"])
        guard formatVersion <= Self.currentFormatVersion else {
            throw ThemeImportExportError.newerFormatVersion(formatVersion)
        }
        guard formatVersion == Self.currentFormatVersion else {
            throw ThemeImportExportError.unsupportedFormatVersion(
                formatVersion
            )
        }
        guard let themeObject = root["theme"] as? [String: Any] else {
            throw ThemeImportExportError.invalidDocument
        }
        let document = try decodeTheme(themeObject)
        try validate(document)

        let rasterObject = root["raster"] as? [String: Any]
        let sanitizedRaster = try await prepareRaster(
            rasterObject,
            for: document,
            stagingDirectory: stagingDirectory
        )
        return PreparedThemeImport(
            document: document,
            sanitizedRaster: sanitizedRaster
        )
    }

    func exportTheme(
        _ document: ThemeDocument,
        rasterPNG: Data?,
        includeRaster: Bool
    ) throws -> Data {
        try validate(document)
        var exportedDocument = document
        var raster: ThemeTransferRaster?

        if includeRaster, let reference = document.rasterReference {
            guard let rasterPNG else {
                throw ThemeImportExportError.missingRaster
            }
            guard rasterPNG.count <= Self.maximumRasterBytes else {
                throw ThemeImportExportError.rasterPayloadTooLarge(
                    rasterPNG.count
                )
            }
            let digest = sha256(rasterPNG)
            guard digest == reference.sha256,
                  reference.relativeIdentifier == digest + ".png"
            else {
                throw ThemeImportExportError.rasterHashMismatch
            }
            raster = ThemeTransferRaster(
                mediaType: "image/png",
                sha256: digest,
                pngBase64: rasterPNG.base64EncodedString()
            )
        } else {
            exportedDocument.rasterReference = nil
        }

        let envelope = ThemeTransferEnvelope(
            formatVersion: Self.currentFormatVersion,
            theme: exportedDocument,
            raster: raster
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let metadata = try encoder.encode(
            ThemeTransferEnvelope(
                formatVersion: Self.currentFormatVersion,
                theme: exportedDocument,
                raster: nil
            )
        )
        guard metadata.count <= Self.maximumDocumentBytes else {
            throw ThemeImportExportError.documentTooLarge(metadata.count)
        }
        let data = try encoder.encode(envelope)
        guard data.count <= Self.maximumTransferBytes else {
            throw ThemeImportExportError.documentTooLarge(data.count)
        }
        return data
    }

    private func validateEnvelopeSize(
        data: Data,
        root: [String: Any]
    ) throws {
        guard root["raster"] != nil else {
            guard data.count <= Self.maximumDocumentBytes else {
                throw ThemeImportExportError.documentTooLarge(data.count)
            }
            return
        }

        var metadataRoot = root
        metadataRoot.removeValue(forKey: "raster")
        let metadata: Data
        do {
            metadata = try JSONSerialization.data(
                withJSONObject: metadataRoot,
                options: [.sortedKeys]
            )
        } catch {
            throw ThemeImportExportError.malformedJSON
        }
        guard metadata.count <= Self.maximumDocumentBytes else {
            throw ThemeImportExportError.documentTooLarge(metadata.count)
        }
    }

    private func decodeTheme(
        _ object: [String: Any]
    ) throws -> ThemeDocument {
        let schemaVersion = try integer(object["schemaVersion"])
        guard schemaVersion <= ThemeDocument.currentSchemaVersion else {
            throw ThemeImportExportError.newerThemeSchema(schemaVersion)
        }
        guard schemaVersion >= ThemeDocument.currentSchemaVersion - 1 else {
            throw ThemeImportExportError.unsupportedThemeSchema(schemaVersion)
        }
        let data: Data
        do {
            data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )
        } catch {
            throw ThemeImportExportError.invalidDocument
        }

        if schemaVersion == ThemeDocument.currentSchemaVersion {
            try validateCurrentShape(object)
            do {
                return try ThemeCanonicalCodec.decode(data)
            } catch {
                throw ThemeImportExportError.invalidDocument
            }
        }

        try validateLegacyShape(object)
        do {
            let legacy = try JSONDecoder().decode(
                LegacyThemeDocumentV0.self,
                from: data
            )
            return ThemeDocument(
                schemaVersion: ThemeDocument.currentSchemaVersion,
                id: legacy.id,
                name: legacy.name,
                appearances: ThemeAppearanceVariants(
                    light: ThemeAppearanceTokens(
                        palette: legacy.palette,
                        background: legacy.background
                    ),
                    dark: ThemeAppearanceTokens(
                        palette: legacy.palette,
                        background: legacy.background
                    )
                ),
                geometry: legacy.geometry,
                ornamentOpacity: legacy.ornamentOpacity,
                rasterReference: legacy.rasterReference
            )
        } catch let error as ThemeImportExportError {
            throw error
        } catch {
            throw ThemeImportExportError.invalidDocument
        }
    }

    private func validate(_ document: ThemeDocument) throws {
        let trimmed = document.name.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard trimmed == document.name,
              (1 ... 80).contains(document.name.count),
              !document.name.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              })
        else {
            throw ThemeImportExportError.unsafeText
        }
        let lower = document.name.lowercased()
        for forbidden in [
            "http://", "https://", "file://", "javascript:", "../",
            "..\\", "<script", "<style", "<svg", "@font-face",
            "data:text/html",
        ] where lower.contains(forbidden) {
            throw ThemeImportExportError.unsafeText
        }

        if let reference = document.rasterReference {
            guard isValidHash(reference.sha256),
                  reference.relativeIdentifier
                    == reference.sha256 + ".png"
            else {
                throw ThemeImportExportError.invalidRasterReference
            }
        }
        let context = ThemeResolutionContext(
            appearance: .light,
            accessibility: ThemeAccessibilityPreferences(
                increaseContrast: false,
                reduceTransparency: false,
                reduceMotion: false,
                textScale: 1
            )
        )
        guard case .success = ThemeValidator(context: context)
            .validate(document)
        else {
            throw ThemeImportExportError.invalidTheme
        }
    }

    private func prepareRaster(
        _ object: [String: Any]?,
        for document: ThemeDocument,
        stagingDirectory: URL
    ) async throws -> SanitizedRasterReference? {
        guard let reference = document.rasterReference else {
            guard object == nil else {
                throw ThemeImportExportError.unexpectedRaster
            }
            return nil
        }
        guard let object else {
            throw ThemeImportExportError.missingRaster
        }
        try requireKeys(
            object,
            required: ["mediaType", "sha256", "pngBase64"],
            optional: []
        )
        guard object["mediaType"] as? String == "image/png",
              let declaredHash = object["sha256"] as? String,
              declaredHash == reference.sha256,
              let encoded = object["pngBase64"] as? String,
              let png = Data(base64Encoded: encoded),
              !png.isEmpty
        else {
            throw ThemeImportExportError.invalidRasterPayload
        }
        guard png.count <= Self.maximumRasterBytes else {
            throw ThemeImportExportError.rasterPayloadTooLarge(png.count)
        }

        do {
            try FileManager.default.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: true
            )
            let incoming = stagingDirectory.appendingPathComponent(
                ".incoming-\(UUID().uuidString).png"
            )
            try png.write(to: incoming, options: [.atomic])
            defer { try? FileManager.default.removeItem(at: incoming) }
            let sanitized = try await ThemeRasterProcessor(
                appThemeDirectory: stagingDirectory
            ).sanitize(
                userSelection: .appOwnedImportedThemePayload(incoming)
            )
            guard sanitized == reference else {
                throw ThemeImportExportError.rasterHashMismatch
            }
            return sanitized
        } catch let error as ThemeImportExportError {
            throw error
        } catch {
            throw ThemeImportExportError.invalidRasterPayload
        }
    }

    private func validateCurrentShape(
        _ object: [String: Any]
    ) throws {
        try requireKeys(
            object,
            required: [
                "schemaVersion", "id", "name", "appearances", "geometry",
                "ornamentOpacity",
            ],
            optional: ["rasterReference"]
        )
        guard let appearances = object["appearances"] as? [String: Any],
              let geometry = object["geometry"] as? [String: Any]
        else {
            throw ThemeImportExportError.invalidDocument
        }
        try requireKeys(
            appearances,
            required: ["light", "dark"],
            optional: []
        )
        for appearance in ["light", "dark"] {
            guard let tokens = appearances[appearance] as? [String: Any]
            else {
                throw ThemeImportExportError.invalidDocument
            }
            try validateAppearanceTokens(tokens)
        }
        try validateGeometry(geometry)
        try validateOptionalRasterReference(object["rasterReference"])
    }

    private func validateLegacyShape(_ object: [String: Any]) throws {
        try requireKeys(
            object,
            required: [
                "schemaVersion", "id", "name", "palette", "background",
                "geometry", "ornamentOpacity",
            ],
            optional: ["rasterReference"]
        )
        guard let palette = object["palette"] as? [String: Any],
              let background = object["background"] as? [String: Any],
              let geometry = object["geometry"] as? [String: Any]
        else {
            throw ThemeImportExportError.invalidDocument
        }
        try validatePalette(palette)
        try validateBackground(background)
        try validateGeometry(geometry)
        try validateOptionalRasterReference(object["rasterReference"])
    }

    private func validateAppearanceTokens(
        _ object: [String: Any]
    ) throws {
        try requireKeys(
            object,
            required: ["palette", "background"],
            optional: []
        )
        guard let palette = object["palette"] as? [String: Any],
              let background = object["background"] as? [String: Any]
        else {
            throw ThemeImportExportError.invalidDocument
        }
        try validatePalette(palette)
        try validateBackground(background)
    }

    private func validatePalette(_ object: [String: Any]) throws {
        try requireKeys(
            object,
            required: [
                "background", "text", "secondaryText", "accent", "healthy",
                "warning", "critical", "stale", "unavailable", "border",
                "focus",
            ],
            optional: []
        )
    }

    private func validateBackground(_ object: [String: Any]) throws {
        guard let type = object["type"] as? String else {
            throw ThemeImportExportError.invalidDocument
        }
        switch type {
        case "solid":
            try requireKeys(
                object,
                required: ["type", "color"],
                optional: []
            )
        case "boundedGradient":
            try requireKeys(
                object,
                required: ["type", "colors"],
                optional: []
            )
        case "systemMaterial":
            try requireKeys(
                object,
                required: ["type", "material"],
                optional: []
            )
        default:
            throw ThemeImportExportError.invalidDocument
        }
    }

    private func validateGeometry(_ object: [String: Any]) throws {
        try requireKeys(
            object,
            required: [
                "cornerRadius", "borderWidth", "shadowRadius",
                "materialOpacity",
            ],
            optional: []
        )
    }

    private func validateOptionalRasterReference(_ value: Any?) throws {
        guard let value, !(value is NSNull) else { return }
        guard let object = value as? [String: Any] else {
            throw ThemeImportExportError.invalidRasterReference
        }
        try requireKeys(
            object,
            required: ["relativeIdentifier", "sha256"],
            optional: []
        )
    }

    private func requireKeys(
        _ object: [String: Any],
        required: Set<String>,
        optional: Set<String>
    ) throws {
        let allowed = required.union(optional)
        if let unknown = object.keys.first(where: { !allowed.contains($0) }) {
            throw ThemeImportExportError.unknownField(unknown)
        }
        guard required.isSubset(of: Set(object.keys)) else {
            throw ThemeImportExportError.invalidDocument
        }
    }

    private func integer(_ value: Any?) throws -> Int {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.rounded() == number.doubleValue
        else {
            throw ThemeImportExportError.invalidDocument
        }
        return number.intValue
    }

    private func isValidHash(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            (48 ... 57).contains($0.value) || (97 ... 102).contains($0.value)
        }
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private struct ThemeTransferEnvelope: Codable {
    let formatVersion: Int
    let theme: ThemeDocument
    let raster: ThemeTransferRaster?
}

private struct ThemeTransferRaster: Codable {
    let mediaType: String
    let sha256: String
    let pngBase64: String
}

private struct LegacyThemeDocumentV0: Codable {
    let schemaVersion: Int
    let id: UUID
    let name: String
    let palette: SemanticPalette
    let background: ThemeBackground
    let geometry: ThemeGeometry
    let ornamentOpacity: Double
    let rasterReference: SanitizedRasterReference?
}
