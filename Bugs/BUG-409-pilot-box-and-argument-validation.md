# BUG-409: pilot_digcheck / pilot_reach box handling (out-of-map box, fractional numbers), pilot_reach `check` drops malformed points, pilot_siege unknown command

- **Status:** open
- **Severity:** S3
- **Area:** `lua/pilot_digcheck.lua:67-75`, `lua/pilot_reach.lua:118-126,128-142`, `lua/pilot_siege.lua:~96`
- **Reported:** 2026-10-02, commit `6dedd96`
- **Environment:** Windows 11 Pro, game running (DF 53.16 + DFHack, **paused**, fort "Windrings", date `27. Granite, Jahr 118`)

## Command / steps
```
cd "E:/Program Files (x86)/Steam/steamapps/common/Dwarf Fortress/hack"
./dfhack-run.exe claude/pilot_digcheck dump 500 500 130 600 600 130
./dfhack-run.exe claude/pilot_digcheck dump 500 0 130 600 5 130
./dfhack-run.exe claude/pilot_digcheck dump 1.5 2.5 130 5 5 130
./dfhack-run.exe claude/pilot_reach dump 500 500 130 600 600 130
./dfhack-run.exe claude/pilot_reach check 100 96 130 101,96,130 102,97,130+ 9999,9999,9999 foo -1,-1,-1
./dfhack-run.exe claude/pilot_siege foo
```

## Expected
Errors (`ok:false`) for boxes outside the map, integer-only coordinates, and `results` aligned 1:1 with the arguments (the header says "same order as the arguments").

## Actual
1. Box completely outside the map: after clamping `x1=500 > x2=191`; `cells = (191-500+1)*(191-500+1)*1 = 94864` (product of two negative numbers) -> misleading error `"box too large: 94864 tiles (max 20000)"` (digcheck) or `ok:true` with `"levels": {"130": []}` (reach; cap 200000 not hit).
2. Box half outside the map (`x 500..600, y 0..5`): negative `cells` passes the cap, answer is `ok:true` with six empty rows `"130": ["","","","","",""]` and an inverted `box` `[500,0,130,191,5,130]`.
3. Fractional coordinates: traceback (exit 1) `bad argument #2 to 'getTileFlags' (number has no integer representation)` at `pilot_digcheck.lua:37` (same in pilot_reach/pilot_water/pilot_perimeter, which all use `tonumber()` without integer check).
4. `pilot_reach check ... foo ...`: the argument `foo` (and any non-matching text) is silently skipped; with 5 points the answer has `"results": [true,true,false,false]` (4 entries), so the caller's index mapping is wrong. A start point outside the map just yields `false` for everything (no error).
5. `claude/pilot_siege foo` -> `{"error": "Squad nil unknown", "ok": false}` instead of the usage text (squad lookup runs before the command dispatch).
Everything else was fine: caps work (`dump 0 0 0 191 191 152` -> `box too large: 5640192 tiles (max 20000)`), `-10 -10 -1 3 3 1` is clamped to `[0,0,0,3,3,1]`, normal boxes: 20000 tiles in 0.1 s, 180k tiles (`pilot_reach dump 0 0 125 189 189 129`) in 0.3 s / 184 KB.

## Evidence
`Bugs/evidence/BUG-409/digcheck_out_of_map_box`, `digcheck_half_outside`, `digcheck_fractional`, `reach_dump_out_of_map`, `reach_check_malformed_arg`, `siege_unknown_cmd` (each `*.cmd.txt` + `*.out.txt`).

## Analysis (reporter's hypothesis)
Clamp-then-count without checking `x1 <= x2`; `tonumber()` accepts floats; `check` loop uses `a[i]:match(...)` and `if x then` without recording a `null`.

## Suggested fix (optional)
After clamping: `if x1 > x2 or y1 > y2 or z1 > z2 then error 'box outside the map' end`; `math.floor` or reject non-integers; in `check` push `false, false` (or `null`) for unparsable arguments; move the `squad_of` line in pilot_siege below the `else` usage branch.

## Info needed
- Cloud session: does `df_llm_helper/features/reach.py` rely on `len(results) == len(points)`? (then item 4 is S2).
