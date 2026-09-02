import AppKit
import Foundation
import ImageIO
import SwiftUI

struct ThemeDensityMetrics: Equatable, Sendable {
    let cardPadding: CGFloat
    let sectionSpacing: CGFloat
    let windowSpacing: CGFloat
    let inlineSpacing: CGFloat

    static let system = ThemeDensityMetrics(
        cardPadding: 16,
        sectionSpacing: 12,
        windowSpacing: 5,
        inlineSpacing: 8
    )
}

private struct ThemeDensityMetricsKey: EnvironmentKey {
    static let defaultValue = ThemeDensityMetrics.system
}

extension EnvironmentValues {
    var themeDensityMetrics: ThemeDensityMetrics {
        get { self[ThemeDensityMetricsKey.self] }
        set { self[ThemeDensityMetricsKey.self] = newValue }
    }
}

enum ThemeViewSupport {
    static func preferredColorScheme(
        for value: AppearanceColorScheme
    ) -> ColorScheme? {
        switch value {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    static func densityMetrics(
        for value: AppearanceDensity
    ) -> ThemeDensityMetrics {
        switch value {
        case .system:
            .system
        case .comfortable:
            ThemeDensityMetrics(
                cardPadding: 18,
                sectionSpacing: 14,
                windowSpacing: 7,
                inlineSpacing: 10
            )
        case .compact:
            ThemeDensityMetrics(
                cardPadding: 12,
                sectionSpacing: 8,
                windowSpacing: 3,
                inlineSpacing: 6
            )
        }
    }

    static func builtInTheme(for persistedID: String?) -> BuiltInTheme {
        let normalizedID: BuiltInThemeID?
        switch persistedID {
        case "warm-illustration":
            normalizedID = .warmHandDrawn
        case "cartoon":
            normalizedID = .cartoonIllustration
        case let id?:
            normalizedID = BuiltInThemeID(rawValue: id)
        case nil:
            normalizedID = nil
        }
        return BuiltInThemes.all.first { $0.id == normalizedID }
            ?? BuiltInThemes.morandi
    }

    static func resolutionContext(
        colorScheme: ColorScheme,
        increaseContrast: Bool,
        reduceTransparency: Bool,
        reduceMotion: Bool
    ) -> ThemeResolutionContext {
        ThemeResolutionContext(
            appearance: colorScheme == .dark ? .dark : .light,
            accessibility: ThemeAccessibilityPreferences(
                increaseContrast: increaseContrast,
                reduceTransparency: reduceTransparency,
                reduceMotion: reduceMotion,
                textScale: 1
            )
        )
    }

    static func resolve(
        _ document: ThemeDocument,
        colorScheme: ColorScheme,
        increaseContrast: Bool,
        reduceTransparency: Bool,
        reduceMotion: Bool
    ) -> ResolvedTheme {
        let context = resolutionContext(
            colorScheme: colorScheme,
            increaseContrast: increaseContrast,
            reduceTransparency: reduceTransparency,
            reduceMotion: reduceMotion
        )
        if case let .success(theme) = ThemeResolver().resolve(
            document,
            context: context
        ) {
            return theme
        }
        return try! ThemeResolver().resolve(
            BuiltInThemes.morandi.document,
            context: context
        ).get()
    }

    static func availabilityState(
        for state: QuotaState
    ) -> ThemeAvailabilityState {
        switch state {
        case .loading:
            .loading
        case .loaded:
            .fresh
        case .stale:
            .stale
        case let .unavailable(reason):
            switch reason {
            case .versionUnsupported, .unsupportedAuthMode:
                .unsupported
            case .binaryNotFound, .trustValidationFailed,
                 .processLaunchFailed, .processExited, .noWindows,
                 .schemaChanged, .timeout, .transportError,
                 .authenticationRequired, .backendUnavailable,
                 .serverRejected, .staleDataUnavailable:
                .unavailable
            }
        }
    }

    static func healthState(for health: OrbHealth) -> ThemeHealthState? {
        switch health {
        case .healthy: .healthy
        case .warning: .warning
        case .critical: .critical
        case .neutral: nil
        }
    }

    static func color(
        for health: ThemeHealthState,
        in theme: ResolvedTheme
    ) -> Color {
        switch health {
        case .healthy: Color(themeColor: theme.palette.healthy)
        case .warning: Color(themeColor: theme.palette.warning)
        case .critical: Color(themeColor: theme.palette.critical)
        }
    }

    static func contrastingActionForeground(
        for background: ResolvedThemeColor
    ) -> ResolvedThemeColor {
        let blackRatio = ResolvedThemeColor.black.contrastRatio(
            against: background
        )
        let whiteRatio = ResolvedThemeColor.white.contrastRatio(
            against: background
        )
        return blackRatio >= whiteRatio ? .black : .white
    }

    static func focusRingColor(
        in theme: ResolvedTheme,
        isFocused: Bool
    ) -> ResolvedThemeColor? {
        isFocused ? theme.palette.focus : nil
    }

    static func strokeStyle(
        for stroke: ThemeCueStroke,
        lineWidth: CGFloat
    ) -> StrokeStyle {
        switch stroke {
        case .solid:
            StrokeStyle(lineWidth: lineWidth)
        case .dashed:
            StrokeStyle(lineWidth: lineWidth, dash: [6, 3])
        case .dotted:
            StrokeStyle(lineWidth: lineWidth, dash: [1, 3])
        case .dotDash:
            StrokeStyle(lineWidth: lineWidth, dash: [1, 3, 7, 3])
        case .doubleLine:
            StrokeStyle(lineWidth: max(2, lineWidth), dash: [9, 2])
        case .heavy:
            StrokeStyle(lineWidth: max(3, lineWidth))
        }
    }

    static func patternSymbol(for pattern: ThemeCuePattern) -> String {
        switch pattern {
        case .waves: "water.waves"
        case .grid: "square.grid.3x3"
        case .split: "circle.lefthalf.filled"
        case .diagonalStripes: "line.diagonal"
        case .crosshatch: "number"
        case .checkerboard: "checkerboard.rectangle"
        case .rings: "circle.circle"
        case .dots: "circle.grid.2x2"
        case .alertBands: "exclamationmark.triangle"
        }
    }
}

struct ThemeRasterRenderState {
    let rasterImage: NSImage?
    let rasterPixelSize: CGSize?
    let rasterOpacity: Double
    let readabilityScrimOpacity: Double
}

final class ThemeRasterImageCache: @unchecked Sendable {
    static let productionTotalCostLimit = 96 * 1_024 * 1_024

    private final class Entry {
        let image: NSImage?
        let cost: Int
        var accessSequence: UInt64

        init(image: NSImage?, cost: Int, accessSequence: UInt64) {
            self.image = image
            self.cost = cost
            self.accessSequence = accessSequence
        }
    }

    private var entries: [Data: Entry] = [:]
    private let countLimit: Int
    private let totalCostLimit: Int
    private var currentCost = 0
    private var accessSequence: UInt64 = 0
    private let lock = NSLock()
    private let decoder: (Data) -> NSImage?

    init(
        countLimit: Int,
        totalCostLimit: Int,
        decoder: @escaping (Data) -> NSImage?
    ) {
        self.countLimit = max(0, countLimit)
        self.totalCostLimit = max(0, totalCostLimit)
        self.decoder = decoder
    }

    func image(for data: Data) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }

        if let entry = entries[data] {
            accessSequence += 1
            entry.accessSequence = accessSequence
            return entry.image
        }

        let image = decoder(data)
        let cost = cacheCost(for: data, image: image)
        guard countLimit > 0, cost <= totalCostLimit else {
            return image
        }

        while entries.count >= countLimit
            || currentCost > totalCostLimit - cost
        {
            guard let oldest = entries.min(by: {
                $0.value.accessSequence < $1.value.accessSequence
            }) else {
                break
            }
            currentCost -= oldest.value.cost
            entries.removeValue(forKey: oldest.key)
        }

        accessSequence += 1
        entries[data] = Entry(
            image: image,
            cost: cost,
            accessSequence: accessSequence
        )
        currentCost += cost
        return image
    }

