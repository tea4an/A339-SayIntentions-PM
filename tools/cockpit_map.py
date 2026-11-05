"""A339 cockpit map : the single source of the switches the SayIntentions co-pilot may operate.

python tools/cockpit_map.py   writes
  src/A339_pm_2_switches.lua   the switches for FlyWithLua (order codes, no X-Plane command : FlyWithLua's limit)
  docs/si_items.json           her PM ACTIONS items (challenge, response, code) for Checklist Tuner v2
  docs/A339_pm_actions.md      the same, readable

Each switch : E(id, name, code, positions, **options). A position : P(word, actions..., **options).
Actions are Lua statements (helpers L, S, C, H below). Options : ground=True (refused in flight),
confirm="question?" (read back, done on "confirm"), confirm_in_flight="question?", check="lua function name".
Codes : a switch owns code .. code + 9 (one per position), never renumber a switch already in her checklist.
Values marked "# autotest" are to be checked in the sim. DANGEROUS elements (fire, jettison, IDG, ditching, RAM AIR,
masters, ADR / IR off, PRIM / SEC...) are not here on purpose.
"""
import json, os, re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def L(index, value):
    return f"light({index}, {value})"


def S(ref, value, index=None):
    return f'set_array("{ref}", {index}, {value})' if index is not None else f'set("{ref}", {value})'


def C(cmd):
    return f'command_once("{cmd}")'


def H(cmd, seconds=3):  # held : test buttons
    return f'PM_hold("{cmd}", {seconds})'


def P(word, *actions, **opts):
    return {"word": word, "actions": list(actions), **opts}


SWITCHES = []


def E(id, name, code, positions, **opts):
    SWITCHES.append({"id": id, "name": name, "code": code, "positions": positions, **opts})


# ---------------- ADIRS ----------------
for n, idx in ((1, 0), (2, 1), (3, 2)):
    E(f"adirs_{n}", f"ADIRS IR {n}", 1000 + 10 * (n - 1), [
        P("OFF", S("AirbusFBW/ADIRUSwitchArray", 0, idx), ground=True),
        P("NAV", S("AirbusFBW/ADIRUSwitchArray", 1, idx)),
        P("ATT", S("AirbusFBW/ADIRUSwitchArray", 2, idx))])  # ATT = 2 : range 0..2 (not written in the test : it would reset the alignment)
E("adirs_all", "ALL ADIRS", 1030, [
    P("OFF", *[S("AirbusFBW/ADIRUSwitchArray", 0, i) for i in range(3)], ground=True),
    P("NAV", *[S("AirbusFBW/ADIRUSwitchArray", 1, i) for i in range(3)]),
    P("ATT", *[S("AirbusFBW/ADIRUSwitchArray", 2, i) for i in range(3)])])

# ---------------- FIRE tests ----------------
E("apu_fire_test", "APU FIRE TEST", 1040, [P("TEST", H("AirbusFBW/FireTestAPU"), ground=True)])
E("eng1_fire_test", "ENGINE 1 FIRE TEST", 1050, [P("TEST", H("AirbusFBW/FireTestENG1"), ground=True)])
E("eng2_fire_test", "ENGINE 2 FIRE TEST", 1060, [P("TEST", H("AirbusFBW/FireTestENG2"), ground=True)])
E("cargo_smoke_test", "CARGO SMOKE TEST", 1070, [P("TEST", H("AirbusFBW/FireTestCargo"), ground=True)])

# ---------------- ELEC ----------------
for n, idx, code in ((1, 5, 1100), (2, 6, 1110)):
    E(f"bat_{n}", f"BATTERY {n}", code, [P("ON", S("AirbusFBW/ElecOHPArray", 1, idx)),
                                          P("OFF", S("AirbusFBW/ElecOHPArray", 0, idx), ground=True)])
E("batteries", "BATTERIES", 1120, [P("ON", S("AirbusFBW/ElecOHPArray", 1, 5), S("AirbusFBW/ElecOHPArray", 1, 6)),
                                    P("OFF", S("AirbusFBW/ElecOHPArray", 0, 5), S("AirbusFBW/ElecOHPArray", 0, 6), ground=True)])
E("apu_bat", "APU BATTERY", 1130, [P("ON", S("AirbusFBW/ElecOHPArray", 1, 16)), P("OFF", S("AirbusFBW/ElecOHPArray", 0, 16), ground=True)])
E("ext_pwr", "EXTERNAL POWER", 1140, [
    P("ON", S("AirbusFBW/ElecOHPArray", 1, 15), S("AirbusFBW/ElecOHPArray", 1, 3), ground=True),
    P("OFF", S("AirbusFBW/ElecOHPArray", 0, 15), S("AirbusFBW/ElecOHPArray", 0, 3))])
