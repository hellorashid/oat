#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "macos")]
mod macos;
mod mic;
mod mixer;
mod resample;
mod system;
#[cfg(target_os = "windows")]
mod windows;

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::Instant;

use crate::error::OatError;

pub use mixer::MixStats;
pub use resample::TARGET_SAMPLE_RATE;

pub struct Recorder {
    inner: Mutex<Option<ActiveRecording>>,
}

struct ActiveRecording {
    stop: Arc<AtomicBool>,
    started_at: Instant,
    path: PathBuf,
    id: String,
    workers: Vec<JoinHandle<()>>,
    mixer: Option<JoinHandle<Result<MixStats, OatError>>>,
}

#[derive(Debug, Clone)]
pub struct FinishedRecording {
    pub id: String,
    pub path: PathBuf,
    pub duration_seconds: u64,
    pub microphone: bool,
    pub system: bool,
}

impl Recorder {
    pub fn new() -> Self {
        Self {
            inner: Mutex::new(None),
        }
    }

    pub fn is_recording(&self) -> bool {
        self.inner.lock().expect("recorder lock").is_some()
    }

    pub fn elapsed_ms(&self) -> u64 {
        self.inner
            .lock()
            .expect("recorder lock")
            .as_ref()
            .map(|active| active.started_at.elapsed().as_millis() as u64)
            .unwrap_or(0)
    }

    pub fn current_id(&self) -> Option<String> {
        self.inner
            .lock()
            .expect("recorder lock")
            .as_ref()
            .map(|active| active.id.clone())
    }

    pub fn start(&self, storage_dir: &Path, id: String) -> Result<PathBuf, OatError> {
        let mut slot = self.inner.lock().expect("recorder lock");
        if slot.is_some() {
            return Err(OatError::msg("A recording is already in progress"));
        }
        std::fs::create_dir_all(storage_dir)?;
        let path = storage_dir.join(format!("{id}.wav"));

        let stop = Arc::new(AtomicBool::new(false));
        let mic_sink = mixer::SampleSink::new();
        let system_sink = mixer::SampleSink::new();
        let mut workers = Vec::new();

        match mic::spawn_microphone(mic_sink.clone(), stop.clone()) {
            Ok(handle) => workers.push(handle),
            Err(error) => eprintln!("oat: microphone unavailable: {error}"),
        }

        match system::spawn_system_audio(system_sink.clone(), stop.clone()) {
            Ok(handle) => workers.push(handle),
            Err(error) => eprintln!("oat: system audio unavailable: {error}"),
        }

        if workers.is_empty() {
            return Err(OatError::msg(
                "Could not open a microphone or system audio source",
            ));
        }

        let mix_path = path.clone();
        let mix_stop = stop.clone();
        let mixer = std::thread::Builder::new()
            .name("oat-mixer".into())
            .spawn(move || mixer::write_mixed_wav(&mix_path, &mic_sink, &system_sink, &mix_stop))
            .map_err(OatError::from)?;

        *slot = Some(ActiveRecording {
            stop,
            started_at: Instant::now(),
            path: path.clone(),
            id,
            workers,
            mixer: Some(mixer),
        });
        Ok(path)
    }

    pub fn stop(&self) -> Result<FinishedRecording, OatError> {
        let mut slot = self.inner.lock().expect("recorder lock");
        let mut active = slot.take().ok_or_else(|| OatError::msg("Not recording"))?;
        active.stop.store(true, Ordering::Relaxed);
        let started_at = active.started_at;
        let path = active.path.clone();
        let id = active.id.clone();
        let mixer = active.mixer.take();
        let workers = std::mem::take(&mut active.workers);
        drop(slot);

        for worker in workers {
            let _ = worker.join();
        }
        let stats = mixer
            .ok_or_else(|| OatError::msg("Mixer thread missing"))?
            .join()
            .map_err(|_| OatError::msg("Mixer thread panicked"))??;

        let duration_seconds = if stats.frames == 0 {
            started_at.elapsed().as_secs()
        } else {
            stats.frames / TARGET_SAMPLE_RATE as u64
        };

        Ok(FinishedRecording {
            id,
            path,
            duration_seconds,
            microphone: stats.microphone,
            system: stats.system,
        })
    }
}

impl Default for Recorder {
    fn default() -> Self {
        Self::new()
    }
}
