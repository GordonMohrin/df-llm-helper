# BUG-293 the player's pop ceiling is lost at a plan reload; no famine hold, no verb to raise it
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-10-29, Run 15c (Inkintense, FR-BUGS Runde 2)
Module: `lua/dfllm/readiness.lua` (inbox_cap, M.famine_check, M.hold_text, verbs popcap.lower/raise/set), `lua/dfllm/util/contract.lua`, `dfpilot/schema.py`, `dfpilot/brief.py`

## Actual
Run 15c Inkintense y375-y376: the player's `popcap.lower cap=25` (round 1) was dropped by the next `plan.reload` (#1029 at tick 151263251, then #1031 POPCAP `max-pop 100 (R0)`); the open-perimeter hold flipped the cap between 32-50 and 100 (#1264, #1312, #1375 `max-pop 100 (R0)`) and migrants came 26 -> 50 through a famine at 0-11 food days (one dwarf starved). Root cause: readiness.lua inbox_cap cleared the inbox ceiling whenever `plan.loaded` changed (`a new plan supersedes an inbox lowering`); nothing lowered max-pop for a famine; there was no verb to raise a lowered ceiling.

## Fix
The player's ceiling (`st.inbox = {cap, u, t}`) survives plan reloads, R0 passes and a closed perimeter. `popcap.lower {cap, until?}`: `until=food` (default while food < FAMINE.player_d 60 days) is lifted once food is back at 60 days, `until=raise` holds until `popcap.raise`. New verbs: `popcap.raise {}` lifts the player ceiling (and a running famine hold for that episode), `popcap.set {cap}` sets the player ceiling exactly (raise or lower; the level and plan caps still bind). Kernel famine hold: food below FAMINE.low_d 15 days and falling (or 0), sampled once a game day, holds max-pop at the population of that moment (POPCAP why `famine`) until food is back at FAMINE.recover_d 30 days. State `pop.hold` (<= 40 bytes: `player 25 until food 60 d`, `famine 50 (food 1 d)`), status pop line ` ceiling <hold>`. Persisted (m.readiness inbox/fam/fprev/fskip); an older save's `{cap, plan}` is held until popcap.raise.

## Tests
`tests/lua/test_fix10_famine.lua` (4 BUG-293 tests), `tests/lua/test_readiness.lua` (popcap.lower pin: the reload keeps the ceiling, popcap.raise lifts it), `tests/test_fix10_famine.py` (verbs, pop.hold, status line). Fail on 05dc764.

## Live check
after `dfllm cmd popcap.lower cap=25` and the next plan reload: `dfllm status` pop line still `gate 25 ceiling player 25 until ...`; `dfllm events --type POPCAP` shows no `R0` raise above 25; at the next famine (food < 15 d and falling) POPCAP `why famine` and kern.log `readiness: famine hold`; `dfllm cmd popcap.raise` brings the R0 cap back.
