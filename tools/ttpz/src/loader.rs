use std::io::Cursor;
use std::path::Path;
use std::time::Duration;

use image::imageops::{self, FilterType};
use image::{DynamicImage, ImageDecoder, ImageReader, Rgb, RgbImage as RgbBuffer};

const MAX_DOWNLOAD: u64 = 64 * 1024 * 1024;

/// An image as row-major 0xRRGGBB pixels.
pub struct RgbImage {
    pub width: usize,
    pub height: usize,
    pub pixels: Vec<u32>,
}

pub fn read(source: &str) -> Result<Vec<u8>, String> {
    let lower = source.to_ascii_lowercase();
    if !lower.starts_with("http://") && !lower.starts_with("https://") {
        return std::fs::read(source).map_err(|e| e.to_string());
    }

    let config = ureq::Agent::config_builder()
        .timeout_global(Some(Duration::from_secs(30)))
        .user_agent("Mozilla/5.0 TurkeyTickleUI-puzzle");
    #[cfg(windows)]
    let config = config.tls_config(
        ureq::tls::TlsConfig::builder().provider(ureq::tls::TlsProvider::NativeTls).build(),
    );
    let agent: ureq::Agent = config.build().into();
    let mut response = agent.get(source).call().map_err(|e| e.to_string())?;
    response.body_mut().with_config().limit(MAX_DOWNLOAD).read_to_vec().map_err(|e| e.to_string())
}

/// Decodes, applies the EXIF orientation, flattens transparency onto black and scales the
/// longest side to `longest_side`. None if the bytes aren't an image format we read.
pub fn decode_scaled(bytes: &[u8], longest_side: u32, min_side: u32, max_side: u32) -> Option<RgbImage> {
    let mut decoder = ImageReader::new(Cursor::new(bytes)).with_guessed_format().ok()?.into_decoder().ok()?;
    let orientation = decoder.orientation().ok();
    let mut decoded = DynamicImage::from_decoder(decoder).ok()?;
    if let Some(orientation) = orientation {
        decoded.apply_orientation(orientation);
    }

    let rgba = decoded.to_rgba8();
    let flat = RgbBuffer::from_fn(rgba.width(), rgba.height(), |x, y| {
        let [r, g, b, a] = rgba.get_pixel(x, y).0;
        let over_black = |c: u8| ((c as u32 * a as u32 + 127) / 255) as u8;
        Rgb([over_black(r), over_black(g), over_black(b)])
    });

    let scale = longest_side as f64 / flat.width().max(flat.height()) as f64;
    let side = |n: u32| ((n as f64 * scale).round_ties_even() as u32).clamp(min_side, max_side);
    let (width, height) = (side(flat.width()), side(flat.height()));
    let scaled = imageops::resize(&flat, width, height, FilterType::Triangle);
    let pixels = scaled.pixels().map(|p| (p[0] as u32) << 16 | (p[1] as u32) << 8 | p[2] as u32).collect();
    Some(RgbImage { width: width as usize, height: height as usize, pixels })
}

pub fn save_preview(
    path: &Path,
    width: usize,
    height: usize,
    palette: &[u32],
    indices: &[u8],
    zoom: usize,
) -> Result<(), String> {
    let large = RgbBuffer::from_fn((width * zoom) as u32, (height * zoom) as u32, |x, y| {
        let rgb = palette[indices[(y as usize / zoom) * width + x as usize / zoom] as usize];
        Rgb([(rgb >> 16) as u8, (rgb >> 8) as u8, rgb as u8])
    });
    large.save(path).map_err(|e| e.to_string())
}
