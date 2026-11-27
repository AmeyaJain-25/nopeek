#!/usr/bin/env bash
# Packages build/NoPeek.app into build/NoPeek-<version>.dmg (drag-to-Applications layout).
#   scripts/make-dmg.sh          # uses the already-built app (run `make build` first)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="$ROOT/build/NoPeek.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
DMG="$ROOT/build/NoPeek-$VERSION.dmg"
STAGING="$ROOT/build/dmg-staging"

[[ -d "$APP" ]] || { echo "✗ $APP not found — run 'make build' first" >&2; exit 1; }

echo "▸ Staging…"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
# ditto --norsrc drops resource forks / Finder metadata; xattr -cr clears any remaining extended attributes.
ditto --norsrc "$APP" "$STAGING/NoPeek.app"
xattr -cr "$STAGING/NoPeek.app"
ln -s /Applications "$STAGING/Applications"

echo "▸ Creating ${DMG}…"
# hdiutil intermittently fails with "Resource busy" (Spotlight/diskarbitrationd); retry a few times.
for attempt in 1 2 3 4 5; do
  if hdiutil create -volname "NoPeek" -srcfolder "$STAGING" -fs HFS+ -ov -format UDZO "$DMG" >/dev/null; then
    break
  fi
  [[ $attempt -eq 5 ]] && { echo "✗ hdiutil failed" >&2; exit 1; }
  echo "  hdiutil busy, retrying ($attempt)…"; sleep 2
done
rm -rf "$STAGING"

echo "✓ Built $DMG"
