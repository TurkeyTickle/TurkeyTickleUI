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
- Optional turned pieces (the host decides): pieces start at random quarter turns. Scroll while
  dragging a piece to turn it either way. Only upright pieces drop into
  place, and neighbors only snap together when they're turned the same way
- Resize the window from its corner, down to a small 320 x 240 to keep it on screen while you play;
  scroll to zoom, right-drag to pan
- Players who log in or join late catch up on the picture and every piece's position
- A faint copy of the picture under the board as a guide (off unless the host turns it on)
- A results banner when the puzzle is done, with who placed the most pieces

## Hosting a puzzle

1. Turn an image into a code with the `ttpz` tool (JPEG, PNG, WebP, GIF, BMP; a web URL or
   a file). Download it from the latest
   [GitHub release](https://github.com/TurkeyTickle/TurkeyTickleUI/releases):
   `ttpz-windows-x86_64.exe` for Windows or `ttpz-linux-x86_64` for Linux (run
   `chmod +x ttpz-linux-x86_64` first). Rename it to `ttpz` if you like. Run it from a terminal:

   ```
   ttpz https://example.com/picture.jpg
   ```

   The code is copied to your clipboard automatically. If the clipboard is unavailable, `ttpz`
   prints the code. Useful options: `--size` (longest side, up to 320 pixels;
   default 192; use 128 for a picture that arrives in about 10 seconds), `--colors` (up to 64), `--dither` (smoother photos), `--preview out.png` (see what
   players will get), `--out code.txt` (write the code to a file). See [Building the image tool](#building-the-image-tool).
2. In game, type `/ttpz host`, paste the code, name the puzzle, pick the number of pieces and whether
   to play with your guild or your party / raid, and click **Start puzzle**. Tick **Pieces start
   turned** for a harder puzzle where pieces have to be turned upright. Not in a party? Choose
   party / raid anyway and you'll be asked whether to puzzle alone; anyone who joins your party
   later can play along.

No image handy? Click **Use sample picture** in the host window.

## Commands

| Command            | Action |
| ------------------ | ------ |
| `/ttpz`            | Open the puzzle (or join the latest one, or host if there isn't one) |
| `/ttpz host`       | Host a new puzzle |
| `/ttpz join [name]`| Join the latest puzzle, or the one hosted by `name`. If you haven't heard about one (it started before you logged in), asks your guild and group and joins the puzzle in progress |
| `/ttpz leave`      | Stop playing (you can rejoin later) |
| `/ttpz end`        | End your puzzle for everyone (host only) |
| `/ttpz status`     | List puzzles and their progress |
| `/ttpz version`    | Show your addon version and puzzle protocol |
| `/ttpz options`    | Open the options |

Options live under **Options > AddOns > Turkey Tickle UI > Puzzle**.

## Playing with older versions

Players don't all need the same version. Anyone can play a puzzle that only uses features their
version has. A puzzle without turned pieces works with every version back to 0.1.0, whoever hosts
it.

When a puzzle needs something newer, players who can't play it get a chat message naming the host's
version, their own, and the version to update to. The host gets a message too, once per player,
naming who can't join and what they need. 0.1.0 came out before version checks, so its players don't
see the puzzle or get a message; only the host is told. Puzzles with turned pieces need 0.2.0.

For developers: `Session.lua` documents the message format and the compatibility rules. Each change
older versions can't follow gets a new protocol number.
`tests/puzzle_compat.sh` plays the current code against 0.1.0 and the latest release.

## Building the image tool

Releases come with ready-made builds, so this is only needed for other platforms or changes to the
tool. `tools/ttpz` is a Rust program that builds to a single self-contained executable:

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
