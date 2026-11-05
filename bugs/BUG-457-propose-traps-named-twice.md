# BUG-457 plan propose crashes with "traps.at: tile ... named twice" (every year); military.pct the draft's own check refuses
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-05, Run 16b i2 Roadvises (E:/DF-test2, y376-y385, ten years in a row)
Module: `dfpilot/bp/traps.py`, `dfpilot/traps.py`, `dfpilot/plan.py`

## Actual
`plan propose` died with `ValueError: traps.at: tile 60,100,121 named twice` (plan.py fit_placeable -> cmd._place -> traps.expand ->
bp/traps.py parse_at). No draft; the player copied last year's plan with `year` changed for ten years. `plan check` of such a copy: ERROR
`military.pct 15 < 20 (D-12 at pop 62)`.

## Cause
1. `bp.traps.ways_in` lists the outside neighbours of every door. Two doors side by side (or a door beside a corner) share neighbour
   tiles, so the same tile is in both lanes. `traps.expand` passed both to `format_at`, which wrote it under both ways, and the very next
   line, `parse_at(out)` (dfpilot/traps.py, the `n = ...` count), refuses a tile named twice. The same for the bridge lanes
   (`_expand_bridges`) and for a hall part that shares a tile with a lane.
2. `expand` called `parse_at` raw: the ValueError was not a BpError, so `fit_placeable` (catches BpError only) and `propose` died.
3. military.pct: propose drafts 20 only when the state at propose time shows pop >= 60; plan check demands it at pop >= 60 of the state at
   check time (D-12). A draft made at 55 citizens met the check at 62.

## Fix
- `bp.traps.dedupe(parts)`: a tile stays with the first part that names it, a part left empty is dropped; `format_at` applies it, and `expand`
  applies it before counting the ways that wait (note `BUG-457: N lane tile(s) shared by two ways kept with the first`). `expand` reads back
  with `_call_bp`, so a remaining ValueError is a BpError (the CLI reports it, no traceback).
- `plan.fit_placeable`: any other exception of a template's placement drops that template from the draft with the line
  `BUG-457: ERROR <tpl>@<site> left out: <Type>: <message>` (and in `notes`); the other builds stay.
- `plan.propose`: military.pct 20 from `MIL_MARGIN_POP` (50) citizens (check unchanged: 20 from 60 under D-12 15/20).

## Tests
`tests/test_bug457_traps_dupe_propose.py` (10): ways_in on two neighbouring doors shares tiles; `cmd.place traps at=ways` and
`plan.fit_placeable` on that snapshot (the real path); dedupe/format_at; a template failure drops only that build with an ERROR line;
propose pct at pop 30..62 passes `plan.check`, also when the pop grew to 62 before the check.

## Live check
On Roadvises: `plan propose plan-y386.json` writes a draft (traps lane for both doors, each tile once, note BUG-457); its military.pct is 20
and `plan check` has no D-12 error. A broken template appears as an ERROR line in the propose output instead of a traceback.
