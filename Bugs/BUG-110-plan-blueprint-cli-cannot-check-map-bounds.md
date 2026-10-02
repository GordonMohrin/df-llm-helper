# BUG-110: `plan blueprint` has no way to check the map bounds: the repo's own "bad" file `bad_footprint_outside_map.csv` passes as `ok`

- **Status:** fixed in 626d04f
- **Severity:** S3
- **Area:** `df_llm_helper/cli.py:589-597` (`validate_blueprint(text)` without `map_size`/`origin`), `df_llm_helper/planners/blueprint.py:393-401` (E_BOUNDS only if `map_size` is given)
- **Reported:** 2026-10-02, commit `50cee52` (code identical to `6dedd96`)
- **Environment:** Windows 11 Pro, Python 3.14.3, no game needed

## Command / steps
```
cd "<project folder>"
python Bugs/evidence/BUG-110/repro.py
python -m df_llm_helper plan blueprint tests/blueprints_bad/bad_footprint_outside_map.csv
```

## Expected
`tests/blueprints_bad/EXPECTED.txt` lists `bad_footprint_outside_map.csv;E_BOUNDS` (`#build lange wand` / `Cw(200x1)` on a 192-wide map), so the CLI should report `E_BOUNDS`
(the map size is known from `claude/status` -> `map_size`, e.g. `192x192x153`; the origin from the quickfort cursor).

## Actual
```
$ python -m df_llm_helper plan blueprint tests/blueprints_bad/bad_footprint_outside_map.csv
...\bad_footprint_outside_map.csv: ok
[exit=0]
API with map_size: ['2:1 error E_BOUNDS footprint x0..199 y0..0 lies outside the map 192x192']
```
The check exists in the planner (and in `tests/test_planners.py`, which passes `map_size=MAP`), but the CLI offers no `--map-size`/`--origin` option and does not ask the game, so the 10th documented error class can never occur on the command line.
(PLANNERS.md says "The lower map boundary is checked only when `origin` is given".)

## Evidence
`Bugs/evidence/BUG-110/repro.py`, `output.txt`.

## Analysis (reporter's hypothesis)
CLI gap. Cheap fix: `--map-size 192x192` and `--origin x,y` options; better: when the game is reachable use `claude/status` `map_size`.

## Suggested fix (optional)
Add the options, mention them in `--help` (see BUG-120), and document in PLANNERS.md that without them E_BOUNDS is not checked.

## Info needed
None.

## Fix
`plan blueprint --map-size WxH [--origin x,y]` passes the map size/origin to the validator (E_BOUNDS); without it the output says `Note: map bounds (E_BOUNDS) not checked`. PLANNERS.md updated. Test: `test_bug110_*`.
