import AppKit
import CoreGraphics
import SwiftUI
import XCTest
@testable import CodexQuotaMonitor

private final class ThreadSafeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func increment() {
        lock.lock()
        storedValue += 1
        lock.unlock()
    }
}

final class ThemeViewIntegrationTests: XCTestCase {
    func testUnavailableRecoveryRoutesConfigurationFailuresToSettingsAndOthersToRefresh() {
        let presenter = CardUnavailableRecoveryPresenter()
        let settingsReasons: [UnavailableReason] = [
            .binaryNotFound,
            .trustValidationFailed,
            .versionUnsupported,
            .processLaunchFailed,
            .serverRejected,
        ]
        let refreshReasons: [UnavailableReason] = [
            .processExited,
            .noWindows,
            .schemaChanged,
            .timeout,
            .transportError,
            .authenticationRequired,
            .unsupportedAuthMode,
            .backendUnavailable,
            .staleDataUnavailable,
        ]

        for reason in settingsReasons {
            XCTAssertEqual(presenter.action(for: reason), .settings, "\(reason)")
        }
        for reason in refreshReasons {
            XCTAssertEqual(presenter.action(for: reason), .refresh, "\(reason)")
        }
    }

    func testPersistedThemeIdentifiersResolveToAllSixBuiltIns() {
        for expected in BuiltInThemes.all {
            XCTAssertEqual(
                ThemeViewSupport.builtInTheme(for: expected.id.rawValue),
                expected
            )
        }

        XCTAssertEqual(
            ThemeViewSupport.builtInTheme(for: "warm-illustration").id,
            .warmHandDrawn
        )
        XCTAssertEqual(
            ThemeViewSupport.builtInTheme(for: "cartoon").id,
            .cartoonIllustration
        )
        XCTAssertEqual(
            ThemeViewSupport.builtInTheme(for: "system").id,
            .morandi
        )
        XCTAssertEqual(
            ThemeViewSupport.builtInTheme(for: "unknown-theme").id,
            .morandi
        )
    }

    func testQuotaStateMapsToAvailabilityWithoutConflatingUnsupported() {
        XCTAssertEqual(
            ThemeViewSupport.availabilityState(for: .loading),
            .loading
        )
        XCTAssertEqual(
            ThemeViewSupport.availabilityState(
                for: .unavailable(.versionUnsupported)
            ),
            .unsupported
        )
        XCTAssertEqual(
            ThemeViewSupport.availabilityState(
                for: .unavailable(.unsupportedAuthMode)
            ),
            .unsupported
        )
        XCTAssertEqual(
            ThemeViewSupport.availabilityState(
                for: .unavailable(.transportError)
            ),
            .unavailable
        )
        XCTAssertEqual(
            ThemeViewSupport.availabilityState(
                for: .unavailable(.serverRejected)
            ),
            .unavailable
        )
    }

    func testOrbHealthMapsToSemanticThemeHealth() {
        XCTAssertEqual(
            ThemeViewSupport.healthState(for: .healthy),
            .healthy
        )
        XCTAssertEqual(
            ThemeViewSupport.healthState(for: .warning),
            .warning
        )
        XCTAssertEqual(
            ThemeViewSupport.healthState(for: .critical),
            .critical
        )
        XCTAssertNil(ThemeViewSupport.healthState(for: .neutral))
    }

    func testAppearanceColorSchemeMapsToSwiftUIPreference() {
        XCTAssertNil(
            ThemeViewSupport.preferredColorScheme(for: .system)
        )
        XCTAssertEqual(
            ThemeViewSupport.preferredColorScheme(for: .light),
            .light
        )
        XCTAssertEqual(
            ThemeViewSupport.preferredColorScheme(for: .dark),
            .dark
        )
    }

    func testRasterRenderPolicyRejectsUndecodableAndMissingData() {
        let undecodable = ThemeRasterRenderPolicy.renderState(
            rasterData: Data("not-an-image".utf8),
            ornamentOpacity: 1,
            reduceTransparency: false
        )
        let missing = ThemeRasterRenderPolicy.renderState(
            rasterData: nil,
            ornamentOpacity: 1,
            reduceTransparency: false
        )

        for state in [undecodable, missing] {
            XCTAssertNil(state.rasterImage)
            XCTAssertEqual(state.rasterOpacity, 0)
            XCTAssertEqual(state.readabilityScrimOpacity, 0)
        }
    }

    func testRasterRenderPolicyRejectsTruncatedPNGs() throws {
        let raster = try XCTUnwrap(
            BuiltInThemeArtworkLoader(bundle: try applicationBundle()).data(
                for: .cartoonIllustration
            )
        )
        let prefixLengths = [
            16,
            512,
            1_024,
            2_048,
            4_096,
            16_384,
            raster.count / 2,
            raster.count - 1,
        ]
        XCTAssertGreaterThan(raster.count, 32_768)

        for length in prefixLengths {
            let state = ThemeRasterRenderPolicy.renderState(
                rasterData: Data(raster.prefix(length)),
                ornamentOpacity: 1,
                reduceTransparency: false
            )

            XCTAssertNil(state.rasterImage, "prefix length: \(length)")
            XCTAssertEqual(state.rasterOpacity, 0, "prefix length: \(length)")
            XCTAssertEqual(
                state.readabilityScrimOpacity,
                0,
                "prefix length: \(length)"
            )
        }
    }

