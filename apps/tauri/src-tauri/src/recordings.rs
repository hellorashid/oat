use std::fs;
use std::path::{Path, PathBuf};

use chrono::{DateTime, Local, TimeZone};
use serde::Serialize;

use crate::error::OatError;

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RecordingStatus {
    Ready,
    Transcribing,
    NeedsKey,
    Failed,
}

#[derive(Debug, Clone, Serialize)]
pub struct RecordingItem {
    pub id: String,
    pub created_at: String,
    pub duration_seconds: Option<u64>,
    pub wav_path: PathBuf,
    pub md_path: Option<PathBuf>,
    pub status: RecordingStatus,
    pub error: Option<String>,
}

pub fn new_recording_id(now: DateTime<Local>) -> String {
    now.format("%Y-%m-%d-%H%M%S").to_string()
}

pub fn list_recordings(
    storage_dir: &Path,
    transcribing: &std::collections::HashSet<String>,
) -> Result<Vec<RecordingItem>, OatError> {
    if !storage_dir.exists() {
        return Ok(Vec::new());
    }

    let mut items = Vec::new();
    for entry in fs::read_dir(storage_dir)? {
        let entry = entry?;
        let path = entry.path();
        if path.extension().and_then(|ext| ext.to_str()) != Some("wav") {
            continue;
        }
        let Some(id) = path.file_stem().and_then(|stem| stem.to_str()) else {
            continue;
        };
        items.push(recording_from_files(storage_dir, id, transcribing)?);
    }

    items.sort_by(|a, b| b.created_at.cmp(&a.created_at));
    Ok(items)
}

pub fn recording_from_files(
    storage_dir: &Path,
    id: &str,
    transcribing: &std::collections::HashSet<String>,
) -> Result<RecordingItem, OatError> {
    let wav_path = storage_dir.join(format!("{id}.wav"));
    if !wav_path.exists() {
        return Err(OatError::msg(format!("Recording {id} not found")));
    }
    let md_path = storage_dir.join(format!("{id}.md"));
    let failed_path = storage_dir.join(format!("{id}.error"));
    let created_at = created_at_from_id(id).unwrap_or_else(|| file_created_at(&wav_path));
    let duration_seconds = wav_duration_seconds(&wav_path);
    let error = fs::read_to_string(&failed_path).ok();

    let status = if transcribing.contains(id) {
        RecordingStatus::Transcribing
    } else if md_path.exists() {
        RecordingStatus::Ready
    } else if error
        .as_deref()
        .is_some_and(|text| text.contains("API key"))
    {
        RecordingStatus::NeedsKey
    } else if error.is_some() {
        RecordingStatus::Failed
    } else {
        RecordingStatus::Failed
    };

    Ok(RecordingItem {
        id: id.to_string(),
        created_at,
        duration_seconds,
        wav_path,
        md_path: md_path.exists().then_some(md_path),
        status,
        error,
    })
}

pub fn wav_duration_seconds(path: &Path) -> Option<u64> {
    let reader = hound::WavReader::open(path).ok()?;
    let spec = reader.spec();
    if spec.sample_rate == 0 {
        return None;
    }
    Some(u64::from(reader.duration()) / u64::from(spec.sample_rate))
}

fn created_at_from_id(id: &str) -> Option<String> {
    let parsed = chrono::NaiveDateTime::parse_from_str(id, "%Y-%m-%d-%H%M%S").ok()?;
    let local = Local.from_local_datetime(&parsed).single()?;
    Some(local.to_rfc3339())
}

fn file_created_at(path: &Path) -> String {
    fs::metadata(path)
        .and_then(|meta| meta.modified())
        .ok()
        .map(|time| DateTime::<Local>::from(time).to_rfc3339())
        .unwrap_or_else(|| Local::now().to_rfc3339())
}

pub fn write_error_file(storage_dir: &Path, id: &str, message: &str) -> Result<(), OatError> {
    fs::write(storage_dir.join(format!("{id}.error")), message)?;
    Ok(())
}

pub fn clear_error_file(storage_dir: &Path, id: &str) {
    let _ = fs::remove_file(storage_dir.join(format!("{id}.error")));
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    #[test]
    fn formats_stable_ids() {
        let time = Local.with_ymd_and_hms(2026, 8, 17, 14, 30, 52).unwrap();
        assert_eq!(new_recording_id(time), "2026-08-17-143052");
    }

    #[test]
    fn lists_wavs_newest_first() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join("2026-08-17-100000.wav"), b"RIFF").unwrap();
        fs::write(dir.path().join("2026-08-17-110000.wav"), b"RIFF").unwrap();
        fs::write(dir.path().join("2026-08-17-110000.md"), b"# hi").unwrap();
        let items = list_recordings(dir.path(), &Default::default()).unwrap();
        assert_eq!(items.len(), 2);
        assert_eq!(items[0].id, "2026-08-17-110000");
        assert_eq!(items[0].status, RecordingStatus::Ready);
        assert_eq!(items[1].status, RecordingStatus::Failed);
    }
}
