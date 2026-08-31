use std::ptr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use block2::{DynBlock, RcBlock};
use dispatch2::{DispatchQueue, DispatchQueueAttr};
use objc2::rc::Retained;
use objc2::runtime::ProtocolObject;
use objc2::{define_class, msg_send, AnyThread, DefinedClass};
use objc2_core_audio_types::AudioBuffer;
use objc2_core_media::{CMBlockBuffer, CMSampleBuffer};
use objc2_foundation::{NSArray, NSError, NSObject, NSObjectProtocol};
use objc2_screen_capture_kit::{
    SCContentFilter, SCShareableContent, SCStream, SCStreamConfiguration, SCStreamOutput,
    SCStreamOutputType, SCWindow,
};

use crate::audio::mixer::SampleSink;
use crate::audio::resample::{
    bytes_to_f32_le, downmix_interleaved, LinearResampler, TARGET_SAMPLE_RATE,
};
use crate::error::OatError;

const SYSTEM_SAMPLE_RATE: isize = 48_000;

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
    if !crate::permissions::has_system_audio_access() {
        let _ = crate::permissions::open_privacy_pane(
            crate::permissions::PrivacyPane::SystemAudio,
        );
        return Err(OatError::msg(
            crate::permissions::system_audio_denied_message(),
        ));
    }

    let content = shareable_content().map_err(|error| {
        let message = error.to_string();
        if message.to_lowercase().contains("tcc")
            || message.to_lowercase().contains("declined")
            || message.to_lowercase().contains("denied")
        {
            OatError::msg(crate::permissions::system_audio_denied_message())
        } else {
            error
        }
    })?;
    let displays = unsafe { content.displays() };
    let display = displays
        .firstObject()
        .ok_or_else(|| OatError::msg("No display available for system audio capture"))?;

    let filter = unsafe {
        SCContentFilter::initWithDisplay_excludingWindows(
            SCContentFilter::alloc(),
            &display,
            &NSArray::<SCWindow>::new(),
        )
    };

    let config = unsafe { SCStreamConfiguration::new() };
    unsafe {
        config.setWidth(16);
        config.setHeight(16);
        config.setCapturesAudio(true);
        config.setSampleRate(SYSTEM_SAMPLE_RATE);
        config.setChannelCount(2);
        config.setExcludesCurrentProcessAudio(true);
    }

    let output = AudioOutput::new(sink);
    let queue = DispatchQueue::new("com.oat.system-audio", DispatchQueueAttr::SERIAL);

    let stream = unsafe {
        SCStream::initWithFilter_configuration_delegate(
            SCStream::alloc(),
            &filter,
            &config,
            None,
        )
    };

    unsafe {
        stream
            .addStreamOutput_type_sampleHandlerQueue_error(
                ProtocolObject::from_ref(&*output),
                SCStreamOutputType::Audio,
                Some(&queue),
            )
            .map_err(|error| {
                OatError::msg(format!(
                    "Could not attach system audio output: {}",
                    ns_error_message(&error)
                ))
            })?;
    }

    await_ns_error(
        |handler| unsafe { stream.startCaptureWithCompletionHandler(handler) },
        "Could not start system audio capture",
    )?;

    while !stop.load(Ordering::Relaxed) {
        thread::sleep(Duration::from_millis(40));
    }

    let _ = await_ns_error(
        |handler| unsafe { stream.stopCaptureWithCompletionHandler(handler) },
        "Could not stop system audio capture",
    );
    drop(output);
    drop(stream);
    Ok(())
}

fn shareable_content() -> Result<Retained<SCShareableContent>, OatError> {
    let (tx, rx) = mpsc::channel();
    let block = RcBlock::new(move |content: *mut SCShareableContent, error: *mut NSError| {
        let result = if !error.is_null() {
            Err(OatError::msg(format!(
                "ScreenCaptureKit: {}",
                ns_error_message(unsafe { &*error })
            )))
        } else if content.is_null() {
            Err(OatError::msg("ScreenCaptureKit returned no shareable content"))
        } else {
            Ok(unsafe { Retained::retain(content).unwrap() })
        };
        let _ = tx.send(result);
    });

    unsafe {
        SCShareableContent::getShareableContentWithCompletionHandler(&block);
    }

    rx.recv_timeout(Duration::from_secs(5))
        .map_err(|_| OatError::msg("Timed out waiting for ScreenCaptureKit content"))?
}

