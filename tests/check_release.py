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


items = json.loads((ROOT / "docs" / "si_items.json").read_text(encoding="utf-8"))
codes = [i["code"] for i in items]
check(len(codes) == len(set(codes)), "si_items.json: duplicate codes")

# switches : every item >= 200 is a position of a generated switch, with the same word
switches = (ROOT / "src" / "A339_pm_2_switches.lua").read_text(encoding="utf-8")
lua_pos = {}
for block in re.finditer(r'code = (\d+), pos = \{(.*?)\n\t\} \}', switches, re.S):
    for k, word in enumerate(re.findall(r'\{ word = "([^"]+)"', block.group(2))):
        lua_pos[int(block.group(1)) + k] = word
for i in items:
    if i["code"] >= 200:
        check(lua_pos.get(i["code"]) == i["response"], "item %s %s %s: not the Lua position %s"
              % (i["code"], i["challenge"], i["response"], lua_pos.get(i["code"])))

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
for c in sorted(sent):
    check(c in codes, "bridge sends ORDER|%d : no such item" % c)

# the Checklist Tuner collection : its importer's rules (app.js confirmImportJson), what SayIntentions accepts
col = make_release.collection()
text = json.dumps(col, indent=2)
check(len(text.encode("utf-8")) < 1024 * 1024, "collection: over the 1 MB import limit")
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
        check(not re.search(r"[<>]", it["checklist_item"] + it["response_visual_only"]), "markup in an item")
        for v in it["variables"]:
            check(v["variable_name"] == "SpeedyCopilot/si/order" and v["variable_category"] == "DREF"
                  and v["variable_type"] == "action", "item variable")
            seen.append(int(v["action_value"]))
check(sorted(seen) == sorted(codes), "collection: the PM ACTIONS codes are not exactly the items")
committed = ROOT / "ChecklistTuner" / "A339_PM_collection.json"
if committed.exists():
    old = json.loads(committed.read_text(encoding="utf-8"))
    old["notes"] = col["notes"] = ""
    check(old == col, "ChecklistTuner/A339_PM_collection.json is stale: run tools/make_release.py")

# the release archive : what a pilot needs, nothing private
for archive in sorted((ROOT / "dist").glob("*.zip")):
    with zipfile.ZipFile(archive) as z:
        names = z.namelist()
        for need in ("FlyWithLua/Scripts/A339_pm_1_core.lua", "FlyWithLua/Scripts/A339_pm_2_switches.lua",
                     "FlyWithLua/Scripts/A339_pm_3_procedures.lua", "FlyWithLua/Scripts/A339_pm/si_bridge.ps1",
                     "FlyWithLua/Scripts/A339_pm/run_hidden.vbs", "FlyWithLua/Scripts/A339_pm/si_items.json",
                     "ChecklistTuner/A339_PM_collection.json", "README.md", "COMMANDS.txt"):
            check(any(n.endswith(need) for n in names), "%s: missing %s" % (archive.name, need))
        for n in names:
            check(not re.search(r"si_dev_key\.txt$|\.log$|_log\.txt$|status\.txt$|flight_state", n),
                  "%s: private file %s" % (archive.name, n))
            body = z.read(n).decode("utf-8", "ignore")
            check(not re.search(r"C:[\\/]+Users[\\/]+\w+", body), "%s: %s has a personal path" % (archive.name, n))

for e in errors:
    print("FAIL  " + e)
print("check_release: %d items, %d checklists, %d errors" % (len(items), len(col["checklists"]), len(errors)))
sys.exit(1 if errors else 0)
