use std::path::{Path, PathBuf};

use serde::Deserialize;

use crate::error::OatError;
use crate::settings::Settings;

const MAX_UPLOAD_BYTES: u64 = 24 * 1024 * 1024;

#[derive(Debug, Clone, PartialEq)]
pub struct TranscriptSegment {
    pub start: f64,
    pub text: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Transcript {
    pub text: String,
    pub segments: Vec<TranscriptSegment>,
}

#[derive(Debug, Clone)]
pub struct TranscriptContext {
    pub id: String,
    pub recorded_at: String,
    pub duration_seconds: u64,
    pub audio_filename: String,
    pub microphone: bool,
    pub system: bool,
}

#[derive(Debug, Deserialize)]
struct VerboseTranscript {
    text: Option<String>,
    segments: Option<Vec<VerboseSegment>>,
}

#[derive(Debug, Deserialize)]
struct VerboseSegment {
    start: Option<f64>,
    text: Option<String>,
}

pub fn render_markdown(ctx: &TranscriptContext, transcript: &Transcript) -> String {
    let mut lines = vec![
        format!("# Recording {}", ctx.id),
        String::new(),
        format!("- **Recorded:** {}", human_datetime(&ctx.recorded_at)),
        format!("- **Duration:** {}", format_duration(ctx.duration_seconds)),
        format!("- **Audio:** [{}](./{})", ctx.audio_filename, ctx.audio_filename),
        format!(
            "- **Sources:** {}",
            source_label(ctx.microphone, ctx.system)
        ),
        String::new(),
        "---".into(),
        String::new(),
        "## Transcript".into(),
        String::new(),
    ];

    if transcript.segments.is_empty() {
        lines.push(transcript.text.trim().to_string());
    } else {
        for segment in &transcript.segments {
            let text = segment.text.trim();
            if text.is_empty() {
                continue;
            }
            lines.push(format!("[{}] {}", format_timestamp(segment.start), text));
        }
    }

    if !lines.last().is_some_and(|line| line.is_empty()) {
        lines.push(String::new());
    }
    lines.join("\n")
}

pub fn format_duration(seconds: u64) -> String {
    let hours = seconds / 3600;
    let minutes = (seconds % 3600) / 60;
    let secs = seconds % 60;
    if hours > 0 {
        format!("{hours}h {minutes:02}m {secs:02}s")
    } else {
        format!("{minutes}m {secs:02}s")
    }
}

pub fn format_timestamp(seconds: f64) -> String {
    let total = seconds.max(0.0) as u64;
    let minutes = total / 60;
    let secs = total % 60;
    format!("{minutes:02}:{secs:02}")
}

fn source_label(microphone: bool, system: bool) -> String {
    match (microphone, system) {
        (true, true) => "microphone + system audio".into(),
        (true, false) => "microphone".into(),
        (false, true) => "system audio".into(),
        (false, false) => "unknown".into(),
    }
}

fn human_datetime(rfc3339: &str) -> String {
    chrono::DateTime::parse_from_rfc3339(rfc3339)
        .map(|dt| dt.with_timezone(&chrono::Local).format("%b %-d, %Y %-I:%M %p").to_string())
        .unwrap_or_else(|_| rfc3339.to_string())
}

pub async fn transcribe_wav(path: &Path, settings: &Settings) -> Result<Transcript, OatError> {
    if !settings.has_api_key() {
        return Err(OatError::msg(
            "Add an API key in Settings to transcribe recordings",
        ));
    }

    let size = std::fs::metadata(path)?.len();
    if size <= MAX_UPLOAD_BYTES {
        return transcribe_chunk(path, settings, 0.0).await;
    }

    let chunks = split_wav(path, chunk_sample_limit(path)?)?;
    let mut combined = Transcript {
        text: String::new(),
        segments: Vec::new(),
    };
    for (index, chunk) in chunks.iter().enumerate() {
        let offset = chunk_offset_seconds(path, index)?;
        let part = transcribe_chunk(chunk, settings, offset).await;
        let _ = std::fs::remove_file(chunk);
        let part = part?;
        if !combined.text.is_empty() && !part.text.is_empty() {
            combined.text.push(' ');
        }
        combined.text.push_str(part.text.trim());
        combined.segments.extend(part.segments);
    }
    Ok(combined)
}

async fn transcribe_chunk(
    path: &Path,
    settings: &Settings,
    offset_seconds: f64,
) -> Result<Transcript, OatError> {
    let url = settings
        .provider
        .transcription_url(Some(settings.base_url.as_str()).filter(|s| !s.is_empty()))?;
    let model = if settings.model.trim().is_empty() {
        settings.provider.default_model().to_string()
    } else {
        settings.model.clone()
    };
    // whisper-1 supports verbose_json (timestamps). gpt-4o(-mini)-transcribe only allow json/text.
    let response_format = if supports_verbose_json(&model) {
        "verbose_json"
    } else {
        "json"
    };
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("recording.wav")
        .to_string();
    let bytes = tokio::fs::read(path).await?;
    let part = reqwest::multipart::Part::bytes(bytes)
        .file_name(file_name)
        .mime_str("audio/wav")
        .map_err(|error| OatError::msg(error.to_string()))?;
    let form = reqwest::multipart::Form::new()
        .text("model", model)
        .text("response_format", response_format)
        .part("file", part);

    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(600))
        .build()?;
    let response = client
        .post(url)
        .bearer_auth(settings.api_key.trim())
        .multipart(form)
        .send()
        .await?;
    let status = response.status();
    let body = response.text().await?;
    if !status.is_success() {
        return Err(OatError::msg(format!(
            "Transcription failed ({status}): {}",
            truncate(&body, 280)
        )));
    }

