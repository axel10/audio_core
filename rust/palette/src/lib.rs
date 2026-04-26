use std::cmp::Ordering;
use std::collections::{BTreeMap, BinaryHeap, HashMap, HashSet};

use serde::Serialize;

const PALETTE_MAX_COLORS: usize = 16;
const QUANTIZE_WORD_MASK: u8 = 0xF8;

pub fn build_theme_colors_from_pixels(
    pixels: &[u8],
    channels_per_pixel: usize,
) -> Option<BTreeMap<String, u32>> {
    build_theme_colors_from_pixels_with_options(
        pixels,
        channels_per_pixel,
        ThemePaletteOptions::default(),
    )
}

pub fn build_theme_colors_from_pixels_with_options(
    pixels: &[u8],
    channels_per_pixel: usize,
    options: ThemePaletteOptions,
) -> Option<BTreeMap<String, u32>> {
    build_theme_palette_bundle_from_pixels_with_options(pixels, channels_per_pixel, options)
        .map(|bundle| bundle.theme_colors)
}

pub fn debug_build_theme_colors_from_pixels(
    pixels: &[u8],
    channels_per_pixel: usize,
) -> Option<BTreeMap<String, u32>> {
    build_theme_colors_from_pixels(pixels, channels_per_pixel)
}

pub fn debug_build_theme_colors_from_pixels_with_options(
    pixels: &[u8],
    channels_per_pixel: usize,
    options: ThemePaletteOptions,
) -> Option<BTreeMap<String, u32>> {
    build_theme_colors_from_pixels_with_options(pixels, channels_per_pixel, options)
}

pub fn build_theme_palette_bundle_from_pixels_with_options(
    pixels: &[u8],
    channels_per_pixel: usize,
    options: ThemePaletteOptions,
) -> Option<ThemePaletteBundle> {
    let (palette_colors, mesh_colors) =
        quantize_palette_colors(pixels, channels_per_pixel, PALETTE_MAX_COLORS);
    let (theme_colors, mesh_debug) = select_theme_colors(palette_colors, mesh_colors, options);
    if theme_colors.is_empty() {
        return None;
    }

    Some(ThemePaletteBundle {
        theme_colors: theme_colors
            .into_iter()
            .map(|(key, color)| (key, color.argb()))
            .collect(),
        mesh_debug,
    })
}

fn quantize_palette_colors(
    pixels: &[u8],
    channels_per_pixel: usize,
    max_colors: usize,
) -> (Vec<PaletteColor>, Vec<PaletteColor>) {
    if channels_per_pixel < 3 {
        return (Vec::new(), Vec::new());
    }

    let mut histogram = HashMap::<u32, usize>::new();
    let mut ignored_histogram = HashMap::<u32, usize>::new();
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
        if should_ignore_color(quantized) {
            *ignored_histogram.entry(quantized).or_insert(0) += 1;
        } else {
            if !histogram.contains_key(&quantized) {
                colors.push(quantized);
            }
            *histogram.entry(quantized).or_insert(0) += 1;
        }
    }

    let theme_colors = if histogram.is_empty() {
        Vec::new()
    } else if colors.len() <= max_colors {
        colors
            .into_iter()
            .map(|color| PaletteColor::new(color, histogram[&color]))
            .collect()
    } else {
        quantize_histogram(histogram, colors, max_colors)
    };

    let mut mesh_colors = theme_colors.clone();
    let mut ignored_counts: Vec<_> = ignored_histogram.into_iter().collect();
    ignored_counts.sort_unstable_by(|a, b| b.1.cmp(&a.1));
    for (color, pop) in ignored_counts.into_iter().take(8) {
        mesh_colors.push(PaletteColor::new(color, pop));
    }
    mesh_colors.sort_by(|a, b| b.population.cmp(&a.population));

    (theme_colors, mesh_colors)
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
        priority_queue.push(PriorityColorBox::from_box(new_box));
        priority_queue.push(PriorityColorBox::from_box(color_box));
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