    func testRasterImageCacheReusesSuccessfulDecodeForEqualData() {
        let decodeCount = ThreadSafeCounter()
        let expectedImage = NSImage(size: NSSize(width: 2, height: 2))
        let cache = ThemeRasterImageCache(
            countLimit: 4,
            totalCostLimit: 1_024 * 1_024
        ) { _ in
            decodeCount.increment()
            return expectedImage
        }
        let data = Data(repeating: 0x5a, count: 1_024)
        let equalData = Data([UInt8](data))

        XCTAssertEqual(data, equalData)
        XCTAssertFalse(data as NSData === equalData as NSData)
        XCTAssertTrue(cache.image(for: data) === expectedImage)
        XCTAssertTrue(cache.image(for: equalData) === expectedImage)
        XCTAssertEqual(
            decodeCount.value,
            1,
            "Equal content must reuse the validation/decode result"
        )
    }

    func testRasterImageCacheNegativeCachesFailedDecodeForEqualData() {
        let decodeCount = ThreadSafeCounter()
        let cache = ThemeRasterImageCache(
            countLimit: 4,
            totalCostLimit: 1_024 * 1_024
        ) { _ in
            decodeCount.increment()
            return nil
        }
        let data = Data(repeating: 0xa5, count: 1_024)
        let equalData = Data([UInt8](data))

        XCTAssertNil(cache.image(for: data))
        XCTAssertNil(cache.image(for: equalData))
        XCTAssertEqual(
            decodeCount.value,
            1,
            "A rejected raster must be negative-cached"
        )
    }

    func testRasterImageCacheCoalescesConcurrentLookupForSameData() {
        let decodeCount = ThreadSafeCounter()
        let expectedImage = NSImage(size: NSSize(width: 2, height: 2))
        let cache = ThemeRasterImageCache(
            countLimit: 4,
            totalCostLimit: 1_024 * 1_024
        ) { _ in
            decodeCount.increment()
            Thread.sleep(forTimeInterval: 0.01)
            return expectedImage
        }
        let data = Data(repeating: 0x3c, count: 1_024)

        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            _ = cache.image(for: data)
        }

