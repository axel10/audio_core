pub use std::collections::BTreeMap;

use fast_image_resize::images::Image as FirImage;
use fast_image_resize::{PixelType, Resizer};
use libblur::{fast_gaussian, AnisotropicRadius, BlurImageMut, EdgeMode, FastBlurChannels, ThreadingPolicy};
pub use palette_core::ThemePaletteOptions;
use palette_core::{
    build_theme_palette_bundle_from_pixels_with_options as build_theme_palette_bundle_from_pixels_with_options_core,
    debug_build_theme_colors_from_pixels as debug_build_theme_colors_from_pixels_core,
    debug_build_theme_colors_from_pixels_with_options as debug_build_theme_colors_from_pixels_with_options_core,
};
use zune_core::colorspace::ColorSpace;
use zune_image::image::Image;

const PALETTE_PREVIEW_SIZE: u32 = 200;
const PALETTE_BLUR_RADIUS: u32 = 5;

#[allow(dead_code)]
pub(crate) fn build_theme_colors_blob(image: &Image) -> anyhow::Result<Option<Vec<u8>>> {
    build_theme_colors_blob_with_options(image, ThemePaletteOptions::default())
}

#[allow(dead_code)]
pub(crate) fn build_theme_colors_blob_with_options(
    image: &Image,
    options: ThemePaletteOptions,
) -> anyhow::Result<Option<Vec<u8>>> {
    let Some(bundle) = build_theme_palette_bundle_with_options(image, options)? else {
        return Ok(None);
    };

    Ok(Some(serde_json::to_vec(&bundle.theme_colors)?))
}

pub(crate) fn build_theme_palette_bundle_with_options(
    image: &Image,
    options: ThemePaletteOptions,
) -> anyhow::Result<Option<palette_core::ThemePaletteBundle>> {
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

    let (width, height) = palette_image.dimensions();
    let flattened_frames = palette_image.flatten_to_u8();
    let Some(pixels) = flattened_frames.first() else {
        return Ok(None);
    };
    let palette_pixels = preprocess_palette_pixels(
        pixels,
        width,
        height,
        target_colorspace.num_components(),
    )?;

    Ok(build_theme_palette_bundle_from_pixels_with_options_core(
        &palette_pixels,
        4,
        options,
    ))
}

fn preprocess_palette_pixels(
    pixels: &[u8],
    width: usize,
    height: usize,
    channels_per_pixel: usize,
) -> anyhow::Result<Vec<u8>> {
    let width = u32::try_from(width)
        .map_err(|_| anyhow::anyhow!("palette image width does not fit into u32"))?;
    let height = u32::try_from(height)
        .map_err(|_| anyhow::anyhow!("palette image height does not fit into u32"))?;
    let rgba_pixels = match channels_per_pixel {
        4 => pixels.to_vec(),
        3 => {
            let mut rgba_pixels = Vec::with_capacity((pixels.len() / 3) * 4);
            for pixel in pixels.chunks_exact(3) {
                rgba_pixels.extend_from_slice(pixel);
                rgba_pixels.push(u8::MAX);
            }
            rgba_pixels
        }
        other => {
            return Err(anyhow::anyhow!(
                "unsupported artwork colorspace for palette preprocessing: {other} channels"
            ));
        }
    };

    let src_image = FirImage::from_vec_u8(width, height, rgba_pixels, PixelType::U8x4)
        .map_err(|err| anyhow::anyhow!("failed to build palette resize source image: {err}"))?;
    let mut dst_image = FirImage::new(
        PALETTE_PREVIEW_SIZE,
        PALETTE_PREVIEW_SIZE,
        PixelType::U8x4,
    );
    Resizer::new()
        .resize(&src_image, &mut dst_image, None)
        .map_err(|err| anyhow::anyhow!("failed to resize palette image: {err}"))?;

    let mut blurred_pixels = dst_image.into_vec();
    let mut blur_image = BlurImageMut::borrow(
        blurred_pixels.as_mut_slice(),
        PALETTE_PREVIEW_SIZE,
        PALETTE_PREVIEW_SIZE,
        FastBlurChannels::Channels4,
    );
    fast_gaussian(
        &mut blur_image,
        AnisotropicRadius::new(PALETTE_BLUR_RADIUS),
        ThreadingPolicy::Single,
        EdgeMode::Clamp.as_2d(),
    )
    .map_err(|err| anyhow::anyhow!("failed to blur palette image: {err}"))?;

    Ok(blurred_pixels)
}

pub fn debug_build_theme_colors_from_pixels(
    pixels: &[u8],
    channels_per_pixel: usize,
) -> Option<std::collections::BTreeMap<String, u32>> {
    debug_build_theme_colors_from_pixels_core(pixels, channels_per_pixel)
}

pub fn debug_build_theme_colors_from_pixels_with_options(
    pixels: &[u8],
    channels_per_pixel: usize,
    options: ThemePaletteOptions,
) -> Option<std::collections::BTreeMap<String, u32>> {
    debug_build_theme_colors_from_pixels_with_options_core(pixels, channels_per_pixel, options)
}

#[cfg(test)]
mod tests {
    use super::preprocess_palette_pixels;

    #[test]
    fn preprocess_palette_pixels_resizes_and_blurs_to_rgba_preview() {
        let pixels = vec![
            255, 0, 0, 0, 255, 0,
            0, 0, 255, 255, 255, 255,
        ];

        let processed = preprocess_palette_pixels(&pixels, 2, 2, 3).expect("preprocess");

        assert_eq!(processed.len(), 200 * 200 * 4);
        assert!(processed.chunks_exact(4).all(|pixel| pixel[3] == 255));
    }
}
