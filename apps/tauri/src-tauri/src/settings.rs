use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::error::OatError;

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "lowercase")]
pub enum Provider {
    #[default]
    Openai,
    Groq,
    Custom,
}

impl Provider {
    pub fn default_model(self) -> &'static str {
        match self {
            Provider::Openai => "gpt-4o-mini-transcribe",
            Provider::Groq => "whisper-large-v3",
            Provider::Custom => "whisper-1",
        }
    }

    pub fn transcription_url(self, base_url: Option<&str>) -> Result<String, OatError> {
        match self {
            Provider::Openai => Ok("https://api.openai.com/v1/audio/transcriptions".into()),
            Provider::Groq => Ok("https://api.groq.com/openai/v1/audio/transcriptions".into()),
            Provider::Custom => {
                let base = base_url
                    .map(str::trim)
                    .filter(|value| !value.is_empty())
                    .ok_or_else(|| OatError::msg("Custom provider needs a base URL"))?;
                Ok(format!(
                    "{}/audio/transcriptions",
                    base.trim_end_matches('/')
                ))
            }
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct Settings {
    pub storage_dir: Option<PathBuf>,
    pub api_key: String,
    pub provider: Provider,
    pub model: String,
    pub base_url: String,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            storage_dir: None,
            api_key: String::new(),
            provider: Provider::Openai,
            model: Provider::Openai.default_model().into(),
            base_url: String::new(),
        }
    }
}

impl Settings {
    pub fn load(path: &Path) -> Result<Self, OatError> {
        if !path.exists() {
            return Ok(Self::default());
        }
        let raw = fs::read_to_string(path)?;
        Ok(serde_json::from_str(&raw)?)
    }

    pub fn save(&self, path: &Path) -> Result<(), OatError> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(path, serde_json::to_string_pretty(self)?)?;
        Ok(())
    }

    pub fn storage_dir(&self) -> Result<PathBuf, OatError> {
        self.storage_dir
            .clone()
            .ok_or_else(|| OatError::msg("Choose a folder for recordings in Settings"))
    }

    pub fn has_api_key(&self) -> bool {
        !self.api_key.trim().is_empty()
    }
}

pub fn settings_path(app_data_dir: &Path) -> PathBuf {
    app_data_dir.join("settings.json")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn custom_url_appends_transcriptions_path() {
        let url = Provider::Custom
            .transcription_url(Some("https://example.com/v1/"))
            .unwrap();
        assert_eq!(url, "https://example.com/v1/audio/transcriptions");
    }

    #[test]
    fn custom_url_requires_base() {
        assert!(Provider::Custom.transcription_url(Some("")).is_err());
    }
}
