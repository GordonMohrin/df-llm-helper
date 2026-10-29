# BUG-131 A stale hospital zone outside the core keeps readiness R0 `hospital_out` red for good, and nothing may remove it
Status: fixed in the BUG-131 commit (offline, live-untested)
Severity: high (goal G3, readiness above R0, can never turn green; max-pop and the starred phases stay held)
Found: 2026-10-28, goal audit of Run 14 (site90, y715: `1 of 3 zones; zone 24422 at 88,28`; SIEGE_UNREADY named `hospital_out` 183 times)
Module: `lua/dfllm/water.lua` (`M.hosp_sort`, `M.zone_patients`, `M.loc_supply`, verb `hospital.retire`, state `water.hout`),
`lua/dfllm/util/contract.lua`, `dfpilot/schema.py`, `dfpilot/brief.py`, `dfpilot/guide.py`, `dfpilot/wake.py`

## Actual
`hospital_out` (BUG-036) counted every hospital zone with a tile outside Kern+/Tiefe+. An old zone (24422 at 88,28,129) stayed outside
while a new hospital inside the core existed or was being built. The playbook does not let the session delete zones (RULES 1.2: one door into
the game, the closed verb set), and no verb removed a hospital zone except BUG-034's dry-hospital removal, which runs only for a DRY hospital
with a thirsty patient. So R0 stayed red for the whole run.

## Cause (from the code at dec5132)
`water.lua` `hospital_out(r, kern, refuge)` put every zone with `out > 0` sampled tiles into `ho.zones`. `hosp_out = ho.n` went into the
state, and readiness R0 `hospital_out` read it. The count asked nothing about the zone: whether a patient lies in it, whether a bed stands in it,
whether its location holds supplies, or whether a finished hospital inside the core had replaced it.

## Fix
1. **Ignore stale zones** (`M.hosp_sort`, after `hospital_out` in the water run). A zone outside the core does not count in `hosp_out` when it is
   - `idle`: no patient lies in its rect, no bed stands in it (`zone_furniture`, the BUG-106 reader) and its location holds no supply (the
     `count_*` fields summed). All three must be known: unknown furniture (no `findAtTile`, more than `M.SORT_ZONES` 12 zones) or a location
     without supply fields counts as present, so the zone still blocks;
   - `superseded`: a finished hospital inside the core exists (a hospital zone with every sampled tile on Kern+/Tiefe+ and at least one bed)
     and no patient lies in the zone outside it. A patient in such a zone keeps it blocking: lying patients cannot walk to the refuge
     (BUG-036), whatever stands inside.
   `water.hospital_out()` returns `ign` (the ignored zones with `why`), `fin` (the finished hospital inside) and `raw` (every zone outside). kern.log
   writes one line when the count of ignored zones changes.
2. **Verb `hospital.retire {zone, approve?}`** (water, PEACE only by contract). It is the player's zones screen remove (`act.hospital_remove`,
   BUG-034's actuator, `dfhack.buildings.deconstruct`) for one hospital zone outside Kern+/Tiefe+ that the last water run saw.
   Refused when:
   - the zone is not a hospital zone of that run;
   - it lies inside the core;
   - a patient lies in it (citizens read at the time of the verb; `approve` does not change this);
   - no finished hospital stands inside, unless `approve:true` comes on the player's word.
   The reply names the zone, its centre and its location. The location stays, because no script can delete a location: with no zone left,
   every count ignores it (BUG-056) and care moves its doctors' posts to the live hospital (BUG-077); otherwise the reply says how many zones
   the location keeps. The zone leaves `hosp_out` at once.
3. **Name it.** State `water.hout {z, at, ok, pat?}` holds the first blocking zone, its centre, `ok` 1 when a finished hospital inside exists
   (no approve needed) and the patients lying in it. The R0 `next:` text of `status`/`brief` adds `zone Z at x,y,z blocks it: ... dfllm cmd
   hospital.retire zone=Z` (with `approve=true` only on Gordon's word while the hospital inside has no bed). `dfllm next` gives the retire
   command when `ok` is 1 and nobody lies in the zone. The SIEGE_UNREADY wake hint points to the status line.

## Not decided offline
- What "finished" means: a bed is required, not water or a table. The water gate (BUG-034) still judges the new hospital.
- The task's wording reads "superseded" without the patient condition. A patient lying outside is BUG-036's risk, so the zone still blocks while
  he lies there.
- Whether `findAtTile` sees beds on every tile of a live zone in DF 53.16 (the BUG-106 audit reads it the same way); a newly placed empty
  zone outside the core is idle and does not block until a bed stands in it.

## Tests
- `tests/lua/test_water.lua`: 3 new tests, all failing at dec5132: idle zone and its five blocking cases; superseded zone, the patient case, a new
  hospital without a bed, the state `hout`; the verb's refusals (ALERT, no approve, unknown zone, a patient, a zone inside) and successes
  (approve, superseded, the location's other zone).
- `tests/test_bug131_hospital_retire.py`: 5 tests (registry and args, status text, `next`, the commands through `parse_kv` and the hook).

## Live check
In PEACE with an old hospital zone outside Kern+/Tiefe+: `dfllm status`. Either `hospital_out` is gone (kern.log `do not block (BUG-131)`), or
the R0 line names `zone N at x,y,z` and the `hospital.retire` command. Send it (approve only with Gordon's yes), then check the reply, that
the zone is gone from DF's zones screen, and that `hospital_out` has left `ready.fail` after the next readiness run.

Related: BUG-034, BUG-036, BUG-056, BUG-077, BUG-106, BUG-116
