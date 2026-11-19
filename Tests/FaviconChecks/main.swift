import AppKit
import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

// Checks for the favicons Side Tabs keeps (FaviconStore.swift, #83): each kept at FaviconStore.pixelSize at most,
// each URL observed on its own, and only so many that no view shows. Drawing them needs the running app.

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition {
        failures += 1
        print("FAIL (line \(line)): \(message)")
    }
}

/// A square image filled with one color.
func square(_ size: Int, _ color: CGColor) -> CGImage {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(color)
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    return context.makeImage()!
}

/// A file holding these images, in the format `type`.
func file(_ images: [CGImage], _ type: UTType) -> Data {
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, images.count, nil)!
    images.forEach { CGImageDestinationAddImage(destination, $0, nil) }
    precondition(CGImageDestinationFinalize(destination))
    return data as Data
}

/// The color at the image's center, as 0–255 red, green, blue.
func centerColor(_ image: CGImage) -> [Int] {
    var pixel = [UInt8](repeating: 0, count: 4)
    let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: -CGFloat(image.width) / 2 + 0.5, y: -CGFloat(image.height) / 2 + 0.5,
                                   width: CGFloat(image.width), height: CGFloat(image.height)))
    return pixel.prefix(3).map(Int.init)
}

let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
let green = CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
let blue = CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
let size = FaviconStore.pixelSize

/// Runs the main queue for a moment, where the store's tasks and dispatches run.
func settle() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
}

/// Whether reading `read` in a view would be updated by `change`.
func notifies(_ read: () -> Void, _ change: () -> Void) -> Bool {
    nonisolated final class Flag: @unchecked Sendable { var on = false }
    let notified = Flag()
    withObservationTracking(read) { notified.on = true }
    change()
    return notified.on
}

// MARK: - Downsampling

do {
    let touchIcon = FaviconStore.downsample(file([square(512, red)], .png))
    check(touchIcon?.width == size && touchIcon?.height == size, "a 512 px touch icon is kept at \(size) px")
    let small = FaviconStore.downsample(file([square(16, red)], .png))
    check(small?.width == 16 && small?.height == 16, "a 16 px icon isn't made bigger")

    let banner = CGContext(data: nil, width: 300, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!,
                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    let wide = FaviconStore.downsample(file([banner], .png))
    check(wide?.width == size && (wide?.height ?? 0) < size, "a wide icon keeps its shape")

    // Several sizes in one file, as ICOs have: the smallest that's large enough is the one used.
    let sizes = file([square(16, red), square(64, green), square(256, blue)], .tiff)
    let picked = FaviconStore.downsample(sizes)
    check(picked?.width == size, "from a file with several sizes, the icon is kept at \(size) px")
    check(picked.map(centerColor) == [0, 255, 0], "made from the 64 px one, the smallest at least \(size) px")
    let smallOnly = FaviconStore.downsample(file([square(16, red), square(24, blue)], .tiff))
    check(smallOnly?.width == 24 && smallOnly.map(centerColor) == [0, 0, 255], "with none large enough, the largest")

    let ico = NSMutableData()
    if let destination = CGImageDestinationCreateWithData(ico, UTType.ico.identifier as CFString, 3, nil) {
        [square(16, red), square(32, green), square(48, blue)].forEach { CGImageDestinationAddImage(destination, $0, nil) }
        if CGImageDestinationFinalize(destination) {
            let icon = FaviconStore.downsample(ico as Data)
            check(icon?.width == size && icon.map(centerColor) == [0, 0, 255], "an ICO's 48 px image is used for \(size) px")
        }
    }

    let svg = Data("""
        <svg xmlns="http://www.w3.org/2000/svg" width="100" height="100" viewBox="0 0 100 100">
        <rect width="100" height="100" fill="#00ff00"/></svg>
        """.utf8)
    let vector = FaviconStore.downsample(svg)
    check(vector?.width == size && vector?.height == size, "an SVG icon is drawn at \(size) px")
    check(FaviconStore.downsample(Data("not an image".utf8)) == nil, "something that isn't an image is no icon")
}

// MARK: - Each URL observed on its own

do {
    let store = FaviconStore()
    let a = "https://a.example/favicon.ico"
    let b = "https://b.example/favicon.ico"
    let icon = file([square(64, red)], .png)
    check(!notifies({ _ = store.image(for: [a]) }, { store.receive(url: b, data: icon) }),
          "another site's icon arriving doesn't update a view showing this one")
    check(notifies({ _ = store.image(for: [a]) }, { store.receive(url: a, data: icon) }),
          "its own icon arriving does")
    check(store.image(for: [a])?.width == size, "and it's there, at \(size) px")
    let fallback = "https://c.example/favicon.ico"
    check(notifies({ _ = store.image(for: [fallback, a]) }, { store.receive(url: fallback, data: icon) }),
          "a view showing its second choice is updated when its first arrives")
    check(!notifies({ _ = store.image(for: [a]) }, { store.receive(url: a, data: Data("broken".utf8)) }),
          "an icon that can't be read changes nothing")
    check(store.image(for: [a]) != nil, "and the one kept stays")
}

// MARK: - Only so many kept

do {
    let store = FaviconStore()
    var asked: [String] = []
    store.requestIcons = { asked += $0 }
    let icon = file([square(64, red)], .png)
    let limit = FaviconStore.unshownLimit

    // An icon a view shows, asked for, arrived, and then the oldest of all.
    let shown = "https://shown.example/favicon.ico"
    let showing = Task { await store.show([shown]) }
    settle()
    check(asked == [shown], "a view showing an icon asks the extension for it")
    store.receive(url: shown, data: icon)
    settle()

    let first = "https://site-0.example/favicon.ico"
    store.receive(url: first, data: icon)
    let readFirst = notifies({ _ = store.image(for: [first]) }) {
        for index in 1...(limit + 50) {
            store.receive(url: "https://site-\(index).example/favicon.ico", data: icon)
        }
    }
    check(store.keptCount == limit + 1, "\(limit) icons no view shows are kept, and the one shown")
    check(readFirst, "a view that read a dropped icon is told, so it asks again")
    check(store.image(for: [first]) == nil, "the least recently used went first")
    check(store.image(for: ["https://site-\(limit + 50).example/favicon.ico"]) != nil, "the newest stays")
    check(store.image(for: [shown]) != nil, "an icon a view shows is never dropped, however long ago it came")

    showing.cancel()
    settle()
    check(store.keptCount <= limit, "once no view shows it, it counts toward the \(limit)")

    // Reading many icons that never arrive (sites without one) doesn't keep a box for each.
    for index in 0..<(limit * 2) {
        _ = store.image(for: ["https://none-\(index).example/favicon.ico"])
    }
    settle()
    check(store.keptCount <= limit, "nor do icons that were only looked for")
}

if failures == 0 {
    print("favicon checks passed")
} else {
    print("\(failures) favicon check(s) failed")
    exit(1)
}
