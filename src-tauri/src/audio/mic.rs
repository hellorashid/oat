use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::{self, JoinHandle};
use std::time::Duration;

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{SampleFormat, StreamConfig};

use crate::audio::mixer::SampleSink;
use crate::audio::resample::{convert_chunk, LinearResampler, TARGET_SAMPLE_RATE};
use crate::error::OatError;

pub fn spawn_microphone(
    sink: SampleSink,
    stop: Arc<AtomicBool>,
) -> Result<JoinHandle<()>, OatError> {
    thread::Builder::new()
        .name("oat-mic".into())
        .spawn(move || {
            if let Err(error) = run_microphone(sink, stop) {
                eprintln!("oat microphone: {error}");
            }
        })
        .map_err(OatError::from)
}

fn run_microphone(sink: SampleSink, stop: Arc<AtomicBool>) -> Result<(), OatError> {
    let host = cpal::default_host();
    let device = host
        .default_input_device()
        .ok_or_else(|| OatError::msg("No microphone found"))?;
    let supported = device.default_input_config()?;
    let config: StreamConfig = supported.clone().into();
    let channels = config.channels as usize;
    let sample_rate = config.sample_rate.0;
    let stream = match supported.sample_format() {
        SampleFormat::F32 => build_stream::<f32>(&device, &config, channels, sample_rate, sink)?,
        SampleFormat::I16 => build_stream::<i16>(&device, &config, channels, sample_rate, sink)?,
        SampleFormat::I32 => build_stream::<i32>(&device, &config, channels, sample_rate, sink)?,
        SampleFormat::U16 => build_stream::<u16>(&device, &config, channels, sample_rate, sink)?,
        other => {
            return Err(OatError::msg(format!(
                "Unsupported microphone format: {other}"
            )))
        }
    };
    stream.play()?;
    while !stop.load(Ordering::Relaxed) {
        thread::sleep(Duration::from_millis(40));
    }
    drop(stream);
    Ok(())
}

fn build_stream<T>(
    device: &cpal::Device,
    config: &StreamConfig,
    channels: usize,
    sample_rate: u32,
    sink: SampleSink,
) -> Result<cpal::Stream, OatError>
where
    T: cpal::SizedSample + crate::audio::resample::ToF32 + Copy + Send + 'static,
{
    let mut resampler = LinearResampler::new(sample_rate, TARGET_SAMPLE_RATE);
    let stream = device.build_input_stream(
        config,
        move |data: &[T], _| {
            let converted = convert_chunk(data, channels, &mut resampler);
            sink.push(&converted);
        },
        |error| eprintln!("oat microphone stream: {error}"),
        None,
    )?;
    Ok(stream)
}