fn select_theme_colors(
    mut palette_colors: Vec<PaletteColor>,
    mesh_colors: Vec<PaletteColor>,
    options: ThemePaletteOptions,
) -> (BTreeMap<String, PaletteColor>, Option<MeshSelectionDebug>) {
    if palette_colors.is_empty() {
        return (BTreeMap::new(), None);
    }

    palette_colors.sort_by(|a, b| b.population.cmp(&a.population));
    let dominant = palette_colors[0].clone();
    let dominant_population = dominant.population.max(1) as f64;
    let hue_cohesion = options.hue_cohesion.clamp(0.0, 1.0);
    let hue_anchors = build_hue_anchors(&palette_colors, &dominant, hue_cohesion);
    let mut theme_colors = BTreeMap::new();
    let mut used_colors = HashSet::<u32>::new();

    theme_colors.insert("dominant".to_string(), dominant.clone());

    for (name, target) in palette_targets() {
        if let Some(color) = get_max_scored_palette_color(
            &palette_colors,
            &target,
            dominant_population,
            &used_colors,
            &hue_anchors,
            hue_cohesion,
        ) {
            theme_colors.insert(name.to_string(), color.clone());
            if target.is_exclusive {
                used_colors.insert(color.rgb);
            }
        }
    }

    harmonize_theme_colors(&mut theme_colors, &hue_anchors, hue_cohesion);

    let mesh_scoring = MeshScoringTuning::from_options(options);
    let mesh_selection = select_mesh_colors(&mesh_colors, mesh_scoring);
    if let Some(mesh_combo) = mesh_selection.as_ref().map(|selection| &selection.colors) {
        theme_colors.insert("mesh1".to_string(), mesh_combo[0].clone());
        theme_colors.insert("mesh2".to_string(), mesh_combo[1].clone());
        theme_colors.insert("mesh3".to_string(), mesh_combo[2].clone());
        theme_colors.insert("mesh4".to_string(), mesh_combo[3].clone());
    }

    let mesh_debug = mesh_selection.map(|selection| selection.debug);
    (theme_colors, mesh_debug)
}

fn get_max_scored_palette_color<'a>(
    palette_colors: &'a [PaletteColor],
    target: &PaletteTarget,
    dominant_population: f64,
    used_colors: &HashSet<u32>,
    hue_anchors: &[f64],
    hue_cohesion: f64,
) -> Option<&'a PaletteColor> {
    let mut best_score = 0.0;
    let mut best_color = None;

    for color in palette_colors {
        if !should_score_for_target(color, target, used_colors) {
            continue;
        }

        let score = generate_palette_score(
            color,
            target,
            dominant_population,
            hue_anchors,
            hue_cohesion,
        );
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
    hue_anchors: &[f64],
    hue_cohesion: f64,
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

    let hue_score = if hue_cohesion > 0.0 && !hue_anchors.is_empty() && color.hsl.saturation > 0.08
    {
        let similarity = hue_anchors
            .iter()
            .map(|anchor| hue_similarity(color.hsl.hue, *anchor))
            .fold(0.0, f64::max);
        0.2 * hue_cohesion * similarity
    } else {
        0.0
    };

    saturation_score + lightness_score + population_score + hue_score
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
    oklab: OklabColor,
    oklch: OklchColor,
}

impl PaletteColor {
    fn new(rgb: u32, population: usize) -> Self {
        let (r, g, b) = unpack_rgb(rgb);
        let oklab = rgb_to_oklab(r, g, b);
        let oklch = oklab_to_oklch(oklab);
        Self {
            rgb,
            population,
            hsl: rgb_to_hsl(rgb),
            oklab,
            oklch,
        }
    }

    fn argb(&self) -> u32 {
        0xff00_0000 | self.rgb
    }
}

#[derive(Debug, Clone, Copy, Serialize)]
pub struct ThemePaletteOptions {
    /// `0.0` keeps the current palette behavior.
    /// `1.0` strongly pulls non-dominant colors toward one or two anchor hues
    /// derived from the artwork's main theme.
    pub hue_cohesion: f64,
    /// Gaussian blur radius used before palette sampling.
    /// Larger values produce softer, more averaged artwork input.
    pub palette_blur_radius: f64,
    /// Multiplier for the penalty applied to muddy/clashing mesh color combinations.
    /// Default is 1.0.
    pub mesh_muddy_penalty_multiplier: f64,
    /// Multiplier for the mesh population bias.
    /// Default is 1.0.
    pub mesh_population_strength: f64,
    /// Multiplier for mesh hue/shape contrast.
    /// Default is 1.0.
    pub mesh_contrast_strength: f64,
    /// Multiplier for mesh harmony and cohesion.
    /// Default is 1.0.
    pub mesh_harmony_strength: f64,
    /// Multiplier for mesh vibrancy / chroma emphasis.
    /// Default is 1.0.
    pub mesh_vibrancy_strength: f64,
}