    private func cacheCost(for data: Data, image: NSImage?) -> Int {
        guard
            let image,
            image.size.width > 0,
            image.size.height > 0
        else {
            return data.count
        }

        let width = Int(image.size.width)
        let height = Int(image.size.height)
        let (pixelCount, pixelCountOverflow) = width
            .multipliedReportingOverflow(by: height)
        let (decodedByteCount, byteCountOverflow) = pixelCount
            .multipliedReportingOverflow(by: 4)
        guard !pixelCountOverflow, !byteCountOverflow else {
            return Int.max
        }
        let (combinedByteCount, combinedByteCountOverflow) = data.count
            .addingReportingOverflow(decodedByteCount)
        guard !combinedByteCountOverflow else {
            return Int.max
        }
        return combinedByteCount
    }
}

enum ThemeRasterRenderPolicy {
    private static let rasterImageCache = ThemeRasterImageCache(
        countLimit: 12,
        totalCostLimit: ThemeRasterImageCache.productionTotalCostLimit
    ) { data in
        decodedRasterImage(from: data)
    }
    private static let pngSignature: [UInt8] = [
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
    ]
    private static let ihdrChunkType: UInt32 = 0x4948_4452
    private static let idatChunkType: UInt32 = 0x4944_4154
    private static let iendChunkType: UInt32 = 0x4945_4e44
    private static let crc32Table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            crc = (crc & 1) == 1
                ? (crc >> 1) ^ 0xedb8_8320
                : crc >> 1
        }
        return crc
    }

    static func renderState(
        rasterData: Data?,
        ornamentOpacity: Double,
        reduceTransparency: Bool
    ) -> ThemeRasterRenderState {
        let rasterOpacity = clamped(ornamentOpacity)
        guard
            rasterOpacity > 0,
            !reduceTransparency,
            let rasterData,
            let rasterImage = rasterImageCache.image(for: rasterData)
        else {
            return ThemeRasterRenderState(
                rasterImage: nil,
                rasterPixelSize: nil,
                rasterOpacity: 0,
                readabilityScrimOpacity: 0
            )
        }
        return ThemeRasterRenderState(
            rasterImage: rasterImage,
            rasterPixelSize: decodedRasterPixelSize(in: rasterData),
            rasterOpacity: rasterOpacity,
            readabilityScrimOpacity: 0.85
        )
    }

    static func orbRenderState(
        rasterData: Data?,
        ornamentOpacity: Double,
        reduceTransparency: Bool
    ) -> ThemeRasterRenderState {
        renderState(
            rasterData: rasterData,
            ornamentOpacity: clamped(ornamentOpacity) * 0.4,
            reduceTransparency: reduceTransparency
        )
    }

    private static func clamped(_ opacity: Double) -> Double {
        min(1, max(0, opacity))
    }

    private static func decodedRasterPixelSize(in data: Data) -> CGSize? {
        data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            guard bytes.count >= 24 else {
                return nil
            }
            let width = bigEndianUInt32(bytes, at: 16)
            let height = bigEndianUInt32(bytes, at: 20)
            guard width > 0, height > 0 else {
                return nil
            }
            return CGSize(width: Int(width), height: Int(height))
        }
    }

    private static func decodedRasterImage(from data: Data) -> NSImage? {
        guard
            isStrictPNG(data),
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetStatus(source) == .statusComplete,
            CGImageSourceGetCount(source) == 1,
            let image = CGImageSourceCreateImageAtIndex(
                source,
                0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            ),
            image.width > 0,
            image.height > 0
        else {
            return nil
        }

        return NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        )
    }

    private static func isStrictPNG(_ data: Data) -> Bool {
        data.withUnsafeBytes { rawBuffer -> Bool in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            guard bytes.count >= pngSignature.count else {
                return false
            }
            for (index, expectedByte) in pngSignature.enumerated() {
                guard bytes[index] == expectedByte else {
                    return false
                }
            }

            var offset = pngSignature.count
            var sawIHDR = false
            var sawIDAT = false
            var sawIEND = false

            while offset < bytes.count {
                guard bytes.count - offset >= 12 else {
                    return false
                }

                let length = Int(bigEndianUInt32(bytes, at: offset))
                let typeOffset = offset + 4
                let dataOffset = offset + 8
                let remainingAfterHeader = bytes.count - dataOffset
                guard length <= remainingAfterHeader - 4 else {
                    return false
                }

                let crcOffset = dataOffset + length
                let nextOffset = crcOffset + 4
                let type = bigEndianUInt32(bytes, at: typeOffset)
                let expectedCRC = bigEndianUInt32(bytes, at: crcOffset)
                guard
                    crc32(bytes, in: typeOffset..<crcOffset) == expectedCRC
                else {
                    return false
                }

                if !sawIHDR, type != ihdrChunkType {
                    return false
                }

                switch type {
                case ihdrChunkType:
                    guard !sawIHDR, offset == pngSignature.count, length == 13
                    else {
                        return false
                    }
                    sawIHDR = true
                case idatChunkType:
                    sawIDAT = true
                case iendChunkType:
                    guard
                        !sawIEND,
                        sawIDAT,
                        length == 0,
                        nextOffset == bytes.count
                    else {
                        return false
                    }
                    sawIEND = true
                default:
                    break
                }

                offset = nextOffset
            }

            return sawIHDR && sawIDAT && sawIEND
        }
    }

    private static func bigEndianUInt32(
        _ bytes: UnsafeBufferPointer<UInt8>,
        at offset: Int
    ) -> UInt32 {
        UInt32(bytes[offset]) << 24
            | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8
            | UInt32(bytes[offset + 3])
    }

    private static func crc32(
        _ bytes: UnsafeBufferPointer<UInt8>,
        in range: Range<Int>
    ) -> UInt32 {
        var crc = UInt32.max
        for index in range {
            let tableIndex = Int((crc ^ UInt32(bytes[index])) & 0xff)
            crc = (crc >> 8) ^ crc32Table[tableIndex]
        }
        return crc ^ UInt32.max
    }
}

