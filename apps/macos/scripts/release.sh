#!/usr/bin/env bash
# Build a Developer ID–signed, notarized Oat.app + .dmg.
#
# One-time setup:
#   ./apps/macos/scripts/setup-notary.sh
#
# Then:
#   ./apps/macos/scripts/release.sh
#
# Skip notarization (signed DMG only):
#   SKIP_NOTARY=1 ./apps/macos/scripts/release.sh
set -euo pipefail

MACOS="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$MACOS/../.." && pwd)"
PROJECT="$MACOS/Oat.xcodeproj"
SCHEME="Oat"
TEAM_ID="UBWBPNVBAN"
IDENTITY="Developer ID Application: Basic Studio Inc ($TEAM_ID)"
PROFILE="${NOTARY_PROFILE:-oat-notary}"
BUILD="$MACOS/build/release"
ARCHIVE="$BUILD/Oat.xcarchive"
EXPORT="$BUILD/export"
EXPORT_OPTIONS="$MACOS/ExportOptions.plist"

cd "$MACOS"

VERSION="$(awk -F' = ' '/MARKETING_VERSION/{gsub(/;/, "", $2); print $2; exit}' "$PROJECT/project.pbxproj")"
if [[ -z "$VERSION" ]]; then
  echo "Could not read MARKETING_VERSION from the Xcode project." >&2
  exit 1
fi

OUT="$REPO/releases/v${VERSION}"
DMG_NAME="Oat_${VERSION}_universal.dmg"

if ! security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
  echo "Missing signing identity: $IDENTITY" >&2
  echo "Install a Developer ID Application certificate for team $TEAM_ID." >&2
  exit 1
fi

if [[ "${SKIP_NOTARY:-}" != "1" ]]; then
  if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "Notary keychain profile '${PROFILE}' is not set up." >&2
    echo "Run: ./apps/macos/scripts/setup-notary.sh" >&2
    echo "Or skip notarization with SKIP_NOTARY=1." >&2
    exit 1
  fi
fi

echo "==> Archiving Oat ${VERSION} (Developer ID, universal)"
rm -rf "$BUILD"
mkdir -p "$BUILD"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -archivePath "$ARCHIVE" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  archive

echo "==> Exporting Developer ID app"
xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT" \
  -exportOptionsPlist "$EXPORT_OPTIONS"

APP="$EXPORT/Oat.app"
if [[ ! -d "$APP" ]]; then
  echo "Export did not produce Oat.app" >&2
  exit 1
fi

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign --display --verbose=2 "$APP"
if codesign --display --entitlements - "$APP" 2>/dev/null | grep -q "get-task-allow"; then
  echo "Release entitlements still include get-task-allow; aborting." >&2
  exit 1
fi

echo "==> Assembling ${DMG_NAME}"
"$REPO/scripts/pack-dmg.sh" "$APP" "$OUT/$DMG_NAME" "Oat"

if [[ "${SKIP_NOTARY:-}" == "1" ]]; then
  echo "==> Skipping notarization (SKIP_NOTARY=1)"
else
  echo "==> Submitting ${DMG_NAME} to notary service"
  xcrun notarytool submit "$OUT/$DMG_NAME" \
    --keychain-profile "$PROFILE" \
    --wait

  echo "==> Stapling"
  xcrun stapler staple "$OUT/$DMG_NAME"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$OUT/$DMG_NAME"
fi

echo "==> Copying .app into $OUT"
rm -rf "$OUT/Oat.app"
cp -R "$APP" "$OUT/"

echo "==> Done"
ls -lh "$OUT"
echo "Open with: open \"$OUT/Oat.app\""
echo "Or mount:  open \"$OUT/$DMG_NAME\""
