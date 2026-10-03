# FEATURE-003: `forbid-watch` - count forbidden own containers/food/drinks/building material and find the cause

- **Status:** implemented in 7067417
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

## Implementation
Commit 7067417. Built on the BUG-125 fix (`util.forbidden()`, `claude/pilot_hygiene forbid`, digest `Drinks Nd (+M
forbidden)`).

- `lua/pilot_forbid.lua` (new): `status` (read only) - own forbidden items by class (container/drink/food/material/other),
  drinks/food blocked by a forbidden container, `flags.in_job`/`flags.dump` for comparison, a cause per item (`dump_zone`,
  `own_dead`, `other_dead`, `used_ammo`, `foreign_made`, `area` = >= 20 forbidden items in one 16x16 map block, `unknown`),
  the 5 densest blocks with stockpile/dump-zone id, standing orders `forbid_*`, forbidden items on hidden tiles (count
  only). `fix <classes> [--max N] [--apply]` clears `flags.forbid` of own items (drink/food/container/material; `other` =
  siege loot refused; foreign/trader/hostile, hidden tiles and dump-zone items never), ids to `tools/out/forbid-fix.log`.
- `df_llm_helper/features/forbid_watch.py` (new): `python -m df_llm_helper forbid-watch [status] [--json] [--dry-run]`,
  `forbid-watch fix [--classes ...] [--max N] [--apply]` (`--fix` alias). Game-log correlation with an own read offset
  (`forbid_watch.log_minutes`, default **10**; the first read counts only the last 300 lines), script-log hints from
  `paths.tools` (`out/*.log`, `events.log`). Fallback to `claude/pilot_hygiene forbid` (counts only).
- `check`: every 5 min; `Forbidden own items: N (drinks D/T, food F/T)` + the `FORBID:` line when drinks/food blocked >
  20 % or Forbidden-area cancels > 10 (`cancel_warn`); a crit warning (one wake line, one digest line
  `[forbid-watch] ...`) only on a change into a warning state; `resolved` when it clears. Hygiene's BUG-125 warning
  stays quiet while forbid-watch reports.
- Decision: the fix needs **no exception-register entry** (unforbidding own items is a normal UI action); it is a dry run
  unless `--apply` is given, never automatic, at most 3 applied runs per hour.
- Tests: `tests/test_forbid_watch.py` (acceptance 1-3 with `fixtures/v3/forbid/`, Lua mock tests of `pilot_forbid`
  status/fix, wake once per change, digest line, fix dry/apply/refusal, fallback).

Not done: DF stores no author per forbid flag, so "who forbade it" is a derived hint (position, race, maker, density,
standing orders, script logs), not a record.

### Live check (after `python -m df_llm_helper install-lua --apply`)
1. `dfhack-run claude/pilot_forbid status` -> JSON with `ok: true`; note the numbers.
2. In the game forbid one full drink barrel and one stack of blocks (item menu). `python -m df_llm_helper forbid-watch`:
   `Forbidden own items` +2, drinks blocked = the barrel's drinks, `classes` container +1 / material +1, a cause line.
3. `python -m df_llm_helper forbid-watch fix` (dry run) lists the barrel id and changes nothing; `forbid-watch fix
   --apply` unforbids it; `tools/out/forbid-fix.log` has the id; the blocks stay forbidden unless `--classes material`.
4. With `paths.gamelog` set: wait for a `cancels Drink: Forbidden area` line (or check a recorded log) and see it in the
   `cancels:` line.
5. Run `python -m df_llm_helper check` twice with the barrel forbidden: one wake line (`python -m df_llm_helper wake`),
   no repeat on the second check.
6. Please record one `claude/pilot_forbid status` answer and 20 game-log lines with `Forbidden area` into `fixtures/`
   (the current fixtures are synthetic).

