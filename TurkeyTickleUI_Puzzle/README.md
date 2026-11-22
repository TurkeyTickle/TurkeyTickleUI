# Turkey Tickle UI: Puzzle

Multiplayer jigsaw puzzles for **World of Warcraft: Forever** (interface `16001`). One player hosts a
picture and everyone in the guild (or party / raid) with the addon puts it together in real time.

## Features

- Host any web image: a small tool turns it into a code you paste in game
- The picture streams to players over addon messages: a blurry preview shows up within a second or
  two and sharpens as the rest arrives (a 192 x 128 photo takes about 20 seconds, the 320 x 320
  maximum up to 2 minutes for a very detailed photo)
- A minimap button tells you when someone starts a puzzle: it pulses blue with a percentage while
  the picture loads in the background, then glows gold (with a chat message, a sound and an optional
  popup) when it's ready. Click it to open the puzzle; right-click to host one; drag to move it
- Real jigsaw-shaped pieces with knobs and holes, cut the same way for everyone
- Everyone sees pieces move as they're dragged, with the holder's name over the piece
- Pieces snap into place near their spot; placed pieces lock
- Drop a piece next to a matching neighbor anywhere on the board and they snap together; move the
  group as one and drop it into place
- Resize the window from its corner; scroll to zoom, right-drag to pan
- Players who log in or join late catch up on the picture and every piece's position
- A faint copy of the picture under the board as a guide (off unless the host turns it on)
- A results banner when the puzzle is done, with who placed the most pieces

## Hosting a puzzle

1. Turn an image into a code with the `ttpz` tool (JPEG, PNG, WebP, GIF, BMP; a web URL or
   a file):

   ```
   ttpz https://example.com/picture.jpg
   ```

   The code is copied to your clipboard automatically. If the clipboard is unavailable, `ttpz`
   prints the code. Useful options: `--size` (longest side, up to 320 pixels;
   default 192; use 128 for a picture that arrives in about 10 seconds), `--colors` (up to 64), `--dither` (smoother photos), `--preview out.png` (see what
   players will get), `--out code.txt` (write the code to a file). See [Building the image tool](#building-the-image-tool).
2. In game, type `/ttpz host`, paste the code, name the puzzle, pick the number of pieces and whether
   to play with your guild or your party / raid, and click **Start puzzle**.

No image handy? Click **Use sample picture** in the host window.

## Commands

| Command            | Action |
| ------------------ | ------ |
| `/ttpz`            | Open the puzzle (or join the latest one, or host if there isn't one) |
| `/ttpz host`       | Host a new puzzle |
| `/ttpz join [name]`| Join the latest puzzle, or the one hosted by `name` |
| `/ttpz leave`      | Stop playing (you can rejoin later) |
| `/ttpz end`        | End your puzzle for everyone (host only) |
| `/ttpz status`     | List puzzles and their progress |
| `/ttpz options`    | Open the options |

Options live under **Options > AddOns > Turkey Tickle UI > Puzzle**.

## Building the image tool

`tools/ttpz` is a Rust program that builds to a single self-contained executable:

```
cargo build --release --manifest-path tools/ttpz/Cargo.toml
```

On Windows or a Mac, the same command builds a native `ttpz.exe` / `ttpz`. To build the Windows
`.exe` from Linux, run `tools/ttpz/build-windows.sh` (its header lists what it needs); it writes
`tools/bin/ttpz.exe`.

## Limits

WoW addons can't download anything, so the picture travels through addon messages, which the
client throttles. That's why images are small (up to 320 x 320) with at most 64 colors.

WoW also can't make textures at runtime, so the picture is drawn from thousands of colored strips,
and the client stops drawing its entire interface somewhere under 20,000 textures. The board keeps
itself to 8,000 by drawing big or detailed pictures with less detail, so beyond the default 192 pixels
a bigger picture mostly just takes longer to send. Only the host
sends the picture, so if the host logs off, people already playing can finish but nobody new can
join.
