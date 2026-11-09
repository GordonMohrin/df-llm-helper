# BUG-583 `trade.want flux` is ignored (not an item type); the refuge-lever link_stale question repeats 10x a year without its cause
Status: fixed (offline, live-untested)
Severity: medium (steel waited on flux for 14 orders; a question the player could not act on)
Found: 2026-11-09, Run 16d i4 Trumpetrealms y411-y418 (`DECISION steel` missing flux, `trade.want flux` accepted but 'ignored (no item type)'; `link_stale` x10 a year, counter 4 -> 2173 days)
Module: `lua/dfllm/trade.lua` (`L.KINDS.flux`, `L.match`, `item_info`), `lua/dfllm/economy.lua` (`plan_steel`, `mech_state`), `lua/dfllm/readiness.lua` (`ask_reflevers`), `dfpilot/schema.py`

## Actual
(c) `flux` matched no token kind and no `df.item_type`, so a flux want was dropped. (d) `ask_reflevers` re-asked every `ask_days` (30) while the cause stayed, with a growing day counter and no word about why no mechanism came (no hard stone).

## Root cause
(c) `trade.lua` `L.token`: kinds are a fixed table, `flux` is not an item type. (d) `readiness.lua` `ask_reflevers`: the 30-day cadence applied to every cause, `mech_state` carried no stone cause.

## Fix
(c) `flux` = a BOULDER of a flux stone (item_info reads the raw reaction class FLUX; limestone, dolomite, marble, chalk, calcite by name as fallback); `flux:limestone` that stone only; `stone:flux` / `boulder:flux` the same; the steel DECISION names `trade.want add "flux"`. (d) a cause that waits on a material (unbuilt / unlinked / link_job / link_stale) is asked again after `DEF.stuck_days` (360) game days, at once only when the cause changes; `economy.mech_state` carries `hard` (DF refuses the rock jobs) and the question leads with the cause (`no mechanisms: DF refuses the rock jobs (no non-economic hard stone in this fort)` / `no usable stone` / `no Mechanics workshop`) and the command; DECISION_NEEDED `why` (schema).

## Tests
`tests/lua/test_bug583_flux_link_stale.lua` (3), `test_economy_reach.lua` (steel decision names the command)

## Live check
`dfllm cmd trade.want '{"add":["flux"]}'` answers without `ignored`; a stuck refuge-lever question appears once a year with the cause.
