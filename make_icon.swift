import AppKit
import Foundation

// Generates the app icon (green squircle with a white note) for the bundle.
//
// Run:     swift make_icon.swift
// Output:  Resources/AppIcon.icns  → copied into the bundle by build_app.sh.
//          Resources/AppIcon.png   → the same icon for the README.
//
// Everything is vector-based and every size is rendered fresh – never upscaled:
// sizes from `nativeSize` up are drawn straight at the target resolution, the
// smaller ones are drawn `supersample` times larger and scaled down, which is
// what keeps 16 and 32 px clean. 1024 px is the largest bitmap an .icns can hold
// (512x512@2x), so that is as sharp as the bundle can get.

let resources = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Resources")
let icnsURL = resources.appendingPathComponent("AppIcon.icns")

/// The same icon as a PNG. The `.icns` cannot be displayed by GitHub or most
/// editors, so this is the copy the README shows.
let pngURL = resources.appendingPathComponent("AppIcon.png")

// These file names/sizes are what macOS expects inside a .iconset.
let iconsetFiles: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

/// A color from a `#RRGGBB` literal.
func hex(_ value: UInt32) -> NSColor {
    NSColor(
        srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
        green: CGFloat((value >> 8) & 0xFF) / 255,
        blue: CGFloat(value & 0xFF) / 255,
        alpha: 1
    )
}

/// The background of the icon is one single flat green – `#1DB954`, nothing else.
/// Deliberately no gradient: a second green tone would break the single-color
/// look, and the dithering of a gradient puts noise into the small sizes.
let backgroundGreen = hex(0x1DB954)

/// The note is the only other color of the icon.
let noteColor = NSColor.white

/// Sizes from here up are rendered straight at the target resolution.
let nativeSize = 256

/// Factor the smaller sizes are rendered with and then scaled down again.
let supersample = 8

/// White music note as an SF Symbol. Symbol images are vector-backed, so they
/// stay crisp at every size – `nil` only if the script process has no symbols.
func noteImage(pointSize: CGFloat) -> NSImage? {
    let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [noteColor]))
    return NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration)
}

/// The symbol's bounding box is taller than the point size it was asked for
/// (measured: 521 pt at 442 pt) – the fallback note uses the same box height so
/// that both variants look alike.
let noteBoxFactor: CGFloat = 1.18

/// Hand-drawn fallback note (head, stem, flag), only used if no SF Symbol is
/// available. Drawn as vector paths straight into the current context – no
/// intermediate bitmap that could be scaled up, so it stays crisp too.
func drawFallbackNote(in rect: NSRect) {
    let headHeight = rect.width * 0.62
    let stemWidth = max(rect.width * 0.13, 1)
    noteColor.setFill()

    // Head at the bottom left.
    NSBezierPath(ovalIn: NSRect(
        x: rect.minX,
        y: rect.minY,
        width: rect.width,
        height: headHeight
    )).fill()

    // Stem on the right, up to the top of the box.
    NSBezierPath(rect: NSRect(
        x: rect.maxX - stemWidth,
        y: rect.minY + headHeight * 0.45,
        width: stemWidth,
        height: rect.height - headHeight * 0.45
    )).fill()

    // Flag that curves off the top of the stem to the left.
    let flag = NSBezierPath()
    flag.move(to: NSPoint(x: rect.maxX - stemWidth / 2, y: rect.maxY))
    flag.curve(
        to: NSPoint(x: rect.minX + rect.width * 0.35, y: rect.maxY - rect.height * 0.20),
        controlPoint1: NSPoint(x: rect.maxX + rect.width * 0.35, y: rect.maxY - rect.height * 0.02),
        controlPoint2: NSPoint(x: rect.maxX - rect.width * 0.10, y: rect.maxY - rect.height * 0.12)
    )
    flag.lineWidth = stemWidth * 1.1
    flag.lineCapStyle = .round
    flag.stroke()
}

/// The color space the icon is rendered in: sRGB. Deliberately not the display's
/// device color space – a wide-gamut (P3) device one would shift the stored
/// values (measured: the requested `#1DB954` came out as `#11C267`).
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

/// A square sRGB bitmap to draw into, where 1 unit = 1 px.
struct Canvas {
    let cgContext: CGContext
    let context: NSGraphicsContext

    /// The finished bitmap.
    func bitmap() -> NSBitmapImageRep {
        guard let image = cgContext.makeImage() else {
            fatalError("Could not snapshot the canvas")
        }
        return NSBitmapImageRep(cgImage: image)
    }
}

