# Turkey Tickle UI

A suite of UI addons for **World of Warcraft: Forever**. Each module is its own addon, so you can
enable only the ones you want.

| Module | Folder | Description |
| ------ | ------ | ----------- |
| [Plates](TurkeyTickleUI_Plates) | `TurkeyTickleUI_Plates` | Blizzard-style nameplates with threat warnings, cast bars and debuffs |
| [Pets](TurkeyTickleUI_Pets) | `TurkeyTickleUI_Pets` | Hunter pet guide: where to learn pet skills, what to tame, rare pets on the map |
| [Puzzle](TurkeyTickleUI_Puzzle) | `TurkeyTickleUI_Puzzle` | Multiplayer jigsaw puzzles: host a picture, solve it together with your guild or group |
| [Cooking](TurkeyTickleUI_Cooking) | `TurkeyTickleUI_Cooking` | Cooking coach: what in your bags levels Cooking, reminders to cook it, mobs nearby to hunt |
| [XP](TurkeyTickleUI_XP) | `TurkeyTickleUI_XP` | A tiny movable XP/hour window with session average, trend line and time to level |

## Install

Download the zip from the latest [GitHub release](https://github.com/TurkeyTickle/TurkeyTickleUI/releases)
and extract it into `World of Warcraft/_forever_/Interface/AddOns/`.

To run straight from the repository instead, copy (or symlink) each module folder into:

```
World of Warcraft/_forever_/Interface/AddOns/
```

All modules share one **Turkey Tickle UI** page in the in-game AddOns options.

## Development

`tests/harness.lua` loads a module in a stubbed WoW environment to catch load and runtime errors
outside the game:

```
luajit tests/harness.lua TurkeyTickleUI_Plates
luajit tests/harness_pets.lua TurkeyTickleUI_Pets
luajit tests/harness_puzzle.lua TurkeyTickleUI_Puzzle [image-code.txt]
luajit tests/harness_cooking.lua TurkeyTickleUI_Cooking
luajit tests/harness_xp.lua TurkeyTickleUI_XP
```

`tests/run_all.sh` runs all of them, then plays the Puzzle module against older releases
(`tests/puzzle_compat.sh`). CI runs it on every push and pull request.

The Pets and Cooking data files are generated from addons in your Forever install:

```
python3 tools/build_pets_data.py
python3 tools/build_cooking_data.py
```

The Puzzle module's image tool is a Rust program in `tools/ttpz`:

```
cargo build --release --manifest-path tools/ttpz/Cargo.toml
tools/ttpz/target/release/ttpz https://example.com/picture.jpg --out /tmp/code.txt
luajit tests/harness_puzzle.lua TurkeyTickleUI_Puzzle /tmp/code.txt
```

## Releasing

All modules share one version, taken from the git tag: plain semver with no `v` (`0.2.0`, or
`0.3.0-beta.1` / `0.3.0-alpha.1` for test builds). The TOCs say `## Version: @project-version@`, and
packaging replaces that with the tag. A copy straight from the repository calls itself `dev`.

Work happens on `main`. To release, merge `main` into `prod` (a pull request from `main` to `prod`
is easiest). Every push to `prod` is a release, and the version is picked for you: the patch number
goes up (0.2.0 to 0.2.1), unless a commit message since the last release contains `[minor]`
(0.2.0 to 0.3.0) or `[major]` (0.2.0 to 1.0.0). To release `prod` as it is, or as an exact version
like `0.3.0-beta.1`, run the **Release** workflow on `prod` from the Actions tab. The workflow:

1. Picks the version (`tools/next_version.sh`) and runs `tests/run_all.sh`
2. Tags the commit and writes a changelog from the commits since the last release
3. Packages every module into one zip with the [BigWigs packager](https://github.com/BigWigsMods/packager)
   (`.pkgmeta`) and publishes it as a GitHub release
4. Attaches the `ttpz` image tool, built for Windows and Linux (`.github/workflows/ttpz.yml`, which
   CI also runs on every push)

To also upload to CurseForge, create the project there, then add a repository secret
`CF_API_KEY` (a CurseForge API token) and a repository variable `CURSEFORGE_PROJECT_ID`. Releases
skip CurseForge until both exist.

If a Puzzle change needs a new protocol, add the release it will ship in to `PROTOCOL_RELEASES` in
`TurkeyTickleUI_Puzzle/Session.lua` (see the compatibility notes there). The automatic version is
raised to at least that release, and an exact version older than it is refused.

## License

MIT
