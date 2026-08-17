use std::sync::atomic::AtomicBool;
use std::sync::Arc;
use std::thread::JoinHandle;

use crate::audio::mixer::SampleSink;
use crate::error::OatError;

pub fn spawn_system_audio(
    sink: SampleSink,
    stop: Arc<AtomicBool>,
) -> Result<JoinHandle<()>, OatError> {
    #[cfg(target_os = "macos")]
    {
        crate::audio::macos::spawn(sink, stop)
    }
    #[cfg(target_os = "windows")]
    {
        crate::audio::windows::spawn(sink, stop)
    }
    #[cfg(target_os = "linux")]
    {
        crate::audio::linux::spawn(sink, stop)
    }
    #[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "linux")))]
    {
        let _ = (sink, stop);
        Err(OatError::msg(
            "System audio capture is not supported on this platform",
        ))
    }
}

pub fn is_loopback_device_name(name: &str) -> bool {
    let name = name.to_lowercase();
    const HINTS: &[&str] = &[
        "monitor",
        "loopback",
        "stereo mix",
        "what u hear",
        "blackhole",
        "soundflower",
        "vb-audio",
        "cable input",
        "cable output",
    ];
    HINTS.iter().any(|hint| name.contains(hint))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_pulse_monitor_names() {
        assert!(is_loopback_device_name(
            "Monitor of Built-in Audio Analog Stereo"
        ));
        assert!(!is_loopback_device_name("Built-in Microphone"));
    }
}
