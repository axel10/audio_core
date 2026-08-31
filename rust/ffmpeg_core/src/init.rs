use std::sync::Once;

use ffmpeg_next as ffmpeg;

use crate::{Error, Result};

static INIT: Once = Once::new();

pub fn ensure_initialized() -> Result<()> {
    let mut init_result = Ok(());
    INIT.call_once(|| {
        init_result = ffmpeg::init().map_err(Error::from);
        ffmpeg::format::network::init();
    });
    init_result
}