        XCTAssertEqual(
            decodeCount.value,
            1,
            "Concurrent lookups must share one validation/decode"
        )
    }

    func testProductionRasterCacheBudgetAccountsForMaximumRaster() {
        let maximumEncodedByteCount = 16 * 1_024 * 1_024
        let maximumDecodedByteCount = 4_096 * 4_096 * 4
        let maximumCombinedByteCount = maximumEncodedByteCount
            + maximumDecodedByteCount
        XCTAssertGreaterThan(
            ThemeRasterImageCache.productionTotalCostLimit,
            maximumCombinedByteCount,
            "The maximum encoded and decoded raster needs cache headroom"
        )

        let maximumImage = NSImage(
            size: NSSize(width: 4_096, height: 4_096)
        )
        let data = Data(
            repeating: 0x7e,
            count: maximumEncodedByteCount
        )

        let retainedDecodeCount = ThreadSafeCounter()
        let productionSizedCache = ThemeRasterImageCache(
            countLimit: 12,
            totalCostLimit: ThemeRasterImageCache.productionTotalCostLimit
        ) { _ in
            retainedDecodeCount.increment()
            return maximumImage
        }
        XCTAssertNotNil(productionSizedCache.image(for: data))
        XCTAssertNotNil(productionSizedCache.image(for: data))
        XCTAssertEqual(retainedDecodeCount.value, 1)

        let rejectedDecodeCount = ThreadSafeCounter()
        let undersizedCache = ThemeRasterImageCache(
            countLimit: 12,
            totalCostLimit: maximumCombinedByteCount - 1
        ) { _ in
            rejectedDecodeCount.increment()
            return maximumImage
        }
        XCTAssertNotNil(undersizedCache.image(for: data))
        XCTAssertNotNil(undersizedCache.image(for: data))
        XCTAssertEqual(
            rejectedDecodeCount.value,
            2,
            "An entry above the combined cost limit must not be retained"
        )
    }

    func testSecondLookupOfSixBuiltInRastersFitsWithinOneFrame() throws {
        let loader = BuiltInThemeArtworkLoader(
            bundle: try applicationBundle()
        )
        let rasters = try BuiltInThemes.all.map { theme in
            try XCTUnwrap(
                loader.data(for: theme.id),
                "Missing artwork for \(theme.id.rawValue)"
            )
        }
        XCTAssertEqual(rasters.count, 6)

        for raster in rasters {
            XCTAssertNotNil(
                ThemeRasterRenderPolicy.renderState(
                    rasterData: raster,
                    ornamentOpacity: 1,
                    reduceTransparency: false
                ).rasterImage
            )
        }

        let start = DispatchTime.now().uptimeNanoseconds
        var acceptedCount = 0
        for raster in rasters {
            if ThemeRasterRenderPolicy.renderState(
                rasterData: raster,
                ornamentOpacity: 1,
                reduceTransparency: false
            ).rasterImage != nil {
                acceptedCount += 1
            }
        }
        let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - start
        let elapsedMilliseconds = Double(elapsedNanoseconds) / 1_000_000

        print(
            String(
                format: "BENCHMARK six-theme second lookup: %.3f ms",
                elapsedMilliseconds
            )
        )
        XCTAssertEqual(acceptedCount, 6)
        XCTAssertLessThan(
            elapsedMilliseconds,
            16.67,
            "Six cache hits must fit within one 60 Hz frame"
        )
    }

    func testRasterRenderPolicyAcceptsValidOpaqueAndFullyTransparentPNGs()
        throws
    {
        let fullRaster = try XCTUnwrap(
            BuiltInThemeArtworkLoader(bundle: try applicationBundle()).data(
                for: .cartoonIllustration
            )
        )
        let fixtures = [
            ("full built-in", fullRaster),
            ("opaque", try tinyPNGData()),
            ("fully transparent", try tinyPNGData(alpha: 0)),
        ]

        for (name, fixture) in fixtures {
            assertAcceptedRaster(fixture, message: name)
        }
    }

    func testRasterRenderPolicyRejectsIDATPayloadBitFlipWithTerminalIEND()
        throws
    {
        let raster = try XCTUnwrap(
            BuiltInThemeArtworkLoader(bundle: try applicationBundle()).data(
                for: .cartoonIllustration
            )
        )
        let chunks = try pngFixtureChunks(in: raster)
        let idat = try XCTUnwrap(
            chunks.first { $0.type == "IDAT" && !$0.dataRange.isEmpty }
        )
        XCTAssertEqual(chunks.last?.type, "IEND")

        var bytes = [UInt8](raster)
        bytes[idat.dataRange.lowerBound + idat.dataRange.count / 2] ^= 0x01

        assertRejectedRaster(
            Data(bytes),
            message: "IDAT payload bit flip"
        )
    }

    func testRasterRenderPolicyRejectsCorruptChunkLengthAndEveryChunkCRC()
        throws
    {
        let raster = try tinyPNGData()
        let chunks = try pngFixtureChunks(in: raster)
        let iend = try XCTUnwrap(chunks.first { $0.type == "IEND" })

        var corruptLength = [UInt8](raster)
        corruptLength.replaceSubrange(
            iend.lengthRange,
            with: [0xff, 0xff, 0xff, 0xff]
        )
        assertRejectedRaster(
            Data(corruptLength),
            message: "overflowing IEND length"
        )

        for chunk in chunks {
            var corruptCRC = [UInt8](raster)
            corruptCRC[chunk.crcRange.lowerBound] ^= 0x01
            assertRejectedRaster(
                Data(corruptCRC),
                message: "\(chunk.type) CRC"
            )
        }
    }

    func testRasterRenderPolicyRequiresExactSignatureFirstUniqueIHDRAndIDAT()
        throws
    {
        let raster = try tinyPNGData()
        let bytes = [UInt8](raster)
        let chunks = try pngFixtureChunks(in: raster)
        let ihdr = try XCTUnwrap(chunks.first { $0.type == "IHDR" })
        let idat = try XCTUnwrap(chunks.first { $0.type == "IDAT" })
        let iend = try XCTUnwrap(chunks.first { $0.type == "IEND" })

        var badSignature = bytes
        badSignature[0] ^= 0x01

        var badIHDRLength = bytes
        badIHDRLength.replaceSubrange(
            ihdr.lengthRange,
            with: [0x00, 0x00, 0x00, 0x0c]
        )

        var duplicateIHDR = bytes
        duplicateIHDR.insert(
            contentsOf: bytes[ihdr.range],
            at: ihdr.range.upperBound
        )

        var nonFirstIHDR = Array(bytes.prefix(8))
        nonFirstIHDR.append(contentsOf: bytes[idat.range])
        nonFirstIHDR.append(contentsOf: bytes[ihdr.range])
        nonFirstIHDR.append(contentsOf: bytes[iend.range])

        var missingIDAT = bytes
        for chunk in chunks.filter({ $0.type == "IDAT" }).reversed() {
            missingIDAT.removeSubrange(chunk.range)
        }

        let invalidFixtures = [
            ("signature", Data(badSignature)),
            ("IHDR length", Data(badIHDRLength)),
            ("duplicate IHDR", Data(duplicateIHDR)),
            ("non-first IHDR", Data(nonFirstIHDR)),
            ("missing IDAT", Data(missingIDAT)),
        ]
        for (name, fixture) in invalidFixtures {
            assertRejectedRaster(fixture, message: name)
        }
    }

    func testRasterRenderPolicyRequiresOneTerminalZeroLengthIEND() throws {
        let raster = try tinyPNGData()
        let bytes = [UInt8](raster)
        let chunks = try pngFixtureChunks(in: raster)
        let iend = try XCTUnwrap(chunks.first { $0.type == "IEND" })

        var missingIEND = bytes
        missingIEND.removeSubrange(iend.range)

        var duplicateIEND = bytes
        duplicateIEND.append(contentsOf: bytes[iend.range])

        var nonterminalIEND = bytes
        nonterminalIEND.append(0x00)

        var nonzeroLengthIEND = bytes
        nonzeroLengthIEND.replaceSubrange(
            iend.lengthRange,
            with: [0x00, 0x00, 0x00, 0x01]
        )

        let invalidFixtures = [
            ("missing IEND", Data(missingIEND)),
            ("duplicate IEND", Data(duplicateIEND)),
            ("nonterminal IEND", Data(nonterminalIEND)),
            ("nonzero-length IEND", Data(nonzeroLengthIEND)),
        ]
        for (name, fixture) in invalidFixtures {
            assertRejectedRaster(fixture, message: name)
        }
    }

    func testRasterRenderPolicyUses085ScrimOnlyForVisibleRaster() throws {
        let raster = try tinyPNGData()
        let visible = ThemeRasterRenderPolicy.renderState(
            rasterData: raster,
            ornamentOpacity: 0.5,
            reduceTransparency: false
        )
        let transparentFallback = ThemeRasterRenderPolicy.renderState(
            rasterData: raster,
            ornamentOpacity: 0.5,
            reduceTransparency: true
        )
        let zeroOpacity = ThemeRasterRenderPolicy.renderState(
            rasterData: raster,
            ornamentOpacity: 0,
            reduceTransparency: false
        )

        XCTAssertNotNil(visible.rasterImage)
        XCTAssertEqual(visible.rasterOpacity, 0.5)
        XCTAssertEqual(visible.readabilityScrimOpacity, 0.85)
        for state in [transparentFallback, zeroOpacity] {
            XCTAssertNil(state.rasterImage)
            XCTAssertEqual(state.rasterOpacity, 0)
            XCTAssertEqual(state.readabilityScrimOpacity, 0)
        }
    }

    func testRasterRenderPolicyClampsVisibleOpacity() throws {
        let raster = try tinyPNGData()

        XCTAssertEqual(
            ThemeRasterRenderPolicy.renderState(
                rasterData: raster,
                ornamentOpacity: -1,
                reduceTransparency: false
            ).rasterOpacity,
            0
        )
        XCTAssertEqual(
            ThemeRasterRenderPolicy.renderState(
                rasterData: raster,
                ornamentOpacity: 2,
                reduceTransparency: false
            ).rasterOpacity,
            1
        )
    }

    func testOrbRasterUsesSharedDecodeAndEffectiveOpacityPolicy() throws {
        let raster = try tinyPNGData()
        let visible = ThemeRasterRenderPolicy.orbRenderState(
            rasterData: raster,
            ornamentOpacity: 0.7,
            reduceTransparency: false
        )
        let undecodable = ThemeRasterRenderPolicy.orbRenderState(
            rasterData: Data("not-an-image".utf8),
            ornamentOpacity: 0.7,
            reduceTransparency: false
        )

        XCTAssertEqual(visible.rasterOpacity, 0.28, accuracy: 0.000_001)
        XCTAssertEqual(visible.readabilityScrimOpacity, 0.85)
        XCTAssertEqual(undecodable.rasterOpacity, 0)
        XCTAssertEqual(undecodable.readabilityScrimOpacity, 0)
    }

    func testBuiltInRasterInfluenceMatchesReviewedCardAndOrbRanges() throws {
        let raster = try tinyPNGData()
        let cardInfluence = BuiltInThemes.all.map { builtIn in
            let state = ThemeRasterRenderPolicy.renderState(
                rasterData: raster,
                ornamentOpacity: builtIn.document.ornamentOpacity,
                reduceTransparency: false
            )
            return state.rasterOpacity * (1 - state.readabilityScrimOpacity)
        }
        let orbInfluence = BuiltInThemes.all.map { builtIn in
            let state = ThemeRasterRenderPolicy.orbRenderState(
                rasterData: raster,
                ornamentOpacity: builtIn.document.ornamentOpacity,
                reduceTransparency: false
            )
            return state.rasterOpacity * (1 - state.readabilityScrimOpacity)
        }

        XCTAssertEqual(
            try XCTUnwrap(cardInfluence.min()),
            0.0375,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(cardInfluence.max()),
            0.105,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(orbInfluence.min()),
            0.015,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(orbInfluence.max()),
            0.042,
            accuracy: 0.000_001
        )
    }

    func testFocusRingConsumesSemanticFocusOnlyWhileFocused() throws {
        let resolved = try ThemeResolver().resolve(
            BuiltInThemes.cyberpunk.document,
            context: ThemeResolutionContext(
                appearance: .dark,
                accessibility: ThemeAccessibilityPreferences(
                    increaseContrast: false,
                    reduceTransparency: false,
                    reduceMotion: false,
                    textScale: 1
                )
            )
        ).get()

        XCTAssertNil(
            ThemeViewSupport.focusRingColor(in: resolved, isFocused: false)
        )
        XCTAssertEqual(
            ThemeViewSupport.focusRingColor(in: resolved, isFocused: true),
            resolved.palette.focus
        )
    }

    func testReduceTransparencyKeepsOpaqueSemanticBackgroundWithRaster() throws {
        let resolved = ThemeViewSupport.resolve(
            BuiltInThemes.glass.document,
            colorScheme: .light,
            increaseContrast: false,
            reduceTransparency: true,
            reduceMotion: false
        )

        XCTAssertEqual(
            resolved.background,
            .solid(resolved.palette.background.opaque)
        )
        XCTAssertEqual(
            ThemeRasterRenderPolicy.renderState(
                rasterData: try tinyPNGData(),
                ornamentOpacity: 1,
                reduceTransparency: true
            ).rasterOpacity,
            0
        )
    }

    func testDensityMetricsAreExplicitAndOrdered() {
        let system = ThemeViewSupport.densityMetrics(for: .system)
        let comfortable = ThemeViewSupport.densityMetrics(
            for: .comfortable
        )
        let compact = ThemeViewSupport.densityMetrics(for: .compact)

        XCTAssertGreaterThan(comfortable.cardPadding, system.cardPadding)
        XCTAssertGreaterThan(system.cardPadding, compact.cardPadding)
        XCTAssertGreaterThan(
            comfortable.sectionSpacing,
            system.sectionSpacing
        )
        XCTAssertGreaterThan(system.sectionSpacing, compact.sectionSpacing)
        XCTAssertGreaterThan(
            comfortable.windowSpacing,
            system.windowSpacing
        )
        XCTAssertGreaterThan(system.windowSpacing, compact.windowSpacing)
    }

    func testSixThemeProviderLayoutMatrixResolvesWithoutChangingPanelGeometry() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let profiles = DisplayProfile.allCases

        for builtIn in BuiltInThemes.all {
            for providerCount in 1...4 {
                let providers = Array(ProviderID.allCases.prefix(providerCount))
                let layout = PanelLayoutResolver.resolve(
                    providerCount: providerCount,
                    visibleFrame: visibleFrame
                )
                let expectedSize: CGSize = switch providerCount {
                case 1: CGSize(width: 272, height: 340)
                case 2: CGSize(width: 520, height: 340)
                case 3: CGSize(width: 768, height: 340)
                default: CGSize(width: 1_016, height: 340)
                }

                for density in AppearanceDensity.allCases {
                    let metrics = ThemeViewSupport.densityMetrics(for: density)
                    for profile in profiles {
                        for accessibility in [false, true] {
                            let context = "theme=\(builtIn.id.rawValue), providers=\(providerCount), density=\(density), profile=\(profile), accessibility=\(accessibility)"
                            let resolved = ThemeViewSupport.resolve(
                                builtIn.document,
                                colorScheme: accessibility ? .dark : .light,
                                increaseContrast: accessibility,
                                reduceTransparency: accessibility,
                                reduceMotion: accessibility
                            )
                            let dashboard = CardDashboardLayoutPresenter()
                                .makePresentation(
                                    enabledProviders: providers,
                                    panelLayout: layout,
                                    displayProfile: profile,
                                    usesAccessibilityTextSize: accessibility
                                )

                            XCTAssertEqual(
                                resolved.id,
                                builtIn.document.id,
                                context
                            )
                            XCTAssertEqual(layout.size, expectedSize, context)
                            XCTAssertFalse(layout.isConstrained, context)
                            XCTAssertEqual(
                                dashboard.orderedProviderIDs,
                                providers,
                                context
                            )
                            XCTAssertEqual(
                                dashboard.columns,
                                providerCount,
                                context
                            )
                            XCTAssertEqual(
                                dashboard.showsVerticalScrollIndicators,
                                profile == .full || accessibility,
                                context
                            )

                            for value in [
                                resolved.geometry.cornerRadius,
                                resolved.geometry.borderWidth,
                                resolved.geometry.shadowRadius,
                                resolved.geometry.materialOpacity,
                                resolved.ornamentOpacity,
                                Double(metrics.cardPadding),
                                Double(metrics.sectionSpacing),
                                Double(metrics.windowSpacing),
                                Double(metrics.inlineSpacing),
                                Double(layout.size.width),
                                Double(layout.size.height),
                            ] {
                                XCTAssertTrue(value.isFinite, context)
                                XCTAssertGreaterThanOrEqual(value, 0, context)
                            }
                            XCTAssertGreaterThan(layout.size.width, 0, context)
                            XCTAssertGreaterThan(layout.size.height, 0, context)
                        }
                    }
                }
            }
        }
    }

    func testRasterTileLayoutNeverUpsamplesBuiltInArtworkAtRetinaScale() {
        let rasterPixelSize = CGSize(width: 1_254, height: 1_254)
        let supportedPanelSizes = [
            CGSize(width: 272, height: 340),
            CGSize(width: 520, height: 340),
            CGSize(width: 768, height: 340),
            CGSize(width: 1_016, height: 340),
            CGSize(width: 520, height: 620),
        ]
        let expectedTileCounts = [
            (columns: 1, rows: 1),
            (columns: 1, rows: 1),
            (columns: 2, rows: 1),
            (columns: 2, rows: 1),
            (columns: 1, rows: 1),
        ]

        for (size, expected) in zip(
            supportedPanelSizes,
            expectedTileCounts
        ) {
            let layout = ThemeRasterTileLayout.resolve(
                for: size,
                rasterPixelSize: rasterPixelSize,
                displayScale: 2
            )

            XCTAssertEqual(layout.columns, expected.columns, "\(size)")
            XCTAssertEqual(layout.rows, expected.rows, "\(size)")
            XCTAssertLessThanOrEqual(
                layout.tileSize.width * layout.displayScale,
                rasterPixelSize.width,
                "\(size)"
            )
            XCTAssertLessThanOrEqual(
                layout.tileSize.height * layout.displayScale,
                rasterPixelSize.height,
                "\(size)"
            )
            XCTAssertEqual(
                layout.tileSize.width * CGFloat(layout.columns),
                size.width,
                accuracy: 0.000_001,
                "\(size)"
            )
            XCTAssertEqual(
                layout.tileSize.height * CGFloat(layout.rows),
                size.height,
                accuracy: 0.000_001,
                "\(size)"
            )
        }
    }

    func testRasterTileLayoutUsesActualPixelsAndNormalizesInvalidScale() {
        let surfaceSize = CGSize(width: 1_016, height: 700)
        let rasterPixelSize = CGSize(width: 1_254, height: 1_254)

        let oneX = ThemeRasterTileLayout.resolve(
            for: surfaceSize,
            rasterPixelSize: rasterPixelSize,
            displayScale: 1
        )
        let threeX = ThemeRasterTileLayout.resolve(
            for: surfaceSize,
            rasterPixelSize: rasterPixelSize,
            displayScale: 3
        )

        XCTAssertEqual(oneX.columns, 1)
        XCTAssertEqual(oneX.rows, 1)
        XCTAssertEqual(threeX.columns, 3)
        XCTAssertEqual(threeX.rows, 2)

        for invalidScale in [CGFloat.zero, -1, .nan, .infinity] {
            let layout = ThemeRasterTileLayout.resolve(
                for: surfaceSize,
                rasterPixelSize: rasterPixelSize,
                displayScale: invalidScale
            )

            XCTAssertEqual(layout.displayScale, 2)
            XCTAssertEqual(layout.columns, 2)
            XCTAssertEqual(layout.rows, 2)
        }
    }

    func testAllBuiltInRastersProvideTheirNativePixelDimensions() throws {
        let loader = BuiltInThemeArtworkLoader(
            bundle: try applicationBundle()
        )

        for theme in BuiltInThemes.all {
            let data = try XCTUnwrap(loader.data(for: theme.id))
            let renderState = ThemeRasterRenderPolicy.renderState(
                rasterData: data,
                ornamentOpacity: 1,
                reduceTransparency: false
            )
            let pixelSize = try XCTUnwrap(renderState.rasterPixelSize)

            XCTAssertEqual(pixelSize.width, 1_254, theme.id.rawValue)
            XCTAssertEqual(pixelSize.height, 1_254, theme.id.rawValue)
        }
    }

    func testOrbForegroundMeetsAAAgainstEverySemanticOrbBackground() throws {
        for builtIn in BuiltInThemes.all {
            for appearance in ThemeAppearance.allCases {
                let resolved = try ThemeResolver().resolve(
                    builtIn.document,
                    context: ThemeResolutionContext(
                        appearance: appearance,
                        accessibility: ThemeAccessibilityPreferences(
                            increaseContrast: false,
                            reduceTransparency: false,
                            reduceMotion: false,
                            textScale: 1
                        )
                    )
                ).get()
                let backgrounds = [
                    resolved.palette.accent,
                    resolved.palette.healthy,
                    resolved.palette.warning,
                    resolved.palette.critical,
                ]

                for background in backgrounds {
                    let foreground = ThemeViewSupport
                        .contrastingActionForeground(for: background)
                    XCTAssertGreaterThanOrEqual(
                        foreground.contrastRatio(against: background),
                        4.5,
                        "\(builtIn.id.rawValue) \(appearance.rawValue)"
                    )
                }
            }
        }
    }

    func testDebugMatrixUsesCanonicalThemeIDsAndResolvableRealTokens() {
        XCTAssertEqual(
            DebugThemeStatePreviewMatrix.themeIDs,
            BuiltInThemeID.allCases.map(\.rawValue)
        )
        XCTAssertEqual(DebugThemeStatePreviewMatrix.all.count, 36)

        for item in DebugThemeStatePreviewMatrix.all {
            let builtIn = ThemeViewSupport.builtInTheme(for: item.themeID)
            let resolved = ThemeViewSupport.resolve(
                builtIn.document,
                colorScheme: .dark,
                increaseContrast: true,
                reduceTransparency: true,
                reduceMotion: true
            )

            XCTAssertEqual(resolved.id, builtIn.document.id)
            XCTAssertEqual(
                item.state.themeAvailabilityState,
                expectedAvailability(for: item.state)
            )
        }
    }

    @MainActor
    func testThemePreviewAndQuotaViewsAcceptResolvedThemeDocuments() {
        let localizationModel = AppLocalizationRuntimeModel(
            language: .english,
            systemLocale: Locale(identifier: "en_US")
        )
        _ = ThemePreviewView(
            theme: BuiltInThemes.glass.document,
            availability: .stale,
            health: .warning,
            localizationModel: localizationModel
        )
        _ = OrbView(
            state: .loading,
            theme: BuiltInThemes.cyberpunk.document,
            toggleExpanded: {}
        )
        _ = CardView(
            viewModel: DebugQuotaFixture.loading.makeViewModel(),
            theme: BuiltInThemes.sketch.document,
            quit: {}
        )
    }

    @MainActor
    func testEditorCopyMapsEveryVisibleRoleToStableCatalogKeys() {
        let copy = ThemeEditorCopy(text: keyEchoProvider())

        XCTAssertEqual(copy.title, "theme.editor.title")
        XCTAssertEqual(copy.name, "theme.editor.name")
        XCTAssertEqual(copy.duplicateName, "theme.editor.duplicate_name")
        XCTAssertEqual(
            copy.duplicateDefaultName(for: "Demo"),
            "theme.editor.duplicate_default_name:Demo"
        )
        XCTAssertEqual(
            ThemeEditorBackgroundKind.allCases.map(copy.backgroundKind),
            [
                "theme.editor.background.solid",
                "theme.editor.background.gradient",
                "theme.editor.background.system_material",
            ]
        )
        XCTAssertEqual(
            SystemThemeMaterial.allCases.map(copy.material),
            [
                "theme.editor.material.ultra_thin",
                "theme.editor.material.thin",
                "theme.editor.material.regular",
                "theme.editor.material.thick",
                "theme.editor.material.ultra_thick",
            ]
        )
        XCTAssertEqual(
            ThemeEditorColorRole.allCases.map(copy.colorRole),
            [
                "theme.editor.color.background",
                "theme.editor.color.primary_text",
                "theme.editor.color.secondary_text",
                "theme.editor.color.accent",
                "theme.editor.color.healthy",
                "theme.editor.color.warning",
                "theme.editor.color.critical",
                "theme.editor.color.stale",
                "theme.editor.color.unavailable",
                "theme.editor.color.border",
                "theme.editor.color.focus_ring",
            ]
        )
        XCTAssertEqual(
            ThemeEditorNumericField.allCases.map(copy.numericField),
            [
                "theme.editor.geometry.corner_radius",
                "theme.editor.geometry.border_width",
                "theme.editor.geometry.shadow_radius",
                "theme.editor.geometry.material_opacity",
                "theme.editor.geometry.decorative_opacity",
            ]
        )
        XCTAssertEqual(
            [
                copy.solidColorPlaceholder,
                copy.gradientStopsPlaceholder,
                copy.colorHexPlaceholder,
                copy.rasterNone,
                copy.rasterSanitized,
                copy.rasterPolicy,
                copy.resetToBuiltIn,
                copy.cancel,
                copy.save,
                copy.saveAndApply,
            ],
            [
                "theme.editor.placeholder.solid_color",
                "theme.editor.placeholder.gradient_stops",
                "theme.editor.placeholder.color_hex",
                "theme.editor.raster.none",
                "theme.editor.raster.sanitized",
                "theme.editor.raster.policy",
                "theme.editor.reset_to_builtin",
                "action.cancel",
                "action.save",
                "action.save_and_apply",
            ]
        )
    }

    @MainActor
    func testPreviewCopyUsesWholeAccessibilityWrappersAndStableStates() {
        let copy = ThemePreviewCopy(text: keyEchoProvider())

        XCTAssertEqual(
            ThemeAvailabilityState.allCases.map(copy.availability),
            [
                "theme.state.availability.loading",
                "theme.state.availability.fresh",
                "theme.state.availability.partial",
                "theme.state.availability.stale",
                "theme.state.availability.unsupported",
                "theme.state.availability.unavailable",
            ]
        )
        XCTAssertEqual(copy.health(.healthy), "theme.state.health.healthy")
        XCTAssertEqual(copy.health(.warning), "theme.state.health.warning")
        XCTAssertEqual(copy.health(.critical), "theme.state.health.critical")
        XCTAssertEqual(copy.health(nil), "common.state.unknown")
        XCTAssertEqual(
            copy.accessibilityLabel(
                themeName: "Demo",
                availability: .stale
            ),
            "preview-label:Demo|theme.state.availability.stale"
        )
        XCTAssertEqual(
            copy.accessibilityValue(
                previewValue: "31%",
                health: .warning
            ),
            "preview-value:31%|theme.state.health.warning"
        )
    }

    @MainActor
    func testBalancedDashboardActuallyFitsAllLocalesThemesAndProviderCounts()
        throws
    {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let viewModel = DebugQuotaFixture.loadedGreen.makeViewModel(now: now)
        let artwork = BuiltInThemeArtworkLoader(
            bundle: try applicationBundle()
        )
        let states: [ProviderID: ProviderPresentationState] = [
            .codex: .loading,
            .claudeCode: .fresh(try XCTUnwrap(ProviderSnapshot(
                providerID: .claudeCode,
                metrics: [],
                capturedAt: now
            ))),
            .googleAntigravity: .fresh(try XCTUnwrap(ProviderSnapshot(
                providerID: .googleAntigravity,
                metrics: [],
                capturedAt: now,
                runtimePresence: .application(
                    installed: false,
                    running: false
                )
            ))),
            .kimiCode: .notConnected,
        ]
        let providerOrder: [ProviderID] = [
            .codex,
            .claudeCode,
            .googleAntigravity,
            .kimiCode,
        ]
        let languages = AppLanguage.allCases.filter { $0 != .system }
        let window = NSWindow(
            contentRect: .zero,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let hosting = NSHostingView(rootView: AnyView(EmptyView()))
        hosting.sizingOptions = []
        window.contentView = hosting

        for language in languages {
            let text = LocalizedTextProvider(
                language: language,
                systemLocale: Locale(identifier: "en_US")
            )
            for builtIn in BuiltInThemes.all {
                let raster = try XCTUnwrap(
                    artwork.data(for: builtIn.id),
                    "Missing raster for \(builtIn.id.rawValue)"
                )
                for providerCount in 1...4 {
                    let providers = Array(providerOrder.prefix(providerCount))
                    let layout = PanelLayoutResolver.resolve(
                        providerCount: providerCount,
                        visibleFrame: CGRect(
                            x: 0,
                            y: 0,
                            width: 1_440,
                            height: 900
                        )
                    )
                    let input = ProviderCardDashboardInput(
                        enabledProviders: providers,
                        statesByProvider: states,
                        primaryMetricPreferences: [:],
                        codexQuotaState: viewModel.state
                    )
                    let context = "language=\(language.rawValue), theme=\(builtIn.id.rawValue), providers=\(providerCount)"
                    hosting.rootView = AnyView(
                        CardView(
                            viewModel: viewModel,
                            dashboardInput: input,
                            panelLayout: layout,
                            displayProfile: .balanced,
                            percentageMode: .remaining,
                            theme: builtIn.document,
                            rasterData: raster,
                            text: text,
                            quit: {},
                            now: { now }
                        )
                        .environment(\.dynamicTypeSize, .medium)
                        .environment(
                            \.themeDensityMetrics,
                            ThemeViewSupport.densityMetrics(for: .system)
                        )
                    )
                    window.setContentSize(layout.size)
                    hosting.frame = CGRect(origin: .zero, size: layout.size)
                    hosting.layoutSubtreeIfNeeded()
                    hosting.displayIfNeeded()

                    if language == .traditionalChinese,
                       providerCount == 3 || providerCount == 4
                    {
                        try attachRenderedDashboard(
                            hosting,
                            name: "dashboard-\(builtIn.id.rawValue)-\(providerCount)-providers"
                        )
                    }

                    let scrollViews = descendantScrollViews(in: hosting)
                    XCTAssertEqual(scrollViews.count, 1, context)
                    guard let scrollView = scrollViews.first,
                          let documentView = scrollView.documentView
                    else {
                        continue
                    }
                    XCTAssertLessThanOrEqual(
                        documentView.frame.height,
                        scrollView.contentView.bounds.height + 1,
                        "Vertical overflow: \(context), content=\(documentView.frame.height), viewport=\(scrollView.contentView.bounds.height)"
                    )
                    XCTAssertLessThanOrEqual(
                        documentView.frame.width,
                        scrollView.contentView.bounds.width + 1,
                        "Horizontal overflow: \(context), content=\(documentView.frame.width), viewport=\(scrollView.contentView.bounds.width)"
                    )
                }
            }
        }
    }

    @MainActor
    private func descendantScrollViews(in view: NSView) -> [NSScrollView] {
        let own = (view as? NSScrollView).map { [$0] } ?? []
        return own + view.subviews.flatMap(descendantScrollViews)
    }

    @MainActor
    private func attachRenderedDashboard(
        _ view: NSView,
        name: String
    ) throws {
        let representation = try XCTUnwrap(
            view.bitmapImageRepForCachingDisplay(in: view.bounds)
        )
        view.cacheDisplay(in: view.bounds, to: representation)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(representation)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func keyEchoProvider() -> LocalizedTextProvider {
        LocalizedTextProvider(locale: .english) { key, _ in
            switch key {
            case .themeEditorDuplicateDefaultName:
                "theme.editor.duplicate_default_name:%@"
            case .themeEditorPreviewAccessibilityLabel:
                "preview-label:%1$@|%2$@"
            case .themeEditorPreviewAccessibilityValue:
                "preview-value:%1$@|%2$@"
            default:
                key.rawValue
            }
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

    private struct PNGFixtureChunk {
        let type: String
        let range: Range<Int>
        let lengthRange: Range<Int>
        let dataRange: Range<Int>
        let crcRange: Range<Int>
    }

    private enum PNGFixtureError: Error {
        case malformedSource
    }

    private func assertAcceptedRaster(
        _ data: Data,
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let state = ThemeRasterRenderPolicy.renderState(
            rasterData: data,
            ornamentOpacity: 1,
            reduceTransparency: false
        )
        XCTAssertNotNil(state.rasterImage, message, file: file, line: line)
        XCTAssertEqual(state.rasterOpacity, 1, message, file: file, line: line)
        XCTAssertEqual(
            state.readabilityScrimOpacity,
            0.85,
            message,
            file: file,
            line: line
        )
    }

    private func assertRejectedRaster(
        _ data: Data,
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let state = ThemeRasterRenderPolicy.renderState(
            rasterData: data,
            ornamentOpacity: 1,
            reduceTransparency: false
        )
        XCTAssertNil(state.rasterImage, message, file: file, line: line)
        XCTAssertEqual(state.rasterOpacity, 0, message, file: file, line: line)
        XCTAssertEqual(
            state.readabilityScrimOpacity,
            0,
            message,
            file: file,
            line: line
        )
    }

    private func pngFixtureChunks(in data: Data) throws -> [PNGFixtureChunk] {
        let bytes = [UInt8](data)
        guard bytes.count >= 8 else {
            throw PNGFixtureError.malformedSource
        }

        var offset = 8
        var chunks: [PNGFixtureChunk] = []
        while offset < bytes.count {
            guard bytes.count - offset >= 12 else {
                throw PNGFixtureError.malformedSource
            }
            let length = Int(
                UInt32(bytes[offset]) << 24
                    | UInt32(bytes[offset + 1]) << 16
                    | UInt32(bytes[offset + 2]) << 8
                    | UInt32(bytes[offset + 3])
            )
            let typeStart = offset + 4
            let dataStart = offset + 8
            guard length <= bytes.count - dataStart - 4 else {
                throw PNGFixtureError.malformedSource
            }
            let crcStart = dataStart + length
            let end = crcStart + 4
            guard
                let type = String(
                    bytes: bytes[typeStart..<(typeStart + 4)],
                    encoding: .ascii
                )
            else {
                throw PNGFixtureError.malformedSource
            }
            chunks.append(
                PNGFixtureChunk(
                    type: type,
                    range: offset..<end,
                    lengthRange: offset..<(offset + 4),
                    dataRange: dataStart..<crcStart,
                    crcRange: crcStart..<end
                )
            )
            offset = end
        }
        return chunks
    }

    private func tinyPNGData(alpha: CGFloat = 1) throws -> Data {
        let colorSpace = try XCTUnwrap(
            CGColorSpace(name: CGColorSpace.sRGB)
        )
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(
            CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: alpha)
        )
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let image = try XCTUnwrap(context.makeImage())
        return try XCTUnwrap(
            NSBitmapImageRep(cgImage: image).representation(
                using: .png,
                properties: [:]
            )
        )
    }

    private func expectedAvailability(
        for state: DebugThemePreviewState
    ) -> ThemeAvailabilityState {
        switch state {
        case .loading: .loading
        case .fresh: .fresh
        case .partial: .partial
        case .stale: .stale
        case .unsupported: .unsupported
        case .error: .unavailable
        }
    }
}
