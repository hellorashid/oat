export type Provider = "openai" | "groq" | "custom";

export type RecordingStatus = "ready" | "transcribing" | "needs_key" | "failed";

export interface Settings {
  storage_dir: string | null;
  api_key: string;
  provider: Provider;
  model: string;
  base_url: string;
}

export interface SessionState {
  recording: boolean;
  recording_id: string | null;
  elapsed_ms: number;
  transcribing: string[];
}

export interface RecordingItem {
  id: string;
  created_at: string;
  duration_seconds: number | null;
  wav_path: string;
  md_path: string | null;
  status: RecordingStatus;
  error: string | null;
}
