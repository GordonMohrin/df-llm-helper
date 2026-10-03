# BUG-125: `digest` shows "Getraenke 475" although all barrels were forbidden; `hygiene` does not report mass-forbidden own containers/drinks/blocks

- **Status:** fixed in 14dbe1b
- **Severity:** S2 (misleading output: the supply looked fine while nobody could drink; leads to deaths, see BUG-423)
- **Area:** `df_llm_helper/digest.py` (food/drink items), `lua/pilot_hygiene.lua` (`hygiene`)
- **Reported:** 2026-10-02, commit `22b9b03`
- **Environment:** Windows 11, game running (DF 53.16 + DFHack), siege, 1043 forbidden items

## Command / steps
```
cd <project folder>
python -m df_llm_helper digest
python -m df_llm_helper hygiene
```
Game state: own barrels with drink and own blocks were set `forbid` (1043 items); the dwarves' jobs failed with `cancels Drink: Forbidden area` in the game log.

## Expected
- `digest` counts only *available* drink/food (not forbidden, reachable) or prints both numbers: `Getraenke 475 (verfuegbar 0, gesperrt 475)`.
- `hygiene` reports `forbidden own items: 1043 (containers N, drinks N, food N, blocks N)` as a warning.

## Actual
`digest`: `Getraenke 475` (all barrels counted, forbidden ones included). `hygiene`: no hint about forbidden items (its areas/trash checks only). Citizens died of dehydration (see BUG-423 and memory note `feedback_df_verbotene_fassen_verdursten.md`).

## Evidence
none recorded; numbers (475, 1043) from the orchestrator's live check. A recorded `pilot_hygiene`/`digest` answer with forbidden barrels is needed for a fixture.

## Analysis (reporter's hypothesis)
The item counters only sum stack/quantity and ignore `item.flags.forbid`. Hygiene has no forbid dimension.

## Suggested fix
Count `flags.forbid` separately in the digest drink/food/meal numbers; implement the new command from FEATURE-003 (`forbid-watch`) and show its one-line summary in the digest.

## Acceptance (fixture based)
Fixture with 10 barrels, all `forbid=true`: `digest` prints `drinks 0 available (10 barrels forbidden)` and a `warn` item; with `forbid=false`: normal number, no warning.

## Info needed
Player: one `digest` JSON with the forbidden state (before un-forbidding) if still available; otherwise the next occurrence.

## Fix
Cause: every drink/food counter (`claude/status`, `claude/report`, `ueberwacher`, `trinken`, `essen`, `watchdog`,
`auslastung`) checked only `item.flags.forbid` of the drink itself. A drink in a forbidden barrel is not flagged, so
all 475 drinks counted as supply while the dwarves cancelled `Drink: Forbidden area`.

- `lua/claude/util.lua`: new `forbidden(item)` = own forbid flag OR a forbidden container around it (up to 5 levels:
  drink -> barrel -> wagon ...).
- `claude/status`: `stock.drink`/`stock.food` (and so `drink_days`/`food_days`) count available items only; new
  `stock.drink_forbidden`/`stock.food_forbidden`; alert `Drinks forbidden: N (not drinkable)`.
- `claude/report`: `getraenke`/`mahlzeiten` available only; new `getraenke_gesperrt`/`mahlzeiten_gesperrt`.
- `ueberwacher` (notfall.flag), `trinken` (brew decision), `essen`, `watchdog`, `auslastung`: same rule, so a
  forbidden stock now triggers brewing/emergency flags instead of hiding the shortage.
- `digest`: status line `Drinks 0d (+475 forbidden) Food ...`; alert `Drinks 0 available (+475 forbidden, 100%) ...`
  as `crit` from `thresholds.forbidden_supply_crit_pct` (default 50 %), `warn` below; same for food.
- `hygiene`: new read-only `claude/pilot_hygiene forbid` (own forbidden items by class container/drink/food/material/
  other, plus drinks/food blocked by forbidden containers; trader/foreign/hostile items excluded). `hygiene status`
  always prints the line; `check` warns `Hygiene: !! forbidden own items: 1043 (containers ..., material ...); drinks
  blocked 475/475 (100 %...)` on its own 5-min interval (`hygiene.forbid_every_s`), repeated only on change or after
  30 min. Forbidden siege loot alone ("other") is reported but never warned.
- Tests: `tests/test_digest.py` (`test_bug125_*`), `tests/test_hygiene.py` (`test_bug125_*`, Lua mock with 10
  forbidden barrels), `tests/test_lua_claude.py` (`test_bug125_*`: `claude/status` under the mock, nested containers).

Live check after `install-lua --apply`: forbid one full drink barrel in the game; `dfhack-run claude/status` must show
`drink_forbidden` = its drinks; `python -m df_llm_helper digest` shows `(+N forbidden)`; `python -m df_llm_helper
hygiene` shows the `forbidden own items` line. Unforbid it again.

