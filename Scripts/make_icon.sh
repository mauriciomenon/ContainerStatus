#!/usr/bin/env bash
# Generates Icon.icns (green service dot on a dark rounded square) without
# Xcode: a small Swift/AppKit script renders the PNGs, iconutil seals them.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
ICONSET="$WORK_DIR/Icon.iconset"
mkdir -p "$ICONSET"

swift - "$ICONSET" <<'SWIFT'
import AppKit

let iconset = CommandLine.arguments[1]

func render(pixels: Int, name: String) throws {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                    isPlanar: false, colorSpaceName: .calibratedRGB,
                                    bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: rep) else {
        throw NSError(domain: "ContainerStatus.Icon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Falha ao alocar bitmap \(pixels)x\(pixels)"])
    }
    let dimension = CGFloat(pixels)
    rep.size = NSSize(width: dimension, height: dimension)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }

    let rect = NSRect(x: 0, y: 0, width: dimension, height: dimension)
    NSColor.clear.setFill()
    rect.fill(using: .copy)
    let background = NSBezierPath(roundedRect: rect.insetBy(dx: dimension * 0.06, dy: dimension * 0.06),
                                  xRadius: dimension * 0.22, yRadius: dimension * 0.22)
    NSColor(calibratedRed: 0.13, green: 0.13, blue: 0.15, alpha: 1).setFill()
    background.fill()
    let dot = dimension * 0.5
    let circle = NSBezierPath(ovalIn: NSRect(x: (dimension - dot) / 2, y: (dimension - dot) / 2,
                                             width: dot, height: dot))
    NSColor(calibratedRed: 0.20, green: 0.78, blue: 0.35, alpha: 1).setFill()
    circle.fill()
    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "ContainerStatus.Icon", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "Falha ao codificar \(name)"])
    }
    try png.write(to: URL(fileURLWithPath: iconset).appendingPathComponent(name))
}

do {
    for entry in [(16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
              (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
              (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
              (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
              (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png")] {
        try render(pixels: entry.0, name: entry.1)
    }
} catch {
    FileHandle.standardError.write(Data("ERRO: Falha ao gerar icone: \(error.localizedDescription)\n".utf8))
    exit(1)
}
print("iconset: \(iconset)")
SWIFT

iconutil -c icns "$ICONSET" -o "$ROOT/Icon.icns"
echo "Created $ROOT/Icon.icns"
