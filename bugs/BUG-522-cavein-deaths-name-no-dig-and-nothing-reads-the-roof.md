# BUG-522 Two citizens died in a CAVEIN while digging (y385 d11) and no event names the dig; nothing reads the roof of a hole before it is dug
Status: fixed (offline, live-untested) as attribution plus a switchable guard; the cause of the y385 deaths is NOT proven
Severity: high (loses citizens)
Found: 2026-11-06, Run 16c i3 Sealcertain y385 d11 (`runs/run-16c/FR-BUGS.md` "BUG 2 Tote durch CAVEIN waehrend Sommer y385"; events.jsonl #3176/#3177 `missing`, #3207/#3208 `found dead: crushed (incident CAVEIN)` at 15,13,141; read only)
Module: `lua/dfllm/runner.lua` (`Q.cave_risk`, `Q.cave_guard`, `M.dig_near`), `lua/dfllm/care.lua` (`cave_attr`), `dfpilot/schema.py` (DEATH `dig`)

## Actual
24804 and 26960 were missing from the unit list from tick 155445642 (summer d11) and found crushed at 15,13,141 at tick 155469944. DEATH said `crushed (incident CAVEIN)` and nothing else; the brief `crushed 2`. The report asked which project's dig did it.

## What the logs show
No dfpilot project dug within 70 tiles of 15,13,141: the open projects of that year are y385s0b0 (hospital, 34,144,137), y385s0b1 (fortcore, 62,82,142) and y379s0b0 (refuge_beds, 56,131,134, parked at a cavern lake); the quarry / stone digs (care `stonedig`, mood) log nothing in that window. So either a dig outside the kernel's projects (the dwarves' own designations), or the DEATH `pos` is where a body that was missing for ten days was found. The log cannot decide it, which is the finding: the report had no field that would.

## Root cause (of the gap)
Nothing recorded which dig chunks were designated where, and nothing looked at what a hole is dug under. A cave-in drops a floor tile that no wall holds; the runner designated every chunk without reading the level above it.

## Fix
- `runner.Q.cave_risk(K, ch)` / `Q.cave_guard`: before a dig chunk is designated, the roof tile above every dug tile (key d h u j i r) is read (snapshot.tile, at most `CFG.cave_probe` 30): a revealed FLOOR tile the chunk does not dig itself with no revealed WALL tile among its eight neighbours (an unrevealed one is no verdict) is a free-hanging floor. `CFG.cave_check`: `warn` (default) logs the project, chunk and tile once and records it in `rt.cv`; `block` blocks the project `cavein_risk` before the designation (bp.cancel it or place it elsewhere); `off`.
- `runner.dig_near(K, pos, r)`: the projects whose bbox lies within r tiles (xy) and one level of a position, with distance and the recorded risk tile. care's DEATH for a CAVEIN carries `d.dig` ["<proj> <tpl> s<stage> <dist>t [risk x,y,z]"] and the text `dig near: <proj> N tiles (free-hanging floor above)` or `no dfpilot dig within 12 tiles` (then the cause is not one of ours).

## Tests
`tests/lua/test_bug522_cavein.lua` (3: warn mode records and keeps digging, block mode stops and a wall neighbour / an unrevealed neighbour / off are no risk, the CAVEIN death names the digs or says none).

## Live check
Next CAVEIN death: DEATH `dig` names the digs near the body or says none; kern.log `free-hanging floor tile(s)` lines before any dig. If a fort shows risk lines for stacked rooms that DF does not drop, keep `warn`; if a CAVEIN follows a risk line, set `runner.CFG.cave_check = 'block'` (kernel config, not yet in config/*.json).
Open: the default is `warn`, not `block`, because the roof rule is DF's documented behaviour, not proven against this game version (a stacked room pair has floor tiles without wall neighbours); the y385 cause stays open until a CAVEIN event carries `dig`.
