# BUG-226: `claude/handel` without the runtime folder: no stability mark, no rules file, goods in bins never marked, one huge item sold

- **Status:** open
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

## Info needed
none
