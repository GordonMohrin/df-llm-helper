# BUG-406 farm plot has no seed for its season while 476 seeds of brewable crops lie unused, drink 23 days
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-04, Run 16c (i3 Yawninggilt R3, y388, `runs/run-16c/FR-BUGS.md`), main 503bb8b
Module: `lua/dfllm/economy.lua`, `dfpilot/wake.py`

## Actual
i3 kern.log, every season of the year: `farm plot 17705 season 0/1/2/3: no seeds for MUSHROOM_HELMET_PLUMP and no other crop with
seeds grows there now`; brief: `drink: no brewable plants (476 seeds; gathering, trade)`; drink 201 d -> 23 d, 16 brews waiting.

## Root cause
`M.slot_crop` (economy.lua:5324, BUG-397) takes a brewable crop only if `fits(inf)`: the plot's kind (`M.plot_under`: underground or
surface) and the slot's season must match the crop. The fort had ONE plot, an underground one, and its 476 seeds were seeds of
brewable surface crops: every slot of every season found 'no other crop with seeds grows there'. `M.brew_seeds` counted the seeds
whatever the plot kind, so the brief said '476 seeds' as if they were usable, and nothing asked for a plot of the other kind (only the
food path requests farms, and only when the farm tiles fall short of the citizens and food is low).

## Fix
- `M.brew_fit(K, c)`: stock seeds of brewable crops by kind (under / surf) and the built plots by kind (a plot of unknown kind counts for
  both).
- `M.brew_farm_request` (from `M.drink_low`): the stills' plants short (`st.bshort`), brewable seeds in stock and none of their kind fits a
  plot: `PROJECT_REQUEST farms n=1 why=drink` (a room plot) or `why=drink_surface` (surface, PEACE only), at most every
  `food.request_days`, never while a farms project is pending or lost. `wake.py`: follow places one plot (`p.plots 1`, `p.surface 1`
  for drink_surface) at prio 1; the new plot's slots take the brewable crop (BUG-397's `slot_crop`).
- `M.drink_block`: `no brewable plants (476 seeds fit no farm plot: surface seeds; a plot is requested, gathering)`.

## Open
Wild plants gathered by the zone are brewed, not sown. A surface plot needs soil or mud ground (BUG-407).

## Tests
tests/lua/test_bug406_brew_fit.lua (7), tests/test_cli_wake.py (+2). The Lua tests fail on 503bb8b.

## Live check
i3-like: one underground plot, brewable surface seeds, drink low: kern.log `drink N days: 476 brewable surface seeds fit no farm plot
(1 plots): a surface farm plot is requested`, `follow` log `auto:farms`, a farms project; after it stands the empty slots show the grass.
