use std::collections::HashSet;
use std::path::PathBuf;

use chrono::Local;
use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager, State};
use tauri_plugin_dialog::DialogExt;
use tauri_plugin_opener::OpenerExt;

use crate::error::OatError;
use crate::recordings::{
    clear_error_file, list_recordings, new_recording_id, recording_from_files, write_error_file,
    RecordingItem,
};
use crate::settings::Settings;
use crate::transcription::{render_markdown, transcribe_wav, write_markdown, TranscriptContext};
use crate::AppState;

#[derive(Debug, Clone, Serialize)]
pub struct SessionState {
    pub recording: bool,
    pub recording_id: Option<String>,
    pub elapsed_ms: u64,
    pub transcribing: Vec<String>,
}

fn session_state(state: &AppState) -> SessionState {
    SessionState {
        recording: state.recorder.is_recording(),
        recording_id: state.recorder.current_id(),
        elapsed_ms: state.recorder.elapsed_ms(),
        transcribing: state
            .transcribing
            .lock()
            .expect("transcribing lock")
            .iter()
            .cloned()
            .collect(),
    }
}

fn emit_session(app: &AppHandle, state: &AppState) {
    let _ = app.emit("oat://session", session_state(state));
}

fn emit_recordings(app: &AppHandle) {
    let _ = app.emit("oat://recordings-changed", ());
}

#[tauri::command]
pub fn get_settings(state: State<AppState>) -> Settings {
    state.settings.lock().expect("settings lock").clone()
}

#[tauri::command]
pub fn save_settings(
    app: AppHandle,
    state: State<AppState>,
    settings: Settings,
) -> Result<Settings, OatError> {
    settings.save(&state.settings_path)?;
    *state.settings.lock().expect("settings lock") = settings.clone();
    emit_session(&app, &state);
    Ok(settings)
}

