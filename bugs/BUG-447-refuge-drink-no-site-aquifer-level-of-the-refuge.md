# BUG-447 refuge_drink finds no site: the aquifer rule drops every site on the refuge's own levels
Status: fixed (offline, live-untested)
Severity: high (R0 refuge_dry holds the population for years)
Found: 2026-11-05, Run 16c i3 Castletongs y375-y380 (`runs/run-16c/FR-BUGS.md` "BUG refuge_drink findet nie einen Platz")
Module: `dfpilot/bp/sites.py` (`aquifer_ok`, `rank`)

## Actual
`bp sites refuge_drink --fresh`: "none (0 ranked, 0 project(s) hold them): refuge_drink rooms open from the dug Z4 floor of the fortcore"; `plan propose`: "no free site for 8 barrels (taken by other projects)"; R0 refuge_dry,
pop ceiling 29-38 for years. Reproduced offline on the i3 files (`dfllm-runtime/r16c3-castletongs-site97/snap/c1a1aae95c6be45801.json` + `manifest.json`, read only): `_rooms` finds 27 sites on the refuge level z119, then
`aquifer_ok` (FR-95) drops all 27: the manifest's `aquifer_levels` [110, 111, 113, 119, 120] contain z119, the level the refuge room itself stands on and was dug in (and z120 right above). A refuge-level room opens only into the refuge.
Nothing raised, so every hint blamed "other projects" / "snapshot predates the dig".

## Fix
- `aquifer_ok`: for a refuge-level template (`on_refuge`: refuge_beds, refuge_drink, a refuge cistern) the levels the refuge room's own bbox stands on (z0..z1+1, the levels the rule tests) do not count as aquifer levels; other known levels
  still rule a site out, damp / aquifer marks stay avoided by the ranking. On the i3 files refuge_drink n=8 now ranks 3 sites (125,124,119 and others).
- `rank` raises "all N candidate site(s) lie on or right under a known aquifer level (z..)" when `aquifer_ok` empties a non-fortcore ranking, instead of ranking nothing.
- Residual risk: the new rooms dig into tiles that may be unrevealed (the i3 sites show 15-19 unknown tiles) on a level whose neighbours are aquifer: the dig stops on water like every dig (AQ_SEEP / AQ_HEAVY); the refuge room was dug the same way.

## Tests
`tests/bp/test_bug447_refuge_aquifer.py` (4 cases).

## Live check
`dfllm bp sites refuge_drink --fresh` on i3: sites at z119; `plan propose` drafts `refuge_drink`.
