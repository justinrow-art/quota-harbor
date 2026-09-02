#!/usr/bin/env swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

private struct ArtworkSpec {
    let sourceName: String
    let outputName: String
}

private enum PreparationError: Error, CustomStringConvertible {
    case invalidSource(String)
    case unsupportedFrameCount(String, Int)
    case cannotCreateSRGBContext(String)
    case cannotEncode(String)

    var description: String {
        switch self {
        case let .invalidSource(name):
            "Cannot decode source artwork: \(name)"
        case let .unsupportedFrameCount(name, count):
            "Source artwork must contain exactly one frame: \(name) has \(count)"
        case let .cannotCreateSRGBContext(name):
            "Cannot create sRGB image context for: \(name)"
        case let .cannotEncode(name):
            "Cannot encode PNG artwork: \(name)"
        }
    }
}

private let artwork = [
    ArtworkSpec(
        sourceName: "01-morandi.png",
        outputName: "theme-morandi-background.png"
    ),
    ArtworkSpec(
        sourceName: "02-cyberpunk.png",
        outputName: "theme-cyberpunk-background.png"
    ),
    ArtworkSpec(
        sourceName: "03-warm-hand-drawn.png",
        outputName: "theme-warm-hand-drawn-background.png"
    ),
    ArtworkSpec(
        sourceName: "04-glass.png",
        outputName: "theme-glass-background.png"
    ),
    ArtworkSpec(
        sourceName: "05-sketch.png",
        outputName: "theme-sketch-background.png"
    ),
    ArtworkSpec(
        sourceName: "06-cartoon.png",
        outputName: "theme-cartoon-illustration-background.png"
    ),
]

private func reencodeSRGBPNG(from sourceURL: URL) throws -> Data {
    guard let source = CGImageSourceCreateWithURL(
        sourceURL as CFURL,
        [kCGImageSourceShouldCache: false] as CFDictionary
    ) else {
        throw PreparationError.invalidSource(sourceURL.lastPathComponent)
    }
    let frameCount = CGImageSourceGetCount(source)
    guard frameCount == 1 else {
        throw PreparationError.unsupportedFrameCount(
            sourceURL.lastPathComponent,
            frameCount
        )
    }
    guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw PreparationError.invalidSource(sourceURL.lastPathComponent)
    }
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
              data: nil,
              width: image.width,
              height: image.height,
              bitsPerComponent: 8,
              bytesPerRow: image.width * 4,
              space: colorSpace,
              bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                  | CGImageAlphaInfo.premultipliedLast.rawValue
          )
    else {
        throw PreparationError.cannotCreateSRGBContext(
            sourceURL.lastPathComponent
        )
    }

    context.setBlendMode(.copy)
    context.draw(
        image,
        in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
    )
    guard let normalizedImage = context.makeImage() else {
        throw PreparationError.cannotCreateSRGBContext(
            sourceURL.lastPathComponent
        )
    }

    let encoded = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        encoded,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        throw PreparationError.cannotEncode(sourceURL.lastPathComponent)
    }
    let properties: [CFString: Any] = [
        kCGImagePropertyPNGDictionary: [
            kCGImagePropertyPNGInterlaceType: 0,
        ],
    ]
    CGImageDestinationAddImage(
        destination,
        normalizedImage,
        properties as CFDictionary
    )
    guard CGImageDestinationFinalize(destination) else {
        throw PreparationError.cannotEncode(sourceURL.lastPathComponent)
    }
    return encoded as Data
}

let root = URL(
    fileURLWithPath: FileManager.default.currentDirectoryPath,
    isDirectory: true
)
let sourceDirectory = root.appendingPathComponent(
    "artwork/source-masters",
    isDirectory: true
)
let outputDirectory = root.appendingPathComponent(
    "CodexQuotaMonitor/Resources/ThemeArtwork",
    isDirectory: true
)
try FileManager.default.createDirectory(
    at: outputDirectory,
    withIntermediateDirectories: true
)

for item in artwork {
    let sourceURL = sourceDirectory.appendingPathComponent(item.sourceName)
    let outputURL = outputDirectory.appendingPathComponent(item.outputName)
    let data = try reencodeSRGBPNG(from: sourceURL)
    try data.write(to: outputURL, options: .atomic)
    print("Prepared \(item.outputName)")
}
