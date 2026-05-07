use std::path::Path;
use std::time::Duration;

use crate::Result;

#[derive(Debug, Clone)]
pub struct AudioProbe {
    pub channels: u16,
    pub sample_rate: u32,
    pub total_duration: Option<Duration>,
    pub seekable: bool,
}

pub fn probe(path: impl AsRef<Path>) -> Result<AudioProbe> {
    Ok(crate::AudioSource::open(path)?.probe().clone())
}
