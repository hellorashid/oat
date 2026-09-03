#!/usr/bin/env bash
# Assemble a styled macOS DMG: Oat.app + Applications shortcut + custom background.
#
# Usage:
#   ./scripts/pack-dmg.sh <path-to-Oat.app> <output.dmg> [volume-name]
#
# Requires: hdiutil, osascript, SetFile (Xcode CLT) or chflags.
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <Oat.app> <output.dmg> [volume-name]" >&2
  exit 1
fi

APP="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
OUT="$2"
VOLUME_NAME="${3:-Oat}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
BG_SRC="$REPO/assets/dmg/background.tiff"
BG_PNG="$REPO/assets/dmg/background.png"
BG_PNG2X="$REPO/assets/dmg/background@2x.png"

if [[ ! -d "$APP" ]]; then
  echo "App not found: $APP" >&2
  exit 1
fi

# Prefer multi-rep TIFF for Retina Finder; build it from PNGs when missing.
if [[ ! -f "$BG_SRC" ]]; then
  if [[ -f "$BG_PNG" && -f "$BG_PNG2X" ]] && command -v tiffutil >/dev/null 2>&1; then
    echo "==> Building background.tiff from PNGs"
    TMP_TIFF="$(mktemp -d "${TMPDIR:-/tmp}/oat-dmg-bg.XXXXXX")"
    sips -s format tiff "$BG_PNG" --out "$TMP_TIFF/1x.tiff" >/dev/null
    sips -s format tiff "$BG_PNG2X" --out "$TMP_TIFF/2x.tiff" >/dev/null
    tiffutil -cathalp "$TMP_TIFF/1x.tiff" "$TMP_TIFF/2x.tiff" -out "$BG_SRC"
    rm -rf "$TMP_TIFF"
  elif [[ -f "$BG_PNG" ]]; then
    BG_SRC="$BG_PNG"
  fi
fi
if [[ ! -f "$BG_SRC" ]]; then
  echo "Missing DMG background. Run: swift scripts/generate-dmg-background.swift assets/dmg ." >&2
  exit 1
fi

# Finder window / icon layout (matches Paper DMG Background: TL → BR).
WINDOW_W=800
WINDOW_H=500
# Finder window bounds include the title bar (~22px); pad height so the
# 800×500 background fills the content area without clipping.
TITLEBAR=22
ICON_SIZE=128
APP_X=160
APP_Y=160
APPS_X=640
APPS_Y=360

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/oat-dmg.XXXXXX")"
RW_DMG="$(mktemp "${TMPDIR:-/tmp}/oat-dmg-rw.XXXXXX").dmg"
MOUNT_DIR=""
cleanup() {
  if [[ -n "$MOUNT_DIR" && -d "$MOUNT_DIR" ]]; then
    hdiutil detach "$MOUNT_DIR" -quiet -force 2>/dev/null || true
  fi
  # Detach by device if AppleScript left it mounted under /Volumes
  if [[ -d "/Volumes/$VOLUME_NAME" ]]; then
    hdiutil detach "/Volumes/$VOLUME_NAME" -quiet -force 2>/dev/null || true
  fi
  rm -rf "$STAGE"
  rm -f "$RW_DMG"
}
trap cleanup EXIT

echo "==> Staging"
# Avoid "Oat 1" mounts if a previous preview is still open.
if [[ -d "/Volumes/$VOLUME_NAME" || -d "/Volumes/${VOLUME_NAME} 1" ]]; then
  echo "Ejecting existing '${VOLUME_NAME}' volume(s)…"
  osascript -e "tell application \"Finder\" to eject (every disk whose name starts with \"$VOLUME_NAME\")" 2>/dev/null || true
  hdiutil detach "/Volumes/$VOLUME_NAME" -force 2>/dev/null || true
  hdiutil detach "/Volumes/${VOLUME_NAME} 1" -force 2>/dev/null || true
  sleep 1
fi

cp -R "$APP" "$STAGE/Oat.app"
ln -s /Applications "$STAGE/Applications"
# Note: do not put .background in the srcfolder — hdiutil drops dotdirs.
# We copy the background onto the mounted volume below.

# Size estimate: app + background + slack for Finder metadata.
APP_KB="$(du -sk "$STAGE" | awk '{print $1}')"
BG_KB="$(du -sk "$BG_SRC" | awk '{print $1}')"
SIZE_MB=$(( (APP_KB + BG_KB) / 1024 + 30 ))
if (( SIZE_MB < 50 )); then SIZE_MB=50; fi

