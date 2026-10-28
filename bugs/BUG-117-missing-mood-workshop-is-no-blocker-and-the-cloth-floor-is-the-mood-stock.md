# BUG-117 A moodable workshop (the Loom) can be missing for years without a blocker, MOOD_RISK names no command, and the kernel keeps only 10 free cloth
Status: fixed in the M6 commit (offline, live-untested): R0 `mood_ws`, `fix` in MOOD_RISK and the mood_workshop decision, `economy.cloth.floor`
Severity: high (Run 14: 151 of 453 citizen deaths were failed strange moods; unit 39015 died waiting 49 days for cloth)
Found: 2026-10-25/28, Run 14 (notes 80 and 92)
Module: `lua/dfllm/readiness.lua` (`M.mood_ws_blocker`), `lua/dfllm/economy.lua` (`M.mood_shops`, `plan_cloth`), `lua/dfllm/care.lua` (`M.ws_fix`, `mood_seen`)

## Actual
- Note 92: the Loom was missing for a while (a siege); MOOD_RISK said "cloth(silk)/cloth(yarn)/cloth(plant) x1: none in the fort" for 49 days.
  Nothing named the missing workshop type or the command that places it.
- Note 80: a miner went into a fey mood and died waiting for cloth; a day later the fort had 643 free cloth, 1376 thread and one Loom. The game
  session added a private MOOD_CLOTH_WATCH (a routine outside the kernel) and asked whether `plan_cloth`/`mood_wants` can miss such a case.

## Cause (proved from the code at 32994bb)
1. **No readiness rule for the moodable shops.** `readiness.lua` has blockers for the audit, bridges, burrows, the hospital and the offices; none
   for a missing Loom/Craftsdwarf/Jeweler. The 12 types are a P1 deliverable of the plan (`runner.lua:127` `M.MOODABLE`, CHECK.workshops
   `runner.lua:3138`) and nothing looks again after they were built and one was destroyed.
2. **`plan_cloth` without a Loom does nothing and asks for nothing.** `economy.lua:1750` `if ws_any(r.f, Cc.loom)`: no Loom, no WeaveCloth order, no
   PROJECT_REQUEST (the tanner has one: `economy.lua:1694` `tannery_request`; the Loom has none). The mood stock is 10 cloth
   (`economy.lua:1374` `mood_target` = `plan.supply.mood_stock`), so a fort with 12 cloth makes no order and a mood that wants 3 kinds
   (silk/yarn/plant, x1 each) can still find none of one kind. `care.mood_wants` raises the need for two days (`economy.lua:1416`
   `m.care = {n, untl = now + 2 * DAY}`).
   Reserved or forbidden cloth is not the gap: `economy.lua:1368` `have` counts care's forbidden mood reserve (`r.held`) as stock, and care frees
   forbidden items for an open mood slot (`tests/lua/test_care_moods.lua` "forbidden ones freed"); BUG-100's `none free` / `none in the fort` says
   which of the two a report means. Without collected thread (or without a Farmer's shop for `ProcessPlants`) no weave order can run whatever the
   deficit is: the thread side has its own request (FR-73 `farmers`).
3. **The care texts name no command.** `care.lua:629-631` (DECISION_NEEDED `mood_workshop`) says "needs a workshop for <skill> now (workshops template or
   one shop)"; MOOD_RISK (`care.lua:579`) says nothing about the workshop of a dwarf that has none.
- Not provable offline (the live data would decide): whether the kernel ran at the time of unit 39015, whether the Loom was built, and
  whether the cloth was forbidden by care's reserve (`reserve.lua`). The three hypotheses of the note (kernel not running, Loom not built,
  items reserved) are all covered by the new rules except the first: a kernel that does not run cannot do anything, which the heartbeat
  (`HB_STALE`) reports.

## Fix
- **R0 `mood_ws`** (`readiness.lua` `M.mood_ws_blocker`): a moodable workshop type missing on the map (`economy.mood_shops`: the 12 types, a built
  Magma Forge/Magma Glass Furnace stands for the plain one; nil before `mood_from_phase` P1) for `offices.mood_ws_days` (7) game days in a fort
  of at least `offices.mood_ws_pop` (20) citizens. The days count from the first look that found it missing in a fort of that size (persisted
  `mws`, type -> tick; a fort of 0, 7 or 19 citizens never gets the blocker). The text names up to three types and the ready command
  `dfllm cmd bp.place {"tpl":"workshops","site":"S1","p":{"only":"Loom"}}` (types a pending `workshops` project already lists are named with the
  project and its percent instead). It travels as `ready.fail` token `mood_ws`, `ready.mws` (state), `SIEGE_UNREADY.mws`, the brief's `next:` line
  and the wake hint. R0 keeps max-pop where the readiness caps put it (all caps are 100 now); the effect is the loud SIEGE_UNREADY wake and the
  status line.
- **MOOD_RISK `fix`, DECISION_NEEDED `mood_workshop` q** (`care.M.ws_fix`): for a dwarf without a workshop the command for the shop of his best
  skill (`care.SKILL_WS`: CARPENTRY -> Carpenters, WEAVING -> Loom, ...) when economy sees it missing, else the first three missing types;
  nothing when his shop stands or economy does not answer (the old text).
- **Cloth floor** (`economy.cloth.floor`, 20, 0 = off): from `cloth.from_phase` on the weave and thread orders aim at 20 free cloth even when
  the mood stock (10) is met; the fiber crops (`fiber_on`, autofarm) still follow the target only, so the farms are not touched. This is the
  kernel's own version of the game session's MOOD_CLOTH_WATCH.
- Config: `offices.mood_ws_days`, `offices.mood_ws_pop`, `economy.cloth.floor` (baseline.json, `fairplay.OFFICES_LIM`/`ECONOMY_LIM`, mirror tests).

## Not decided offline
- Whether R0 for a missing Jeweler or Mechanic in a fort that never needed them is too loud: the 12 types are the plan's own P1 deliverable and
  the player can silence it with `offices.mood_ws_days 0`. The live cost is one SIEGE_UNREADY per game month (util/cadence).
- The cause of unit 39015's 49 days: `kern.log` and `events.jsonl` of y707 d074-d123 (kernel running? `workshops` project? cloth items forbidden?).

## Tests
`tests/lua/test_readiness.lua` (2: the blocker with its text, queued, knobs, 0/7/19/20 citizens), `tests/lua/test_m6_economy.lua` (3: `mood_shops`),
`tests/lua/test_care_moods.lua` (2: the fix in MOOD_RISK and the decision), `tests/lua/test_economy_chains.lua` (the floor; the old target test runs with floor 0),
`tests/test_m6_orders.py` (schema, wake, brief, config). All fail on 32994bb.
