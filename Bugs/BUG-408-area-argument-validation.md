# BUG-408: `claude/area z x` (x without y) crashes with a traceback; zero/negative width/height print an empty degenerate grid

- **Status:** verified fixed (retest 2026-10-02, 8e67f05) [static code review; lua5.4 not available, mock not run]
- **Severity:** S3
- **Area:** `lua/claude/area.lua:14-31`
- **Reported:** 2026-10-02, commit `6dedd96`
- **Environment:** Windows 11 Pro, game running (DF 53.16 + DFHack, **paused**, fort "Windrings", date `27. Granite, Jahr 118`)

## Command / steps
```
cd "E:/Program Files (x86)/Steam/steamapps/common/Dwarf Fortress/hack"
./dfhack-run.exe claude/area 130 80            # only x0 given
./dfhack-run.exe claude/area 130 80 90 0 0     # zero size
./dfhack-run.exe claude/area 130 80 90 -5 -5   # negative size
```

## Expected
Usage text (`claude/area [z [x0 y0 [w h]]]`) or sensible clamping (w,h >= 1).

## Actual
1. `claude/area 130 80` -> exit code 1 and a Lua error instead of a usage message:
```
attempt to compare nil with number
stack traceback:
	[C]: in function 'math.min'
	...aude gordons projects/dwarf-fortress/lua/claude/area.lua:31: in local 'script_code'
	...team\steamapps\common\Dwarf Fortress\hack\lua\dfhack.lua:1117: in function 'dfhack.run_script_with_env'
	(...tail calls...)
```
(`x0` is given, so the "default centre" block `if not x0` is skipped, `y0` stays nil -> line 31.)
2. `claude/area 130 80 90 0 0` -> `z=130  x=80..79  y=90..89  (Karte 192x192x153)` followed by two blank axis rows and the legend; `-5 -5` -> `x=80..74  y=90..84`.
Everything else behaved correctly: z clamped (`9999` -> 152), x0/y0 clamped to the map (`500 500` -> `x=182..191`), w/h capped at 100, non-numeric z falls back to the dwarves' main level.

## Evidence
`Bugs/evidence/BUG-408/area_130_80.out.txt`, `area_zero_size.out.txt`, `area_negative_size.out.txt`.

## Analysis (reporter's hypothesis)
`area.lua:15-30`: `y0` is only defaulted together with `x0`; `w = math.min(tonumber(a[4]) or 60, 100)` has no lower bound.

## Suggested fix (optional)
`local x0, y0 = tonumber(a[2]), tonumber(a[3]); if x0 and not y0 then usage-error end` and `w, h = math.max(1, w), math.max(1, h)`.

## Info needed
none. (Output is plain text by design, not JSON - see BUG-410.)

## Fix
`x0` without `y0` prints the usage line; width/height clamped to >= 1; fractions floored.
