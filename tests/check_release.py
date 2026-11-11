"""Consistency checks without X-Plane : items <-> Lua codes <-> bridge, the Checklist Tuner collection (its own
import rules), and the release archive (no key, no log, no personal path). Run by tests/run_tests.ps1."""
import json
import re
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import make_release  # noqa: E402  (reads docs/si_items.json)

errors = []


def check(ok, text):
    if not ok:
        errors.append(text)


# the PM ACTIONS items of each aircraft (si_items.json : the A339)
ITEM_FILES = {"A339": "si_items.json", "A321": "si_items_A321.json"}
items_of = {ac: json.loads((ROOT / "docs" / f).read_text(encoding="utf-8")) for ac, f in ITEM_FILES.items()}
items = items_of["A339"]
codes = [i["code"] for i in items]

# switches : every item >= 200 is a position of that aircraft's generated switch, with the same word
switches = (ROOT / "src" / "A339_pm_2_switches.lua").read_text(encoding="utf-8")
for ac, its in items_of.items():
    check(len({i["code"] for i in its}) == len(its), "%s items: duplicate codes" % ac)
    table = re.search(r'\n\t%s = \{(.*?)\n\t\},' % ac, switches, re.S)
    check(table is not None, "switches Lua: no %s table" % ac)
    lua_pos = {}
    for block in re.finditer(r'code = (\d+), pos = \{(.*?)\n\t\t\} \}', table.group(1) if table else "", re.S):
        for k, word in enumerate(re.findall(r'\{ word = "([^"]+)"', block.group(2))):
            lua_pos[int(block.group(1)) + k] = word
    for i in its:
        if i["code"] >= 200:
            check(lua_pos.get(i["code"]) == i["response"], "%s item %s %s %s: not the Lua position %s"
                  % (ac, i["code"], i["challenge"], i["response"], lua_pos.get(i["code"])))
    check(set(i["code"] for i in its if i["code"] < 200) == set(c for c in codes if c < 200),
          "%s: the PF order / procedure items differ from the A339" % ac)

# procedures, flaps, gear, value items : registered in the Lua
procs = (ROOT / "src" / "A339_pm_3_procedures.lua").read_text(encoding="utf-8")
proc_ids = dict((int(c), p) for c, p in re.findall(r'proc\((\d+), "(\w+)"', procs))
core = (ROOT / "src" / "A339_pm_1_core.lua").read_text(encoding="utf-8")
for i in items:
    c = i["code"]
    if 100 <= c < 200:
        check(c in proc_ids, "procedure item %s %s: no proc() in the Lua" % (c, i["challenge"]))
    elif c in (10, 11, 12, 13, 14):
        check("PM_register_code(9 + i" in core, "flaps codes not registered")
    elif c in (20, 21):
        check("PM_register_code(20" in core or "PM_register_code(2" in core, "gear codes not registered")

# the bridge only starts procedures that exist
bridge = (ROOT / "src" / "A339_pm" / "si_bridge.ps1").read_text(encoding="utf-8")
table = re.search(r'\$PROCEDURES = \[ordered\]@\{(.*?)\n\}', bridge, re.S).group(1)
named = set(re.findall(r'= "(\w+)"', table)) | {"engine_start", "engine_start_21", "engine_start_12",
                                                   "engine_start_abort", "go_around"}
for p in sorted(named):
    check(p in proc_ids.values(), "bridge starts proc/%s : no such procedure" % p)
# ... and only sends order codes that exist ("ORDER|1510", the flaps table, "{ 1930 }" in the light choices)
sent = set(int(c) for c in re.findall(r'ORDER\|(\d+)', bridge))
sent |= set(int(c) for c in re.findall(r'"\w+" = (\d+)', re.search(r'\$FLAPS = @\{(.*?)\}', bridge, re.S).group(1)))
sent |= set(int(c) for c in re.findall(r'\{ (\d{2,4}) \}', bridge))
for ac, its in items_of.items():
    for c in sorted(sent):
        check(c in {i["code"] for i in its}, "bridge sends ORDER|%d : no such %s item" % (c, ac))

