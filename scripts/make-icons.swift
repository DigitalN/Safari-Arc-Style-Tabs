#!/usr/bin/env swift
// Draws the app icon, the extension icons and the Safari toolbar icon.
// Run from the repository root: swift scripts/make-icons.swift

import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let appIconSet = root.appending(path: "SideTabs/Assets.xcassets/AppIcon.appiconset")
let extensionImages = root.appending(path: "WebExtension/images")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: alpha
    )
}

func render(size: Int, draw: (CGRect) -> Void) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    draw(CGRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

/// The app icon, drawn on a 1024 grid and scaled to `rect`.
func drawAppIcon(in rect: CGRect) {
    let s = rect.width / 1024
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: rect.minX + x * s, y: rect.minY + y * s, width: w * s, height: h * s)
    }

    // Squircle background with a soft shadow.
    let tile = r(100, 100, 824, 824)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x000000, 0.28)
    shadow.shadowBlurRadius = 24 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.set()
    color(0x4A49E0).setFill()
    tilePath.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(0x7AA2FF), ending: color(0x4532D4))!.draw(in: tilePath, angle: -90)

    // A browser window...
    let window = r(214, 250, 596, 524)
    let windowPath = NSBezierPath(roundedRect: window, xRadius: 58 * s, yRadius: 58 * s)
    color(0xFFFFFF, 0.97).setFill()
    windowPath.fill()

    // ...whose left side is the tab sidebar.
    NSGraphicsContext.saveGraphicsState()
    windowPath.addClip()
    color(0xE3E7FF).setFill()
    r(214, 250, 216, 524).fill()
    NSGraphicsContext.restoreGraphicsState()

    let tabTops: [CGFloat] = [644, 570, 496, 422, 348]
    for (index, top) in tabTops.enumerated() {
        let selected = index == 1
        if selected {
            color(0xFFFFFF).setFill()
            NSBezierPath(roundedRect: r(234, top - 14, 176, 58), xRadius: 16 * s, yRadius: 16 * s).fill()
        }
        color(selected ? 0x4F5BE8 : 0x9AA6E8).setFill()
        NSBezierPath(ovalIn: r(254, top + 3, 24, 24)).fill()
        color(selected ? 0x3B3F6E : 0xB4BDEB).setFill()
        NSBezierPath(roundedRect: r(292, top + 6, 96, 18), xRadius: 9 * s, yRadius: 9 * s).fill()
    }

    // Page content.
    color(0xD8DCF0).setFill()
    for (index, width) in [292.0, 240, 268, 180].enumerated() {
        let y = 660 - CGFloat(index) * 62
        NSBezierPath(roundedRect: r(474, y, width, 22), xRadius: 11 * s, yRadius: 11 * s).fill()
    }
}

/// Toolbar icons are black on transparent; Safari tints them to match its toolbar.
func drawToolbarIcon(in rect: CGRect) {
    let configuration = NSImage.SymbolConfiguration(pointSize: rect.height * 0.8, weight: .regular)
    guard let symbol = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration) else { return }
    let tinted = NSImage(size: symbol.size, flipped: false) { bounds in
        symbol.draw(in: bounds)
        NSColor.black.set()
        bounds.fill(using: .sourceAtop)
        return true
    }
    let scale = min(rect.width / tinted.size.width, rect.height / tinted.size.height) * 0.9
    let size = CGSize(width: tinted.size.width * scale, height: tinted.size.height * scale)
    tinted.draw(in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
}

try FileManager.default.createDirectory(at: appIconSet, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: extensionImages, withIntermediateDirectories: true)

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try render(size: points * scale, draw: drawAppIcon).write(to: appIconSet.appending(path: name))
        images.append(["idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: appIconSet.appending(path: "Contents.json"))

for size in [48, 96, 128, 256, 512] {
    try render(size: size, draw: drawAppIcon).write(to: extensionImages.appending(path: "icon-\(size).png"))
}
for size in [16, 19, 32, 38] {
    try render(size: size, draw: drawToolbarIcon).write(to: extensionImages.appending(path: "toolbar-\(size).png"))
}
print("Icons written.")
