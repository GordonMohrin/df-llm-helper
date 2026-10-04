# BUG-432: Trade depot disappeared from the game; depot position reported inconsistently

- **Status:** open
- **Severity:** S2
- **Area:** `lua/claude/ueberwacher.lua`, `lua/claude/handel.lua`
- **Reported:** 2026-10-04, commit `eb0f007`
- **Environment:** Windows 11, Python 3.14, game: running (DF 53.16 + DFHack), fort Windrings year 182-183 (Run 5)

## Command / steps
1. Depot 6111 with origin `(104,97,z133)` existed until about 22:10 (merchants stood at (106,98) and (106,99)).
2. At 22:52 `ueberwacher` wrote `notfall.flag`: `KEIN HANDELSDEPOT`. `world.buildings.all` contained no TradeDepot.
3. Rebuilt with `quickfort run claude/r5h_depot.csv -n /r5h_depot -c 104,97,133` (5x5): new building 8623, finished about 23:00.

## Expected
A depot is never removed silently, and the helper reports one consistent position (a 5x5 depot at origin (104,97) covers x104..108, y97..101, so merchants at (106,98) stand inside it).

## Actual
The depot vanished without an announcement. The trade agent later said "the depot is at (106,99), not (104,97)", because it looked at where the units stood. Who removed building 6111 is unknown (candidates: the reload from the 21:59 autosave, one of the building agents, a `quickfort undo` of a same-extent layer).

## Evidence
none (building list before and after was not captured).

## Analysis (reporter's hypothesis)
`quickfort undo` removes everything with the same extent; the reload may also have restored an older layout. Neither is confirmed.

## Suggested fix
`handel status` should print depot id, origin, size and build stage; `ueberwacher` should re-queue the depot blueprint when no depot exists and no caravan is present.

## Info needed
Check the announcements between 22:09 and 22:52 for "deconstructed/destroyed" depot messages.
