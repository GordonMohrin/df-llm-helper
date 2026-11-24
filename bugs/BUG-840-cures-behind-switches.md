# BUG-840 the cures of the 'fass' round act on a guessed cause: they are config switches, default OFF
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-11-24, review of BUG-834..838 (two verifiers: the container cause is not confirmed live; `nobarrel` outranked every other verdict, the pile freeze and the labor holds could hide the real stall).
Module: `lua/dfllm/economy.lua` (`M.diag_on`, `M.DEFAULTS.diag`, `brew_watch`, `plan_contx`, `manager_farm_off`, `brew_cause`), `config/baseline.json`, `dfpilot/fairplay.py`

## Root cause
BUG-834/835/837/838 changed fort behaviour (container reserve and phantom verdict, plant-pile barrel limit frozen, Carpentry and Stone crafting labors held, direct MakeBarrel tasks, more manager chores off, the 'bound to one Still' re-make) before any live line named the cause (PROCESS.md: root causes must be confirmed).

## Fix
`economy.diag` = `{cx_cure: false, mgr_chores: false, still_pin: false, stall_line: true}` (config/baseline.json, `M.DEFAULTS.diag`, lint --config, contract).
- `cx_cure`: the reserve (3 as BUG-779 when off), the phantom verdict, the `pile_barrels` freeze (a freeze left behind is given back when the switch is off), `cx_labor`, `cx_direct`.
- `mgr_chores`: the manager's Herbalism, Spinning, plant processing and giving-water labors (Farming always went off, BUG-547).
- `still_pin`: the `pinned to one Still` verdict and its re-make.
- Reporting stays on: the `by my count` text, jobwhy conditions, `scan_unreliable` and labor names, the chore named in `why`, the stall line. The act verbs (`pile_barrels`, `labor_set carpenter ...`, `ws_task MakeBarrel`) stay in the contract and the player's `labor.set` still works.

## Tests
`tests/lua/test_neu3_diag.lua` (defaults off: no pile freeze, no labor_set, no MakeBarrel task, reserve 3, no phantom), `tests/lua/test_bug834_838_brew_chain.lua` and `test_bug544_547_stone_manager.lua` run the cures with the switches on.

## Live-Erwartung
1. Without a config change a stalled brew fort behaves as before BUG-834 (no `takes no new barrel` line, no manager labors off beyond Farming, no `bound to Still` text) and writes the `raw stall brew:` line.
2. A cure is switched on only when the dump named its cause: `economy.diag.cx_cure` after `why items:barrels --raw` shows that empties free as DF sees them are the shortage (H5), `mgr_chores` after `why manager --raw` shows a chore job (H6), `still_pin` after `why brew --raw` shows `pinned=` on one Still beside an idle one (H3).