# the Checklist Tuner collections : their importer's rules (app.js confirmImportJson), what SayIntentions accepts
for ac, its in items_of.items():
  col = make_release.collection(ac)
  text = json.dumps(col, indent=2)
  check(len(text.encode("utf-8")) < 1024 * 1024, "%s collection: over the 1 MB import limit" % ac)
  seen = []
  for cl in col["checklists"]:
    check(cl["category"] in ("normal", "emergency", "supplemental", "abnormal"), "%s: bad category" % cl["name"])
    check(len(cl["name"]) <= 256 and len(cl["notes"]) <= 1024, "%s: name / notes too long" % cl["name"])
    if cl["name"].startswith("PM ACTIONS"):
        check(len(cl["items"]) <= 76, "%s: %d items (SayIntentions ignored a 290-item list)" % (cl["name"], len(cl["items"])))
    for it in cl["items"]:
        check(it["checklist_item_type"] in ("Basic CR", "No CR", "Advanced CR", "Full Automatic"), "bad item type")
        check(it["speak_response"] in (-1, 0, 1), "bad speak_response")
        check(0 < len(it["checklist_item"]) <= 512 and len(it["response_visual_only"]) <= 256, "item text length")
        # the importer cuts the reply lists at 256 characters
        check(len(it["accepted_pos_reply"]) <= 256 and len(it["accepted_neg_reply"]) <= 256,
              "%s %s: accepted replies over 256 characters" % (cl["name"], it["checklist_item"]))
        if it["checklist_item_type"] == "Advanced CR":
            check(it["accepted_pos_reply"].strip() != "", "%s %s: Advanced CR without accepted replies" % (cl["name"], it["checklist_item"]))
        check(not re.search(r"[<>]", it["checklist_item"] + it["response_visual_only"]), "markup in an item")
        for v in it["variables"]:
            check(v["variable_name"] == "SpeedyCopilot/si/order" and v["variable_category"] == "DREF"
                  and v["variable_type"] == "action", "item variable")
            seen.append(int(v["action_value"]))
  check(sorted(seen) == sorted(i["code"] for i in its), "%s collection: the PM ACTIONS codes are not exactly the items" % ac)
  committed = ROOT / "ChecklistTuner" / ("%s_PM_collection.json" % ac)
  if committed.exists():
    old = json.loads(committed.read_text(encoding="utf-8"))
    old["notes"] = col["notes"] = ""
    check(old == col, "ChecklistTuner/%s_PM_collection.json is stale: run tools/make_release.py" % ac)

# the release archive just built (older ones in dist/ are already published) : what a pilot needs, nothing private
for archive in sorted((ROOT / "dist").glob("*.zip"), key=lambda p: p.stat().st_mtime)[-1:]:
    with zipfile.ZipFile(archive) as z:
        names = z.namelist()
        for need in ("FlyWithLua/Scripts/A339_pm_1_core.lua", "FlyWithLua/Scripts/A339_pm_2_switches.lua",
                     "FlyWithLua/Scripts/A339_pm_3_procedures.lua", "FlyWithLua/Scripts/A339_pm/si_bridge.ps1",
                     "FlyWithLua/Scripts/A339_pm/run_hidden.vbs", "FlyWithLua/Scripts/A339_pm/si_items.json",
                     "FlyWithLua/Scripts/A339_pm/si_items_A321.json",
                     "ChecklistTuner/A339_PM_collection.json", "ChecklistTuner/A321_PM_collection.json",
                     "README.md", "COMMANDS.txt"):
            check(any(n.endswith(need) for n in names), "%s: missing %s" % (archive.name, need))
        for n in names:
            check(not re.search(r"si_dev_key\.txt$|\.log$|_log\.txt$|status\.txt$|flight_state", n),
                  "%s: private file %s" % (archive.name, n))
            body = z.read(n).decode("utf-8", "ignore")
            check(not re.search(r"C:[\\/]+Users[\\/]+\w+", body), "%s: %s has a personal path" % (archive.name, n))

for e in errors:
    print("FAIL  " + e)
print("check_release: %s, %d errors" % (", ".join("%s %d items" % (ac, len(its)) for ac, its in items_of.items()), len(errors)))
sys.exit(1 if errors else 0)
