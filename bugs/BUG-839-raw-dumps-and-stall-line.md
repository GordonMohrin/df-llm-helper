# BUG-839 forts die of thirst and nobody can read WHY: no raw view of the game's own order / job / item / manager state, no stall line in kern.log
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-24, Run 17 i1 Diedplank y380, i2 Whirledrampart y485 (MakeBarrel job 1430329 unworked 54 days; 'Needs logs' cancels beside 183 free logs; `why` input scan '0 match' beside 6,978 plants; 'no builder took it' beside idle citizens). Two rounds of fixes (round 51 BUG-779, BUG-834..838) acted on a guessed cause; two verifiers rejected it.
Module: `lua/dfllm/dfraw.lua` (new), `lua/dfllm/economy.lua` (`M.inspect.raw`, `M.stall_log`), `lua/dfllm/jobwhy.lua` (`J.util`, `J.labors`), `lua/dfllm/snapshot.lua` (`M.hidden`), `dfpilot/cli.py` (`why --raw`), `dfpilot/schema.py` (`inspect what=raw`)

## Root cause
No tool printed what DF itself keeps: an order's flags, pinned shop and conditions, a workshop's profile / jobs / links, a job's items and the labor holders with their burrow / walk group / squad state, the items of a need counted by the reason DF may skip them, the manager's office and orders. The interpretations (jobwhy causes, `brew_cause` verdicts) were built on guesses, and the fake world shared the guess. `J.labors` returned nil for a MakeBarrel-like job given without a shop (`O.workshops(MakeBarrel, 'any')` is nil), so a bare job read 'the labor is not known'.

## Fix
- `inspect what=raw key=...` (`dfpilot why <key> --raw`): `order:<id>`, `brew`, `job:<id>`, `items:<logs|plants|barrels|VECTOR>`, `manager`, `ws:<id>`. Read only, bounded (140 lines of 290 characters), no interpretation. Every field is read through pcall; an unreadable field prints `?` (never 0, never an error); each struct is also dumped generically (`pairs`) so the real field names show even where a name here is wrong. No DF structure source is installed (only symbols.xml), so no field name is taken on trust.
- Items: per vector the count of items by exclusion reason as DF may see it: forbid, dump, in_job, in_building, on_fire, rotten, owned, trader, melt, hostile, in a claimed container, outside the civil-alert burrow, other walk group, unwalkable tile, hidden tile; first-reason counts and hit counts; the census value beside.
- Stall line: `M.stall_log` writes ONE kern.log line `raw stall <brew|order|build>: ...` per stall and game week (`economy.diag.stall_line`, default on) from `brew_watch` (before any cure), the stale-order scan and the 'no builder took it' build state: order flags, pinned shop, Still jobs (suspended / working), labor holders by status (free, busy, burrow_own, burrow_civ, far, soldier, mood), items by reason, census.
- `J.labors` without a shop key falls back to wood, then rock, for a job with no material class (MakeBarrel -> CARPENTER).

## Tests
`tests/lua/test_neu3_diag.lua` (11: every dump against the fake world, a world whose fields all raise, the counts of 183 logs by reason, the weekly stall line, the order and build lines), `tests/test_neu3_diag.py` (contract, switches, `why --raw`).

## Live-Erwartung
1. After the reload `dfpilot why brew --raw`, `why order:<id> --raw`, `why job:<id> --raw`, `why items:logs --raw`, `why items:plants --raw`, `why items:barrels --raw` and `why manager --raw` on i1 and i2 print the dumps (docs/v2/NEU3-diagnose.md names the line that confirms or refutes each hypothesis H1..H8).
2. kern.log of a stalled fort has one `raw stall brew:` line within one game week (and `raw stall order:` / `raw stall build:` for stale orders and untaken builds), again each following week while the stall holds.
3. Unreadable fields show as `?`; the line `fields not readable on this DF` in an items dump names flags the game does not have. Those lines are the next fix's input, not a failure.
