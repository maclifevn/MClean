#!/usr/bin/env swift
// Exports the approved Clean M identity from transparent PNG masters.
// Usage: swift scripts/generate-appicon.swift [path-to-AppIcon.appiconset]
// AppIcon, BrandMark and MenuBarIcon are regenerated together so the old
// mountain artwork cannot be reintroduced by running this script.

import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ExportError: LocalizedError {
    case invalidMaster(URL)
    case renderingFailed(Int)
    case writingFailed(URL)

    var errorDescription: String? {
        switch self {
        case .invalidMaster(let url):
            return "Expected a square transparent PNG master: \(url.path)"
        case .renderingFailed(let pixels):
            return "Could not render a \(pixels)px asset"
        case .writingFailed(let url):
            return "Could not write \(url.path)"
        }
    }
}

let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
let masters = repository.appendingPathComponent("docs/assets/branding")
let defaultAssets = repository.appendingPathComponent("MClean/Assets.xcassets")

func loadMaster(_ name: String) throws -> CGImage {
    let url = masters.appendingPathComponent(name)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          image.width == image.height, image.width >= 1024,
          [.first, .last, .premultipliedFirst, .premultipliedLast].contains(image.alphaInfo)
    else { throw ExportError.invalidMaster(url) }
    return image
}

func render(_ source: CGImage, pixels: Int) throws -> CGImage {
    guard let context = CGContext(
        data: nil, width: pixels, height: pixels,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw ExportError.renderingFailed(pixels) }
    context.interpolationQuality = .high
    context.draw(source, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    guard let image = context.makeImage() else { throw ExportError.renderingFailed(pixels) }
    return image
}

func writePNG(_ image: CGImage, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else { throw ExportError.writingFailed(url) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw ExportError.writingFailed(url) }
    print("wrote \(url.lastPathComponent) (\(image.width)x\(image.height))")
}

func renderWordmark(_ symbol: CGImage, dark: Bool) throws -> CGImage {
    guard let context = CGContext(
        data: nil, width: 1024, height: 256,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw ExportError.renderingFailed(1024) }
    context.interpolationQuality = .high
    context.draw(symbol, in: CGRect(x: 0, y: 0, width: 256, height: 256))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSAttributedString(string: "MClean", attributes: [
        .font: NSFont.systemFont(ofSize: 176, weight: .bold),
        .foregroundColor: dark ? NSColor.white : NSColor(
            srgbRed: 0.03, green: 0.08, blue: 0.15, alpha: 1
        ),
    ]).draw(at: CGPoint(x: 271, y: 43))
    guard let image = context.makeImage() else { throw ExportError.renderingFailed(1024) }
    return image
}

do {
    guard CommandLine.arguments.count <= 2 else {
        print("Usage: swift scripts/generate-appicon.swift [path-to-AppIcon.appiconset]")
        exit(1)
    }
    let appIconSet = CommandLine.arguments.count == 2
        ? URL(fileURLWithPath: CommandLine.arguments[1])
        : defaultAssets.appendingPathComponent("AppIcon.appiconset")
    let assets = appIconSet.deletingLastPathComponent()
    // Load every master before writing, so a missing input leaves exports intact.
    let appIcon = try loadMaster("app-icon-master.png")
    let logo = try loadMaster("logo-master.png")
    let menuBar = try loadMaster("menubar-master.png")
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
        let image = try render(appIcon, pixels: pixels)
        for name in names { try writePNG(image, to: appIconSet.appendingPathComponent(name)) }
    }
    for (pixels, name) in [(18, "menubar-icon.png"), (36, "menubar-icon@2x.png")] {
        try writePNG(render(menuBar, pixels: pixels),
                     to: assets.appendingPathComponent("MenuBarIcon.imageset/\(name)"))
    }
    for (pixels, name) in [(128, "brand-mark.png"), (256, "brand-mark@2x.png")] {
        try writePNG(render(logo, pixels: pixels),
                     to: assets.appendingPathComponent("BrandMark.imageset/\(name)"))
    }
    try writePNG(render(appIcon, pixels: 256),
                 to: repository.appendingPathComponent("docs/assets/icon.png"))
    try writePNG(render(logo, pixels: 512),
                 to: masters.appendingPathComponent("logo.png"))
    try writePNG(renderWordmark(logo, dark: false),
                 to: masters.appendingPathComponent("wordmark.png"))
    try writePNG(renderWordmark(logo, dark: true),
                 to: masters.appendingPathComponent("wordmark-dark.png"))
} catch {
    fputs("Brand export failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