for n, idx, code in ((1, 0, 1150), (2, 1, 1160)):
    E(f"gen_{n}", f"GENERATOR {n}", code, [P("ON", S("AirbusFBW/ElecOHPArray", 1, idx)), P("OFF", S("AirbusFBW/ElecOHPArray", 0, idx))])
E("apu_gen", "APU GENERATOR", 1170, [P("ON", S("AirbusFBW/ElecOHPArray", 1, 2)), P("OFF", S("AirbusFBW/ElecOHPArray", 0, 2))])
E("bus_tie", "BUS TIE", 1180, [P("AUTO", S("AirbusFBW/ElecOHPArray", 1, 4)), P("OFF", S("AirbusFBW/ElecOHPArray", 0, 4))])
E("ac_ess_feed", "AC ESSENTIAL FEED", 1190, [P("NORMAL", S("AirbusFBW/ElecOHPArray", 0, 7)), P("ALTERNATE", S("AirbusFBW/ElecOHPArray", 1, 7))])  # checked 31.10.2026
E("commercial", "COMMERCIAL", 1200, [P("ON", S("AirbusFBW/ElecOHPArray", 1, 8)), P("OFF", S("AirbusFBW/ElecOHPArray", 0, 8))])
E("galley", "GALLEY", 1210, [P("ON", S("AirbusFBW/ElecOHPArray", 1, 9)), P("OFF", S("AirbusFBW/ElecOHPArray", 0, 9))])
E("emer_gen_test", "EMERGENCY GENERATOR TEST", 1220, [P("TEST", H("toliss_airbus/eleccommands/PressEmerGenTestButton"), ground=True)])

# ---------------- FUEL ----------------
PUMPS = (("left_pump_1", "LEFT FUEL PUMP 1", 0), ("left_pump_2", "LEFT FUEL PUMP 2", 1),
         ("right_pump_1", "RIGHT FUEL PUMP 1", 4), ("right_pump_2", "RIGHT FUEL PUMP 2", 5),
         ("center_left_pump", "CENTER TANK LEFT PUMP", 2), ("center_right_pump", "CENTER TANK RIGHT PUMP", 3),
         ("left_stby_pump", "LEFT STANDBY FUEL PUMP", 8), ("right_stby_pump", "RIGHT STANDBY FUEL PUMP", 9))
for k, (pid, pname, idx) in enumerate(PUMPS):
    E(pid, pname, 1300 + 10 * k, [P("ON", S("AirbusFBW/FuelOHPArray", 1, idx)),
                                  P("OFF", S("AirbusFBW/FuelOHPArray", 0, idx), ground=True)])
E("main_fuel_pumps", "MAIN FUEL PUMPS", 1380, [
    P("ON", *[S("AirbusFBW/FuelOHPArray", 1, i) for i in (0, 1, 2, 3, 4, 5)]),
    P("OFF", *[S("AirbusFBW/FuelOHPArray", 0, i) for i in (0, 1, 2, 3, 4, 5)], ground=True)])
E("stby_fuel_pumps", "STANDBY FUEL PUMPS", 1390, [
    P("ON", S("AirbusFBW/FuelOHPArray", 1, 8), S("AirbusFBW/FuelOHPArray", 1, 9)),
    P("OFF", S("AirbusFBW/FuelOHPArray", 0, 8), S("AirbusFBW/FuelOHPArray", 0, 9))])
E("all_fuel_pumps", "ALL FUEL PUMPS", 1400, [
    P("ON", *[S("AirbusFBW/FuelOHPArray", 1, i) for i in (0, 1, 2, 3, 4, 5, 8, 9)]),
    P("OFF", *[S("AirbusFBW/FuelOHPArray", 0, i) for i in (0, 1, 2, 3, 4, 5, 8, 9)], ground=True)])
