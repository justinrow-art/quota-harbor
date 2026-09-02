#!/usr/bin/env swift

import AppKit
import Foundation

private struct IconSlot {
    let filename: String
    let pixels: Int
}

private let slots = [
    IconSlot(filename: "icon_16x16.png", pixels: 16),
    IconSlot(filename: "icon_16x16@2x.png", pixels: 32),
    IconSlot(filename: "icon_32x32.png", pixels: 32),
    IconSlot(filename: "icon_32x32@2x.png", pixels: 64),
    IconSlot(filename: "icon_128x128.png", pixels: 128),
    IconSlot(filename: "icon_128x128@2x.png", pixels: 256),
    IconSlot(filename: "icon_256x256.png", pixels: 256),
    IconSlot(filename: "icon_256x256@2x.png", pixels: 512),
    IconSlot(filename: "icon_512x512.png", pixels: 512),
    IconSlot(filename: "icon_512x512@2x.png", pixels: 1024),
]

private func color(
    _ red: CGFloat,
    _ green: CGFloat,
    _ blue: CGFloat,
    _ alpha: CGFloat = 1
) -> NSColor {
    NSColor(
        calibratedRed: red,
        green: green,
        blue: blue,
        alpha: alpha
    )
}

private func drawIcon(pixels: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap)
    else {
        throw CocoaError(.fileWriteUnknown)
    }

    let side = CGFloat(pixels)
    let bounds = NSRect(x: 0, y: 0, width: side, height: side)
    bitmap.size = bounds.size

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.setAllowsAntialiasing(true)
    context.cgContext.setShouldAntialias(true)

    NSColor.clear.setFill()
    bounds.fill()

    let tile = NSBezierPath(rect: bounds)

    let background = NSGradient(colors: [
        color(0.025, 0.055, 0.16),
        color(0.10, 0.08, 0.28),
        color(0.04, 0.24, 0.38),
    ])!
    background.draw(in: tile, angle: 48)

    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    let glowRect = NSRect(
        x: side * 0.34,
        y: side * 0.28,
        width: side * 0.82,
        height: side * 0.82
    )
    let glow = NSGradient(colors: [
        color(0.36, 0.90, 1.00, 0.34),
        color(0.52, 0.28, 1.00, 0.04),
        NSColor.clear,
    ])!
    glow.draw(in: NSBezierPath(ovalIn: glowRect), relativeCenterPosition: .zero)

    let sheen = NSBezierPath()
    sheen.move(to: NSPoint(x: side * 0.10, y: side * 0.83))
    sheen.curve(
        to: NSPoint(x: side * 0.90, y: side * 0.61),
        controlPoint1: NSPoint(x: side * 0.36, y: side * 1.04),
        controlPoint2: NSPoint(x: side * 0.70, y: side * 0.79)
    )
    sheen.line(to: NSPoint(x: side * 0.90, y: side * 0.95))
    sheen.line(to: NSPoint(x: side * 0.10, y: side * 0.95))
    sheen.close()
    color(1, 1, 1, 0.055).setFill()
    sheen.fill()
    NSGraphicsContext.restoreGraphicsState()

    let center = NSPoint(x: side * 0.50, y: side * 0.50)
    let mainArc = NSBezierPath()
    mainArc.appendArc(
        withCenter: center,
        radius: side * 0.295,
        startAngle: -48,
        endAngle: 244,
        clockwise: false
    )
    mainArc.lineWidth = max(1, side * 0.092)
    mainArc.lineCapStyle = .round
    color(0.37, 0.90, 0.98).setStroke()
    mainArc.stroke()

    let accentArc = NSBezierPath()
    accentArc.appendArc(
        withCenter: center,
        radius: side * 0.205,
        startAngle: 35,
        endAngle: 214,
        clockwise: false
    )
    accentArc.lineWidth = max(1, side * 0.048)
    accentArc.lineCapStyle = .round
    color(0.74, 0.43, 1.00).setStroke()
    accentArc.stroke()

    let core = NSBezierPath(ovalIn: NSRect(
        x: side * 0.437,
        y: side * 0.437,
        width: side * 0.126,
        height: side * 0.126
    ))
    let coreGradient = NSGradient(colors: [
        color(1.00, 0.84, 0.35),
        color(1.00, 0.43, 0.48),
    ])!
    coreGradient.draw(in: core, angle: -45)

    let terminalAngle = CGFloat(-48) * .pi / 180
    let terminalRadius = side * 0.295
    let terminalCenter = NSPoint(
        x: center.x + cos(terminalAngle) * terminalRadius,
        y: center.y + sin(terminalAngle) * terminalRadius
    )
    let terminalSide = side * 0.070
    let terminal = NSBezierPath(ovalIn: NSRect(
        x: terminalCenter.x - terminalSide / 2,
        y: terminalCenter.y - terminalSide / 2,
        width: terminalSide,
        height: terminalSide
    ))
    NSColor.white.setFill()
    terminal.fill()

    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(
        using: NSBitmapImageRep.FileType.png,
        properties: [:]
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return png
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconSet = root
    .appendingPathComponent("CodexQuotaMonitor/Resources/Assets.xcassets")
    .appendingPathComponent("AppIcon.appiconset")
let artwork = root.appendingPathComponent("artwork/source-masters")

try FileManager.default.createDirectory(
    at: iconSet,
    withIntermediateDirectories: true
)
try FileManager.default.createDirectory(
    at: artwork,
    withIntermediateDirectories: true
)

for slot in slots {
    try drawIcon(pixels: slot.pixels).write(
        to: iconSet.appendingPathComponent(slot.filename),
        options: .atomic
    )
}
try drawIcon(pixels: 2048).write(
    to: artwork.appendingPathComponent("app-icon-master.png"),
    options: .atomic
)

print("Generated AppIcon images and 2048px source master.")
