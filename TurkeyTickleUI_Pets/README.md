# Turkey Tickle UI: Pets

A hunter pet guide for **World of Warcraft: Forever** (interface `16001`), built from
[Petopia's Forever guide](https://www.wow-petopia.com/forever/).

## Features

- **Skills**: every pet skill and rank, with its pet level, training point cost and the beasts that teach
  it (level and zone). Teachers are sorted by distance from you.
- **Ready to learn now**: the best rank of each skill you don't know yet that you can tame at your level,
  plus what the pet trainer can sell you.
- **Families**: role (offense / general / defense), diet, learnable skills, notable rare looks and the
  beasts in that family that teach skills.
- **Rare & Special**: Petopia's unique rares, rares, unusual looks, elites and spawned pets.
- **Trainers**: every pet trainer, nearest first.
- **World map markers**: rare and special pets (purple), pet trainers (gold) and anything you pin (green).
  Click a marker for a TomTom waypoint (or its coordinates); shift-click pins or unpins it.
- **Beast tooltips**: mouse over a beast to see which skill ranks it teaches (green when it's new to you).
- Remembers which ranks you know: click **Read my skills** in the browser (or cast Beast Training) and
  they're read from its window; skills WhatsTraining has already recorded are imported at login, and new
  ones are picked up from the "You have learned" message. Shift-click a rank in the browser to set it by hand.

## Usage

| Command              | Action                                  |
| -------------------- | --------------------------------------- |
| `/ttpets`            | Open or close the pet browser           |
| `/ttpets <text>`     | Open the browser searching for `<text>` |
| `/ttpets known`      | List the skill ranks recorded as known  |
| `/ttpets clear`      | Remove all pins from the map            |
| `/ttpets options`    | Open the options                        |
| `/ttpets reset`      | Reset all settings                      |

Options live under **Options > AddOns > Turkey Tickle UI > Pets**.

## Data

`Data/*.lua` is generated; don't edit it by hand. Rebuild with:

```
python3 tools/build_pets_data.py            # uses cached Petopia pages in tools/.cache
python3 tools/build_pets_data.py --refresh  # downloads Petopia again
```

Pet abilities, ranks, teachers, families and special pets come from Petopia. Spawn coordinates and the
pet trainer list come from the NPC databases of the [Polestar](https://www.curseforge.com/wow/addons/polestar)
addon, read from your Forever install (`--addons` to point elsewhere). A few dungeon elites and rares have no
known coordinates and show only their zone.

Skill names are matched in English, so recording known ranks only works on an English client.
