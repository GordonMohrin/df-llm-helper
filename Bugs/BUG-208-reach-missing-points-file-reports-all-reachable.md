# BUG-208: `reach --points <missing file>` prints `Reachable: 0/0 mandatory points` (exit 0); points outside the map / the core itself are accepted without comment

- **Status:** verified fixed (retest 2026-10-02, 8e67f05)
- **Severity:** S2 (a typo in the path = "all reachable" in a check whose job is to wake the orchestrator when farms are cut off)
- **Area:** `df_llm_helper/features/reach.py` (points loading, `--points` / `reach.points_file`)
- **Reported:** 2026-10-02, commit `6dedd96`
- **Environment:** Windows 11 Pro, Python 3.14.3, game running (DF 53.16 + DFHack, paused), fort date 27. Granite, Jahr 118

## Command / steps
```
cd "<project folder>"
python -m df_llm_helper reach --points "C:/does/not/exist.yaml"
python -m df_llm_helper reach --points "Bugs/evidence/BUG-208/pts test.yaml"     # file with: OutOfMap (999,999,999), Core (100,101,130), two well tiles
```
(Also tested: a syntactically broken file gives a clean one-line error, exit 2: good.)

## Expected
`reach: points file not found: C:/does/not/exist.yaml`, exit 2. In the second case a point outside the map should be reported as a configuration error ("point OutOfMap (999,999,z999) is outside the map") instead of "UNREACHABLE ... (cause unknown)".

## Actual
```
Reachable: 0/0 mandatory points            rc 0
UNREACHABLE: Aussen, OutOfMap (cause unknown)     rc 1
```
(`Aussen (150,150,z130)` is an unrevealed/outside tile: also just "unreachable (cause unknown)". Brunnen at (140,99,129) and its neighbour (139,99,129) are reported reachable, i.e. the building false-positive case from the brief is fine.)

## Evidence
`Bugs/evidence/BUG-208/` (outputs, the points file).

## Analysis (reporter's hypothesis)
A non-existent file is treated like an empty point list (probably `load_points` returns `[]`). Coordinates are not validated against the map size.

## Suggested fix (optional)
Raise on a missing file; warn on points with x/y/z outside `claude/status.map_size`; `cause unknown` should say what to check ("tile revealed? point on a constructed wall? see BUG-209").

## Info needed
None.

## Fix
`reach --points <missing>` -> `Error: reach: points file not found` (rc 2); no watch points -> rc 2 with a message; points outside `claude/status.map_size` are reported as `config error` (status not readable, no CRIT); `cause unknown` lines say what to check. Test: `test_bug208_*` (points file `fixtures/bugs/BUG-208/pts_test.yaml`).
