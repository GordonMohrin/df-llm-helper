# BUG-133 Ghosts never rest: no memorial slab is ever placed, the slab orders starve, and the tomb repair frees the same zones for ever
Status: fixed in the BUG-133 commit (offline, live-untested)
Severity: critical (Run 14: ghosts 0 -> 49; ghosts haunt, stress the fort and topple buildings)
Found: 2026-10-28, Run 14 region2-site90 (y502-y716), analysis of the event log and kern.log at dec5132
Module: `lua/dfllm/care.lua` (memorial phase new, `tomb_repair`, `corpse_seen`, `tomb_report`, `inspect`), `lua/dfllm/act.lua`
(`slab_place` new), `lua/dfllm/orderfix.lua` (`OF.slabs`, `OF.slab_buildings` new), `lua/dfllm/economy.lua` (`slab_pass`,
`slab_engrave`, `slab_why` new), `lua/dfllm/runner.lua` (rebuild policy), `dfpilot/wake.py`, `dfpilot/lint.py`

## Actual
139 GHOSTS events. y502-y586 ghosts 0-14 (unreachable, no_job, coffin_taken, zone_shared); y586/y636/y645 TOMBS_LOCKED churn
"14046 freed re-given by DF"; y631-y707 corpse_far 5 stable; y707 mass death (181 DEATH events, pop 8, rebuild mode), then no_coffin
14 -> 69 and ghosts 0 -> 49 (y716), 41 after a reload. kern.log: `tombs: removed 0, freed 20, opened 0, assigned 0, entomb 0` 631 times.
economy removed 47 EngraveSlab orders (0 blank slabs), ordered ConstructSlab only three times (x3, x1, x4). The Masons', Carpenters' and
Craftsdwarfs' workshops were lost at 284.35M/286.05M and the rebuild policy paused the workshops project. `inspect tombs` said "20 ghosts"
while 28 stood.

## Cause (proved from the code at dec5132)
1. Nothing in `lua/` placed a slab: the only mention was the GHOSTS hint text ("slab for no_body"); DFHack's autoslab only queues engrave
   orders. `OF.slabs` counted every engraved memorial (placed or loose) as a served ghost, so `slab_engrave` never looked further.
2. `slab_pass` capped the blank slabs at `restock_cap` 5 for any number of ghosts; with no mason's workshop it set `sb.why = 'no Masons'`,
   visible only in `inspect orders`, and asked for nothing.
3. The rebuild policy (pop < `rebuild.pop`) paused every workshops project, also the one that would have built the masons' shop.
4. `corpse_seen` kept `r.interred[coffin] = uid` single-valued: a coffin with two bodies listed only the last; the zone of the first body was
   freed as `elsewhere`, DF handed the free zone over the occupied coffin to the next dead (coffin_taken), the next run freed it again
   ("freed re-given by DF"). A stale or bad zone over an occupied coffin was freed the same way.
5. `tomb_repair` spent its shared budget of 20 acts on removals and frees first: the assignments got 0 (`freed 20, assigned 0, entomb 0`).
6. `inspect tombs` counted the ghost LIST (capped at 20), not the ghosts.

## Fix
- `act.slab_place(item, x, y, z)` (care): Build > Furniture > Slab with that slab chosen: `dfhack.buildings.constructBuilding{type = Slab,
  items = {slab}}`, a planned building the builder fetches and builds. Refused: no SLAB item, in a job, built in, carried, a merchant's,
  garbage, nobody can walk to the tile (`canWalkBetween`, the slab list greys such a slab out; the lint allows the read in `slab_place` as
  in `free_mechanisms`). A forbidden slab is unforbidden first (its toggle). The game judges the tile.
