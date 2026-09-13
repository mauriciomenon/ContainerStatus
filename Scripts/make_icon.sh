#!/usr/bin/env bash
# Generates Icon.icns (green service dot on a dark rounded square) without
# Xcode: a small Swift/AppKit script renders the PNGs, iconutil seals them.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICONSET="$(mktemp -d)/Icon.iconset"
mkdir -p "$ICONSET"

swift - "$ICONSET" <<'SWIFT'
import AppKit

let iconset = CommandLine.arguments[1]

func render(_ points: CGFloat, pixels: Int) -> NSImage {
    let size = NSSize(width: points, height: points)
    let image = NSImage(size: size)
    image.lockFocus()
    let rect = NSRect(x: 0, y: 0, width: points, height: points)
    let background = NSBezierPath(roundedRect: rect.insetBy(dx: points * 0.06, dy: points * 0.06),
                                  xRadius: points * 0.22, yRadius: points * 0.22)
    NSColor(calibratedRed: 0.13, green: 0.13, blue: 0.15, alpha: 1).setFill()
    background.fill()
    let dot = points * 0.5
    let circle = NSBezierPath(ovalIn: NSRect(x: (points - dot) / 2, y: (points - dot) / 2,
                                             width: dot, height: dot))
    NSColor(calibratedRed: 0.20, green: 0.78, blue: 0.35, alpha: 1).setFill()
    circle.fill()
    image.unlockFocus()

    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .calibratedRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: rect)
    NSGraphicsContext.restoreGraphicsState()
    return image
}

func write(_ image: NSImage, pixels: Int, name: String) throws {
    let tiff = image.tiffRepresentation!
    let rep = NSBitmapImageRep(data: tiff)!
    let png = rep.representation(using: .png, properties: [:])!
    try png.write(to: URL(fileURLWithPath: iconset).appendingPathComponent(name))
}

for entry in [(16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
              (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
              (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
              (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
              (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png")] {
    try write(render(CGFloat(entry.0), pixels: entry.0), pixels: entry.0, name: entry.1)
}
print("iconset: \(iconset)")
SWIFT

iconutil -c icns "$ICONSET" -o "$ROOT/Icon.icns"
echo "Created $ROOT/Icon.icns"
