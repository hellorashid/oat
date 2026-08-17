import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { useCallback, useEffect, useMemo, useState } from "react";
import type { Provider, RecordingItem, SessionState, Settings } from "./types";

const defaultSettings: Settings = {
  storage_dir: null,
  api_key: "",
  provider: "openai",
  model: "whisper-1",
  base_url: "",
};

const defaultSession: SessionState = {
  recording: false,
  recording_id: null,
  elapsed_ms: 0,
  transcribing: [],
};

function formatElapsed(ms: number): string {
  const total = Math.floor(ms / 1000);
  const minutes = Math.floor(total / 60)
    .toString()
    .padStart(2, "0");
  const seconds = (total % 60).toString().padStart(2, "0");
  return `${minutes}:${seconds}`;
}

function formatWhen(value: string): string {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return value;
  }
  return date.toLocaleString(undefined, {
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
  });
}

function formatDuration(seconds: number | null): string {
  if (seconds == null) {
    return "—";
  }
  const minutes = Math.floor(seconds / 60);
  const rest = seconds % 60;
  return `${minutes}m ${rest.toString().padStart(2, "0")}s`;
}

function statusLabel(status: RecordingItem["status"]): string {
  switch (status) {
    case "ready":
      return "transcribed";
    case "transcribing":
      return "transcribing";
    case "needs_key":
      return "needs api key";
    case "failed":
      return "failed";
  }
}

