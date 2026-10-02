# BUG-209: live `reach` reports the mandatory point "Kitchens (106,85,z132)" as UNREACHABLE: the point lies on a constructed wall; the advice "remove the construction" is dangerous

- **Status:** fixed in e47790f
- **Severity:** S2 (permanent false CRIT every `check` interval - `reach:unreachable` wakes the orchestrator - and a harmful repair suggestion)
- **Area:** `data/reach.yaml` (shipped EXAMPLE values from run 5), `df_llm_helper/features/reach.py` (cause search `cut by construction ...`)
- **Reported:** 2026-10-02, commit `6dedd96`
- **Environment:** Windows 11 Pro, Python 3.14.3, game running (DF 53.16 + DFHack, paused), fort date 27. Granite, Jahr 118. Run with an isolated state file (`--config <temp>`), live game reads only.

## Command / steps
```
cd "<project folder>"
python -m df_llm_helper reach
python -m df_llm_helper reach what-if --wall 106 85 132
```
Cross-checks (read only): `claude/area 132 94 79 19 14` and the `claude/pilot_reach dump 94 79 129 112 107 133` that `reach` itself calls.

## Expected
All 7 mandatory points reachable (the docs report 9/9 on 02.10.2026 after the well fix) or, if a point really is cut off, a cause that is true.

## Actual
```
UNREACHABLE: Kitchens (cut at (106,85,z132))
Kitchens (106,85,z132): cut by construction (106,85,z132) -> remove it (designate 'remove construction') or replace it with a door
```
Raw: `claude/pilot_reach check 100 101 130 ...` -> `"results": [true, true, false, true, true, true, true, true, true]` (3rd = Kitchens). `claude/area 132 ...` row y=85, x=94..112 is `^^......+CCCCCCCCCC` and the pilot_reach dump row is `//,,,,,,,CCCCCCCCCC`: x=103..112 are constructed wall `C`, so (106,85,z132) is part of a long constructed wall, not a workshop. The real kitchen (id 1367, `claude/buildings`) is at x105..107, y97..99, z132 (the Still at x102..104 y97..99), i.e. the watch points "Kitchens"/"Stills" in `data/reach.yaml` are guessed coordinates.

## Evidence
`Bugs/evidence/BUG-209/` (`l_r1.jsonl` raw check + dump answers, `l_area2.jsonl` area dumps, `l_bld.jsonl` buildings, outputs).

## Analysis (reporter's hypothesis)
Data problem plus a weak diagnosis: when the *target tile itself* is a constructed wall, the cheapest-path search names that tile as "the cutting construction", and the suggested action (remove it) would open the farm-terrace wall. The tool should detect "point lies inside a wall/construction" and say "check the coordinates in data/reach.yaml".

## Suggested fix (optional)
1. Cause search: if the point tile is `C`/`#` in the dump -> `watch point ... is on a wall tile: fix data/reach.yaml (kitchen is at x105..107,y97..99,z132)`; never advise removing the construction without the player.
2. Update the shipped example points from `claude/buildings` (use building centres; the Lua already tests the footprint+1 for blocking buildings).

## Info needed
Gordon: please confirm the coordinates of the kitchen and the stills (the buildings list above is truncated to 150 entries: `truncated: true`) and whether the wall at (103..112,85,z132) is the intended farm-terrace boundary. A live check after correcting `data/reach.yaml`: `python -m df_llm_helper reach` should print `Reachable: 7/7 mandatory points`.

## Fix
A mandatory point whose own tile is a wall (`#`, `A`, `C`) is reported as `point on a wall tile: fix the points file` with level `warn` (no CRIT) and never with the advice to remove the construction; the removal advice for real cutting constructions is marked `(player decision)`. `data/reach.yaml`: Kitchens (106,98,z132) and Stills (103,98,z132) from `claude/buildings` (kitchen 1367, still 1366). Test: `test_bug209_*` (replay `fixtures/bugs/BUG-209/l_r1.jsonl`). Live check: `python -m df_llm_helper reach` should print `Reachable: 7/7 mandatory points`.
