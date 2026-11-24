# BUG-826 quiet PEACE ran at timestream 500 with 30 graphics frames; the dead-man tick bound would pause players after 24 s at 1000 ticks/s
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-11-24, Gordon's request: "by default, when nothing special is going on, every game should run at maximum game frames and few graphics frames, and timestream should be used as much as possible"; live: a 44-dwarf fort reached ~270 ticks/s (CPU bound), an 18-dwarf fort ~475 (timestream target 500, DF FPS cap 250 on most instances, 60 on one)
Module: `lua/dfllm/arbiter.lua:31` (`M.MODE_FPS`, `M.CLOCK`, `M.PROFILE.gfps`, `deadman`), `config/reflex.json` `clock`, `deadman`

## Actual
Quiet PEACE targeted timestream 500 and every game ran `enabler.gfps` 30 (a render takes CPU the simulation could use). Raising the target alone would have broken the dead-man: `deadman.max_ticks` 24000 is only 24 real seconds at 1000 ticks/s, shorter than the time a player thinks between two commands, so a live player would be paused mid-thought.

## Cause
`M.MODE_FPS.PEACE = 500` and `M.PROFILE.gfps = 30` were constants (arbiter.lua:31, :37); the dead-man compared game ticks only (`ran > max_ticks`, arbiter.lua `deadman`).

## Fix
`config/reflex.json` `clock.gfps` (1..100, default 10) and `clock.peace_fps` (100..1000, default 1000), read by the arbiter (`M.clock_cfg`, bounds in `M.CLOCK_LIM`; a bad value keeps the built-in default key by key). Only quiet PEACE uses `peace_fps`; ALERT/RECOVERY 250, SIEGE/BREACH/DRILL off with the siege cap, the clock lockdown, trade cap, supply brake, tempo.lower and the P0 brake are untouched. The vanilla FPS cap is NOT raised (timestream already ran 475 ticks/s above a 250 cap live; the arbiter keeps "only the brake writes the cap"). While trade holds the clock gfps rises to 30 (the trade UI click waits are 100 ms) and falls back. `deadman.min_s` (0..3600, default 45): the tick bound fires only once the heartbeat is also `min_s` real seconds old; `timeout_s` 180 stays the primary bound. State `clock` gains `gfps`, `pt`; the status clock line names the gfps; D-11 rejected shows `ts -1`. Details and the worst case in game days: `docs/v2/NEU2-tempo.md`.

## Tests
`tests/lua/test_bug826_tempo.lua` (9: defaults, a cap of 60 left alone, override, invalid values, every other mode unchanged, brake/lockdown win, trade gfps, D-11), `tests/lua/test_neu1_deadman.lua` (2 new: min_s), `tests/lua/test_kern_arbiter.lua` (expectations moved to 1000/10), `tests/test_bug826_tempo.py` (5: lint, Lua = JSON defaults, status line).

## Live-Erwartung
1. `status` in a quiet PEACE fort shows `clock: free (cap 250, timestream 1000, gfps 10)`; during a siege/lockdown `clock: held 30 t/s, reason ..., gfps 10`; during a caravan trade `gfps 30`.
2. A fort with few dwarfs shows clearly more ticks/s than before (earlier ~475 at 18 dwarfs); a large fort stays CPU bound (about 270 at 44 dwarfs) and gains little. No fort runs faster in SIEGE/BREACH/ALERT than before.
3. No `DEADMAN_PAUSE` with `why: ticks` while a session is alive (heartbeat every 10 s in `wait`); a dead session still pauses the game within ~185 real seconds.
4. kern.log shows no `fps cap` raise; no `ui_timeout` regression in caravan trades with gfps 10 (trade runs gfps 30).
