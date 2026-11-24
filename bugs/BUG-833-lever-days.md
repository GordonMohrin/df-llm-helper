# BUG-833 the player's `lever` down could not name its hold: days= / hold= refused, the 3-day hold lasts seconds at timestream speed
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-11-24, Run 17d i4 Girderroots: `cmd lever bridge=B1 want=down` -> `ok lever: B1 already down; held down 3 days`; `days=` / `hold=` refused as unknown keys; at ~450 ticks/s three game days (3,600 ticks) are ~8 real seconds, so the player could not keep B1 down while the kernel crushed citizens
Module: `dfpilot/schema.py` (VERB_ARGS lever), `lua/dfllm/gate.lua` (`M.verbs.lever`, `M.HOLD_MAX`)

## Fix
`lever` takes `days` (int 1..120, only with `want down`): the hold lasts that many game days instead of `gate.lever_hold_days`; a bad value or `days` with `want up` is refused with the bounds. The hold semantics are unchanged (no automatic raise in PEACE; a lockdown, a threat, a drill or `lever up` ends it). Schema, RULES.md and the CONTRACTS appendix carry the key.

## Tests
`tests/lua/test_bug831_833_peace_bridge.lua` (lever days), `tests/test_bug831_833_config.py` (schema accepts 1..120, refuses 0 and 121).

## Live-Erwartung
1. `cmd lever bridge=B1 want=down days=10` answers `held down 10 days`; kern.log `gate: B1 held down by lever (...) for 10 days`; no `GATE B1 up` in PEACE until the hold ends or a threat comes.