E("center_tank_mode", "CENTER TANK MODE", 1410, [P("AUTO", S("AirbusFBW/FuelOHPArray", 1, 6)), P("MANUAL", S("AirbusFBW/FuelOHPArray", 0, 6))])  # checked 31.10.2026
E("fuel_crossfeed", "FUEL CROSSFEED", 1420, [P("OPEN", S("AirbusFBW/FuelOHPArray", 1, 7)), P("SHUT", S("AirbusFBW/FuelOHPArray", 0, 7))])
E("outer_tank_transfer", "OUTER TANK TRANSFER", 1430, [P("ON", S("AirbusFBW/FuelOHPArray", 1, 24)), P("OFF", S("AirbusFBW/FuelOHPArray", 0, 24))])
E("tail_tank_transfer", "TAIL TANK FORWARD TRANSFER", 1440, [P("ON", S("AirbusFBW/FuelOHPArray", 1, 22)), P("OFF", S("AirbusFBW/FuelOHPArray", 0, 22))])

# ---------------- APU ----------------
E("apu_master", "APU MASTER", 1500, [P("ON", C("toliss_airbus/apucommands/MasterOn")), P("OFF", C("toliss_airbus/apucommands/MasterOff"))])
E("apu_start", "APU", 1510, [P("START", 'PM_apu_start()'),  # starter 5 s after the master switch
                             P("OFF", C("toliss_airbus/apucommands/MasterOff"))])
E("apu_bleed", "APU BLEED", 1520, [P("ON", C("toliss_airbus/apucommands/BleedOn"), check="PM_check_apu_bleed"),
                                   P("OFF", C("toliss_airbus/apucommands/BleedOff"))])

# ---------------- ANTI ICE ----------------
E("eng1_anti_ice", "ENGINE 1 ANTI ICE", 1600, [P("ON", C("toliss_airbus/antiicecommands/ENG1On")), P("OFF", C("toliss_airbus/antiicecommands/ENG1Off"))])
E("eng2_anti_ice", "ENGINE 2 ANTI ICE", 1610, [P("ON", C("toliss_airbus/antiicecommands/ENG2On")), P("OFF", C("toliss_airbus/antiicecommands/ENG2Off"))])
E("engine_anti_ice", "ENGINE ANTI ICE", 1620, [P("ON", C("toliss_airbus/antiicecommands/ENG1On"), C("toliss_airbus/antiicecommands/ENG2On")),
                                               P("OFF", C("toliss_airbus/antiicecommands/ENG1Off"), C("toliss_airbus/antiicecommands/ENG2Off"))])
E("wing_anti_ice", "WING ANTI ICE", 1630, [P("ON", C("toliss_airbus/antiicecommands/WingOn")), P("OFF", C("toliss_airbus/antiicecommands/WingOff"))])
E("probe_heat", "PROBE AND WINDOW HEAT", 1640, [P("ON", S("AirbusFBW/ProbeHeatSwitch", 1)), P("AUTO", S("AirbusFBW/ProbeHeatSwitch", 0))])

# ---------------- AIR CONDITIONING / BLEED / PRESSURIZATION ----------------
E("pack_1", "PACK 1", 1700, [P("ON", C("toliss_airbus/aircondcommands/Pack1On")), P("OFF", C("toliss_airbus/aircondcommands/Pack1Off"))])
E("pack_2", "PACK 2", 1710, [P("ON", C("toliss_airbus/aircondcommands/Pack2On")), P("OFF", C("toliss_airbus/aircondcommands/Pack2Off"))])
E("packs", "PACKS", 1720, [P("ON", C("toliss_airbus/aircondcommands/Pack1On"), C("toliss_airbus/aircondcommands/Pack2On")),
                           P("OFF", C("toliss_airbus/aircondcommands/Pack1Off"), C("toliss_airbus/aircondcommands/Pack2Off"))])
E("pack_flow", "PACK FLOW", 1730, [P("LOW", S("AirbusFBW/PackFlowSel", 0)), P("NORMAL", S("AirbusFBW/PackFlowSel", 1)), P("HIGH", S("AirbusFBW/PackFlowSel", 2))])
E("eng1_bleed", "ENGINE 1 BLEED", 1740, [P("ON", S("AirbusFBW/ENG1BleedSwitch", 1)), P("OFF", S("AirbusFBW/ENG1BleedSwitch", 0))])
E("eng2_bleed", "ENGINE 2 BLEED", 1750, [P("ON", S("AirbusFBW/ENG2BleedSwitch", 1)), P("OFF", S("AirbusFBW/ENG2BleedSwitch", 0))])
E("eng_bleeds", "ENGINE BLEEDS", 1760, [P("ON", S("AirbusFBW/ENG1BleedSwitch", 1), S("AirbusFBW/ENG2BleedSwitch", 1)),
                                        P("OFF", S("AirbusFBW/ENG1BleedSwitch", 0), S("AirbusFBW/ENG2BleedSwitch", 0))])