- care's memorial phase (after tombs): every ghost (census.g, then the death record) gets its slab state none / order / loose / build / placed
  / nohf (`OF.slabs`: a memorial in a built Slab building or built in = placed, in a planned one = build, else loose). In PEACE/RECOVERY up to
  `care.memorials` (2) loose memorials a run are placed on a free roofed floor tile whose eight neighbours are free floor too (the inner
  part of a free 3x3: never a way, a door or a stair), judged as the coffin search judges its floor (revealed, no designation, building,
  zone or stockpile, roofed, `coffin_entrance_r` from the entrances, the citizens' walk group), nearest the crypt / core / citizens; a
  refused placement is retried a day later, three times. GHOSTS `d.slabs` (per listed unit) and `d.mem`; `inspect tombs` ghosts
  `[unit, cause, slab]`, `mem`, `mem_why`.
- `OF.slabs`: `placed`, `build`, `loose` ({hf = item id}); `slab_engrave`: a ghost is served only by a placed or building memorial, a loose
  one gets no second order; `sb.served`, `sb.loose`, `sb.gneed` (ghosts without memorial and order).
- `slab_pass`: ConstructSlab for `gneed` ghosts, capped at min(ghosts, `restock_cap` 20); `M.slab_why`: kern.log names why no slab is
  ordered (util/cadence), and while ghosts stand and no mason's workshop does, PROJECT_REQUEST workshops why=slabs types [Masons] at most
  every `food.request_days`; follow places the masons' shop alone (as why=mandatory).
- runner: a workshops project of Masons and/or Carpenters only (`tomb_shops`) runs in the rebuild while care reports ghosts, old bodies
  or short coffins (seal first and care first still pause it as work).
- `tomb_repair`: a coffin holds several bodies (`r.inside`); a zone over an occupied coffin is never freed (`acts.kept_occ`); the
  assignments (with the frees of the zones they give and the bad zones their bodies leave) run first on their own budget
  `care.tomb_assign_per_run` (20), then removals and frees on `tomb_acts_per_run`.
- `inspect tombs`: `ghosts_n` = every ghost; msg `28 ghosts (+8 more not listed)`.

## Tests (each fails on dec5132)
tests/lua/test_care_ghosts.lua (8), tests/lua/test_economy_b2.lua (4 new, BUG-061 cap 5 -> 6), tests/lua/test_runner_seal_first.lua (1),
tests/lua/test_act_supply.lua (1), tests/lua/test_care_b3.lua and test_care_fr.lua (the new order of the acts), tests/test_bug133_ghosts.py (4).

## Live check
`dfllm inspect what=tombs`: `N ghosts` = the ghosts on the units screen, `memorials: ...`, each ghost `[unit, cause, slab]`; a loose engraved
memorial becomes `build` within a care run in PEACE (kern.log `memorial: slab ... placed at x,y,z`) and `placed` once built; a ghost with
its slab placed leaves the GHOSTS list. `inspect orders` slabs: `gneed`, `served`, `loose`, `want` <= 20. No mason's workshop: kern.log
`slabs: no ConstructSlab ... no Masons` once, a PROJECT_REQUEST workshops why=slabs, follow places the masons' shop at prio 1 and it runs
in the rebuild. kern.log `tombs:` lines show `assigned` > 0 when bodies wait; TOMBS_LOCKED `churn` stays 0.

## Not decided offline
Whether DF 53.16's constructBuilding takes an engraved memorial in `items` as the Build menu does (buildingplan and quickfort place slabs
that way; the item list of the real menu was not read); whether a built slab building of another figure's memorial nearby needs distance.

## Review
- A planned Slab building holds its slab in the ConstructBuilding job (`Buildings::constructWithItems` attaches the items to
  the job; `contained_items` fills only once it is built), so `OF.slab_buildings` reads the job items too: a placed memorial
  waiting for its builder said `loose` (and `slab ... in job`) from the next run on. The test mock now puts the slab in the job.
- economy's why=slabs request is not sent while a workshops project is queued (`runner.pending`, as the tannery request):
  follow would place a second masons' shop beside a paused one every request_days.
