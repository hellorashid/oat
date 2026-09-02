# Oat

A tiny recorder. Pick a local folder, start a recording, and Oat saves the audio plus a markdown transcript on your machine. The native Mac app uses a regular window and stays in the menu bar when that window is closed.

This repo has two apps that share the same on-disk format (`{id}.wav` + `{id}.md` in a folder you choose):

| App | Path | Use when |
| --- | --- | --- |
| Tauri (React + Rust) | [`apps/tauri`](apps/tauri) | Cross-platform (macOS, Windows, Linux) |
| Native macOS (SwiftUI) | [`apps/macos`](apps/macos) | macOS-only, simpler native shell |

## Tauri

```bash
pnpm install
pnpm tauri dev
```

See [`apps/tauri/README.md`](apps/tauri/README.md) for permissions, transcription, and packaging.

## Native macOS

Open [`apps/macos/Oat.xcodeproj`](apps/macos/Oat.xcodeproj) in Xcode (macOS 14+) and run the Oat scheme. See [`apps/macos/README.md`](apps/macos/README.md).

## Storage layout

```
your-folder/
  2026-08-17-143052.wav
  2026-08-17-143052.md
```

Both apps can point at the same folder. Settings (API key, folder path, local Whisper model) are stored per app.

The native Mac app can transcribe on-device with WhisperKit (pick a model in Settings; it downloads on first use). OpenAI remains optional. The Tauri app still uses a cloud API key.