E("x_bleed", "CROSS BLEED", 1770, [P("SHUT", S("AirbusFBW/XBleedSwitch", 0)), P("AUTO", S("AirbusFBW/XBleedSwitch", 1)), P("OPEN", S("AirbusFBW/XBleedSwitch", 2))])
E("hot_air_1", "HOT AIR 1", 1780, [P("ON", S("AirbusFBW/HotAirSwitch", 1)), P("OFF", S("AirbusFBW/HotAirSwitch", 0))])
E("hot_air_2", "HOT AIR 2", 1790, [P("ON", S("AirbusFBW/HotAirSwitch2", 1)), P("OFF", S("AirbusFBW/HotAirSwitch2", 0))])
E("cabin_fans", "CABIN FANS", 1800, [P("ON", S("AirbusFBW/CabinFanSwitch", 1)), P("OFF", S("AirbusFBW/CabinFanSwitch", 0))])
E("avionics_extract", "AVIONICS EXTRACT", 1810, [P("AUTO", S("AirbusFBW/ExtractSwitch", 0)), P("OVERRIDE", S("AirbusFBW/ExtractSwitch", 1))])  # checked 31.10.2026
E("fwd_cargo_isol", "FORWARD CARGO ISOLATION VALVE", 1820, [P("OPEN", S("AirbusFBW/FwdIsolValve", 1)), P("SHUT", S("AirbusFBW/FwdIsolValve", 0))])  # checked 31.10.2026
E("bulk_cargo_isol", "BULK CARGO ISOLATION VALVE", 1830, [P("OPEN", S("AirbusFBW/BulkIsolValve", 1)), P("SHUT", S("AirbusFBW/BulkIsolValve", 0))])  # checked 31.10.2026
E("cargo_hot_air", "CARGO HOT AIR", 1840, [P("ON", S("AirbusFBW/CargoHotAir", 1)), P("OFF", S("AirbusFBW/CargoHotAir", 0))])
E("landing_elevation", "LANDING ELEVATION", 1850, [P("AUTO", S("AirbusFBW/LandElev", -3))])
E("cabin_press_mode", "CABIN PRESSURE MODE", 1860, [P("AUTO", S("AirbusFBW/CabPressMode", 0)), P("MANUAL", S("AirbusFBW/CabPressMode", 1))])

# ---------------- EXTERIOR LIGHTS / SIGNS ----------------
E("beacon", "BEACON", 1900, [P("ON", L(0, 1)), P("OFF", L(0, 0))])
E("wing_lights", "WING LIGHTS", 1910, [P("ON", C("toliss_airbus/lightcommands/WingLightOn")), P("OFF", C("toliss_airbus/lightcommands/WingLightOff"))])
E("nav_lights", "NAV AND LOGO LIGHTS", 1920, [P("ON", L(2, 1)), P("OFF", L(2, 0))])
E("nose_light", "NOSE LIGHT", 1930, [P("OFF", L(3, 0)), P("TAXI", L(3, 1)), P("TAKEOFF", L(3, 2))])
E("landing_lights", "LANDING LIGHTS", 1940, [P("ON", L(4, 2), L(5, 2)), P("OFF", L(4, 0), L(5, 0))])
E("turnoff_lights", "RUNWAY TURN OFF LIGHTS", 1950, [P("ON", C("toliss_airbus/lightcommands/TurnoffLightOn")), P("OFF", C("toliss_airbus/lightcommands/TurnoffLightOff"))])
E("strobe", "STROBE LIGHTS", 1960, [P("OFF", L(7, 0)), P("AUTO", L(7, 1)), P("ON", L(7, 2))])
E("dome", "DOME LIGHT", 1970, [P("OFF", L(8, 0)), P("DIM", L(8, 1)), P("BRIGHT", L(8, 2))])
E("ice_ind", "ICE INDICATOR AND STANDBY COMPASS LIGHT", 1980, [P("ON", L(9, 1)), P("OFF", L(9, 0))])
E("emer_exit", "EMERGENCY EXIT LIGHTS", 1990, [P("OFF", L(10, 0)), P("ARM", L(10, 1)), P("ON", L(10, 2))])
E("seat_belts", "SEAT BELT SIGNS", 2000, [P("OFF", L(11, 0)), P("AUTO", L(11, 1)), P("ON", L(11, 2))])
E("ped", "NO PORTABLE ELECTRONIC DEVICES", 2010, [P("OFF", L(12, 0)), P("AUTO", L(12, 1)), P("ON", L(12, 2))])

