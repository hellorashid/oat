use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::{self, JoinHandle};
use std::time::Duration;

use wasapi::{DeviceEnumerator, Direction, StreamMode};

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
    let _ = wasapi::initialize_mta();
    let enumerator = DeviceEnumerator::new()
        .map_err(|error| OatError::msg(format!("WASAPI enumerator: {error}")))?;
    let device = enumerator
        .get_default_device(&Direction::Render)
        .map_err(|error| OatError::msg(format!("WASAPI render device: {error}")))?;
    let mut audio_client = device
        .get_iaudioclient()
        .map_err(|error| OatError::msg(format!("WASAPI client: {error}")))?;
    let mix_format = audio_client
        .get_mixformat()
        .map_err(|error| OatError::msg(format!("WASAPI mix format: {error}")))?;

    let channels = mix_format.get_nchannels() as usize;
    let bytes_per_sample = (mix_format.get_bitspersample() / 8) as usize;
    let sample_rate = mix_format.get_samplespersec();
    let (_default_period, min_period) = audio_client
        .get_device_period()
        .map_err(|error| OatError::msg(format!("WASAPI period: {error}")))?;

    let stream_mode = StreamMode::EventsShared {
        autoconvert: true,
        buffer_duration_hns: min_period,
    };
    audio_client
        .initialize_client(&mix_format, &Direction::Capture, &stream_mode)
        .map_err(|error| OatError::msg(format!("WASAPI loopback init: {error}")))?;

    let event = audio_client
        .set_get_eventhandle()
        .map_err(|error| OatError::msg(format!("WASAPI event: {error}")))?;
    let capture_client = audio_client
        .get_audiocaptureclient()
        .map_err(|error| OatError::msg(format!("WASAPI capture client: {error}")))?;
    audio_client
        .start_stream()
        .map_err(|error| OatError::msg(format!("WASAPI start: {error}")))?;

    let mut resampler = LinearResampler::new(sample_rate, TARGET_SAMPLE_RATE);

    while !stop.load(Ordering::Relaxed) {
        if let Ok(Some(frames_available)) = capture_client.get_next_packet_size() {
            if frames_available > 0 {
                let buffer_size = frames_available as usize * channels * bytes_per_sample;
                let mut buffer = vec![0u8; buffer_size];
                if let Ok((frames_read, _)) = capture_client.read_from_device(&mut buffer) {
                    let byte_len = frames_read as usize * channels * bytes_per_sample;
                    let samples = bytes_to_f32_le(&buffer[..byte_len.min(buffer.len())], bytes_per_sample);
                    let mono = downmix_interleaved(&samples, channels.max(1));
                    let converted = resampler.push(&mono);
                    sink.push(&converted);
                }
            }
        }
        let _ = event.wait_for_event(80);
    }

    let _ = audio_client.stop_stream();
    // Keep the thread alive briefly so COM teardown stays on this thread.
    thread::sleep(Duration::from_millis(20));
    Ok(())
}
