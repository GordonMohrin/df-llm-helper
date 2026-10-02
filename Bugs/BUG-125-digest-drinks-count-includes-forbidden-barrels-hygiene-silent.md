# BUG-125: `digest` shows "Getraenke 475" although all barrels were forbidden; `hygiene` does not report mass-forbidden own containers/drinks/blocks

- **Status:** open
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
