# Oat

A tiny meeting recorder for your Mac.

Pick a folder, start a recording, and Oat writes a `.wav` plus a markdown transcript next to it. It lives in the menu bar. No account, no cloud workspace — bring your own editor and agent.

[oat.raz.lol](https://oat.raz.lol)

## What it does

- Records your microphone and, when macOS allows it, system audio from meetings (Zoom, Meet, and similar)
- Transcribes on this Mac with [WhisperKit](https://github.com/argmaxinc/WhisperKit) after you download a model, or optionally with OpenAI. Transcription is off until you turn it on.
- Saves files in a folder you choose
- Stays in the menu bar when the window is closed

## Privacy

Audio and transcripts stay on your machine by default. Whisper models download only when you choose Download in Settings, then run locally. If you switch the engine to OpenAI, audio is uploaded to OpenAI with a key you paste in Settings.

Settings (folder path, API key, model) live in the app’s Application Support directory, not in this repo.

## Download

Grab the latest macOS DMG from [Releases](https://github.com/hellorashid/oat/releases/latest).

Grant **Microphone** and **System Audio Recording Only** (under Screen & System Audio Recording). Oat uses a Core Audio tap, not screen capture.

## Native macOS

macOS 14+. Full Xcode is required.

```bash
open apps/macos/Oat.xcodeproj
```

Run the **Oat** scheme. See [`apps/macos/README.md`](apps/macos/README.md) for permissions, on-device Whisper, and Developer ID / notarized releases.

## Tauri

A cross-platform port lives in [`apps/tauri`](apps/tauri). Same on-disk format; transcription is cloud-only (OpenAI, Groq, or a compatible API).

```bash
pnpm install
pnpm tauri dev
```

See [`apps/tauri/README.md`](apps/tauri/README.md) for permissions and packaging.

## Storage

```
your-folder/
  2026-08-17-143052.wav
  2026-08-17-143052.md
```

Both apps can point at the same folder.
