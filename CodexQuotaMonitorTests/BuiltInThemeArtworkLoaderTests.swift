import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import CodexQuotaMonitor

final class BuiltInThemeArtworkLoaderTests: XCTestCase {
    func testResourceNamesAreExactAndUniqueForAllBuiltInThemes() {
        let expected = [
            "theme-morandi-background.png",
            "theme-cyberpunk-background.png",
            "theme-warm-hand-drawn-background.png",
            "theme-glass-background.png",
            "theme-sketch-background.png",
            "theme-cartoon-illustration-background.png",
        ]

        let actual = BuiltInThemeID.allCases.map {
            BuiltInThemeArtworkLoader.resourceName(for: $0)
        }

        XCTAssertEqual(actual, expected)
        XCTAssertEqual(Set(actual).count, BuiltInThemeID.allCases.count)
    }

    func testInjectedDataProviderReturnsDataAndMissingResourceReturnsNil() {
        let glassData = Data("glass-artwork".utf8)
        let loader = BuiltInThemeArtworkLoader { resourceName in
            resourceName == "theme-glass-background.png"
                ? glassData
                : nil
        }

        XCTAssertEqual(loader.data(for: .glass), glassData)
        XCTAssertNil(loader.data(for: .morandi))
    }

    func testProductionBundleContainsDecodableSingleFrameSquarePNGs()
        throws
    {
        let loader = BuiltInThemeArtworkLoader(
            bundle: try applicationBundle()
        )

        for id in BuiltInThemeID.allCases {
            let resourceName = BuiltInThemeArtworkLoader.resourceName(for: id)
            let data = try XCTUnwrap(
                loader.data(for: id),
                "Missing production resource \(resourceName)"
            )
            let source = try XCTUnwrap(
                CGImageSourceCreateWithData(data as CFData, nil),
                "Undecodable production resource \(resourceName)"
            )
            let type = CGImageSourceGetType(source).map { $0 as String }
            let properties = try XCTUnwrap(
                CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                    as? [CFString: Any]
            )
            let width = try XCTUnwrap(
                properties[kCGImagePropertyPixelWidth] as? NSNumber
            ).intValue
            let height = try XCTUnwrap(
                properties[kCGImagePropertyPixelHeight] as? NSNumber
            ).intValue

            XCTAssertEqual(type, UTType.png.identifier, resourceName)
            XCTAssertEqual(CGImageSourceGetCount(source), 1, resourceName)
            XCTAssertNotNil(
                CGImageSourceCreateImageAtIndex(source, 0, nil),
                resourceName
            )
            XCTAssertEqual(width, height, resourceName)
            XCTAssertGreaterThanOrEqual(width, 1_200, resourceName)
        }
    }

    private func applicationBundle() throws -> Bundle {
        var candidate = Bundle(for: Self.self).bundleURL.standardizedFileURL
        while candidate.path != "/" {
            if candidate.pathExtension == "app" {
                return try XCTUnwrap(Bundle(url: candidate))
            }
            candidate.deleteLastPathComponent()
        }
        return try XCTUnwrap(nil as Bundle?)
    }
}
