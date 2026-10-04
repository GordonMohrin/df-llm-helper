# BUG-430: Broker never reaches the depot: `handel broker --force-job` only works if the broker has no job

- **Status:** open
- **Severity:** S2
- **Area:** `lua/claude/handel.lua` (`broker`)
- **Reported:** 2026-10-04, commit `eb0f007`
- **Environment:** Windows 11, Python 3.14, game: running (DF 53.16 + DFHack), fort Windrings year 182-183 (Run 5)

## Command / steps
```
dfhack-run claude/handel broker --live --force-job
```
1. Caravan arrives (trade_state 1 then 2), `trader_requested` is true.
2. The broker (Etur 9279, later Tun) is busy with Haul, Drink, PlantSeeds, Sleep, HarvestPlants or PenLargeAnimal.

## Expected
The helper frees the broker (cancels the current non-critical job), assigns `TradeAtDepot`, and the broker stands in the depot before the caravan leaves.

## Actual
`--force-job` only creates the job when the broker has none; a direct `dfhack.job.addWorker` failed (`addWorker` false). Second attempt (22:12): the broker kept hauling, drinking, sowing and sleeping; the caravan left (trade_state 3) before `TradeAtDepot` ran. In the third attempt (23:05) the agent removed the broker's current job by hand in a one-off Lua script (`HarvestPlants`, `PenLargeAnimal`) and then `TradeAtDepot` worked.

## Evidence
none needed (see section "Handel Muboomon 04.10." in `ERFAHRUNGEN.md` of the dwarf-fortress repo).

## Analysis (reporter's hypothesis)
`handel.lua` treats "has a job" as "busy, do not touch". Removing the current job with `dfhack.job.removeJob` is safe when it is not Eat/Drink/Sleep at a critical need and not a mood job. The broker should also have his labors cleared during the caravan so he is not re-tasked (known rule: broker and manager never carry labors).

## Suggested fix
`broker --force-job`: remove the current job unless it is Eat/Drink/Sleep above the critical limit, then add `TradeAtDepot`; re-check every 60 ticks until the broker stands on a depot tile; show `broker_at_depot` in `handel status`.

## Info needed
Check that `removeJob` on `HarvestPlants`/`PenLargeAnimal` leaves no stuck `in_job` flags on the claimed items.
