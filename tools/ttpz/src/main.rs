mod clipboard;
mod image_code;
mod loader;
mod quantizer;

use std::io::IsTerminal;
use std::path::PathBuf;
use std::process::ExitCode;

use image_code::{MAX_COLORS, MAX_SIDE, MIN_SIDE};

const USAGE: &str = "\
Turns an image (web URL or file) into a code for TurkeyTickleUI_Puzzle.
Copies the code to your clipboard for the addon's host window (/ttpz host).

usage: ttpz <url-or-file> [options]

  --size N         longest side in pixels (8-320, default 192)
  --colors N       palette size (2-64, default 64)
  --dither         dither colors (smoother photos, slightly bigger code)
  --preview FILE   save an enlarged PNG of what players will see
  --out FILE       write the code to a file instead of the clipboard";

struct Options {
    source: String,
    size: u32,
    colors: usize,
    dither: bool,
    preview: Option<PathBuf>,
    out: Option<PathBuf>,
}

fn main() -> ExitCode {
    let options = match parse(std::env::args().skip(1).collect()) {
        Ok(Some(options)) => options,
        Ok(None) => {
            println!("{USAGE}");
            return ExitCode::SUCCESS;
        }
        Err(message) => return fail(&message),
    };
    match run(options) {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => fail(&message),
    }
}

/// None means help was asked for.
fn parse(args: Vec<String>) -> Result<Option<Options>, String> {
    let mut source = None;
    let (mut size, mut colors, mut dither) = (192u32, 64usize, false);
    let (mut preview, mut out) = (None, None);
    let mut args = args.into_iter();
    while let Some(arg) = args.next() {
        let mut value = || args.next().ok_or_else(|| format!("{arg} needs a value"));
        match arg.as_str() {
            "-h" | "--help" => return Ok(None),
            "--size" => size = number(&value()?)?,
            "--colors" => colors = number(&value()?)?,
            "--dither" => dither = true,
            "--preview" => preview = Some(PathBuf::from(value()?)),
            "--out" => out = Some(PathBuf::from(value()?)),
            _ if source.is_none() && !arg.starts_with("--") => source = Some(arg),
            _ => return Err(format!("unexpected argument {arg}")),
        }
    }

    let source = source.ok_or("give an image URL or file")?;
    if !(MIN_SIDE..=MAX_SIDE).contains(&size) {
        return Err(format!("--size must be {MIN_SIDE}-{MAX_SIDE}"));
    }
    if !(2..=MAX_COLORS).contains(&colors) {
        return Err(format!("--colors must be 2-{MAX_COLORS}"));
    }
    Ok(Some(Options { source, size, colors, dither, preview, out }))
}

fn number<T: std::str::FromStr>(text: &str) -> Result<T, String> {
    text.parse().map_err(|_| format!("{text} isn't a number"))
}

fn run(options: Options) -> Result<(), String> {
    let source = &options.source;
    let bytes = loader::read(source).map_err(|e| format!("couldn't load {source}: {e}"))?;
    let image = loader::decode_scaled(&bytes, options.size, MIN_SIDE, MAX_SIDE)
        .ok_or_else(|| format!("{source} isn't an image format I can read"))?;

    let (palette, indices) = quantizer::reduce(&image, options.colors, options.dither);
    let code = image_code::encode(image.width, image.height, &palette, &indices);
    eprintln!(
        "{}x{} pixels, {} colors, {} characters, about {:.0}s to send.",
        image.width,
        image.height,
        palette.len(),
        thousands(code.len()),
        image_code::send_seconds(code.len())
    );

    if let Some(path) = &options.preview {
        loader::save_preview(path, image.width, image.height, &palette, &indices, 4)
            .map_err(|e| format!("couldn't save the preview: {e}"))?;
        eprintln!("Preview saved to {}", path.display());
    }

    if let Some(path) = &options.out {
        std::fs::write(path, &code).map_err(|e| format!("couldn't write {}: {e}", path.display()))?;
        eprintln!("Code written to {}", path.display());
    } else {
        let copied = clipboard::try_copy(&code);
        eprintln!(
            "{}",
            if copied {
                "Code copied to the clipboard. In game: /ttpz host, then paste it."
            } else {
                "Clipboard unavailable. The code was printed below."
            }
        );
        if !copied || !std::io::stdout().is_terminal() {
            println!("{code}");
        }
    }
    Ok(())
}

fn thousands(n: usize) -> String {
    let digits = n.to_string();
    let mut out = String::new();
    for (i, c) in digits.chars().enumerate() {
        if i > 0 && (digits.len() - i).is_multiple_of(3) {
            out.push(',');
        }
        out.push(c);
    }
    out
}

fn fail(message: &str) -> ExitCode {
    eprintln!("ttpz: {message}");
    eprintln!("Run ttpz --help for usage.");
    ExitCode::from(2)
}
