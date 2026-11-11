# BUG-707 Woodcutters without a usable axe: nobody forges or buys one
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-11, Run 16b i2 Whirledrampart y421 win d56 (inspect workload key=tools: axe 1, axe_free 1, axe_forb 1, axe_res 1; census w_axe 2; FellTree 4 unclaimed, 21 of 28 adults idle; trade.want held 'pick' and not 'axe')
Module: `lua/dfllm/economy.lua` (`M.plan_tool`, `M.plan_axes`, `tool_check` `st.tmiss`, `M.trade_wants`), `config/baseline.json` + `DEFAULTS` `axes`

## Root cause
Only picks had a forge order and a caravan want (`plan_picks`, `trade_wants`, Run 11). The Woodcutters' axes were only counted: when the axes are all reserved, forbidden, owned or on another walk group nobody forged or asked for one, and the wood stayed at 0 for years (no logs, no furniture).

## Fix
`plan_picks` is `plan_tool(kind 'pick')`; `plan_axes` is the same for `axe` (battle axe, config `axes`: tag `dfllm:axe`, metals as the picks, max_jobs 2). The demand is the Woodcutters' target less `tools_have`; and, set by `tool_check` as `st.tmiss.axe`, as many as the members who lack an axe while no free one is usable for them (`use` is 0, or the diagnosis says walk / off_group / reserved / forbidden / owned). The forge makes it from a spare bar and fuel; without forge or bar `trade_wants` asks the caravans (`axe`). Usable free axes: nothing is ordered.

## Tests
`tests/lua/test_bug705_707_wood_axes.lua`: forge + iron + fuel -> one `dfllm:axe` order (MakeWeapon ITEM_WEAPON_AXE_BATTLE, IRON), no trade want; no forge -> axe in trade_wants; usable free axes -> neither.

## Live check
kern.log / orders: a `dfllm:axe` MakeWeapon order while the Woodcutters hold no axe and no free one is usable; `trade.want` shows `axe`. Open: a new axe lying on another walk group than the woodcutters (the forge's group) still waits for the dwarves' fetch; DF's pairing of a free axe to a woodcutter is not under our control.
