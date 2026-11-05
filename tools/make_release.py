"""Builds the A339 PM release from this repository.

    python tools/make_release.py [version]

Writes COMMANDS.txt, ChecklistTuner/A339_PM_collection.json (Checklist Tuner "Import JSON") and
dist/A339-SayIntentions-PM-<version>.zip (what a pilot downloads: FlyWithLua/Scripts + ChecklistTuner + docs).
src/A339_pm_2_switches.lua and docs/si_items.json come from tools/cockpit_map.py.
"""
import json
import shutil
import sys
import zipfile
from pathlib import Path

VERSION = sys.argv[1] if len(sys.argv) > 1 else "dev"
ROOT = Path(__file__).resolve().parent.parent
DIST = ROOT / "dist"
PACKAGE = DIST / "A339-SayIntentions-PM"
ITEMS = json.loads((ROOT / "docs" / "si_items.json").read_text(encoding="utf-8"))

# the PM's normal A330 checklists : [challenge, response, challenge spoken, response spoken] (spoken forms, or the PM spells
# "T.O RWY" letter by letter). Named "... Checklist" so that "<name> procedure" is never taken for a checklist.
NORMAL = {
    "Cockpit Preparation": [["GEAR PINS AND COVERS", "REMOVED", "Gear pins and covers", "Removed"], ["FUEL QUANTITY", "CHECKED", "Fuel quantity", "Checked"], ["SEAT BELTS", "ON", "Seat belts", "On"], ["ADIRS", "NAV", "Adirs", "Nav"], ["BARO REF", "SET (BOTH)", "Baro reference", "Set, both"]],
    "Before Start": [["PARKING BRAKE", "SET", "Parking brake", "Set"], ["T.O SPEEDS AND THRUST", "CHECKED (BOTH)", "Takeoff speeds and thrust", "Checked, both"], ["WINDOWS", "CLOSED (BOTH)", "Windows", "Closed, both"], ["BEACON", "ON", "Beacon", "On"]],
    "After Start": [["ANTI ICE", "AS REQUIRED", "Anti ice", "As required"], ["ECAM STATUS", "CHECKED", "Ecam status", "Checked"], ["PITCH TRIM", "SET", "Pitch trim", "Set"], ["RUDDER TRIM", "NEUTRAL", "Rudder trim", "Neutral"]],
    "Taxi": [["FLIGHT CONTROLS", "CHECKED (BOTH)", "Flight controls", "Checked, both"], ["FLAPS SETTING", "CONF ___ (BOTH)", "Flaps setting", "Set, both"], ["RADAR AND PRED W/S", "ON AND AUTO", "Weather radar and predictive windshear", "On and auto"], ["ENG MODE SEL", "AS REQUIRED", "Engine mode selector", "As required"], ["ECAM MEMO", "CHECKED", "Ecam memo", "Checked"]],
    "Lineup": [["T.O RWY", "CONFIRMED (BOTH)", "Takeoff runway", "Confirmed, both"], ["TCAS", "TA OR TA/RA", "Tee cas", "T A, or T A, R A"], ["PACKS 1 AND 2", "AS REQUIRED", "Packs one and two", "As required"]],
    "Departure Change": [["RWY AND SID", "CONFIRMED", "Runway and sid", "Confirmed"], ["FLAPS SETTING", "CONF ___ (BOTH)", "Flaps setting", "Set, both"], ["T.O SPEEDS AND THRUST", "CHECKED (BOTH)", "Takeoff speeds and thrust", "Checked, both"], ["FCU ALT", "SET", "Selected altitude", "Set"]],
    "Approach": [["BARO REF", "SET (BOTH)", "Baro reference", "Set, both"], ["SEAT BELTS", "ON", "Seat belts", "On"], ["MINIMUM", "SET", "Minimum", "Set"], ["AUTO BRAKE", "AS REQUIRED", "Autobrake", "As required"], ["ENG MODE SEL", "AS REQUIRED", "Engine mode selector", "As required"]],
    "Landing": [["GO AROUND ALTITUDE", "SET", "Go around altitude", "Set"], ["CABIN CREW", "ADVISED", "Cabin crew", "Advised"], ["ECAM MEMO", "CHECKED", "Ecam memo", "Checked"]],
    "After Landing": [["RADAR AND PRED W/S", "OFF", "Weather radar and predictive windshear", "Off"]],
    "Parking": [["PARK BRAKE OR CHOCKS", "SET", "Parking brake or chocks", "Set"], ["ENGINES", "OFF", "Engines", "Off"], ["WING LIGHTS", "OFF", "Wing lights", "Off"], ["FUEL PUMPS", "OFF", "Fuel pumps", "Off"]],
    "Securing the Aircraft": [["OXYGEN", "OFF", "Oxygen", "Off"], ["EMER EXIT LT", "OFF", "Emergency exit lights", "Off"], ["EFBs", "OFF", "Tablets", "Off"], ["BATTERIES", "OFF", "Batteries", "Off"]],
}
NORMAL_NOTES = ("Run this checklist only when the pilot says the word checklist. A request that says procedure is never "
                "this checklist: it is the PROCEDURE / START item in PM ACTIONS.")
