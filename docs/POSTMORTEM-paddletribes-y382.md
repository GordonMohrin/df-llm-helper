# Post-mortem: Paddletribes (site 94), fallen spring year 382

End state: 1 citizen (a child, 0 adults), 120 loose corpses, 41 ghosts, food 0 days.
Peak population 55 (year 332). Decline from about 46 (year 379) to 0 within one year.

## Chain of failure
1. **Burial backlog.** Coffins and tombs lagged deaths for years (Mason workshops blocked by EngraveSlab jobs,
   coffin orders without material, planned coffins in cut-off rooms). Loose corpses grew to 70-120, ghosts to 30-41.
2. **Ghosts wreck the fort.** Ghosts batter dwarves and destroy buildings (log: "Coffin destroyed by ... Ghostly
   Recruit"). Bridges, traps and unfinished workshops (kitchen, still) vanished or never finished; traps went 31 -> 0.
3. **Stress.** 21+ dwarves above 50000, later 85-100 %. Tantrums, failed moods, deaths.
4. **No water.** No aquifer, the cavern lake was unreachable, so no well; the hospital had no water for years.
5. **Famine, hidden by a wrong metric.** The kernel counted food in cut-off caves (117 of 137 fruit): it read
   "101 food days" while 35 of 42 dwarves starved. Fixed in economy.lua/snapshot.far (commit "economy: food/drink
   on other walkable groups..."). Found too late.
6. **No kitchen.** A PrepareMeal order was valid for months, but no Kitchen workshop existed. The kernel never
   checked that a workshop for an order exists.
7. **False alarms.** Underworld demons (z1-7, 110 levels below the fort) kept putting the fort in ALERT/BREACH
   (idle up to 91 %). Fixed in sense.lua (non-invaders 40+ levels below every citizen are no hostiles).
8. **Order spam.** 133 orders without material (EngraveSlab, webs, silk) cancelled constantly.

## Lessons / to build
- Monitor must flag: loose corpses > 20, ghosts > 5, planned buildings that stay at stage 0 for > 30 days,
  orders whose workshop type does not exist.
- Count only reachable, edible food (done); report stock per walkable group.
- Build the kitchen, still, well and coffins/tombs BEFORE the population exceeds 30.
- Place workshops in rooms that ghosts and cut-off areas cannot reach; bury the dead first.
- suspendmanager re-suspends construction jobs ("preventblocking" false helps); the baseline re-enables it.
- Do not mine floors for shafts (designation resets); use stairs through walls.
