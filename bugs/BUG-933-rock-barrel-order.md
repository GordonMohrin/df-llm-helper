# BUG-933 `order.add MakeBarrel mat=rock` "becomes make wooden barrel": the order is a rock order, `why` showed the wooden tally; the ladder named a rock order beside 0 free boulders
Status: fixed (offline, live-untested)
Severity: medium (a misleading reading and an impossible suggestion; no order was wrong)
Found: Run 17 i1 Diedplank, orders 709 / 710 / 719 / 919 / 1399 (runs/run-17a/FR-BUGS.md)
Module: `lua/dfllm/jobwhy.lua` (`J.order`, `J.df_match`, `J.attach_df`), `lua/dfllm/economy.lua` (`M.verbs['order.add']`), `dfpilot/leiter.py` (`t_versorgung`)

## Cause (PROVEN)
- The mat IS passed: commands.log of i1 (Steam dir) `1795705687 175798460 economy act.workorder [{"amount_total":15,"frequency":"OneTime","job":"MakeBarrel","material":"INORGANIC","tag":"dfllm:cmd"}] ok` for `verb:order.add {"amount":15,"job":"MakeBarrel","mat":"rock"}` (order 1399); the reserve's own rock orders likewise (`dfllm:barrelx ... "material":"INORGANIC"`). DF names that kind 'make rock barrel' (i1 order 725: "DF cancelled make rock barrel 1x in 7 d: Needs non-economic hard stone boulders"), and order 710's job wants "boulder x1: 0 match, 0 free".
- `J.df_match` matched DF's cancel tally by the job caption only ('make' ... 'barrel'): `why order:1399` led with the tally of EVERY 'make wooden barrel: Needs logs', which the player read as "mat ignored". Not a code path that drops the material.
- The ladder (`leiter.t_versorgung`) named `order.add MakeBarrel mat=rock` whenever `stock.wood` was 0, with `stock.rock` 0 / `rhard` 1 ('boulder x1: 0 match, 0 free, 0 of 2 free boulders are hard non-economic stone'): a rock barrel needs a free boulder DF lets a job take, so the order could only wait (i1 y422: order 728 x2 rock was made once 2 boulders were free).
- DF's large pot (stone food container) is a TOOL job (MakeTool ITEM_TOOL_LARGE_POT, `M.plan_pots`): not touched here.

## Change
- `J.order` records the order's material class (`r.mat`: wood by `material_category.wood`, rock by `mat_type == 0`); `J.df_match` then matches only the cancels of that kind ('make wooden barrel' for wood, 'make rock / stone barrel' for rock; unknown material keeps the old match); `J.attach_df` gives the job of an order the order's material. `why order:N` no longer leads with the other material's tally.
- `order.add MakeBarrel mat=rock` is REFUSED when the census holds no boulder a job may take (`M.stone_none` or no usable boulder; text: "no boulder a rock barrel may take (N boulders, 0 usable): it would only wait; dig stone (plan propose) or mat=wood / trade.want wood; material=INORGANIC forces it"); `material=INORGANIC` still orders it by hand. No refusal without a census.
- The ladder names `trade.want wood` instead of the rock order when `stock.rock` is 0 or `stock.rhard` is set.

## Tests
`tests/lua/test_bug933_rock_barrel.lua` (3), `tests/test_bug933_ladder_rock.py` (4).

## Live-Erwartung
`why order:<rock barrel order>` leads with DF's 'make rock barrel' reason (or none), not 'make wooden barrel'; `order.add ... mat=rock` with 0 usable boulders answers `ERR ... no boulder a rock barrel may take`; the ladder line for drink names `trade.want wood`.

## Not proven
- Whether DF sometimes hands a rock order to a wooden job at all: not seen; the logs show INORGANIC arriving and the job wanting a boulder.
