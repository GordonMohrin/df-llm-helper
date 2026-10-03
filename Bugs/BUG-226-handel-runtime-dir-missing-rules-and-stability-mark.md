# BUG-226: `claude/handel` without the runtime folder: no stability mark, no rules file, goods in bins never marked, one huge item sold

- **Status:** fixed in 4bda017
- **Severity:** S2 (the live trade stops in REVIEW/ABORT; the default rules buy nothing; most sale goods are invisible to `mark`)
- **Area:** `lua/claude/util.lua` (`home()`), `lua/claude/handel.lua` (`write_state`, `load_rules`, `sell_candidates`, `select`), trade rules file `tools/scopes/handel-regeln.md`
- **Reported:** 2026-10-03, commit `16dee07` (originally `Bugs/handel-runtime-dir-fehlt.md`, German)
- **Environment:** Windows 11, Python 3.14, game: running (DF 53.16 + DFHack), live trade on 2026-10-03; no `DF_LLM_HELPER_HOME` in the game's environment

## Command / steps
```
cd <project folder>
python -m df_llm_helper trade step      # repeated; internally claude/handel status|plan|mark --live|select --dry
```
1. Without the environment variable `DF_LLM_HELPER_HOME`, `claude/util.home()` returns `<DF>/df-llm-helper-runtime`. That folder did not exist.
2. Run the trade automaton up to OPEN/SELECT_DRY/REVIEW.

## Expected
- `home()` creates the runtime folder, or the scripts report clearly that it is missing.
- `handel status` writes the stability mark (`tools/out/handel-state.json`); `select` works after >= 2 s.
- A missing `tools/scopes/handel-regeln.md` is reported loudly instead of silently falling back to the default rules.
- `mark` finds the sale goods, including those stored in bins/barrels.
- The automatic sale pays with many small items instead of one huge item.
- The buy rules can buy any cloth.

## Actual
Findings of the live trade (no raw output was recorded):
1. `handel status` never wrote the stability mark: `write_state` swallows the error with `pcall`. Result: `select` always answered "keine Stabilitaetsmarke" (no stability mark); the trade automaton's REVIEW stayed empty or went to ABORT.
2. `handel-regeln.md` was not found -> default rules with an empty buy list: `select` answered "nichts Sinnvolles auszuwaehlen" (nothing sensible to select).
3. Second finding: `sell_candidates` skips every item with `flags.in_inventory`. Everything stored in chests/BINs has that flag (here 396 of 429 figurines), so `mark` found nothing. The bins must be marked with `markForTrade`.
4. Also: the automatic sale chose 1 item worth 26300 (the surplus is lost) instead of many small ones.
5. Third finding: the buy rules have no generic CLOTH entry (only silk); cloth was selected by hand.

Workaround used live: created the folder `df-llm-helper-runtime/tools/out` and `tools/scopes/handel-regeln.md` (a copy).

## Evidence
none recorded.

## Analysis (reporter's hypothesis)
- `util.home()` only builds the path; nothing creates the folder. `write_state` swallows the error with `pcall`.
- `load_rules()` only logs "Regeldatei fehlt" (rules file missing) to `tools/out/handel.log`, which cannot be written without the folder either.
- `sell_candidates` filters `not f.in_inventory`.
- `select`, step 4 (sale): the first loop takes the most valuable piece whenever nothing is chosen yet, however far it overshoots.

## Suggested fix (optional)
`home()` must create the folder or report the error; `write_state` must not fail silently; report a missing rules file loudly; mark goods in bins (by marking the container, or what `dfhack.items.markForTrade` supports); prefer many small items in the automatic sale; add a generic CLOTH buy entry.

## Fix
- `util.home()` creates `<home>/tools/out` and `<home>/tools/scopes` (`dfhack.filesystem.mkdir_recursive`, checked with
  `isdir`); when that fails, `util.home_error()` returns `runtime folder missing and not creatable: <path> (set
  DF_LLM_HELPER_HOME for the game or create the folder)`, printed once to the DFHack console. Success is cached per
  path, a failure is retried on the next call.
- `handel.lua`:
  - `write_state` returns `false, <reason>`; `status` adds `stability mark not written (<file>): <reason>` to a new
    `errors` list (also: the runtime-folder error and `rules file missing: <path>`). `trade step` prints these lines
    (`!! claude/handel: ...`), the caravan autopilot turns them into warnings. The "keine Stabilitaetsmarke" answer of
    `select`/`list`/`confirm` names the runtime error or the state file.
  - `load_rules` keeps the error in `R.rules_error` (log + console); `plan`, `mark`, `select` refuse with
    `rules file missing: <path> - template: data/trade/handel-regeln.md (install-lua --apply copies it)`.
  - `sell_candidates`: an item with `in_inventory` is a candidate when it is stored in a container (bin/barrel/bag)
    that is not carried, forbidden, in a job or a trader's; it is checked with `dfhack.items.canTrade` (the
    `...WithContents` variant refuses contained items) and marked by itself with `dfhack.items.markForTrade`, as the
    player's move-goods list does (the hauler takes it out of the bin). Items carried by units stay excluded.
  - Sale choice `choose_sells`: most valuable first but only pieces that keep the sum within the overshoot tolerance
    (many small pieces); still short -> the cheapest single piece that closes the gap; only if none does, the most
    valuable remaining pieces. The live case (26300 + small figurines, need ~1000) now sells the small ones.
  - `open` closes an open Squads window first (BUG-224 addendum).
- `data/trade/handel-regeln.md`: rules template (format documented) with `buy 4 CLOTH silk 10` followed by the generic
  `buy 4 CLOTH * 30`. `install-lua --apply` creates `<DF>/df-llm-helper-runtime/tools/{out,scopes}` and copies the
  template when no rules file exists (an existing file is never overwritten; the plan shows `new` or `kept`).
- Tests: `tests/test_lua_claude.py::test_bug226_*` (home creates the folder, reports an uncreatable one once, status
  errors and written mark, plan refuses without rules, candidates in bins, `mark --live` marks them, small-piece sale,
  template has the generic CLOTH entry), `tests/test_install_lua.py::test_bug226_*`,
  `tests/test_live_trade.py::test_bug225_caravan_pilot_waits_during_alarm_and_reenters` (errors become warnings).

## Info needed
Live check after `python -m df_llm_helper install-lua --apply`:
1. `<DF>/df-llm-helper-runtime/tools/scopes/handel-regeln.md` exists (template, or your own file kept). Merge your
   own rules with the template's generic `buy 4 CLOTH * 30` line if you keep your file.
2. `dfhack-run claude/handel status`: `errors` is `[]`.
3. With a caravan: `claude/handel plan` lists figurines stored in bins (`n` close to the 429 figurines);
   `mark --live` creates BringItemToDepot jobs for them, and haulers take them out of the bins. If DF refuses the job
   for contained items (marked 0, skipped > 0), save the `mark --live` output under `Bugs/evidence/BUG-226/`.
4. `select --dry`: `sell_top` contains several small pieces, not the single 26300 piece.
