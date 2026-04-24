use std::cmp::Ordering;
use std::collections::{BTreeMap, BinaryHeap, HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};

use lofty::config::{ParseOptions, WriteOptions};
use lofty::prelude::*;
use lofty::probe::Probe;
use lofty::tag::{ItemKey, Tag, TagType};
use zune_core::bytestream::ZCursor;
use zune_core::colorspace::ColorSpace;
use zune_core::options::DecoderOptions;
use zune_image::codecs::ImageFormat;
use zune_image::image::Image;
use zune_image::traits::OperationsTrait;
use zune_imageprocs::crop::Crop;
use zune_imageprocs::resize::{Resize, ResizeMethod};

use id3::frame::{
    Comment as Id3Comment, ExtendedText as Id3ExtendedText, Lyrics as Id3Lyrics,
    Picture as Id3Picture, PictureType as Id3PictureType,
};
use id3::{Tag as Id3Tag, TagLike as _, Version as Id3Version};

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
}

const PALETTE_MAX_COLORS: usize = 16;
const QUANTIZE_WORD_MASK: u8 = 0xF8;

pub fn update_track_metadata(path: String, metadata: TrackMetadataUpdate) -> anyhow::Result<()> {
    if should_use_id3(&path) {
        return update_track_metadata_with_id3(path, metadata);
    }

    update_track_metadata_with_lofty(path, metadata)
}

pub fn get_track_metadata(path: String) -> TrackMetadataUpdate {
    if should_use_id3(&path) {
        return read_track_metadata_with_id3(&path);
    }

    read_track_metadata_with_lofty(&path)
}

pub fn generate_track_artwork(
    path: String,
    cache_root_path: String,
    save_large_artwork: bool,
    thumbnail_size: i32,
) -> anyhow::Result<TrackArtworkResult> {
    let picture = extract_embedded_artwork(&path);
    let Some(picture) = picture else {
        return Ok(TrackArtworkResult {
            artwork_found: false,
            ..TrackArtworkResult::default()
        });
    };

    if picture.bytes.is_empty() {
        return Ok(TrackArtworkResult {
            artwork_found: false,
            ..TrackArtworkResult::default()
        });
    }

    let (thumbnail_image, artwork_width, artwork_height) =
        build_square_thumbnail(&picture.bytes, thumbnail_size.max(1) as usize)?;
    let theme_colors_blob = build_theme_colors_blob(&thumbnail_image).unwrap_or_else(|err| {
        log::warn!("failed to calculate artwork palette for {path}: {err}");
        None
    });
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
        fs::write(&artwork_path, &picture.bytes)?;
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
    })
}

fn should_use_id3(path: &str) -> bool {
    matches!(
        Path::new(path)
            .extension()
            .and_then(|ext| ext.to_str())
            .map(|ext| ext.to_ascii_lowercase())
            .as_deref(),
        Some("mp3" | "wav" | "aiff" | "aif")
    )
}

fn extract_embedded_artwork(path: &str) -> Option<TrackPicture> {
    if should_use_id3(path) {
        return extract_embedded_artwork_with_id3(path);
    }

    extract_embedded_artwork_with_lofty(path)
}

fn extract_embedded_artwork_with_id3(path: &str) -> Option<TrackPicture> {
    let tag = Id3Tag::read_from_path(path).ok()?;
    let picture = tag.pictures().next()?;
    Some(TrackPicture {
        bytes: picture.data.clone(),
        mime_type: picture.mime_type.clone(),
        picture_type: id3_picture_type_to_label(picture.picture_type),
        description: if picture.description.is_empty() {
            None
        } else {
            Some(picture.description.clone())
        },
    })
}

