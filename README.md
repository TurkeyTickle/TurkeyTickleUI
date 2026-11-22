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

Copy (or symlink) each module folder into:

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

The Pets and Cooking data files are generated from addons in your Forever install:

```
python3 tools/build_pets_data.py
python3 tools/build_cooking_data.py
```

The Puzzle module's image tool is a .NET 10 Native AOT app in `tools/PuzzleImage`:

```
dotnet publish tools/PuzzleImage -c Release -r linux-x64 -o tools/bin
tools/bin/ttpz https://example.com/picture.jpg --out /tmp/code.txt
luajit tests/harness_puzzle.lua TurkeyTickleUI_Puzzle /tmp/code.txt
```

## License

MIT
