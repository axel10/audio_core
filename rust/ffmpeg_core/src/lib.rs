mod error;
mod init;
mod probe;
mod source;

pub use error::{Error, Result};
pub use ffmpeg_next as ffmpeg;
pub use init::ensure_initialized;
pub use probe::{probe, AudioProbe};
pub use source::AudioSource;
