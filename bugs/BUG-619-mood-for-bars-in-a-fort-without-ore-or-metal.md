# BUG-619 A strange mood for bars in a fort with no ore, no marked metal and no smelter is told at 15 days or with the thirst
Status: fixed (offline, live-untested)
Severity: high (the dwarf dies)
Found: 2026-11-09, Run 16c i3 Wallfree y378 (Possessed 26275 `bars x3: none in the fort`, MOOD_CRITICAL from 41 d left, died at 0; `MOOD_RISK` with `IMPOSSIBLE bars: no ore and no metal marked for melting, and no smelter` only with thirst 30,163)
Module: `lua/dfllm/care.lua` (`early_kind`, `mood_report`, `mood_early`)

## Actual
Round 37 (BUG-575) told rough gems, hard stone and silk at the first report (`DECISION_NEEDED mood_deadline early 1`). A bars slot went the late way: MOOD_CRITICAL lines `caravans asked: bar:inorganic` from 41 days out, `mood_deadline` at 15 days (`mood_decide`), the IMPOSSIBLE text with the thirst. In a fort without ore, metal items marked for melting or a smelter no caravan came; nothing could be done and nobody was told early.

## Root cause
`early_kind` knew `gems` (ROUGH), `boulders` (non-economic) and silk only. `economy.mood_hint('bars')` (BUG-520) has the answer (no ore, no marked metal; `impossible` without a smelter and without stone for one) but only `mood_deadline` and the MOOD_RISK note asked it.

## Fix
`care.early_kind(a, inv, bh)`: a `bars` slot that is short while `economy.mood_hint('bars')` has a text is an early slot ('bars'); `mood_report` reads the hint once per mood; `mood_early` names it: impossible -> `IMPOSSIBLE here: <hint> (only a caravan can bring bars)` and no explore dig among the commands; possible (a smelter stands, or stone for one) -> `bars: no ore and no metal marked for melting: trade.want bar:iron, an explore dig for ore, or mark metal items (weapons, tools, armour) for melting`, with the explore dig among the commands. The trade.want line comes from `mood_cmds` (the mood's tokens). One decision per set of kinds and mood, as for gems.
- Not done: no verb marks metal items for melting (`act.item_flag melt` exists, the kernel never melts a fort's own gear on its own); the decision names the way.

- Limits: this is early warning, not a rescue (nothing melts or smelts by itself; Wallfree could not have been saved without a caravan). `mood_hint('bars')` ignores the bar material the mood wants: a fort with copper only and an iron mood is told 'can make bars' (no early decision).

## Tests
`tests/lua/test_bug573_575_mood_materials.lua` (impossible: q says IMPOSSIBLE and only a caravan, no explore dig; possible: ways and explore dig; ore in the fort: no early decision).

## Live check
Possessed / Secretive mood for bars in a fort with no ore: a `DECISION_NEEDED mood_deadline` with `early 1` and the `IMPOSSIBLE here` or `bars:` text at the mood's first report.
