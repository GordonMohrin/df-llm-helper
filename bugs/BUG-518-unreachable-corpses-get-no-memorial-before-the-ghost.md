# BUG-518 Bodies nobody can walk to (tree crowns, no walk group) get a memorial slab only after a ghost exists, and tombs.repair says nothing about them
Status: fixed (offline, live-untested)
Severity: high (a ghost scared a citizen to death; ghosts keep the stress sources up for years)
Found: 2026-11-06, Run 16b i2 Brotherarrow y385 (`runs/run-16b/FR-BUGS.md` "BUG Geist erschreckt Buerger zu Tode (y385 sum d14-d37), Leichen unerreichbar"; events.jsonl DEATH #3205/#3213 `incident SCARE; by dwarf 26369`, GHOSTS #3206 `corpse_unreachable 2`; read only). Earlier: BUG-105 (the class), BUG-133 (memorial slabs)
Module: `lua/dfllm/care.lua` (`phase_memorials_run`, `MEM.unreach`, `tombs.repair`, `tomb_report`, `M.unreach_ids`), `lua/dfllm/economy.lua` (`M.slab_extra`, `slab_pass`, `slab_engrave`)

## Actual
Five (later two more) citizens drowned at the brook and their bodies lie on branch tiles / tiles without a walk group (`corpse_unreachable`, BUG-105). No coffin, zone or hauler can bury them; the only thing that lays the dead to rest in DF is a memorial slab (autoslab, or our EngraveSlab order of BUG-078). Both ran for a body only after it was a *ghost* (`MEM.ghosts`: census.g and the ghostly units of the death record; `slab_engrave`: census.g ids). The ghost of 26369 walked for about 13 years, scared 26850 to death (DEATH `unknown (incident SCARE; by dwarf 26369)`), and `tombs.repair` answered `queued: the next care run repairs ...` although a repair cannot touch those bodies. kern.log shows the slabs coming one at a time, each only after its ghost (`memorial: slab 1523653 of ghost unit 26369 placed ...` twice, years apart).

## Root cause
`care.lua phase_memorials_run` took `MEM.ghosts(K, p, now)` as the only list of memorial targets, and `economy.lua slab_engrave` built its candidates from `census.g` only. The set the burial work already knows to be unburiable (`r.unr`, BUG-105) was a count in `inspect tombs` and a note in the GHOSTS wake, nothing that acted. `tombs.repair` set `st.force_repair` and answered with a fixed string.

## Fix
- `care.MEM.unreach(r)`: the dead whose body is in `r.unr` and who have a historical figure. `phase_memorials_run` adds them to the ghost list (same states none / order / loose / build / placed, same placement search); `st.unr_ids` keeps them; one warn line in kern.log when the set changes names the units and says a slab is their burial. `care.unreach_ids(K)` hands the list to economy.
- `economy.slab_extra(K)` (the care list without the ghosts already in census.g): `slab_pass` counts them in `ghosts` (restock cap, ConstructSlab), `slab_engrave` serves them like a ghost older than `slabs.engrave_days` (same order, same back-off, never twice).
- `tombs.repair` appends how many bodies lie where nobody can walk, which units and the slab states (`unreach`, `unreach_n`, `mem` in the reply data); `inspect tombs` carries `unreach` [[unit, slab state]].
- The scare death itself is a DF mechanism (a ghost frightens); the slab now comes before the ghost does.

## Tests
`tests/lua/test_bug518_unreach_memorial.lua` (2: care.unreach_ids lists only the dead with a figure, inspect tombs and the warn line; tombs.repair names the unreachable bodies and keeps the short answer when there are none), `tests/lua/test_economy_b2.lua` (+1: EngraveSlab orders for unreachable bodies, the ghost in census.g not twice).

## Live check
On a fort with bodies in crowns: `dfllm cmd tombs.repair`: the reply says `N citizen bodies lie where nobody can walk ... (slabs: ...)`; `inspect what=tombs` `unreach`; kern.log `economy ... EngraveSlab order ... for ghost unit <id>` for a unit that is not a ghost yet, then `care memorial: slab ... placed`.
Open: a memorial helps only once a Masons workshop, a boulder and a free 3x3 floor exist (the existing GHOSTS / slab_why / PROJECT_REQUEST workshops texts say which is missing); a unit without a historical figure cannot be served (counted in `unreach_n`, not listed in `unreach`).