impl Default for ThemePaletteOptions {
    fn default() -> Self {
        Self {
            hue_cohesion: 0.0,
            palette_blur_radius: 5.0,
            mesh_muddy_penalty_multiplier: 1.0,
            mesh_population_strength: 1.0,
            mesh_contrast_strength: 1.0,
            mesh_harmony_strength: 1.0,
            mesh_vibrancy_strength: 1.0,
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct ThemePaletteBundle {
    pub theme_colors: BTreeMap<String, u32>,
    pub mesh_debug: Option<MeshSelectionDebug>,
}

#[derive(Debug, Clone, Serialize)]
pub struct MeshSelectionDebug {
    pub score: MeshScoreBreakdown,
    pub colors: Vec<MeshColorDebug>,
}

#[derive(Debug, Clone, Serialize)]
pub struct MeshScoreBreakdown {
    pub population: f64,
    pub distinct: f64,
    pub harmony: f64,
    pub vibrancy: f64,
    pub cohesion: f64,
    pub over_chroma: f64,
    pub total: f64,
}

#[derive(Debug, Clone, Serialize)]
pub struct MeshColorDebug {
    pub slot: String,
    pub color: u32,
    pub role: String,
    pub primary_driver: String,
    pub hue: f64,
    pub chroma: f64,
    pub lightness: f64,
    pub population: usize,
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
}

impl PriorityColorBox {
    fn from_box(color_box: ColorVolumeBox) -> Self {
        Self { color_box }
    }

    fn into_inner(self) -> ColorVolumeBox {
        self.color_box
    }
}

impl PartialEq for PriorityColorBox {
    fn eq(&self, other: &Self) -> bool {
        self.color_box.volume() == other.color_box.volume()
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
        self.color_box.volume().cmp(&other.color_box.volume())
    }
}

fn build_hue_anchors(
    palette_colors: &[PaletteColor],
    dominant: &PaletteColor,
    hue_cohesion: f64,
) -> Vec<f64> {
    if hue_cohesion <= 0.0 || dominant.hsl.saturation <= 0.08 {
        return Vec::new();
    }

    let mut anchors = vec![dominant.hsl.hue];
    let dominant_population = dominant.population.max(1) as f64;
    let mut best_secondary_score = 0.0;
    let mut best_secondary_hue = None;

    for color in palette_colors.iter().skip(1) {
        if color.hsl.saturation <= 0.16 {
            continue;
        }

        let distance = circular_hue_distance(dominant.hsl.hue, color.hsl.hue);
        if !(72.0..=180.0).contains(&distance) {
            continue;
        }

        let population_score = color.population as f64 / dominant_population;
        let saturation_score = color.hsl.saturation;
        let spacing_score = if distance <= 120.0 {
            (distance - 72.0) / 48.0
        } else {
            1.0 - ((distance - 120.0) / 60.0)
        }
        .clamp(0.0, 1.0);
        let score = population_score * 0.7 + saturation_score * 0.1 + spacing_score * 0.2;
        if score > best_secondary_score {
            best_secondary_score = score;
            best_secondary_hue = Some(color.hsl.hue);
        }
    }

    if best_secondary_score >= 0.3 {
        if let Some(hue) = best_secondary_hue {
            anchors.push(hue);
        }
    }

    anchors
}

fn harmonize_theme_colors(
    theme_colors: &mut BTreeMap<String, PaletteColor>,
    hue_anchors: &[f64],
    hue_cohesion: f64,
) {
    if hue_cohesion <= 0.0 || hue_anchors.is_empty() {
        return;
    }

    let shift_strength = 0.55 * hue_cohesion;
    let max_shift = 48.0 * hue_cohesion;

    for (name, color) in theme_colors.iter_mut() {
        if name == "dominant" || color.hsl.saturation <= 0.08 {
            continue;
        }

        let Some(anchor_hue) = nearest_hue_anchor(color.hsl.hue, hue_anchors) else {
            continue;
        };

        let new_hue = move_hue_toward(color.hsl.hue, anchor_hue, shift_strength, max_shift);
        let new_hsl = HslColor {
            hue: new_hue,
            saturation: color.hsl.saturation,
            lightness: color.hsl.lightness,
        };
        color.hsl = new_hsl;
        color.rgb = hsl_to_rgb(new_hsl);
    }
}

fn hue_similarity(hue: f64, anchor: f64) -> f64 {
    (1.0 - circular_hue_distance(hue, anchor) / 90.0).clamp(0.0, 1.0)
}

fn circular_hue_distance(a: f64, b: f64) -> f64 {
    let distance = (a - b).abs().rem_euclid(360.0);
    distance.min(360.0 - distance)
}

fn nearest_hue_anchor(hue: f64, anchors: &[f64]) -> Option<f64> {
    anchors.iter().copied().min_by(|a, b| {
        circular_hue_distance(hue, *a)
            .partial_cmp(&circular_hue_distance(hue, *b))
            .unwrap_or(Ordering::Equal)
    })
}

fn move_hue_toward(hue: f64, target_hue: f64, strength: f64, max_shift: f64) -> f64 {
    let delta = shortest_hue_delta(hue, target_hue);
    let shifted = delta.signum() * (delta.abs() * strength).min(max_shift);
    (hue + shifted).rem_euclid(360.0)
}

fn shortest_hue_delta(from: f64, to: f64) -> f64 {
    let delta = (to - from).rem_euclid(360.0);
    if delta > 180.0 {
        delta - 360.0
    } else {
        delta
    }
}

fn hsl_to_rgb(hsl: HslColor) -> u32 {
    let hue = hsl.hue.rem_euclid(360.0) / 360.0;
    let saturation = hsl.saturation.clamp(0.0, 1.0);
    let lightness = hsl.lightness.clamp(0.0, 1.0);

    if saturation <= f64::EPSILON {
        let value = (lightness * 255.0).round() as u8;
        return pack_rgb(value, value, value);
    }

    let q = if lightness < 0.5 {
        lightness * (1.0 + saturation)
    } else {
        lightness + saturation - lightness * saturation
    };
    let p = 2.0 * lightness - q;

    let red = hue_to_rgb(p, q, hue + 1.0 / 3.0);
    let green = hue_to_rgb(p, q, hue);
    let blue = hue_to_rgb(p, q, hue - 1.0 / 3.0);

    pack_rgb(
        (red * 255.0).round() as u8,
        (green * 255.0).round() as u8,
        (blue * 255.0).round() as u8,
    )
}

fn hue_to_rgb(p: f64, q: f64, mut t: f64) -> f64 {
    if t < 0.0 {
        t += 1.0;
    }
    if t > 1.0 {
        t -= 1.0;
    }
    if t < 1.0 / 6.0 {
        return p + (q - p) * 6.0 * t;
    }
    if t < 1.0 / 2.0 {
        return q;
    }
    if t < 2.0 / 3.0 {
        return p + (q - p) * (2.0 / 3.0 - t) * 6.0;
    }
    p
}

#[derive(Debug, Clone, Copy)]
struct OklabColor {
    l: f64,
    a: f64,
    b: f64,
}

#[derive(Debug, Clone, Copy)]
struct OklchColor {
    l: f64,
    c: f64,
    h: f64,
}

fn srgb_to_linear(c: u8) -> f64 {
    let c = f64::from(c) / 255.0;
    if c >= 0.04045 {
        ((c + 0.055) / 1.055).powf(2.4)
    } else {
        c / 12.92
    }
}

fn rgb_to_oklab(r: u8, g: u8, b: u8) -> OklabColor {
    let r = srgb_to_linear(r);
    let g = srgb_to_linear(g);
    let b = srgb_to_linear(b);

    let l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b;
    let m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b;
    let s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b;

    let l_ = l.cbrt();
    let m_ = m.cbrt();
    let s_ = s.cbrt();

    let l_out = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_;
    let a_out = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_;
    let b_out = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_;

    OklabColor {
        l: l_out,
        a: a_out,
        b: b_out,
    }
}

fn oklab_to_oklch(oklab: OklabColor) -> OklchColor {
    let c = (oklab.a * oklab.a + oklab.b * oklab.b).sqrt();
    let mut h = oklab.b.atan2(oklab.a).to_degrees();
    if h < 0.0 {
        h += 360.0;
    }
    OklchColor { l: oklab.l, c, h }
}

fn oklab_distance(c1: &OklabColor, c2: &OklabColor) -> f64 {
    ((c1.l - c2.l).powi(2) + (c1.a - c2.a).powi(2) + (c1.b - c2.b).powi(2)).sqrt()
}

fn select_mesh_colors(
    palette_colors: &[PaletteColor],
    tuning: MeshScoringTuning,
) -> Option<MeshSelectionOutcome> {
    let n = palette_colors.len();
    if n < 4 {
        if n == 0 {
            return None;
        }
        let mut combo = [
            palette_colors[0].clone(),
            palette_colors[0].clone(),
            palette_colors[0].clone(),
            palette_colors[0].clone(),
        ];
        for i in 0..4 {
            combo[i] = palette_colors[i % n].clone();
        }
        let max_pop = combo
            .iter()
            .map(|color| color.population as f64)
            .fold(1.0, f64::max);
        let debug = build_mesh_selection_debug(&combo, max_pop, tuning, 0.0);
        return Some(MeshSelectionOutcome {
            colors: combo,
            debug,
        });
    }

    let mut best_score = f64::NEG_INFINITY;
    let mut best_combo = None;

    let max_pop = palette_colors[0].population as f64;

    for i in 0..n {
        for j in (i + 1)..n {
            for k in (j + 1)..n {
                for m in (k + 1)..n {
                    let combo = [
                        &palette_colors[i],
                        &palette_colors[j],
                        &palette_colors[k],
                        &palette_colors[m],
                    ];
                    let score = evaluate_mesh_combo(&combo, max_pop, tuning);
                    if score > best_score {
                        best_score = score;
                        best_combo = Some([
                            palette_colors[i].clone(),
                            palette_colors[j].clone(),
                            palette_colors[k].clone(),
                            palette_colors[m].clone(),
                        ]);
                    }
                }
            }
        }
    }

    if let Some(mut combo) = best_combo {
        combo.sort_by(|a, b| b.oklch.l.partial_cmp(&a.oklch.l).unwrap_or(Ordering::Equal));
        let debug = build_mesh_selection_debug(&combo, max_pop, tuning, best_score);
        Some(MeshSelectionOutcome {
            colors: combo,
            debug,
        })
    } else {
        None
    }
}

fn evaluate_mesh_combo(combo: &[&PaletteColor; 4], max_pop: f64, tuning: MeshScoringTuning) -> f64 {
    let pop_score = combo
        .iter()
        .map(|c| c.population as f64 / max_pop)
        .sum::<f64>();

    let mut min_dist = f64::INFINITY;
    for i in 0..4 {
        for j in (i + 1)..4 {
            let dist = oklab_distance(&combo[i].oklab, &combo[j].oklab);
            min_dist = min_dist.min(dist);
        }
    }

    let distinct_score = if min_dist < 0.04 {
        -20.0
    } else {
        (min_dist.min(0.15) - 0.04) * 10.0
    };

    let template_bonus = mesh_template_bonus(combo);

    let mut clash_penalty = 0.0;
    for i in 0..4 {
        for j in (i + 1)..4 {
            let h_dist = circular_hue_distance(combo[i].oklch.h, combo[j].oklch.h);
            let chroma_product = combo[i].oklch.c * combo[j].oklch.c;
            if h_dist > 45.0 && h_dist < 120.0 {
                clash_penalty += chroma_product
                    * 420.0
                    * tuning.harmony_strength
                    * tuning.muddy_penalty_multiplier;
            }
        }
    }

    let mut l_mean = 0.0;
    let mut c_mean = 0.0;
    for c in combo {
        l_mean += c.oklch.l;
        c_mean += c.oklch.c;
    }
    l_mean /= 4.0;
    c_mean /= 4.0;

    let mut l_var = 0.0;
    let mut c_var = 0.0;
    for c in combo {
        l_var += (c.oklch.l - l_mean).powi(2);
        c_var += (c.oklch.c - c_mean).powi(2);
    }

    let vibrancy_reward = c_mean * 5.0;
    let over_chroma_penalty = if c_mean > 0.15 {
        (c_mean - 0.15) * 15.0
    } else {
        0.0
    };
    let cohesion_penalty = l_var * 1.0 + c_var * 1.0;

    pop_score * 2.0 * tuning.population_strength
        + distinct_score * tuning.contrast_strength
        + vibrancy_reward * tuning.vibrancy_strength
        + template_bonus * tuning.harmony_strength
        - clash_penalty
        - cohesion_penalty * tuning.harmony_strength
        - over_chroma_penalty * tuning.vibrancy_strength
}

#[derive(Debug, Clone, Copy)]
struct MeshScoringTuning {
    population_strength: f64,
    contrast_strength: f64,
    harmony_strength: f64,
    vibrancy_strength: f64,
    muddy_penalty_multiplier: f64,
}

impl MeshScoringTuning {
    fn from_options(options: ThemePaletteOptions) -> Self {
        Self {
            population_strength: options.mesh_population_strength.clamp(0.0, 3.0),
            contrast_strength: options.mesh_contrast_strength.clamp(0.0, 3.0),
            harmony_strength: options.mesh_harmony_strength.clamp(0.0, 3.0),
            vibrancy_strength: options.mesh_vibrancy_strength.clamp(0.0, 3.0),
            muddy_penalty_multiplier: options.mesh_muddy_penalty_multiplier.clamp(0.0, 3.0),
        }
    }
}

#[derive(Debug, Clone)]
struct MeshSelectionOutcome {
    colors: [PaletteColor; 4],
    debug: MeshSelectionDebug,
}

fn build_mesh_selection_debug(
    combo: &[PaletteColor; 4],
    max_pop: f64,
    tuning: MeshScoringTuning,
    total: f64,
) -> MeshSelectionDebug {
    let refs = [&combo[0], &combo[1], &combo[2], &combo[3]];

    let population = refs
        .iter()
        .map(|c| c.population as f64 / max_pop.max(1.0))
        .sum::<f64>()
        * 2.0
        * tuning.population_strength;

    let mut min_dist = f64::INFINITY;
    for i in 0..4 {
        for j in (i + 1)..4 {
            min_dist = min_dist.min(oklab_distance(&refs[i].oklab, &refs[j].oklab));
        }
    }
    let distinct = if min_dist < 0.04 {
        -20.0
    } else {
        (min_dist.min(0.15) - 0.04) * 10.0 * tuning.contrast_strength
    };

    let harmony = mesh_template_bonus(&refs) * tuning.harmony_strength;
    let vibrancy_mean = refs.iter().map(|c| c.oklch.c).sum::<f64>() / 4.0;
    let vibrancy = vibrancy_mean * 5.0 * tuning.vibrancy_strength;

    let mut l_mean = 0.0;
    let mut c_mean = 0.0;
    for c in &refs {
        l_mean += c.oklch.l;
        c_mean += c.oklch.c;
    }
    l_mean /= 4.0;
    c_mean /= 4.0;

    let mut l_var = 0.0;
    let mut c_var = 0.0;
    for c in &refs {
        l_var += (c.oklch.l - l_mean).powi(2);
        c_var += (c.oklch.c - c_mean).powi(2);
    }
    let cohesion = -(l_var * 1.0 + c_var * 1.0) * tuning.harmony_strength;
    let over_chroma = if c_mean > 0.15 {
        -((c_mean - 0.15) * 15.0) * tuning.vibrancy_strength
    } else {
        0.0
    };

    let score = MeshScoreBreakdown {
        population,
        distinct,
        harmony,
        vibrancy,
        cohesion,
        over_chroma,
        total,
    };

    let cluster = best_hue_cluster(&refs, 45.0);
    let anchor_index = cluster.as_ref().and_then(|cluster| {
        refs.iter()
            .enumerate()
            .min_by(|(_, a), (_, b)| {
                circular_hue_distance(cluster.center_hue, a.oklch.h)
                    .partial_cmp(&circular_hue_distance(cluster.center_hue, b.oklch.h))
                    .unwrap_or(Ordering::Equal)
            })
            .map(|(index, _)| index)
    });
    let accent_index = cluster.as_ref().and_then(|cluster| {
        refs.iter()
            .enumerate()
            .max_by(|(_, a), (_, b)| {
                circular_hue_distance(cluster.center_hue, a.oklch.h)
                    .partial_cmp(&circular_hue_distance(cluster.center_hue, b.oklch.h))
                    .unwrap_or(Ordering::Equal)
            })
            .map(|(index, _)| index)
    });

    let mut colors = Vec::with_capacity(4);
    for (index, color) in combo.iter().enumerate() {
        let hue_distance = cluster
            .as_ref()
            .map(|cluster| circular_hue_distance(cluster.center_hue, color.oklch.h))
            .unwrap_or_default();
        let (role, primary_driver) = if Some(index) == accent_index && hue_distance >= 80.0 {
            ("accent".to_string(), "contrast".to_string())
        } else if Some(index) == anchor_index {
            ("anchor".to_string(), "population".to_string())
        } else if color.oklch.c >= vibrancy_mean {
            ("support".to_string(), "vibrancy".to_string())
        } else {
            ("support".to_string(), "harmony".to_string())
        };

        colors.push(MeshColorDebug {
            slot: format!("mesh{}", index + 1),
            color: color.argb(),
            role,
            primary_driver,
            hue: color.oklch.h,
            chroma: color.oklch.c,
            lightness: color.oklch.l,
            population: color.population,
        });
    }

    MeshSelectionDebug { score, colors }
}

#[derive(Debug, Clone, Copy)]
struct MeshHueCluster {
    center_hue: f64,
    count: usize,
    span: f64,
    average_chroma: f64,
    average_saturation: f64,
}

fn mesh_template_bonus(combo: &[&PaletteColor; 4]) -> f64 {
    let hues = combo.iter().map(|color| color.oklch.h).collect::<Vec<_>>();
    let span = minimal_circular_span(&hues);
    let Some(cluster) = best_hue_cluster(combo, 45.0) else {
        return if span > 155.0 {
            -((span - 155.0) * 0.18)
        } else {
            0.0
        };
    };

    let mut bonus = match cluster.count {
        4 => 5.0,
        3 => 4.0,
        2 => 1.25,
        _ => 0.0,
    };

    if cluster.span <= 48.0 {
        bonus += (48.0 - cluster.span) / 48.0 * 1.5;
    }

    if cluster.count == 3 {
        bonus += accent_bonus(combo, &cluster);
    }

    if span < 70.0 {
        bonus += (70.0 - span) / 70.0 * 0.8;
    } else if span > 155.0 {
        bonus -= (span - 155.0) * 0.25;
    }

    bonus
}

fn best_hue_cluster(combo: &[&PaletteColor; 4], radius: f64) -> Option<MeshHueCluster> {
    let mut best: Option<MeshHueCluster> = None;

    for pivot in combo {
        let members = combo
            .iter()
            .copied()
            .filter(|candidate| circular_hue_distance(pivot.oklch.h, candidate.oklch.h) <= radius)
            .collect::<Vec<_>>();

        let count = members.len();
        let hues = members
            .iter()
            .map(|color| color.oklch.h)
            .collect::<Vec<_>>();
        let span = minimal_circular_span(&hues);
        let average_chroma = members.iter().map(|color| color.oklch.c).sum::<f64>() / count as f64;
        let average_saturation = members
            .iter()
            .map(|color| color.hsl.saturation)
            .sum::<f64>()
            / count as f64;

        let candidate = MeshHueCluster {
            center_hue: pivot.oklch.h,
            count,
            span,
            average_chroma,
            average_saturation,
        };

        let replace = best
            .as_ref()
            .map(|current| {
                candidate.count > current.count
                    || (candidate.count == current.count && candidate.span < current.span)
            })
            .unwrap_or(true);

        if replace {
            best = Some(candidate);
        }
    }

    best
}

fn accent_bonus(combo: &[&PaletteColor; 4], cluster: &MeshHueCluster) -> f64 {
    let Some(accent) = combo.iter().copied().max_by(|a, b| {
        circular_hue_distance(cluster.center_hue, a.oklch.h)
            .partial_cmp(&circular_hue_distance(cluster.center_hue, b.oklch.h))
            .unwrap_or(Ordering::Equal)
    }) else {
        return 0.0;
    };

    let accent_distance = circular_hue_distance(cluster.center_hue, accent.oklch.h);
    if !(70.0..=155.0).contains(&accent_distance) {
        return -1.5;
    }

    let distance_reward = 1.8 - ((accent_distance - 112.0).abs() / 42.0) * 1.2;
    let chroma_excess = (accent.oklch.c - cluster.average_chroma * 1.05).max(0.0);
    let saturation_excess = (accent.hsl.saturation - cluster.average_saturation * 1.15).max(0.0);

    distance_reward - chroma_excess * 12.0 - saturation_excess * 2.0
}

fn minimal_circular_span(hues: &[f64]) -> f64 {
    match hues.len() {
        0 | 1 => 0.0,
        _ => {
            let mut sorted = hues.to_vec();
            sorted.sort_by(|a, b| a.partial_cmp(b).unwrap_or(Ordering::Equal));

            let mut max_gap: f64 = 0.0;
            for index in 0..sorted.len() - 1 {
                max_gap = max_gap.max(sorted[index + 1] - sorted[index]);
            }
            max_gap = max_gap.max(360.0 - sorted.last().copied().unwrap_or_default() + sorted[0]);
            360.0 - max_gap
        }
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

        let (palette, _) = quantize_palette_colors(&pixels, 4, PALETTE_MAX_COLORS);

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

        assert_eq!(theme_colors.len(), 6);
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

    #[test]
    fn hue_cohesion_biases_dark_vibrant_toward_secondary_theme_hue() {
        let palette_colors = vec![
            PaletteColor::new(pack_rgb(0xff, 0x20, 0x20), 100),
            PaletteColor::new(pack_rgb(0x00, 0x84, 0x84), 95),
            PaletteColor::new(pack_rgb(0x84, 0x3a, 0x00), 70),
        ];

        let loose = select_theme_colors(
            palette_colors.clone(),
            palette_colors.clone(),
            ThemePaletteOptions {
                hue_cohesion: 0.0,
                ..Default::default()
            },
        );
        let cohesive = select_theme_colors(
            palette_colors.clone(),
            palette_colors,
            ThemePaletteOptions {
                hue_cohesion: 1.0,
                ..Default::default()
            },
        );

        assert_eq!(loose.0.get("darkVibrant").map(|c| c.rgb), Some(0x008484));
        assert_eq!(cohesive.0.get("darkVibrant").map(|c| c.rgb), Some(0x008484));
    }

    #[test]
    fn hue_anchors_prefer_far_high_population_color() {
        let dominant = PaletteColor::new(pack_rgb(0xff, 0x20, 0x20), 100);
        let palette_colors = vec![
            dominant.clone(),
            PaletteColor::new(pack_rgb(0xff, 0xa0, 0x20), 90),
            PaletteColor::new(pack_rgb(0x00, 0x84, 0x84), 80),
        ];

        let anchors = build_hue_anchors(&palette_colors, &dominant, 1.0);

        assert_eq!(anchors.len(), 2);
        assert!(circular_hue_distance(anchors[0], anchors[1]) >= 72.0);
        assert!(circular_hue_distance(anchors[1], 180.0) < 30.0);
    }

    #[test]
    fn hue_cohesion_harmonizes_selected_swatches() {
        let mut theme_colors = BTreeMap::new();
        theme_colors.insert(
            "dominant".to_string(),
            PaletteColor::new(pack_rgb(0xff, 0x20, 0x20), 100),
        );
        theme_colors.insert(
            "lightVibrant".to_string(),
            PaletteColor::new(pack_rgb(0x20, 0xb4, 0xff), 60),
        );

        harmonize_theme_colors(&mut theme_colors, &[0.0], 1.0);

        let harmonized = theme_colors.get("lightVibrant").expect("light vibrant");
        assert!(circular_hue_distance(harmonized.hsl.hue, 0.0) < 120.0);
        assert!(harmonized.hsl.saturation > 0.5);
    }

    #[test]
    fn mesh_scoring_prefers_cohesive_warm_clusters_over_strong_rgb_contrast() {
        let cohesive_combo = [
            PaletteColor::new(pack_rgb(0xf2, 0x87, 0x41), 100),
            PaletteColor::new(pack_rgb(0xe8, 0x5d, 0x3d), 100),
            PaletteColor::new(pack_rgb(0xd9, 0x4f, 0x70), 100),
            PaletteColor::new(pack_rgb(0xf0, 0xa5, 0x6c), 100),
        ];
        let clash_combo = [
            PaletteColor::new(pack_rgb(0xff, 0x20, 0x20), 100),
            PaletteColor::new(pack_rgb(0x20, 0xff, 0x20), 100),
            PaletteColor::new(pack_rgb(0x20, 0x20, 0xff), 100),
            PaletteColor::new(pack_rgb(0xff, 0xe0, 0x20), 100),
        ];

        let cohesive_refs = [
            &cohesive_combo[0],
            &cohesive_combo[1],
            &cohesive_combo[2],
            &cohesive_combo[3],
        ];
        let clash_refs = [
            &clash_combo[0],
            &clash_combo[1],
            &clash_combo[2],
            &clash_combo[3],
        ];

        let tuning = MeshScoringTuning {
            population_strength: 1.0,
            contrast_strength: 1.0,
            harmony_strength: 1.0,
            vibrancy_strength: 1.0,
            muddy_penalty_multiplier: 1.0,
        };
        let cohesive_score = evaluate_mesh_combo(&cohesive_refs, 100.0, tuning);
        let clash_score = evaluate_mesh_combo(&clash_refs, 100.0, tuning);

        assert!(cohesive_score > clash_score);
    }

    #[test]
    fn muddy_penalty_multiplier_reduces_clashing_mesh_scores() {
        let clash_combo = [
            PaletteColor::new(pack_rgb(0xff, 0x20, 0x20), 100),
            PaletteColor::new(pack_rgb(0x20, 0xff, 0x20), 100),
            PaletteColor::new(pack_rgb(0x20, 0x20, 0xff), 100),
            PaletteColor::new(pack_rgb(0xff, 0xe0, 0x20), 100),
        ];
        let clash_refs = [
            &clash_combo[0],
            &clash_combo[1],
            &clash_combo[2],
            &clash_combo[3],
        ];

        let loose_tuning = MeshScoringTuning {
            population_strength: 1.0,
            contrast_strength: 1.0,
            harmony_strength: 1.0,
            vibrancy_strength: 1.0,
            muddy_penalty_multiplier: 0.0,
        };
        let strict_tuning = MeshScoringTuning {
            muddy_penalty_multiplier: 2.0,
            ..loose_tuning
        };

        let loose_score = evaluate_mesh_combo(&clash_refs, 100.0, loose_tuning);
        let strict_score = evaluate_mesh_combo(&clash_refs, 100.0, strict_tuning);

        assert!(strict_score < loose_score);
    }
}
