#!/usr/bin/env bash
set -euo pipefail

CONF=${1:-release}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

APP_NAME=${APP_NAME:-ContainerStatus}
BUNDLE_ID=${BUNDLE_ID:-local.ContainerStatus}
MACOS_MIN_VERSION=${MACOS_MIN_VERSION:-13.0}
MENU_BAR_APP=${MENU_BAR_APP:-1}
SIGNING_MODE=${SIGNING_MODE:-}
APP_IDENTITY=${APP_IDENTITY:-}

# APP_NAME vai para rm -rf e ambos para o Info.plist: so nomes simples.
for value in "$APP_NAME" "$BUNDLE_ID"; do
  if [[ ! "$value" =~ ^[A-Za-z0-9._-]+$ || "$value" == *..* ]]; then
    echo "Invalid APP_NAME/BUNDLE_ID: $value" >&2
    exit 1
  fi
done

read_version_env() {
  local file=$1 line key value
  local saw_marketing=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line%$'\r'}
    [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" == *=* ]] || { echo "Invalid version.env line" >&2; return 1; }
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      MARKETING_VERSION)
        [[ "$value" =~ ^[0-9]+(\.[0-9]+){1,3}([+-][0-9A-Za-z.-]+)?$ ]] || {
          echo "Invalid MARKETING_VERSION in version.env" >&2; return 1;
        }
        MARKETING_VERSION=$value
        saw_marketing=1
        ;;
      *) echo "Unknown key in version.env: $key" >&2; return 1 ;;
    esac
  done < "$file"
  (( saw_marketing == 1 )) || {
    echo "version.env must define MARKETING_VERSION" >&2
    return 1
  }
}

verify_binary_arches() {
  local binary="$1"; shift
  local expected=("$@")
  local actual
  actual=$(lipo -archs "$binary")
  local actual_arches
  read -r -a actual_arches <<< "$actual"
  if [[ ${#actual_arches[@]} -ne ${#expected[@]} ]]; then
    echo "ERROR: $binary arch mismatch (expected: ${expected[*]}, actual: ${actual})" >&2
    exit 1
  fi
  for arch in "${expected[@]}"; do
    if [[ " $actual " != *" $arch "* ]]; then
      echo "ERROR: $binary missing arch $arch (have: ${actual})" >&2
      exit 1
    fi
  done
}

if [[ -f "$ROOT/version.env" ]]; then
  read_version_env "$ROOT/version.env"
else
  MARKETING_VERSION=${MARKETING_VERSION:-0.1.0}
fi

read -r -a ARCH_LIST <<< "${ARCHES:-}"
if [[ ${#ARCH_LIST[@]} -eq 0 ]]; then
  HOST_ARCH=$(uname -m)
  ARCH_LIST=("$HOST_ARCH")
fi

BUILD_ARGS=(-c "$CONF" --product "$APP_NAME")
for ARCH in "${ARCH_LIST[@]}"; do
  BUILD_ARGS+=(--arch "$ARCH")
done
swift build "${BUILD_ARGS[@]}"
BUILD_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
verify_binary_arches "$BUILD_DIR/$APP_NAME" "${ARCH_LIST[@]}"

APP="$ROOT/${APP_NAME}.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
ICON_TARGET="$ROOT/Icon.icns"

LSUI_VALUE="false"
if [[ "$MENU_BAR_APP" == "1" ]]; then
  LSUI_VALUE="true"
fi

BUILD_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
BUILD_DATE=$(date -u +"%Y-%m-%d")
GIT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${MARKETING_VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>${MACOS_MIN_VERSION}</string>
    <key>LSUIElement</key><${LSUI_VALUE}/>
    <key>CFBundleIconFile</key><string>Icon</string>
    <key>BuildTimestamp</key><string>${BUILD_TIMESTAMP}</string>
    <key>BuildDate</key><string>${BUILD_DATE}</string>
    <key>GitCommit</key><string>${GIT_COMMIT}</string>
</dict>
</plist>
PLIST

cp "$BUILD_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
chmod +x "$APP/Contents/MacOS/$APP_NAME"

if [[ -f "$ICON_TARGET" ]]; then
  cp "$ICON_TARGET" "$APP/Contents/Resources/Icon.icns"
fi

# Ensure contents are writable before stripping attributes and signing.
chmod -R u+w "$APP"

# Strip extended attributes to prevent AppleDouble files that break code sealing.
xattr -cr "$APP"
find "$APP" -name '._*' -delete

# Sem entitlements: o app nao precisa de nenhum (README, politica de
# privilegios). Identidade real liga hardened runtime e timestamp.
if [[ "$SIGNING_MODE" == "adhoc" || -z "$APP_IDENTITY" ]]; then
  CODESIGN_ARGS=(--force --sign "-")
else
  CODESIGN_ARGS=(--force --timestamp --options runtime --sign "$APP_IDENTITY")
fi

codesign "${CODESIGN_ARGS[@]}" "$APP"

echo "Created $APP"