fn await_ns_error(
    invoke: impl FnOnce(Option<&DynBlock<dyn Fn(*mut NSError)>>),
    err_prefix: &str,
) -> Result<(), OatError> {
    let (tx, rx) = mpsc::channel();
    let prefix = err_prefix.to_string();
    let block = RcBlock::new(move |error: *mut NSError| {
        let result = if error.is_null() {
            Ok(())
        } else {
            Err(OatError::msg(format!(
                "{prefix}: {}",
                ns_error_message(unsafe { &*error })
            )))
        };
        let _ = tx.send(result);
    });

    invoke(Some(&block));

    rx.recv_timeout(Duration::from_secs(5))
        .map_err(|_| OatError::msg(format!("Timed out: {err_prefix}")))?
}

fn ns_error_message(error: &NSError) -> String {
    error.localizedDescription().to_string()
}

struct OutputIvars {
    sink: SampleSink,
    resampler: Mutex<LinearResampler>,
}

define_class!(
    #[unsafe(super(NSObject))]
    #[ivars = OutputIvars]
    struct AudioOutput;

    unsafe impl NSObjectProtocol for AudioOutput {}

    unsafe impl SCStreamOutput for AudioOutput {
        #[allow(non_snake_case)]
        #[unsafe(method(stream:didOutputSampleBuffer:ofType:))]
        unsafe fn stream_didOutputSampleBuffer_ofType(
            &self,
            _stream: &SCStream,
            sample_buffer: &CMSampleBuffer,
            of_type: SCStreamOutputType,
        ) {
            if of_type != SCStreamOutputType::Audio {
                return;
            }

            let interleaved = decode_audio_sample_buffer(sample_buffer);
            if interleaved.is_empty() {
                return;
            }

            let ivars = self.ivars();
            let mut resampler = ivars.resampler.lock().expect("resampler lock");
            let converted = resampler.push(&interleaved);
            ivars.sink.push(&converted);
        }
    }
);

impl AudioOutput {
    fn new(sink: SampleSink) -> Retained<Self> {
        let this = Self::alloc().set_ivars(OutputIvars {
            sink,
            resampler: Mutex::new(LinearResampler::new(
                SYSTEM_SAMPLE_RATE as u32,
                TARGET_SAMPLE_RATE,
            )),
        });
        unsafe { msg_send![super(this), init] }
    }
}

#[repr(C)]
struct AudioBufferListStorage {
    number_buffers: u32,
    buffers: [AudioBuffer; 8],
}

fn decode_audio_sample_buffer(sample: &CMSampleBuffer) -> Vec<f32> {
    let mut storage = AudioBufferListStorage {
        number_buffers: 0,
        buffers: [AudioBuffer {
            mNumberChannels: 0,
            mDataByteSize: 0,
            mData: ptr::null_mut(),
        }; 8],
    };
    let mut block_buffer: *mut CMBlockBuffer = ptr::null_mut();

    let status = unsafe {
        sample.audio_buffer_list_with_retained_block_buffer(
            ptr::null_mut(),
            (&raw mut storage).cast(),
            std::mem::size_of::<AudioBufferListStorage>(),
            None,
            None,
            0,
            &mut block_buffer,
        )
    };

    let _block_guard = unsafe { Retained::from_raw(block_buffer) };

    if status != 0 || storage.number_buffers == 0 {
        return Vec::new();
    }

    let mut planes = Vec::new();
    let count = storage.number_buffers.min(8) as usize;
    for buffer in storage.buffers.iter().take(count) {
        if buffer.mData.is_null() || buffer.mDataByteSize == 0 {
            continue;
        }
        let bytes = unsafe {
            std::slice::from_raw_parts(buffer.mData as *const u8, buffer.mDataByteSize as usize)
        };
        let samples = if bytes.len() % 4 == 0 {
            bytes_to_f32_le(bytes, 4)
        } else {
            bytes_to_f32_le(bytes, 2)
        };
        if !samples.is_empty() {
            planes.push((buffer.mNumberChannels.max(1) as usize, samples));
        }
    }

    match planes.len() {
        0 => Vec::new(),
        1 => {
            let (channels, samples) = &planes[0];
            downmix_interleaved(samples, *channels)
        }
        _ => {
            let frames = planes
                .iter()
                .map(|(_, samples)| samples.len())
                .min()
                .unwrap_or(0);
            (0..frames)
                .map(|frame| {
                    let sum: f32 = planes.iter().map(|(_, samples)| samples[frame]).sum();
                    sum / planes.len() as f32
                })
                .collect()
        }
    }
}
