# Oat (native macOS)

SwiftUI recorder for macOS 14+. Same product as the Tauri app: pick a folder, record mic + system audio, write `{id}.wav` and a sibling `{id}.md`.

## Run

Full **Xcode** is required (the Command Line Tools package cannot build this app). Open this project:

```bash
open apps/macos/Oat.xcodeproj
```

Run the **Oat** scheme. The app opens a regular window and also lives in the menu bar (no Dock icon). Closing the window leaves Oat running; click the tray icon for Start/Stop, Open Oat, Settings, and Quit.

Or from the command line:

```bash
xcodebuild -project apps/macos/Oat.xcodeproj -scheme Oat -configuration Debug build
```

## Release (Developer ID + notarization)

Release builds sign with **Developer ID Application: Basic Studio Inc (UBWBPNVBAN)**, enable hardened runtime, and do not inject `get-task-allow`.

One-time: store notary credentials in the keychain (Apple ID + [app-specific password](https://appleid.apple.com)):

```bash
./apps/macos/scripts/setup-notary.sh
```

Then archive, export, notarize, and staple:

```bash
./apps/macos/scripts/release.sh
```

That writes `releases/v{version}/Oat.app` and `Oat_{version}_universal.dmg`. Use `SKIP_NOTARY=1` to produce a signed DMG without submitting it.

Debug runs from Xcode stay ad-hoc so local iteration does not require the Developer ID cert.

## Permissions

Grant **Microphone** and **System Audio Recording Only** (under Screen & System Audio Recording). Oat uses a Core Audio tap, not screen capture.

TCC attributes to the `.app` bundle. Run from Xcode or a built app, not a raw binary.

## Storage

Recordings use the same layout as the Tauri app, so both can share a folder:

```
your-folder/
  2026-08-17-143052.wav
  2026-08-17-143052.md
```

Settings (folder path, API key, model) live in this app’s Application Support directory (`com.raz.oat.macos`), separate from Tauri (`com.raz.oat`).

## Updates

The app checks [GitHub Releases](https://github.com/hellorashid/oat/releases/latest) on launch and every few hours. Settings shows the current version and an Update button when a newer tag is published. Upload a macOS `.dmg` (or `.zip` of `Oat.app`) on the release — `Oat_0.1.0_aarch64.dmg` is picked on Apple Silicon.

## Transcription

By default, new installs transcribe **on this Mac** with [WhisperKit](https://github.com/argmaxinc/WhisperKit) (Core ML Whisper, not whisper.cpp). Pick a multilingual or English-only model in Settings (Tiny through Large v3) and download it, or let the first recording fetch the selected model. Files stay local. You can also turn transcription off.

OpenAI is still available: switch the transcription engine, pick a cloud model, and paste an API key. Audio is then uploaded to OpenAI.

Whisper models are stored under Application Support (`com.raz.oat.macos/whisperkit/`).
