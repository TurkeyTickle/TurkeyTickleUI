# ForeverPlates

Clean, readable nameplates for **World of Warcraft: Forever** (interface `16001`).

## Features

- Flat health bars colored by reaction, class (players), or tapped state
- Threat glow: orange with your threat % when you're close to pulling, red when the mob is on you
  (**tank mode** flips it to warn when you're losing aggro)
- Execute-range highlight (configurable threshold)
- Cast bars with spell icon, name, timer, uninterruptible tint, and an "Interrupted" flash
- Your own debuffs on enemy plates with cooldown swipes and stack counts
- Level with difficulty color and elite / rare / boss tag
- Target highlight border and raid target icons
- In-game options panel; everything applies live

## Install

Copy or symlink this folder into:

```
World of Warcraft/_forever_/Interface/AddOns/ForeverPlates
```

## Usage

| Command     | Action               |
| ----------- | -------------------- |
| `/fp`       | Open the options     |
| `/fp tank`  | Toggle tank mode     |
| `/fp reset` | Reset all settings   |

Nameplate visibility, stacking, and range are still controlled by the game's own
nameplate settings (Interface > Names, or the `nameplate*` CVars).

## License

MIT