export default function App() {
  const [tab, setTab] = useState<"recordings" | "settings">("recordings");
  const [settings, setSettings] = useState<Settings>(defaultSettings);
  const [session, setSession] = useState<SessionState>(defaultSession);
  const [recordings, setRecordings] = useState<RecordingItem[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  const loadLibrary = useCallback(async () => {
    const items = await invoke<RecordingItem[]>("list_library");
    setRecordings(items);
  }, []);

  useEffect(() => {
    let disposed = false;

    async function boot() {
      try {
        const [nextSettings, nextSession] = await Promise.all([
          invoke<Settings>("get_settings"),
          invoke<SessionState>("get_session"),
        ]);
        if (disposed) {
          return;
        }
        setSettings(nextSettings);
        setSession(nextSession);
        if (!nextSettings.storage_dir) {
          setTab("settings");
        }
        await loadLibrary();
      } catch (bootError) {
        setError(String(bootError));
      }
    }

    boot();

    const unlistenSession = listen<SessionState>("oat://session", (event) => {
      setSession(event.payload);
    });
    const unlistenLibrary = listen("oat://recordings-changed", () => {
      void loadLibrary();
    });

    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        void invoke("hide_window");
      }
    };
    window.addEventListener("keydown", onKey);

    return () => {
      disposed = true;
      window.removeEventListener("keydown", onKey);
      void unlistenSession.then((unlisten) => unlisten());
      void unlistenLibrary.then((unlisten) => unlisten());
    };
  }, [loadLibrary]);

  const canRecord = Boolean(settings.storage_dir);
  const recordHint = useMemo(() => {
    if (!settings.storage_dir) {
      return "Choose a folder in Settings before recording.";
    }
    if (session.recording) {
      return "Capturing your microphone and system audio. Click to stop.";
    }
    if (!settings.api_key) {
      return "Ready to record. Add an API key to transcribe afterward.";
    }
    return "Records your voice and meeting audio, then writes a local transcript.";
  }, [session.recording, settings.api_key, settings.storage_dir]);

  async function toggleRecording() {
    setError(null);
    try {
      if (session.recording) {
        await invoke("stop_recording");
      } else {
        await invoke("start_recording");
      }
      await loadLibrary();
    } catch (toggleError) {
      setError(String(toggleError));
    }
  }

  async function chooseFolder() {
    setError(null);
    try {
      const path = await invoke<string | null>("pick_storage_dir");
      if (path) {
        setSettings((current) => ({ ...current, storage_dir: path }));
        await loadLibrary();
      }
    } catch (folderError) {
      setError(String(folderError));
    }
  }

  async function save() {
    setSaving(true);
    setError(null);
    try {
      const next = await invoke<Settings>("save_settings", { settings });
      setSettings(next);
    } catch (saveError) {
      setError(String(saveError));
    } finally {
      setSaving(false);
    }
  }

  async function changeProvider(provider: Provider) {
    const model =
      provider === "groq"
        ? "whisper-large-v3"
        : provider === "openai"
          ? "whisper-1"
          : settings.model;
    setSettings((current) => ({ ...current, provider, model }));
  }

  return (
    <div className="app">
      <header className="header" data-tauri-drag-region>
        <div className="brand">
          <h1>Oat</h1>
          <span>local notes</span>
        </div>
        <div className="tabs">
          <button
            className={tab === "recordings" ? "active" : ""}
            onClick={() => setTab("recordings")}
          >
            Recordings
          </button>
          <button
            className={tab === "settings" ? "active" : ""}
            onClick={() => setTab("settings")}
          >
            Settings
          </button>
        </div>
      </header>

      <section className="recorder">
        <button
          className={`record-button${session.recording ? " live" : ""}`}
          onClick={() => void toggleRecording()}
          disabled={!canRecord && !session.recording}
          aria-label={session.recording ? "Stop recording" : "Start recording"}
        >
          <span className="record-glyph" />
        </button>
        <div className="timer">
          {session.recording ? formatElapsed(session.elapsed_ms) : "Start recording"}
        </div>
        <p className="hint">{recordHint}</p>
        {error ? <div className="error">{error}</div> : null}
      </section>

      {tab === "recordings" ? (
        <section className="panel">
          <h2>Library</h2>
          {recordings.length === 0 ? (
            <div className="empty">
              Nothing here yet. Start a recording from the menu bar and Oat
              will keep the audio and markdown in your chosen folder.
            </div>
          ) : (
            <div className="list">
              {recordings.map((item) => (
                <div className="item" key={item.id}>
                  <div
                    role="button"
                    tabIndex={0}
                    onClick={() => void invoke("reveal_recording", { id: item.id })}
                    onKeyDown={(event) => {
                      if (event.key === "Enter" || event.key === " ") {
                        void invoke("reveal_recording", { id: item.id });
                      }
                    }}
                  >
                    <div className="item-top">
                      <strong>{formatWhen(item.created_at)}</strong>
                      <span>{formatDuration(item.duration_seconds)}</span>
                    </div>
                    <div className="item-meta">
                      <span className={`status ${item.status}`}>
                        {statusLabel(item.status)}
                      </span>
                      <span>{item.id}</span>
                    </div>
                  </div>
                  {item.error ? <div className="item-error">{item.error}</div> : null}
                  {item.status === "failed" || item.status === "needs_key" ? (
                    <button
                      className="retry"
                      onClick={() => void invoke("retry_transcription", { id: item.id })}
                    >
                      Retry transcript
                    </button>
                  ) : null}
                </div>
              ))}
            </div>
          )}
        </section>
      ) : (
        <section className="panel">
          <h2>Storage</h2>
          <p className="help">
            Recordings and transcripts stay on this computer. Oat never hosts
            your files.
          </p>
          <div className="field">
            <label>Folder</label>
            <div className="row">
              <input
                readOnly
                value={settings.storage_dir ?? ""}
                placeholder="Choose a local folder"
              />
              <button className="ghost" onClick={() => void chooseFolder()}>
                Browse
              </button>
            </div>
          </div>
          {settings.storage_dir ? (
            <button className="ghost" onClick={() => void invoke("open_storage_dir")}>
              Open folder
            </button>
          ) : null}

          <h2 style={{ marginTop: 22 }}>Transcription</h2>
          <p className="help">
            Bring your own key. OpenAI Whisper, Groq, or any compatible
            `/v1/audio/transcriptions` endpoint.
          </p>
          <div className="field">
            <label>Provider</label>
            <select
              value={settings.provider}
              onChange={(event) => void changeProvider(event.target.value as Provider)}
            >
              <option value="openai">OpenAI</option>
              <option value="groq">Groq</option>
              <option value="custom">Compatible API</option>
            </select>
          </div>
          {settings.provider === "custom" ? (
            <div className="field">
              <label>Base URL</label>
              <input
                value={settings.base_url}
                placeholder="https://api.example.com/v1"
                onChange={(event) =>
                  setSettings((current) => ({
                    ...current,
                    base_url: event.target.value,
                  }))
                }
              />
            </div>
          ) : null}
          <div className="field">
            <label>Model</label>
            <input
              value={settings.model}
              onChange={(event) =>
                setSettings((current) => ({ ...current, model: event.target.value }))
              }
            />
          </div>
          <div className="field">
            <label>API key</label>
            <input
              type="password"
              value={settings.api_key}
              placeholder="sk-..."
              onChange={(event) =>
                setSettings((current) => ({ ...current, api_key: event.target.value }))
              }
            />
          </div>
          <p className="help">
            On macOS, allow Microphone and Screen Recording for Oat so meeting
            audio can be captured. On Linux, a Pulse/PipeWire monitor device is
            used when available.
          </p>
          <button className="primary" onClick={() => void save()} disabled={saving}>
            {saving ? "Saving…" : "Save settings"}
          </button>
        </section>
      )}
    </div>
  );
}
