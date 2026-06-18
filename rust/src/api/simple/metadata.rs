use std::fs;
use std::path::{Path, PathBuf};

use zune_core::bytestream::ZCursor;
use zune_core::options::DecoderOptions;
use zune_image::codecs::ImageFormat;
use zune_image::image::Image;
use zune_image::traits::OperationsTrait;
use zune_imageprocs::crop::Crop;
use zune_imageprocs::resize::{Resize, ResizeMethod};

use super::palette::{
    build_theme_palette_bundle_with_options, MeshStylePreset, ThemePaletteOptions,
};

#[derive(Debug, Clone, Default)]
pub struct TrackPicture {
    pub bytes: Vec<u8>,
    pub mime_type: String,
    pub picture_type: String,
    pub description: Option<String>,
}

#[derive(Debug, Clone, Default)]
pub struct TrackMetadataUpdate {
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub album_artist: Option<String>,
    pub track_number: Option<i32>,
    pub track_total: Option<i32>,
    pub disc_number: Option<i32>,
    pub date: Option<String>,
    pub year: Option<i32>,
    pub comment: Option<String>,
    pub lyrics: Option<String>,
    pub composer: Option<String>,
    pub lyricist: Option<String>,
    pub performer: Option<String>,
    pub conductor: Option<String>,
    pub remixer: Option<String>,
    pub genres: Vec<String>,
    pub pictures: Vec<TrackPicture>,
}

#[derive(Debug, Clone, Default)]
pub struct TrackArtworkResult {
    pub artwork_found: bool,
    pub artwork_path: Option<String>,
    pub thumbnail_path: Option<String>,
    pub artwork_width: Option<i32>,
    pub artwork_height: Option<i32>,
    pub theme_colors_blob: Option<Vec<u8>>,
    pub mesh_debug_blob: Option<Vec<u8>>,
}

#[derive(Debug, Clone, Default)]
pub struct AudioDetails {
    pub format_name: String,
    pub codec_name: String,
    pub duration_ms: i64,
    pub bitrate: i32,
    pub sample_rate: i32,
    pub channels: i32,
    pub bit_depth: Option<i32>,
    pub bitrate_mode: String,
    pub file_size: i64,
}

pub fn update_track_metadata(_path: String, _metadata: TrackMetadataUpdate) -> anyhow::Result<()> {
    Err(anyhow::anyhow!("update_track_metadata is deprecated in Rust; use TagLib in Dart instead"))
}

pub fn get_track_metadata(_path: String) -> TrackMetadataUpdate {
    TrackMetadataUpdate::default()
}

pub fn get_audio_details(_path: String) -> anyhow::Result<AudioDetails> {
    Err(anyhow::anyhow!("get_audio_details is deprecated in Rust; use TagLib in Dart instead"))
}

pub fn remove_all_tags(_path: String) -> anyhow::Result<()> {
    Err(anyhow::anyhow!("remove_all_tags is deprecated in Rust; use TagLib in Dart instead"))
}

