# NEU7: a standing container reserve, the wood truth, honest numbers (BUG-854..859)

Status: offline, live-untested. Branch `neu7-vorrat`, base main ac8bed9a. Lead's brief: `leitung/neu3/LIVE-DIAGNOSE-2026-11-24.md`, Nachtrag 25.11. 02:30.

## Findings of this round

- The players' working command `order.add MakeBarrel mat=rock` is `{job = MakeBarrel, material = INORGANIC}` (`orders` verb, `act.workorder`). DF announces it as 'Make rock barrel (10)' / '(15)' / '(20)' (i4 gamelog: exactly the amounts the players sent): a real BARREL item. The kernel's old rock relief made 'Make rock pot' (MakeTool ITEM_TOOL_LARGE_POT): 971 completed on i4 and no lift of drink. A rock barrel is no large pot.
- i2 kern.log, cycles 1-2 (ticks 197971200, 198245607): 'pile barrel limit written on 34 / 45 piles', '8 barrels at once', then `economy task plan: ...economy.lua:1929: attempt to call a nil value (global 'stone_free')`: `plan_pots` called a `local function` defined later in the file (a nil global), the plan run died; 8 barrels per cycle went into a fort with 321-346 barrels and 6,400 plants (barrels 321 -> 329 -> 346, empty stayed 7: the piles' haulers took them); the pile freeze ran 14 days and was not renewed for 14 more. Cycle 3 worked next to the player's `MakeBarrel x10` order and two idle citizens given the Brewing labor.
- 'Logs' with `flags=[construction]` are built into walls: the census skipped them but still counted them in 'usable of M', dfraw called them unwalkable.
- The three drink numbers: status = usable units / 7-day rate; census = raw units; the alert's 32 d = 74 units at the seeded rate (53 milli-units per citizen and day).
- The kernel never picks logs for constructions itself; buildingplan's global material settings decide (`bm_route`, `wall_alt`, `T.jmake`).

## The reserve (BUG-854)

`economy.plan_reserve` runs first for barrels. State `p.rsv = {t0, at, done, open, mat, n, made, rep, lday}`.

| Situation | Action |
|---|---|
| no brew order open, or the reserve is off (`creserve.on`, `diag.cx_cure`) | nothing (the old planning) |
| a batch order stands (`dfllm:barrelx`) | nothing new; the labor of its material is held once a game day |
| DF cancels (>= `cx_min_n` 'Needs empty food storage item' in the window), no batch yet or the last one ended and a cancel is newer than `done + grace_days`, `repeat_days` apart | a batch of `ceil(brews / brews_per)` (10..30) |
| the same, `max_repeats` batches in a row | every 14 days only |
| DF cancels but the last batch has had no effect yet | nothing orders (the old x15 batch and pots stay behind it) |
| the cancels stopped, the cure ran once, `trickle_days` passed, free containers < `trickle_free` | a trickle of `trickle_n` |
| `total_cap` reached | no order, one warn a week while DF still cancels |

Material: `rock` when free boulders >= batch + `rock_plenty` or usable wood < batch, else `wood`; the rock order is `{job MakeBarrel, material INORGANIC}` with `uses.rock = 1`. Labor: Stone crafting (rock) or Carpentry (wood) held by `max(3, min(6, 2 + brews / 10))` adult non-soldier citizens (`cx_labor`).

## Residual risks

- A batch may be absorbed by the plant piles' haulers again (the freeze is unchanged: 14 days): the reserve repeats while DF cancels, bounded by `total_cap` (200) and the 14-day slow-down.
- Which workshop makes 'rock barrel' is read from the game's behaviour (it was done on the live forts through the same order), not from a table: `orderlib.O.WS.MakeBarrel` has no rock entry. The reserve needs a Craftsdwarf's workshop for rock.
- `wguard` switches buildingplan's `logs` for the whole fort while it is on; a fort whose stone is later refused by DF (hard_denied) gets the logs back at the next jmake run.
- The alert behind '32 d' was not located in the code; `dall` names the matching number.
- `refusal_evidence` sees only what went through the CLI (cli.log); a refusal that only an event or kern.log carries is not read.
