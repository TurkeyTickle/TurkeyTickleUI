#!/usr/bin/env python3
"""Builds TurkeyTickleUI_Pets/Data/*.lua.

Pet facts (abilities, ranks, which beasts teach them, families, rare and special pets) come from
Petopia's World of Warcraft: Forever pages. Spawn coordinates and pet trainers come from the
Polestar addon's NPC databases in the local Forever install.

    python3 tools/build_pets_data.py [--refresh] [--addons PATH]
"""

import argparse
import glob
import html
import os
import re
import sys
import time
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE = os.path.join(ROOT, "tools", ".cache")
OUT = os.path.join(ROOT, "TurkeyTickleUI_Pets", "Data")
PETOPIA = "https://www.wow-petopia.com/forever/"
DEFAULT_ADDONS = os.path.expanduser(
    "~/Games/battlenet/drive_c/Program Files (x86)/World of Warcraft/_forever_/Interface/AddOns"
)
SPECIAL_LISTS = ["collector", "rare", "looks", "elite", "spawned"]


def fetch(path, refresh):
    os.makedirs(CACHE, exist_ok=True)
    name = re.sub(r"[^a-z0-9]+", "_", path.lower()).strip("_") + ".html"
    cached = os.path.join(CACHE, name)
    if refresh or not os.path.exists(cached):
        req = urllib.request.Request(PETOPIA + path, headers={"User-Agent": "TurkeyTickleUI data build"})
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = resp.read().decode("utf-8", "replace")
        with open(cached, "w") as f:
            f.write(data)
        time.sleep(0.5)
    with open(cached) as f:
        return f.read()


def text(fragment):
    return re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", "", fragment))).strip()


def icon_name(src):
    return os.path.splitext(os.path.basename(src))[0]


# ---------------------------------------------------------------------------- Petopia


def parse_families(refresh):
    index = fetch("", refresh)
    families = []
    for m in re.finditer(
        r"<div class='family_panel_item (\w+) [^']*'><a href='family\.php\?id=(\w+)'>.*?src='([^']+)'.*?"
        r"family_panel_name[^>]*>([^<]+)<",
        index,
        re.S,
    ):
        role, key, icon, name = m.groups()
        families.append({"key": key, "name": text(name), "role": role, "icon": icon_name(icon)})
    for fam in families:
        page = fetch("family.php?id=" + fam["key"], refresh)
        for kind in ("active", "passive"):
            block = re.search(r"familydetailsabilities classic forever %s'>(.*?)</div></div>" % kind, page, re.S)
            fam[kind] = re.findall(r"abilities\.php#([\w!']+)'", block.group(1)) if block else []
        diet = re.search(r"familydetailsheading diet'>Diet</div>.*?familydetailsdata'>(.*?)</div>", page, re.S)
        fam["diet"] = text(diet.group(1)) if diet else ""
    return families


def parse_npc_item(li):
    m = re.search(r"npc=(\d+)'>([^<]+)</a>\s*\(([^)]*)\)", li)
    if not m:
        return None
    npc_id, name, info = m.groups()
    parts = [p.strip() for p in html.unescape(info).split(",")]
    family = parts[0] if parts else ""
    levels = parts[1] if len(parts) > 1 else ""
    zone = ", ".join(parts[2:]) if len(parts) > 2 else ""
    return {"id": int(npc_id), "name": text(name), "family": family, "levels": levels, "zone": zone}


