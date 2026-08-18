use std::collections::VecDeque;
use std::fs::File;
use std::io::BufWriter;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use hound::{WavSpec, WavWriter};

use crate::audio::resample::TARGET_SAMPLE_RATE;
use crate::error::OatError;

const BACKLOG_BEFORE_SOLO: usize = TARGET_SAMPLE_RATE as usize / 10;
const MAX_BUFFER_SAMPLES: usize = TARGET_SAMPLE_RATE as usize * 30;

#[derive(Clone)]
pub struct SampleSink {
    pub buf: Arc<Mutex<VecDeque<f32>>>,
    pub active: Arc<AtomicBool>,
}

impl SampleSink {
    pub fn new() -> Self {
        Self {
            buf: Arc::new(Mutex::new(VecDeque::new())),
            active: Arc::new(AtomicBool::new(false)),
        }
    }

    pub fn push(&self, samples: &[f32]) {
        if samples.is_empty() {
            return;
        }
        self.active.store(true, Ordering::Relaxed);
        let mut buf = self.buf.lock().expect("sample buffer lock");
        buf.extend(samples.iter().copied());
        if buf.len() > MAX_BUFFER_SAMPLES {
            let overflow = buf.len() - MAX_BUFFER_SAMPLES;
            buf.drain(..overflow);
        }
    }
}

#[derive(Debug, Clone)]
pub struct MixStats {
    pub frames: u64,
    pub microphone: bool,
    pub system: bool,
}

pub fn mix_available(
    mic: &mut VecDeque<f32>,
    system: &mut VecDeque<f32>,
    allow_solo: bool,
) -> Vec<f32> {
    if mic.is_empty() && system.is_empty() {
        return Vec::new();
    }

    if !mic.is_empty() && !system.is_empty() {
        let n = mic.len().min(system.len());
        return (0..n)
            .map(|_| {
                let mixed = mic.pop_front().unwrap_or(0.0) + system.pop_front().unwrap_or(0.0);
                mixed.clamp(-1.0, 1.0)
            })
            .collect();
    }

    if !allow_solo {
        return Vec::new();
    }

    if system.is_empty() && mic.len() >= BACKLOG_BEFORE_SOLO {
        return mic.drain(..).collect();
    }
    if mic.is_empty() && system.len() >= BACKLOG_BEFORE_SOLO {
        return system.drain(..).collect();
    }

    Vec::new()
}

pub fn write_mixed_wav(
    path: &Path,
    mic: &SampleSink,
    system: &SampleSink,
    stop: &AtomicBool,
) -> Result<MixStats, OatError> {
    let spec = WavSpec {
        channels: 1,
        sample_rate: TARGET_SAMPLE_RATE,
        bits_per_sample: 16,
        sample_format: hound::SampleFormat::Int,
    };
    let mut writer = WavWriter::create(path, spec)?;
    let mut frames = 0u64;

    while !stop.load(Ordering::Relaxed) {
        frames += flush_once(&mut writer, mic, system, false)?;
        std::thread::sleep(Duration::from_millis(20));
    }

    std::thread::sleep(Duration::from_millis(80));
    frames += flush_once(&mut writer, mic, system, true)?;
    writer.finalize()?;

    Ok(MixStats {
        frames,
        microphone: mic.active.load(Ordering::Relaxed),
        system: system.active.load(Ordering::Relaxed),
    })
}

fn flush_once(
    writer: &mut WavWriter<BufWriter<File>>,
    mic: &SampleSink,
    system: &SampleSink,
    final_pass: bool,
) -> Result<u64, OatError> {
    let mut mic_buf = mic.buf.lock().expect("mic lock");
    let mut sys_buf = system.buf.lock().expect("system lock");
    let mixed = mix_available(&mut mic_buf, &mut sys_buf, final_pass);
    drop(mic_buf);
    drop(sys_buf);

    for sample in &mixed {
        writer.write_sample((*sample * 32767.0) as i16)?;
    }
    Ok(mixed.len() as u64)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mixes_equal_length_streams() {
        let mut mic = VecDeque::from([0.4, 0.2]);
        let mut system = VecDeque::from([0.1, 0.1]);
        let out = mix_available(&mut mic, &mut system, false);
        assert!((out[0] - 0.5).abs() < 1e-6);
        assert!((out[1] - 0.3).abs() < 1e-6);
        assert!(mic.is_empty());
        assert!(system.is_empty());
    }

    #[test]
    fn waits_when_one_source_is_briefly_empty() {
        let mut mic = VecDeque::from([0.5]);
        let mut system = VecDeque::new();
        let out = mix_available(&mut mic, &mut system, false);
        assert!(out.is_empty());
        assert_eq!(mic.len(), 1);
    }

    #[test]
    fn solos_after_backlog_on_final_pass() {
        let mut mic = VecDeque::from(vec![0.25; BACKLOG_BEFORE_SOLO]);
        let mut system = VecDeque::new();
        let out = mix_available(&mut mic, &mut system, true);
        assert_eq!(out.len(), BACKLOG_BEFORE_SOLO);
    }

    #[test]
    fn clamps_mixed_samples() {
        let mut mic = VecDeque::from([0.8]);
        let mut system = VecDeque::from([0.8]);
        let out = mix_available(&mut mic, &mut system, false);
        assert_eq!(out, vec![1.0]);
    }
}
