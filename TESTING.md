# Testing a release

Four levels, from cheap to real. A release is published only when 1–3 pass; 4 is done on one real flight.

## 1. Automatic (every commit, GitHub Actions)

`powershell -File tests/run_tests.ps1` — no X-Plane needed:

- **bridge phrases** (`tests/bridge_phrases.tsv`): 300+ phrases from real flights — commands, speech recognition
  slips, ATC instructions, the PM's answers, questions, negations, checklist answers — each with the action the bridge
  must find (or none);
- **consistency**: every item's order code exists in the Lua with the same position, every procedure the bridge can
  start exists, the bridge only sends known codes;
- **Checklist Tuner collection**: passes the importer's own rules (types, categories, lengths, 1 MB), ≤ 76 items per
  PM ACTIONS list, every code exactly once, the committed file is up to date;
- **release zip**: contains every file a pilot needs, and no developer key, log or personal path.

The Lua syntax is checked on Linux with `luac5.1 -p` (FlyWithLua runs LuaJIT, Lua 5.1 syntax).

## 2. Clean install (before a release, on a real X-Plane)

Do exactly what the README says, from the zip, as a new user would:

1. Move your current `A339_pm*` scripts and `A339_pm/` folder out of `FlyWithLua/Scripts` (keep them as a backup).
2. Download the zip from the release page, **Unblock**, extract, copy `FlyWithLua/Scripts`, put `si_dev_key.txt`.
3. Checklist Tuner: **Import JSON** as a *new* collection, activate it (the old one becomes Not Activated — it stays
   as a backup), save, **New Flight** in SayIntentions.
4. Load the A339 cold and dark. Expect in X-Plane `Log.txt`: `[A339 PM] loaded, UDP 49052`; in
   `Scripts/A339_pm/si_bridge_log.txt`: `SayIntentions bridge started` and `connected`.
5. Negative checks: rename `si_dev_key.txt` → the bridge log / status says *no developer key*; load another ToLiss
   aircraft → no `[A339 PM]` lines at all.

## 3. Smoke test in the sim (no voice)

Cold and dark on ground, scripts loaded. Send the bridge's own UDP messages to the PM (127.0.0.1:49052) — e.g.
`SI|SpeedyCopilot/proc/preliminary`, `SI|ORDER|1940` (landing lights on), `SI|PILOT|HDG|175`, `SI|PILOT|SQUAWK|4721`
— and read the result through the X-Plane web API (`http://localhost:8086/api/v2/datarefs`): switch arrays, FCU
heading, `AirbusFBW/XPDR1..4`. Check refusals too (`SI|ORDER|20` gear up on ground → `[A339 PM] ... We are on the
ground.`). Restore every value afterwards.

## 4. Voice flight

One short flight, saying each line of this list once on the intercom and comparing the bridge log
(`heard '…' -> …`) and `Log.txt` (`[A339 PM]`) with the expectation:

| Phase | Say | Expect |
|---|---|---|
| Cold & dark | preliminary cockpit preparation procedure | batteries, APU BAT, ext power, oxygen … *procedure done* |
| | cockpit preparation procedure | fuel pumps, packs, ADIRS NAV, seat belts ON … |
| | cockpit preparation checklist | **the PM's own** checklist starts (no procedure) |
| | start APU / APU bleed on | START 5 s after MASTER; bleed waits for AVAIL |
| | squawk 4721 / QNH 1013 / heading 175 | XPDR digits, both baros, FCU HDG (not pulled on ground) |
| | before start procedure | door, APU bleed, seat belts ON, XPDR, beacon |
| | engine start procedure → confirm | read back, then 2 then 1, *both engines running* |
| Taxi | after start procedure, taxi procedure, flaps one | … flaps 1 (one step) |
| | landing lights on, strobe on | single phrase, both done |
| Line up | line up procedure | packs off, TCAS TA RA, lights |
| Climb | gear up, after takeoff procedure, flaps up, climb procedure | seat belts AUTO, packs on |
| | flight level 220 and push / speed 250 | managed altitude / selected speed |
| Cruise | pack flow high; something said unclearly | the bridge or the PM's answer (`from the co-pilot's words` in the bridge log) |
| Descent | descent preparation procedure, descent procedure, approach procedure | seat belts ON, spoilers ARM |
| Approach | flaps one … full, gear down | VFE / 250 kt refusals when too fast, said by the PM |
| | go around (below 2500 ft AGL) | flaps one step up, gear up at positive climb |
| Ground | after landing procedure, parking procedure, securing the aircraft procedure | flaps 0, … |

Every phrase that went wrong becomes a line in `tests/bridge_phrases.tsv` before it is fixed.
