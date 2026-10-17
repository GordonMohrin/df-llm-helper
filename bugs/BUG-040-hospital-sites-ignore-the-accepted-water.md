# BUG-040 Hospital sites ignore the accepted water; nobody knows where Tiefe+ lies; cisterns without a fill source stand dry
Status: fixed in <commit> (offline, live-untested): `bp sites hospital` ranks and filters by the kernel's accepted water
(water.lua's measure and radius) and names the source, the nearest candidate and the refuge's water; `plan check`
measures the site the sites offer (both agree); status/brief/`refuge_dry`/`hospital_out`/`inspect water_sources` name
where Tiefe+ lies and its nearest accepted water; CISTERN_DRY (B) reports a done cistern whose well stays dry; `plan
check` warns about and `plan propose` drafts no bucket-fed cistern without a fill source
Severity: high (wrong decision: no hospital is planned, wounded lie in beds without a hospital; two cisterns built for
nothing)
Found: 2026-10-17, Run 11 fort Kilrudrabed (site98), y453 summer (and autumn d7, siege 10), kernel b49acfb / main 3d5fe0a,
from the game session's read-only report
Module: `dfpilot/bp/sites.py` (rank: no water term for rooms), `dfpilot/plan.py` (hospital_facts/hospital_water: S1 against
water.src), `dfpilot/cmd.py` (ranking cache), `lua/dfllm/water.lua` (cisterns, sources), `lua/dfllm/seal.lua`
(refuge_drink), `lua/dfllm/readiness.lua` (refuge_dry, hospital_out texts)

## Actual (live, read-only)
- No new hospital is planned: the session waits for water because `plan check` refuses a hospital without a source
  (BUG-034's rule). The hospital zones are gone (HOSPITAL 8 locations remain); wounded lie in beds without a hospital.
- `inspect water_sources`: 16 wells, one wet: well 19098 at 137,77,143. `inspect refuge` (y453 autumn d7): Tiefe+ 212
  tiles, 60 beds, drink 0, food 513, wells 1 (dry); its dead end bottom 126,56,129, mouth 128,77,136, z129-136;
  Kern+ 8393 tiles, 14 wells, drink 1186; `sep 0` for all three burrows (entrance 129,121,143 open).
- The cisterns y450s0b0 and y452s1b0 are PROJECT_DONE; their wells stayed dry (`water NO` since the run began).
- Tiefe+ is reported dry (refuge_dry) and nothing says where it lies.
- `bp sites hospital` offered S1 139,61,139 and S2 144,61,139; the explore y432s1b0 is parked at a cavern lake.

## Causes (proved from the code at 3d5fe0a)
1. **The hospital's sites knew nothing of water.** `sites._rooms` (sites.py:364-419) scores a hospital like any room
   (1000 - 5 per step to a stair - unknown/10); the water term (`WATER_NEAR`, `water_bonus`, sites.py:51, 533-539) exists
   only for the fortcore anchor and uses revealed water bodies of >= 8 tiles, not the kernel's accepted sources
   (water.lua `src`: a wet well, a Water Source zone on water >= 4/7). `plan check` measured only the first free site
   (`hospital_facts` -> `free_sites(...)[0]`, plan.py:179-197) from its anchor to `water.src` (plan.py:212-234). So the
   sites offered what the check could refuse, and a refusal never led to another site.
2. **The check measured from the anchor, water.lua from the zone** (water.lua:351-360 `served`: dist_box from the source
   to the hospital zone rect). A site near the edge of the radius could pass one and fail the other.
3. **A refused ranking read as "not checked".** `hospital_facts` swallowed a BpError (site None) and `hospital_water`
   then passed with a warning (plan.py:227-230).
4. **The ranking cache ignored the water** (cmd.py:203-214 `ranking`: snapshot, params, manifest digest only).
5. **Nobody said where Tiefe+ lies.** readiness's `refuge_dry` (readiness.lua:285-299) and `hospital_out` texts, status
   and brief name no place; seal's audit counted the refuge's tiles block by block (seal.lua:460-485 `burrow_size`) but
   kept no bbox; water knew the sources but not on which burrow they stand.
6. **Cisterns: how they fill, and why these did not.** `rooms.cistern` (rooms.py:531-574): with `path` "" (what `plan
   propose` drafts: `CISTERN = {"tpl":"cistern","site":"S1"}`, plan.py:52, drafted at plan.py:1141) it is bucket-fed: a
   pond hole (1,3) beside the well (0,3) and a pond zone; bucket carriers fill it from a water source. With a `path` it
   is fed through a pipe from revealed brook/river water behind a floodgate that only the well room's lever opens (linked
   and pulled by hand; nothing in the kernel does it). fortcore's core and refuge well spots (fortcore.py:134, 192) and
   the hospital's own well spot (rooms.py:170-175) are the same bucket-fed sump design. Nothing checked that a fill
   source exists: `plan propose` drafted the bucket-fed cistern in a fort with no revealed open water (`_cistern_due`,
   plan.py:1199-1203), `plan check` never looked, the kernel never reported a done cistern whose well stays dry (water.lua
   only says why a cistern does not serve the hospital, `cistern_state` 514-566, and only while a hospital is dry).
   A design conflict on top: water.lua's pond-loop rule (412-433) removes a Pond zone within `pond_near` 3 of a wet well
   (live L6: the carriers took the water from the well beside the pond and poured it back). The cistern's pond hole is
   1 tile from its own well, so the first bucket that wets the cistern makes its own well the carriers' nearest source
   and gets its pond zone removed: a bucket-fed cistern whose well stands cannot fill past a trickle (code + the L6
   record; whether it happened to y450s0b0/y452s1b0 is not known, see below).
7. **What counts as the refuge's drink today.** readiness `refuge_dry` (readiness.lua:285-299) counts a well only while
   water's `refuge_ok` says a wet well stands on Tiefe+: a dry cistern's well is correctly no drink there. seal's own
   rating (`burrow_audit`, seal.lua:559, 570) counts every built well as drink (`a.wet`, the SIEGE/WET levels and `rwet`
   in `choose`, which frees the refuge from the 7 breach days): with one dry well Tiefe+ reads as wet. That fits the live
   `alert on Tiefe+ (dry)` beyond the breach window (sep 0: only the BREACH/DEAD levels can take it, `rwet` lets them).

## Not decided offline (the read-only live data that decides it)
- **Why the session's plan check refused S1/S2.** By water.lua's measure the zones of 139,61,139 and 144,61,139 (rot 0)
  lie 10 tiles from well 19098 (z included; the anchors 16), inside the 30: the code at 3d5fe0a would have passed them
  (`tests/test_hospital_sites.py::test_live_case_y453`). A refusal therefore means `state.water.src` was empty at check
  time (no accepted source then: a well over a trickle that comes and goes?) or another site was measured. Decides it:
  the `dfllm plan check` output line, `state.json` `water.src` at that time, and the new `inspect water_sources` source
  entry of 19098 (`[kind, id, x, y, z, accepted, depth, burrow]`: the depth of the water under it).
- **Which cisterns y450s0b0/y452s1b0 are**: `bp/y450s0b0.json`, `bp/y452s1b0.json` `params.path` ("" = bucket-fed);
  kern.log `water: pond zone N removed: the wet well M beside it was its water source (a loop)` (the pond-loop rule hit
  them); the zones screen (a pond zone in each well room?). After the fix: CISTERN_DRY `fill` says it.
- Whether well 19098 is in Kern+ (the coordinator's guess): `water.src_l` / `inspect water_sources` now carry it.

## Fix
- **Sites (`bp/sites.py`):** `rank(..., water=)` for `hospital` (WATER_TPLS): only candidates whose zone rect lies within
  `near` (config water.near, 30) of an accepted source (Chebyshev, z included: `box_dist`/`zone_box`, water.lua's
  `served`), +2 score per tile nearer, `why` `..., well 19098 at 137,77,143 in Kern+ 10 tiles`, `water` `{d, src}` per
  site. None: ValueError `hospital: no accepted water in the fort (...)` or `hospital: no site within 30 tiles of
  accepted water (nearest: well 19098 at ... in Kern+; the nearest candidate x,y,z rot0 is N tiles from it); no accepted
  water in Tiefe+ (126-128,56-77 z129-136; nearest: ..., 9 tiles from Tiefe+): dig the core toward that water ...`.
  Every room site is a public Z4 anchor and the room's burrow stage paints Kern+, so an offered hospital lies in Kern+;
  the refuge level stays the refuge's own (no hospital site there).
- **cmd:** `water_ctx` (state water.src/src_l/refuge_ok, alert.ref) feeds the ranking; its digest is part of the sites
  cache; `water_near` moved here (plan re-exports it). `dfllm bp sites hospital` prints the water line.
- **plan:** `hospital_facts` keeps the site's rot and distance, the ranking's refusal (`why`) and `fill`
  (`sites.fill_source`); `hospital_water` measures the zone and refuses with the ranking's reason (sites and check
  agree); `cistern_gate` warns about a new bucket-fed cistern without a fill source (revealed brook/river/lake >= 8
  tiles, no cavern mark, not the fort's own sump, reachable on foot from Z4; a wet well is none); `propose` drafts no
  such cistern (note `no cistern either (BUG-040: ...)`) and the hospital gate's fix no longer sends the player to one.
- **Kernel:** water labels each source with the burrow it stands on (state `water.src_l`, first 4), `water.label`,
  `water.wet_wells`; `inspect water_sources` sources `[..., depth, burrow]` and `refuge`; CISTERN_DRY (B) once per dry
  spell of a manifest cistern whose built well stays dry `water.cistern_dry_days` (30) (fill pond / pond_removed / pipe /
  none, the project via `runner.kept_in`, the pipe via `runner.bp_params`, the nearest accepted water to carry from);
  pond_loops keeps its removals (`p.prm`). seal's `burrow_size` keeps the bbox and, for the refuge, the tile nearest an
  accepted source (state `alert.ref` `box`/`wd`/`ws`, `refuge_drink` `box`/`near`/`wwet`); readiness's `refuge_dry`
  names the place and the water, `hospital_out` sends the hospital into Kern+ next to the water when Tiefe+ has none.
- Not changed (judgment): seal's alert rating still counts every built well as drink (cause 7): counting only wet ones
  would cut a dry Tiefe+'s hold from "until the citizens get thirsty" (BUG-031 (b) mark) to the 7 breach days during a
  siege. `refuge_drink.wwet` reports the truth; the decision is the player's.

## Found on the way (not fixed here)
- The bucket-fed cistern design conflicts with the pond-loop rule (cause 6); the hospital's own well spot and fortcore's
  well spots are the same sump design. Only a piped cistern (`python -m dfpilot.bp.sites cistern`) fills reliably, and
  only once its lever is linked and pulled by hand.
- `water.lua`'s monthly PROJECT_REQUEST `cistern why=hospital_water` does not look for a fill source either (no consumer
  places it).

## Tests
`tests/test_hospital_sites.py` (new), `tests/lua/test_water.lua`, `tests/lua/test_seal_refuge.lua`,
`tests/lua/test_readiness.lua` (each new test fails on 3d5fe0a); adjusted: `tests/test_hospital_water.py` (the zone
distance 37, not 40), `tests/lua/test_seal_refuge.lua` (alert.ref/refuge_drink carry box/wd), `tests/lua/test_water_fr.lua`
(the source entry's depth and burrow), `tests/test_cli_wake.py` (the hospital_out hint).

Related: BUG-034, BUG-035, BUG-036, BUG-031, FR-47, live L6 (pond loop)
