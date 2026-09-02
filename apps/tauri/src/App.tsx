import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { useCallback, useEffect, useState } from "react";
import oatMark from "./assets/oat-mark.svg";
import type { RecordingItem, SessionState, Settings } from "./types";

const OPENAI_MODELS = [
  {
    id: "gpt-4o-transcribe",
    label: "GPT-4o Transcribe",
    hint: "Best accuracy",
  },
  {
    id: "gpt-4o-mini-transcribe",
    label: "GPT-4o Mini Transcribe",
    hint: "Fast & affordable",
  },
  {
    id: "whisper-1",
    label: "Whisper",
    hint: "Classic Whisper",
  },
] as const;

const defaultSettings: Settings = {
  storage_dir: null,
  api_key: "",
  provider: "openai",
  model: "gpt-4o-mini-transcribe",
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
  const [permissionBusy, setPermissionBusy] = useState(false);
  const [permissionNote, setPermissionNote] = useState<string | null>(null);
  const [permissionStatus, setPermissionStatus] = useState<{
    system_audio: string;
    microphone: string;
    from_app_bundle: boolean;
  } | null>(null);

  const loadLibrary = useCallback(async () => {
    const items = await invoke<RecordingItem[]>("list_library");
    setRecordings(items);
  }, []);

  const refreshPermissions = useCallback(async () => {
    try {
      const status = await invoke<{
        system_audio: string;
        microphone: string;
        from_app_bundle: boolean;
      }>("get_permission_status");
      setPermissionStatus(status);
    } catch {
      // ignore — permissions UI is best-effort
    }
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
        setSettings({
          ...nextSettings,
          provider: "openai",
          model: OPENAI_MODELS.some((item) => item.id === nextSettings.model)
            ? nextSettings.model
            : defaultSettings.model,
        });
        setSession(nextSession);
        if (!nextSettings.storage_dir) {
          setTab("settings");
        }
        await loadLibrary();
        await refreshPermissions();
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
    const onFocus = () => {
      void refreshPermissions();
    };
    window.addEventListener("focus", onFocus);

    return () => {
      disposed = true;
      window.removeEventListener("keydown", onKey);
      window.removeEventListener("focus", onFocus);
      void unlistenSession.then((unlisten) => unlisten());
      void unlistenLibrary.then((unlisten) => unlisten());
    };
  }, [loadLibrary, refreshPermissions]);

  const canRecord = Boolean(settings.storage_dir);

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
      const next = await invoke<Settings>("save_settings", {
        settings: {
          ...settings,
          provider: "openai",
          base_url: "",
        },
      });
      setSettings({ ...next, provider: "openai" });
    } catch (saveError) {
      setError(String(saveError));
    } finally {
      setSaving(false);
    }
  }

  async function openPrivacy(pane: "microphone" | "system_audio") {
    setError(null);
    try {
      await invoke("open_privacy_settings", { pane });
    } catch (privacyError) {
      setError(String(privacyError));
    }
  }

  async function requestPermissions() {
    setPermissionBusy(true);
    setError(null);
    setPermissionNote(null);
    try {
      const status = await invoke<{
        system_audio: string;
        granted: boolean;
        identity: string;
        from_app_bundle: boolean;
        note: string;
      }>("request_system_permissions");
      setPermissionNote(
        `System audio: ${status.system_audio}${status.from_app_bundle ? "" : " (not from Oat.dev.app)"}. ${status.note}`,
      );
      await refreshPermissions();
    } catch (permissionError) {
      setError(String(permissionError));
    } finally {
      setPermissionBusy(false);
    }
  }

  function permissionLabel(value: string): string {
    switch (value) {
      case "granted":
        return "Granted";
      case "denied":
        return "Not granted";
      case "not_determined":
        return "Not requested yet";
      case "unavailable":
        return "Unavailable";
      default:
        return value;
    }
  }

  return (
    <div className="app">
      <header className="header" data-tauri-drag-region>
        <div className="brand">
          <img className="brand-mark" src={oatMark} alt="" width={22} height={22} />
          <h1>Oat</h1>
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
            onClick={() => {
              setTab("settings");
              void refreshPermissions();
            }}
          >
            Settings
          </button>
        </div>
      </header>

      {tab === "recordings" ? (
        <>
          <section className="recorder compact">
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
            {error ? <div className="error">{error}</div> : null}
          </section>

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
                    {item.error && item.status !== "needs_key" ? (
                      <div className="item-error">{item.error}</div>
                    ) : null}
                    <div className="item-actions">
                      <button
                        className="icon-button"
                        title="Show in Finder"
                        aria-label="Show in Finder"
                        onClick={() => void invoke("reveal_recording", { id: item.id })}
                      >
                        <svg
                          width="14"
                          height="14"
                          viewBox="0 0 16 16"
                          fill="none"
                          aria-hidden="true"
                        >
                          <path
                            d="M1.5 4.5A1.5 1.5 0 0 1 3 3h3.2l1.1 1.2H13A1.5 1.5 0 0 1 14.5 5.7v6.3A1.5 1.5 0 0 1 13 13.5H3A1.5 1.5 0 0 1 1.5 12V4.5Z"
                            stroke="currentColor"
                            strokeWidth="1.3"
                            strokeLinejoin="round"
                          />
                        </svg>
                      </button>
                      {item.status === "failed" || item.status === "needs_key" ? (
                        <button
                          className="retry"
                          onClick={() => void invoke("retry_transcription", { id: item.id })}
                        >
                          Retry transcript
                        </button>
                      ) : null}
                    </div>
                  </div>
                ))}
              </div>
            )}
          </section>
        </>
      ) : (
        <section className="panel settings-panel">
          {error ? <div className="error">{error}</div> : null}
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
            Bring your own OpenAI key. Audio is sent to OpenAI’s speech-to-text
            API; recordings stay on this computer.
          </p>
          <div className="field">
            <label>Model</label>
            <select
              value={settings.model}
              onChange={(event) =>
                setSettings((current) => ({
                  ...current,
                  provider: "openai",
                  model: event.target.value,
                }))
              }
            >
              {OPENAI_MODELS.map((model) => (
                <option key={model.id} value={model.id}>
                  {model.label} — {model.hint}
                </option>
              ))}
            </select>
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
          <button className="primary" onClick={() => void save()} disabled={saving}>
            {saving ? "Saving…" : "Save settings"}
          </button>

          <h2 style={{ marginTop: 22 }}>System permissions</h2>
          <p className="help">
            Meeting audio needs macOS system-audio access (Screen &amp; System
            Audio Recording). After enabling, quit and reopen Oat if status
            stays denied.
          </p>
          {permissionStatus ? (
            <div className="permission-status">
              <div className="permission-row">
                <span
                  className={`permission-dot ${permissionStatus.microphone}`}
                  aria-hidden="true"
                />
                <span>Microphone</span>
                <strong>{permissionLabel(permissionStatus.microphone)}</strong>
              </div>
              <div className="permission-row">
                <span
                  className={`permission-dot ${permissionStatus.system_audio}`}
                  aria-hidden="true"
                />
                <span>System audio</span>
                <strong>{permissionLabel(permissionStatus.system_audio)}</strong>
              </div>
            </div>
          ) : null}
          <div className="permission-actions">
            <button
              className="ghost"
              onClick={() => void requestPermissions()}
              disabled={permissionBusy}
            >
              {permissionBusy ? "Requesting…" : "Request system audio access"}
            </button>
            <button
              className="ghost"
              onClick={() => {
                void openPrivacy("system_audio");
                window.setTimeout(() => void refreshPermissions(), 1000);
              }}
            >
              Open system audio settings
            </button>
            <button
              className="ghost"
              onClick={() => {
                void openPrivacy("microphone");
                window.setTimeout(() => void refreshPermissions(), 1000);
              }}
            >
              Open microphone settings
            </button>
            <button className="ghost" onClick={() => void refreshPermissions()}>
              Refresh status
            </button>
          </div>
          {permissionNote ? <p className="help permission-note">{permissionNote}</p> : null}
        </section>
      )}
    </div>
  );
}