mkdir -p "$(dirname "$OUT")"
# Absolute output path (hdiutil is picky about relative paths after cd).
if [[ "$OUT" != /* ]]; then
  OUT="$(pwd)/$OUT"
fi
rm -f "$OUT"

echo "==> Creating read-write DMG (${SIZE_MB}MB)"
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGE" \
  -ov \
  -fs HFS+ \
  -format UDRW \
  -size "${SIZE_MB}m" \
  "$RW_DMG"

echo "==> Mounting"
MOUNT_DIR="$(hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG" | awk '/\/Volumes\//{print $NF; exit}')"
if [[ -z "$MOUNT_DIR" || ! -d "$MOUNT_DIR" ]]; then
  echo "Failed to mount $RW_DMG" >&2
  exit 1
fi

echo "==> Installing background"
mkdir -p "$MOUNT_DIR/.background"
# Always name it background.tiff inside the volume (PNG works too if that's the source).
BG_NAME="background.tiff"
if [[ "$BG_SRC" == *.png ]]; then
  BG_NAME="background.png"
fi
cp "$BG_SRC" "$MOUNT_DIR/.background/$BG_NAME"

# Bless the volume so Finder opens this folder view.
if command -v bless >/dev/null 2>&1; then
  bless --folder "$MOUNT_DIR" --openfolder "$MOUNT_DIR" 2>/dev/null || true
fi

# Hide the background folder from Finder (invisible bit).
hide_support_files() {
  local root="$1"
  if command -v SetFile >/dev/null 2>&1; then
    [[ -e "$root/.background" ]] && SetFile -a V "$root/.background" || true
    [[ -e "$root/.fseventsd" ]] && SetFile -a V "$root/.fseventsd" || true
    [[ -e "$root/.Trashes" ]] && SetFile -a V "$root/.Trashes" || true
    [[ -e "$root/.TemporaryItems" ]] && SetFile -a V "$root/.TemporaryItems" || true
  else
    [[ -e "$root/.background" ]] && chflags hidden "$root/.background" || true
    [[ -e "$root/.fseventsd" ]] && chflags hidden "$root/.fseventsd" || true
  fi
}

hide_support_files "$MOUNT_DIR"

echo "==> Styling Finder window"
# Give Finder a moment to register the volume.
sleep 2

osascript <<EOF
tell application "Finder"
  tell disk "$VOLUME_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 100, $((200 + WINDOW_W)), $((100 + WINDOW_H + TITLEBAR))}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to $ICON_SIZE
    set text size of viewOptions to 12
    set background picture of viewOptions to file ".background:$BG_NAME"
    set position of item "Oat.app" of container window to {$APP_X, $APP_Y}
    set position of item "Applications" of container window to {$APPS_X, $APPS_Y}
    update without registering applications
    delay 2
    close
    open
    delay 1
    close
  end tell
end tell
EOF

# Ensure .DS_Store is flushed before detach.
sync
sleep 1

echo "==> Scrubbing support files"
# Drop ephemeral Finder/system dirs so they aren't baked into the UDZO.
# (They reappear while the RW image is mounted; final users won't see them
# unless they have "Show Hidden Files" on — then Cmd+Shift+. hides them.)
rm -rf "$MOUNT_DIR/.fseventsd" "$MOUNT_DIR/.Trashes" "$MOUNT_DIR/.TemporaryItems"
hide_support_files "$MOUNT_DIR"
sync
sleep 1

echo "==> Detaching"
# Close any leftover Finder windows on this volume first.
osascript <<EOF || true
tell application "Finder"
  try
    close (every window whose name is "$VOLUME_NAME")
  end try
end tell
EOF
hdiutil detach "$MOUNT_DIR" -quiet || hdiutil detach "$MOUNT_DIR" -force
MOUNT_DIR=""
# Volume name mount may linger
if [[ -d "/Volumes/$VOLUME_NAME" ]]; then
  hdiutil detach "/Volumes/$VOLUME_NAME" -quiet -force 2>/dev/null || true
fi

echo "==> Compressing"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$OUT"
# internet-enable is obsolete on modern macOS; ignore failures.
hdiutil internet-enable -quiet -no "$OUT" 2>/dev/null || true

echo "==> Packed $OUT"
ls -lh "$OUT"