# ---------------- WIPERS / OXYGEN / RECORDER / DOOR ----------------
E("wiper_capt", "CAPTAIN WIPER", 2100, [P("OFF", S("AirbusFBW/LeftWiperSwitch", 0)), P("SLOW", S("AirbusFBW/LeftWiperSwitch", 1)), P("FAST", S("AirbusFBW/LeftWiperSwitch", 2))])
E("wiper_fo", "FIRST OFFICER WIPER", 2110, [P("OFF", S("AirbusFBW/RightWiperSwitch", 0)), P("SLOW", S("AirbusFBW/RightWiperSwitch", 1)), P("FAST", S("AirbusFBW/RightWiperSwitch", 2))])
E("wipers", "WIPERS", 2120, [P("OFF", S("AirbusFBW/LeftWiperSwitch", 0), S("AirbusFBW/RightWiperSwitch", 0)),
                             P("SLOW", S("AirbusFBW/LeftWiperSwitch", 1), S("AirbusFBW/RightWiperSwitch", 1)),
                             P("FAST", S("AirbusFBW/LeftWiperSwitch", 2), S("AirbusFBW/RightWiperSwitch", 2))])
E("crew_oxygen", "CREW OXYGEN SUPPLY", 2130, [P("ON", S("AirbusFBW/CrewOxySwitch", 1)), P("OFF", S("AirbusFBW/CrewOxySwitch", 0), ground=True)])
E("recorder_gnd_ctl", "RECORDER GROUND CONTROL", 2140, [P("ON", S("AirbusFBW/CvrGndCtrl", 1)), P("OFF", S("AirbusFBW/CvrGndCtrl", 0))])
E("cockpit_door", "COCKPIT DOOR", 2150, [P("OPEN", S("AirbusFBW/CockpitDoorAngle", 90)), P("CLOSE", S("AirbusFBW/CockpitDoorAngle", 0))])

# ---------------- EFIS / ND ----------------
E("flight_directors", "FLIGHT DIRECTORS", 2200, [P("ON", S("AirbusFBW/FD1Engage", 1), S("AirbusFBW/FD2Engage", 1)),
                                                 P("OFF", S("AirbusFBW/FD1Engage", 0), S("AirbusFBW/FD2Engage", 0))])
E("baro", "BAROMETERS", 2210, [P("STANDARD", "PM_baro_std(true)"), P("QNH", "PM_baro_std(false)")])
E("baro_unit", "BARO UNIT", 2220, [P("HECTOPASCAL", S("AirbusFBW/BaroUnitCapt", 1), S("AirbusFBW/BaroUnitFO", 1)),
                                   P("INCHES", S("AirbusFBW/BaroUnitCapt", 0), S("AirbusFBW/BaroUnitFO", 0))])
E("terrain_nd_capt", "TERRAIN ON CAPTAIN ND", 2230, [P("ON", S("AirbusFBW/TerrainSelectedND1", 1)), P("OFF", S("AirbusFBW/TerrainSelectedND1", 0))])
E("terrain_nd_fo", "TERRAIN ON FIRST OFFICER ND", 2240, [P("ON", S("AirbusFBW/TerrainSelectedND2", 1)), P("OFF", S("AirbusFBW/TerrainSelectedND2", 0))])
E("cstr_nd_fo", "CONSTRAINTS ON FIRST OFFICER ND", 2250, [P("ON", S("AirbusFBW/NDShowCSTRFO", 1)), P("OFF", S("AirbusFBW/NDShowCSTRFO", 0))])
ND_MODES = ("LS", "VOR", "NAV", "ARC", "PLAN")
E("nd_mode_capt", "CAPTAIN ND MODE", 2260, [P(m, S("AirbusFBW/NDmodeCapt", i)) for i, m in enumerate(ND_MODES)])
E("nd_mode_fo", "FIRST OFFICER ND MODE", 2270, [P(m, S("AirbusFBW/NDmodeFO", i)) for i, m in enumerate(ND_MODES)])
ND_RANGES = ("10", "20", "40", "80", "160", "320")
E("nd_range_capt", "CAPTAIN ND RANGE", 2280, [P(r, S("AirbusFBW/NDrangeCapt", i)) for i, r in enumerate(ND_RANGES)])
E("nd_range_fo", "FIRST OFFICER ND RANGE", 2290, [P(r, S("AirbusFBW/NDrangeFO", i)) for i, r in enumerate(ND_RANGES)])

