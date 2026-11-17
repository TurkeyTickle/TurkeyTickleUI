# XP/hour module design

A new Turkey Tickle UI module, `TurkeyTickleUI_XP`, that shows a small movable window with your
current XP per hour, a session average, a trend line and an estimated time to level.

## Goals

- See at a glance how fast you're levelling right now, and whether it's going up or down.
- Stay out of the way: a tiny window you can drag anywhere and hide/show instantly.

## Non-goals

- Tracking reputation, honor, gold or kills.
- Keeping history across logins. The session starts fresh on each real login.

## Files

| File | Purpose |
| ---- | ------- |
| `TurkeyTickleUI_XP.toc` | Metadata, saved variables, load order |
| `Core.lua` | Defaults, saved settings, event driver, `/ttxp` slash command, addon compartment click |
| `Tracker.lua` | XP accounting and rate maths. No frames, so the harness can test it directly |
| `Display.lua` | The window: text, arrow, sparkline, drag, tooltip, right-click reset |
| `Config.lua` | Options page under the shared "Turkey Tickle UI" settings category |
| `Bindings.xml` | Key binding "Toggle XP/hour window" |
| `README.md` | Module readme |

The module follows the existing modules' patterns: `ns.handlers` event table, `ns.defaults` with
`copyDefaults`, `ns:Print`, `ns:Changed`, and the shared `getSuiteCategory` options code.

## Saved variables

- `TurkeyTickleUI_XPDB` (account-wide settings):
  - `shown = true`
  - `locked = false`
  - `scale = 1.0`
  - `windowMinutes = 10` (rolling window, 5 to 30)
  - `point = {}` (saved window position)
- `TurkeyTickleUI_XPCharDB` (per character): the current session, so it survives `/reload`:
  - `session = { start, gained, samples, lastXP, lastMax, lastLevel }`

## Tracking

- **Clock:** `GetTime()`, which keeps counting across `/reload`. The saved session is kept only
  when `PLAYER_ENTERING_WORLD` reports `isReloadingUi`. Otherwise (a fresh login or a character
  switch) a new session starts.
- **Gains:** on `PLAYER_XP_UPDATE` and `PLAYER_LEVEL_UP`, read `UnitXP`, `UnitXPMax` and
  `UnitLevel`:
  - Same level: `gained += xp - lastXP` (ignored if negative).
  - Level went up: `gained += (lastMax - lastXP) + xp`. If several levels were skipped, the
    middle levels are not counted. That's acceptable because it doesn't happen through normal play.
  - Store the new `lastXP`, `lastMax` and `lastLevel`.
- **Samples:** every 30 seconds (an `OnUpdate` throttle on the driver), append `{ t, gained }`.
  Keep samples covering the last 70 minutes, enough for the 60-minute sparkline plus one window.
- **Recent rate:** `(gained_now - gained_at(now - window)) / window * 3600`. If the session is
  younger than the window, use the session's age as the window. This is undefined (shown as `--`)
  for the first 60 seconds.
- **Session average:** `gained / (now - start) * 3600`, or `--` for the first 60 seconds.
- **Trend:** compare the recent rate with the rate over the window before it. A change of more than 5% is up or down; anything smaller is flat. There's no trend until the session is two windows old.
- **Time to level:** `(UnitXPMax - UnitXP) / rate` using the recent rate, falling back to the
  session average when the recent rate is 0. Shows `--` when both are 0 or undefined.
- **Max level:** when `IsPlayerAtEffectiveMaxLevel()` (or `UnitXPMax == 0`) is true, the window
  hides and tracking stops.
- **Reset:** clears the session and starts a new one from the current XP.

## Window

- About 160×56 pixels, `BackdropTemplate`, a dark translucent background with a thin border, and
  `MEDIUM` strata, clamped to the screen.
- Line 1: the recent rate as `14.2k/hr` (`1.2m/hr` above a million), then the trend arrow: green
  ▲, red ▼ or grey –. Arrows use texture escapes or plain characters that the game font renders.
- Line 2 (small, grey): `avg 11.8k · 1h 12m to 37`.
- Sparkline: across the bottom, the recent rate at each sample over the last 60 minutes, drawn as
  line segments with `CreateLine`, scaled to the highest value shown. It's hidden until there are
  two points.
- The text refreshes once per sample tick and on every XP event.
- **Drag** with the left button to move, unless the window is locked. The position is saved to
  `point`.
- **Right-click:** resets the session.
- **Tooltip:** XP this session, session length, XP to level, and the hint lines "Drag: move",
  "Right-click: reset session" and "/ttxp: hide".

## Hide/show

- `/ttxp` toggles the window.
- `/ttxp reset` resets the session.
- `/ttxp options` opens the options page.
- `/ttxp help` lists these commands.
- The `TURKEYTICKLEUI_XP_TOGGLE` binding in `Bindings.xml` toggles the window under the
  "Turkey Tickle UI" header.
- Clicking the addon compartment entry toggles the window.
- `shown` is saved, so the window comes back in the same state.

## Options page

- Checkboxes: Show window, Lock position.
- Sliders: Scale (50% to 200%), Rolling window minutes (5 to 30, step 5).
- Buttons: Reset session, Reset window position, Reset to defaults.

## Testing

`tests/harness_xp.lua` loads the module in a stubbed WoW environment (modelled on
`harness_cooking.lua`) with a controllable `GetTime`, `UnitXP`, `UnitXPMax` and `UnitLevel`. It
checks:

- The module loads and the slash command and toggle work without errors.
- A steady gain of 1000 XP per minute gives about 60k/hr, both recent and average.
- Raising the gain rate makes the trend go up; lowering it makes the trend go down.
- A level-up mid-session counts the leftover XP of the old level plus the XP in the new level.
- Time to level matches the XP remaining divided by the rate.
- A reset zeroes the session.

The README gains a module row and a harness command.
