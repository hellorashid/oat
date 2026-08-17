use serde::Serialize;

#[derive(Debug, thiserror::Error)]
pub enum OatError {
    #[error("{0}")]
    Message(String),
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error(transparent)]
    Json(#[from] serde_json::Error),
    #[error(transparent)]
    Wav(#[from] hound::Error),
    #[error(transparent)]
    Http(#[from] reqwest::Error),
}

impl OatError {
    pub fn msg(message: impl Into<String>) -> Self {
        Self::Message(message.into())
    }
}

impl Serialize for OatError {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        serializer.serialize_str(&self.to_string())
    }
}

impl From<cpal::DefaultStreamConfigError> for OatError {
    fn from(value: cpal::DefaultStreamConfigError) -> Self {
        Self::Message(value.to_string())
    }
}

impl From<cpal::BuildStreamError> for OatError {
    fn from(value: cpal::BuildStreamError) -> Self {
        Self::Message(value.to_string())
    }
}

impl From<cpal::PlayStreamError> for OatError {
    fn from(value: cpal::PlayStreamError) -> Self {
        Self::Message(value.to_string())
    }
}

impl From<cpal::DevicesError> for OatError {
    fn from(value: cpal::DevicesError) -> Self {
        Self::Message(value.to_string())
    }
}
