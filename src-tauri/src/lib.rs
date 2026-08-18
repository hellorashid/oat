mod audio;
mod commands;
mod error;
mod recordings;
mod settings;
mod transcription;
mod tray;

use std::collections::HashSet;
use std::sync::Mutex;

use tauri::{Emitter, Manager};

use crate::audio::Recorder;
use crate::settings::{settings_path, Settings};

pub struct AppState {
    pub settings: Mutex<Settings>,
    pub settings_path: std::path::PathBuf,
    pub recorder: Recorder,
    pub transcribing: Mutex<HashSet<String>>,
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| {
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.show();
                let _ = window.set_focus();
            }
        }))
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_positioner::init())
        .setup(|app| {
            let app_data = app
                .path()
                .app_data_dir()
                .unwrap_or_else(|_| std::env::temp_dir().join("oat"));
            std::fs::create_dir_all(&app_data)?;
            let settings_file = settings_path(&app_data);
            let settings = Settings::load(&settings_file).unwrap_or_default();
            let first_run = settings.storage_dir.is_none();

            app.manage(AppState {
                settings: Mutex::new(settings),
                settings_path: settings_file,
                recorder: Recorder::new(),
                transcribing: Mutex::new(HashSet::new()),
            });

            tray::setup(app.handle())?;

            if let Some(window) = app.get_webview_window("main") {
                let hide = window.clone();
                window.on_window_event(move |event| match event {
                    tauri::WindowEvent::CloseRequested { api, .. } => {
                        api.prevent_close();
                        let _ = hide.hide();
                    }
                    tauri::WindowEvent::Focused(false) => {
                        let _ = hide.hide();
                    }
                    _ => {}
                });
                if first_run {
                    let _ = window.show();
                    let _ = window.set_focus();
                }
            }

            let handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                let mut ticker = tokio::time::interval(std::time::Duration::from_millis(250));
                loop {
                    ticker.tick().await;
                    if let Some(state) = handle.try_state::<AppState>() {
                        if state.recorder.is_recording() {
                            let _ = handle.emit(
                                "oat://session",
                                commands::get_session(state),
                            );
                        }
                    }
                }
            });

            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            commands::get_settings,
            commands::save_settings,
            commands::pick_storage_dir,
            commands::get_session,
            commands::list_library,
            commands::start_recording,
            commands::stop_recording,
            commands::retry_transcription,
            commands::reveal_recording,
            commands::open_storage_dir,
            commands::hide_window,
        ])
        .run(tauri::generate_context!())
        .expect("error while running oat");
}
