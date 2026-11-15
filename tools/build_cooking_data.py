#!/usr/bin/env python3
"""Builds TurkeyTickleUI_Cooking/Data/*.lua.

Recipes, reagents, skill-up thresholds, trainer fees, recipe scrolls and rank training come from the
SkillUp Forever addon's data (WoW: Forever client tables). Where reagents and recipes drop, who sells
them, NPC levels and spawn coordinates come from the Polestar addon's Codex and NPC databases. Both are
read from the local Forever install.

    python3 tools/build_cooking_data.py [--addons PATH]
"""

import argparse
import glob
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from build_pets_data import DEFAULT_ADDONS, ROOT, load_polestar, lua_spawns, lua_str  # noqa: E402

OUT = os.path.join(ROOT, "TurkeyTickleUI_Cooking", "Data")
COOKING = 185
FISHING = 356
# Below this a mob isn't worth hunting for the reagent.
MIN_DROP_CHANCE = 5


# ---------------------------------------------------------------------------- SkillUp Forever


def lua_block(src, name):
    """The body of `ns.<name> = { ... }` (to its closing brace at column 0)."""
    m = re.search(r"^ns\.%s = \{\n(.*?)^\}" % re.escape(name), src, re.S | re.M)
    if not m:
        sys.exit("SkillUp Forever data has no ns.%s" % name)
    return m.group(1)


def number_list(s):
    return [float(n) if "." in n else int(n) for n in re.findall(r"-?[\d.]+", s)]


def load_skillup(addons):
    data = os.path.join(addons, "SkillUpForever", "Data")
    if not os.path.isdir(data):
        sys.exit("No SkillUp Forever data under " + addons)
    read = lambda name: open(os.path.join(data, name)).read()
    recipes_src, thresholds_src = read("Recipes.lua"), read("Thresholds.lua")
    trainer_src, sources_src, vendor_src = read("Trainer.lua"), read("Sources.lua"), read("Vendor.lua")

    thresholds = {}
    for m in re.finditer(r"^\t\[(\d+)\] = \{ ([\d, ]+) \},", lua_block(thresholds_src, "Thresholds"), re.M):
        thresholds[int(m.group(1))] = number_list(m.group(2))

    recipes = {}
    for m in re.finditer(r"^\t\[(\d+)\] = \{ skillLine = (\d+), reagents = \{(.*?)\}, output = (false|\{[^}]*\}) \},$",
                         lua_block(recipes_src, "RecipeData"), re.M):
        if int(m.group(2)) != COOKING:
            continue
        reagents = [(int(i), int(q)) for i, q in re.findall(r"itemID = (\d+), quantity = (\d+)", m.group(3))]
        out = re.search(r"itemID = (\d+), quantity = ([\d.]+)", m.group(4))
        recipes[int(m.group(1))] = {"reagents": reagents, "output": int(out.group(1)) if out else None,
                                    "yield": float(out.group(2)) if out else 0}

    names = {}
    block = re.search(r"^\t\[%d\] = \{\n(.*?)^\t\}," % COOKING, lua_block(recipes_src, "RecipeNames"), re.S | re.M)
    for name, spell in re.findall(r'\["((?:[^"\\]|\\.)*)"\] = (\d+)', block.group(1)):
        names[int(spell)] = name.replace('\\"', '"')

    def pairs_table(src, name):
        return {int(k): number_list(v) for k, v in re.findall(r"^\t\[(\d+)\] = \{ ([^}]*) \},", lua_block(src, name), re.M)}

    def skill_line_row(src, name):
        m = re.search(r"^\t\[%d\] = \{ (.*) \},$" % COOKING, lua_block(src, name), re.M)
        return [re.findall(r'-?\d+|"\w+"', row) for row in re.findall(r"\{ ([^{}]*) \}", m.group(1))] if m else []

    scroll_drops = {}
    for k, v in re.findall(r"^\t\[(\d+)\] = \{ (.*) \},$", lua_block(sources_src, "ScrollDrops"), re.M):
        scroll_drops[int(k)] = [(int(n), float(c)) for n, c in re.findall(r"\{ (\d+), ([\d.]+) \}", v)]

    return {
        "thresholds": thresholds,
        "recipes": recipes,
        "names": names,
        "scrolls": pairs_table(recipes_src, "RecipeScrolls"),
        "trainer": pairs_table(trainer_src, "TrainerFees"),
        "trainer_ranks": skill_line_row(trainer_src, "TrainerRanks"),
        "rank_books": skill_line_row(recipes_src, "RankBooks"),
        "rank_quests": skill_line_row(trainer_src, "RankQuests"),
        "trainers": skill_line_row(sources_src, "ProfessionTrainers"),
        "gathered": {int(k): int(v) for k, v in re.findall(r"^\t\[(\d+)\] = (\d+),", lua_block(sources_src, "GatheredBy"), re.M)},
        "scroll_drops": scroll_drops,
        "world_drops": {int(k) for k in re.findall(r"^\t\[(\d+)\] = true", lua_block(sources_src, "WorldDrops"), re.M)},
        "vendor_prices": {int(k): int(v) for k, v in re.findall(r"^\t\[(\d+)\] = (\d+),", lua_block(vendor_src, "VendorPrices"), re.M)},
    }


