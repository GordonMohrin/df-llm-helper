# BUG-414: `claude/pilot_water scan` has no limit on the box size (freeze risk), also `near` radius

- **Status:** verified fixed (retest 2026-10-02, 8e67f05) [static code review; lua5.4 not available, mock not run]
- **Severity:** S3 (S2 if a caller can pass a whole-map box)
- **Area:** `lua/pilot_water.lua:30-61` (`scan`), `:63-73` (`near`)
- **Reported:** 2026-10-02, commit `6dedd96`
- **Environment:** Windows 11 Pro, game running (DF 53.16 + DFHack, **paused**), fort "Windrings"

## Command / steps
Run (small boxes only): 
```
cd "E:/Program Files (x86)/Steam/steamapps/common/Dwarf Fortress/hack"
./dfhack-run.exe claude/pilot_water scan 90 90 128 130 130 130      # 41x41x3 = 5043 tiles, 0.07 s, hidden: 2767
./dfhack-run.exe claude/pilot_water scan 90 90 130 80 80 130        # reversed box -> silently 0 tiles, "hidden": 0
./dfhack-run.exe claude/pilot_water scan -5 -5 -5 5 5 5             # negative coordinates are skipped (216 hidden)
./dfhack-run.exe claude/pilot_water near 100 96 130 2               # 0.07 s, 7.9 KB
```
NOT run: `scan 0 0 0 191 191 152` (5.6 million `getTileFlags` calls, estimated seconds to tens of seconds in the main thread; the sibling scripts cap at 20000 tiles (`pilot_digcheck`) / 200000 (`pilot_reach`, measured 0.3 s for 180k tiles) and `pilot_hygiene status` caps at 50000 items per call).

## Expected
A cap (`box too large`) like in digcheck/reach; a reversed box is normalised or rejected; `near` radius capped (r=1000 would iterate 3 x 2001 x 2001 tiles).

## Actual
No cap. Reversed boxes (`x1 > x2`) silently count nothing. `by_z` is `[]` instead of `{}` when no water is found (type instability, see BUG-400).

## Evidence
none needed (outputs trivial: `{ "by_z": [], "hidden": 2767, "magma": 0, "ok": true, "units": 0, "water": 0 }`; `Bugs/RESULTS-lua.md`).

## Suggested fix (optional)
Same normalisation and cap as `pilot_reach.lua:118-126` (e.g. 200000), cap `r` at 10.

## Info needed
- Player: what box sizes does `df_llm_helper/water.py` actually send? (`grep -n "pilot_water" df_llm_helper/water.py`)

## Fix
`scan` normalises reversed boxes, clamps to the map, max 200000 tiles; `near` radius 0..10. (`water.py` sends `near ... 2` and config boxes.)
