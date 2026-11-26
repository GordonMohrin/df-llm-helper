# BUG-935 BUG-930 verifier nits: held piles that are gone or unwritable keep the hold alive, no word after 2 game years, status text claims the registration matters
Status: fixed (offline, live-untested)
Severity: low
Found: Run 17 i3 verifier of 17c (runs/run-17c/FR-BUGS.md), read in the code of BUG-930
Module: `lua/dfllm/economy.lua` (`M.release_giveback`, `M.hold_warn`, `M.cont_words`), `lua/dfllm/act.lua` (`pile_barrels restore`), `lua/dfllm/brewsnap.lua` (`B.headline`), `config/baseline.json` + `dfpilot/fairplay.py` (`economy.cancel.hold_warn_d`)

## Cause
- `M.release_giveback` removed a `p.relpiles` entry only when `act.pile_barrels('restore')` reported a write for it and the new limit reached the old one. A pile that was deconstructed (`df.building.find` nil) or whose write fails never reported, stayed in `relpiles` for ever, `held` never reached 0 and `p.hold` never ended.
- A hold with `cont_free` under the target for years said nothing.
- `M.cont_words` said "N held by stockpiles as their containers" beside "usable", and the BREW_CANCEL_SNAPSHOT headline "free empties N" without saying that count does not subtract the registrations: DF's own use of registered empties is UNPROVEN (BUG-930).

## Change
- `act.pile_barrels restore` returns `missing = {{id, why}}` (`gone` / `write failed` / `no limit`) beside the written entries. `M.release_giveback` drops an entry whose pile is gone, or whose write failed `M.GIVE_FAIL_DROP` (3) steps in a row, or which has no readable old limit; one line `pile barrel release: N held piles leave the hold, their limit cannot be given back: ID (pile gone), ID (write failed 3 steps in a row)`; the other piles are given back as before and the hold ends. (A pile dropped for failed writes keeps its lowered limit: said in the line.)
- `M.hold_warn`: a hold older than `cancel.hold_warn_d` (672 = 2 game years) with `cont_free` under `give_target`: ONE kern.log line a game week "N piles have held their barrel limit lowered for D game days and the usable empties are still F of the T wanted: the limits are NOT given back by this ...; economy.cancel.release = false hands them all back at once". Nothing is given back by it.
- Wording: `M.cont_words` adds "(DF's own use of them is not proven)" to the registered count; the snapshot headline reads "free empties N (incl. pile-reg)".

## Tests
`tests/lua/test_bug935_hold_nits.lua` (4: gone pile, three failed writes, the weekly line, the wording).

## Live-Erwartung
A held pile that is deconstructed: `pile barrel release: 1 held piles leave the hold ... ID (pile gone)` at the next give-back step and `PILE_BARREL_RELEASE` steps continue for the others; after 672 game days of hold with cont_free < 20 one `have held their barrel limit lowered` line a week.
