# BUG-210: live `hygiene`: no item is classified as `fort` (12.9k loose items = `cavern`), so marking finds 0 candidates, the dump diagnosis is wrong, and "125 dwarf corpses > 14 coffins: ghost risk" contradicts `claude/gesund krypta` (0 open corpses)

- **Status:** fixed, live check pending (see TESTPLAN-live)
- **Severity:** S2 (wrong area split drives `hygiene mark` and the cause text; the `!!` ghost-risk line is probably a false alarm)
- **Area:** `lua/pilot_hygiene.lua` `fort_ref()` / `reachable()` / `area_of()` (reference tile = `claude/config` `FORT_REFS[1]` = (94,96,133)), `is_dwarf_corpse()` (`hist_figure_id >= 0`, fail-safe `not ok`); `df_llm_helper/features/hygiene.py` (`diagnose`, `status`)
- **Reported:** 2026-10-02, commit `6dedd96`
- **Environment:** Windows 11 Pro, Python 3.14.3, game running (DF 53.16 + DFHack, paused), fort date 27. Granite, Jahr 118; ran with an isolated state file, game reads only (`status` blocks took 0.24 s + 0.15 s, 32,814 items: no runtime problem)

## Command / steps
```
cd "<project folder>"
python -m df_llm_helper --config <temp cfg> hygiene --dry-run
python -m df_llm_helper --config <temp cfg> hygiene mark                  # dry run
python -m df_llm_helper record "claude/gesund krypta" "claude/muell status"
python -m df_llm_helper record "claude/pilot_reach check 94 96 133 100,101,130 99,94,132 98,99,133 102,100,133" "claude/pilot_reach check 100 101 130 94,96,133 102,100,133"
```

## Expected
Items in the dug fort (boulders at z105..z130 in the mine, rooms) are `fort`; the doc example shows `areas: fort=10200 surface=1700 cavern=649`. `hygiene mark` has candidates for corpses lying in the fort. The ghost-risk line only appears when dwarf corpses really lie around (`claude/gesund krypta` -> `leichen_offen`).

## Actual
```
loose stacks 14k: boulders 11.8k (ok), corpses 1.2k (dump 0 jobs), goblets 391 (cap)
areas: cavern=12891 hidden=1693 surface=1139; corpses dwarf=125 other=1105; rotten=0
Dump: cause 'zone too far' -> propose zone D z130 x86..88,y112..114 (nearest zone 55 tiles from the marked items)
!! Dwarf corpses 125 > free coffins 14: ghost risk - build coffins/tombs
[dry] would mark 0 items (cap 298): claude/pilot_hygiene mark 298 CORPSE,CORPSEPIECE,REMAINS --rotten --dry
```
Raw: `pilot_hygiene status` has no `fort` key at all, `other_fort: 0`, `ref: [94,96,133]`. `claude/pilot_reach check 94 96 133 <any fort point>` returns `false` for every point (also for 99,94,132 / 98,99,133 / 80,100,121), while from the core (100,101,130) `102,100,133` is reachable: the reference tile (94,96,133) lies outside the closed gatehouse ("Torhaus Q", walls/doors at (96..104,92..102,z133)), so `canWalkBetween` is false for all underground items. `claude/gesund krypta` says `"leichen_offen": 0, "saerge_frei": 14, "geister": 0` while hygiene counts 125 loose dwarf corpses (`is_dwarf_corpse` is also true for every corpse with a `hist_figure_id`, e.g. named goblin/elf invaders, and for any read error). Totals also differ from `claude/muell status` (THREAD 920 missing in hygiene, CORPSE 444 vs 958): different "loose" definitions are not explained.

## Evidence
`Bugs/evidence/BUG-210/` (`l_hy1.jsonl` raw `pilot_hygiene status/report` answers, `l_krypta.jsonl`, `l_refwalk.jsonl` (reachability probes), `l_ref2.jsonl` (`claude/muell status`), outputs).

## Analysis (reporter's hypothesis)
`FORT_REFS[1]` in the live `lua/claude/config.lua` is a *surface* point at the camp, valid before the gatehouse was closed. Hygiene uses only the first entry. A reference point inside the fort (e.g. the `reach.start` core (100,101,130)) fixes the split. The ghost-risk comparison should use only *fort* corpses of dwarf race without `hist_figure_id` shortcut, or `claude/gesund krypta.leichen_offen`.

## Suggested fix (optional)
Use any of `FORT_REFS` (reachable-from-any), or read the core from `reach.start`; report "area classification failed: reference tile cannot reach any fort tile" when `fort == 0` and `loose > 1000`. Show the ghost-risk line only if `leichen_offen > 0`.

## Info needed
Gordon: (1) are there really ~125 dwarf corpses/pieces lying loose in the fort? (`gesund krypta` says 0). (2) Should `FORT_REFS[1]` in `dwarf-fortress/lua/claude/config.lua` be changed to a tile inside the fort? I did not touch the live tool.

## Fix
`pilot_hygiene.lua`: reachability from every `FORT_REFS` entry plus up to 5 citizens standing on inside tiles; the corpse COUNT uses the fort race only (named invaders = `other`; the fail-safe mark filter is unchanged). `hygiene`: `!! area classification failed ...` when 0 of > 1000 loose items are in the fort (the dump diagnosis is then skipped); the ghost alarm uses `claude/gesund krypta.leichen_offen` when present. Test: `test_bug210_*` (replay `fixtures/bugs/BUG-210/hygiene_live.jsonl`, Lua mock). Still worth a live look (Gordon): `FORT_REFS[1]` in `lua/claude/config.lua` is a surface point.
