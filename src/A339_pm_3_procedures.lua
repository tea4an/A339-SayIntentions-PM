-- A339 PM : procedures (docs/PLAN_lightweight_PM.md, approved 31.10.2026), engine start, securing the aircraft.
-- Each procedure checks its conditions, then sets its items one after the other like a PM would.
-- Flaps and gear are PF orders only, except FLAPS 0 in AFTER LANDING (pilot's decision 01.11.2026).

if not string.find(PLANE_AUTHOR, "Gliding") or PM_do == nil then return end

PM_packs_off_for_takeoff = true    -- LINE UP : PACKS OFF (PACKS ON again in AFTER TAKEOFF)
-- SEAT BELTS : ON where the plan says ON (cockpit prep, before start, descent) ; where it said OFF (climb, parking)
-- AUTO instead - a procedure never switches them OFF, the pilot does. NO PORTABLE ELEC DEVICE : AUTO, never OFF.

local function night()
	local hour = get("sim/cockpit2/clock_timer/local_time_hours")
	return hour >= 18 or hour < 7
end

local function apu_avail() return PM_ref("AirbusFBW/APUAvail") == 1 end

local function open_doors()
	local open = {}
	for i = 0, 7 do if PM_ref("AirbusFBW/PaxDoorArray", i) > 0.05 then open[#open + 1] = "passenger door " .. (i + 1) end end
	for i = 0, 2 do if PM_ref("AirbusFBW/CargoDoorArray", i) > 0.05 then open[#open + 1] = "cargo door " .. (i + 1) end end
	return table.concat(open, ", ")
end

local function parked()
	return PM_ref("AirbusFBW/ParkBrake") == 1 or PM_ref("AirbusFBW/Chocks") == 1
end

-- airborne at least once in this flight (after landing condition), kept in a file : survives a script reload
local STATE_FILE = PM_DIR .. "flight_state.txt"
PM_was_airborne = false
do
	local f = io.open(STATE_FILE, "r")
	if f ~= nil then PM_was_airborne = (f:read("*a") == "airborne") f:close() end
end
local function set_was_airborne(value)
	if PM_was_airborne == value then return end
	PM_was_airborne = value
	local f = io.open(STATE_FILE, "w")
	if f ~= nil then f:write(value and "airborne" or "ground") f:close() end
end
function PM_track_flight()
	if PM_agl_m() > 150 then set_was_airborne(true) end
end
do_often("PM_track_flight()")

--########################################
--# RUNNING A PROCEDURE                  #
--########################################
-- steps : { "switch_id", "POSITION" } or a function ; a function returning false is asked again a second later
-- (waiting for the APU...), at most 120 s.
PM_RUN = nil

local function run(name, steps)
	PM_RUN = { name = name, steps = steps, index = 1, wait = PM_time + 0.5, since = PM_time }
	PM_log(name)
end

function PM_run_process()
	local r = PM_RUN
	if r == nil or PM_time < r.wait then return end
	local step = r.steps[r.index]
	if step == nil then
		PM_log(r.name .. " done")
		-- she reports it ("Cockpit preparation procedure done."), in lower case so that it is not spelled out
		local name = string.lower(r.name)
		PM_say(string.upper(string.sub(name, 1, 1)) .. string.sub(name, 2) .. " procedure done.")
		PM_RUN = nil
		return
	end
	if type(step) == "function" then
		if step() == false and PM_time - r.since < 120 then r.wait = PM_time + 1 return end
	else
		PM_set(step[1], step[2])
	end
	r.index = r.index + 1
	r.wait = PM_time + 0.8
end
do_every_frame("PM_run_process()")

-- The bridge starts a procedure from the pilot's words ("approach procedure") and she may press its item too :
-- the same procedure asked again within 15 s is started once. Engine start keeps her repeat (= confirmation) ;
-- repeat = true (always allowed) or the number of seconds a repeat is ignored.
local PROC_REPEAT = 15
local proc_asked = {}

local function proc(code, id, name, start, repeat_allowed)
	local window = type(repeat_allowed) == "number" and repeat_allowed or PROC_REPEAT
	-- source : "bridge" (the command, from the pilot's words) or "her" (her checklist item, order code)
	local function ask(source)
		local last = proc_asked[id]
		if repeat_allowed ~= true and last ~= nil and PM_time - last < window then PM_log(name .. " asked again : already started") return end
		proc_asked[id] = PM_time
		start(source or "bridge")
	end
	create_command("SpeedyCopilot/proc/" .. id, "A339 PM : " .. name, "PM_proc_" .. id .. "()", "", "")
	_G["PM_proc_" .. id] = ask
	PM_register_code(code, function() ask("her") end)
end

--########################################
--# GROUND                               #
--########################################
proc(100, "preliminary", "PRELIMINARY COCKPIT PREPARATION", function()
	if not PM_on_ground(5) then PM_refuse("PRELIMINARY COCKPIT PREPARATION", "On ground only.") return end
	-- the APU is started on the pilot's order only ("APU start"), never by a procedure
	run("PRELIMINARY COCKPIT PREPARATION", {
		{ "batteries", "ON" }, { "apu_bat", "ON" }, { "ext_pwr", "ON" }, { "eng_mode", "NORMAL" },
		{ "dome", night() and "DIM" or "BRIGHT" }, { "recorder_gnd_ctl", "ON" }, { "crew_oxygen", "ON" },
		{ "ecam_recall", "PRESS" }, { "apu_fire_test", "TEST" },
		function() return PM_time > PM_RUN.since + 12 end, -- end of the fire test
		{ "baro_unit", "HECTOPASCAL" },
	})
end)

proc(101, "cockpit_preparation", "COCKPIT PREPARATION", function()
	if not PM_on_ground(5) then PM_refuse("COCKPIT PREPARATION", "On ground only.") return end
	run("COCKPIT PREPARATION", {
		{ "all_fuel_pumps", "ON" }, { "center_tank_mode", "AUTO" }, { "packs", "ON" }, { "adirs_all", "NAV" },
		{ "beacon", "OFF" }, { "wing_lights", "OFF" }, { "nav_lights", "ON" }, { "nose_light", "OFF" },
		{ "landing_lights", "OFF" }, { "turnoff_lights", "OFF" }, { "strobe", "AUTO" },
		{ "seat_belts", "ON" }, { "ped", "AUTO" }, { "emer_exit", "ARM" },
		{ "landing_elevation", "AUTO" }, { "cabin_press_mode", "AUTO" },
		{ "eng1_fire_test", "TEST" }, function() return PM_time > PM_RUN.since + 25 end, { "eng2_fire_test", "TEST" },
		{ "transponder", "STANDBY" }, { "flight_directors", "ON" },
	})
end)

proc(102, "before_start", "BEFORE START", function()
	if not PM_on_ground(10) then PM_refuse("BEFORE START", "On ground only.") return end
	-- no APU start here (pilot's order only) : with the APU available, its bleed goes ON and the external power OFF
	local steps = { { "cockpit_door", "CLOSE" } }
	steps[#steps + 1] = function() if apu_avail() then PM_set("apu_bleed", "ON") end end
	steps[#steps + 1] = function() if apu_avail() then PM_set("ext_pwr", "OFF") end end
	for _, s in ipairs({ { "seat_belts", "ON" }, { "ped", "AUTO" }, { "transponder", "AUTO" }, { "beacon", "ON" } }) do steps[#steps + 1] = s end
	run("BEFORE START", steps)
end)

proc(106, "after_start", "AFTER START", function()
	if not PM_on_ground(30) then PM_refuse("AFTER START", "On ground, below 30 knots only.") return end
	if not PM_both_engines_running() then PM_refuse("AFTER START", "Both engines must be running.") return end
	if PM_ES.state ~= "idle" then PM_refuse("AFTER START", "Engine start still in progress.") return end
	run("AFTER START", { { "eng_mode", "NORMAL" }, { "ground_spoilers", "ARM" }, { "x_bleed", "AUTO" }, { "dome", "DIM" } })
end)

proc(107, "taxi", "TAXI", function()
	if not PM_on_ground(30) then PM_refuse("TAXI", "On ground, below 30 knots only.") return end
	if not PM_both_engines_running() then PM_refuse("TAXI", "Both engines must be running.") return end
	local steps = { { "flight_directors", "ON" }, { "weather_radar", "ON" }, { "pws", "AUTO" }, { "autobrake", "MAX" },
		{ "terrain_nd_fo", "ON" }, { "to_config", "TEST" }, { "nose_light", "TAXI" },
		{ "apu_bleed", "OFF" }, { "apu_master", "OFF" } } -- engines running : the APU goes off at the taxi (pilot)
	if night() then steps[#steps + 1] = { "turnoff_lights", "ON" } end
	steps[#steps + 1] = { "dome", "OFF" }
	run("TAXI", steps)
end)

proc(108, "lineup", "LINE UP", function()
	if not PM_on_ground(40) then PM_refuse("LINE UP", "On ground, below 40 knots only.") return end
	if not PM_both_engines_running() then PM_refuse("LINE UP", "Both engines must be running.") return end
	local steps = { { "transponder", "AUTO" }, { "tcas", "TA RA" }, { "nose_light", "TAKEOFF" }, { "turnoff_lights", "ON" },
		{ "strobe", "ON" }, { "landing_lights", "ON" }, { "brake_fans", "OFF" } }
	if PM_packs_off_for_takeoff then steps[#steps + 1] = { "packs", "OFF" } end
	run("LINE UP", steps)
end)

proc(114, "after_landing", "AFTER LANDING", function()
	if not PM_on_ground(40) then PM_refuse("AFTER LANDING", "On ground, below 40 knots only.") return end
	if not PM_was_airborne then PM_refuse("AFTER LANDING", "We have not flown yet.") return end
	-- the flaps go up here without a PF order (pilot's decision 01.11.2026) ; flaps and gear are PF orders anywhere else
	run("AFTER LANDING", { { "ground_spoilers", "DISARM" }, function() PM_flaps(0, true) end, { "strobe", "AUTO" }, { "landing_lights", "OFF" }, { "nose_light", "TAXI" },
		{ "weather_radar", "OFF" }, { "pws", "OFF" }, { "terrain_nd_fo", "OFF" }, { "tcas", "STANDBY" },
		{ "transponder", "AUTO" },
		function() if PM_ref("AirbusFBW/ChronoTimeND2") > 0 then command_once("AirbusFBW/CoChronoButton") end end })
end)

proc(115, "parking", "PARKING", function()
	if not PM_on_ground(1) then PM_refuse("PARKING", "The aircraft must be stopped.") return end
	if PM_n1(1) >= 17 or PM_n1(2) >= 17 then PM_refuse("PARKING", "Shut down the engines first.") return end
	if not parked() then PM_refuse("PARKING", "Set the parking brake first.") return end
	set_was_airborne(false) -- next leg
	run("PARKING", { { "beacon", "OFF" },
		function() -- APU BLEED only with the APU available (awaited while it starts, skipped when it is off)
			if apu_avail() then PM_set("apu_bleed", "ON") return true end
			if PM_ref("AirbusFBW/APUMaster") == 1 then return false end
		end,
		{ "all_fuel_pumps", "OFF" }, { "wing_lights", "OFF" },
		{ "nose_light", "OFF" }, { "landing_lights", "OFF" }, { "turnoff_lights", "OFF" }, { "strobe", "OFF" },
		{ "seat_belts", "AUTO" }, -- the plan said OFF : AUTO instead
		{ "transponder", "STANDBY" }, { "tcas", "STANDBY" }, { "ext_pwr", "ON" },
		{ "flight_directors", "OFF" } })
end)

-- securing (FCOM, simplified) : the batteries go OFF once the APU has stopped and its air intake flap is closed
proc(116, "securing", "SECURING THE AIRCRAFT", function()
	if not PM_on_ground(1) then PM_refuse("SECURING", "The aircraft must be stopped.") return end
	if PM_n1(1) >= 17 or PM_n1(2) >= 17 then PM_refuse("SECURING", "Shut down the engines first.") return end
	if not parked() then PM_refuse("SECURING", "Set the parking brake first.") return end
	set_was_airborne(false)
	run("SECURING THE AIRCRAFT", { { "adirs_all", "OFF" }, { "crew_oxygen", "OFF" }, { "beacon", "OFF" }, { "nav_lights", "OFF" },
		{ "wing_lights", "OFF" }, { "nose_light", "OFF" }, { "landing_lights", "OFF" }, { "turnoff_lights", "OFF" },
		{ "strobe", "OFF" }, { "apu_bleed", "OFF" }, { "emer_exit", "OFF" },
		{ "apu_master", "OFF" },
		function() return PM_ref("AirbusFBW/APUN") < 5 and PM_ref("AirbusFBW/APUFlapOpenRatio") < 0.05 end,
		{ "ext_pwr", "OFF" }, { "batteries", "OFF" } })
end)

--########################################
--# IN FLIGHT                            #
--########################################
proc(109, "after_takeoff", "AFTER TAKEOFF", function()
	if PM_agl_m() < 122 then PM_refuse("AFTER TAKEOFF", "Above four hundred feet only.") return end
	if PM_vs() < -300 then PM_refuse("AFTER TAKEOFF", "We are not climbing.") return end
	set_was_airborne(true)
	run("AFTER TAKEOFF", { { "ground_spoilers", "DISARM" }, { "nose_light", "OFF" }, { "turnoff_lights", "OFF" },
		{ "apu_bleed", "OFF" }, { "apu_master", "OFF" }, { "packs", "ON" } })
end)

proc(110, "climb", "CLIMB", function()
	if not PM_airborne() then PM_refuse("CLIMB", "In flight only.") return end
	if PM_vs() < -300 then PM_refuse("CLIMB", "We are not climbing.") return end
	-- the plan said SEAT BELTS OFF here : AUTO instead (the pilot never wants a procedure to switch them OFF)
	run("CLIMB", { { "landing_lights", "OFF" }, { "seat_belts", "AUTO" }, { "terrain_nd_fo", "OFF" } })
end)

proc(111, "descent_preparation", "DESCENT PREPARATION", function()
	if not PM_airborne() or PM_altitude() < 10000 then PM_refuse("DESCENT PREPARATION", "Above flight level one hundred only.") return end
	run("DESCENT PREPARATION", { { "cstr_nd_fo", "ON" } })
end)

proc(112, "descent", "DESCENT", function()
	if not PM_airborne() then PM_refuse("DESCENT", "In flight only.") return end
	if PM_vs() > 300 then PM_refuse("DESCENT", "We are not descending.") return end
	run("DESCENT", { { "landing_lights", "ON" }, { "nose_light", "TAKEOFF" }, { "seat_belts", "ON" }, { "ped", "AUTO" },
		{ "terrain_nd_fo", "ON" }, { "cstr_nd_fo", "ON" } })
end)

proc(113, "approach", "APPROACH", function()
	if not PM_airborne() then PM_refuse("APPROACH", "In flight only.") return end
	if PM_vs() > 300 then PM_refuse("APPROACH", "We are not descending.") return end
	set_was_airborne(true)
	run("APPROACH", { { "ground_spoilers", "ARM" }, { "turnoff_lights", "ON" }, { "nose_light", "TAKEOFF" } })
end)

-- GO AROUND, on the pilot's "go around" / "missed approach" (bridge) : below 2500 ft AGL only (higher, the pilot does
-- it). Flaps one step up at once and gear up at positive climb, by itself (pilot's decision 02.11.2026), then the
-- after takeoff items without the packs. A second "going around" (to ATC on the wrong button) within 90 s does nothing.
local GO_AROUND_MAX_AGL_M = 762 -- 2500 ft

proc(118, "go_around", "GO AROUND", function()
	if not PM_airborne() then PM_refuse("GO AROUND", "In flight only.") return end
	if PM_agl_m() > GO_AROUND_MAX_AGL_M then PM_refuse("GO AROUND", "Above two thousand five hundred feet above ground. Your go around.") return end
	set_was_airborne(true)
	PM_bridge_mark() -- her FLAPS / GEAR item pressed on the same words is dropped
	run("GO AROUND", {
		function() -- one step up, without the S / F speed checks of a normal retraction
			local detent = math.floor(get("sim/flightmodel/controls/flaprqst") * 4 + 0.5)
			if detent > 0 then set("sim/flightmodel/controls/flaprqst", (detent - 1) / 4) PM_log("  FLAPS ONE STEP UP (" .. (detent - 1) .. ")") end
		end,
		function() -- gear up at positive climb (waited for at most 120 s)
			if get("sim/cockpit2/controls/gear_handle_down") == 0 then return true end
			if PM_vs() < 200 then return false end
			PM_gear(true)
		end,
		{ "ground_spoilers", "DISARM" }, { "nose_light", "OFF" }, { "turnoff_lights", "OFF" },
		{ "apu_bleed", "OFF" }, { "apu_master", "OFF" } })
end, 90)

--########################################
--# ENGINE START                         #
--########################################
-- Bleed air (APU bleed or HP ground air, duct pressure) -> ENG MODE IGN/START -> masters one after the other in the
-- briefed sequence, each one awaited (N1 >= 17 % for 5 s). ENG MODE stays IGN : NORM is the first after start item.
-- The engine masters are touched by this procedure only.
PM_start_sequence = { 2, 1 }
PM_ES = { state = "idle" }

local function es_fail(text)
	PM_ES = { state = "idle" }
	PM_log("engine start interrupted : " .. text)
	PM_say("Engine start interrupted. " .. text)
end

function PM_engine_start_process()
	local es = PM_ES
	if es.state == "idle" or PM_time < es.wait then return end
	local now = PM_time
	if es.state == "bleed" then
		local hp_air = PM_ref("AirbusFBW/GroundHPAir") == 1
		if not hp_air and not apu_avail() then
			if PM_ref("AirbusFBW/APUMaster") == 1 and now - es.since < 120 then es.wait = now + 1 return end
			PM_ES = { state = "idle" }
			PM_refuse("ENGINE START", "No bleed air. We need the APU bleed or high pressure ground air.")
			return
		end
		if apu_avail() and not hp_air and PM_ref("AirbusFBW/APUBleedSwitch") ~= 1 then PM_set("apu_bleed", "ON") es.wait = now + 4 return end
		local pressure = math.max(PM_ref("AirbusFBW/LeftBleedPress"), PM_ref("AirbusFBW/RightBleedPress"))
		if pressure < 15 then
			es.pressure_since = es.pressure_since or now
			if now - es.pressure_since > 25 then es_fail("No bleed pressure.") return end
			es.wait = now + 1
			return
		end
		if PM_ref("AirbusFBW/OHPLightSwitches", 0) == 0 then PM_set("beacon", "ON") end
		es.state, es.wait = "mode", now + 1
	elseif es.state == "mode" then
		PM_set("eng_mode", "IGNITION")
		es.state, es.wait = "master", now + 4
	elseif es.state == "master" then
		local engine = PM_start_sequence[es.index]
		if PM_n1(engine) >= 17 then
			es.index = es.index + 1
			if es.index > 2 then es.state = "done" end
			return
		end
		command_once("toliss_airbus/engcommands/Master" .. engine .. "On")
		PM_log("  ENG " .. engine .. " MASTER ON")
		es.state, es.started, es.stable_since, es.wait = "spool", now, nil, now + 2
	elseif es.state == "spool" then
		local engine = PM_start_sequence[es.index]
		if PM_n1(engine) >= 17 then
			es.stable_since = es.stable_since or now
			if now - es.stable_since >= 5 then
				PM_log("  ENG " .. engine .. " AVAIL")
				es.index = es.index + 1
				if es.index > 2 then es.state, es.wait = "done", now + 1 else es.state, es.wait = "master", now + 3 end
			end
		elseif now - es.started > 150 then
			es_fail("Engine " .. engine .. " not stabilized. Check the ECAM.")
		end
	elseif es.state == "done" then
		PM_log("ENGINE START done : both engines running")
		PM_say("Engine start procedure done. Both engines running.")
		PM_ES = { state = "idle" }
	end
end
do_every_frame("PM_engine_start_process()")

local pending_sequence = nil -- a sequence said in the confirmation ("confirm, sequence one two")

-- The bridge starts it from the pilot's words ("engine start procedure", 02.11.2026 : she said "starting the engines"
-- and pressed nothing) ; she may press the item too. While the question waits :
--   - the bridge again ("confirm, sequence two one") : the pilot's confirmation, with that sequence ;
--   - her press within 10 s of the question : the same pilot phrase, ignored (it must never confirm by itself) ;
--   - her press later : the pilot's "confirm engine start ..." she took for an order, his confirmation.
local function engine_start(first, second, source)
	local label = "ENGINE START"
	if PM_pending_confirm ~= nil and PM_pending_confirm.label == label then
		local asked = PM_pending_confirm.expires - 45
		if source == "her" and PM_time - asked < 10 then PM_log(label .. " : her item, the question is already asked") return end
		if first ~= nil then pending_sequence = { first, second } end
		PM_confirm()
		return
	end
	if PM_ES.state ~= "idle" then
		-- her press of the item right after the pilot's "confirm sequence two one" : the start already runs
		if PM_time - PM_ES.since < 20 then PM_log(label .. " asked again : already running") return end
		PM_refuse(label, "Engine start already in progress.")
		return
	end
	if not PM_on_ground(10) then PM_refuse(label, "On ground, below ten knots only.") return end
	if PM_ref("AirbusFBW/OHPLightSwitches", 0) == 0 then PM_refuse(label, "Before start procedure not done, beacon off.") return end
	local doors = open_doors()
	if doors ~= "" then PM_refuse(label, "Doors open : " .. doors .. ".") return end
	if PM_both_engines_running() then PM_refuse(label, "Both engines are already running.") return end
	local sequence = { first or PM_start_sequence[1], second or PM_start_sequence[2] }
	PM_ask_confirm("Confirm engine start, sequence " .. sequence[1] .. " " .. sequence[2] .. "?", label, function()
		PM_start_sequence = pending_sequence or sequence -- the sequence said in the confirmation wins
		pending_sequence = nil
		PM_ES = { state = "bleed", index = 1, wait = PM_time + 1, since = PM_time }
		PM_log("ENGINE START, sequence " .. PM_start_sequence[1] .. " - " .. PM_start_sequence[2])
	end)
end

proc(103, "engine_start", "ENGINE START (briefed sequence, 2-1 by default)", function(source) engine_start(nil, nil, source) end, true)
proc(104, "engine_start_21", "ENGINE START, sequence 2-1", function(source) engine_start(2, 1, source) end, true)
proc(105, "engine_start_12", "ENGINE START, sequence 1-2", function(source) engine_start(1, 2, source) end, true)
proc(117, "engine_start_abort", "stop the ENGINE START", function()
	if PM_ES.state ~= "idle" then PM_ES = { state = "idle" } PM_log("Engine start stopped.") PM_say("Engine start stopped. Running engines keep running.") end
end, true)

--########################################
--# F/O CHRONO AT THE TAKEOFF ROLL       #
--########################################
-- Started once per takeoff, by itself (asked by the pilot) : on ground, both engines at takeoff thrust
-- (N1 >= 75 %), ground speed above 30 kt. The clock on the main panel is left to the pilot.
local chrono_done = false
function PM_chrono_watch()
	if PM_airborne() then return end
	local gs = PM_gs_kt()
	if gs < 5 then chrono_done = false return end
	if chrono_done or gs < 30 or PM_n1(1) < 75 or PM_n1(2) < 75 then return end
	chrono_done = true
	if PM_ref("AirbusFBW/ChronoTimeND2") == 0 then
		command_once("AirbusFBW/CoChronoButton")
		PM_log("takeoff roll : F/O ND chrono started")
	end
end
do_often("PM_chrono_watch()")
