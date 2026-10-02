# BUG-205: `water check x y z` answers `ok: no water nearby` (exit 0) for coordinates outside the map

- **Status:** fixed in f15d3b5
- **Severity:** S2 (a "green" answer of the pre-dig safety check for a tile that does not exist; typos in x/y/z, or a swapped order such as z x y, pass silently)
- **Area:** `df_llm_helper/water.py` `check_near` (empty `tiles` list -> `ok`), `lua/pilot_water.lua` (`near`, answers `ok:true, tiles:[]` for tiles without a map block); related to BUG-409 (box handling in the Lua scripts)
- **Reported:** 2026-10-02, commit `6dedd96`
- **Environment:** Windows 11 Pro, Python 3.14.3, game running (DF 53.16 + DFHack, paused), map 192x192x153, fort date 27. Granite, Jahr 118

## Command / steps
```
cd "<project folder>"
python -m df_llm_helper water check 9999 9999 9999
python -m df_llm_helper water check -5 -5 -5
python -m df_llm_helper water check 100 100 130          # (inside, for comparison)
```

## Expected
`error: (9999,9999,z9999) is outside the map (192x192x153)`, exit != 0 (like `unsafe`: exit 1). The spec says unknown/unreadable neighbourhoods are `unsafe`, never `ok`.

## Actual
```
$ python -m df_llm_helper water check 9999 9999 9999
ok: no water nearby              (rc 0)
$ python -m df_llm_helper water check -5 -5 -5
ok: no water nearby              (rc 0)
$ python -m df_llm_helper water check 100 100 130
unsafe: hidden neighbor tile (-1,-1,-1); hidden neighbor tile (0,-1,-1); hidden neighbor tile (1,-1,-1)   (rc 1)
```
Raw game answer for the first call (`claude/pilot_water near 9999 9999 9999 2`): `{"ok": true, "r": 2, "tiles": [], "x": 9999, "y": 9999, "z": 9999}` - no `self` entry, no tiles.

## Evidence
`Bugs/evidence/BUG-205/` (recorded raw answers `l_wc_e1.jsonl`, `l_wc_e2.jsonl`, outputs).

## Analysis (reporter's hypothesis)
`pilot_water near` silently skips map positions without a block (`getTileBlock` nil) and returns an empty tile list; `check_near` only looks at what is present, so "nothing found" = `ok`. A tile without a `self` record should be treated as "not readable".

## Suggested fix (optional)
In `check_near`: `if not j.get("self")` (or `tiles` empty) -> `Verdict("unsafe", ["tile outside the map / not readable"])`; additionally validate x/y/z against `claude/status.map_size` in `cmd_water`.

## Info needed
None.

## Fix
`check_near` answers `unsafe: tile ... outside the map or not readable` when the Lua answer has no record of the tile itself; `WaterWatch.check` validates x/y/z against `claude/status.map_size` (and negative values) before the Lua call; an unrevealed tile itself is `unsafe`. Test: `test_bug205_*` (recorded answers `fixtures/bugs/BUG-205/`).