    if let Ok(parsed) = serde_json::from_str::<VerboseTranscript>(&body) {
        let segments = parsed
            .segments
            .unwrap_or_default()
            .into_iter()
            .filter_map(|segment| {
                let text = segment.text.unwrap_or_default();
                if text.trim().is_empty() {
                    None
                } else {
                    Some(TranscriptSegment {
                        start: segment.start.unwrap_or(0.0) + offset_seconds,
                        text,
                    })
                }
            })
            .collect::<Vec<_>>();
        let text = parsed
            .text
            .unwrap_or_else(|| {
                segments
                    .iter()
                    .map(|segment| segment.text.trim())
                    .collect::<Vec<_>>()
                    .join(" ")
            });
        return Ok(Transcript { text, segments });
    }

    Ok(Transcript {
        text: body,
        segments: Vec::new(),
    })
}

fn chunk_sample_limit(path: &Path) -> Result<usize, OatError> {
    let reader = hound::WavReader::open(path)?;
    let spec = reader.spec();
    let bytes_per_sec = spec.sample_rate as u64
        * spec.channels as u64
        * (spec.bits_per_sample as u64 / 8).max(1);
    let seconds = (20 * 1024 * 1024 / bytes_per_sec.max(1)) as usize;
    Ok(seconds.max(60) * spec.sample_rate as usize)
}

fn chunk_offset_seconds(path: &Path, index: usize) -> Result<f64, OatError> {
    let limit = chunk_sample_limit(path)?;
    let reader = hound::WavReader::open(path)?;
    let rate = reader.spec().sample_rate as f64;
    Ok((limit as f64 / rate) * index as f64)
}

fn split_wav(path: &Path, samples_per_chunk: usize) -> Result<Vec<PathBuf>, OatError> {
    let mut reader = hound::WavReader::open(path)?;
    let spec = reader.spec();
    let samples: Result<Vec<i16>, _> = reader.samples::<i16>().collect();
    let samples = samples?;
    let mut paths = Vec::new();
    for (index, chunk) in samples.chunks(samples_per_chunk * spec.channels as usize).enumerate()
    {
        let chunk_path = path.with_file_name(format!(
            "{}-part-{index}.wav",
            path.file_stem().and_then(|s| s.to_str()).unwrap_or("rec")
        ));
        let mut writer = hound::WavWriter::create(&chunk_path, spec)?;
        for sample in chunk {
            writer.write_sample(*sample)?;
        }
        writer.finalize()?;
        paths.push(chunk_path);
    }
    Ok(paths)
}

fn supports_verbose_json(model: &str) -> bool {
    let model = model.trim().to_ascii_lowercase();
    // OpenAI's gpt-4o*transcribe models reject verbose_json.
    !(model.contains("gpt-4o") && model.contains("transcribe"))
}

fn truncate(text: &str, max: usize) -> String {
    if text.len() <= max {
        text.to_string()
    } else {
        format!("{}…", &text[..max])
    }
}

pub fn write_markdown(path: &Path, markdown: &str) -> Result<(), OatError> {
    std::fs::write(path, markdown)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_clock_values() {
        assert_eq!(format_duration(94), "1m 34s");
        assert_eq!(format_duration(3661), "1h 01m 01s");
        assert_eq!(format_timestamp(75.2), "01:15");
    }

    #[test]
    fn renders_segmented_markdown() {
        let md = render_markdown(
            &TranscriptContext {
                id: "2026-08-17-143052".into(),
                recorded_at: "2026-08-17T14:30:52-07:00".into(),
                duration_seconds: 94,
                audio_filename: "2026-08-17-143052.wav".into(),
                microphone: true,
                system: true,
            },
            &Transcript {
                text: "Hello world".into(),
                segments: vec![
                    TranscriptSegment {
                        start: 0.0,
                        text: " Hello".into(),
                    },
                    TranscriptSegment {
                        start: 12.0,
                        text: "world".into(),
                    },
                ],
            },
        );
        assert!(md.contains("## Transcript"));
        assert!(md.contains("[00:00] Hello"));
        assert!(md.contains("[00:12] world"));
        assert!(md.contains("microphone + system audio"));
        assert!(md.contains("./2026-08-17-143052.wav"));
    }

    #[test]
    fn verbose_json_only_for_whisper_family() {
        assert!(supports_verbose_json("whisper-1"));
        assert!(!supports_verbose_json("gpt-4o-transcribe"));
        assert!(!supports_verbose_json("gpt-4o-mini-transcribe"));
        assert!(!supports_verbose_json("gpt-4o-transcribe-api-ev3"));
    }
}
