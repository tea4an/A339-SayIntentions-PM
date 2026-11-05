# A339 PM — a SayIntentions.AI co-pilot integration for the ToLiss A330-900

Fly the **ToLiss A330-900 (A339)** in **X-Plane 12** with the **SayIntentions.AI co-pilot as your pilot monitoring**.
You talk to her on the intercom like to a real PM — *"landing lights on"*, *"flaps one"*, *"taxi procedure"*,
*"heading 175"* — she answers, and the A339 PM does it in the cockpit, with the checks a PM would make.

- **275 switch positions on 125 cockpit controls** by voice: lights, signs, fuel, APU, air conditioning, anti-ice, ADIRS, EFIS, ECAM pages,
  TCAS / transponder, autobrake, FCU buttons, GPWS … (full list in [COMMANDS.txt](COMMANDS.txt)).
- **16 procedures** (flows) from preliminary cockpit preparation to securing the aircraft, including a full
  **engine start** (with a read back) and a **go around**. She reports *"Taxi procedure done."*
- **Flaps and gear** on the PF's order only, one flap step at a time, with VFE / S / F speed and positive climb checks.
- **FCU numbers** by voice: heading, speed / mach, altitude, QNH, squawk.
- **When she handles the radio, she flies the clearances too**: *"Turn left heading 110, descend and maintain 3,000,
  altimeter 30.24, squawk 5711"* — the FCU, both altimeters and the transponder are set as ATC says, without a word
  from you (see [ATC instructions](#atc-instructions-when-she-handles-the-radio)).
- **She refuses with a reason**, in her own voice: *"Unable. Speed above V F E, 196 knots."*
- Speech recognition slips are understood (*"Linden Lights Owen"*, *"Puckflow High"*, *"flat level 220"*), and when
  your words are unclear but her answer is right (*"Sure, setting pack flow high"*), her answer is used.
- Nothing on screen, no sounds of its own: SayIntentions does all the talking.

## How it works

```
you ──intercom PTT──▶ SayIntentions co-pilot (speech, conversation)
                         │  SAPI comms history: your words and her answer
                         ▼
               si_bridge.ps1 (hidden PowerShell, started by the Lua script)
                 finds the action in your words (or her answer) ──UDP──▶ A339_pm (FlyWithLua)
                 says the PM's refusals through her (SAPI sayAs)  ◀──────  checks speeds, ground / air,
                                                                            conditions → acts or refuses
```

Her **Checklist Tuner items** (the collection in `ChecklistTuner/`) tell her what she can do, so that she answers
correctly. The actions themselves are done by the bridge and the PM — they don't depend on her pressing an item.

## Requirements

- X-Plane 12 and the **ToLiss A330-900** (tested with V1.2.1).
- **FlyWithLua NG+** for X-Plane 12.
- **SayIntentions.AI** with the co-pilot.
- **Windows 10 / 11** (the bridge is a Windows PowerShell 5.1 script).
- A **SayIntentions developer key** (free, personal — see step 2).

## Installation

1. **Scripts.** Before extracting the zip: right-click it › *Properties* › tick **Unblock** › OK (Windows marks
   downloaded scripts and may block the hidden bridge). Copy the content of `FlyWithLua/Scripts/` into
   `X-Plane 12/Resources/plugins/FlyWithLua/Scripts/` — three `A339_pm_*.lua` files and the `A339_pm` folder.

2. **Developer key.** Sign in to the SayIntentions.AI pilot portal, open the **Developer Key** page and request a
   personal key (product: *A339 PM*, integration: *SAPI comms history and sayAs for my own flights*).
   Save the key alone in `Scripts/A339_pm/si_dev_key.txt`. It is yours: never share or publish it.

3. **Checklist Tuner.** Open <https://checklists.sayintentions.ai>, sign in, select (or add) your **A339** aircraft,
   click **Import JSON** and pick `ChecklistTuner/A339_PM_collection.json`. On the new collection click
   **Not Activated** so that it becomes **Activated** (the collection SayIntentions uses for the A339), then save.
   It contains her normal A330 checklists (with spoken forms) and the *PM ACTIONS 1–5* lists — never run those as
   checklists, they only teach her the cockpit.

4. **New Flight.** SayIntentions loads checklists only when a flight starts: press **New Flight** in the
   SayIntentions client after the import (and after any later change in Checklist Tuner).

5. **Fly.** Load the A339. The bridge starts by itself (hidden) and stops when X-Plane closes. After updating the
   scripts while flying: *Plugins › FlyWithLua › Reload all Lua script files*.

## Using it

Hold the **intercom** PTT and speak to her. See **[COMMANDS.txt](COMMANDS.txt)** for everything she understands.

- **Procedure or checklist** — *"taxi procedure"* runs the flow; *"taxi checklist"* starts her own checklist.
- **Engine start** is the only read back: *"engine start procedure"* → *"Confirm engine start, sequence 2 1?"* →
  *"confirm"* (or *"confirm, sequence one two"*).
- **Go around** (*"go around"*, *"missed approach"*) below 2500 ft AGL: flaps one step up, gear up at positive climb,
  after takeoff items.
- **FCU**: heading and speed are set and pulled, altitude set and pushed in flight; say *push* / *pull* to choose.

### ATC instructions when she handles the radio

When the SayIntentions co-pilot is in charge of the radio (you handed her the communications), the bridge reads
every ATC transmission and the PM sets what the controller assigns — the way a PM sets the clearance while the PF
flies:

| ATC says | The PM sets |
|---|---|
| *turn left heading 110* | FCU heading 110, pulled (selected) in flight |
| *climb FL360*, *descend and maintain 3,000* | FCU altitude, pushed (managed) in flight |
| *reduce speed 210*, *mach .78* | FCU speed / mach, pulled |
| *altimeter 30.24*, *QNH 1012* | both altimeters — left on STD if they are on STD (above the transition) |
| *squawk 5711* | the transponder code |

When **you** handle the radio, ATC instructions are only logged, never set: tell her (*"heading 110"*) or set them
yourself. Asking her to *request* something (*"request flight level 370"*) sets nothing until ATC clears it.

### Things it will never touch

Fire pushbuttons and agents, fuel jettison, IDG, ditching, RAM AIR, evacuation, passenger oxygen, PRIM / SEC,
MAN START, ADR / IR pushbuttons, gravity gear. Engine masters only inside the engine start procedure. A procedure
never switches SEAT BELTS or NO PORTABLE ELECTRONIC DEVICES off.

## Troubleshooting

| Symptom | Look at |
|---|---|
| Nothing happens at all | `Scripts/A339_pm/si_bridge_log.txt` — does it say `connected`? `No developer key file` → step 2. |
| She answers but nothing is done | the bridge log: `heard '…' -> -` means your words were not understood; tell us the phrase. |
| An action is refused | X-Plane `Log.txt`, lines `[A339 PM]` — the reason is also said by her. |
| She doesn't know an item / opens a checklist | step 4: New Flight after importing the collection. |
| ATC and co-pilot silent, PTT works | a SayIntentions service problem — nothing the bridge can do without your recognized words. |

## Development

| Path | What |
|---|---|
| `src/A339_pm_1_core.lua` | validation, flaps / gear, FCU values, the UDP link to the bridge |
| `src/A339_pm_2_switches.lua` | the switches — **generated** by `tools/cockpit_map.py` (edit the map, not this file) |
| `src/A339_pm_3_procedures.lua` | procedures, engine start, go around |
| `src/A339_pm/si_bridge.ps1` | the bridge: SAPI, phrase → action, her answers, sayAs |
| `docs/si_items.json` | every item (challenge, position, order code) — generated |
| `tools/make_release.py` | builds `COMMANDS.txt`, the Checklist Tuner collection and `dist/*.zip` |
| `tests/` | `run_tests.ps1`: 300+ real phrases with the expected action, and consistency checks |

```
python tools/cockpit_map.py              # after changing the switch map
python tools/make_release.py 2.3         # release files
powershell -File tests/run_tests.ps1     # must pass before a commit (also run by GitHub Actions)
```

A phrase that was misunderstood in flight: add it with the expected result to `tests/bridge_phrases.tsv`, fix the
aliases in `si_bridge.ps1`, run the tests.

## Privacy

The bridge talks only to the SayIntentions API (`apipri.sayintentions.ai`), with your developer key and the
`api_key` of your current flight (read from SayIntentions' own `flight.json`): it reads your flight's comms history
and asks her to say the PM's messages. Nothing else leaves your computer. The logs stay in `Scripts/A339_pm/`.

## Credits

Born as an A339 edition of *Speedy Copilot for ToLiSs* by Aérographe (Etalab Open Licence 2.0), then rewritten as a
lightweight SayIntentions PM. Not affiliated with ToLiss or SayIntentions.AI.
