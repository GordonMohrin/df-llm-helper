# BUG-397 'no brewable plants': an embark without brewable seeds and no depot spirals into thirst
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-04, Run 16c (i3 Yawninggilt R2, `runs/run-16c/FR-BUGS.md`), main bb87afb
Module: `lua/dfllm/economy.lua`

## Actual
i3: `farm plot 17705: no seeds for MUSHROOM_HELMET_PLUMP and no other crop with seeds grows there now`, drink 201 d -> 15 d in a
year, `16 brews wait ... no brewable plants`; the caravans could not come (no depot, BUG-399), so no seeds by trade.

## Root cause
BUG-382 already draws the gather zone for the stills' plants. What stayed: (1) the farm slots took the crop with the MOST seeds
(`M.slot_crop`), a food crop, although a brewable crop with fewer seeds was in stock while the drink was short; (2) `M.fd_wants`
asked for seeds only at 0 seeds in all (a fort with cook-crop seeds never asked for brewable ones); (3) the drink block said just
`no brewable plants`, nothing about seeds, gathering or the caravans.

## Fix
- `M.brew_crop` (DRINK_MAT in the structural material or a growth, or a plant on the Cook ban = plump helmets, rule D-09),
  `M.cook_ban_set`, `M.brew_seeds`; `M.drink_low` keeps `st.nocook` / `st.bseeds` while `st.bshort` (BUG-382).
- `M.slot_crop`: while `st.bshort`, an empty slot takes the brewable crop with the most seeds that grows there, before the cook
  and fiber passes.
- `M.fd_wants`: `bshort` and no seed of a brewable crop with farm plots standing: `buy seeds` (`no seeds of a brewable crop`)
  and `buy plant` (the caravans, `trade_wants`).
- `M.drink_block`: `no brewable plants (N seeds; gathering, trade)` (status, DECISION `drink_low`, `stock.dwhy`).

## Open
Wild plants gathered by the zone are brewed, not sown (seeds come from eaten or processed plants). A fort with no depot still waits for
the caravan for seeds (BUG-399 widens the depot sites).

## Tests
tests/lua/test_bug397_brew_seeds.lua (3). Fail on bb87afb (the crop with the most seeds, no seed want, bare text).

## Live check
i3-like: drink < 60 d, no brewable plants: `stock.bshort 1`, a plot's empty slots show the brewable crop (e.g. MUSHROOM_CUP_DIMPLE),
`trade.want` lists seeds and plants, `status` drink line shows `(0 seeds; gathering, trade)`.