# ---------------- WARNINGS / ECAM ----------------
E("master_caution", "MASTER CAUTION", 2300, [P("RESET", C("AirbusFBW/CaptCautPush"))])
E("master_warning", "MASTER WARNING", 2310, [P("RESET", C("AirbusFBW/CaptWarnPush"))])
E("ecam_emer_cancel", "ECAM EMERGENCY CANCEL", 2320, [P("PRESS", C("AirbusFBW/EmerCancel"))])
E("ecam_recall", "ECAM RECALL", 2330, [P("PRESS", C("AirbusFBW/ECAMRecall"))])
E("ecam_clear", "ECAM CLEAR", 2340, [P("PRESS", C("AirbusFBW/ECP/CopilotClear"))])
E("to_config", "TAKEOFF CONFIG TEST", 2350, [P("TEST", H("AirbusFBW/TOConfigPress", 2), ground=True)])
ECAM_PAGES = (("ENGINE", "SelectEnginePage"), ("BLEED", "SelectBleedPage"), ("PRESSURE", "SelectPressPage"),
              ("ELEC AC", "SelectElecACPage"), ("ELEC DC", "SelectElecDCPage"), ("HYDRAULIC", "SelectHydraulicPage"),
              ("CIRCUIT BREAKERS", "SelectCircuitBreakerPage"), ("APU", "SelectAPUPage"), ("CONDITIONING", "SelectConditioningPage"),
              ("DOOR", "SelectDoorOxyPage"), ("WHEEL", "SelectWheelPage"), ("FLIGHT CONTROLS", "SelectFlightControlPage"),
              ("FUEL", "SelectFuelPage"), ("STATUS", "SelectStatusPage"))
E("ecam_page", "ECAM PAGE", 2400, [P(name, C("AirbusFBW/ECP/" + cmd)) for name, cmd in ECAM_PAGES[:10]])
E("ecam_page_2", "ECAM PAGE", 2410, [P(name, C("AirbusFBW/ECP/" + cmd)) for name, cmd in ECAM_PAGES[10:]] + [P("ALL", C("AirbusFBW/ECAMAll"))])

# ---------------- BRAKES / GEAR AREA ----------------
E("autobrake", "AUTOBRAKE", 2500, [P("LOW", C("AirbusFBW/AbrkLo")), P("MEDIUM", C("AirbusFBW/AbrkMed")), P("MAX", C("AirbusFBW/AbrkMax"))])
E("brake_fans", "BRAKE FANS", 2510, [P("ON", S("AirbusFBW/BrakeFan", 1)), P("OFF", S("AirbusFBW/BrakeFan", 0))])
E("park_brake", "PARKING BRAKE", 2520, [P("SET", C("toliss_airbus/park_brake_set"), ground=True), P("RELEASE", C("toliss_airbus/park_brake_release"), ground=True)])
E("ground_spoilers", "GROUND SPOILERS", 2530, [P("ARM", S("sim/cockpit2/controls/speedbrake_ratio", -0.5)), P("DISARM", S("sim/cockpit2/controls/speedbrake_ratio", 0))])
E("row_rop", "ROW ROP", 2540, [P("ON", S("AirbusFBW/ROPROWSwitchOHP", 1)), P("OFF", S("AirbusFBW/ROPROWSwitchOHP", 0))])

# ---------------- TRANSPONDER / TCAS / RADAR ----------------
E("transponder", "TRANSPONDER", 2600, [P("STANDBY", S("AirbusFBW/XPDRPower", 0), ground=True), P("AUTO", S("AirbusFBW/XPDRPower", 1)), P("ON", S("AirbusFBW/XPDRPower", 2))])  # checked 31.10.2026
E("tcas", "TCAS", 2610, [P("STANDBY", S("AirbusFBW/XPDRTCASMode", 0)), P("TA ONLY", S("AirbusFBW/XPDRTCASMode", 1)), P("TA RA", S("AirbusFBW/XPDRTCASMode", 2))])
E("xpdr_system", "TRANSPONDER SYSTEM", 2620, [P("ONE", S("AirbusFBW/XPDRSystem", 1)), P("TWO", S("AirbusFBW/XPDRSystem", 2))])  # checked 31.10.2026
E("xpdr_ident", "TRANSPONDER IDENT", 2630, [P("PRESS", C("sim/transponder/transponder_ident"))])
E("weather_radar", "WEATHER RADAR", 2640, [P("ON", S("AirbusFBW/WXPowerSwitch", 2)), P("OFF", S("AirbusFBW/WXPowerSwitch", 1))])
E("pws", "PREDICTIVE WINDSHEAR", 2650, [P("AUTO", S("AirbusFBW/WXSwitchPWS", 1)), P("OFF", S("AirbusFBW/WXSwitchPWS", 0))])  # checked 31.10.2026

