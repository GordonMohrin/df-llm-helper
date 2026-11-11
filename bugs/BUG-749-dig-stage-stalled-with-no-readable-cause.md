# BUG-749 A dig stage "stalled 30 d at dig 6%: set aside" names no cause; the lone Miner hauled barrels while dig jobs stood open
Status: fixed (offline, live-untested)
Severity: medium (explore / tombs digs of stone-less forts stand for months)
Found: 2026-11-11, Run 16a i1 Basementflew (explore c1a1ca697e and tombs c1a1ca77f7 "stalled 30 d at dig 0-6%: set aside", kern.log:2779, 2945, 2980, 3030; economy "tools: Miners blocked (none): nothing visible ... member 27163: job StoreItemInBarrel, 2 items on his pickup list, 5 work tool pairs in the fort ... picks: 1521814 ... u foreign", kern.log:3052)
Module: `lua/dfllm/runner.lua` (`Q.parts`), `lua/dfllm/economy.lua` (`M.dig_wait`, `T.boost`)

## Root cause
- `Q.parts` (what a stalled stage waits for) answered only for build stages; a dig stage printed "stalled 30 d at dig 6%: set aside" with nothing after it.
- The one Miner (detail "Miners", one member) held the Mining labor and 4 reachable open dig jobs and took none: he was at StoreItemInBarrel, a hauling job. The tool answer ended at "nothing visible". All four sampled free picks carry the flag `foreign` (bought from caravans: trade ledger "bought pick x1"); whether DF hands foreign picks out as work tools is not proven (the flag is not among the blockers `TD_BLOCK`). The designation jobs wait at the end of DF's list like the construction jobs of BUG-747.

## Fix
- `economy.dig_wait(K, bbox)` (one pass over the job list, called for a stalled or set-aside announcement only): the dig jobs inside the stage's box (open, taken, suspended, raised), the Miners detail (members, idle, the job most of them are at) and the tool answer of the last tool check: "dig: 3 dig jobs here (1 open, 1 taken, 1 suspended, 1 raised); Miners detail 2 (0 idle, 2 at StoreItemInBarrel); tools: ...". `Q.parts` returns it for a dig stage, so PROJECT_BLOCKED `d.parts` / `waits:` and `inspect projects` carry it.
- `T.boost` (BUG-747) raises untaken dig jobs after 3 days too, so the Miner takes the dig before the hauling.

## Tests
`tests/lua/test_bug747_749_boost.lua` ("BUG-749": `dig_wait` counts and text; the runner puts it into `d.parts` of a set-aside dig project).

## Open
The `foreign` picks and the second Miner (`tools.min` 2, the fort had one) are not changed; no verb moves or unforbids a tool for a member (fair play).