#[tauri::command]
pub async fn pick_storage_dir(
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<Option<PathBuf>, OatError> {
    let (tx, rx) = tokio::sync::oneshot::channel();
    app.dialog().file().pick_folder(move |folder| {
        let _ = tx.send(folder);
    });
    let picked = rx
        .await
        .map_err(|_| OatError::msg("Folder picker was cancelled"))?;
    let Some(file_path) = picked else {
        return Ok(None);
    };
    let path = file_path
        .into_path()
        .map_err(|error| OatError::msg(error.to_string()))?;
    let mut settings = state.settings.lock().expect("settings lock").clone();
    settings.storage_dir = Some(path.clone());
    settings.save(&state.settings_path)?;
    *state.settings.lock().expect("settings lock") = settings;
    emit_recordings(&app);
    Ok(Some(path))
}

#[tauri::command]
pub fn get_session(state: State<AppState>) -> SessionState {
    session_state(&state)
}

#[tauri::command]
pub fn list_library(state: State<AppState>) -> Result<Vec<RecordingItem>, OatError> {
    let settings = state.settings.lock().expect("settings lock").clone();
    let Some(dir) = settings.storage_dir else {
        return Ok(Vec::new());
    };
    let transcribing = state.transcribing.lock().expect("transcribing lock").clone();
    list_recordings(&dir, &transcribing)
}

#[tauri::command]
pub fn start_recording(app: AppHandle, state: State<AppState>) -> Result<SessionState, OatError> {
    let settings = state.settings.lock().expect("settings lock").clone();
    let dir = settings.storage_dir()?;
    let id = new_recording_id(Local::now());
    state.recorder.start(&dir, id)?;
    crate::tray::refresh_tray(&app, true);
    emit_session(&app, &state);
    emit_recordings(&app);
    Ok(session_state(&state))
}

#[tauri::command]
pub fn stop_recording(app: AppHandle, state: State<AppState>) -> Result<RecordingItem, OatError> {
    let finished = state.recorder.stop()?;
    crate::tray::refresh_tray(&app, false);
    let settings = state.settings.lock().expect("settings lock").clone();
    let dir = settings.storage_dir()?;
    state
        .transcribing
        .lock()
        .expect("transcribing lock")
        .insert(finished.id.clone());
    emit_session(&app, &state);
    emit_recordings(&app);

    let app_handle = app.clone();
    let finished_id = finished.id.clone();
    tauri::async_runtime::spawn(async move {
        transcribe_and_store(app_handle, finished).await;
    });

    let transcribing = state.transcribing.lock().expect("transcribing lock").clone();
    recording_from_files(&dir, &finished_id, &transcribing)
}

#[tauri::command]
pub fn retry_transcription(
    app: AppHandle,
    state: State<AppState>,
    id: String,
) -> Result<RecordingItem, OatError> {
    let settings = state.settings.lock().expect("settings lock").clone();
    let dir = settings.storage_dir()?;
    let wav = dir.join(format!("{id}.wav"));
    if !wav.exists() {
        return Err(OatError::msg("Recording file is missing"));
    }
    clear_error_file(&dir, &id);
    state
        .transcribing
        .lock()
        .expect("transcribing lock")
        .insert(id.clone());
    emit_session(&app, &state);
    emit_recordings(&app);

    let duration = crate::recordings::wav_duration_seconds(&wav).unwrap_or(0);
    let finished = crate::audio::FinishedRecording {
        id: id.clone(),
        path: wav,
        duration_seconds: duration,
        microphone: true,
        system: true,
    };
    let app_handle = app.clone();
    tauri::async_runtime::spawn(async move {
        transcribe_and_store(app_handle, finished).await;
    });

    let transcribing = state.transcribing.lock().expect("transcribing lock").clone();
    recording_from_files(&dir, &id, &transcribing)
}

#[tauri::command]
pub fn reveal_recording(app: AppHandle, state: State<AppState>, id: String) -> Result<(), OatError> {
    let settings = state.settings.lock().expect("settings lock").clone();
    let dir = settings.storage_dir()?;
    let md = dir.join(format!("{id}.md"));
    let wav = dir.join(format!("{id}.wav"));
    let path = if md.exists() { md } else { wav };
    app.opener()
        .open_path(path.to_string_lossy(), None::<&str>)
        .map_err(|error| OatError::msg(error.to_string()))?;
    Ok(())
}

#[tauri::command]
pub fn open_storage_dir(app: AppHandle, state: State<AppState>) -> Result<(), OatError> {
    let dir = state.settings.lock().expect("settings lock").storage_dir()?;
    app.opener()
        .open_path(dir.to_string_lossy(), None::<&str>)
        .map_err(|error| OatError::msg(error.to_string()))?;
    Ok(())
}

#[tauri::command]
pub fn hide_window(app: AppHandle) -> Result<(), OatError> {
    if let Some(window) = app.get_webview_window("main") {
        window
            .hide()
            .map_err(|error| OatError::msg(error.to_string()))?;
    }
    Ok(())
}

async fn transcribe_and_store(app: AppHandle, finished: crate::audio::FinishedRecording) {
    let Some(state) = app.try_state::<AppState>() else {
        return;
    };
    let settings = state.settings.lock().expect("settings lock").clone();
    let result = async {
        let dir = settings.storage_dir()?;
        let transcript = transcribe_wav(&finished.path, &settings).await?;
        let item = recording_from_files(&dir, &finished.id, &HashSet::new())?;
        let markdown = render_markdown(
            &TranscriptContext {
                id: finished.id.clone(),
                recorded_at: item.created_at,
                duration_seconds: finished.duration_seconds,
                audio_filename: format!("{}.wav", finished.id),
                microphone: finished.microphone,
                system: finished.system,
            },
            &transcript,
        );
        write_markdown(&dir.join(format!("{}.md", finished.id)), &markdown)?;
        clear_error_file(&dir, &finished.id);
        Ok::<(), OatError>(())
    }
    .await;

    if let Err(error) = result {
        if let Ok(dir) = settings.storage_dir() {
            let _ = write_error_file(&dir, &finished.id, &error.to_string());
        }
    }

    state
        .transcribing
        .lock()
        .expect("transcribing lock")
        .remove(&finished.id);
    emit_session(&app, &state);
    emit_recordings(&app);
}
