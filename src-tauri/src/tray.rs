use tauri::image::Image;
use tauri::menu::{Menu, MenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIcon, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Manager, PhysicalPosition, Rect};

use crate::error::OatError;
use crate::AppState;

const TRAY_ID: &str = "oat-tray";

pub fn setup(app: &AppHandle) -> Result<(), OatError> {
    let show = MenuItem::with_id(app, "show", "Open Oat", true, None::<&str>)
        .map_err(|error| OatError::msg(error.to_string()))?;
    let toggle = MenuItem::with_id(app, "toggle", "Start recording", true, None::<&str>)
        .map_err(|error| OatError::msg(error.to_string()))?;
    let quit = MenuItem::with_id(app, "quit", "Quit", true, None::<&str>)
        .map_err(|error| OatError::msg(error.to_string()))?;
    let menu = Menu::with_items(app, &[&show, &toggle, &quit])
        .map_err(|error| OatError::msg(error.to_string()))?;

    let icon = app
        .default_window_icon()
        .cloned()
        .or_else(|| Image::from_bytes(include_bytes!("../icons/32x32.png")).ok())
        .ok_or_else(|| OatError::msg("Missing tray icon"))?;

    TrayIconBuilder::with_id(TRAY_ID)
        .icon(icon)
        .icon_as_template(true)
        .tooltip("Oat")
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_menu_event(|app, event| match event.id().as_ref() {
            "show" => {
                if let Some(window) = app.get_webview_window("main") {
                    let _ = window.show();
                    let _ = window.set_focus();
                }
            }
            "toggle" => {
                let _ = toggle_recording(app);
            }
            "quit" => {
                app.exit(0);
            }
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            tauri_plugin_positioner::on_tray_event(tray.app_handle(), &event);
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                rect,
                ..
            } = event
            {
                toggle_window(tray.app_handle(), &rect);
            }
        })
        .build(app)
        .map_err(|error| OatError::msg(error.to_string()))?;

    Ok(())
}

pub fn refresh_tray(app: &AppHandle, recording: bool) {
    if let Some(tray) = app.tray_by_id(TRAY_ID) {
        let _ = tray.set_tooltip(Some(if recording {
            "Oat — recording"
        } else {
            "Oat"
        }));
        #[cfg(target_os = "macos")]
        {
            let _ = tray.set_title(Some(if recording { "●" } else { "" }));
        }
        let _ = update_toggle_label(&tray, app, recording);
    }
}

fn update_toggle_label(tray: &TrayIcon, app: &AppHandle, recording: bool) -> Result<(), OatError> {
    let show = MenuItem::with_id(app, "show", "Open Oat", true, None::<&str>)
        .map_err(|error| OatError::msg(error.to_string()))?;
    let toggle = MenuItem::with_id(
        app,
        "toggle",
        if recording {
            "Stop recording"
        } else {
            "Start recording"
        },
        true,
        None::<&str>,
    )
    .map_err(|error| OatError::msg(error.to_string()))?;
    let quit = MenuItem::with_id(app, "quit", "Quit", true, None::<&str>)
        .map_err(|error| OatError::msg(error.to_string()))?;
    let menu = Menu::with_items(app, &[&show, &toggle, &quit])
        .map_err(|error| OatError::msg(error.to_string()))?;
    tray.set_menu(Some(menu))
        .map_err(|error| OatError::msg(error.to_string()))?;
    Ok(())
}

fn toggle_recording(app: &AppHandle) -> Result<(), OatError> {
    let Some(state) = app.try_state::<AppState>() else {
        return Ok(());
    };
    if state.recorder.is_recording() {
        crate::commands::stop_recording(app.clone(), state)?;
    } else {
        crate::commands::start_recording(app.clone(), state)?;
    }
    Ok(())
}

fn toggle_window(app: &AppHandle, rect: &Rect) {
    let Some(window) = app.get_webview_window("main") else {
        return;
    };
    if window.is_visible().unwrap_or(false) {
        let _ = window.hide();
        return;
    }
    position_under_tray(&window, rect);
    let _ = window.show();
    let _ = window.set_focus();
}

fn position_under_tray(window: &tauri::WebviewWindow, rect: &Rect) {
    let size = window.outer_size().ok();
    let win_w = size.map(|s| s.width as f64).unwrap_or(360.0);
    let win_h = size.map(|s| s.height as f64).unwrap_or(540.0);
    let tray_x = rect.position.x;
    let tray_y = rect.position.y;
    let tray_w = rect.size.width;
    let tray_h = rect.size.height;

    let mut x = tray_x + (tray_w / 2.0) - (win_w / 2.0);
    let mut y = tray_y + tray_h + 8.0;

    if let Ok(Some(monitor)) = window.current_monitor() {
        let screen = monitor.position();
        let screen_size = monitor.size();
        let screen_bottom = screen.y as f64 + screen_size.height as f64;
        if tray_y > screen.y as f64 + (screen_size.height as f64 / 2.0) {
            y = tray_y - win_h - 8.0;
        }
        x = x.clamp(
            screen.x as f64 + 8.0,
            screen.x as f64 + screen_size.width as f64 - win_w - 8.0,
        );
        y = y.clamp(screen.y as f64 + 8.0, screen_bottom - win_h - 8.0);
    }

    let _ = window.set_position(PhysicalPosition::new(x.round() as i32, y.round() as i32));
}