# ---------------------------------------------------------------------------- Polestar Codex


def codex_groups(addons, group, pattern):
    """{id: (name, record)} for every Register("<group>", names, records) in the matching pack files."""
    out = {}
    for path in sorted(glob.glob(os.path.join(addons, "Polestar_Codex", pattern))):
        src = open(path).read()
        for m in re.finditer(r'C\.Register\("%s", "((?:[^"\\]|\\.)*)", "((?:[^"\\]|\\.)*)"' % group, src):
            unesc = lambda s: s.replace("\\n", "\n").replace("\\t", "\t").replace('\\"', '"').replace("\\\\", "\\")
            for line in unesc(m.group(1)).split("\n"):
                parts = line.split("\t")
                if len(parts) >= 3 and parts[0].isdigit():
                    out.setdefault(int(parts[0]), ["", ""])[0] = parts[2]
            for line in unesc(m.group(2)).split("\n"):
                parts = line.split("\t", 1)
                if len(parts) == 2 and parts[0].isdigit():
                    out.setdefault(int(parts[0]), ["", ""])[1] = parts[1]
    return out


def item_sources(record):
    """Decoded item sources: drops [(npc, chance)], vendors [(npc, cost)], quests, world (min, max)."""
    fields = record.split(";")
    src = {"drops": [], "vendors": [], "quests": [], "objects": [], "world": None}
    for f in fields[7:]:
        if not f:
            continue
        kind, parts = f[0], f[1:].split(",")
        num = lambda i: float(parts[i]) if len(parts) > i and parts[i] not in ("",) and re.match(r"^[\d.]+$", parts[i]) else None
        if kind == "d" and num(0):
            # parts: npc, chance, instance, provenance
            src["drops"].append((int(num(0)), num(1) or 0, parts[2] if len(parts) > 2 else ""))
        elif kind == "v" and num(0):
            src["vendors"].append((int(num(0)), int(num(1) or 0)))
        elif kind == "q" and num(0):
            src["quests"].append(int(num(0)))
        elif kind == "o" and num(0):
            src["objects"].append((int(num(0)), num(1) or 0))
        elif kind == "w" and num(0) is not None:
            src["world"] = (int(num(0)), int(num(1) or num(0)))
    return src


def npc_facts(record):
    """Level range, elite/rare/boss and instance from a Codex NPC record."""
    t = record.split(";")
    level = lambda i: int(t[i]) if len(t) > i and t[i].isdigit() else None
    lo, hi = level(0), level(1)
    flags = t[3] if len(t) > 3 else ""
    title = t[-1][1:] if len(t) >= 8 and t[-1].startswith("t") else ""
    title = re.sub(r"%([0-9A-Fa-f]{2})", lambda m: chr(int(m.group(1), 16)), title)
    return {
        "title": title,
        "lo": lo, "hi": hi or lo,
        "faction": t[2] if len(t) > 2 else "",
        "elite": "e" in flags, "rare": "r" in flags, "boss": "b" in flags,
        "instance": t[4] if len(t) > 4 else "",
        "roles": t[5].split(",") if len(t) > 5 and t[5] else [],
    }


# ---------------------------------------------------------------------------- Lua output


HEADER = "-- Generated by tools/build_cooking_data.py from SkillUp Forever's recipe data and Polestar's item and NPC data.\n" \
         "-- Do not edit by hand: rerun the script.\n\nlocal _, ns = ...\n\n"


def write(name, body):
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, name), "w") as f:
        f.write(HEADER + body)


