use std::cmp::Ordering;
use std::collections::{BTreeMap, BinaryHeap, HashMap, HashSet};

use zune_core::colorspace::ColorSpace;
use zune_image::image::Image;

const PALETTE_MAX_COLORS: usize = 16;
const QUANTIZE_WORD_MASK: u8 = 0xF8;

pub(crate) fn build_theme_colors_blob(image: &Image) -> anyhow::Result<Option<Vec<u8>>> {
    let Some(theme_colors) = build_theme_colors_from_image(image)? else {
        return Ok(None);
    };

    Ok(Some(serde_json::to_vec(&theme_colors)?))
}

fn build_theme_colors_from_image(image: &Image) -> anyhow::Result<Option<BTreeMap<String, u32>>> {
    let target_colorspace = if image.colorspace().has_alpha() {
        ColorSpace::RGBA
    } else {
        ColorSpace::RGB
    };

    let mut palette_image = image.clone();
    if palette_image.colorspace() != target_colorspace {
        palette_image
            .convert_color(target_colorspace)
            .map_err(|err| anyhow::anyhow!("failed to convert artwork colorspace: {err}"))?;
    }

    let flattened_frames = palette_image.flatten_to_u8();
    let Some(pixels) = flattened_frames.first() else {
        return Ok(None);
    };

    Ok(build_theme_colors_from_pixels(
        pixels,
        target_colorspace.num_components(),
    ))
}

fn build_theme_colors_from_pixels(
    pixels: &[u8],
    channels_per_pixel: usize,
) -> Option<BTreeMap<String, u32>> {
    let palette_colors = quantize_palette_colors(pixels, channels_per_pixel, PALETTE_MAX_COLORS);
    let theme_colors = select_theme_colors(palette_colors);
    if theme_colors.is_empty() {
        return None;
    }

    Some(theme_colors)
}

pub fn debug_build_theme_colors_from_pixels(
    pixels: &[u8],
    channels_per_pixel: usize,
) -> Option<BTreeMap<String, u32>> {
    build_theme_colors_from_pixels(pixels, channels_per_pixel)
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
    let mut next_sequence = 0usize;
    priority_queue.push(PriorityColorBox::from_box(
        ColorVolumeBox::new(0, colors.len() - 1, &colors, &histogram),
        next_sequence,
    ));
    next_sequence += 1;

    while priority_queue.len() < max_colors {
        let Some(mut color_box) = priority_queue.pop().map(PriorityColorBox::into_inner) else {
            break;
        };

        if !color_box.can_split() {
            priority_queue.push(PriorityColorBox::from_box(color_box, next_sequence));
            next_sequence += 1;
            break;
        }

        let new_box = color_box.split_box(&mut colors, &histogram);
        priority_queue.push(PriorityColorBox::from_box(new_box, next_sequence));
        next_sequence += 1;
        priority_queue.push(PriorityColorBox::from_box(color_box, next_sequence));
        next_sequence += 1;
    }

    let mut palette_colors = Vec::with_capacity(priority_queue.len());
    while let Some(color_box) = priority_queue.pop().map(PriorityColorBox::into_inner) {
        let average_color = color_box.average_color(&colors, &histogram);
        if !should_ignore_color(average_color.rgb) {
            palette_colors.push(average_color);
        }
    }

    palette_colors
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
struct PriorityColorBox {
    color_box: ColorVolumeBox,
    sequence: usize,
}

impl PriorityColorBox {
    fn from_box(color_box: ColorVolumeBox, sequence: usize) -> Self {
        Self {
            color_box,
            sequence,
        }
    }

    fn into_inner(self) -> ColorVolumeBox {
        self.color_box
    }
}

impl PartialEq for PriorityColorBox {
    fn eq(&self, other: &Self) -> bool {
        self.color_box.volume() == other.color_box.volume() && self.sequence == other.sequence
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
        self.color_box
            .volume()
            .cmp(&other.color_box.volume())
            .then_with(|| self.sequence.cmp(&other.sequence))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quantize_palette_colors_preserves_first_seen_order() {
        let pixels = [
            0x08, 0x18, 0x28, 0xff, 0x08, 0x18, 0x28, 0xff, 0x30, 0x40, 0x50, 0xff,
        ];

        let palette = quantize_palette_colors(&pixels, 4, PALETTE_MAX_COLORS);

        assert_eq!(palette.len(), 2);
        assert_eq!(palette[0].rgb, pack_rgb(0x08, 0x18, 0x28));
        assert_eq!(palette[0].population, 2);
        assert_eq!(palette[1].rgb, pack_rgb(0x30, 0x40, 0x50));
        assert_eq!(palette[1].population, 1);
    }

    #[test]
    fn single_neutral_color_maps_to_expected_theme_slots() {
        let pixels = [
            0x78, 0x78, 0x78, 0xff, 0x78, 0x78, 0x78, 0xff, 0x78, 0x78, 0x78, 0xff,
        ];

        let theme_colors = build_theme_colors_from_pixels(&pixels, 4).expect("theme colors");

        assert_eq!(theme_colors.len(), 2);
        assert_eq!(theme_colors.get("dominant"), Some(&0xff78_7878));
        assert_eq!(theme_colors.get("muted"), Some(&0xff78_7878));
    }

    #[test]
    fn fully_transparent_pixels_are_ignored_like_dart_palette_generator() {
        let pixels = [
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x20, 0x90, 0xd0, 0xff, 0x20, 0x90,
            0xd0, 0xff,
        ];

        let theme_colors = build_theme_colors_from_pixels(&pixels, 4).expect("theme colors");

        assert_eq!(theme_colors.get("dominant"), Some(&0xff20_90d0));
    }
}
