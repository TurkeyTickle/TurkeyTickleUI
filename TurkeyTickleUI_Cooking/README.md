# Turkey Tickle UI: Cooking

A Cooking coach for **World of Warcraft: Forever** (interface `16001`): it notices what in your bags can
level Cooking, reminds you to actually cook it, and points you at the mobs nearby worth killing for meat.

## Features

- **Cook now**: what to cook from your bags, best skill-up chance first, with your skill moving as you go,
  and about how many points that gets you. Also: leftover meat that only needs a vendor's spices, recipes
  worth learning for meat you're already carrying, and ingredients that no longer give you points.
- **Hunt**: mobs at or near your level, ranked by expected Cooking skill-ups per kill (drop chance times
  what the meat is worth to you) and how close they are; plus every useful ingredient and who drops it.
- **Recipes**: every Cooking recipe grouped by its colour at your skill, with reagents, bag counts and
  where to get them.
- **Learn**: your next Cooking rank (trainer, Expert Cookbook or the Artisan quest), recipes worth
  learning now or in the next 25 points, and trainers nearest first.
- **Reminders**: at login, when you start resting in an inn or city, and when looting fills your bags
  with points, plus a warning before you hit your skill cap.
- **Cook button**: a movable button that shows how many skill-ups you're carrying. Click it to open
  Cooking, right-click for the helper, shift-drag to move. It hides when there's nothing to cook.
- **Tooltips**: ingredients list the recipes that use them and their colour for you; mobs list their
  cooking drops and skill-ups per kill.
- **World map**: the best hunting mobs nearby in orange, and anything you pin in green. Click a marker for
  a TomTom waypoint (or its coordinates); shift-click pins or unpins it.

Known recipes are read from the Cooking window: open it once (the helper's **Open Cooking** button does)
and they're remembered. Recipes learned later are picked up from the "You have learned" message, and
shift-clicking a recipe in the helper marks it by hand.

## Usage

| Command           | Action                                   |
| ----------------- | ---------------------------------------- |
| `/ttcook`         | Open or close the Cooking helper         |
| `/ttcook <text>`  | Search recipes and ingredients           |
| `/ttcook status`  | Print what your bags can cook right now  |
| `/ttcook hunt`    | Open the Hunt tab                        |
| `/ttcook learn`   | Open the Learn tab                       |
| `/ttcook clear`   | Remove all pins from the map             |
| `/ttcook options` | Open the options                         |
| `/ttcook reset`   | Reset all settings                       |

Options live under **Options > AddOns > Turkey Tickle UI > Cooking**.

## Data

`Data/*.lua` is generated; don't edit it by hand. Rebuild with:

```
python3 tools/build_cooking_data.py
```

Recipes, reagents, skill-up colours, trainer fees, recipe items and rank training come from the
[SkillUp Forever](https://www.curseforge.com/wow/addons/skillup-forever) addon's data (read from the
Forever client's tables). Drop chances, vendors, NPC levels and spawn coordinates come from the
[Polestar](https://www.curseforge.com/wow/addons/polestar) addon's Codex. Both are read from your Forever
install (`--addons` to point elsewhere).

Recipe and profession names are matched in English for the chat and skill fallbacks, so an English
client works best.
