# BUG-343 patients die of thirst with "hospital ok" and GiveWater jobs running
Status: partly fixed (offline, live-untested): a `run` verdict that brings no water for 2 days is `noeffect` and says
whether the patient starves too (then the care fails, not the water); PATIENT_DYING `lie` reads the DFHack fields that hold
a patient down (unit.counters unconscious/stunned/webbed/suffocation, unit.counters2 paralysis/numbness), liquid on his
tile, his hunger and his syndromes; open: why the game's carriers do not deliver (the cancel reason), the syndrome itself
Severity: critical
Found: 2026-11-04, Run 15 (i2 Guildcleans y386-y390, Runde 2; code 14ff5a3), FR-BUGS "Patienten verdursten auch bei
'hospital ok' + Brunnen in Kern+", "OBS Verdurstete haben thoughts 'Syndrome' + wounds 0", "3 Tote 'suffocated'"
Module: `lua/dfllm/water.lua` (give_diag :1763 `run`; the first pass's M.lie read `u.counters.paralysis`, a field DFHack
has only in `unit.counters2`: scripts/full-heal.lua:127, internal/gm-unit/editor_counters.lua counters2)

## Actual
- i2 events.jsonl: 24 citizens `dehydrated (thirst 75000)` between tick 154629426 and 157984456, every one a patient, from
  y388 nearly all at 104-108,104-110,125 (the hospital of project c1a1a510be3991ea01, well 18183 at 105,105,125).
- kern.log every water run: `hospital ok, refuge dry (5 wells, ..., 0 of them wet), 3 wet sources, ... 0-3 GiveWater`;
  PATIENT_DYING #7452/#7616/#7916/#8327/#8675/#9345/#9692 `hospital ok, ... N giving water; N GiveWater jobs running` (key
  `run`, 15-42 caregivers idle, reach = all): the verdict said nothing was wrong while the thirst climbed 60,000 -> 75,000.
- CANCEL_LOOP #8040 `Give water cancelled 5 times today` (d only {job, n}: no reason recorded anywhere).

## Evidence (what kills them)
- **Thirst and hunger together:** every one of the 24 had hunger 52,824-98,595 at death (19 of them over 60,000; e.g.
  26756 98,595, 26584 85,774, 26636 75,495). No food reached them either: GiveFood is the same caregivers' work. So the delivery
  (the caregivers' job), not the water source, fails. The same in i4 (BUG-344: hunger 51,683-94,529).
- **Suffocation:** 12 `SUFFOCATE` deaths; 7 carry `by dwarf`, all patients, 6 of them in the hospital beds (#7402 #7638
  #7937 by 26740, #7944 by 26644, #7958 by 26656, #8545 #9371 by 26576: kills by other dwarves, strangled), 1 `by goblin
  27487` (#10051, the y390 siege), 4 without a killer (#5482 at 122,101,129; #6530-6532 at 84-87,81-82,125 at tick
  156046356, y387 d7, patients without a hospital). Whether those 4 lay in liquid or were webbed cannot be read offline;
  `lie` now says it for a dying patient.
- **'Syndrome' with wounds 0** (FR-BUGS y389, unit 26584): the syndrome's name was never read; `lie` names it.
- **Withdrawn (first pass):** "the hospital well beside its own pond is a loop while a far zone exists" (M.pond_fed). The
  starving shows it does not explain the deaths; drawing from a well is not shown to drain it; and the hospital template
  (dfpilot/bp/rooms.py:182-193) builds exactly that well + Pond zone, so the rule would remove every template hospital's pond
  once wet and then the hospital itself at thirst 25,000 (place/remove churn; i2 HOSPITAL_REMOVED of zone 18069 at y385).
  Reverted to 14ff5a3's loop rule.

## Cause
1. give_diag returned `run` for any running GiveWater job, also one that ran for days without the patient ever drinking.
2. The kernel never read why a patient lies or whether he is fed; the first pass's `lie` read `u.counters.paralysis`
   (always nil in DFHack: paralysis is `unit.counters2.paralysis`), inside a pcall, so it failed silently, and it did not
   read webbed or suffocation at all.

## Fix
- `M.give_effect`: `run` for the same top patient for `M.NOEFFECT_DAYS` (2) days while his thirst climbs at least at half the
  tick rate is `noeffect` with the nearest accepted water; the reason ends `hunger N too: no food reaches him either, the
  care fails, not the water` from `M.STARVE_HUNGER` (50,000; patients carry `hunger`), else `a dry well, or the carriers
  cancel?`. A drink, another top patient or another verdict starts anew. Report only.
- `M.lie(u)`: PATIENT_DYING `lie` (≤ 120) and its kern.log line: `wounds N`, `unconscious` `stunned` `webbed` `suffocation`
  (unit.counters), `paralysis` `numbness` (unit.counters2), `in water N/7` / `in magma N/7` (getTileFlags on his tile, as
  snapshot.tile reads it), `hunger N`, `syndrome <name>` (at most 2).

## Tests
tests/lua/test_water_m1.lua: noeffect (+ the hunger reason), lie (counters2.paralysis read, a `paralysis` in counters
ignored, suffocation, hunger, water on the tile). Fail on 14ff5a3 and on 40b118e (the first pass).

## Live check
i2 with a patient over 60,000: PATIENT_DYING `lie` (e.g. `wounds 0, ..., hunger 61000, syndrome <name>`) and, 2 days of
`run` later, `key noeffect` with `hunger N too: ...`. Gordon/the player reads `lie` to decide (syndrome: cure/quarantine; in
water: drain; webbed: wait).

## Open
- Why the GiveWater/GiveFood jobs are cancelled (CANCEL_LOOP carries no reason; DF's job cancel reason is not read).
- The syndrome is named, not treated; the strangling (suffocated by dwarf) is a fight/mood issue.
- pond_fed's zone distance from a zone centre (first pass) is gone with the revert.

Related: BUG-034, BUG-104, BUG-263, BUG-324, BUG-344
