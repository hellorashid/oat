#!/usr/bin/env bash
# Build a local macOS build of Oat (.app + .dmg).
#
# Notes for macOS 26/27 betas:
# - The strip=none workaround in src-tauri/.cargo/config.toml is required, or
#   proc-macro dylibs fail to load ("mis-aligned LINKEDIT string pool").
# - Tauri's bundle_dmg.sh (Finder/AppleScript styling) is flaky on the beta, so
#   we build the .app with Tauri and assemble the .dmg with hdiutil instead.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(node -p "require('./package.json').version")"
REPO="$(cd "$ROOT/../.." && pwd)"
OUT="$REPO/releases/v${VERSION}"
APP="src-tauri/target/release/bundle/macos/Oat.app"
DMG_NAME="Oat_${VERSION}_aarch64.dmg"

echo "==> Frontend + Tauri app bundle (.app only)"
pnpm build
pnpm exec tauri bundle --bundles app --no-sign --ci

echo "==> Ad-hoc codesign"
codesign --force --deep --sign - "$APP"

echo "==> Assembling ${DMG_NAME}"
"$REPO/scripts/pack-dmg.sh" "$APP" "$OUT/$DMG_NAME" "Oat"

echo "==> Copying .app into $OUT"
rm -rf "$OUT/Oat.app"
cp -R "$APP" "$OUT/"

echo "==> Done"
ls -lh "$OUT"
echo "Open with: open \"$OUT/Oat.app\""
echo "Or mount:  open \"$OUT/$DMG_NAME\""
