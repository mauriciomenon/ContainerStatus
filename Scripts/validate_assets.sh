#!/usr/bin/env bash
set -euo pipefail

if [[ $# -gt 1 ]]; then
  echo "Uso: $0 [ContainerStatus.app]" >&2
  exit 2
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
iconutil -c iconset "$ROOT/Icon.icns" -o "$WORK_DIR/Icon.iconset"

swift - "$WORK_DIR/Icon.iconset" "${1:-}" <<'SWIFT'
import AppKit

func require(_ condition: Bool, _ message: String) throws {
    if !condition {
        throw NSError(domain: "ContainerStatus.Validacao", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: message])
    }
}

do {
    let iconset = URL(fileURLWithPath: CommandLine.arguments[1])
    let sizes = ["icon_16x16.png": 16, "icon_16x16@2x.png": 32,
                 "icon_32x32.png": 32, "icon_32x32@2x.png": 64,
                 "icon_128x128.png": 128, "icon_128x128@2x.png": 256,
                 "icon_256x256.png": 256, "icon_256x256@2x.png": 512,
                 "icon_512x512.png": 512, "icon_512x512@2x.png": 1024]
    let files = try FileManager.default.contentsOfDirectory(atPath: iconset.path)
    try require(Set(files) == Set(sizes.keys), "O ICNS deve conter as 10 representacoes padrao")
    for (name, pixels) in sizes.sorted(by: { $0.key < $1.key }) {
        let data = try Data(contentsOf: iconset.appendingPathComponent(name))
        guard let bitmap = NSBitmapImageRep(data: data) else {
            throw NSError(domain: "ContainerStatus.Validacao", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "PNG invalido: \(name)"])
        }
        try require(bitmap.pixelsWide == pixels && bitmap.pixelsHigh == pixels,
                    "Dimensoes incorretas em \(name): esperado \(pixels)x\(pixels)")
        try require(bitmap.hasAlpha, "Canal alfa ausente em \(name)")
        for (x, y) in [(0, 0), (pixels - 1, 0), (0, pixels - 1), (pixels - 1, pixels - 1)] {
            try require(bitmap.colorAt(x: x, y: y)?.alphaComponent == 0,
                        "Canto sem transparencia em \(name)")
        }
        try require(bitmap.colorAt(x: pixels / 2, y: pixels / 2)?.alphaComponent == 1,
                    "Centro sem opacidade em \(name)")
    }
    print("OK: ICNS com 10 representacoes de 16x16 a 1024x1024 e alfa correto")

    let bundle = CommandLine.arguments[2]
    if !bundle.isEmpty {
        let url = URL(fileURLWithPath: bundle).appendingPathComponent("Contents/Info.plist")
        let data = try Data(contentsOf: url)
        let value = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let plist = value as? [String: Any] else {
            throw NSError(domain: "ContainerStatus.Validacao", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Info.plist invalido"])
        }
        for key in ["CFBundleName", "CFBundleDisplayName", "CFBundleExecutable"] {
            try require(plist[key] as? String == "ContainerStatus", "\(key) incorreto")
        }
        try require(plist["CFBundlePackageType"] as? String == "APPL", "Tipo do bundle incorreto")
        try require(plist["LSUIElement"] as? Bool == true, "LSUIElement deve ser true")
        try require(plist["LSMinimumSystemVersion"] as? String == "13.0", "macOS minimo deve ser 13.0")
        try require(plist["CFBundleIconFile"] as? String == "Icon", "CFBundleIconFile deve ser Icon")
        try require(plist["CFBundleIdentifier"] as? String == "local.menon.ContainerStatus",
                    "CFBundleIdentifier nao deve ser placeholder de template")
        try require(plist["CFBundleVersion"] == nil, "CFBundleVersion deve permanecer ausente")
        print("OK: Info.plist preserva produto, menu, icone e versao minima")
    }
} catch {
    FileHandle.standardError.write(Data("ERRO: \(error.localizedDescription)\n".utf8))
    exit(1)
}
SWIFT

if [[ $# -eq 1 ]]; then
  [[ -x "$1/Contents/MacOS/ContainerStatus" ]] || {
    echo "ERRO: Executavel ContainerStatus ausente ou sem permissao de execucao" >&2
    exit 1
  }
  cmp "$ROOT/Icon.icns" "$1/Contents/Resources/Icon.icns" || {
    echo "ERRO: Icone do bundle difere de Icon.icns" >&2
    exit 1
  }
  codesign --verify --deep --strict --all-architectures "$1"
  echo "OK: Icone do bundle identico e assinatura valida"
fi
