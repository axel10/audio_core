use std::fmt;

use ffmpeg_next as ffmpeg;

#[derive(Debug)]
pub enum Error {
    Ffmpeg(ffmpeg::Error),
    NoAudioStream,
    InvalidSampleRate,
    InvalidChannelCount,
    Message(String),
}

pub type Result<T> = std::result::Result<T, Error>;

impl From<ffmpeg::Error> for Error {
    fn from(value: ffmpeg::Error) -> Self {
        Self::Ffmpeg(value)
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Ffmpeg(error) => write!(f, "{error}"),
            Error::NoAudioStream => f.write_str("no audio stream found"),
            Error::InvalidSampleRate => f.write_str("missing or invalid sample rate"),
            Error::InvalidChannelCount => f.write_str("missing or invalid channel count"),
            Error::Message(message) => f.write_str(message),
        }
    }
}

impl std::error::Error for Error {}
