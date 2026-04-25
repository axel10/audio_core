use std::collections::BTreeMap;

pub use palette_core::ThemePaletteOptions;
use palette_core::{
    build_theme_colors_from_pixels_with_options as build_theme_colors_from_pixels_with_options_core,
    debug_build_theme_colors_from_pixels as debug_build_theme_colors_from_pixels_core,
    debug_build_theme_colors_from_pixels_with_options as debug_build_theme_colors_from_pixels_with_options_core,
};
use zune_core::colorspace::ColorSpace;
use zune_image::image::Image;

pub(crate) fn build_theme_colors_blob(image: &Image) -> anyhow::Result<Option<Vec<u8>>> {
    build_theme_colors_blob_with_options(image, ThemePaletteOptions::default())
}

pub(crate) fn build_theme_colors_blob_with_options(
    image: &Image,
    options: ThemePaletteOptions,
) -> anyhow::Result<Option<Vec<u8>>> {
    let Some(theme_colors) = build_theme_colors_from_image_with_options(image, options)? else {
        return Ok(None);
    };

    Ok(Some(serde_json::to_vec(&theme_colors)?))
}

fn build_theme_colors_from_image_with_options(
    image: &Image,
    options: ThemePaletteOptions,
) -> anyhow::Result<Option<BTreeMap<String, u32>>> {
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

    Ok(build_theme_colors_from_pixels_with_options_core(
        pixels,
        target_colorspace.num_components(),
        options,
    ))
}

pub fn debug_build_theme_colors_from_pixels(
    pixels: &[u8],
    channels_per_pixel: usize,
) -> Option<BTreeMap<String, u32>> {
    debug_build_theme_colors_from_pixels_core(pixels, channels_per_pixel)
}

pub fn debug_build_theme_colors_from_pixels_with_options(
    pixels: &[u8],
    channels_per_pixel: usize,
    options: ThemePaletteOptions,
) -> Option<BTreeMap<String, u32>> {
    debug_build_theme_colors_from_pixels_with_options_core(pixels, channels_per_pixel, options)
}
