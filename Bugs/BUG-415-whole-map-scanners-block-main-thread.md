# BUG-415: `claude/ores`, `claude/geo` (classified as plain reads) and other whole-map scanners will block the game's main thread for > 20 s - not run, extrapolated

- **Status:** fixed in ce278a8
- **Severity:** S2 (a "read" command that freezes the game; the helper polls reads freely)
- **Area:** `lua/claude/ores.lua:33-39`, `lua/claude/geo.lua:15-37,70-85`, `lua/claude/zugaenge.lua` (header: "~10 s runtime (main thread)!"), `lua/claude/kohle.lua:21-45`, `lua/claude/erzdig.lua` (also with `--dry`), `lua/pilot_perimeter.lua` (`scan`, synchronous), classification `df_llm_helper/client.py:61-62` (`_READ_EXACT`: `claude/ores`, `claude/geo`)
- **Reported:** 2026-10-02, commit `6dedd96`
- **Environment:** Windows 11 Pro, game running (DF 53.16 + DFHack, **paused**), map 192 x 192 x 153 (`claude/status` -> `map_size`)

## Command / steps (all NOT run)
```
dfhack-run.exe claude/ores
dfhack-run.exe claude/geo
dfhack-run.exe claude/zugaenge
dfhack-run.exe claude/erzdig ALL 104 132 60 --dry
dfhack-run.exe claude/pilot_perimeter scan 100 101 130 100 140
```

## Expected
Reads that finish in well under a second, or are clearly marked / chunked.

## Actual (estimate)
- `ores.lua`: `for bz = 0, mz-1; for bx; for by; getBlock(...)` = 153 x 144 = **22,032 blocks**, each iterating `blk.block_events` with `is_instance` checks (and the per-tile bit loop for vein events).
- `geo.lua`: tile-level double loop over **all** z (5.6 million tiles, `designation[i][j]` + `tiletype.attrs` lookups) and a second loop `for bz = 0, ceil(97)` (3.5 million tiles). This is the heaviest script of the set.
- Reference measurements from the project itself: `workload.py:88` "run `claude/kohle run 10` once by hand (permanent job stays off, **9 s freeze**)" - `kohle.run` scans only z >= `dig_min_z` (104..152 = 49 levels) with exactly the same block-event loop as `ores`; `zugaenge.lua:1` "~10 s runtime"; `pilot_perimeter.lua:12` "(the prototype held it ~10 s)". Scaling `kohle` by 153/49 gives roughly **28 s for `ores`**; `geo` should be well above that.
- Measured cheap neighbours (for calibration): `claude/raster status` 0.45 s, `claude/bauprog status` 0.2 s, `claude/config` 0.5 s (41 levels over the fort box), `claude/pilot_reach dump` 180k tiles 0.3 s, `claude/mood plan` 1.3 s (145 KB answer).

## Evidence
none (not run on purpose). Calibration timings are in `Bugs/RESULTS-lua.md`.

## Analysis (reporter's hypothesis)
Scripts from the exploration phase (run 4/5) written for a one-off use by the orchestrator, later whitelisted as "reads".

## Suggested fix (optional)
Chunk like `pilot_perimeter start` (budget per frame via `dfhack.timeout(1,'frames')`), or restrict to `cfg.Z_MIN..cfg.SURFACE_Z`; remove `claude/ores`/`claude/geo` from `_READ_EXACT` (or give them a `timeout`/`heavy` tag so autopilots never call them unattended).

## Info needed
- Player: at a safe moment (fort saved, no siege) please run `Measure-Command { dfhack-run.exe claude/ores }` and `claude/geo` once and add the seconds here. >20 s confirms the bug; <5 s means the extrapolation is wrong and the severity drops to S3.

## Fix
`ores` (optional z range) and `geo` (one pass instead of two) scan top-down and stop after a time budget (`--budget`, default 2 s / 3 s) with `unvollstaendig` and the continuation; `client.is_write` treats ores/geo/zugaenge/kohle (except status)/erzdig as never-free (also with --dry). zugaenge/kohle run/erzdig/perimeter scan are not chunked (marked heavy, COMPANION.md). Info needed (player): `Measure-Command` of `claude/ores` and `claude/geo` once.
