#!/usr/bin/env swift
// Contact sheet of the actual exported assets, including menu-bar pixel sizes.
// Usage: swift scripts/preview-brand-assets.swift [output.png]

import AppKit
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
let assets = root.appendingPathComponent("MClean/Assets.xcassets")
let output = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : root.appendingPathComponent("docs/assets/branding/preview.png")
let scale: CGFloat = 2
let width = 1024, height = 700
let context = CGContext(
    data: nil, width: width * Int(scale), height: height * Int(scale),
    bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
context.scaleBy(x: scale, y: scale)
context.setFillColor(CGColor(red: 0.97, green: 0.98, blue: 0.99, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: width, height: height))
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)

func text(_ string: String, at point: CGPoint, size: CGFloat,
          weight: NSFont.Weight = .regular, color: NSColor = .labelColor) {
    NSAttributedString(string: string, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
    ]).draw(at: point)
}

func load(_ relative: String) -> CGImage {
    let url = assets.appendingPathComponent(relative)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fatalError("Missing image: \(url.path)")
    }
    return image
}

func draw(_ image: CGImage, in rect: CGRect) {
    context.saveGState()
    context.interpolationQuality = .high
    context.draw(image, in: rect)
    context.restoreGState()
}

func template(_ image: CGImage, in rect: CGRect, color: CGColor) {
    context.saveGState()
    context.interpolationQuality = .high
    context.clip(to: rect, mask: image)
    context.setFillColor(color)
    context.fill(rect)
    context.restoreGState()
}

let app = load("AppIcon.appiconset/icon_512@2x.png")
let logo = load("BrandMark.imageset/brand-mark@2x.png")
let menu1x = load("MenuBarIcon.imageset/menubar-icon.png")
let menu2x = load("MenuBarIcon.imageset/menubar-icon@2x.png")
text("MClean · Clean M", at: CGPoint(x: 46, y: 624), size: 34, weight: .bold)
text("Approved concept 04 · exported app assets", at: CGPoint(x: 47, y: 594),
     size: 15, color: .secondaryLabelColor)
draw(app, in: CGRect(x: 24, y: 207, width: 388, height: 388))
text("macOS app icon", at: CGPoint(x: 106, y: 190), size: 18, weight: .medium)

draw(logo, in: CGRect(x: 484, y: 425, width: 146, height: 146))
text("MClean", at: CGPoint(x: 636, y: 471), size: 57, weight: .bold)
text("Logo · transparent background", at: CGPoint(x: 508, y: 403),
     size: 16, color: .secondaryLabelColor)

text("Menubar · template rendering", at: CGPoint(x: 505, y: 343),
     size: 20, weight: .semibold)
let black = CGColor(gray: 0.08, alpha: 1)
let white = CGColor(gray: 0.98, alpha: 1)
for (index, dark) in [false, true].enumerated() {
    let y: CGFloat = index == 0 ? 275 : 212
    let bar = CGRect(x: 506, y: y, width: 438, height: 50)
    context.setFillColor(dark ? CGColor(gray: 0.13, alpha: 1) : CGColor(gray: 0.91, alpha: 1))
    context.addPath(CGPath(roundedRect: bar, cornerWidth: 10, cornerHeight: 10, transform: nil))
    context.fillPath()
    template(menu1x, in: CGRect(x: 532, y: y + 16, width: 18, height: 18),
             color: dark ? white : black)
    template(menu2x, in: CGRect(x: 570, y: y + 16, width: 18, height: 18),
             color: dark ? white : black)
    text("18 px / 36 px @2x", at: CGPoint(x: 619, y: y + 17), size: 14,
         color: dark ? .white : .darkGray)
    template(menu2x, in: CGRect(x: 862, y: y + 8, width: 34, height: 34),
             color: dark ? white : black)
}
text("Both samples above display at 18 pt; enlarged mark at right.",
     at: CGPoint(x: 506, y: 184), size: 12, color: .secondaryLabelColor)

text("Dock / Finder sizes", at: CGPoint(x: 47, y: 145), size: 16, weight: .semibold)
for (size, x) in [(16, 53), (32, 127), (64, 214), (128, 337)] {
    draw(app, in: CGRect(x: x, y: 25, width: size, height: size))
    text("\(size) px", at: CGPoint(x: x, y: 7), size: 11, color: .secondaryLabelColor)
}
text("M + sweeping brush · same identity throughout MClean", at: CGPoint(x: 507, y: 73),
     size: 15, weight: .medium)
text("AppKit switches the menubar mark between black and white.",
     at: CGPoint(x: 507, y: 49), size: 12, color: .secondaryLabelColor)

NSGraphicsContext.restoreGraphicsState()
let image = context.makeImage()!
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
let destination = CGImageDestinationCreateWithURL(output as CFURL,
    UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Could not write preview") }
print(output.path)
