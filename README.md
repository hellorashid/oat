# Oat

A tiny menubar recorder. Pick a local folder, start a recording from the tray, and Oat saves the audio plus a markdown transcript on your machine.

It is a deliberately small Granola-style workflow: no note editor, no playback UI, no account.

## What it does

1. You choose a folder for recordings and transcripts.
2. You start and stop capture from the menu bar.
3. Oat records your microphone and, when the OS allows it, system audio from meetings (Zoom, Meet, and similar).
4. The session is written as a `.wav` file.
5. If you have added an API key, Oat transcribes the file with Whisper (or a compatible API) and writes a sibling `.md` file.

## Storage layout

```
your-folder/
  2026-08-17-143052.wav
  2026-08-17-143052.md
```

The markdown file links to the audio next to it. Open either file with whatever local apps you already use.

## Setup

### Prerequisites

- Rust 1.85+ (stable)
- Node.js 20+ and [pnpm](https://pnpm.io)
- [Tauri 2 Linux/macOS/Windows dependencies](https://v2.tauri.app/start/prerequisites/)

### Run

```bash
pnpm install
pnpm tauri dev
```

The app lives in the menu bar / system tray. Click the tray icon to open the popover. Right-click for Start/Stop, Open, and Quit.

### Permissions

- **macOS 13+:** allow Microphone and Screen Recording for Oat. Screen Recording is how system/meeting audio is captured via ScreenCaptureKit.
- **Windows:** system audio uses WASAPI loopback from the default playback device.
- **Linux:** Oat looks for a PulseAudio/PipeWire monitor or other loopback device. If none exists, it records the microphone only.

## Transcription

Settings accepts a bring-your-own key:

- OpenAI (`whisper-1`)
- Groq (`whisper-large-v3`)
- Any OpenAI-compatible `/v1/audio/transcriptions` base URL

The key is stored locally in the app data directory. Long recordings are split before upload to stay under typical 25 MB API limits.

## Build

```bash
pnpm tauri build
```