def parse_abilities(refresh):
    page = fetch("abilities.php", refresh)
    trainer_keys = set()
    trainer_block = re.search(r"Learned from the trainer:</h4>(.*?)</ul>", page, re.S)
    if trainer_block:
        trainer_keys = set(re.findall(r"href='#([\w!']+)'", trainer_block.group(1)))

    abilities, npcs = [], {}
    sections = re.split(r"<h3 class='guide_heading classic forever' id='", page)[1:]
    for section in sections:
        key = section[: section.index("'")]
        head = re.match(r"[^>]*><img[^>]*src='([^']+)'>([^<]+)</h3>", section[len(key):])
        if not head:
            continue
        desc = re.search(r"abilitymaindesc[^>]*>(.*?)</p>", section, re.S)
        fams = re.search(r"ability_family_list classic forever'>(.*?)</span></p>", section, re.S)
        fam_keys = re.findall(r"family\.php\?id=(\w+)", fams.group(1)) if fams else []
        ability = {
            "key": key,
            "name": text(head.group(2)),
            "icon": icon_name(head.group(1)),
            "desc": text(desc.group(1)) if desc else "",
            "trainer": key in trainer_keys,
            "families": fam_keys or "all",
            "ranks": [],
        }
        for rank_html in re.split(r"<li id='[\w!']+?\d+' class='abilityrank", section)[1:]:
            rm = re.search(r"abilityrankname[^>]*>.*?(\d+)</span>: Pet Level (\d+), Cost (\d+) TP\.", rank_html, re.S)
            if not rm:
                continue
            rdesc = re.search(r"abilityrankdesc[^>]*>(.*?)</span>\s*<span class='abilitysourceheading", rank_html, re.S)
            source = re.search(r"abilitysourceheading[^>]*>([^<]*)", rank_html)
            source = source.group(1) if source else ""
            if "trainer" in source:
                src = "trainer"
            elif "taming" in source:
                src = "wild"
            else:
                src = "unknown"
            teachers = []
            for li in re.findall(r"<li class='abilityranknpc[^>]*>(.*?)</li>", rank_html, re.S):
                npc = parse_npc_item(li)
                if npc:
                    teachers.append(npc["id"])
                    npcs.setdefault(npc["id"], npc)
            ability["ranks"].append({
                "rank": int(rm.group(1)),
                "level": int(rm.group(2)),
                "tp": int(rm.group(3)),
                "desc": text(rdesc.group(1)) if rdesc else "",
                "source": src,
                "npcs": teachers,
            })
        abilities.append(ability)
    return abilities, npcs


def parse_special(refresh):
    pets = []
    for list_id in SPECIAL_LISTS:
        page = fetch("browse.php?id=" + list_id, refresh)
        family = None
        for m in re.finditer(
            r"<h2><a href='/forever/family\.php\?id=(\w+)'>|<a href='/forever/look\.php\?id=[^']*' title='([^']*)'"
            r"|<tr class='petstats classic forever'><td class='name'>(.*?)</td><td class='level'>(.*?)</td>"
            r"<td class='zone'>(.*?)</td></tr>\s*<tr class='petnotes[^>]*>.*?<td class='petnotes'[^>]*>(.*?)</td>",
            page,
            re.S,
        ):
            if m.group(1):
                family, look = m.group(1), None
            elif m.group(2) is not None:
                look = html.unescape(m.group(2))
            elif m.group(3):
                name_html = m.group(3)
                level_bits = [text(b) for b in re.split(r"<br\s*/?>", m.group(4))]
                pets.append({
                    "list": list_id,
                    "family": family,
                    "look": look,
                    "name": text(re.sub(r"<div class='tameableicon'>.*?</div>", "", name_html, flags=re.S)),
                    "tameable": "Can Be Tamed" in name_html,
                    "levels": level_bits[0] if level_bits else "",
                    "tags": [b.lower() for b in level_bits[1:] if b],
                    "zone": text(m.group(5)),
                    "note": text(m.group(6)),
                })
    return pets


# ---------------------------------------------------------------------------- Polestar


def codex_records(path, kind):
    src = open(path).read()
    marker = 'C.Register("%s", "' % kind
    body = src[src.find(marker) + len(marker) : src.rfind('")')].encode().decode("unicode_escape")
    for line in body.split("\n"):
        parts = line.split("\t")
        if len(parts) >= 2 and parts[0].isdigit():
            yield int(parts[0]), parts


