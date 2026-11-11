# BUG-716 Raw fish stay uncleaned beside idle adults, and the stock runs out every spring
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-11, Run 16c i3 Wallfree y423-y426 (965 -> 2,616 raw fish, Fishery 'jobs 1, working 0', 17 of 33 adults idle, food 618 -> 183 days, manual PrepareRawFish orders made no cleaned fish) and Doorwings y377-y380 (food 0 days each winter, relief only by the spring crop)
Module: `lua/dfllm/economy.lua` (`M.fish_watch`, `M.labor_assign`, `M.fish_labor`, `M.gap_low`, `M.food_low`, `M.food_block`), `lua/dfllm/act.lua` (`LABOR_SETS.clean_fish`)

## Root cause
1. Raw fish count only as `fish_raw`; `plan_fish` orders PrepareRawFish and nothing watched whether the pile ever fell. The kitchen got a stall watch (BUG-629: labor switch, order made again), the fishery did not: nobody was asked to hold the Fish cleaning labor (CLEAN_FISH), the player could only read, and the food decision said 'raw fish need cleaning' without a cause.
2. `M.food_low` (line 13071) fired at `pre_days` 30 only. The harvest of the autumn gave about 119 days; the winter freeze stopped fishing; at 30 days it was too late for hunters, caravans and edible crops, so the stock hit 0 before the first spring crop every year.
3. Fish stock depletion (fishers with 'job none') is BUG-698's `fish_dry` (a second zone); cabbage leaves ('N inedible (CABBAGE:LEAF: no food use)') are named apart and never counted as food since BUG-618: both unchanged.

## Fix
- `M.fish_watch` (line 10745, daily, `T.watch`): fishery stands, raw fish >= `fish.stall_raw` (40), the pile did not fall by a fifth for `fish.stall_days` (6) days: it names the cause (nobody holds Fish cleaning -> `M.fish_labor` switches the labor on for the best idle adult via `act.labor_set clean_fish`; every holder busy -> one more; no PrepareRawFish order open; or 'the fishery is slower than the catch'), ORDER_STUCK B 'raw fish not cleaned for N days' (again after 30 days), and `st.fishw` puts 'N raw fish uncleaned for D days: ...' (`fish_clean`) into the food decisions. `M.labor_assign` (line 10373) is `cook_labor` made generic (same pick, same once-a-day stamp).
- `M.gap_low` (line 13074): in autumn and winter a stock under `food.gap_days` (110, 0 = off) counts as low (`M.food_low`): edible crops first, caravans asked for food, kitchen and butcher requested, hunters; no DECISION of its own.

## Tests
`tests/lua/test_bug715_718_food.lua`: stall -> labor on for the idle adult and told once (not again in 30 days); holder present -> told, no labor switched; a pile that fell by a fifth is no stall; no fishery / pile under 40 -> no watch; the decision blocker text; `food_low` by season (autumn, winter, spring, summer, bigger stock, gap_days 0, default). Existing suites run unchanged.

## Live check
kern.log 'raw fish not cleaned for 6 days: N raw fish, fishery built, Fish cleaning on nobody ...'; in autumn below 110 food days the economy acts as at food low. Open: 110 days and the 6-day / 40-fish thresholds are judgements; DF may give the Fish cleaning job only at a reachable fishery (BUG-715 covers a dead one); cabbage and the fish stock itself were not changed; a Kernel reload is needed.