fn extract_embedded_artwork_with_lofty(path: &str) -> Option<TrackPicture> {
    let tagged_file = Probe::open(path)
        .and_then(|probe| {
            probe
                .options(ParseOptions::new().read_properties(false))
                .read()
        })
        .ok()?;
    let tag = tagged_file
        .primary_tag()
        .or_else(|| tagged_file.first_tag())?;
    let picture = tag.pictures().iter().next()?;
    Some(TrackPicture {
        bytes: picture.data().to_vec(),
        mime_type: picture
            .mime_type()
            .map(|mime| mime.to_string())
            .unwrap_or_else(|| "image/jpeg".to_string()),
        picture_type: lofty_picture_type_to_label(picture.pic_type()),
        description: picture.description().map(str::to_string),
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

fn build_theme_colors_blob(image: &Image) -> anyhow::Result<Option<Vec<u8>>> {
    let mut rgb_image = image.clone();
    if rgb_image.colorspace() != ColorSpace::RGB {
        rgb_image
            .convert_color(ColorSpace::RGB)
            .map_err(|err| anyhow::anyhow!("failed to convert artwork colorspace: {err}"))?;
    }

    let flattened_frames = rgb_image.flatten_to_u8();
    let Some(pixels) = flattened_frames.first() else {
        return Ok(None);
    };

    let palette_colors = quantize_palette_colors(pixels, 3, PALETTE_MAX_COLORS);
    let theme_colors = select_theme_colors(palette_colors);
    if theme_colors.is_empty() {
        return Ok(None);
    }

    Ok(Some(serde_json::to_vec(&theme_colors)?))
}

fn quantize_palette_colors(
    pixels: &[u8],
    channels_per_pixel: usize,
    max_colors: usize,
) -> Vec<PaletteColor> {
    let mut histogram = HashMap::<u32, usize>::new();
    let mut colors = Vec::<u32>::new();

    for pixel in pixels.chunks_exact(channels_per_pixel) {
        let alpha = if channels_per_pixel >= 4 {
            pixel[3]
        } else {
            u8::MAX
        };
        if alpha == 0 {
            continue;
        }

        let quantized = quantize_rgb(pixel[0], pixel[1], pixel[2]);
        if !histogram.contains_key(&quantized) {
            colors.push(quantized);
        }
        *histogram.entry(quantized).or_insert(0) += 1;
    }

    histogram.retain(|color, _| !should_ignore_color(*color));
    colors.retain(|color| !should_ignore_color(*color));
    if histogram.is_empty() {
        return Vec::new();
    }

    if colors.len() <= max_colors {
        return colors
            .into_iter()
            .map(|color| PaletteColor::new(color, histogram[&color]))
            .collect();
    }

    quantize_histogram(histogram, colors, max_colors)
}

fn quantize_histogram(
    histogram: HashMap<u32, usize>,
    mut colors: Vec<u32>,
    max_colors: usize,
) -> Vec<PaletteColor> {
    if colors.is_empty() {
        return Vec::new();
    }

    let mut priority_queue = BinaryHeap::new();
    priority_queue.push(PriorityColorBox::from_box(ColorVolumeBox::new(
        0,
        colors.len() - 1,
        &colors,
        &histogram,
    )));

    while priority_queue.len() < max_colors {
        let Some(mut color_box) = priority_queue.pop().map(PriorityColorBox::into_inner) else {
            break;
        };

        if !color_box.can_split() {
            priority_queue.push(PriorityColorBox::from_box(color_box));
            break;
        }

        let new_box = color_box.split_box(&mut colors, &histogram);
        priority_queue.push(PriorityColorBox::from_box(color_box));
        priority_queue.push(PriorityColorBox::from_box(new_box));
    }

    priority_queue
        .into_iter()
        .map(PriorityColorBox::into_inner)
        .filter_map(|color_box| {
            let average_color = color_box.average_color(&colors, &histogram);
            (!should_ignore_color(average_color.rgb)).then_some(average_color)
        })
        .collect()
}

fn select_theme_colors(mut palette_colors: Vec<PaletteColor>) -> BTreeMap<String, u32> {
    if palette_colors.is_empty() {
        return BTreeMap::new();
    }

    palette_colors.sort_by(|a, b| b.population.cmp(&a.population));
    let dominant = palette_colors[0].clone();
    let dominant_population = dominant.population.max(1) as f64;
    let mut theme_colors = BTreeMap::new();
    let mut used_colors = HashSet::<u32>::new();

    theme_colors.insert("dominant".to_string(), dominant.argb());

    for (name, target) in palette_targets() {
        if let Some(color) = get_max_scored_palette_color(
            &palette_colors,
            &target,
            dominant_population,
            &used_colors,
        ) {
            theme_colors.insert(name.to_string(), color.argb());
            if target.is_exclusive {
                used_colors.insert(color.rgb);
            }
        }
    }

    theme_colors
}

fn get_max_scored_palette_color<'a>(
    palette_colors: &'a [PaletteColor],
    target: &PaletteTarget,
    dominant_population: f64,
    used_colors: &HashSet<u32>,
) -> Option<&'a PaletteColor> {
    let mut best_score = 0.0;
    let mut best_color = None;

    for color in palette_colors {
        if !should_score_for_target(color, target, used_colors) {
            continue;
        }

        let score = generate_palette_score(color, target, dominant_population);
        if best_color.is_none() || score > best_score {
            best_score = score;
            best_color = Some(color);
        }
    }

    best_color
}

fn should_score_for_target(
    color: &PaletteColor,
    target: &PaletteTarget,
    used_colors: &HashSet<u32>,
) -> bool {
    color.hsl.saturation >= target.minimum_saturation
        && color.hsl.saturation <= target.maximum_saturation
        && color.hsl.lightness >= target.minimum_lightness
        && color.hsl.lightness <= target.maximum_lightness
        && !used_colors.contains(&color.rgb)
}

fn generate_palette_score(
    color: &PaletteColor,
    target: &PaletteTarget,
    dominant_population: f64,
) -> f64 {
    let saturation_score = if target.saturation_weight > 0.0 {
        target.saturation_weight * (1.0 - (color.hsl.saturation - target.target_saturation).abs())
    } else {
        0.0
    };
    let lightness_score = if target.lightness_weight > 0.0 {
        target.lightness_weight * (1.0 - (color.hsl.lightness - target.target_lightness).abs())
    } else {
        0.0
    };
    let population_score = if target.population_weight > 0.0 {
        target.population_weight * (color.population as f64 / dominant_population)
    } else {
        0.0
    };

    saturation_score + lightness_score + population_score
}

fn palette_targets() -> [(&'static str, PaletteTarget); 6] {
    [
        ("lightVibrant", PaletteTarget::light_vibrant()),
        ("vibrant", PaletteTarget::vibrant()),
        ("darkVibrant", PaletteTarget::dark_vibrant()),
        ("lightMuted", PaletteTarget::light_muted()),
        ("muted", PaletteTarget::muted()),
        ("darkMuted", PaletteTarget::dark_muted()),
    ]
}

fn should_ignore_color(color: u32) -> bool {
    let hsl = rgb_to_hsl(color);
    let is_black = hsl.lightness <= 0.05;
    let is_white = hsl.lightness >= 0.95;
    let is_near_red_i_line = hsl.hue >= 10.0 && hsl.hue <= 37.0 && hsl.saturation <= 0.82;

    is_black || is_white || is_near_red_i_line
}

fn quantize_rgb(red: u8, green: u8, blue: u8) -> u32 {
    pack_rgb(
        red & QUANTIZE_WORD_MASK,
        green & QUANTIZE_WORD_MASK,
        blue & QUANTIZE_WORD_MASK,
    )
}

fn pack_rgb(red: u8, green: u8, blue: u8) -> u32 {
    (u32::from(red) << 16) | (u32::from(green) << 8) | u32::from(blue)
}

fn unpack_rgb(color: u32) -> (u8, u8, u8) {
    (
        ((color >> 16) & 0xff) as u8,
        ((color >> 8) & 0xff) as u8,
        (color & 0xff) as u8,
    )
}

fn rgb_to_hsl(color: u32) -> HslColor {
    let (red, green, blue) = unpack_rgb(color);
    let red = f64::from(red) / 255.0;
    let green = f64::from(green) / 255.0;
    let blue = f64::from(blue) / 255.0;

    let max = red.max(green.max(blue));
    let min = red.min(green.min(blue));
    let lightness = (max + min) / 2.0;

    if (max - min).abs() < f64::EPSILON {
        return HslColor {
            hue: 0.0,
            saturation: 0.0,
            lightness,
        };
    }

    let delta = max - min;
    let saturation = delta / (1.0 - (2.0 * lightness - 1.0).abs());
    let hue = if (max - red).abs() < f64::EPSILON {
        60.0 * ((green - blue) / delta).rem_euclid(6.0)
    } else if (max - green).abs() < f64::EPSILON {
        60.0 * (((blue - red) / delta) + 2.0)
    } else {
        60.0 * (((red - green) / delta) + 4.0)
    };

    HslColor {
        hue,
        saturation,
        lightness,
    }
}

#[derive(Debug, Clone)]
struct PaletteColor {
    rgb: u32,
    population: usize,
    hsl: HslColor,
}

impl PaletteColor {
    fn new(rgb: u32, population: usize) -> Self {
        Self {
            rgb,
            population,
            hsl: rgb_to_hsl(rgb),
        }
    }

    fn argb(&self) -> u32 {
        0xff00_0000 | self.rgb
    }
}

#[derive(Debug, Clone, Copy)]
struct HslColor {
    hue: f64,
    saturation: f64,
    lightness: f64,
}

#[derive(Debug, Clone)]
struct PaletteTarget {
    minimum_saturation: f64,
    target_saturation: f64,
    maximum_saturation: f64,
    minimum_lightness: f64,
    target_lightness: f64,
    maximum_lightness: f64,
    is_exclusive: bool,
    saturation_weight: f64,
    lightness_weight: f64,
    population_weight: f64,
}

impl PaletteTarget {
    fn light_vibrant() -> Self {
        Self::new(0.35, 1.0, 1.0, 0.55, 0.74, 1.0)
    }

    fn vibrant() -> Self {
        Self::new(0.35, 1.0, 1.0, 0.3, 0.5, 0.7)
    }

    fn dark_vibrant() -> Self {
        Self::new(0.35, 1.0, 1.0, 0.0, 0.26, 0.45)
    }

    fn light_muted() -> Self {
        Self::new(0.0, 0.3, 0.4, 0.55, 0.74, 1.0)
    }

    fn muted() -> Self {
        Self::new(0.0, 0.3, 0.4, 0.3, 0.5, 0.7)
    }

    fn dark_muted() -> Self {
        Self::new(0.0, 0.3, 0.4, 0.0, 0.26, 0.45)
    }

    fn new(
        minimum_saturation: f64,
        target_saturation: f64,
        maximum_saturation: f64,
        minimum_lightness: f64,
        target_lightness: f64,
        maximum_lightness: f64,
    ) -> Self {
        let mut target = Self {
            minimum_saturation,
            target_saturation,
            maximum_saturation,
            minimum_lightness,
            target_lightness,
            maximum_lightness,
            is_exclusive: true,
            saturation_weight: 0.24,
            lightness_weight: 0.52,
            population_weight: 0.24,
        };
        target.normalize_weights();
        target
    }

    fn normalize_weights(&mut self) {
        let sum = self.saturation_weight + self.lightness_weight + self.population_weight;
        if sum > 0.0 {
            self.saturation_weight /= sum;
            self.lightness_weight /= sum;
            self.population_weight /= sum;
        }
    }
}

#[derive(Debug, Clone)]
struct ColorVolumeBox {
    lower_index: usize,
    upper_index: usize,
    population: usize,
    min_red: u8,
    max_red: u8,
    min_green: u8,
    max_green: u8,
    min_blue: u8,
    max_blue: u8,
}

impl ColorVolumeBox {
    fn new(
        lower_index: usize,
        upper_index: usize,
        colors: &[u32],
        histogram: &HashMap<u32, usize>,
    ) -> Self {
        let mut color_box = Self {
            lower_index,
            upper_index,
            population: 0,
            min_red: u8::MAX,
            max_red: 0,
            min_green: u8::MAX,
            max_green: 0,
            min_blue: u8::MAX,
            max_blue: 0,
        };
        color_box.fit_minimum_box(colors, histogram);
        color_box
    }

    fn volume(&self) -> usize {
        usize::from(self.max_red - self.min_red + 1)
            * usize::from(self.max_green - self.min_green + 1)
            * usize::from(self.max_blue - self.min_blue + 1)
    }

    fn can_split(&self) -> bool {
        self.color_count() > 1
    }

    fn color_count(&self) -> usize {
        self.upper_index + 1 - self.lower_index
    }

    fn split_box(&mut self, colors: &mut [u32], histogram: &HashMap<u32, usize>) -> ColorVolumeBox {
        let split_point = self.find_split_point(colors, histogram);
        let new_box = ColorVolumeBox::new(split_point + 1, self.upper_index, colors, histogram);
        self.upper_index = split_point;
        self.fit_minimum_box(colors, histogram);
        new_box
    }

    fn average_color(&self, colors: &[u32], histogram: &HashMap<u32, usize>) -> PaletteColor {
        let mut red_sum = 0usize;
        let mut green_sum = 0usize;
        let mut blue_sum = 0usize;
        let mut total_population = 0usize;

        for color in &colors[self.lower_index..=self.upper_index] {
            let population = histogram.get(color).copied().unwrap_or_default();
            let (red, green, blue) = unpack_rgb(*color);
            red_sum += population * usize::from(red);
            green_sum += population * usize::from(green);
            blue_sum += population * usize::from(blue);
            total_population += population;
        }

        let red_mean = (red_sum as f64 / total_population as f64).round() as u8;
        let green_mean = (green_sum as f64 / total_population as f64).round() as u8;
        let blue_mean = (blue_sum as f64 / total_population as f64).round() as u8;

        PaletteColor::new(pack_rgb(red_mean, green_mean, blue_mean), total_population)
    }

    fn fit_minimum_box(&mut self, colors: &[u32], histogram: &HashMap<u32, usize>) {
        let mut min_red = u8::MAX;
        let mut min_green = u8::MAX;
        let mut min_blue = u8::MAX;
        let mut max_red = 0u8;
        let mut max_green = 0u8;
        let mut max_blue = 0u8;
        let mut population = 0usize;

        for color in &colors[self.lower_index..=self.upper_index] {
            let (red, green, blue) = unpack_rgb(*color);
            population += histogram.get(color).copied().unwrap_or_default();
            min_red = min_red.min(red);
            min_green = min_green.min(green);
            min_blue = min_blue.min(blue);
            max_red = max_red.max(red);
            max_green = max_green.max(green);
            max_blue = max_blue.max(blue);
        }

        self.population = population;
        self.min_red = min_red;
        self.min_green = min_green;
        self.min_blue = min_blue;
        self.max_red = max_red;
        self.max_green = max_green;
        self.max_blue = max_blue;
    }

    fn find_split_point(&self, colors: &mut [u32], histogram: &HashMap<u32, usize>) -> usize {
        let longest_dimension = self.longest_dimension();
        colors[self.lower_index..=self.upper_index].sort_by_key(|color| {
            let (red, green, blue) = unpack_rgb(*color);
            match longest_dimension {
                ColorComponent::Red => {
                    (u32::from(red) << 16) | (u32::from(green) << 8) | u32::from(blue)
                }
                ColorComponent::Green => {
                    (u32::from(green) << 16) | (u32::from(red) << 8) | u32::from(blue)
                }
                ColorComponent::Blue => {
                    (u32::from(blue) << 16) | (u32::from(green) << 8) | u32::from(red)
                }
            }
        });

        let median_population = (self.population as f64 / 2.0).round() as usize;
        let mut cumulative_population = 0usize;

        for (index, color) in colors[self.lower_index..=self.upper_index]
            .iter()
            .enumerate()
        {
            cumulative_population += histogram.get(color).copied().unwrap_or_default();
            if cumulative_population >= median_population {
                return (self.lower_index + index).min(self.upper_index - 1);
            }
        }

        self.lower_index
    }

    fn longest_dimension(&self) -> ColorComponent {
        let red_length = self.max_red - self.min_red;
        let green_length = self.max_green - self.min_green;
        let blue_length = self.max_blue - self.min_blue;

        if red_length >= green_length && red_length >= blue_length {
            ColorComponent::Red
        } else if green_length >= red_length && green_length >= blue_length {
            ColorComponent::Green
        } else {
            ColorComponent::Blue
        }
    }
}

#[derive(Debug, Clone, Copy)]
enum ColorComponent {
    Red,
    Green,
    Blue,
}

#[derive(Debug, Clone)]
struct PriorityColorBox(ColorVolumeBox);

impl PriorityColorBox {
    fn from_box(color_box: ColorVolumeBox) -> Self {
        Self(color_box)
    }

    fn into_inner(self) -> ColorVolumeBox {
        self.0
    }
}

impl PartialEq for PriorityColorBox {
    fn eq(&self, other: &Self) -> bool {
        self.0.volume() == other.0.volume() && self.0.population == other.0.population
    }
}

impl Eq for PriorityColorBox {}

impl PartialOrd for PriorityColorBox {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for PriorityColorBox {
    fn cmp(&self, other: &Self) -> Ordering {
        self.0
            .volume()
            .cmp(&other.0.volume())
            .then_with(|| self.0.population.cmp(&other.0.population))
    }
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

fn update_track_metadata_with_id3(
    path: String,
    metadata: TrackMetadataUpdate,
) -> anyhow::Result<()> {
    let mut tag = Id3Tag::read_from_path(&path).unwrap_or_else(|_| Id3Tag::new());

    if let Some(v) = metadata.title {
        tag.set_title(v);
    }
    if let Some(v) = metadata.artist {
        tag.set_artist(v);
    }
    if let Some(v) = metadata.album {
        tag.set_album(v);
    }
    if let Some(v) = metadata.album_artist {
        tag.set_album_artist(v);
    }
    if let Some(v) = metadata.track_number {
        tag.set_track(v as u32);
    }
    if let Some(v) = metadata.track_total {
        tag.set_total_tracks(v as u32);
    }
    if let Some(v) = metadata.disc_number {
        tag.set_disc(v as u32);
    }
    if let Some(v) = metadata.date {
        tag.set_text("TDRC", v);
    } else if let Some(v) = metadata.year {
        tag.set_year(v);
    }

    if let Some(v) = metadata.comment {
        tag.add_frame(Id3Comment {
            lang: "eng".to_string(),
            description: String::new(),
            text: v,
        });
    }

    if let Some(v) = metadata.lyrics {
        tag.add_frame(Id3Lyrics {
            lang: "eng".to_string(),
            description: String::new(),
            text: v,
        });
    }

    if let Some(v) = metadata.composer {
        tag.set_text("TCOM", v);
    }
    if let Some(v) = metadata.lyricist {
        tag.set_text("TEXT", v);
    }
    if let Some(v) = metadata.performer {
        tag.set_text("TPE3", v);
    }
    if let Some(v) = metadata.conductor {
        tag.add_frame(Id3ExtendedText {
            description: "CONDUCTOR".to_string(),
            value: v,
        });
    }
    if let Some(v) = metadata.remixer {
        tag.add_frame(Id3ExtendedText {
            description: "REMIXER".to_string(),
            value: v,
        });
    }

    if let Some(v) = metadata.genres.first() {
        tag.set_genre(v.clone());
    }

    for pic in metadata.pictures {
        let pic_type = match pic.picture_type.to_lowercase().as_str() {
            "front" | "cover front" | "front cover" => Id3PictureType::CoverFront,
            "back" | "cover back" | "back cover" => Id3PictureType::CoverBack,
            _ => Id3PictureType::Other,
        };

        tag.add_frame(Id3Picture {
            mime_type: pic.mime_type,
            picture_type: pic_type,
            description: pic.description.unwrap_or_default(),
            data: pic.bytes,
        });
    }

    tag.write_to_path(&path, Id3Version::Id3v24)?;
    Ok(())
}

fn update_track_metadata_with_lofty(
    path: String,
    metadata: TrackMetadataUpdate,
) -> anyhow::Result<()> {
    // 1. 读取音频文件 (简洁版本，参考 demo)
    let mut tagged_file = Probe::open(&path)?.read()?;

    // 2. 获取可变的 Tag (优先主标签，其次第一个标签，都没有则新建)
    let tag = match tagged_file.primary_tag_mut() {
        Some(primary) => primary,
        None => match tagged_file.first_tag_mut() {
            Some(first) => first,
            None => {
                let tag_type = tagged_file.primary_tag_type();
                tagged_file.insert_tag(Tag::new(tag_type));
                tagged_file.primary_tag_mut().unwrap()
            }
        },
    };

    // 如果歌曲是 ID3v1，则将其转换为 ID3v2，旧的 v1 标签保留在原处
    if tag.tag_type() == TagType::Id3v1 {
        println!("ID3v1 detected, upgrading to ID3v2...");
        // 将内存中的标签对象转换为 ID3v2，以便支持封面等现代特性
        tag.re_map(TagType::Id3v2);
    }

    // 3. 设置标签内容 (全部交给 lofty Accessor 和 ItemKey 处理)
    if let Some(v) = metadata.title {
        tag.set_title(v);
    }
    if let Some(v) = metadata.artist {
        tag.set_artist(v);
    }
    if let Some(v) = metadata.album {
        tag.set_album(v);
    }
    if let Some(v) = metadata.genres.get(0) {
        tag.set_genre(v.clone());
    }
    if let Some(v) = metadata.track_number {
        tag.set_track(v as u32);
    }
    if let Some(v) = metadata.track_total {
        tag.set_track_total(v as u32);
    }
    if let Some(v) = metadata.disc_number {
        tag.set_disk(v as u32);
    }
    if let Some(v) = metadata.date {
        tag.insert_text(ItemKey::RecordingDate, v);
    } else if let Some(v) = metadata.year {
        tag.insert_text(ItemKey::Year, v.to_string());
    }

    // 其他通用项
    if let Some(v) = metadata.album_artist {
        tag.insert_text(ItemKey::AlbumArtist, v);
    }
    if let Some(v) = metadata.comment {
        tag.insert_text(ItemKey::Comment, v);
    }
    if let Some(v) = metadata.lyrics {
        tag.insert_text(ItemKey::UnsyncLyrics, v);
    }
    if let Some(v) = metadata.composer {
        tag.insert_text(ItemKey::Composer, v);
    }
    if let Some(v) = metadata.lyricist {
        tag.insert_text(ItemKey::Lyricist, v);
    }
    if let Some(v) = metadata.performer {
        tag.insert_text(ItemKey::Performer, v);
    }
    if let Some(v) = metadata.conductor {
        tag.insert_text(ItemKey::Conductor, v);
    }
    if let Some(v) = metadata.remixer {
        tag.insert_text(ItemKey::Remixer, v);
    }

    // 图片处理
    if !metadata.pictures.is_empty() {
        use lofty::picture::{MimeType, Picture, PictureType};
        for pic in metadata.pictures {
            let pic_type = match pic.picture_type.to_lowercase().as_str() {
                "front" | "cover front" | "front cover" => PictureType::CoverFront,
                "back" | "cover back" | "back cover" => PictureType::CoverBack,
                _ => PictureType::Other,
            };
            tag.remove_picture_type(pic_type);
            tag.push_picture(
                Picture::unchecked(pic.bytes)
                    .mime_type(MimeType::from_str(&pic.mime_type))
                    .pic_type(pic_type)
                    .build(),
            );
        }
    }

    // 4. 保存标签 (默认根据文件类型选择最佳方案)
    tag.save_to_path(&path, WriteOptions::default())?;

    Ok(())
}

fn read_track_metadata_with_id3(path: &str) -> TrackMetadataUpdate {
    let Ok(tag) = Id3Tag::read_from_path(path) else {
        return TrackMetadataUpdate::default();
    };

    let title = tag.title().map(|v| v.to_string());
    let artist = tag.artist().map(|v| v.to_string());
    let album = tag.album().map(|v| v.to_string());
    let album_artist = tag.album_artist().map(|v| v.to_string());
    let track_number = tag.track().map(|v| v as i32);
    let track_total = tag.total_tracks().map(|v| v as i32);
    let disc_number = tag.disc().map(|v| v as i32);
    let date = tag.date_recorded().map(|v| v.to_string());
    let year = tag.year();
    let comment = tag.comments().next().map(|comment| comment.text.clone());
    let lyrics = tag.lyrics().next().map(|lyrics| lyrics.text.clone());
    let composer = first_text_frame_value(&tag, "TCOM");
    let lyricist = first_text_frame_value(&tag, "TEXT");
    let performer = first_text_frame_value(&tag, "TPE3");
    let conductor = first_extended_text_value(&tag, "CONDUCTOR");
    let remixer = first_extended_text_value(&tag, "REMIXER");
    let genres = tag
        .genres_parsed()
        .into_iter()
        .map(|genre| genre.into_owned())
        .collect::<Vec<_>>();
    let pictures = tag
        .pictures()
        .map(|picture| TrackPicture {
            bytes: picture.data.clone(),
            mime_type: picture.mime_type.clone(),
            picture_type: id3_picture_type_to_label(picture.picture_type),
            description: if picture.description.is_empty() {
                None
            } else {
                Some(picture.description.clone())
            },
        })
        .collect::<Vec<_>>();

    TrackMetadataUpdate {
        title,
        artist,
        album,
        album_artist,
        track_number,
        track_total,
        disc_number,
        date,
        year,
        comment,
        lyrics,
        composer,
        lyricist,
        performer,
        conductor,
        remixer,
        genres,
        pictures,
    }
}

fn read_track_metadata_with_lofty(path: &str) -> TrackMetadataUpdate {
    let Ok(tagged_file) = Probe::open(path).and_then(|probe| probe.read()) else {
        return TrackMetadataUpdate::default();
    };

    let Some(tag) = tagged_file
        .primary_tag()
        .or_else(|| tagged_file.first_tag())
    else {
        return TrackMetadataUpdate::default();
    };

    let title = tag.title().map(|v| v.to_string());
    let artist = tag.artist().map(|v| v.to_string());
    let album = tag.album().map(|v| v.to_string());
    let album_artist = first_tag_value(tag, ItemKey::AlbumArtist);
    let track_number = tag.track().map(|v| v as i32);
    let track_total = tag.track_total().map(|v| v as i32);
    let disc_number = tag.disk().map(|v| v as i32);
    let date = tag.date().map(|v| v.to_string());
    let year = tag.date().map(|v| i32::from(v.year));
    let comment = tag
        .comment()
        .map(|v| v.to_string())
        .or_else(|| first_tag_value(tag, ItemKey::Comment));
    let lyrics = first_tag_value(tag, ItemKey::UnsyncLyrics)
        .or_else(|| first_tag_value(tag, ItemKey::Lyrics));
    let composer = first_tag_value(tag, ItemKey::Composer);
    let lyricist = first_tag_value(tag, ItemKey::Lyricist);
    let performer = first_tag_value(tag, ItemKey::Performer);
    let conductor = first_tag_value(tag, ItemKey::Conductor);
    let remixer = first_tag_value(tag, ItemKey::Remixer);
    let genres = tag
        .get_strings(ItemKey::Genre)
        .map(str::to_string)
        .collect::<Vec<_>>();
    let pictures = tag
        .pictures()
        .iter()
        .map(|picture| TrackPicture {
            bytes: picture.data().to_vec(),
            mime_type: picture
                .mime_type()
                .map(|mime| mime.to_string())
                .unwrap_or_else(|| "image/jpeg".to_string()),
            picture_type: lofty_picture_type_to_label(picture.pic_type()),
            description: picture.description().map(str::to_string),
        })
        .collect::<Vec<_>>();

    TrackMetadataUpdate {
        title,
        artist,
        album,
        album_artist,
        track_number,
        track_total,
        disc_number,
        date,
        year,
        comment,
        lyrics,
        composer,
        lyricist,
        performer,
        conductor,
        remixer,
        genres,
        pictures,
    }
}

fn first_tag_value(tag: &Tag, key: ItemKey) -> Option<String> {
    tag.get_strings(key).next().map(str::to_string)
}

fn first_text_frame_value(tag: &Id3Tag, frame_id: &str) -> Option<String> {
    tag.get(frame_id)
        .and_then(|frame| frame.content().text())
        .map(str::to_string)
}

fn first_extended_text_value(tag: &Id3Tag, description: &str) -> Option<String> {
    tag.frames().find_map(|frame| {
        let ext = frame.content().extended_text()?;
        if ext.description.eq_ignore_ascii_case(description) {
            Some(ext.value.clone())
        } else {
            None
        }
    })
}

fn id3_picture_type_to_label(picture_type: Id3PictureType) -> String {
    match picture_type {
        Id3PictureType::CoverFront => "Front Cover".to_string(),
        Id3PictureType::CoverBack => "Back Cover".to_string(),
        Id3PictureType::Leaflet => "Leaflet Page".to_string(),
        Id3PictureType::Media => "Media Label CD".to_string(),
        Id3PictureType::LeadArtist => "Lead Artist".to_string(),
        Id3PictureType::Artist => "Artist / Performer".to_string(),
        Id3PictureType::Conductor => "Conductor".to_string(),
        Id3PictureType::Band => "Band Logo".to_string(),
        Id3PictureType::BandLogo => "Band Logo".to_string(),
        Id3PictureType::Composer => "Composer".to_string(),
        Id3PictureType::Lyricist => "Lyricist".to_string(),
        Id3PictureType::RecordingLocation => "Recording Location".to_string(),
        Id3PictureType::DuringRecording => "During Recording".to_string(),
        Id3PictureType::DuringPerformance => "During Performance".to_string(),
        Id3PictureType::ScreenCapture => "Screen Capture".to_string(),
        Id3PictureType::BrightFish => "Bright Fish".to_string(),
        Id3PictureType::Illustration => "Illustration".to_string(),
        Id3PictureType::PublisherLogo => "Publisher Logo".to_string(),
        Id3PictureType::Other => "Other".to_string(),
        Id3PictureType::OtherIcon => "Other Icon".to_string(),
        Id3PictureType::Icon => "Icon".to_string(),
        Id3PictureType::Undefined(v) => format!("Undefined({v})"),
    }
}

fn lofty_picture_type_to_label(picture_type: lofty::picture::PictureType) -> String {
    match picture_type {
        lofty::picture::PictureType::CoverFront => "Front Cover".to_string(),
        lofty::picture::PictureType::CoverBack => "Back Cover".to_string(),
        lofty::picture::PictureType::Leaflet => "Leaflet Page".to_string(),
        lofty::picture::PictureType::Media => "Media Label CD".to_string(),
        lofty::picture::PictureType::LeadArtist => "Lead Artist".to_string(),
        lofty::picture::PictureType::Artist => "Artist / Performer".to_string(),
        lofty::picture::PictureType::Conductor => "Conductor".to_string(),
        lofty::picture::PictureType::Band => "Band Logo".to_string(),
        lofty::picture::PictureType::Composer => "Composer".to_string(),
        lofty::picture::PictureType::Lyricist => "Lyricist".to_string(),
        lofty::picture::PictureType::RecordingLocation => "Recording Location".to_string(),
        lofty::picture::PictureType::DuringRecording => "During Recording".to_string(),
        lofty::picture::PictureType::DuringPerformance => "During Performance".to_string(),
        lofty::picture::PictureType::ScreenCapture => "Screen Capture".to_string(),
        lofty::picture::PictureType::BrightFish => "Bright Fish".to_string(),
        lofty::picture::PictureType::Illustration => "Illustration".to_string(),
        lofty::picture::PictureType::PublisherLogo => "Publisher Logo".to_string(),
        lofty::picture::PictureType::Other => "Other".to_string(),
        lofty::picture::PictureType::Icon => "Icon".to_string(),
        lofty::picture::PictureType::OtherIcon => "Other Icon".to_string(),
        lofty::picture::PictureType::Undefined(v) => format!("Undefined({v})"),
        _ => "Other".to_string(),
    }
}

pub fn remove_all_tags(path: String) -> anyhow::Result<()> {
    if should_use_id3(&path) {
        id3::v1v2::remove_from_path(&path)?;
        return Ok(());
    }

    let tagged_file = Probe::open(&path)?.read()?;
    for tag in tagged_file.tags() {
        tag.tag_type().remove_from_path(&path)?;
    }
    Ok(())
}
