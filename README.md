# Turkey Tickle UI

A suite of UI addons for **World of Warcraft: Forever**. Each module is its own addon, so you can
enable only the ones you want.

| Module | Folder | Description |
| ------ | ------ | ----------- |
| [Plates](TurkeyTickleUI_Plates) | `TurkeyTickleUI_Plates` | Blizzard-style nameplates with threat warnings, cast bars and debuffs |

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
```

## License

MIT
