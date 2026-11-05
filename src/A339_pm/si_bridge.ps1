# Speedy Copilot A339 edition - SayIntentions.AI bridge.
# The SayIntentions co-pilot acts on the aircraft through the co-pilot own checklist items (SpeedyCopilot/si/order) ;
# our PM validates every action. This bridge only carries what the co-pilot's items cannot :
#   - the pilot's answer to a read back ("Confirm") : SpeedyCopilot/confirm over UDP ;
#   - the PM's read backs and refusals, said by the SayIntentions co-pilot (SAPI sayAs), since our PM is silent ;
#   - the numbers for the FCU, QNH and squawk, from the pilot's words to the co-pilot and from the ATC instructions.
# Started by Speedycopilot_A339_voice.lua, stops when X-Plane closes. Windows PowerShell 5.1.
#
#   -Test file   print what each line of a text file would give, then exit (no network)
#   -DryRun      fetch the comms history once and print what would be done, then exit
param(
    [int]$Port = 49052,
    [string]$DevKeyFile = "",   # default : si_dev_key.txt next to this script
    [double]$Interval = 1.0,
    [string]$Test,
    [switch]$Tsv,   # with -Test : "phrase<TAB>result" lines (tests\run_tests.ps1)
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$dir = $PSScriptRoot
$statusFile = Join-Path $dir "si_bridge_status.txt"
$logFile = Join-Path $dir "si_bridge_log.txt"
$quitFlag = Join-Path $dir "si_bridge_quit.flag"
$sayQueue = Join-Path $dir "si_say_queue.txt"
$flightJson = Join-Path $env:LOCALAPPDATA "SayIntentionsAI\flight.json"
$api = "https://apipri.sayintentions.ai/sapi/"

#########################################
# UNDERSTANDING THE PILOT               #
#########################################

function Normalize([string]$text) {
    $t = $text.ToLower() -replace "[’']", ""
    $t = $t -replace "[^a-z0-9 ]", " "
    return (($t -replace "\s+", " ").Trim())
}

# answer to a read back ("Confirm engine start ?") : only when it is the whole phrase
$CONFIRM = "^((okay|ok|yes|yeah|yep) )?(confirm|confirmed|affirm|affirmative|correct|thats correct|confirm that|go ahead|yes|yeah|yep)( please| sir| captain| mate)?$"

# "confirm engine start, sequence two one", "affirmative, go ahead" : a phrase that starts with confirm / affirm
# (the PM ignores it when nothing waits for a confirmation). In flight the pilot said "Confirm sequence 2-1" twice.
$CONFIRM_START = "^((okay|ok|yes|yeah|yep) )?(confirm|confirmed|affirm|affirmative) "
$CONFIRM_NOT = " (dont|do not|not|negative|cancel|abort|stop|wait) "

# "<name> procedure" without the word checklist : the bridge starts the procedure itself. Procedures and the co-pilot's own
# checklists are kept apart by that word : in flight the co-pilot said "okay" to "approach procedure" and pressed nothing,
# and opened the co-pilot's After Landing / Parking checklists on "... procedure". The co-pilot's own press of the item as well is started
# once (the PM ignores the same procedure again within 15 s). Engine start stays with the co-pilot's items (its read back).
$PROCEDURES = [ordered]@{
    "preliminary" = "preliminary"; "cockpit prep(aration)?" = "cockpit_preparation"; "before start" = "before_start"
    "after start" = "after_start"; "after take ?off" = "after_takeoff"; "after landing" = "after_landing"
    "taxi" = "taxi"; "line ?up" = "lineup"; "climb" = "climb"; "(descent|the scent|decent|dissent) prep(aration)?" = "descent_preparation"
    "(descent|the scent|decent|dissent)" = "descent"; "approach" = "approach"; "parking|parker" = "parking"; "securing|secure" = "securing"
}
$PROCEDURE_NOT = " (check ?list|checklists|done|complete|completed|finished|engine|engines|missed|expect|abort|stop|cancel|dont|do not|not yet|wait|hold on|negative|belay|never mind|disregard|later) "

# "go around" / "missed approach" : the PM's GO AROUND procedure (below 2500 ft AGL). Not when the words name the
# go around altitude (landing checklist), a briefing or a plan.
$GO_AROUND_NOT = " (altitude|alt|checklist|brief|briefing|plan|planned|if|in case|expect|expected|published|done|complete|completed|dont|do not|not|negative|cancel|disregard|never mind) "

# engine start ("engine start procedure", "start engines", "sequence two one") : the co-pilot said "starting the engines now"
# and pressed nothing (02.11.2026). The PM asks for the confirmation ; a phrase with only the sequence is one too.
function Get-EngineStart([string]$t) {
    $s = " $t "
    $sequence = $null
    if ([regex]::IsMatch($s, " sequence (2|two) ?(1|one) ")) { $sequence = "engine_start_21" }
    elseif ([regex]::IsMatch($s, " sequence (1|one) ?(2|two) ")) { $sequence = "engine_start_12" }
    if ([regex]::IsMatch($s, " (check ?list|abort|stop|cancel|done|complete|completed|after|dont|do not|not yet|wait|hold on|negative|disregard|never mind) ")) { return $null }
    if ([regex]::IsMatch($s, "^ (what|whats|is|are|should|shall|why|how|when|where|do we|did|have we|can i) ")) { return $null }
    if ([regex]::IsMatch($s, " (engine|engines) start | start (the )?(engine|engines) ")) { if ($sequence) { return $sequence } else { return "engine_start" } }
    return $sequence   # "confirm sequence 21"
}

function Get-GoAround([string]$t) {
    if (-not [regex]::IsMatch(" $t ", " (go around|going around|goaround|missed approach) ")) { return $false }
    if ([regex]::IsMatch(" $t ", $GO_AROUND_NOT)) { return $false }
    return -not [regex]::IsMatch(" $t ", "^ (what|whats|is|are|should|shall|why|how|when|where|do we|did|have we|can i) ")
}

function Get-Procedure([string]$t) {
    if (-not [regex]::IsMatch(" $t ", " procedures? ") -or [regex]::IsMatch(" $t ", $PROCEDURE_NOT)) { return $null }
    if ([regex]::IsMatch(" $t ", "^ (what|whats|is|are|should|shall|why|how|when|where|do we|did|have we|can i) ")) { return $null }   # questions
    foreach ($name in $PROCEDURES.Keys) {
        if ([regex]::IsMatch(" $t ", " ($name) ")) { return $PROCEDURES[$name] }
    }
    return $null
}

# Items the co-pilot pressed wrong in flight : the bridge sends their codes itself (SI|ORDER|n), the PM drops the co-pilot's own press of
# the same kind. "flaps one" -> FLAPS TWO, "start APU" -> APU MASTER ON only, "all anti ice off" -> engine anti ice only.
$FLAPS = @{ "up" = 10; "zero" = 10; "0" = 10; "one" = 11; "1" = 11; "two" = 12; "2" = 12; "three" = 13; "3" = 13; "tree" = 13
            "full" = 14; "four" = 14; "4" = 14 }

function Get-BridgeOrders([string]$t) {
    $orders = @()
    # heard as "flips two", "laps up", "clips three"
    $m = [regex]::Match(" $t ", " (flaps|flap|flips|flats|laps|claps|clips|lips) (to |config |conf )?(up|zero|0|one|1|two|2|three|3|tree|full|four|4) ")
    if ($m.Success) { $orders += "ORDER|" + $FLAPS[$m.Groups[3].Value] }
    if ([regex]::IsMatch(" $t ", " (start|starting) (the |our )?(apu|api) | (apu|api) (start|on and start) ")) { $orders += "ORDER|1510" }
    # gear ("Gear up" : the co-pilot said "gear coming up" and pressed nothing, 02.11.2026 ; "Girdown")
    # also the co-pilot's answer "gear coming up"
    $m = [regex]::Match(" $t ", " (landing )?(gear|gears|gir|girl|year) (is |coming |going )?(up|down) | (girdown|gearup|geardown|girup) ")
    if ($m.Success) { $orders += "ORDER|" + $(if (($m.Groups[4].Value + $m.Groups[5].Value) -match "up") { 20 } else { 21 }) }
    # nose light ("nose lights off" was heard as "no its lights off", the co-pilot switched the runway turn off lights) and
    # runway turn off lights : "<light> off" or "turn off (the) <light>"
    $nose = "(nose|noes|knows|no its|no is|taxi|takes a)"
    $m = [regex]::Match(" $t ", " $nose lights? (to )?(off|on|taxi|take ?off) | (turn|switch|set) (off|on) (the )?$nose lights? ")
    if ($m.Success) {
        $word = $m.Groups[3].Value + $m.Groups[5].Value
        $orders += "ORDER|" + $(if ($word -eq "off") { 1930 } elseif ($word -match "^take ?off$") { 1932 } else { 1931 })
    }
    $turnoff = "(runway turn ?off|turnoff)"
    $m = [regex]::Match(" $t ", " $turnoff lights? (off|on) | (turn|switch) (off|on) (the )?$turnoff lights? ")
    if ($m.Success) { $orders += "ORDER|" + $(if (($m.Groups[2].Value + $m.Groups[4].Value) -eq "off") { 1951 } else { 1950 }) }
    # all anti ice (engines and wings) : "all anti ice off", "turn off all anti ice", "anti ice off" (no engine / wing)
    if ([regex]::IsMatch(" $t ", " anti ?ice ")) {
        $all = [regex]::IsMatch(" $t ", " all ") -or -not [regex]::IsMatch(" $t ", " (engine|engines|eng|wing|wings) ")
        $off = [regex]::IsMatch(" $t ", " off ")
        $on = [regex]::IsMatch(" $t ", " on ")
        if ($all -and $off -and -not $on) { $orders += "ORDER|1621"; $orders += "ORDER|1631" }
        elseif ($all -and $on -and -not $off -and [regex]::IsMatch(" $t ", " all ")) { $orders += "ORDER|1620"; $orders += "ORDER|1630" }
    }
    return $orders
}

#########################################
# EVERY ITEM THE CO-PILOT KNOWS (si_items.json)
#########################################
# The co-pilot is unreliable at pressing the co-pilot's items (02.11.2026 : after a SayIntentions update the co-pilot pressed none at all) : the
# bridge finds the item in the pilot's words itself and sends its code. The co-pilot's items stay, so that the co-pilot answers right.
# The pilot's words and the item names go through the same aliases, then a phrase segment must hold every required
# word of the item name and its position ("landing lights on", "turn off the seat belts", "TCAS TA RA").

$itemsFile = @((Join-Path $PSScriptRoot "si_items.json"), (Join-Path $PSScriptRoot "..\..\docs\si_items.json")) |
    Where-Object { Test-Path $_ } | Select-Object -First 1
$ITEMS = @()
if ($itemsFile) { $ITEMS = @((Get-Content $itemsFile -Raw | ConvertFrom-Json) | ForEach-Object { $_ }) }   # PS 5.1 : unroll the array

# spoken names -> one word ; applied in this order to both sides
$ALIASES = [ordered]@{
    " (seat ?belts?|sit belts?|seatbelts?)( signs?)? " = " seatbelt "
    " (no )?(portable (electronic )?devices?|electronic devices?|ped|no smoking)( signs?)? " = " ped "
    " (nav|navigation|no) and logo " = " navlogo "; " (nav|navigation|logo) lights? " = " navlogo light "
    " (pack|packs|puck|pac|pak|pact|back|buck)( |s )?flow " = " pack flow "; " (pack|puck|pac|pak|pact|back|buck)s?flow " = " pack flow "
    " navigation " = " nav "; " owen " = " on "; " vipers? " = " wiper "; " trim tank " = " tail tank "
    " (lock|locked) " = " shut "; " unlock " = " open "
    " (adirs|adiru|adirus|aders|adios|editors|irs) " = " adirs "; " (att|attitude) " = " att "
    " left wipers? " = " captain wiper "; " right wipers? " = " fo wiper "
    " (captain|capt|captains) " = " captain "; " (first officer|f o|fo|copilot|co pilot) " = " fo "
    " (weather radar|wx radar|wx) " = " radar "
    " (predictive windshear|predictive wind shear|pred ws|windshear|wind shear) " = " pws "
    " (tee cas|t cas) " = " tcas "; " (ta ?ra|ta slash ra|ta and ra) " = " tara "; " ta only " = " taonly "
    " (stby|stand by) " = " standby "
    " auto ?brakes? " = " autobrake "; " med " = " medium "; " maximum " = " max "
    " (ground )?(spoilers?|speed ?brakes?) " = " spoiler "
    " (cross ?bleeds?|x ?bleed) " = " crossbleed "; " (fuel )?(cross ?feed|x ?feed) " = " crossfeed "
    " (closed|close) " = " shut "
    " park(ing)? brakes? " = " parkbrake "
    " (flight directors?|f ?ds?) " = " fd "
    " (landing|linden) lights? " = " landing light "; " (wing|wind) lights? " = " wing light "
    " strobes? " = " strobe "; " (dome|interior|cockpit) lights? " = " dome light "
    " (emer|emergency) exit( lights?)? " = " emerexit light "
    " (external|ext) (power|pwr) | ground power " = " extpower "
    " (probe (and )?window heat|probe heat|window heat|probes) " = " probeheat "
    " (crew )?(oxygen|oxy) " = " crewoxygen "
    " (engine|eng) mode( selector)? | mode selector " = " engmode "
    " (ign|ignition)( start)? " = " ignition "; " norm " = " normal "
    " (takeoff|take off|t o) config " = " toconfig "
    " (take ?off|t o) " = " takeoff "
    " (hpa|hectopascals) " = " hectopascal "; " (in ?hg|inch) " = " inches "
    " (baro|barometers?|borrow|borough|barrow|bar or) " = " barometer "; " std " = " standard "
    " (q a|q and a|q n h|qna) " = " qnh "
    " api " = " apu "; " (batt|bat|bats) " = " battery "; " gen " = " generator "
    " (xpdr|squawk) " = " transponder "
    " (auto pilot|ap) " = " autopilot "; " (auto ?thrust|athr|a thr) " = " autothrust "
    " (loc|localiser) " = " localizer "; " appr " = " approach "
    " hdg " = " heading "; " trk " = " track "; " (vs|v s|vertical speed) " = " verticalspeed "
    " eng " = " engine "; " anti ?ice " = " antiice "
    " cstr " = " constraint "; " terr " = " terrain "
    " navigation display " = " nd "; " recorder (gnd |ground )?(ctl|control) " = " recorder "
    " one " = " 1 "; " two " = " 2 "; " three " = " 3 "; " four " = " 4 "
}
$ITEM_STOP = @("on", "and", "the", "of", "to", "set")                       # not part of a name
$ITEM_OPTIONAL = @("sign", "light", "system", "button", "knob", "switch", "supply", "all", "fuel", "nd", "mode", "ecam", "ir", "forward", "transfer")
$ITEM_ACTIONS = @("press", "test", "engage", "reset")                       # a one-action item ("ECAM RECALL - PRESS")
$ACTION_WORDS = @("press", "push", "hit", "engage", "test", "reset", "activate", "select", "set", "on", "arm")
$SELF_ACTION = @("recall", "clear", "cancel", "ident")                      # its name says the action ("ECAM recall")
# a position word the pilot uses for an item that has no such position : "interior light on" = DOME BRIGHT
# "pack flow auto" = NORMAL (the selector has LO / NORM / HI)
$POSITION_ALT = @{ "bright" = "on"; "set" = "on"; "release" = "off"; "shut" = "off"; "engage" = "on"; "standby" = "off"; "normal" = "auto" }
$KEEP_S = @("status", "adirs", "tcas", "gpws", "pws", "bus", "press", "ecas")

function Canonical([string]$text) {
    $s = " " + (Normalize $text) + " "
    foreach ($k in $ALIASES.Keys) { $s = [regex]::Replace($s, $k, $ALIASES[$k]); $s = $s -replace "\s+", " " ; if (-not $s.StartsWith(" ")) { $s = " $s" }; if (-not $s.EndsWith(" ")) { $s = "$s " } }
    $words = foreach ($w in ($s.Trim() -split " ")) {
        if ($w -match "ies$") { $w -replace "ies$", "y" }
        elseif ($w.Length -gt 3 -and $w -match "[^s]s$" -and $KEEP_S -notcontains $w) { $w.Substring(0, $w.Length - 1) }
        else { $w }
    }
    return " " + ($words -join " ") + " "
}

# the items, once : required / optional name words and the position words of each
$ITEM_INDEX = @()
foreach ($group in ($ITEMS | Where-Object { [int]$_.code -ge 200 } | Group-Object challenge)) {
    $name = @((Canonical $group.Name).Trim() -split " " | Where-Object { $_ -ne "" -and $ITEM_STOP -notcontains $_ })
    $positions = @($group.Group | ForEach-Object { @{ code = [int]$_.code; words = @((Canonical $_.response).Trim() -split " "); text = "$($_.challenge) $($_.response)" } })
    $own = @($positions | ForEach-Object { $_.words[0] })
    foreach ($p in $positions) {
        $alt = $POSITION_ALT[$p.words[0]]
        if ($p.words.Count -eq 1 -and $alt -and $own -notcontains $alt) { $p.alt = $alt }
    }
    $ITEM_INDEX += @{ name = $group.Name; required = @($name | Where-Object { $ITEM_OPTIONAL -notcontains $_ }); optional = @($name | Where-Object { $ITEM_OPTIONAL -contains $_ }); positions = $positions }
}
$ITEM_TEXT = @{}; foreach ($i in $ITEMS) { $ITEM_TEXT[[int]$i.code] = "$($i.challenge) $($i.response)" }

function Find-Item([string[]]$words, [string[]]$phraseWords) {
    $best = $null; $bestScore = 0; $tie = $false
    foreach ($item in $ITEM_INDEX) {
        if ($item.required.Count -eq 0) { continue }
        $missing = @($item.required | Where-Object { $words -notcontains $_ })
        if ($missing.Count -gt 0) { continue }
        # the position said in this part of the phrase, else anywhere in it ("radar and pws off") ; several said :
        # the last one ("seat belts currently in auto, set to on")
        $found = $null
        foreach ($pool in @(, $words) + @(, $phraseWords)) {
            $at = -1
            foreach ($p in $item.positions) {
                $said = if (@($p.words | Where-Object { $pool -notcontains $_ }).Count -eq 0) { $p.words[-1] } elseif ($p.alt -and $pool -contains $p.alt) { $p.alt } else { $null }
                if ($said -eq $null) { continue }
                $index = [array]::LastIndexOf($pool, $said)
                if ($index -gt $at -or ($index -eq $at -and $p.words.Count -gt $found.words.Count)) { $found = $p; $at = $index }
            }
            if ($found -ne $null) { break }
        }
        if ($found -eq $null -and $item.positions.Count -eq 1 -and $ITEM_ACTIONS -contains $item.positions[0].words[0] -and
            (@($ACTION_WORDS | Where-Object { $words -contains $_ }).Count -gt 0 -or @($SELF_ACTION | Where-Object { $item.required -contains $_ }).Count -gt 0)) { $found = $item.positions[0] }
        if ($found -eq $null) { continue }
        $score = $item.required.Count * 10 + @($item.optional | Where-Object { $words -contains $_ }).Count + $found.words.Count
        if ($score -gt $bestScore) { $best = $found; $bestScore = $score; $tie = $false }
        elseif ($score -eq $bestScore -and $best.code -ne $found.code) { $tie = $true }
    }
    if ($tie) { return $null }   # two items fit as well : nothing rather than the wrong one
    return $best
}

function Get-ItemOrders([string]$t) {
    $orders = @()
    if ([regex]::IsMatch(" " + (Normalize $t) + " ", " (procedures?|check ?list|checklists) ")) { return $orders }
    $s = Canonical $t
    $phraseWords = @($s.Trim() -split " ")
    # parts : "strobe on, landing lights off", "radar and pws off" (the commas are in the original text)
    $parts = foreach ($piece in ($t -split "[,;.!?]")) { (Canonical $piece) -split " (and|then|also|plus) " }
    foreach ($part in $parts) {
        $words = @($part.Trim() -split " " | Where-Object { $_ -ne "" })
        if ($words.Count -eq 0) { continue }
        $item = Find-Item $words $phraseWords
        if ($item -ne $null) { $orders += "ORDER|" + $item.code }
    }
    return $orders
}

# The co-pilot's answer, when the pilot's words gave nothing ("Puckflow High" -> the co-pilot said "Sure, setting pack flow high") :
# the items in the co-pilot's words, only when the co-pilot confirms an action ("sure, setting / switching / turning ...") and never
# when the co-pilot asks, doubts or reads a checklist line. Switch items only (no procedure, no number).
$REPLY_ACTION = " (setting|set|switching|switched|turning|turned|arming|armed|disarming|engaging|engaged|selecting|selected|starting|opening|closing|releasing|pressing|pushing|pulling|coming|going) "
$REPLY_NOT = " (not|cant|cannot|unable|dont|do not|isnt|wont|say again|clarify|which|what|unclear|sorry|maybe|should i|shall i|want me|do you|did you|let me know|if you) "

function Get-ReplyOrders([string]$reply) {
    if ($reply -match "\?") { return @() }   # the co-pilot's question, or a checklist line ("Seat belts???")
    $t = " " + (Normalize $reply) + " "
    $agrees = [regex]::IsMatch($t, $REPLY_ACTION) -or [regex]::IsMatch($t, "^ (sure|okay|ok|roger|copy|got it|will do|done|affirm|wilco|right) ")   # "Sure, strobe lights on"
    if (-not $agrees -or [regex]::IsMatch($t, $REPLY_NOT)) { return @() }
    if ([regex]::IsMatch($t, " (procedures?|check ?list|checklists) ")) { return @() }
    $orders = @(Get-BridgeOrders $t.Trim())
    foreach ($o in @(Get-ItemOrders $reply)) { if ($orders -notcontains $o) { $orders += $o } }
    return $orders
}

# the pilot's phrase gave nothing, but it was not a question, a negation, a checklist answer or chat with ATC words :
# the co-pilot's answer may be read
function Test-ReplyWorth([string]$phrase) {
    $t = " " + (Normalize $phrase) + " "
    if ([regex]::IsMatch($t, $NEGATION) -or [regex]::IsMatch($t, $REQUEST)) { return $false }
    if ([regex]::IsMatch($t, "^ (what|whats|is|are|should|shall|why|how|when|where|do we|did|have we|can i|hello|hi|hey|thank|thanks) ")) { return $false }
    if ([regex]::IsMatch($t, " (procedures?|check ?list|checklists) ")) { return $false }
    return @($t.Trim() -split " ").Count -ge 2   # "Check", "Set", "Removed" : checklist answers
}

# for the log : "ORDER|1940" -> "LANDING LIGHTS ON", "SpeedyCopilot/proc/taxi" -> "proc/taxi"
function Show-Order([string]$o) {
    if ($o -match "^ORDER\|(\d+)$" -and $ITEM_TEXT.ContainsKey([int]$Matches[1])) { return $ITEM_TEXT[[int]$Matches[1]] }
    return ($o -replace "^SpeedyCopilot/", "")
}

function Get-Orders([string]$text) {
    $orders = @()
    $t = Normalize $text
    $engines = Get-EngineStart $t
    if ([regex]::IsMatch($t, $CONFIRM) -or ([regex]::IsMatch("$t ", $CONFIRM_START) -and -not [regex]::IsMatch(" $t ", $CONFIRM_NOT))) {
        # "confirm, sequence two one" : the engine start with that sequence confirms the waiting question
        if ($engines -and $engines -ne "engine_start") { $orders += "SpeedyCopilot/proc/$engines" }
        else { $orders += "SpeedyCopilot/confirm" }
    } elseif ([regex]::IsMatch(" $t ", " (abort|stop|cancel) (the )?(engine start|engines? start|start) | (engine start|start) (abort|stop) ")) {
        $orders += "SpeedyCopilot/proc/engine_start_abort"
    } elseif ($engines) {
        $orders += "SpeedyCopilot/proc/$engines"
    } elseif (Get-GoAround $t) {
        $orders += "SpeedyCopilot/proc/go_around"
    } else {
        $procedure = Get-Procedure $t
        if ($procedure) { $orders += "SpeedyCopilot/proc/$procedure" }
        elseif (-not [regex]::IsMatch(" $t ", $NEGATION) -and -not [regex]::IsMatch(" $t ", "^ (what|whats|is|are|should|shall|why|how|when|where|do we|did|can i) ")) {
            $orders += @(Get-BridgeOrders $t)
            foreach ($o in @(Get-ItemOrders $text)) { if ($orders -notcontains $o) { $orders += $o } }   # with its commas
        }
    }
    return $orders   # callers wrap it : @(Get-Orders ...)
}

#########################################
# NUMBERS : FCU, QNH, SQUAWK            #
#########################################
# The co-pilot's checklist items carry a fixed value only : the bridge reads the numbers, in the pilot's words to the co-pilot
# ("heading one seven five") and in the ATC instructions (used by the PM only when the co-pilot handles the radio).

$WORDNUM = @{ "zero" = "0"; "oh" = "0"; "one" = "1"; "two" = "2"; "three" = "3"; "tree" = "3"; "four" = "4"; "fower" = "4"
              "five" = "5"; "fife" = "5"; "six" = "6"; "seven" = "7"; "eight" = "8"; "nine" = "9"; "niner" = "9"
              "point" = "."; "decimal" = "." }
$NEGATION = " (dont|do not|not yet|wait|hold on|negative|belay|cancel that|never mind|disregard|later) "
$REQUEST = " (request|requesting|ask|asking|tell|call|contact|check with|inform|atc|dispatcher|dispatch|control|controller|center) "

# "turn right heading one seven five, climb five thousand" -> "turn right heading 175 climb 5000"
function Digitize([string]$text) {
    $t = $text.ToLower() -replace "[’']", ""
    $t = [regex]::Replace($t, "\bfl(\d)", 'fl $1')           # ATC writes "Climb FL360"
    $t = [regex]::Replace($t, "(\d),(\d{3})", '$1$2')        # 5,000
    $t = [regex]::Replace($t, "(\d)\.(\d)", '$1#$2')          # keep 29.92 together
    $t = $t -replace "[^a-z0-9# ]", " "
    $out = New-Object System.Collections.ArrayList
    foreach ($w in ($t -split "\s+" | Where-Object { $_ -ne "" })) {
        $w = $w -replace "#", "."
        if ($WORDNUM.ContainsKey($w)) { $w = $WORDNUM[$w] }
        $last = if ($out.Count) { $out[$out.Count - 1] } else { "" }
        # spoken digits are joined : "1 7 5" -> "175", "2 9 . 9 2" -> "29.92"
        if ($last -match "^[\d\.]+$" -and $w -match "^[\d\.]+$" -and ($w.Length -eq 1 -or $last.EndsWith("."))) { $out[$out.Count - 1] = $last + $w }
        else { [void]$out.Add($w) }
    }
    $s = " " + ($out -join " ") + " "
    $s = [regex]::Replace($s, " (\d+) thousand (\d) hundred ", { param($m) " " + ([int]$m.Groups[1].Value * 1000 + [int]$m.Groups[2].Value * 100) + " " })
    $s = [regex]::Replace($s, " (\d+) thousand ", { param($m) " " + ([int]$m.Groups[1].Value * 1000) + " " })
    $s = [regex]::Replace($s, " (\d+) hundred ", { param($m) " " + ([int]$m.Groups[1].Value * 100) + " " })
    $s = $s -replace " (flight|flat|flight s|fly|flite) level ", " fl "   # SayIntentions heard "flat level 220"
    return $s
}

# values in a phrase : "HDG|175", "ALT|35000", "SPD|250", "MACH|0.78", "SPDMANAGED|1", "QNH|1013", "SQUAWK|4721" ;
# a knob value may carry the pilot's "push" / "pull" : "ALT|22000|PUSH"
function Get-Values([string]$text, [switch]$Pilot) {
    $values = @()
    $s = Digitize $text
    if ([regex]::IsMatch($s, $NEGATION)) { return $values }
    # the pilot asks the co-pilot to request it from ATC ("can you request flight level 350") : a request, not a value to set
    if ($Pilot -and [regex]::IsMatch($s, $REQUEST)) { return $values }
    # the pilot's questions ; not for ATC ("When ready descend FL290" was skipped as a question)
    if ($Pilot -and [regex]::IsMatch($s, "^ (what|whats|is|are|should|shall|why|how|when|where|do we|did) ")) { return $values }
    # FCU knobs : value and where it ends in the phrase (an optional "push" / "pull" after it goes with it)
    $knobs = @()
    $m = [regex]::Match($s, " heading (\d{1,3}) ")
    if ($m.Success) { $knobs += @{ v = "HDG|" + [int]$m.Groups[1].Value; at = $m.Index + $m.Length } }
    $m = [regex]::Match($s, " fl (\d{2,3}) ")
    if ($m.Success) { $knobs += @{ v = "ALT|" + ([int]$m.Groups[1].Value * 100); at = $m.Index + $m.Length } }
    else {
        $m = [regex]::Match($s, " (climb|descend|maintain|altitude)( and maintain| to| altitude)*( to)? (\d{3,5})( feet| ft)? ")
        if ($m.Success) { $knobs += @{ v = "ALT|" + [int]$m.Groups[4].Value; at = $m.Index + $m.Length } }
    }
    $m = [regex]::Match($s, " mach (0?\.\d{1,2}) ")
    if ($m.Success) { $knobs += @{ v = "MACH|" + [double]("0" + ($m.Groups[1].Value -replace "^0", "")); at = $m.Index + $m.Length } }
    elseif ([regex]::IsMatch($s, " (speed managed|managed speed|resume normal speed|normal speed|no speed restriction|no atc speed restriction) ")) { $values += "SPDMANAGED|1" }
    else {
        $m = [regex]::Match($s, " speed( to)? (\d{3}) | (\d{3}) knots ")
        if ($m.Success) { $knobs += @{ v = "SPD|" + [int]($m.Groups[2].Value + $m.Groups[3].Value); at = $m.Index + $m.Length } }
    }
    # optional, only when said : "flight level 220 and push", "heading 175 pull", "speed 250 selected"
    foreach ($w in [regex]::Matches($s, " (push|pushed|pull|pulled)( it)? | (managed|selected) ")) {
        $word = ($w.Groups[1].Value + $w.Groups[3].Value)
        if ($word -eq "managed" -or $word -eq "selected") {
            if (-not [regex]::IsMatch($s.Substring(0, $w.Index + 1), "\d $")) { continue }   # only right after the number
        }
        $mode = if ($word -match "^(push|pushed|managed)$") { "PUSH" } else { "PULL" }
        $owner = $knobs | Where-Object { $_.at -le $w.Index + 1 } | Sort-Object { $_.at } | Select-Object -Last 1
        if ($owner -ne $null -and -not $owner.mode) { $owner.mode = $mode }
    }
    foreach ($k in $knobs) { $values += $(if ($k.mode) { $k.v + "|" + $k.mode } else { $k.v }) }
    # "set QNH to 1012" was heard as "set Q&A to 1012"
    $m = [regex]::Match($s, " (qnh|q n h|q a|q and a|qna|altimeter|baro|barometer)s?( setting)?( set)?( to)? (\d{2,4}(\.\d+)?) ")
    if ($m.Success) {
        $raw = $m.Groups[5].Value
        $v = [double]$raw
        if ($raw -notmatch "\." -and $v -ge 2700 -and $v -le 3200) { $v = $v / 100 }   # "altimeter two niner niner two"
        $values += "QNH|" + $v.ToString([Globalization.CultureInfo]::InvariantCulture)
    }
    $m = [regex]::Match($s, " (squawk|squawking|squak|squark|squeak|transponder|transponder code|code) ([0-7]{4}) ")
    if ($m.Success) { $values += "SQUAWK|" + $m.Groups[2].Value }
    else {
        # SayIntentions hears "squawk 4456" as "that's 4456" : a whole phrase "<word> four octal digits"
        $m = [regex]::Match($s, "^ (thats|that is|swat|quack|squad|scott|squat|swa) ([0-7]{4}) $")
        if ($m.Success) { $values += "SQUAWK|" + $m.Groups[2].Value }
    }
    return $values   # callers wrap it : @(Get-Values ...)
}

if ($Test) {
    foreach ($line in Get-Content $Test) {
        if ($line.Trim() -eq "" -or $line.StartsWith("#")) { continue }
        if ($line.StartsWith("ATC:")) { $found = @(Get-Values $line.Substring(4)) }   # an ATC instruction
        elseif ($line -match "^PAIR:(.*)=>(.*)$") {   # "PAIR:the pilot's words => the co-pilot's answer"
            $pilot = @(Get-Orders $Matches[1]) + @(Get-Values $Matches[1] -Pilot)
            if ($pilot.Count -gt 0) { $found = @("pilot: " + (($pilot | ForEach-Object { Show-Order $_ }) -join " + ")) }
            elseif (Test-ReplyWorth $Matches[1]) { $found = @(Get-ReplyOrders $Matches[2] | ForEach-Object { "copilot: " + (Show-Order $_) }) }
            else { $found = @() }
        }
        else { $found = @(Get-Orders $line | ForEach-Object { Show-Order $_ }) + @(Get-Values $line -Pilot) }
        $shown = if ($found.Count -gt 0) { $found -join " + " } else { "-" }
        if ($Tsv) { "$line`t$shown" } else { "{0,-62} -> {1}" -f $line, $shown }
    }
    exit
}

#########################################
# SAYINTENTIONS                         #
#########################################

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Now-Unix { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
function Write-Log($text) {
    $line = (Get-Date -Format "HH:mm:ss") + "  " + $text
    Write-Host $line
    Add-Content -Path $logFile -Value $line -Encoding UTF8
}
function Write-Status($state, $last) { try { [IO.File]::WriteAllText($statusFile, "$(Now-Unix)|$state|$last") } catch { } }

function Get-ApiKey {
    try { return ((Get-Content $flightJson -Raw | ConvertFrom-Json).flight_details.api_key) } catch { return $null }
}

function Invoke-Sapi($endpoint, $query) {
    $pairs = @()
    foreach ($k in $query.Keys) { $pairs += ($k + "=" + [uri]::EscapeDataString([string]$query[$k])) }
    return Invoke-RestMethod -Uri ($api + $endpoint + "?" + ($pairs -join "&")) -Headers @{ "X-Developer-Key" = $script:devKey } -TimeoutSec 10
}

# the co-pilot's answer : logged ; acted on only when the pilot's words gave nothing ($fromCopilot)
function Use-Reply([string]$reply, [bool]$fromCopilot) {
    $orders = @(if ($fromCopilot) { Get-ReplyOrders $reply })
    foreach ($o in $orders) { Send-Command $o }
    if ($orders.Count -gt 0) { Write-Log "  co-pilot said '$($reply.Trim())' -> $(($orders | ForEach-Object { Show-Order $_ }) -join ' + ') (from the co-pilot's words)" }
    else { Write-Log "  co-pilot said '$($reply.Trim())'" }
}

function Is-CopilotPhrase($entry) {
    return ([string]$entry.channel -like "INTERCOM*") -and ([string]$entry.station_name -match "co-?pilot")
}

# each pilot's own SayIntentions developer key (pilot portal, Developer Key page), next to this script
if ($DevKeyFile -eq "") { $DevKeyFile = Join-Path $PSScriptRoot "si_dev_key.txt" }
if (-not $DevKeyFile -or -not (Test-Path $DevKeyFile)) { Write-Host "No developer key file : put si_dev_key.txt next to si_bridge.ps1"; Write-Status "no developer key" ""; exit }
$script:devKey = (Get-Content $DevKeyFile -Raw).Trim()

if ($DryRun) {
    $key = Get-ApiKey
    $r = Invoke-Sapi "getCommsHistory" @{ api_key = $key }
    foreach ($e in ($r.comm_history | Sort-Object id)) {
        if (-not (Is-CopilotPhrase $e) -or [string]$e.incoming_message -eq "") { continue }
        $orders = @(Get-Orders ([string]$e.incoming_message))
        "{0} '{1}' -> {2}" -f $e.id, $e.incoming_message, $(if ($orders.Count) { $orders -join " + " } else { "-" })
    }
    exit
}

# a single bridge at a time : the script that starts us writes the quit flag first, an older bridge leaves
$mutex = New-Object System.Threading.Mutex($false, "SpeedyCopilotSIBridge")
try { $owned = $mutex.WaitOne(8000) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) { exit }
try { if (Test-Path $quitFlag) { Remove-Item $quitFlag -Force } } catch { }
if ((Test-Path $logFile) -and (Get-Item $logFile).Length -gt 1MB) { Remove-Item $logFile -Force }

$udp = New-Object System.Net.Sockets.UdpClient
function Send-Command($command) {
    $bytes = [Text.Encoding]::ASCII.GetBytes("SI|" + $command)   # tagged : the Windows voice mute does not apply
    [void]$udp.Send($bytes, $bytes.Length, "127.0.0.1", $Port)
}

# the PM read backs and refusals, said by the SayIntentions co-pilot
function Flush-SayQueue($key) {
    if (-not (Test-Path $sayQueue)) { return }
    $lines = @()
    try { $lines = Get-Content $sayQueue; Remove-Item $sayQueue -Force } catch { return }
    foreach ($line in $lines) {
        $message = $line.Trim()
        if ($message -eq "") { continue }
        if ($message.Length -gt 250) { $message = $message.Substring(0, 250) }
        try { [void](Invoke-Sapi "sayAs" @{ api_key = $key; channel = "INTERCOM1_IN"; message = $message; rephrase = 0 }); Write-Log "co-pilot says : $message" }
        catch { Write-Log "sayAs failed : $($_.Exception.Message)" }
    }
}

Write-Log "SayIntentions bridge started (UDP $Port)"
$seen = @{}
$firstSeen = @{}
$replyWait = @{}
$watermark = $null
$key = $null
$keyTime = 0
$last = ""
$state = "waiting for SayIntentions"
Write-Status $state $last

while ($true) {
    if (Test-Path $quitFlag) { try { Remove-Item $quitFlag -Force } catch { }; break }
    if (-not (Get-Process -Name "X-Plane" -ErrorAction SilentlyContinue)) { break }

    if ($key -eq $null -or (Now-Unix) - $keyTime -gt 60) { $key = Get-ApiKey; $keyTime = Now-Unix }
    if ($key -eq $null) { $state = "waiting for SayIntentions"; Write-Status $state $last; Start-Sleep -Seconds 3; continue }

    try {
        if ($watermark -eq $null) {
            # start : what was said before is history, not answers
            $r = Invoke-Sapi "getCommsHistory" @{ api_key = $key }
            $watermark = 0
            foreach ($e in $r.comm_history) { if ([long]$e.id -gt $watermark) { $watermark = [long]$e.id } }
            $state = "connected"
            Write-Log "connected, history up to id $watermark ignored"
        } else {
            $r = Invoke-Sapi "getCommsHistory" @{ api_key = $key; since_id = $watermark }
            $pending = @()
            foreach ($e in ($r.comm_history | Sort-Object { [long]$_.id })) {
                $id = [long]$e.id
                # the co-pilot's answer to a phrase already handled : logged when it arrives (at most 30 s), for diagnosis
                if ($replyWait.ContainsKey($id)) {
                    $reply = [string]$e.outgoing_message
                    if ($reply.Trim() -ne "") { Use-Reply $reply $replyWait[$id].fromCopilot; $replyWait.Remove($id) }
                    elseif ((Now-Unix) - $replyWait[$id].since -gt 30) { $replyWait.Remove($id) }
                    else { $pending += $id }
                    continue
                }
                if ($seen.ContainsKey($id)) { continue }
                if (-not (Is-CopilotPhrase $e)) {
                    $seen[$id] = $true
                    # ATC instructions : the PM sets them only when the co-pilot handles the radio (siai/copilot)
                    $atc = [string]$e.outgoing_message
                    if ([string]$e.channel -like "COM*" -and $atc.Trim() -ne "" -and [string]$e.station_name -notmatch "atis") {
                        $values = @(Get-Values $atc)
                        foreach ($v in $values) { Send-Command ("ATC|" + $v) }
                        # every ATC instruction is logged : "Climb FL360" once gave no value and left no trace
                        Write-Log "ATC '$($atc.Trim())' -> $(if ($values.Count -gt 0) { $values -join ' + ' } else { '-' })"
                    }
                    continue
                }
                $phrase = [string]$e.incoming_message
                if ($phrase.Trim() -eq "") {
                    # the pilot's words may come a moment later in the same entry
                    if (-not $firstSeen.ContainsKey($id)) { $firstSeen[$id] = Now-Unix }
                    if ((Now-Unix) - $firstSeen[$id] -gt 20) { $seen[$id] = $true } else { $pending += $id }
                    continue
                }
                $seen[$id] = $true
                $orders = @(Get-Orders $phrase)
                foreach ($o in $orders) { Send-Command $o }
                $values = @(Get-Values $phrase -Pilot)
                foreach ($v in $values) { Send-Command ("PILOT|" + $v) }
                $found = @($orders | ForEach-Object { Show-Order $_ }) + $values
                if ($found.Count -gt 0) {
                    $last = "$($phrase.Trim()) -> " + ($found -join " + ")
                    Write-Log "heard '$($phrase.Trim())' -> $($found -join ' + ')"
                } else {
                    Write-Log "heard '$($phrase.Trim())'"
                }
                # nothing in the pilot's words : the co-pilot's answer may tell what the pilot asked ("Puckflow High")
                $fromCopilot = ($found.Count -eq 0) -and (Test-ReplyWorth $phrase)
                $reply = [string]$e.outgoing_message
                if ($reply.Trim() -ne "") { Use-Reply $reply $fromCopilot }
                else { $replyWait[$id] = @{ since = Now-Unix; fromCopilot = $fromCopilot }; $pending += $id }
            }
            # the watermark stays below the entries still waiting for the pilot's words or the co-pilot's answer
            $maxId = $watermark
            foreach ($e in $r.comm_history) { if ([long]$e.id -gt $maxId) { $maxId = [long]$e.id } }
            if ($pending.Count -gt 0) { $watermark = ($pending | Measure-Object -Minimum).Minimum - 1 } else { $watermark = $maxId }
            $state = "connected"
        }
        Flush-SayQueue $key
    } catch {
        $state = "offline"
        Write-Log "SayIntentions error : $($_.Exception.Message)"
        Start-Sleep -Seconds 3
    }
    Write-Status $state $last
    Start-Sleep -Milliseconds ([int]($Interval * 1000))
}

Write-Log "SayIntentions bridge stopped"
Write-Status "stopped" ""
$udp.Close()
