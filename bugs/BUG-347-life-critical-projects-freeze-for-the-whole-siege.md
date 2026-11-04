# BUG-347 life-critical projects freeze for the whole siege: the hospital stays undug while a patient dies of thirst
Status: partly fixed (offline, live-untested): life support inside the alert burrow runs in SIEGE; open: a life-support stage
with tiles outside the alert burrow (a hospital dug next to Kern+, added to it only by its own last burrow stage)
Severity: critical
Found: 2026-11-04, Run 15 (i2 Guildcleans y386-387, `runs/run-15-guildcleans/FR-BUGS.md` Runde 2 "Hospital/Stockroom/Galerie
'dig BLOCKED:frozen' die ganze Belagerung"), kernel main 14ff5a3
Module: `lua/dfllm/runner.lua` (allowed, was :2880; new Q.life_ok / Q.life_burrows, rows)

## Actual
i2 Guildcleans: SIEGE from tick 155897577 (BREACH, SIEGE again 155926277) to 156116788 (`SIEGE>RECOVERY quiet`, about 160
game days), 26-40 goblins in sight (SIEGE_STATUS `40 .. 26 visible`). The hospital c1a1a510be3991ea01 (bp.place y386, queued
kern.log tick 156003801), plan y386s1b0 gallery_o1 and y387s0b0 stockroom stood `dig 0% BLOCKED:frozen` the whole time. Patient
26739 (Kern+, 78,99,128) reached thirst 60260 with 5 GiveWater jobs 'running' and no accepted water inside (PATIENT_DYING #6360)
and died of thirst (#6453); 26661 was at thirst 33536. The hospital ran only after the siege (`resumed`, `done` at 156235601).

Root cause: runner.lua `allowed` (14ff5a3 :2880) gates by class: SIEGE runs only `defense` projects inside a Z3/Z4 box. The
hospital is `living` (dfpilot/bp/rooms.py:184), cistern/refuge_drink/farms/stockroom `infra`: every one froze for the whole siege
(rows: `frozen`), whatever it meant for the patients; ALERT/RECOVERY froze the hospital too (living).

## Fix
Life support runs in a SIEGE when its work stays where the citizens already are: `Q.life_ok` (runner.lua :2910) passes the
hospital, the cistern, the refuge's drink store, and farms / the stockroom while a food or drink emergency holds
(S.focus.emerg: seal_first food_d / drink_d, patients without water), when every tile of the project's current stage lies inside
a burrow the sounding civ alert holds the citizens in (plotinfo.alerts.list[idx].burrows; the care burrow Pflege+ is skipped: it
reaches patients outside), or inside Kern+ (manifest role kern) while no civ alert sounds. The hospital also runs so in
ALERT/RECOVERY. BREACH and DRILL freeze everything as before; gallery_o1 (defense outside Z3/Z4) stays frozen in SIEGE. A stage
with a tile outside says so in the row: `frozen: 9/11 tiles off Kern+` (status, plan). Measured once a game day per stage
(S.life, runtime).

## Tests
`tests/lua/test_bug347_life_siege.lua` (4: review pass 2: an alert burrow switch measures again inside LIFE_TTL, a BREACH
row says plain `frozen`; the hospital inside the alert burrow digs, a bedroom and a hospital outside stay
frozen with the count; farms only in a famine, the cistern always, BREACH freezes; no civ alert: Kern+, ALERT runs the hospital).
All fail on 14ff5a3.

## Live check
A siege with a hospital, cistern or farm project (famine) whose tiles lie in Kern+: the row leaves `frozen` and the project digs;
one outside: `frozen: N/M tiles off Kern+`.

Review pass 2: the measure (S.life) is taken again when the alert burrow (Kern+ <-> Tiefe+) or the mode changes, and a row in
BREACH/DRILL (where life_ok is not called) no longer shows the tile count of an earlier SIEGE measure (plain `frozen`).

## Open
Not closed for the reported incident: hospital blueprints (dfpilot/bp/rooms.py:92-98, `_finish`) add the room to Kern+ only in
their LAST stage (`burrow`), so a newly placed hospital's dig/build stages normally lie outside Kern+ and stay frozen in a SIEGE,
as the i2 hospital c1a1a510be3991ea01 did; and while the civ alert sounds on Tiefe+ (i2 for most of the siege) only Tiefe+
counts, so a Kern+ hospital stays frozen too. This fix would likely not have saved patient 26739. FR-BUGS y388-389 also shows
patients dying of thirst with `hospital ok`, which is a care/water problem this bug does not touch.
The i2 hospital's dig tiles (103-108,104-110,125) may lie outside Kern+ until its own last stage (`burrow`: `a{name=Kern+}`)
adds them; such a project stays frozen (the row says how many tiles). Painting the work tiles into the alert burrow first would
let it run, but changes seal's audited burrow (a way out could open): left to a separate decision.