pub fn generate_track_artwork(
    path: String,
    artwork_bytes: Option<Vec<u8>>,
    cache_root_path: String,
    save_large_artwork: bool,
    thumbnail_size: i32,
    mesh_style_preset: i32,
    hue_cohesion: f64,
    palette_blur_radius: f64,
    mesh_muddy_penalty_multiplier: f64,
    mesh_population_strength: f64,
    mesh_contrast_strength: f64,
    mesh_harmony_strength: f64,
    mesh_vibrancy_strength: f64,
) -> anyhow::Result<TrackArtworkResult> {
    let picture_bytes = artwork_bytes.unwrap_or_default();

    if picture_bytes.is_empty() {
        return Ok(TrackArtworkResult {
            artwork_found: false,
            ..TrackArtworkResult::default()
        });
    }

    let (thumbnail_image, artwork_width, artwork_height) =
        build_square_thumbnail(&picture_bytes, thumbnail_size.max(1) as usize)?;
    let palette_options = ThemePaletteOptions {
        hue_cohesion,
        mesh_style_preset: MeshStylePreset::from_code(mesh_style_preset),
        palette_blur_radius,
        mesh_muddy_penalty_multiplier,
        mesh_population_strength,
        mesh_contrast_strength,
        mesh_harmony_strength,
        mesh_vibrancy_strength,
        ..ThemePaletteOptions::default()
    };
    let palette_bundle = build_theme_palette_bundle_with_options(&thumbnail_image, palette_options)
        .unwrap_or_else(|err| {
            log::warn!("failed to calculate artwork palette for {path}: {err}");
            None
        });
    let theme_colors_blob = palette_bundle
        .as_ref()
        .and_then(|bundle| serde_json::to_vec(&bundle.theme_colors).ok());
    let mesh_debug_blob = palette_bundle
        .as_ref()
        .and_then(|bundle| bundle.mesh_debug.as_ref())
        .and_then(|debug| serde_json::to_vec(debug).ok());
    let thumbnail_bytes = thumbnail_image
        .write_to_vec(ImageFormat::JPEG)
        .map_err(|err| anyhow::anyhow!("failed to encode artwork thumbnail: {err}"))?;

    let cache_root = PathBuf::from(cache_root_path);
    let artworks_dir = cache_root.join("artworks");
    let thumbnails_dir = cache_root.join("thumbnails");
    fs::create_dir_all(&artworks_dir)?;
    fs::create_dir_all(&thumbnails_dir)?;

    let base_name = format!("{}_{}", current_time_millis(), file_token(&path));

    let artwork_path = if save_large_artwork {
        let artwork_path = artworks_dir.join(format!("{base_name}.jpg"));
        fs::write(&artwork_path, &picture_bytes)?;
        Some(path_to_string(&artwork_path))
    } else {
        None
    };

    let thumbnail_path = thumbnails_dir.join(format!("{base_name}_thumb.jpg"));
    fs::write(&thumbnail_path, &thumbnail_bytes)?;

    Ok(TrackArtworkResult {
        artwork_found: true,
        artwork_path,
        thumbnail_path: Some(path_to_string(&thumbnail_path)),
        artwork_width: Some(artwork_width as i32),
        artwork_height: Some(artwork_height as i32),
        theme_colors_blob,
        mesh_debug_blob,
    })
}

fn build_square_thumbnail(
    artwork_bytes: &[u8],
    thumbnail_size: usize,
) -> anyhow::Result<(Image, usize, usize)> {
    let mut image = Image::read(ZCursor::new(artwork_bytes), DecoderOptions::default())
        .map_err(|err| anyhow::anyhow!("failed to decode artwork image: {err}"))?;
    let (width, height) = image.dimensions();
    if width == 0 || height == 0 {
        anyhow::bail!("failed to decode artwork image: decoded dimensions are 0x0");
    }
    let crop_size = width.min(height);
    let offset_x = (width.saturating_sub(crop_size)) / 2;
    let offset_y = (height.saturating_sub(crop_size)) / 2;

    Crop::new(crop_size, crop_size, offset_x, offset_y)
        .execute(&mut image)
        .map_err(|err| anyhow::anyhow!("failed to crop artwork image: {err}"))?;
    Resize::new(thumbnail_size, thumbnail_size, ResizeMethod::Bilinear)
        .execute(&mut image)
        .map_err(|err| anyhow::anyhow!("failed to resize artwork image: {err}"))?;

    Ok((image, width, height))
}

fn file_token(path: &str) -> String {
    let mut hash = 0xcbf29ce484222325u64;
    for byte in path.trim().to_ascii_lowercase().bytes() {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    format!("{hash:016x}")
}

fn current_time_millis() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_millis())
        .unwrap_or_default()
}

fn path_to_string(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}
