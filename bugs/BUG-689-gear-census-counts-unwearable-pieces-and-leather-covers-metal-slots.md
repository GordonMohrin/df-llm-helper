# BUG-689 Gear census counts pieces nobody can wear, and a leather piece covers a metal slot: bars lie unused
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-11-10, Run 16d i4 Trumpetrealms y447-y456 ('gear: ... body 28/10 ok' with 24 alien-made pieces among the 'lying free but out of reach', 'metal 0 %', 13-32 bars, DECISION metal); Run 16a i1 Basementflew ('metal: no ore, 2-3 bars; 0 forge jobs, 0 bars for the soldiers' beside 'body 18/7 ok, head 23/7 ok')
Module: `lua/dfllm/economy.lua` (census `GEAR_CAT` branch, `M.wearable`, `gear_pre`, `M.gear_metal_topup`)

## Actual
- r16d4 `kern.log`: 'gear: 11 soldiers ... worn 53-71 %, pieces 93/99; body 21-28/11 ok, head 10/11+1 ok, ... weapon 3/8+1 ordered'; MakeArmor never ordered, soldiers in leather ('metal 0 %'). The same log lists 'lying free but out of reach: 36 bin, 1 far, 24 alien, 22-29 reserved'.
- r16a5 `kern.log`: every slot ok (body 18/7, head 23/7, gloves 138/14), so `plan_metal` counted 0 forge jobs: the 'no ore, 3 bars' DECISION is true for the moods and says nothing of the soldiers.

## Root cause
`economy.lua` census: `gear_ok(it)` (not owned, not melting, held by nobody or a soldier) was the whole test; a breastplate made by goblins (sized for goblins), a piece on a flooded level and a leather piece all counted as one piece of the slot. `gear_pre` compares `want - have - opened`, so a slot that is 'ok' in leather or loot ordered nothing, whatever lay in the bar stock; `military.gear_sets` (g_body) over-counted the same way.

## Fix
- `M.wearable(acc, item)`: a piece a soldier holds always counts; a piece made by another race (`maker_race` against `plotinfo.race_id`, the BUG-598 test) or lying on another walk group than the citizens' (`snapshot.far`) does not. Census `g_<cat>` counts wearable pieces only; `g_unusable` counts what was left out; `gm_<cat>` counts the metal pieces per armor slot.
- `M.gear_metal_topup` (end of `plan_gear`): for the armor slots that have a leather alternative (body, head, pants, gloves, shoes) and no missing piece, `gm_<cat>` below the soldiers wanted and no open order: one order in the first metal of `gear.metals` that has the bars (`left()` keeps the mood stock floors), at most `gear.max_jobs` jobs; it runs after every slot's own needs, so weapons and the missing pieces take the bars first. kern.log 'gear: body: 0 of 11 slots hold a metal piece, bars lie there: 5 jobs MakeArmor in IRON'. Needs a forge and fuel. A top-up order that makes nothing is handled by `gear_stale` like any other.

## Tests
`tests/lua/test_bug689_gear_census.lua` (3: leather armor + bars -> a metal body order; no forge / no bars / enough metal pieces -> none; goblin-made pieces do not cover the slot, dwarf-made ones do, `wearable` cases).

## Live check
kern.log 'gear:' line counts fall by the alien pieces (`body 4/11` instead of `28/11`) and an order `dfllm:gear_body` in iron appears while iron/bronze bars lie in the fort and the soldiers wear leather; `inspect what=military` stock.body.metal rises over the days.
Open: bars the top-up uses are not available for picks, mechanisms or crafts afterwards (only the mood floors are kept); the Basementflew DECISION text 'metal: no ore ... 0 forge jobs' is unchanged (it also counts the moods' 5 bars); the 32 bars of Trumpetrealms could not be confirmed as gear metals from the logs.
