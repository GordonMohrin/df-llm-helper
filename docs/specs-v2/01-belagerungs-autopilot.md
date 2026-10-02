# Spec 01: Siege Autopilot (`dfpilot siege`)

Priority: P0 | As of: 01.10.2026 (Run 5, Windrings) | Status: implemented (PR v2-01), not yet live-tested | Framework: see README.md

## Goal and Benefit
A siege, raid or beast is handled without LLM turns: pause, record targets, kill order, civilian warning, step mode, cleanup. In Run 5 I did this by hand for 6 attacks (elves 50 and 31, goblins 18 and 15 each with a war cave dragon, thieves/snatchers), each time with 15–40 tool calls (`engage.sh`, `killgob.lua`).
**Expected gain:** approx. 90 % fewer turns per attack, same quality (no forgotten cleanup steps as in Run 3).

## As-Is State (Run 5)
- The watchdog detects the alert/siege flag and pauses; `gefahr.lua` classifies; `wake` reports.
- By hand: list invaders (`isInvader`, not `isFortControlled`), Chebyshev distance to the fort center, `df.squad_order_kill_listst` (units + histfigs) into the guard, `claude/alert on`, `claude/advance N` in steps, then delete orders (`squad.orders:erase`), `alert off`, delete flags `alert/siege/pause.hold`, `advance run`.
- Learned: kill radius ≤ 45–60 tiles (otherwise soldiers chase enemies 70 tiles away); for soldiers that are too far away, a move order; a move target must be reachable (`canWalkBetween`), otherwise the soldiers stand still; never a kill order against citizens (berserk citizens kill the civilians).

## Behavior (state machine)
1. **DETECT:** `siege.flag`/`alert.flag` with living invaders on the map (not combat lines alone).
2. **ASSESS** (1 snapshot): count, professions/types (`BOWMAN, LASHER, SWORDSMAN, CAVE_DRAGON/TRAINED_WAR, THIEF`), distance, guard state (armor pieces, wounds, blood), threat level.
3. **PREPARE:** civilian warning only at distance ≤ `alert_radius`; plug proposal (no automatic building).
4. **ENGAGE loop:** `advance(step)` adaptive (distance > 60: 300, 30–60: 120, < 30: 60); after each step re-set the kill order (targets within radius `kill_radius`) and measure state.
5. **ABORT:** soldier blood < `min_blood_pct` or dead → retreat (move order to a reachable barracks point) and report; more than `max_losses` losses → pause and notification.
6. **CLEANUP:** no invaders (or only fleeing ones > `flee_dist`): delete orders, alert off, flags gone, `advance run`, report (losses, dead, duration, turns saved).
Runs as `dfpilot siege --loop` (started by the watchdog) or `--once` for tests.

## Configuration (`config.yaml`)
`siege: {alert_radius: 40, kill_radius: 45, flee_dist: 70, step_far: 300, step_mid: 120, step_near: 60, min_blood_pct: 60, max_losses: 2, squad_alias: Wache}`

## Interfaces
`DFClient.lua(...)` (new thin Lua `pilot_siege.lua`, not yet live-tested), `guard` (tempo/blocker), `bus`, `overlay`, notification via file `tools/notify.flag` (the orchestrator sends the push message).

## Safety
- Kill order only against `isInvader` and not `isFortControlled/Citizen/Pet/Merchant/Guest`; never against citizens or animals.
- Squad only by alias (`Wache`), never `Bergleute`. Orders are guaranteed to be deleted (try/finally; the watchdog checks for orphaned orders).
- No rebuilding of burrows during combat (Run 3 lesson).

## Acceptance Criteria
1. Replay "elves 31": pauses, orders set, at the end all orders deleted, alert off, flags gone (mock checks the final state).
2. Test "soldier below 60 % blood": retreat order and report.
3. Test "enemy ≥ 70 tiles fleeing": abort without pursuit.
4. Test "citizen berserk": no kill order, report only.
5. Loop protection: abort after `max_steps`; `--dry` shows actions without effect.
6. Tokens: a complete siege ≤ 12 lines of final report.

## Fixtures/Tests
Record anew: unit lists with invaders, squad orders before/after, `claude/alert` responses, gamelog excerpts of the attacks (`tools/events.log`, Y105/Y106).
