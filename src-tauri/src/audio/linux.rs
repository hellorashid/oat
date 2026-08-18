use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::{self, JoinHandle};
use std::time::Duration;

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{SampleFormat, StreamConfig};

use crate::audio::mixer::SampleSink;
use crate::audio::resample::{convert_chunk, LinearResampler, TARGET_SAMPLE_RATE};
use crate::audio::system::is_loopback_device_name;
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
    let host = cpal::default_host();
    let default_name = host
        .default_input_device()
        .and_then(|device| device.name().ok())
        .unwrap_or_default();

    let device = host
        .input_devices()?
        .find(|device| {
            device
                .name()
                .map(|name| is_loopback_device_name(&name) && name != default_name)
                .unwrap_or(false)
        })
        .ok_or_else(|| {
            OatError::msg(
                "No system audio loopback device found. On Linux, enable a Pulse/PipeWire monitor source.",
            )
        })?;

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
                "Unsupported system audio format: {other}"
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
    Ok(device.build_input_stream(
        config,
        move |data: &[T], _| {
            let converted = convert_chunk(data, channels, &mut resampler);
            sink.push(&converted);
        },
        |error| eprintln!("oat system stream: {error}"),
        None,
    )?)
}