PM_CHUNK = 70  # one SayIntentions checklist of 290 items never worked; up to ~76 do


def collection():
    """The Checklist Tuner collection, in its own export format (Import JSON)."""
    checklists = []
    for n, (name, rows) in enumerate(NORMAL.items(), 1):
        checklists.append({
            "name": name + " Checklist", "category": "normal", "full_auto": 0, "notes": NORMAL_NOTES, "sort_order": n,
            "admin_disabled": 0,
            "items": [{"checklist_item": c, "checklist_item_pronounced": cp, "checklist_item_type": "Basic CR",
                       "accepted_reply": "Any Positive", "accepted_pos_reply": "", "accepted_neg_reply": "",
                       "response_visual_only": r, "speak_response": 0, "response_pronounced": rp,
                       "speak_pause_seconds": 0, "sort_order": k, "admin_disabled": 0, "variables": []}
                      for k, (c, r, cp, rp) in enumerate(rows, 1)]})
    for part in range(0, len(ITEMS), PM_CHUNK):
        chunk = ITEMS[part:part + PM_CHUNK]
        checklists.append({
            "name": "PM ACTIONS %d" % (part // PM_CHUNK + 1), "category": "abnormal", "full_auto": 0,
            "notes": "Never run as a checklist: these items tell the PM what it can do in the cockpit.",
            "sort_order": len(checklists) + 1, "admin_disabled": 0,
            "items": [{"checklist_item": i["challenge"], "checklist_item_pronounced": "",
                       "checklist_item_type": "Full Automatic", "accepted_reply": "", "accepted_pos_reply": "",
                       "accepted_neg_reply": "", "response_visual_only": i["response"], "speak_response": 1,
                       "response_pronounced": "", "speak_pause_seconds": 0, "sort_order": k, "admin_disabled": 0,
                       "variables": [{"variable_name": "SpeedyCopilot/si/order", "variable_category": "DREF",
                                      "variable_type": "action", "action_value": str(i["code"]),
                                      "validation_low": None, "validation_high": None}]}
                      for k, i in enumerate(chunk, 1)]})
    return {"__export_version": 1, "name": "A339 PM - SayIntentions co-pilot",
            "notes": "A339 PM %s: the PM's normal A330 checklists and the PM ACTIONS items (cockpit actions)." % VERSION,
            "shared": 0, "admin_disabled": 0, "checklists": checklists}


def commands():
    """COMMANDS.txt : everything the co-pilot (the bridge) understands."""
    groups = {}
    for i in ITEMS:
        groups.setdefault(i["challenge"], []).append(i)
    out = [
        "A339 PM %s - what you can say to the SayIntentions co-pilot (intercom)" % VERSION,
        "=" * 78, "",
        "Say it naturally: 'landing lights on', 'turn off the seat belts', 'strobe on, landing lights off'.",
        "The bridge finds the item in your words; if it finds nothing, it looks at the PM's answer",
        "('Sure, setting pack flow high'). Several orders in one phrase: separate them with a comma or 'and'.",
        "Nothing is done for questions ('are the landing lights on?'), negations ('don't ...'),",
        "requests to ATC ('ask ATC for flight level 350') or checklist answers ('check', 'set').", "",
        "PROCEDURES  (say the word 'procedure'; the word 'checklist' starts the PM's own checklist instead)",
        "-" * 78,
        "  preliminary cockpit preparation procedure     on ground (batteries, APU BAT, ext power, oxygen, tests)",
        "  cockpit preparation procedure                 on ground (fuel pumps, packs, ADIRS NAV, lights, signs)",
        "  before start procedure                        door, APU bleed (APU available), seat belts, XPDR, beacon",
        "  engine start procedure [sequence two one]     asks 'Confirm engine start, sequence 2 1?' -> 'confirm'",
        "  abort engine start / stop engine start",
        "  after start procedure                         ENG MODE NORM, spoilers ARM, X BLEED AUTO",
        "  taxi procedure                                FD, radar, PWS, autobrake MAX, T.O CONFIG, APU off",
        "  line up procedure                             XPDR, TCAS TA RA, lights, brake fans off, packs off",
        "  after takeoff procedure                       above 400 ft: spoilers disarm, lights, APU off, packs on",
        "  climb procedure                               landing lights off, seat belts AUTO, terrain off",
        "  descent preparation procedure                 above FL100: constraints on ND",
        "  descent procedure                             landing lights, seat belts ON, terrain on",
        "  approach procedure                            spoilers ARM, turn off lights, nose light T.O",
        "  go around / going around / missed approach    below 2500 ft AGL: flaps one step up, gear up at",
        "                                                positive climb, after takeoff items (packs untouched)",
        "  after landing procedure                       flaps 0, spoilers disarm, lights, radar/PWS off, ...",
        "  parking procedure                             engines off + parking brake: beacon off, fuel pumps off ...",
        "  securing the aircraft procedure               ADIRS off, oxygen off, APU off, batteries off",
        "  The PM reports '<name> procedure done.' A procedure never sets SEAT BELTS or PED to OFF.", "",
        "FLAPS, GEAR (one flap step at a time, VFE / S / F speed checks)",
        "-" * 78,
        "  flaps up / zero / one / two / three / full     gear up / gear down", "",
        "FCU, ALTIMETERS, TRANSPONDER (numbers)",
        "-" * 78,
        "  heading 175 [pull|push]          in flight: set and pulled (selected)",
        "  speed 250 [pull|push] / mach 0.78 / speed managed",
        "  flight level 350 / altitude 5000 [push|pull]   in flight: set and pushed (managed)",
        "  QNH 1013 / altimeter 29.92       baro out of STD          baro standard / set baro STD",
        "  squawk 4721", "",
        "ATC INSTRUCTIONS  (only when the PM handles the radio)",
        "-" * 78,
        "  Nothing to say: what ATC assigns is set by itself - heading (pulled), altitude / FL (pushed),",
        "  speed / mach, QNH / altimeter (left on STD above the transition), squawk.",
        "  When YOU handle the radio, ATC instructions are not set: tell the PM ('heading 110') or set them.",
        "  'Request flight level 370' (to the PM, for ATC) sets nothing until ATC clears it.", "",
        "OTHER",
        "-" * 78,
        "  start APU                        the START button 5 s after APU MASTER",
        "  APU bleed on                     waits for APU AVAIL; refused above FL200 with packs on",
        "  all anti ice on / off            engine and wing anti ice", "",
        "EVERY SWITCH  (name : positions)   e.g. 'seat belts on', 'TCAS TA RA', 'captain wiper slow'",
        "-" * 78,
    ]
    for name, items in groups.items():
        if items[0]["code"] < 200:
            continue
        out.append("  %-44s %s" % (name.lower(), " / ".join(i["response"].lower() for i in items)))
    out += ["", "UNDERSTOOD ALSO  (other names and speech recognition slips)", "-" * 78,
            "  seatbelts, sit belts = seat belt signs        no portable devices, PED = no portable electronic devices",
            "  nav lights, logo lights = nav and logo lights interior light = dome light (on = bright)",
            "  linden lights = landing lights                wind lights = wing lights",
            "  left / right wiper = captain / first officer wiper, viper = wiper",
            "  ADIRS / aders / adios = ADIRS                 navigation = nav, attitude = att",
            "  TCAS: TA RA, TA only, standby                 transponder off = standby",
            "  spoilers, speed brakes = ground spoilers      x bleed = cross bleed, x feed = fuel crossfeed",
            "  park brake on / off = set / release           FD = flight directors",
            "  baro, borrow, borough = barometers (STD = standard)     Q&A = QNH",
            "  flips, laps, claps, clips, lips = flaps       tree = three, four = full",
            "  puckflow, pakflow, backflow = pack flow       pack flow auto = normal",
            "  API = APU                                     girdown = gear down",
            "  flat level = flight level                     the scent = descent",
            "  lock / unlock the cockpit door = close / open"]
    return "\n".join(out) + "\n"


def main():
    (ROOT / "COMMANDS.txt").write_text(commands(), encoding="utf-8")
    (ROOT / "ChecklistTuner").mkdir(exist_ok=True)
    (ROOT / "ChecklistTuner" / "A339_PM_collection.json").write_text(json.dumps(collection(), indent=2), encoding="utf-8")
    if PACKAGE.exists():
        shutil.rmtree(PACKAGE)
    scripts = PACKAGE / "FlyWithLua" / "Scripts"
    (scripts / "A339_pm").mkdir(parents=True)
    for f in ("A339_pm_1_core.lua", "A339_pm_2_switches.lua", "A339_pm_3_procedures.lua"):
        shutil.copy(ROOT / "src" / f, scripts / f)
    for f in ("si_bridge.ps1", "run_hidden.vbs"):
        shutil.copy(ROOT / "src" / "A339_pm" / f, scripts / "A339_pm" / f)
    shutil.copy(ROOT / "docs" / "si_items.json", scripts / "A339_pm" / "si_items.json")
    (scripts / "A339_pm" / "PUT si_dev_key.txt HERE.txt").write_text(
        "Create a file named si_dev_key.txt in this folder containing only your SayIntentions developer key.\n"
        "See README.md, step 2.\n", encoding="utf-8")
    shutil.copytree(ROOT / "ChecklistTuner", PACKAGE / "ChecklistTuner")
    for f in ("README.md", "LICENSE", "COMMANDS.txt"):
        if (ROOT / f).exists():
            shutil.copy(ROOT / f, PACKAGE / f)
    archive = DIST / ("A339-SayIntentions-PM-%s.zip" % VERSION)
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as z:
        for p in sorted(PACKAGE.rglob("*")):
            if p.is_file():
                z.write(p, Path(PACKAGE.name) / p.relative_to(PACKAGE))
    n = sum(len(c["items"]) for c in collection()["checklists"])
    print("release %s : %d collection items, %s" % (VERSION, n, archive))


if __name__ == "__main__":
    main()
