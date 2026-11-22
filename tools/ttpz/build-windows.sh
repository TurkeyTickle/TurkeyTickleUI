#!/bin/sh
# Cross-compiles ttpz.exe for Windows from Linux, linking with lld-link against the MSVC
# runtime and Windows SDK libraries that xwin downloads (accepting Microsoft's license).
#
# Needs: rustup with the x86_64-pc-windows-msvc target, lld-link, and xwin:
#   rustup target add x86_64-pc-windows-msvc
#   cargo install --locked xwin && xwin --accept-license --arch x86_64 splat --output ~/.xwin
set -e
cd "$(dirname "$0")"
# A distro's own Rust usually lacks the Windows target; prefer rustup's.
command -v rustup >/dev/null || PATH="$HOME/.cargo/bin:$PATH"
xwin="${XWIN:-$HOME/.xwin}"
export CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_LINKER=lld-link
export LIB="$xwin/crt/lib/x86_64;$xwin/sdk/lib/um/x86_64;$xwin/sdk/lib/ucrt/x86_64"
cargo build --release --target x86_64-pc-windows-msvc
target="${CARGO_TARGET_DIR:-target}"
mkdir -p ../bin
cp "$target/x86_64-pc-windows-msvc/release/ttpz.exe" ../bin/ttpz.exe
echo "Built tools/bin/ttpz.exe"
