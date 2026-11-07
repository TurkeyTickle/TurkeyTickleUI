# Turkey Tickle UI: Plates

Clean, Blizzard-style nameplates for **World of Warcraft: Forever** (interface `16001`).

## Features

- Health bars in Blizzard's reaction colors, class colors for players, grey when tapped
- Threat glow: pulsing orange with a `!` and your threat % when you're close to pulling off the tank or
  your pet, solid red when the mob is on you (**tank mode** flips it to warn when you're losing aggro),
  plus an optional warning sound
- Execute-range highlight (configurable threshold)
- Cast bars with spell icon, timer, uninterruptible shield, and an "Interrupted" flash
- Your own debuffs on enemy plates with cooldown swipes and stack counts
- Level colored by Blizzard's difficulty rules, elite / rare markers
- Target highlight, raid target icons, configurable nameplate distance

## Usage

| Command      | Action             |
| ------------ | ------------------ |
| `/ttp`       | Open the options   |
| `/ttp tank`  | Toggle tank mode   |
| `/ttp threat`| Print threat debug info for your target |
| `/ttp reset` | Reset all settings |

Options live under **Options > AddOns > Turkey Tickle UI > Plates**.