def lua_num(n):
    return ("%g" % n) if isinstance(n, float) else str(n)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--addons", default=DEFAULT_ADDONS, help="Forever Interface/AddOns folder")
    args = parser.parse_args()

    su = load_skillup(args.addons)
    spawns, names, _, factions, _, era_frames = load_polestar(args.addons)
    if not spawns:
        sys.exit("No Polestar NPC data found under " + args.addons)
    items = codex_groups(args.addons, "item", "Items*.lua")
    items.update(codex_groups(args.addons, "recipe", "Recipes*.lua"))
    npcs = codex_groups(args.addons, "npc", "Npcs*.lua")
    npcs.update(codex_groups(args.addons, "rare", "Rares*.lua"))

    used_npcs = {}  # npcID -> set of kinds

    def use_npc(npc_id, kind):
        if npc_id in spawns:
            used_npcs.setdefault(npc_id, set()).add(kind)
            return True
        return False

    # Recipes ---------------------------------------------------------------
    recipe_rows, reagent_ids, scroll_ids, output_ids = [], set(), set(), set()
    for spell, t in sorted(su["thresholds"].items(), key=lambda kv: (kv[1][1], kv[0])):
        recipe = su["recipes"].get(spell)
        name = su["names"].get(spell)
        if not recipe or not name or not recipe["reagents"]:
            continue
        row = {"id": spell, "name": name, "t": t, "reagents": recipe["reagents"], "output": recipe["output"]}
        if spell in su["trainer"]:
            row["trainer"] = su["trainer"][spell]
        if spell in su["scrolls"]:
            row["scroll"], row["scrollSkill"] = su["scrolls"][spell]
            scroll_ids.add(row["scroll"])
        recipe_rows.append(row)
        reagent_ids.update(i for i, _ in recipe["reagents"])
        if recipe["output"]:
            output_ids.add(recipe["output"])

    # Items -----------------------------------------------------------------
    item_rows = {}
    for item_id in sorted(reagent_ids | scroll_ids | output_ids | {16072}):
        name, record = items.get(item_id, ("", ""))
        if not name:
            continue
        src = item_sources(record)
        row = {"name": name}
        if item_id in reagent_ids:
            drops = [(n, c) for n, c, inst in src["drops"] if not inst and c >= MIN_DROP_CHANCE and use_npc(n, "mob")]
            if drops:
                row["drops"] = drops
            if su["gathered"].get(item_id) == FISHING:
                row["fish"] = True
            if item_id in su["vendor_prices"]:
                row["price"] = su["vendor_prices"][item_id]
        if item_id in scroll_ids:
            drops = [(n, c) for n, c in su["scroll_drops"].get(item_id, []) if use_npc(n, "mob")]
            if drops:
                row["drops"] = drops
            if item_id in su["world_drops"]:
                row["worldDrop"] = True
        if item_id in reagent_ids or item_id in scroll_ids or item_id == 16072:
            vendors = [(n, c) for n, c in src["vendors"] if use_npc(n, "vendor")]
            if vendors:
                row["vendors"] = [n for n, _ in vendors]
                row.setdefault("price", vendors[0][1])
            if src["quests"]:
                row["quests"] = src["quests"]
        item_rows[item_id] = row

    # Rank training -----------------------------------------------------------
    ranks = []
    for cap, fee, skill, level in (map(int, r) for r in su["trainer_ranks"]):
        ranks.append("{ cap = %d, skill = %d, level = %d, fee = %d }" % (cap, skill, level, fee))
    for cap, book, price, skill, level in (map(int, r) for r in su["rank_books"]):
        ranks.append("{ cap = %d, skill = %d, level = %d, book = %d, price = %d }" % (cap, skill, level, book, price))
    quest_rows = {}
    for row in su["rank_quests"]:
        cap, quest, skill, level, side = int(row[0]), int(row[1]), int(row[2]), int(row[3]), row[4].strip('"')
        quest_rows.setdefault((cap, quest, skill, level), []).append(side)
    for (cap, quest, skill, level), sides in quest_rows.items():
        ranks.append("{ cap = %d, skill = %d, level = %d, quest = %d }" % (cap, skill, level, quest))

    # Every cooking trainer teaches up to Journeyman; Expert is a book and Artisan a quest.
    trainer_caps = {npc_id: cap for npc_id, cap in (map(int, r) for r in su["trainers"])}
    for npc_id, (_, record) in npcs.items():
        if "trainer:%d" % COOKING in npc_facts(record)["roles"]:
            trainer_caps.setdefault(npc_id, 150)
    trainers = [(npc_id, cap) for npc_id, cap in sorted(trainer_caps.items()) if use_npc(npc_id, "trainer")]

    # Write -------------------------------------------------------------------
    lines = ["-- { id = recipe spell, t = { orange, yellow, green, grey }, r = { { item, count } }, trainer = { fee, skill },",
             "--   scroll = recipe item, scrollSkill }", "ns.recipes = {"]
    for r in recipe_rows:
        fields = ["id = %d" % r["id"], "name = " + lua_str(r["name"]), "t = { %s }" % ", ".join(map(str, r["t"])),
                  "r = { %s }" % ", ".join("{ %d, %d }" % p for p in r["reagents"])]
        if r["output"]:
            fields.append("item = %d" % r["output"])
        if "trainer" in r:
            fields.append("trainer = { %s }" % ", ".join(lua_num(n) for n in r["trainer"]))
        if "scroll" in r:
            fields.append("scroll = %d, scrollSkill = %d" % (r["scroll"], r["scrollSkill"]))
        lines.append("\t{ %s }," % ", ".join(fields))
    lines.append("}\n")
    write("Recipes.lua", "\n".join(lines))

    lines = ["-- drops = { { npc, chance % } }, vendors = { npc }, price in copper, fish = caught by fishing", "ns.items = {"]
    for item_id, row in sorted(item_rows.items()):
        fields = ["n = " + lua_str(row["name"])]
        if row.get("drops"):
            fields.append("drops = { %s }" % ", ".join("{ %d, %s }" % (n, lua_num(round(c, 1))) for n, c in row["drops"]))
        if row.get("vendors"):
            fields.append("vendors = { %s }" % ", ".join(map(str, row["vendors"])))
        if row.get("price"):
            fields.append("price = %d" % row["price"])
        if row.get("quests"):
            fields.append("quests = { %s }" % ", ".join(map(str, row["quests"])))
        if row.get("fish"):
            fields.append("fish = true")
        if row.get("worldDrop"):
            fields.append("worldDrop = true")
        lines.append("\t[%d] = { %s }," % (item_id, ", ".join(fields)))
    lines.append("}\n")
    lines.append("-- Cooking ranks above Apprentice and how to get them")
    lines.append("ns.ranks = {\n\t%s,\n}\n" % ",\n\t".join(ranks))
    lines.append("-- { npc, highest cap it trains }")
    lines.append("ns.trainerList = { %s }\n" % ", ".join("{ %d, %d }" % t for t in trainers))
    write("Items.lua", "\n".join(lines))

    lines = ["ns.npcs = {"]
    for npc_id in sorted(used_npcs):
        name, record = npcs.get(npc_id, (names.get(npc_id, ""), ""))
        name = name or names.get(npc_id, "")
        facts = npc_facts(record)
        lv = ""
        if facts["lo"]:
            lv = str(facts["lo"]) if facts["hi"] == facts["lo"] else "%d-%d" % (facts["lo"], facts["hi"])
        fields = ["n = " + lua_str(name), "lv = " + lua_str(lv), "s = " + lua_spawns(spawns[npc_id])]
        faction = factions.get(npc_id) or (facts["faction"] if facts["faction"] in ("A", "H") else "")
        if faction:
            fields.append("faction = " + lua_str(faction))
        if facts["title"]:
            fields.append("sub = " + lua_str(facts["title"]))
        if facts["elite"]:
            fields.append("elite = true")
        if facts["rare"]:
            fields.append("rare = true")
        lines.append("\t[%d] = { %s }," % (npc_id, ", ".join(fields)))
    lines.append("}\n")
    write("Npcs.lua", "\n".join(lines))

    used_maps = {m for npc_id in used_npcs for m, era, _ in spawns[npc_id] if era}
    lines = ["ns.eraMapFrames = {"]
    for map_id in sorted(used_maps):
        b = era_frames.get(map_id)
        if b:
            lines.append("\t[%d] = { c = %s, left = %s, right = %s, top = %s, bottom = %s }," % (
                map_id, b["c"], b["left"], b["right"], b["top"], b["bottom"]))
        else:
            print("warning: no Era bounds for map %d" % map_id)
    lines.append("}\n")
    write("MapFrames.lua", "\n".join(lines))

    kinds = {}
    for k in used_npcs.values():
        for kind in k:
            kinds[kind] = kinds.get(kind, 0) + 1
    print("recipes %d, reagents %d, scrolls %d, npcs %d (%s), trainers %d" % (
        len(recipe_rows), len(reagent_ids), len(scroll_ids), len(used_npcs),
        ", ".join("%s %d" % kv for kv in sorted(kinds.items())), len(trainers)))


if __name__ == "__main__":
    main()