/// Creates an empty RGBA canvas of `pixels` x `pixels` px.
func makeCanvas(pixels: Int) -> Canvas {
    guard let cgContext = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: sRGB,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("Could not create a bitmap for \(pixels) px")
    }
    return Canvas(
        cgContext: cgContext,
        context: NSGraphicsContext(cgContext: cgContext, flipped: false)
    )
}

/// Draws the icon vector-based at exactly `pixels` px.
func renderIcon(pixels: Int) -> NSBitmapImageRep {
    let canvas = makeCanvas(pixels: pixels)
    let side = CGFloat(pixels)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = canvas.context
    canvas.context.imageInterpolation = .high

    // Base shape: squircle with the margin macOS icons usually have.
    let inset = side * 0.085
    let shape = NSRect(x: inset, y: inset, width: side - 2 * inset, height: side - 2 * inset)
    let cornerRadius = shape.width * 0.2237
    backgroundGreen.setFill()
    NSBezierPath(
        roundedRect: shape,
        xRadius: cornerRadius,
        yRadius: cornerRadius
    ).fill()

    // Note centered, slightly below the optical center.
    let centerY = shape.midY + side * 0.01
    if let note = noteImage(pointSize: shape.width * 0.52) {
        note.draw(
            in: NSRect(
                x: shape.midX - note.size.width / 2,
                y: centerY - note.size.height / 2,
                width: note.size.width,
                height: note.size.height
            ),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
    } else {
        let fallbackHeight = shape.width * 0.52 * noteBoxFactor
        let fallbackWidth = fallbackHeight * 0.74
        drawFallbackNote(in: NSRect(
            x: shape.midX - fallbackWidth / 2,
            y: centerY - fallbackHeight / 2,
            width: fallbackWidth,
            height: fallbackHeight
        ))
    }

    NSGraphicsContext.restoreGraphicsState()
    return canvas.bitmap()
}

/// Scales a render down to `pixels` px with high-quality interpolation.
func downscale(_ source: NSBitmapImageRep, to pixels: Int) -> NSBitmapImageRep {
    let canvas = makeCanvas(pixels: pixels)
    let side = CGFloat(pixels)
    guard let cgImage = source.cgImage else {
        fatalError("The \(source.pixelsWide) px render has no image")
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = canvas.context
    canvas.context.imageInterpolation = .high

    // The source image is drawn at its own size, so it is scaled down from many
    // pixels to one – that is what keeps the small sizes clean.
    let image = NSImage(cgImage: cgImage, size: NSSize(
        width: CGFloat(source.pixelsWide),
        height: CGFloat(source.pixelsHigh)
    ))
    image.draw(
        in: NSRect(x: 0, y: 0, width: side, height: side),
        from: .zero,
        operation: .copy,
        fraction: 1
    )

    NSGraphicsContext.restoreGraphicsState()
    return canvas.bitmap()
}

/// The icon at `pixels` px: from `nativeSize` up drawn straight at that
/// resolution, below it rendered `supersample` times larger and scaled down.
func drawIcon(pixels: Int) -> NSBitmapImageRep {
    guard pixels < nativeSize else { return renderIcon(pixels: pixels) }
    return downscale(renderIcon(pixels: pixels * supersample), to: pixels)
}

// 1) Write every size as a PNG into a temporary .iconset.
let iconset = FileManager.default.temporaryDirectory
    .appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

var pngCache: [Int: Data] = [:]
for file in iconsetFiles {
    if pngCache[file.pixels] == nil {
        let rep = drawIcon(pixels: file.pixels)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            fatalError("PNG for \(file.pixels) px failed")
        }
        pngCache[file.pixels] = data
    }
    guard let data = pngCache[file.pixels] else { continue }
    try data.write(to: iconset.appendingPathComponent(file.name))
    let mode = file.pixels < nativeSize ? "\(supersample)x supersampled" : "native"
    print("==> \(file.name) (\(file.pixels) px, \(mode))")
}

// 2) Pack the .iconset into an .icns.
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icnsURL.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    fatalError("iconutil aborted with status \(iconutil.terminationStatus)")
}
try? FileManager.default.removeItem(at: iconset)

// 3) The same icon once more as a PNG for the README. `nativeSize` is more than
//    enough for that and already rendered, so nothing extra is drawn here.
guard let png = pngCache[nativeSize] else {
    fatalError("The \(nativeSize) px render is missing")
}
try png.write(to: pngURL)

print("")
print("==> Done: \(icnsURL.path)")
print("    Done: \(pngURL.path) (\(nativeSize) px, for the README)")
print("    Now rebuild: ./build_app.sh")