# ---------------- GPWS (GPWSSwitchArray, normal state 1,1,1,0,1 : 1 = ON ; [3] = LDG FLAP 3, as Speedy Copilot) ----------------
for k, (gid, gname, idx) in enumerate((("gpws_sys", "GPWS SYSTEM", 0), ("gpws_gs", "GPWS GLIDESLOPE MODE", 1),
                                       ("gpws_flap", "GPWS FLAP MODE", 2), ("gpws_ldg_flap3", "GPWS LANDING FLAPS 3", 3),
                                       ("gpws_terr", "GPWS TERRAIN", 4))):
    E(gid, gname, 2950 + 10 * k, [P("ON", S("AirbusFBW/GPWSSwitchArray", 1, idx)), P("OFF", S("AirbusFBW/GPWSSwitchArray", 0, idx))])

# ---------------- ENGINES ----------------
E("eng_mode", "ENGINE MODE", 2700, [P("CRANK", C("toliss_airbus/engcommands/EngineModeSwitchToCrank"), ground=True),
                                    P("NORMAL", C("toliss_airbus/engcommands/EngineModeSwitchToNorm")),
                                    P("IGNITION", C("toliss_airbus/engcommands/EngineModeSwitchToStart"))])

# ---------------- FCU (on request) ----------------
E("ap1", "AUTOPILOT 1", 2800, [P("ENGAGE", C("toliss_airbus/ap1_push"))])
E("ap2", "AUTOPILOT 2", 2810, [P("ENGAGE", C("toliss_airbus/ap2_push"))])
E("athr", "AUTOTHRUST", 2820, [P("PRESS", C("sim/autopilot/autothrottle_toggle"))])
E("appr", "APPROACH MODE", 2830, [P("PRESS", C("AirbusFBW/APPRbutton"))])
E("loc", "LOCALIZER MODE", 2840, [P("PRESS", C("AirbusFBW/LOCbutton"))])
E("fcu_alt", "ALTITUDE KNOB", 2850, [P("PUSH", C("AirbusFBW/PushAltitude")), P("PULL", C("AirbusFBW/PullAltitude"))])
E("fcu_hdg", "HEADING KNOB", 2860, [P("PUSH", C("AirbusFBW/PushHDGSel")), P("PULL", C("AirbusFBW/PullHDGSel"))])
E("fcu_spd", "SPEED KNOB", 2870, [P("PUSH", C("AirbusFBW/PushSPDSel")), P("PULL", C("AirbusFBW/PullSPDSel"))])
E("fcu_vs", "VERTICAL SPEED KNOB", 2880, [P("PUSH", C("AirbusFBW/PushVSSel")), P("PULL", C("AirbusFBW/PullVSSel"))])
E("hdg_trk", "HEADING TRACK BUTTON", 2890, [P("PRESS", C("toliss_airbus/hdgtrk_button_push"))])
E("spd_mach", "SPEED MACH BUTTON", 2900, [P("PRESS", C("toliss_airbus/ias_mach_button_push"))])
E("metric_alt", "METRIC ALTITUDE", 2910, [P("PRESS", C("toliss_airbus/metric_alt_button_push"))])


# ---------------- generation ----------------
def slug(word):
    return re.sub(r"[^a-z0-9]+", "_", word.lower()).strip("_")


