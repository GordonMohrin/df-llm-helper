# BUG-343 patients die of thirst with "hospital ok" and GiveWater jobs running: the hospital's own well is a pond loop
Status: partly fixed (offline, live-untested): a well with its own pond beside it stays a loop while the only wet Water
Source zone lies farther away; a `run` verdict that brings no water for 2 days is `noeffect`; PATIENT_DYING says why the
patient lies (`lie`: wounds, unconscious, syndromes); open: what the game's carrier really does with the bucket, the
hospital template's bucket-filled sump, the strangling dwarves
Severity: critical
Found: 2026-11-04, Run 15 (i2 Guildcleans y386-y390, Runde 2; code 14ff5a3), FR-BUGS "Patienten verdursten auch bei
'hospital ok' + Brunnen in Kern+", "OBS Verdurstete haben thoughts 'Syndrome' + wounds 0"
Module: `lua/dfllm/water.lua` (was :514 pond_loops `if s.kind == 'zone' and s.wet then return 0 end`, :556/:567 M.loops
`zone_wet and {} or r.ponds`; :1763 give_diag `run`); the template `dfpilot/bp/rooms.py:182-193` (hospital: well at u 2,
pond zone at u 3 over the same sump)

## Actual
- i2 events.jsonl: 13 citizens `dehydrated (... thirst 75000; patient)` between tick 156168024 and 157437046 (26441, 26827,
  26797, 26659, 26621, 26756, 26761, 26584, 26793, 26689, 26636, 26487, earlier 26739), all lying at 104-108,104-110,125 =
  the hospital of project c1a1a510be3991ea01; hunger 54,000-98,000 too (no GiveFood either).
- kern.log every water run: `hospital ok, refuge dry (5 wells, ..., 0 of them wet), 3 wet sources, ... 1-11 GiveWater`;
  PATIENT_DYING #7452/#7616/#7916/#8327/#8675 `hospital ok, ... 1-4 giving water; N GiveWater jobs running` (key `run`): the
  verdict said nothing was wrong while the patient's thirst climbed from 60,000 to 75,000.
- CANCEL_LOOP #8040 `Give water cancelled 5 times today`; reflex at 156991564: `26274:job:FillPond@104,104,125
  26278:job:GiveWater@57,100,125` (a carrier filling the hospital's pond beside the patients, another 48 tiles away).

## Evidence
- bp/c1a1a510be3991ea01.json (tpl hospital, rot 3): dig `h` 105,104,125 and 105,105,125, build `l` (the well) at
  105,105,125, zone `p{pond=true}` at 105,104,125: the well and its pond 1 tile apart over one sump. The same in i4
  (bp/c1a1a42305c01d4601.json: well 76,50,142 = well 18324, pond 77,50,142), see BUG-344.
- The only wet Water Source zone in i2 was zone 18086 at 125,121,129, 66 tiles away outside (HOSPITAL_REMOVED y385: `nearest
  accepted water 125,121,129 (66 tiles)`); in i4 zone 18276 at 87,82,141 (~30 tiles).

## Cause
1. The loop rule (BUG-263, header "pond loop", live L6: the carriers take the nearest source) was switched off by any wet
   Water Source zone on the map (`a real supply exists`). The hospital's well beside its own pond therefore read wet
   whenever its sump held a trickle and counted as the hospital's water (`hospital ok`, state water.src), so neither
   HOSPITAL_DRY nor the dry-hospital removal (BUG-034) ever came; the carriers poured the well's own water back into it.
2. give_diag returned `run` for any running GiveWater job, also one that had run for days without the patient ever drinking.
3. Not water: 7 `suffocated ... by dwarf` deaths (#7402 #7638 #7937 by 26740, who went Berserk and died #8126; #7944 by
   26644, #7958 by 26656, #8545 by 26576) are kills by other dwarves (strangled in a fight), the care/mood side. The
   'Syndrome' thought of the dead could not be named offline (no curse lines, no syndrome reader); now `lie` names it.

## Fix
- `M.pond_fed(r, pd, d)`: a wet Water Source zone is the pond's supply only when it lies at most as far from the pond as the
  well beside it (d). pond_loops and M.loops ask it per pond: a far zone leaves the loop a loop (pond removed, the well a
  store: s.wet false, s.water true; HOSPITAL_DRY names `well N ... is fed only by its own pond P`).
- `M.give_effect`: `run` for the same top patient for `M.NOEFFECT_DAYS` (2) days while his thirst climbs at least at half the
  tick rate is `noeffect` with the nearest accepted water (`1 GiveWater job running 2+ days without effect (unit 5 thirst
  61000 -> 64600; nearest water: well 18183 at 105,105,125, 2 tiles): a dry or pond-fed well?`); a drink, another top patient
  or another verdict starts anew. A changed key is news for PATIENT_DYING. Report only.
- `M.lie(u)`: PATIENT_DYING `lie` (contract: optional str) and its kern.log line: `wounds N`, `unconscious`, `paralysis`,
  `syndrome <name>` (at most 2).

## Tests
tests/lua/test_bug262_266_water.lua (+1, 1 adjusted: the supplying zone now lies beside the pond), tests/lua/test_water.lua
(pond loop: +1 assertion, the zone beside the pond), tests/lua/test_water_m1.lua (+2). The new ones fail on 14ff5a3.

## Live check
i2/i4 after a reload: kern.log `water: pond zone N removed: the wet well 18183 beside it was its water source (a loop)`
(i4: well 18324); status no longer `src ... (well 18183 in Kern+)`; with a patient over 30,000 HOSPITAL_DRY or the removal
at 25,000 instead of `hospital ok`; PATIENT_DYING `key noeffect` and `lie` for a patient whose jobs run without effect.

## Open
- What the carrier does with the bucket (fill at the far zone, a dry well, carry it to the bed) is the game's; the kernel only
  sees the job and the thirst. Whether a well over 1/7 serves a bucket at all is not confirmed live.
- The hospital template (rooms.py:182) still builds a bucket-filled sump with its own pond: once wet it is a loop by
  definition; a hospital needs a well over real water (bp sites hospital ranks by water.src, which no longer holds it).
- The strangling (suffocated by dwarf) is a fight/mood issue, not handled here.
- Patients lying with wounds 0: why (syndrome, unconscious) is now named, not treated.

Related: BUG-034, BUG-104, BUG-263, BUG-266, BUG-324, BUG-344
