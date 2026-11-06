# BUG-541 GiveWater carriers fill at a dry well for 26-28 days, the patient dies, the decision comes late
Status: fixed (offline, live-untested) as detection, an early decision, a command and an earlier zone rung; open: nothing makes the game's carriers choose the pond zone, and `act.well_remove` is live-untested
Severity: critical (3 patients dead: Run 16b i2 Brotherarrow y386 (26371) and y390, Run 16d i4 Trumpetrealms y404 (26761; y396 26593))
Found: 2026-11-06, `runs/run-16b/FR-BUGS.md` (BUG-507 observation: a child at 81,118,134 beside the dry well 82,119,134, Kern+, wet 0, 26 days; the captain in FillPond at the same well) and `runs/run-16d/FR-BUGS.md` ("Hospital-Patient verdurstet trotz drink 442 d: GiveWater 28+ d ohne Wirkung, Brunnen trocken": wells 17727/17824/18136 wet 0, the only source the pond zone 17697 18 tiles away; DECISION '2 GiveWater jobs running 28+ days without effect: a dry well' #9684 at thirst 32,420; #9701 HOSPITAL_REMOVED at 59,730; the soldier then drank at once (thirst 192))
Module: `lua/dfllm/water.lua` (`M.stalls`, `M.trap_well`, `stall_hospital`, verb `well.retire`), `lua/dfllm/act.lua` (`well_remove`), `dfpilot/wake.py`, `dfpilot/schema.py`, `dfpilot/fairplay.py`, `lua/dfllm/util/contract.lua`

## Actual
The hospital counted as served (a pond zone within `near` = 30 tiles), so `remove_dry` never acted. The GiveWater workers went to the nearest WELL, which was dry, and stood there. BUG-507's tracker needed `stall_days` (3) and a worker over `stall_need` (or a patient over `thirst_alarm` 30,000); the hospital rung needed the third round (day 5) AND a patient over `stall_dying` (45,000); the only decision (`job_stalled`) did not name the well. The patients reached 60,000-75,000.

## Root cause
- `water.lua` `M.stalls` (the case rule) never looked WHERE the worker stood: a worker at a dry well was a case only by the generic thresholds, late, and the DECISION carried no well and no command that removes it.
- DF's own choice of the water source is not readable or steerable from here; the levers that exist for the player are the building screen's remove (the well), the Orderlies detail (the carrier's labor: the game drops the job and posts it anew: BUG-383/507) and the zone screen's remove (BUG-034's recipe: without the hospital zone the patient fetches his own drink; the game has no "give drink from a barrel" job for patients: BUG-470).

## Fix
- `M.trap_well(c, r, e)`: a built well of the last run with `wet` false (an emergency well counts wet) within `trap_near` (2) tiles of a GiveWater worker.
- `M.stalls`: such a worker is a case after `trap_days` (1) once a patient is over `thirst_watch` (25,000), whatever his own thirst; the ladder runs as before (off Orderlies, pond zone beside him). From the second round (not the third) the hospital zone of a patient over `trap_dying` (35,000, not 45,000) goes (`stall_hospital(need)`), and BUG-539/540 draw it again.
- DECISION_NEEDED `dry_well` (urgent in wake.py) instead of `job_stalled` for those workers: the well, the patient's thirst, the nearest accepted water and the distance, `cmds` = `well.retire id=<well>`, `water.unstick unit=<id>`; again after 3 days for another set.
- Verb `well.retire {id, approve?}` (any mode) and act `well_remove` (`dfhack.buildings.deconstruct` of the well by id, as `pond_remove` does for a zone): only a built well that the last run read as dry; a wet well is refused; a well in a manifest cistern room (meant to fill) only with `approve:true`.
- Conf `trap`, `trap_days`, `trap_near`, `trap_dying`, `hrm_expire` (fairplay `WATER_LIM`).
- A LOOP well (BUG-263: water below, fed only by its own pond; `s.wet` false, `s.loop` set, `s.water` true) is no dry well: `M.trap_well` (water.lua) requires `not s.loop and not s.water`, `well.retire` refuses when `loop` or `water` is set (found by the verifier).
- Not done on purpose: no automatic well removal (a cistern's or a planned well may be dry for a while); no barrel fallback (no such job in DF, BUG-470).

## Tests
`tests/lua/test_bug540_542_hospital.lua` (decision at a dry well after 2 days, none at a wet well or without a thirsty patient; the zone goes from round 2 at 40,000 and stays at 30,000; `well.retire`: dry well retired, unknown id and wet well refused, cistern room only with approve; a loop well gives no decision and is refused by `well.retire`, also with approve), `tests/lua/test_kern_act.lua` (`well_remove`), `tests/test_bug540_542_hospital.py` (registry, contract, config keys, wake line, hook).

## Live check
A patient over 25,000 and GiveWater workers at a dry well: kern.log "N GiveWater carrier(s) stand at the DRY well ..." within a day, the decision `dry_well` with the command; `dfllm cmd well.retire id=<well>` removes the building, the next GiveWater trip should go to the pond zone / a wet well. Unknown until then: whether the game then really picks the other source.
