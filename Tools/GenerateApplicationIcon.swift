// Draws the application icon and writes Packaging/AppIcon.icns.
//
//   swift Tools/GenerateApplicationIcon.swift
//
// The icon follows the heads-up display: nine blue bars (the display has 20) on the pill's near-black, inside the
// standard macOS icon shape, an 824 pt rounded square with a 185.4 pt corner radius, centered on a 1024 pt canvas. The
// tool draws the icon itself and does not use the `waveform` SF Symbol from the menu bar, because the SF Symbols
// license does not allow symbols in application icons. Every size is drawn from the same vectors, so small sizes stay
// sharp.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let canvas: CGFloat = 1024
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let cornerRadius: CGFloat = 185.4

/// Bar heights as fractions of the tallest bar. They are uneven on purpose, like the fixed bar offsets of the pill.
let barHeights: [CGFloat] = [0.30, 0.56, 0.84, 0.62, 1.00, 0.72, 0.90, 0.50, 0.32]
let barWidth: CGFloat = 38
let barPitch: CGFloat = 66
let tallestBar: CGFloat = 440

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [red, green, blue, alpha])!
}

func draw(in context: CGContext) {
    let shape = CGPath(roundedRect: body, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    // Drop shadow under the body, as in Apple's icon template.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0, 0, 0, 0.35))
    context.addPath(shape)
    context.setFillColor(color(0.08, 0.08, 0.08))
    context.fillPath()
    context.restoreGState()

    // Body: a vertical gradient around the pill's #141414, about #212124 at the top and #0F0F0F at the bottom.
    context.saveGState()
    context.addPath(shape)
    context.clip()
    let gradient = CGGradient(
        colorsSpace: colorSpace, colors: [color(0.13, 0.13, 0.14), color(0.06, 0.06, 0.06)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
    context.restoreGState()

    // Hairline edge, as on the pill.
    context.addPath(CGPath(
        roundedRect: body.insetBy(dx: 2, dy: 2), cornerWidth: cornerRadius - 2, cornerHeight: cornerRadius - 2, transform: nil))
    context.setStrokeColor(color(1, 1, 1, 0.10))
    context.setLineWidth(4)
    context.strokePath()

    // Bars in system blue (dark appearance), centered in the body.
    let stripWidth = CGFloat(barHeights.count - 1) * barPitch + barWidth
    let start = body.midX - stripWidth / 2
    context.setFillColor(color(10 / 255, 132 / 255, 255 / 255))
    for (index, fraction) in barHeights.enumerated() {
        let height = tallestBar * fraction
        let bar = CGRect(x: start + CGFloat(index) * barPitch, y: body.midY - height / 2, width: barWidth, height: height)
        context.addPath(CGPath(roundedRect: bar, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
    }
    context.fillPath()
}

func writeImage(pixels: Int, to url: URL) {
    let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(pixels) / canvas, y: CGFloat(pixels) / canvas)
    draw(in: context)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Could not write \(url.path)") }
}

let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    writeImage(pixels: points, to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    writeImage(pixels: points * 2, to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let output = repository.appendingPathComponent("Packaging/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["--convert", "icns", "--output", output.path, iconset.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed with status \(iconutil.terminationStatus)") }
try FileManager.default.removeItem(at: iconset)
print("Wrote \(output.path)")
