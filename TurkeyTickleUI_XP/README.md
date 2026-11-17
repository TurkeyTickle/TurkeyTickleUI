# Turkey Tickle UI: XP

A tiny XP/hour window for **World of Warcraft: Forever** (interface `16001`): how fast you're levelling
right now, whether that's going up or down, and how long until your next level.

## Features

- **Recent rate**: XP earned over the last 10 minutes (5 to 30 in the options), scaled to an hour, with a
  green or red arrow when it's more than 5% faster or slower than the 10 minutes before.
- **Session average** and **time to level**, from the recent rate (or the session average when you haven't
  earned anything lately).
- **Trend line**: the recent rate over the last hour.
- Drag the window anywhere (or lock it), right-click it to start a new session, and mouse over it for
  session totals. The session survives `/reload` and starts fresh each login. The window hides at max level.

## Usage

| Command         | Action                         |
| --------------- | ------------------------------ |
| `/ttxp`         | Show or hide the window        |
| `/ttxp reset`   | Start a new session            |
| `/ttxp options` | Open the options               |

A key binding to show or hide the window is under **Key Bindings > AddOns > Turkey Tickle UI**, and
clicking the module in the addon compartment menu does the same.

Options live under **Options > AddOns > Turkey Tickle UI > XP**.
