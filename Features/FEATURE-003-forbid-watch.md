# FEATURE-003: `forbid-watch` - count forbidden own containers/food/drinks/building material and find the cause

- **Status:** proposed
- **Priority:** P1 (mass-forbidden barrels contributed to > 10 deaths by dehydration; nothing warned)
- **Requested by:** Gordon (player), 2026-10-02, via the local orchestrator
- **Area:** new `df_llm_helper forbid-watch` (+ Lua `lua/pilot_forbid.lua`), `digest`/`wake` integration, extension of `hygiene` (see BUG-125)

## Problem
Own barrels, drinks, food and building blocks were set to `forbid` in large numbers (1043 items). The dwarves cancelled jobs with `cancels Drink: Forbidden area` (game log), while `digest` still showed `Getraenke 475` and `hygiene` stayed silent. Nobody saw it until citizens were dying of thirst (see BUG-423, memory note `feedback_df_verbotene_fassen_verdursten.md`).

## Proposed behaviour
`python -m df_llm_helper forbid-watch [--json]` (read-only):
1. One Lua call (`pilot_forbid status`, JSON): count own (fort-owned, not foreign/trader) items with `flags.forbid` by class: container (barrel/bin/bag), drink, food/meal, building material (blocks, wood, bars), other; also the number of *claimed/dump* flags for comparison.
2. Cause hint per item group: whether the forbid came from `claude/*` scripts (name in the script's own log, e.g. `gefahr`, `sperre`, door/forbid repeat jobs), from an item `dump`/`forbid` order, from a burrow/stockpile setting, or unknown.
3. **Correlation with the game log:** count `cancels Drink: Forbidden area` / `cancels ...: Forbidden area` lines within the last N minutes (reuse `journal`/`gamelog` reader; N from config `forbid_watch.log_minutes`, default to be chosen by the cloud session). Output: `FORBID: 1043 own items forbidden (drinks 475 = 100 %), 37 Forbidden-area cancels in 10 min -> drinking blocked`.
4. `digest`: line `Forbidden own items: N (drinks D/T, food F/T)` as `warn` when drinks forbidden > 20 % or Forbidden-area cancels > threshold; wake line once per state change.
5. Optional `--fix` (only with an exception-register entry because it changes items): `claude/...` clears `forbid` on own drink/food/containers; lists what was changed (ids) in a log.

## Data needed from the game
`item.flags.forbid`, `item.flags.foreign`, item type/subtype, container relation (`dfhack.items.getContainer`), `dfhack.items.getGeneralRef` for owner; game log lines (already read by `journal`/`defense`).

## Safety / fair play
Reading is free. `--fix` only toggles the player-visible `forbid` flag of own items (same as the in-game forbid key), logged, exception register required; never touch foreign/trader goods (lint rule L13).

## Acceptance criteria (fixture based)
1. Fixture "all barrels forbidden": `forbid-watch` prints drinks `100 %` forbidden and a warning; `digest` shows both counts (see BUG-125).
2. Fixture log with 37 `cancels Drink: Forbidden area` lines in 10 min plus forbidden drinks: output contains the correlation line; without forbidden items the log lines are reported as `Forbidden-area cancels without forbidden items (burrow/zone?)`.
3. Fixture "no forbidden": `Forbidden own items: 0`, exit 0, no wake line.

## Info needed
Player: one recorded `forbid-watch`-style Lua answer from the live game (a quick `dfhack-run lua` count of `item.flags.forbid` by type is enough) and 20 sample game log lines with `Forbidden area`.
