use serde::Serialize;
use tauri::AppHandle;

use crate::error::OatError;

pub const BUNDLE_ID: &str = "com.raz.oat";
const DEV_APP_NAME: &str = "Oat.dev.app";

#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum PrivacyPane {
    Microphone,
    SystemAudio,
}

#[derive(Debug, Clone, Serialize)]
pub struct PermissionStatus {
    pub system_audio: String,
    pub granted: bool,
    pub identity: String,
    pub from_app_bundle: bool,
    pub note: String,
}

pub fn open_privacy_pane(pane: PrivacyPane) -> Result<(), OatError> {
    #[cfg(target_os = "macos")]
    {
        let urls: &[&str] = match pane {
            PrivacyPane::Microphone => &[
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone",
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
            ],
            PrivacyPane::SystemAudio => &[
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AudioCapture",
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
                "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture",
            ],
        };
        for url in urls {
            let status = std::process::Command::new("open").arg(url).status();
            if matches!(status, Ok(s) if s.success()) {
                return Ok(());
            }
        }
        Err(OatError::msg("Could not open System Settings"))
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = pane;
        Err(OatError::msg(
            "System permission settings are only available on macOS",
        ))
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct PermissionSnapshot {
    pub system_audio: String,
    pub microphone: String,
    pub from_app_bundle: bool,
    pub identity: String,
}

pub fn permission_snapshot() -> PermissionSnapshot {
    #[cfg(target_os = "macos")]
    {
        PermissionSnapshot {
            system_audio: if preflight_system_audio() {
                "granted".into()
            } else {
                "denied".into()
            },
            microphone: microphone_authorization_label(),
            from_app_bundle: running_from_dev_app(),
            identity: current_identity_label(),
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        PermissionSnapshot {
            system_audio: "unavailable".into(),
            microphone: "unavailable".into(),
            from_app_bundle: false,
            identity: "n/a".into(),
        }
    }
}

pub fn has_system_audio_access() -> bool {
    #[cfg(target_os = "macos")]
    {
        preflight_system_audio()
    }
    #[cfg(not(target_os = "macos"))]
    {
        true
    }
}

pub fn system_audio_denied_message() -> String {
    format!(
        "System audio is blocked. Enable Oat under System Settings → Privacy & Security → Screen & System Audio Recording (look for “Oat” / {DEV_APP_NAME} / {BUNDLE_ID}), then quit Oat completely and reopen."
    )
}

/// Request system-audio capture access only.
pub fn request_capture_permissions(_app: &AppHandle) -> Result<PermissionStatus, OatError> {
    #[cfg(target_os = "macos")]
    {
        let from_app_bundle = running_from_dev_app();
        let identity = current_identity_label();

        if !from_app_bundle {
            return Ok(PermissionStatus {
                system_audio: "wrong_binary".into(),
                granted: false,
                identity,
                from_app_bundle: false,
                note:
                    "Oat is running as a bare dev binary, so macOS can't attribute permission to it. Launch the built Oat.app and request again."
                        .into(),
            });
        }

        activate_app();
        let granted_before = preflight_system_audio();
        let _ = request_system_audio_access();
        let _ = probe_shareable_content();
        std::thread::sleep(std::time::Duration::from_millis(400));
        let granted_after = preflight_system_audio();

        if !granted_after {
            let _ = open_privacy_pane(PrivacyPane::SystemAudio);
        }

        let status = if granted_after {
            "granted"
        } else if granted_before {
            "denied"
        } else {
            "prompted"
        };

        Ok(PermissionStatus {
            system_audio: status.into(),
            granted: granted_after,
            identity,
            from_app_bundle: true,
            note: if granted_after {
                "System audio access is granted. You can start recording.".into()
            } else {
                "System Settings should be open. Enable “Oat” under Screen & System Audio Recording, then quit Oat completely (tray → Quit) and reopen before recording.".into()
            },
        })
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = _app;
        Ok(PermissionStatus {
            system_audio: "unavailable".into(),
            granted: false,
            identity: "n/a".into(),
            from_app_bundle: false,
            note: "Permission prompts are handled by your OS when you start recording.".into(),
        })
    }
}

/// Package the debug binary as Oat.dev.app and open it via LaunchServices.
///
/// Launching with `open` detaches from Ghostty/Terminal so TCC attributes
/// Screen & System Audio permission to Oat instead of the terminal.
// Dev-only helper: not wired into run() (the shipped Oat.app already gets the
// correct TCC identity). Kept for `tauri dev`, where you can call it to relaunch
// as a signed bundle so permissions attribute to Oat instead of the terminal.
#[cfg(target_os = "macos")]
#[allow(dead_code)]
pub fn ensure_dev_codesign() {
    if !cfg!(debug_assertions) {
        return;
    }

    let Ok(exe) = std::env::current_exe() else {
        return;
    };
    let Some(exe_str) = exe.to_str() else {
        return;
    };

    let in_bundle = exe_str.contains(DEV_APP_NAME);
    let identity_ok = current_codesign_identity(exe_str).as_deref() == Some(BUNDLE_ID);
    let under_dev_launcher = parent_is_dev_launcher();

    // True LaunchServices start: bundled, signed, not a child of Ghostty/cargo/node.
    if in_bundle && identity_ok && !under_dev_launcher {
        eprintln!("oat: running from {DEV_APP_NAME} as {BUNDLE_ID} (LaunchServices)");
        return;
    }

    let Some(debug_dir) = exe.parent().and_then(|p| {
        if in_bundle {
            p.ancestors().nth(3)
        } else {
            Some(p)
        }
    }) else {
        return;
    };

    let cargo_binary = debug_dir.join("oat");
    let source = if cargo_binary.exists() {
        cargo_binary
    } else {
        exe.clone()
    };

    let app_dir = debug_dir.join(DEV_APP_NAME);
    let contents = app_dir.join("Contents");
    let macos_dir = contents.join("MacOS");
    let bundled_exe = macos_dir.join("Oat");
    let info_plist = contents.join("Info.plist");

    if let Err(error) = std::fs::create_dir_all(&macos_dir) {
        eprintln!("oat: could not create {DEV_APP_NAME}: {error}");
        return;
    }

    if let Err(error) = std::fs::copy(&source, &bundled_exe) {
        eprintln!("oat: could not copy binary into {DEV_APP_NAME}: {error}");
        return;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&bundled_exe, std::fs::Permissions::from_mode(0o755));
    }

    let plist = format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>Oat</string>
  <key>CFBundleIdentifier</key>
  <string>{BUNDLE_ID}</string>
  <key>CFBundleName</key>
  <string>Oat</string>
  <key>CFBundleDisplayName</key>
  <string>Oat</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>0.1.0</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Oat records your microphone so transcripts include your voice.</string>
  <key>NSScreenCaptureUsageDescription</key>
  <string>Oat captures system audio from meetings such as Zoom and Google Meet so it can transcribe them.</string>
</dict>
</plist>
"#
    );
    if let Err(error) = std::fs::write(&info_plist, plist) {
        eprintln!("oat: could not write Info.plist: {error}");
        return;
    }

    let entitlements = concat!(env!("CARGO_MANIFEST_DIR"), "/entitlements.plist");
    let status = std::process::Command::new("codesign")
        .args([
            "-s",
            "-",
            "-f",
            "--deep",
            "--identifier",
            BUNDLE_ID,
            "--entitlements",
            entitlements,
        ])
        .arg(&app_dir)
        .status();

    if !matches!(status, Ok(s) if s.success()) {
        eprintln!("oat: could not codesign {DEV_APP_NAME}");
        return;
    }

    // Drop any prior instance so `open -n` doesn't stack trays.
    let _ = std::process::Command::new("pkill")
        .args(["-f", "Oat.dev.app/Contents/MacOS/Oat"])
        .status();
    std::thread::sleep(std::time::Duration::from_millis(200));

    eprintln!(
        "oat: opening {DEV_APP_NAME} via LaunchServices so TCC shows Oat (not Ghostty/Terminal)"
    );
    let status = std::process::Command::new("open")
        .args(["-W", "-n"])
        .arg(&app_dir)
        .status();

    let code = status.ok().and_then(|s| s.code()).unwrap_or(1);
    std::process::exit(code);
}

#[cfg(not(target_os = "macos"))]
pub fn ensure_dev_codesign() {}

#[cfg(target_os = "macos")]
#[allow(dead_code)]
fn parent_is_dev_launcher() -> bool {
    let Some(name) = parent_process_name() else {
        return true;
    };
    let lower = name.to_lowercase();
    const HINTS: &[&str] = &[
        "ghostty",
        "terminal",
        "iterm",
        "kitty",
        "alacritty",
        "warp",
        "vscode",
        "cursor",
        "cargo",
        "node",
        "npm",
        "pnpm",
        "bun",
        "deno",
        "zsh",
        "bash",
        "fish",
        "sh",
        "tauri",
        "rustc",
        "esbuild",
    ];
    HINTS.iter().any(|hint| lower.contains(hint))
}

#[cfg(target_os = "macos")]
#[allow(dead_code)]
fn parent_process_name() -> Option<String> {
    let ppid = std::os::unix::process::parent_id();
    let output = std::process::Command::new("ps")
        .args(["-o", "comm=", "-p"])
        .arg(ppid.to_string())
        .output()
        .ok()?;
    let name = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if name.is_empty() {
        None
    } else {
        Some(name)
    }
}
#[cfg(target_os = "macos")]
fn running_from_dev_app() -> bool {
    // True when running from any packaged .app bundle (the shipped Oat.app or a
    // dev bundle) — as opposed to a bare `cargo`/`tauri dev` binary, where TCC
    // would attribute Screen Recording to the launching terminal instead of Oat.
    std::env::current_exe()
        .ok()
        .and_then(|p| p.to_str().map(|s| s.contains(".app/Contents/MacOS/")))
        .unwrap_or(false)
}

#[cfg(target_os = "macos")]
fn current_identity_label() -> String {
    std::env::current_exe()
        .ok()
        .and_then(|p| {
            let path = p.display().to_string();
            let id = p
                .to_str()
                .and_then(current_codesign_identity)
                .unwrap_or_else(|| "unknown".into());
            Some(format!("{id} @ {path}"))
        })
        .unwrap_or_else(|| "unknown".into())
}

#[cfg(target_os = "macos")]
fn current_codesign_identity(exe: &str) -> Option<String> {
    let output = std::process::Command::new("codesign")
        .args(["-dv", exe])
        .output()
        .ok()?;
    let stderr = String::from_utf8_lossy(&output.stderr);
    for line in stderr.lines() {
        if let Some(id) = line.strip_prefix("Identifier=") {
            return Some(id.trim().to_string());
        }
    }
    None
}

#[cfg(target_os = "macos")]
fn activate_app() {
    use objc2_app_kit::NSApplication;
    use objc2_foundation::MainThreadMarker;

    let Some(mtm) = MainThreadMarker::new() else {
        return;
    };
    let app = NSApplication::sharedApplication(mtm);
    #[allow(deprecated)]
    app.activateIgnoringOtherApps(true);
}

#[cfg(target_os = "macos")]
fn microphone_authorization_label() -> String {
    use std::ffi::CStr;

    use objc2::runtime::AnyClass;
    use objc2::msg_send;
    use objc2_foundation::NSString;

    #[link(name = "AVFoundation", kind = "framework")]
    extern "C" {}

    let name = CStr::from_bytes_with_nul(b"AVCaptureDevice\0").unwrap();
    let Some(class) = AnyClass::get(name) else {
        return "unknown".into();
    };
    // AVMediaTypeAudio == "soun"
    let media_type = NSString::from_str("soun");
    // 0 notDetermined, 1 restricted, 2 denied, 3 authorized
    let status: isize =
        unsafe { msg_send![class, authorizationStatusForMediaType: &*media_type] };
    match status {
        3 => "granted".into(),
        2 | 1 => "denied".into(),
        0 => "not_determined".into(),
        _ => "unknown".into(),
    }
}

#[cfg(target_os = "macos")]
fn preflight_system_audio() -> bool {
    objc2_core_graphics::CGPreflightScreenCaptureAccess()
}

#[cfg(target_os = "macos")]
fn request_system_audio_access() -> bool {
    objc2_core_graphics::CGRequestScreenCaptureAccess()
}

#[cfg(target_os = "macos")]
fn probe_shareable_content() -> bool {
    use std::sync::mpsc;
    use std::time::Duration;

    use block2::RcBlock;
    use objc2_foundation::NSError;
    use objc2_screen_capture_kit::SCShareableContent;

    let (tx, rx) = mpsc::channel();
    let block = RcBlock::new(move |content: *mut SCShareableContent, error: *mut NSError| {
        let ok = error.is_null() && !content.is_null();
        let _ = tx.send(ok);
    });
    unsafe {
        SCShareableContent::getShareableContentWithCompletionHandler(&block);
    }
    rx.recv_timeout(Duration::from_secs(3)).unwrap_or(false)
}
