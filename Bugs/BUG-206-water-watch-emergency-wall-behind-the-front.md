# BUG-206: `water watch` proposes the emergency wall at a choke point that lies BEHIND the water front (default `fort_center: None` disables the "between front and fort" test)

- **Status:** fixed in f15d3b5
- **Severity:** S2 (wrong action advice during a flood: the runbook `rb21_flut` would wall off the dry side of the water)
- **Area:** `df_llm_helper/water.py` `notwand_for` (`center is None or ...`), `DEFAULTS["fort_center"] = None`, `WaterWatch.watch`
- **Reported:** 2026-10-02, commit `6dedd96`
- **Environment:** Windows 11 Pro, Python 3.14.3, replay of synthetic `pilot_water scan` answers (the live fort box has 0 water tiles, so the alarm path cannot be triggered live); game paused, fort date 27. Granite, Jahr 118

## Command / steps
```
cd "<project folder>"
python -m df_llm_helper --replay-file Bugs/evidence/BUG-206/water_0.jsonl water watch      # 0 tiles (baseline)
python -m df_llm_helper --replay-file Bugs/evidence/BUG-206/water_1.jsonl water watch      # 5 tiles, front (120,99,128)
python -m df_llm_helper --replay-file Bugs/evidence/BUG-206/water_2.jsonl water watch      # 12 tiles, front (118,99,128)
```
(each file answers `claude/pilot_water scan 60 40 126 127 130 133` with `{"ok":true,"water":N,"front":[x,99,128],...}`; the fort box ends at x=127, the configured choke point is (128,99,128), east of the fort box = on the water side.)

## Expected
MANUAL 9.8: "emergency-wall suggestion at the nearest planned chokepoint between front and fort". A front at x=120 is already inside the fort box (x<=127); the only configured choke point x=128 is further out, so no valid proposal exists. Expected output: `Emergency wall: no planned choke point between front and fort (water.chokepoints) - by hand` (the code has this branch).

## Actual
```
!! Water in the fort at (120,99,128): 5 tiles (before 0)
Emergency wall: runbook rb21_flut --param x=128 --param y=99 --param z=128 (Quickfort claude/r5_notwand.csv); dig ban around the front
```
and the same wall for the front at (118,99,128).

## Evidence
`Bugs/evidence/BUG-206/` (replay files, outputs `r_w1.out`, `r_w2.out`). Written flag: `wasser.flag` contains the same two lines.

## Analysis (reporter's hypothesis)
`notwand_for(front, chokepoints, center)` filters by `d(c, center) <= d(front, center)` only when `center` is given; `water.fort_center` defaults to `None`, and nothing derives it from `claude/config` (`fort` = (96,96,133)) or `claude/status.center`.

## Suggested fix (optional)
Default the centre to the fort point of `claude/config` (or the centre of `fort_box`), and add a test with a front inside the fort box and a choke point outside. Also consider ranking only choke points whose x/y lie inside `fort_box`.

## Info needed
Gordon: confirm that (128,99,z128) is the *existing* emergency wall (`LAYOUT-run5.md` 11, MANUAL 9.8). If yes, any water inside the fort box is already behind the wall and the right advice is "wall is breached/not tight: check (128,99,128)".

## Fix
The fort centre defaults to the centre of `water.fort_box` (`water.fort_center` still wins); a front inside the fort box gets no proposal for a choke point outside the box but `Emergency wall: the water is already inside the fort box, the planned choke points ... lie behind the front - wall breached/not tight? check them; wall off the front by hand`. Test: `test_bug206_*` (replays `fixtures/bugs/BUG-206/`). Gordon's confirmation that (128,99,z128) is the existing wall matches this wording.
