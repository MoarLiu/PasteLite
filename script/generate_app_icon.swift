#!/usr/bin/env swift

import AppKit
import Foundation

let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resourcesURL = rootURL.appendingPathComponent("Resources", isDirectory: true)
let iconsetURL = resourcesURL.appendingPathComponent("AppIcon.iconset", isDirectory: true)
let icnsURL = resourcesURL.appendingPathComponent("AppIcon.icns")

try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
try? FileManager.default.removeItem(at: iconsetURL)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let iconFiles: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for iconFile in iconFiles {
    let image = drawIcon(size: iconFile.pixels)
    let pngData = try pngData(from: image)
    try pngData.write(to: iconsetURL.appendingPathComponent(iconFile.name))
}

try? FileManager.default.removeItem(at: icnsURL)
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetURL.path, "-o", icnsURL.path]
try process.run()
process.waitUntilExit()

guard process.terminationStatus == 0 else {
    throw NSError(domain: "PasteLiteIconGenerator", code: Int(process.terminationStatus))
}

func drawIcon(size: Int) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    let bounds = NSRect(x: 0, y: 0, width: size, height: size)
    let cornerRadius = CGFloat(size) * 0.22
    let backgroundPath = NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)
    backgroundPath.addClip()

    NSGradient(colors: [
        NSColor(calibratedRed: 1.00, green: 0.27, blue: 0.28, alpha: 1),
        NSColor(calibratedRed: 0.93, green: 0.12, blue: 0.24, alpha: 1),
        NSColor(calibratedRed: 0.60, green: 0.10, blue: 0.32, alpha: 1)
    ])?.draw(in: bounds, angle: 135)

    NSColor.white.withAlphaComponent(0.16).setFill()
    NSBezierPath(ovalIn: NSRect(
        x: CGFloat(size) * 0.52,
        y: CGFloat(size) * 0.54,
        width: CGFloat(size) * 0.62,
        height: CGFloat(size) * 0.62
    )).fill()

    let strokeWidth = max(CGFloat(size) * 0.055, 2)
    let boardRect = NSRect(
        x: CGFloat(size) * 0.28,
        y: CGFloat(size) * 0.20,
        width: CGFloat(size) * 0.44,
        height: CGFloat(size) * 0.58
    )
    let boardPath = NSBezierPath(roundedRect: boardRect, xRadius: CGFloat(size) * 0.055, yRadius: CGFloat(size) * 0.055)
    NSColor.white.setStroke()
    boardPath.lineWidth = strokeWidth
    boardPath.stroke()

    let clipRect = NSRect(
        x: CGFloat(size) * 0.38,
        y: CGFloat(size) * 0.70,
        width: CGFloat(size) * 0.24,
        height: CGFloat(size) * 0.12
    )
    let clipPath = NSBezierPath(roundedRect: clipRect, xRadius: CGFloat(size) * 0.04, yRadius: CGFloat(size) * 0.04)
    clipPath.lineWidth = strokeWidth
    clipPath.stroke()

    for y in [0.56, 0.45, 0.34] {
        let linePath = NSBezierPath()
        linePath.move(to: NSPoint(x: CGFloat(size) * 0.38, y: CGFloat(size) * y))
        linePath.line(to: NSPoint(x: CGFloat(size) * 0.62, y: CGFloat(size) * y))
        linePath.lineWidth = max(CGFloat(size) * 0.035, 1.5)
        linePath.stroke()
    }

    return image
}

func pngData(from image: NSImage) throws -> Data {
    guard let tiffData = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData),
          let pngData = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "PasteLiteIconGenerator", code: 1)
    }
    return pngData
}
