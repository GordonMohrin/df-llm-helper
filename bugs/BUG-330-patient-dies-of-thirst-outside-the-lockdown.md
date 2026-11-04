# BUG-330 a patient outside the alert burrow dies of thirst while the carers wait inside the lockdown
Status: fixed (offline, live-untested)
Severity: critical
Found: 2026-11-04, Run 15b (Earthboat, i3, `runs/run-15b-earthboat/FR-BUGS.md` Runde 4), kernel main 9b6f614
Module: `lua/dfllm/water.lua` (give_diag, new care_step / care_rooms, patients_out), `lua/dfllm/siege.lua` (alert_list),
`lua/dfllm/act.lua` (burrow_tiles `exact`), contract act owners

## Actual
Earthboat y385 summer (SIEGE from tick 155285731, the deep defense `weak: worn 56% < 60%`, civ alert in Tiefe+):
- events #2949 (BREACH, earlier) and #6847 PATIENTS_OUT `2 of 2 patients lie outside the alert burrow Tiefe+ (26578 at 54,68,138,
  26629 at 74,83,138)`; #6867/#6947 DECISION_NEEDED patient_thirst key `alert` `the civ alert holds the caregivers in Tiefe+, the
  patient lies outside; jobs 1 open/0 running, 68 idle, 77 reach`; #6919 PATIENT_DYING at 60503; #6966 DEATH 26629 `dehydrated
  (incident THIRST; thirst 75000; hunger 93611; patient)` at 74,83,138, tick 155359343.
- kern.log the same days: `water: 2 patients ..., hospital none, refuge dry (4 wells, 1 in Tiefe+, 0 of them wet), 0 wet sources`;
  the scan found 0 well spots and 0 banks in every run of the siege (`0 with a bank or a dig, 0 with a well spot`).
- earlier (#6813, tick 155321101, before BUG-324 was live): key `open` `1 GiveWater job open, none taken by 53 idle`.

Why GiveWater was not taken: two causes at once, and the verdict named only one.
1. No accepted water at all: the well 17700 (57,80,135) dry, no Water Source zone; in a SIEGE BUG-324's zone_found paints only
   roofed water (the river is open), so nothing could change that during the fight. A GiveWater job without a source is never
   carried out, whoever is idle (BUG-324's `nowater` verdict).
2. The civ alert: a citizen the alert confines takes no job on a tile outside its burrows. The patient lay in the core (Kern+)
   but the alert held everybody in Tiefe+ (the deep defense, BUG-331). Nothing in the kernel ever let a carrier out:
   water.lua:1713 (9b6f614) `give_diag` stopped at `alert`, `patients_out` (water.lua:1536) only reported, siege's alert list
   (siege.lua:957 `alert_list`) held the mode burrow and the lever rooms only.

Labor Feed Patients was not the cause: 77 carers held FEED_WATER_CIVILIANS (`carers 77 of 4 wanted`), buckets 15 free of 19.

## Fix
- water `M.care_step` (every run, before the texts): while the civ alert sounds, every patient over `care_thirst` (30000) lying
  outside every alert burrow, with a fresh hostile census and no visible hostile within `care_near` (20) tiles of him, gets his
  tile, the nearest accepted water outside the alert burrows (a wet well's tile, a Water Source zone's rect) and the nearest free
  bucket outside them (each with no hostile near) painted into the burrow `Pflege+` (`act.burrow_tiles(name, tiles, true,
  true)`: created if missing, erased and painted exactly; `exact` is refused for every other name, BUG-096). `water.care_rooms`
  names it while open; `siege.alert_list` appends it to the civ alert's list, so the confined caregivers may take the GiveWater
  job out there. A hostile near, the patient below the mark, inside, dead, or the alert off closes it (it leaves the list);
  kern.log `water: care burrow Pflege+ opened to patient(s) ... / closed: <why>`.
- Without accepted water nothing opens: the `alert` verdict now says `..., and no accepted water (no well over water, no Water
  Source zone): nothing to carry`; with the burrow open `; Pflege+ opened to him (his tile and the water)`, else `; Pflege+ not
  opened: <why>`. PATIENTS_OUT (the early warning, at the first patient outside in a fight) adds what the care burrow does
  (`d.care`: open, `opens to one over thirst 30000 with no hostile near`, or why not).
- Contract: act `burrow_tiles` owners seal, runner, water (contract.lua, schema.py, CONTRACTS row); config/baseline.json water keys
  `care` (bool), `care_thirst`, `care_near` (fairplay WATER_LIM).

## Review fix (merge14)
The care burrow could open where it draws civilians into danger, and stayed open on old data. Now (water.lua `care_step`,
`care_check`, `foe_dist`):
- never in BREACH (closed at once; the BREACH alert list is Tiefe+ alone again);
- outside PEACE/ALERT the patient, water and bucket tiles must lie on Kern+ (the rule of `unforbid_ok`); a well on Kern+ is
  preferred over a Water Source zone, and a zone counts only when every painted tile of it is on Kern+;
- the painted tiles are kept in `st.care` and re-checked on every water step and every `care_rooms` ask (siege asks it on every
  alert set): a hostile within `care_near` of one, a census older than `CARE_FRESH` (now 200 ticks, siege's fresh rule, was 1200),
  another mode than the one it opened in, or BREACH closes it (kern.log `care burrow Pflege+ closed: <tile>: a hostile N tiles
  from it`, `the mode changed (PEACE -> ALERT)`, `BREACH: ...`);
- `foe_dist` gives no distance (unknown, not safe) when the census sees more hostiles than it lists (sense keeps the 40 nearest
  O1), so a goblin group cut from the list can no longer pass as far.
Tests: 5 new in `tests/lua/test_bug330_care_burrow.lua` (BREACH, SIEGE outside Kern+, well before zone, re-check between runs,
truncated list); all fail on merge14. Still not checked: the walk path to the tiles (Kern+ is the bound instead).

## Tests
`tests/lua/test_bug330_care_burrow.lua` (4), `tests/lua/test_bug331_siege_long.lua` (the alert list test),
`tests/test_bug330_331_lockdown.py` (contract, guard, config keys). All fail on 9b6f614.

## Live check
Earthboat (still SIEGE, 26578 a patient at 52,65,138 outside Tiefe+): once his thirst passes 30000 with no goblin within 20 tiles,
kern.log `care burrow Pflege+ opened ...`, the alerts screen lists Pflege+ beside Tiefe+, the burrows screen shows exactly his
tile (+ water + bucket). With no accepted water (Earthboat now) nothing opens and patient_thirst says `and no accepted water`.

## Uncertain / open
- Whether DF lets a burrow-restricted caregiver walk through tiles outside its burrows to a job tile inside one (DF's burrow rule
  restricts job sites and items, not paths, as far as known): not decided offline.
- Whether a GiveWater carrier fills its bucket at a well/zone tile listed in an alert burrow it does not stand in.
- Earthboat needs water first (FR-47: a well over water / a Water Source zone in PEACE); the care burrow brings carriers, not water.
- The rescue (DF's recover-wounded job, a lying patient carried to a hospital) needs a hospital zone: not part of this fix.
