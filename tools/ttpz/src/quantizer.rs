//! Reduces an image to a small palette: median cut, refined with a few k-means passes.

use std::collections::HashMap;
use std::collections::hash_map::Entry;

use crate::loader::RgbImage;

const REFINE_PASSES: usize = 5;

#[derive(Clone, Copy)]
struct Weighted {
    rgb: u32,
    count: u32,
}

/// Returns the palette (0xRRGGBB, only colors that are used) and each pixel's palette index.
pub fn reduce(image: &RgbImage, max_colors: usize, mut dither: bool) -> (Vec<u32>, Vec<u8>) {
    // In order of first appearance, so the result doesn't depend on hashing.
    let mut slots: HashMap<u32, usize> = HashMap::new();
    let mut colors: Vec<Weighted> = Vec::new();
    for &rgb in &image.pixels {
        match slots.entry(rgb) {
            Entry::Occupied(slot) => colors[*slot.get()].count += 1,
            Entry::Vacant(slot) => {
                slot.insert(colors.len());
                colors.push(Weighted { rgb, count: 1 });
            }
        }
    }

    let palette = if colors.len() <= max_colors {
        dither = false;
        colors.iter().map(|c| c.rgb).collect()
    } else {
        let mut palette = median_cut(&colors, max_colors);
        for _ in 0..REFINE_PASSES {
            palette = refine(&colors, &palette);
        }
        palette
    };

    let indices = if dither { map_dithered(image, &palette) } else { map_nearest(&image.pixels, &palette) };
    compact(&palette, indices)
}

fn channel(rgb: u32, channel: usize) -> i32 {
    ((rgb >> (16 - 8 * channel)) & 255) as i32
}

fn distance(r1: i32, g1: i32, b1: i32, r2: i32, g2: i32, b2: i32) -> i32 {
    let (dr, dg, db) = (r1 - r2, g1 - g2, b1 - b2);
    2 * dr * dr + 4 * dg * dg + 3 * db * db
}

fn nearest(palette: &[u32], r: i32, g: i32, b: i32) -> usize {
    let mut best = 0;
    let mut best_distance = i32::MAX;
    for (i, &p) in palette.iter().enumerate() {
        let d = distance(r, g, b, channel(p, 0), channel(p, 1), channel(p, 2));
        if d < best_distance {
            best = i;
            best_distance = d;
        }
    }
    best
}

fn median_cut(colors: &[Weighted], max_colors: usize) -> Vec<u32> {
    let mut boxes: Vec<Vec<Weighted>> = vec![colors.to_vec()];
    while boxes.len() < max_colors {
        let mut best_box = None;
        let mut best_channel = 0;
        let mut best_score: i64 = 0;
        for (i, b) in boxes.iter().enumerate() {
            if b.len() < 2 {
                continue;
            }
            let total: i64 = b.iter().map(|c| c.count as i64).sum();
            for ch in 0..3 {
                let max = b.iter().map(|c| channel(c.rgb, ch)).max().unwrap_or(0);
                let min = b.iter().map(|c| channel(c.rgb, ch)).min().unwrap_or(0);
                let score = (max - min) as i64 * total;
                if score > best_score {
                    (best_box, best_channel, best_score) = (Some(i), ch, score);
                }
            }
        }
        let Some(best_box) = best_box else {
            break;
        };

        let mut b = std::mem::take(&mut boxes[best_box]);
        b.sort_by_key(|c| channel(c.rgb, best_channel));
        let half = b.iter().map(|c| c.count as i64).sum::<i64>() / 2;
        let mut running = 0;
        let mut split = 1;
        while split < b.len() - 1 {
            running += b[split - 1].count as i64;
            if running >= half {
                break;
            }
            split += 1;
        }
        let rest = b.split_off(split);
        boxes[best_box] = b;
        boxes.push(rest);
    }
    boxes.iter().map(|b| mean(b)).collect()
}

fn mean(colors: &[Weighted]) -> u32 {
    let (mut r, mut g, mut b, mut n) = (0i64, 0i64, 0i64, 0i64);
    for c in colors {
        let count = c.count as i64;
        r += channel(c.rgb, 0) as i64 * count;
        g += channel(c.rgb, 1) as i64 * count;
        b += channel(c.rgb, 2) as i64 * count;
        n += count;
    }
    (((r / n) << 16) | ((g / n) << 8) | (b / n)) as u32
}

fn refine(colors: &[Weighted], palette: &[u32]) -> Vec<u32> {
    let mut groups: Vec<Vec<Weighted>> = vec![Vec::new(); palette.len()];
    for &c in colors {
        groups[nearest(palette, channel(c.rgb, 0), channel(c.rgb, 1), channel(c.rgb, 2))].push(c);
    }
    palette
        .iter()
        .zip(&groups)
        .map(|(&rgb, group)| if group.is_empty() { rgb } else { mean(group) })
        .collect()
}

fn map_nearest(pixels: &[u32], palette: &[u32]) -> Vec<u8> {
    let mut cache: HashMap<u32, u8> = HashMap::new();
    pixels
        .iter()
        .map(|&rgb| {
            *cache
                .entry(rgb)
                .or_insert_with(|| nearest(palette, channel(rgb, 0), channel(rgb, 1), channel(rgb, 2)) as u8)
        })
        .collect()
}

// Floyd-Steinberg error diffusion.
fn map_dithered(image: &RgbImage, palette: &[u32]) -> Vec<u8> {
    let (width, height) = (image.width, image.height);
    let row = (width + 2) * 3;
    let mut error = vec![0f32; row * 2];
    let mut indices = vec![0u8; width * height];
    for y in 0..height {
        let current = (y % 2) * row;
        let next = ((y + 1) % 2) * row;
        error[next..next + row].fill(0.0);
        for x in 0..width {
            let rgb = image.pixels[y * width + x];
            let at = current + (x + 1) * 3;
            let level = |c: usize| (((channel(rgb, c) as f32 + error[at + c]) as f64).round_ties_even() as i32).clamp(0, 255);
            let (r, g, b) = (level(0), level(1), level(2));
            let index = nearest(palette, r, g, b);
            indices[y * width + x] = index as u8;

            let p = palette[index];
            let diff = [(r - channel(p, 0)) as f32, (g - channel(p, 1)) as f32, (b - channel(p, 2)) as f32];
            for c in 0..3 {
                error[at + 3 + c] += diff[c] * 7.0 / 16.0;
                error[next + x * 3 + c] += diff[c] * 3.0 / 16.0;
                error[next + (x + 1) * 3 + c] += diff[c] * 5.0 / 16.0;
                error[next + (x + 2) * 3 + c] += diff[c] / 16.0;
            }
        }
    }
    indices
}

fn compact(palette: &[u32], mut indices: Vec<u8>) -> (Vec<u32>, Vec<u8>) {
    let mut remap = vec![None; palette.len()];
    let mut used = Vec::new();
    for index in &mut indices {
        let slot = &mut remap[*index as usize];
        let new = *slot.get_or_insert_with(|| {
            used.push(palette[*index as usize]);
            (used.len() - 1) as u8
        });
        *index = new;
    }
    (used, indices)
}
