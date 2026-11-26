#!/usr/bin/env bash
# Builds NoPeek.app into ./build.
#   SIGN_IDENTITY="NoPeek Local Signing" scripts/build-app.sh   # stable identity (permissions survive rebuilds)
#   scripts/build-app.sh                                        # ad-hoc signing
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="${CONFIG:-release}"
APP="$ROOT/build/NoPeek.app"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"

# Prefer the local signing identity if it exists (see scripts/create-signing-identity.sh).
if [[ -z "$SIGN_IDENTITY" ]] && security find-identity -p codesigning 2>/dev/null | grep -q "NoPeek Local Signing"; then
  SIGN_IDENTITY="NoPeek Local Signing"
fi

echo "▸ Compiling ($CONFIG)…"
swift build -c "$CONFIG" --arch arm64
BIN="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)/NoPeek"

echo "▸ Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/NoPeek"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

if [[ ! -f "$ROOT/build/AppIcon.icns" ]]; then
  echo "▸ Rendering icon…"
  swift "$ROOT/scripts/make-icon.swift" "$ROOT/build/AppIcon.iconset" >/dev/null
  iconutil -c icns "$ROOT/build/AppIcon.iconset" -o "$ROOT/build/AppIcon.icns"
fi
cp "$ROOT/build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

echo "▸ Signing (${SIGN_IDENTITY:-ad-hoc})…"
codesign --force --options runtime --sign "${SIGN_IDENTITY:--}" \
  --entitlements "$ROOT/Resources/NoPeek.entitlements" "$APP"

echo "✓ Built $APP"