extension Color {
    init(themeColor: ResolvedThemeColor) {
        self.init(
            .sRGB,
            red: Double(themeColor.red) / 255,
            green: Double(themeColor.green) / 255,
            blue: Double(themeColor.blue) / 255,
            opacity: Double(themeColor.alpha) / 255
        )
    }
}

struct ThemeSurfaceView: View {
    let theme: ResolvedTheme
    let rasterData: Data?
    let reduceTransparency: Bool

    init(
        theme: ResolvedTheme,
        rasterData: Data? = nil,
        reduceTransparency: Bool = false
    ) {
        self.theme = theme
        self.rasterData = rasterData
        self.reduceTransparency = reduceTransparency
    }

    var body: some View {
        let rasterState = ThemeRasterRenderPolicy.renderState(
            rasterData: rasterData,
            ornamentOpacity: theme.ornamentOpacity,
            reduceTransparency: reduceTransparency
        )

        ZStack {
            baseSurface
            ThemeRasterOrnamentView(
                renderState: rasterState
            )
            if rasterState.readabilityScrimOpacity > 0 {
                Color(themeColor: theme.palette.background)
                    .opacity(rasterState.readabilityScrimOpacity)
                    .allowsHitTesting(false)
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var baseSurface: some View {
        switch theme.background {
        case let .solid(color):
            Color(themeColor: color)
        case let .boundedGradient(colors):
            LinearGradient(
                colors: colors.map(Color.init(themeColor:)),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case let .systemMaterial(material):
            Rectangle()
                .fill(swiftUIMaterial(material))
                .overlay(
                    Color(themeColor: theme.palette.background)
                        .opacity(1 - theme.geometry.materialOpacity)
                )
        }
    }

    private func swiftUIMaterial(_ material: SystemThemeMaterial) -> Material {
        switch material {
        case .ultraThin: .ultraThinMaterial
        case .thin: .thinMaterial
        case .regular: .regularMaterial
        case .thick: .thickMaterial
        case .ultraThick: .ultraThickMaterial
        }
    }
}

struct ThemeRasterOrnamentView: View {
    let renderState: ThemeRasterRenderState
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if
                renderState.rasterOpacity > 0,
                let rasterImage = renderState.rasterImage,
                let rasterPixelSize = renderState.rasterPixelSize
            {
                GeometryReader { proxy in
                    let layout = ThemeRasterTileLayout.resolve(
                        for: proxy.size,
                        rasterPixelSize: rasterPixelSize,
                        displayScale: displayScale
                    )

                    VStack(spacing: 0) {
                        ForEach(0..<layout.rows, id: \.self) { row in
                            HStack(spacing: 0) {
                                ForEach(
                                    0..<layout.columns,
                                    id: \.self
                                ) { column in
                                    Image(nsImage: rasterImage)
                                        .resizable()
                                        .interpolation(.high)
                                        .scaledToFill()
                                        .frame(
                                            width: layout.tileSize.width,
                                            height: layout.tileSize.height
                                        )
                                        .clipped()
                                        .scaleEffect(
                                            x: column.isMultiple(of: 2)
                                                ? 1 : -1,
                                            y: row.isMultiple(of: 2)
                                                ? 1 : -1
                                        )
                                }
                            }
                            .frame(height: layout.tileSize.height)
                        }
                    }
                    .frame(
                        width: proxy.size.width,
                        height: proxy.size.height
                    )
                    .clipped()
                    .opacity(renderState.rasterOpacity)
                }
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

struct ThemeRasterTileLayout: Equatable, Sendable {
    private static let fallbackDisplayScale: CGFloat = 2

    let columns: Int
    let rows: Int
    let tileSize: CGSize
    let displayScale: CGFloat

    static func resolve(
        for surfaceSize: CGSize,
        rasterPixelSize: CGSize,
        displayScale: CGFloat
    ) -> ThemeRasterTileLayout {
        let effectiveScale = displayScale.isFinite && displayScale > 0
            ? displayScale
            : fallbackDisplayScale
        let maximumTileSize = CGSize(
            width: max(1, rasterPixelSize.width / effectiveScale),
            height: max(1, rasterPixelSize.height / effectiveScale)
        )
        let columns = max(
            1,
            Int((max(0, surfaceSize.width) / maximumTileSize.width)
                .rounded(.up))
        )
        let rows = max(
            1,
            Int((max(0, surfaceSize.height) / maximumTileSize.height)
                .rounded(.up))
        )

        return ThemeRasterTileLayout(
            columns: columns,
            rows: rows,
            tileSize: CGSize(
                width: surfaceSize.width / CGFloat(columns),
                height: surfaceSize.height / CGFloat(rows)
            ),
            displayScale: effectiveScale
        )
    }
}
