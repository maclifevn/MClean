#!/usr/bin/env swift
// Renders the MClean app icon (Maclife "M" mountain mark on a macOS
// Big Sur-style rounded rect) at every size in AppIcon.appiconset.
//
// Usage: swift scripts/generate-appicon.swift MClean/Assets.xcassets/AppIcon.appiconset
//
// The mark is redrawn natively from the three polygons of the Maclife
// logo (favicon-ml.svg, viewBox 0 0 64 54.75) so no SVG rasterizer is
// needed and every size renders crisp instead of being downscaled.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Design constants (1024pt master canvas)

let canvas: CGFloat = 1024
// Apple macOS icon grid: icon body is 824x824 centered (100pt margins).
let bodySize: CGFloat = 824
let bodyOrigin = (canvas - bodySize) / 2
let cornerRadius: CGFloat = 185.4

// Background gradient (light field so the three brand blues read well).
let bgTop = (r: 1.00, g: 1.00, b: 1.00)
let bgBottom = (r: 0.863, g: 0.945, b: 0.992) // #DCF1FD

// The Maclife mark: polygons in SVG space (top-left origin, 64 x 54.75).
let logoW: CGFloat = 64, logoH: CGFloat = 54.75
let polygons: [(points: [(CGFloat, CGFloat)], color: (CGFloat, CGFloat, CGFloat))] = [
    ([(13.77, 17.46), (1.29, 50.15), (12.29, 50.15), (27.56, 26.78)],
     (0x12 / 255.0, 0xC3 / 255.0, 0xF4 / 255.0)),
    ([(43.12, 2.94), (27.56, 26.78), (62.16, 50.15)],
     (0x39 / 255.0, 0xA4 / 255.0, 0xDC / 255.0)),
    ([(27.56, 26.78), (12.29, 50.15), (62.16, 50.15)],
     (0x00 / 255.0, 0x66 / 255.0, 0xAB / 255.0)),
]

// Mark occupies ~63% of the body width, optically centered (nudged up
// slightly because the mark is bottom-heavy).
let markWidth: CGFloat = 520
let markScale = markWidth / logoW
let markHeight = logoH * markScale
let markX = (canvas - markWidth) / 2
let markY = (canvas - markHeight) / 2 + 18 // CG origin is bottom-left; +y = up

// MARK: - Rendering

func render(pixels: Int) -> CGImage {
    let scale = CGFloat(pixels) / canvas
    let ctx = CGContext(
        data: nil, width: pixels, height: pixels,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.scaleBy(x: scale, y: scale)
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // Rounded-rect body, clipped, filled with a vertical gradient.
    let body = CGRect(x: bodyOrigin, y: bodyOrigin, width: bodySize, height: bodySize)
    let bodyPath = CGPath(
        roundedRect: body, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil
    )
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [
            CGColor(red: bgTop.r, green: bgTop.g, blue: bgTop.b, alpha: 1),
            CGColor(red: bgBottom.r, green: bgBottom.g, blue: bgBottom.b, alpha: 1),
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: canvas / 2, y: bodyOrigin + bodySize),
        end: CGPoint(x: canvas / 2, y: bodyOrigin),
        options: []
    )

    // The mark. SVG y grows downward, CG y grows upward: y' = logoH - y.
    for polygon in polygons {
        ctx.beginPath()
        for (i, p) in polygon.points.enumerated() {
            let point = CGPoint(x: markX + p.0 * markScale,
                                y: markY + (logoH - p.1) * markScale)
            if i == 0 { ctx.move(to: point) } else { ctx.addLine(to: point) }
        }
        ctx.closePath()
        let c = polygon.color
        ctx.setFillColor(CGColor(red: c.0, green: c.1, blue: c.2, alpha: 1))
        ctx.fillPath()
    }
    ctx.restoreGState()

    // Hairline inner stroke so the light body keeps an edge on white desktops.
    ctx.addPath(bodyPath)
    ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.06))
    ctx.setLineWidth(2)
    ctx.strokePath()

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    )!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        fatalError("Failed to write \(url.path)")
    }
}

// MARK: - Main

guard CommandLine.arguments.count == 2 else {
    print("Usage: swift scripts/generate-appicon.swift <path-to-AppIcon.appiconset>")
    exit(1)
}
let outDir = URL(fileURLWithPath: CommandLine.arguments[1])

// pixel size -> appiconset filenames (matches Contents.json)
let outputs: [Int: [String]] = [
    16: ["icon_16.png"],
    32: ["icon_16@2x.png", "icon_32.png"],
    64: ["icon_32@2x.png"],
    128: ["icon_128.png"],
    256: ["icon_128@2x.png", "icon_256.png"],
    512: ["icon_256@2x.png", "icon_512.png"],
    1024: ["icon_512@2x.png"],
]

for (pixels, names) in outputs.sorted(by: { $0.key < $1.key }) {
    let image = render(pixels: pixels)
    for name in names {
        writePNG(image, to: outDir.appendingPathComponent(name))
        print("wrote \(name) (\(pixels)x\(pixels))")
    }
}
