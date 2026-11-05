# BUG-467 strange moods die in a stone-0 fort: the materials are asked for only after the mood started
Status: fixed (offline, live-untested)
Severity: high (Roadvises: 6 moods, 3 dead; Basementflew: 2 dead for glass and gems)
Found: 2026-11-05, Run 16b i2 Roadvises ("Mood Manager insane (Stein/Barren fehlen)", "Mood-Vorsorge: Stein/Gems/Stoff per Handel bei Stein-Null-Fort"), Run 16a i1
Module: `lua/dfllm/economy.lua` (`rock_dig`, `supply_wants`, `M.SUPPLY`)

## Actual
In a fort with no free boulder (and no ore, gems, bars, cloth) a strange mood asks for stone, a gem, a bar or cloth the dwarf cannot get in its window; `care.mood_wants` buys after the mood started (the caravan comes once a season), `supply_wants` bought stone and gems only after two stone digs found soil (`rocksoil`). Roadvises never reached that mark.

## Root cause
`supply_wants` was gated on `st.rock.soil` alone; a fort that has no stone for other reasons (digs not yet made, soft stone only, an aquifer ring) bought nothing in advance, bars and cloth never.

## Fix
`rock_dig` times the stretch without a free boulder (`p.rock0`); after `SUPPLY.zero_days` (14) `st.rock.zero` holds: `supply_wants` asks for `stone` (the rock need, else 5 for a mood), `gem` up to 3, `bar:iron` up to 2 and `cloth` up to 2 in stock. A free boulder resets the clock. The glass chain (sand, bags, fuel, furnace) is economy's own since BUG-303/304; what blocked it in Basementflew was the furnace (BUG-466).

## Tests
`tests/lua/test_economy_pieces.lua` (BUG-467: not before 14 days, the four wants, stock suppresses bars / cloth, a boulder cancels it).

## Live check
A fort with stone free 0 for two weeks: `trade.want` lists stone, gem, bar:iron, cloth (inspect trade wants); with stone in stock none of them.
Open: sand for glass is no trade token (the chain makes glass from sand the fort collects); a mood for a material no caravan carries still fails.
