//! The image code TurkeyTickleUI_Puzzle reads; see the format notes in its Codec.lua.

pub const MIN_SIDE: u32 = 8;
pub const MAX_SIDE: u32 = 320;
pub const MAX_COLORS: usize = 64;

const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
const TAG: &str = "TTPZ1:";
const RUN: char = '~';
const MIN_RUN: usize = 3;
const MAX_RUN: usize = MIN_RUN + 63;
const LEVEL_STEPS: [usize; 3] = [4, 2, 1];

// Must match the pacing in the addon's Comm.lua.
const PAYLOAD: usize = 240;
const OVERHEAD: usize = 40;
const BURST_BYTES: usize = 2000;
const BYTES_PER_SECOND: f64 = 800.0;
const PREFIXES: usize = 4;
const PREFIX_BURST: usize = 10;

/// `palette` is 24-bit RGB colors; `pixels` is row-major palette indices.
pub fn encode(width: usize, height: usize, palette: &[u32], pixels: &[u8]) -> String {
    let mut code = String::from(TAG);
    append_number(&mut code, width as u32, 2);
    append_number(&mut code, height as u32, 2);
    append_number(&mut code, palette.len() as u32 - 1, 1);
    for &rgb in palette {
        append_number(&mut code, rgb, 4);
    }

    let order = pixel_order(width, height);
    let mut i = 0;
    while i < order.len() {
        let color = pixels[order[i]];
        let mut run = 1;
        while i + run < order.len() && run < MAX_RUN && pixels[order[i + run]] == color {
            run += 1;
        }
        if run >= MIN_RUN {
            code.push(RUN);
            code.push(digit(run - MIN_RUN));
            code.push(digit(color as usize));
        } else {
            run = 1;
            code.push(digit(color as usize));
        }
        i += run;
    }
    code
}

pub fn send_seconds(chars: usize) -> f64 {
    let messages = chars.div_ceil(PAYLOAD);
    let by_bytes = (chars + messages * OVERHEAD).saturating_sub(BURST_BYTES) as f64 / BYTES_PER_SECOND;
    let by_prefix = messages.saturating_sub(PREFIX_BURST * PREFIXES) as f64 / PREFIXES as f64;
    by_bytes.max(by_prefix)
}

fn digit(value: usize) -> char {
    ALPHABET[value] as char
}

// Coarse to fine: every 4th pixel, then every 2nd, then the rest.
fn pixel_order(width: usize, height: usize) -> Vec<usize> {
    let mut order = Vec::with_capacity(width * height);
    let mut coarser: Option<usize> = None;
    for step in LEVEL_STEPS {
        for y in (0..height).step_by(step) {
            for x in (0..width).step_by(step) {
                if coarser.is_none_or(|c| x % c != 0 || y % c != 0) {
                    order.push(y * width + x);
                }
            }
        }
        coarser = Some(step);
    }
    order
}

fn append_number(code: &mut String, value: u32, digits: u32) {
    for shift in (0..digits).rev() {
        code.push(digit(((value >> (6 * shift)) & 63) as usize));
    }
}