def lua_string(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


codes = {}
for sw in SWITCHES:
    assert len(sw["positions"]) <= 10, sw["id"]
    for i, _ in enumerate(sw["positions"]):
        code = sw["code"] + i
        assert code not in codes, f"code {code} used twice ({codes.get(code)} / {sw['id']})"
        codes[code] = sw["id"]

out = ["-- GENERATED by tools/cockpit_map.py : do not edit, edit the map and run it again.",
       "-- A339 cockpit switches the SayIntentions co-pilot may operate, by order code (SpeedyCopilot/si/order).",
       "", "if not string.find(PLANE_AUTHOR, \"Gliding\") or PM_do == nil then return end", "", "PM_SWITCHES = {"]
items = []
for sw in SWITCHES:
    out.append(f"\t{sw['id']} = {{ name = {lua_string(sw['name'])}, code = {sw['code']}, pos = {{")
    for i, p in enumerate(sw["positions"]):
        opts = ""
        if p.get("ground"): opts += ", ground = true"
        if p.get("confirm"): opts += f", confirm = {lua_string(p['confirm'])}"
        if p.get("confirm_in_flight"): opts += f", confirm_in_flight = {lua_string(p['confirm_in_flight'])}"
        if p.get("check"): opts += f", check = {p['check']}"
        body = " ".join(p["actions"])
        out.append(f"\t\t{{ word = {lua_string(p['word'])}, slug = \"{slug(p['word'])}\", run = function() {body} end{opts} }},")
        items.append({"challenge": sw["name"], "response": p["word"], "code": sw["code"] + i})
    out.append("\t} },")
out.append("}")
out.append("")
out.append("PM_register_switches()")
out.append("")
with open(os.path.join(ROOT, "src", "A339_pm_2_switches.lua"), "w", encoding="utf-8", newline="\n") as f:
    f.write("\n".join(out))

# PF orders and procedures (codes of A339_pm_1_core.lua and A339_pm_3_procedures.lua)
# flaps : one distinct challenge per position ("FLAPS / ONE" and "FLAPS / TWO" differed only by the response and she
# pressed TWO on "flaps one")
EXTRA = [("FLAPS UP", "SET", 10), ("FLAPS ONE", "SET", 11), ("FLAPS TWO", "SET", 12), ("FLAPS THREE", "SET", 13),
         ("FLAPS FULL", "SET", 14),
         ("LANDING GEAR", "UP", 20), ("LANDING GEAR", "DOWN", 21),
         # the bridge sets the number ; these tell her that she can (no action in the PM)
         ("SET SELECTED HEADING", "AS REQUESTED", 30), ("SET SELECTED SPEED OR MACH", "AS REQUESTED", 31),
         ("SET SELECTED ALTITUDE", "AS REQUESTED", 32), ("SET QNH ON BOTH ALTIMETERS", "AS REQUESTED", 33),
         ("SET TRANSPONDER SQUAWK CODE", "AS REQUESTED", 34),
         # procedures : action wording ("... PROCEDURE / START"). "... / DONE" read like a checklist answer and the
         # names clash with her own checklists (Cockpit Preparation, After Start...) : she did not press them.
         ("PRELIMINARY COCKPIT PREPARATION PROCEDURE", "START", 100), ("COCKPIT PREPARATION PROCEDURE", "START", 101),
         ("BEFORE START PROCEDURE", "START", 102), ("ENGINE START PROCEDURE", "START ENGINES", 103),
         ("ENGINE START PROCEDURE", "SEQUENCE TWO ONE", 104), ("ENGINE START PROCEDURE", "SEQUENCE ONE TWO", 105),
         ("AFTER START PROCEDURE", "START", 106), ("TAXI PROCEDURE", "START", 107), ("LINE UP PROCEDURE", "START", 108),
         ("AFTER TAKEOFF PROCEDURE", "START", 109), ("CLIMB PROCEDURE", "START", 110),
         ("DESCENT PREPARATION PROCEDURE", "START", 111), ("DESCENT PROCEDURE", "START", 112),
         ("APPROACH PROCEDURE", "START", 113), ("AFTER LANDING PROCEDURE", "START", 114),
         ("PARKING PROCEDURE", "START", 115), ("SECURING THE AIRCRAFT PROCEDURE", "START", 116),
         ("ENGINE START PROCEDURE", "ABORT", 117), ("GO AROUND PROCEDURE", "START", 118)]
for challenge, response, code in EXTRA:
    assert code not in codes, code
items = [{"challenge": c, "response": r, "code": k} for c, r, k in EXTRA] + items

with open(os.path.join(ROOT, "docs", "si_items.json"), "w", encoding="utf-8") as f:
    json.dump(items, f, ensure_ascii=False, indent=1)

md = ["# PM ACTIONS — переключатели (сгенерировано tools/cockpit_map.py)", "",
      "Пункт Checklist Tuner: Challenge / Response, Full Automatic, DREF `SpeedyCopilot/si/order` = код.", "",
      "| Challenge | Response | Код |", "|---|---|---|"]
md += [f"| {it['challenge']} | {it['response']} | {it['code']} |" for it in items]
with open(os.path.join(ROOT, "docs", "A339_pm_actions.md"), "w", encoding="utf-8") as f:
    f.write("\n".join(md) + "\n")
print(len(SWITCHES), "switches,", len(items), "positions / items")