def load_polestar(addons):
    """Spawns are {npcID: [(uiMapID, era, [(x, y), ...])]}, x/y in map percent; era marks the Classic
    Era map frame (Forever moved some zones, so those points are converted in game)."""
    spawns, names, trainers, factions, rares, era_frames = {}, {}, [], {}, set(), {}

    questdb = os.path.join(addons, "Polestar_QuestDB", "Npcs.lua")
    if os.path.exists(questdb):
        for block in re.findall(r"\[\[(.*?)\]\]", open(questdb).read(), re.S):
            for line in block.split("\n"):
                if "\t" not in line:
                    continue
                npc_id, rest = line.split("\t", 1)
                fields = rest.lstrip("'").split(";")
                names[int(npc_id)] = fields[0]
                maps, i = [], 1
                while i + 2 < len(fields):
                    map_id, frame, count = int(fields[i]), fields[i + 1], int(fields[i + 2])
                    vals = fields[i + 3 : i + 3 + count * 3]
                    points = [(float(vals[j]), float(vals[j + 1])) for j in range(0, len(vals) - 1, 3)]
                    maps.append((map_id, frame == "0", points))
                    i += 3 + count * 3
                if maps:
                    spawns[int(npc_id)] = maps

    files = [(p, "npc") for p in sorted(glob.glob(os.path.join(addons, "Polestar_Codex", "Npcs*.lua")))]
    files.append((os.path.join(addons, "Polestar_Codex", "Rares1.lua"), "rare"))
    for path, kind in files:
        if not os.path.exists(path):
            continue
        for npc_id, parts in codex_records(path, kind):
            if kind == "rare":
                rares.add(npc_id)
            if len(parts) >= 3 and parts[1] == "":
                names.setdefault(npc_id, parts[2])
                continue
            fields = parts[1].split(";")
            if len(fields) > 2 and fields[2] in ("A", "H"):
                factions[npc_id] = fields[2]
            if "tPet Trainer" in fields:
                trainers.append(npc_id)
            if npc_id in spawns:
                continue
            maps = []
            for f in fields:
                m = re.match(r"^(\d+),(e?),([\d,]+)$", f)
                if m:
                    nums = [int(n) for n in m.group(3).split(",")]
                    points = [(nums[j] / 10, nums[j + 1] / 10) for j in range(0, len(nums) - 1, 2)]
                    maps.append((int(m.group(1)), m.group(2) == "e", points))
            if maps:
                spawns[npc_id] = maps

    for path in [os.path.join(addons, "Polestar_QuestDB", "MapFrames.lua"),
                 os.path.join(addons, "Polestar", "Core", "ClassTrainers.lua")]:
        if os.path.exists(path):
            for m in re.finditer(r"\[(\d+)\]\s*=\s*\{([^}]*)\}", open(path).read()):
                vals = dict(re.findall(r"(\w+)=(-?[\d.]+)", m.group(2).replace(" ", "")))
                if all(k in vals for k in ("c", "left", "right", "top", "bottom")):
                    era_frames.setdefault(int(m.group(1)), vals)
    return spawns, names, trainers, factions, rares, era_frames


# ---------------------------------------------------------------------------- Lua output


def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def lua_spawns(maps):
    out = []
    for map_id, era, points in maps:
        coords = ",".join("%.1f,%.1f" % p for p in points[:12])
        out.append("{%d,%s,%s}" % (map_id, "true" if era else "false", coords))
    return "{" + ",".join(out) + "}"


HEADER = "-- Generated by tools/build_pets_data.py from Petopia (wow-petopia.com/forever) and Polestar's NPC data.\n" \
         "-- Do not edit by hand: rerun the script.\n\nlocal _, ns = ...\n\n"


