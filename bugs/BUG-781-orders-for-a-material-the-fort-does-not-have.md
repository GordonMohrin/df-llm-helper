# BUG-781 orders for a material the fort does not have stay for ever (no rock, no bars STEEL / IRON)
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-11-11, Run 16b i2 Whirledrampart y451 (STAND 20:10: '60 Orders stuck no rock / no bars STEEL'); kern events ORDER_STUCK '20 order(s) cannot run for 35 days: no rock (order 29 ConstructArmorStand, 30, ...)', '14 order(s) ... no bars:INORGANIC:STEEL (order 762 MakeShield, ...)', '15 order(s) ... no bars:INORGANIC:IRON (order 761 MakeAmmo, ...)'
Module: `lua/dfllm/economy.lua` (`M.order_dead`, `M.mat_dead`, called from `T.ocheck` after `M.order_prune`), `config/baseline.json` / `dfpilot/fairplay.py` (orders.dead_*)

## Actual
The library imports (rockstock, military: ids 29-48, 761-779) are one-time or standing orders of materials this fort never had (hard stone refused by DF, no iron, no steel). `M.order_prune` (BUG-315) keeps one order of each stuck kind, never the piece jobs (`M.PRUNE_KEEP`: ConstructArmorStand) and never standing orders, and `plan_steel` only asks one DECISION. So 60 orders stayed stuck for 24-64 days, ORDER_STUCK repeated every ~10 days and the manager's queue stayed full.

## Fix
`M.mat_dead(c, r, key)`: the input cannot come at all: `rock` when no usable boulder exists (`M.usable_n` 0, or DF's own refusal `M.hard_denied`); `bars:INORGANIC:X` of a pure metal with no bars and no ore of that metal in the census; steel when `plan_steel` names a missing input (`st.steel.missing`). Alloys other than steel are not judged.
`M.order_dead` (daily, in `T.ocheck`): an order stuck on such an input (kind input) for `orders.dead_days` (14; 0 = off) is removed, one-time and standing alike (the piece jobs too, unless a kernel tag of `M.PRUNE_KEEP_TAG` owns the order: moods, pieces, the dead, the hospital), at most `prune_per_day` together with the prune. A kernel-owned one is not entered again for `orders.dead_backoff_days` (30). ONE ORDER_STUCK (B, kind `dead_material`) per material and `dead_report_days` (30) names the material, the count and what gives it (stone.use / trade.want wood / trade.want bar:x / dig for ore); kern.log says it on every pass.

## Open
Alloy bars (bronze, brass) are not judged; a removed standing library order is not imported again (`p.imported`). `wood_orders` (rock -> wood) still runs first for one-time furniture orders. A Kernel reload is needed.

## Tests
`tests/lua/test_bug781_dead_orders.lua` (3): dead iron orders (one-time and standing) leave after dead_days with one event, a copper order with a copper bar stays, `mat_dead` rules, config keys.
