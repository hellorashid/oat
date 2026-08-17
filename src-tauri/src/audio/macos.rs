use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::{self, JoinHandle};
use std::time::Duration;

use screencapturekit::cm::{AudioBufferList, CMSampleBufferExt};
use screencapturekit::prelude::*;

use crate::audio::mixer::SampleSink;
use crate::audio::resample::{
    bytes_to_f32_le, downmix_interleaved, LinearResampler, TARGET_SAMPLE_RATE,
};
use crate::error::OatError;

pub fn spawn(sink: SampleSink, stop: Arc<AtomicBool>) -> Result<JoinHandle<()>, OatError> {
    thread::Builder::new()
        .name("oat-system".into())
        .spawn(move || {
            if let Err(error) = run(sink, stop) {
                eprintln!("oat system audio: {error}");
            }
        })
        .map_err(OatError::from)
}

fn run(sink: SampleSink, stop: Arc<AtomicBool>) -> Result<(), OatError> {
    let content = SCShareableContent::get()
        .map_err(|error| OatError::msg(format!("ScreenCaptureKit: {error}")))?;
    let displays = content.displays();
    let display = displays
        .first()
        .ok_or_else(|| OatError::msg("No display available for system audio capture"))?;

    let filter = SCContentFilter::create()
        .with_display(display)
        .with_excluding_windows(&[])
        .build();

    let config = SCStreamConfiguration::new()
        .with_width(16)
        .with_height(16)
        .with_captures_audio(true)
        .with_sample_rate(48_000)
        .with_channel_count(2);

    let handler = AudioHandler {
        sink,
        resampler: std::sync::Mutex::new(LinearResampler::new(48_000, TARGET_SAMPLE_RATE)),
    };

    let mut stream = SCStream::new(&filter, &config);
    stream.add_output_handler(handler, SCStreamOutputType::Audio);
    stream
        .start_capture()
        .map_err(|error| OatError::msg(format!("Could not start system audio capture: {error}")))?;

    while !stop.load(Ordering::Relaxed) {
        thread::sleep(Duration::from_millis(40));
    }

    let _ = stream.stop_capture();
    Ok(())
}

struct AudioHandler {
    sink: SampleSink,
    resampler: std::sync::Mutex<LinearResampler>,
}

impl SCStreamOutputTrait for AudioHandler {
    fn did_output_sample_buffer(&self, sample: CMSampleBuffer, of_type: SCStreamOutputType) {
        if of_type != SCStreamOutputType::Audio {
            return;
        }
        let Some(list) = sample.audio_buffer_list() else {
            return;
        };
        let interleaved = decode_audio_list(&list);
        if interleaved.is_empty() {
            return;
        }
        let mut resampler = self.resampler.lock().expect("resampler lock");
        let converted = resampler.push(&interleaved);
        self.sink.push(&converted);
    }
}

fn decode_audio_list(list: &AudioBufferList) -> Vec<f32> {
    let mut planes = Vec::new();
    for index in 0..8 {
        let Some(buffer) = list.get(index) else {
            break;
        };
        let bytes = buffer.data();
        let samples = if bytes.len() % 4 == 0 && !bytes.is_empty() {
            bytes_to_f32_le(bytes, 4)
        } else {
            bytes_to_f32_le(bytes, 2)
        };
        if !samples.is_empty() {
            planes.push(samples);
        }
    }

    match planes.len() {
        0 => Vec::new(),
        1 => downmix_interleaved(&planes[0], 2),
        _ => {
            let frames = planes.iter().map(Vec::len).min().unwrap_or(0);
            (0..frames)
                .map(|frame| {
                    let sum: f32 = planes.iter().map(|plane| plane[frame]).sum();
                    sum / planes.len() as f32
                })
                .collect()
        }
    }
}
