# BUG-034 Patients die of thirst in a dry hospital: HOSPITAL_DRY stood for seasons, the kernel never acted, the plans drafted `hospital` again
Status: fixed (offline, live-untested): the kernel removes a dry hospital's zones once a patient is thirsty (HOSPITAL_REMOVED), `plan check` refuses and `plan propose` holds back a hospital without accepted water near it (a cistern first), the state's `water` key
Severity: critical (loses citizens: 5 bedridden patients died of thirst, DEATHS_PREVENTABLE)
Found: 2026-10-17, Run 11 fort Kilrudrabed (site98), y439 spring d28, dfpilot main fcada16, from the game session's events
and its hand repair
Module: `lua/dfllm/water.lua` (finish: the hospital gate only reported), `dfpilot/plan.py` (propose/check: no water check
for `hospital`), `lua/dfllm/care.lua` (`stock.hosp_water`, read as the brief's `water ok|NO`)

## Actual
- DEATHS_PREVENTABLE: 5 bedridden patients died of dehydration (thirst 75,000); 8 more were above 40,000.
- The hospital had no water: brief `water NO`; 4 hospital locations (6, 8, 10, 17) with 5 zones. HOSPITAL_DRY had been
  reported for a long time; the line's recipe ended "until then delete the hospital zone", and nothing in the kernel
  could do that (no act for it; `zone_remove` takes only `dfllm-*` zone names and belongs to the runner).
- The year plan kept drafting `hospital` (the live plan has it for y439 s2): P3's deliverable `proj hospital` is drafted
  by every `plan propose` that does not find it applied, and `plan check` never looked at water. The 4 locations fit the
  loop draft -> apply (the zone stage makes a new location) -> HOSPITAL_DRY -> cancel -> draft again (an inference from
  the counts; the cancels themselves were not read).
- The game session removed the 5 hospital zones by hand (zones screen, a UI action): GiveWater jobs brought water to the
  patients again, 4 of them active at once.

## Expected
A hospital without accepted water is worse than none (RULES §7 said so). Once a patient there gets thirsty the kernel
removes the dry hospital's zones itself and says so (class A), never while the hospital has a working source; a new
hospital is planned only where accepted water reaches it, otherwise water (a cistern) comes first.

## The DF rule this rests on (task 3: do care and water tell the truth?)
The claim "patients in a hospital without water get no GiveWater; without the hospital zone they do" is not from DF's
code or docs. It rests on these live records, all in this repo:
1. **Run 9 (FR-33a, `docs/feature-requests/README.md`):** two bedridden citizens (23433, 21542) died of thirst at the
   hospital; every `GiveWater` job was cancelled with `No water source` while the only Water Source zone lay on 1/7
   seepage. `tools/run_release.lua` (Run 9 hospital rescue) records the same gamelog line plus `Diagnose patient: Patient
   not resting`; a v1 test replays 100 real `Give water: No water source` gamelog lines (CHANGELOG).
2. **Run 9 (FR-34):** six patients died of thirst in a ward with 190 days of drink in stock; deleting the hospital zone
   made the survivor stand up, drink and eat at once.
3. **L5 (`docs/v2/STATUS.md` §0, Atír "Wallgulf", unit 19661):** bedridden without a wound, thirst 40,000 -> 75,000;
   GiveWater jobs were posted and he got no water (the hospital read `water NO`, the cistern was dry).
4. **L2 (STATUS §0d, death 5):** "probably bedridden: the fort has no well water (sump 2/7, `hosp_water` 0), so patients
   get no water"; bucket carriers walked ~90 tiles to the brook meanwhile (the brook was usable for FillPond).
5. **Run 11 (this bug):** with the 5 hospital zones gone, 4 GiveWater jobs became active.

What holds: in a hospital without an accepted source, patients got no water (1, 3, 5), and removing the hospital zone
brought water back, either through GiveWater (5) or because the patient got up (2). What is NOT established:
- **The distance.** water.lua counts a hospital as served when an accepted source lies within `near` (30) tiles of a
  hospital zone (Chebyshev, z included). 30 is our number (FR-31's wording), not DF's. Run 11 suggests DF's GiveWater
  found a source once the zones were gone; the session did not record where that source was.
- **The well depth.** water.lua counts a well over any water (1/7 and up); the Water Source zone needs >= 4/7 (from 1.).
  Record 4 (a 2/7 sump, patients without water) is a hint that a shallow well may not do; BUG-031 left it open and the
  HOSPITAL_DRY line prints the depth under the well.
- **The mechanism.** Whether DF limits a hospital patient's GiveWater to sources near the hospital, or the hospital
  location changes which jobs are posted at all, is not known. The kernel now logs the GiveWater jobs at the removal
  and a day later (below), so the next live removal measures it.

What the code said, checked against that:
- `water.lua` header ("a Water Source zone on 1/7 seepage does not count: GiveWater was cancelled") - matches record 1.
- patient_thirst's recipe "delete the hospital zone (patients fetch their own drink)" - matched record 2 only; now
  "(GiveWater resumes or patients fetch their own drink)" (records 2 and 5).
- HOSPITAL_DRY's tail "until then delete the hospital zone" asked the orchestrator for something it has no verb for; now
  "until then the kernel removes it at thirst 25000" while the removal is on (else the old text).
- care's `stock.hosp_water` (the brief's `water ok|NO`) is narrower than water's judgement: 1 only for a wet well within
  one tile of a hospital zone on its level (and without a tile reader it trusts any built well). It is not wrong for the
  live case, but it disagrees with water.lua whenever the source is a Water Source zone or a well farther away (STATUS
  L4 item 7). The brief and status now show water's view (`hospital ok|DRY|none src N patients N (thirst N)`) when the
  state has the `water` key; `stock.hosp_water` stays for older readers.

## Fix (2026-10-17)
- **Kernel (`water.lua` remove_dry, new act `hospital_remove`, owner `water`):** while a patient's thirst is over
  `water.patient_thirst` (config/baseline.json, 25,000), every zone of a hospital location none of whose zones has an
  accepted source within `near` is removed (zones screen > remove: `dfhack.buildings.deconstruct` of that one zone; the
  act refuses any zone that is not linked to a HOSPITAL location and the zone open on the zone sheet), at most
  `remove_per_run` (8) a run. A location with one served zone keeps all of its zones ("never while the hospital has a
  working source"). The location stays (an empty entry on the locations screen).
  - HOSPITAL_REMOVED (A): `removed 5 dry hospital zone(s) 61,62,63,64,65 (location 6,8,10,17): 8 patient(s) over thirst
    25000, unit 10 at 48000; nearest accepted water 60,12,5 (46 tiles); water before a new hospital`; d: zones, locs,
    units, n, thirst, patients, give (GiveWater jobs then), failed, near, src, d. No patient_thirst or HOSPITAL_DRY in
    that run; afterwards the gate is quiet (no hospital zone left) unless a hospital project is pending and there is no
    accepted water at all (the old `planned` case).
  - kern.log (warn) `water: removed hospital zone(s) ... of location(s) ... (no accepted water within 30 tiles): 8
    patient(s) over thirst 25000 (unit 10 at 48000), 0 GiveWater job(s) now; ...`, and a day later (info) `water: a day
    after the hospital removal (tick T): N GiveWater job(s), N patient(s), max thirst N (was N)`; `inspect
    water_sources` carries `removed` {t, zones, locs, n, tmax, give, after, tmax_after}.
  - A refused removal is an ACT_FAIL (B) and is tried again in the next run (the patient_thirst line still comes).
  - `water.hosp_remove` false keeps the old report-only behaviour; the knobs are validated by `python -m dfpilot.lint
    --config` (`fairplay.WATER_LIM`, mirrored from water.lua's DEFAULTS by a test); water.conf ignores a value of
    another type than its default.
- **State (`water`, owner water; contract.lua STATE_SPEC + schema.STATE):** `{patients, thirst_max, hosp_ok, refuge_ok,
  buckets_free, hosp, src}`; `src` = up to 8 accepted sources [x,y,z], nearest the first hospital zone (else the
  citizens' median) first. water.lua had this state prepared but unpublished.
- **Plan (`plan.py` hospital_gate, hospital_water, hospital_facts):** `plan check` refuses a plan whose new builds add a
  `hospital` while no accepted source lies within `near` (config water.near, 30) tiles of the hospital's site (the
  anchor `bp.place tpl=hospital site=S1` would take, `cmd.free_sites`), or while `water.src` is empty:
  `hospital (seasons[2]): no accepted water in the fort (...): its patients would die of thirst (BUG-034); remove it
  and add {"tpl":"cistern","site":"S1"} first (...)` (a cistern under way or planned: it must hold water first). No
  sites snapshot: a warning that the distance is not checked. An older kernel (no `water` key): not checked, as the
  supply goals. `plan propose` holds the hospital back under the same rule and drafts `cistern@S1` in its place once
  (not while a cistern project is under way or a cistern room stands), with a note.
- RULES §7 (`HOSPITAL_DRY / HOSPITAL_REMOVED`), CONTRACTS §5/§7/§9.3/§9.17/§12 and the appendix, DESIGN §5 hospital
  water, follow's wake hint, the brief/status hospital line.
- Tests (fail on fcada16): `tests/lua/test_water.lua` (the Run 11 replay: 4 locations, 5 zones, 8 patients over 40,000
  -> 5 removals, the event, no patient_thirst/HOSPITAL_DRY, the next days quiet, the GiveWater count a day later; a
  served location keeps its far zone; below the mark, config mark, hosp_remove false, remove_per_run, a refused removal;
  state `water.src`), `tests/lua/test_kern_act.lua` (hospital_remove: owner, not a hospital zone, zone sheet open, refused
  deconstruct), `tests/test_hospital_water.py` (state/event schema, config mirror and validation, check refuses without
  water / far water / with a cistern under way, the site distance, propose holds the hospital and drafts the cistern,
  fort facts, status line).

## Open
- The 30-tile rule and the well depth (above) stay assumptions until a live removal's GiveWater counts are read.
- The removed hospital's room (beds, traction bench, well spot) stays without a zone. `plan propose` does not draft an
  applied hospital again (any year), so once real water stands near it the player or the orchestrator re-zones the room
  by hand or places a new one (`bp sites hospital`, `bp.place`). Re-zoning the old room automatically needs a template
  stage the runner can re-apply (not done).
- A hospital project already queued in the runner still applies its zone stage; if that hospital is dry and a patient is
  thirsty, the next water run removes the new zone again (no loop with the runner: zone stages are applied once).
- `dfllm cmd bp.place tpl=hospital` (by hand or by an agent) is not gated by the water rule; only the plan is.
- The 4 empty hospital locations of Run 11 stay on the locations screen.

Related: FR-31, FR-33a, FR-34, FR-47, BUG-031 (the cistern in HOSPITAL_DRY), BUG-008 (wake cadence)