def write(name, body):
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, name), "w") as f:
        f.write(HEADER + body)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--refresh", action="store_true", help="re-download Petopia pages")
    parser.add_argument("--addons", default=DEFAULT_ADDONS, help="Forever Interface/AddOns folder")
    args = parser.parse_args()

    families = parse_families(args.refresh)
    abilities, npcs = parse_abilities(args.refresh)
    special = parse_special(args.refresh)
    spawns, names, trainer_ids, factions, polestar_rares, era_frames = load_polestar(args.addons)
    if not spawns:
        sys.exit("No Polestar NPC data found under " + args.addons)

    family_by_single = {}
    for fam in families:
        single = {"Bats": "Bat", "Birds of Prey": "Bird of Prey", "Carrion Birds": "Carrion Bird",
                  "Foxes": "Fox", "Wolves": "Wolf"}.get(fam["name"], fam["name"][:-1])
        fam["single"] = single
        family_by_single[single] = fam["key"]

    by_name = {}
    for npc_id, npc in npcs.items():
        by_name.setdefault(npc["name"].lower(), []).append(npc_id)
    for npc_id, name in names.items():
        ids = by_name.setdefault(name.lower(), [])
        if npc_id not in ids:
            ids.append(npc_id)

    next_fake = -1
    for pet in special:
        subtitle = re.match(r"^(.*?)\s*<(.*)>$", pet["name"])
        if subtitle:
            pet["name"], pet["subtitle"] = subtitle.groups()
        key = pet["name"].lower()
        ids = by_name.get(key, [])
        npc_id = next((i for i in ids if i in npcs), None) or next((i for i in ids if i in spawns), None) \
            or (ids[0] if ids else None)
        if npc_id is None:
            npc_id, next_fake = next_fake, next_fake - 1
            by_name[key] = [npc_id]
        npc = npcs.setdefault(npc_id, {"id": npc_id, "name": pet["name"], "levels": pet["levels"], "zone": pet["zone"]})
        if pet.get("subtitle"):
            npc["subtitle"] = pet["subtitle"]
        npc["familyKey"] = pet["family"]
        npc.setdefault("lists", set()).add(pet["list"])
        npc.setdefault("tags", set()).update(pet["tags"])
        if pet["look"]:
            npc["look"] = pet["look"]
        if pet["note"]:
            npc["note"] = pet["note"]
        if not pet["tameable"]:
            npc["untameable"] = True
    for npc in npcs.values():
        npc.setdefault("familyKey", family_by_single.get(npc.get("family", ""), ""))
        if npc["id"] in polestar_rares:
            npc.setdefault("tags", set()).add("rare")

    # Families
    lines = ["ns.families = {"]
    for fam in families:
        lines.append("\t{ key = %s, name = %s, single = %s, role = %s, icon = %s, diet = %s, active = { %s }, passive = { %s } }," % (
            lua_str(fam["key"]), lua_str(fam["name"]), lua_str(fam["single"]), lua_str(fam["role"]),
            lua_str(fam["icon"]), lua_str(fam["diet"]),
            ", ".join(lua_str(a) for a in fam["active"]), ", ".join(lua_str(a) for a in fam["passive"])))
    lines.append("}\n")
    write("Families.lua", "\n".join(lines))

    # Abilities
    lines = ["ns.abilities = {"]
    for ab in abilities:
        fams = "true" if ab["families"] == "all" else "{ " + ", ".join(lua_str(f) for f in ab["families"]) + " }"
        lines.append("\t{")
        lines.append("\t\tkey = %s, name = %s, icon = %s, trainer = %s, families = %s," % (
            lua_str(ab["key"]), lua_str(ab["name"]), lua_str(ab["icon"]), "true" if ab["trainer"] else "false", fams))
        lines.append("\t\tdesc = %s," % lua_str(ab["desc"]))
        lines.append("\t\tranks = {")
        for r in ab["ranks"]:
            lines.append("\t\t\t{ rank = %d, level = %d, tp = %d, source = %s, desc = %s, npcs = { %s } }," % (
                r["rank"], r["level"], r["tp"], lua_str(r["source"]), lua_str(r["desc"]),
                ", ".join(str(i) for i in r["npcs"])))
        lines.append("\t\t},")
        lines.append("\t},")
    lines.append("}\n")
    write("Abilities.lua", "\n".join(lines))

    # NPCs (beasts)
    located = 0
    lines = ["ns.npcs = {"]
    for npc_id in sorted(npcs):
        npc = npcs[npc_id]
        fields = ["n = " + lua_str(npc["name"]), "f = " + lua_str(npc.get("familyKey", "")),
                  "lv = " + lua_str(npc.get("levels", "")), "z = " + lua_str(npc.get("zone", ""))]
        if npc_id in spawns:
            fields.append("s = " + lua_spawns(spawns[npc_id]))
            located += 1
        tags = sorted(npc.get("tags", set()))
        if tags:
            fields.append("tags = { %s }" % ", ".join("%s = true" % t for t in tags))
        lists = sorted(npc.get("lists", set()))
        if lists:
            fields.append("lists = { %s }" % ", ".join("%s = true" % l for l in lists))
        if npc.get("subtitle"):
            fields.append("sub = " + lua_str(npc["subtitle"]))
        if npc.get("look"):
            fields.append("look = " + lua_str(npc["look"]))
        if npc.get("note"):
            fields.append("note = " + lua_str(npc["note"]))
        if npc.get("untameable"):
            fields.append("untameable = true")
        lines.append("\t[%d] = { %s }," % (npc_id, ", ".join(fields)))
    lines.append("}\n")
    write("Npcs.lua", "\n".join(lines))

    # Pet trainers
    lines = ["ns.trainers = {"]
    for npc_id in sorted(set(trainer_ids)):
        if npc_id not in spawns:
            continue
        lines.append("\t[%d] = { n = %s, faction = %s, s = %s }," % (
            npc_id, lua_str(names.get(npc_id, "Pet Trainer")), lua_str(factions.get(npc_id, "")), lua_spawns(spawns[npc_id])))
    lines.append("}\n")
    write("Trainers.lua", "\n".join(lines))

    # Era map bounds (world yards) for every map an Era-frame point uses
    used = set()
    for npc_id in list(npcs) + trainer_ids:
        for map_id, era, _ in spawns.get(npc_id, []):
            if era:
                used.add(map_id)
    lines = ["ns.eraMapFrames = {"]
    for map_id in sorted(used):
        b = era_frames.get(map_id)
        if b:
            lines.append("\t[%d] = { c = %s, left = %s, right = %s, top = %s, bottom = %s }," % (
                map_id, b["c"], b["left"], b["right"], b["top"], b["bottom"]))
        else:
            print("warning: no Era bounds for map %d" % map_id)
    lines.append("}\n")
    write("MapFrames.lua", "\n".join(lines))

    print("families %d, abilities %d, beasts %d (%d with coordinates), special pets %d, trainers %d" % (
        len(families), len(abilities), len(npcs), located, len(special), len(set(trainer_ids))))


if __name__ == "__main__":
    main()
