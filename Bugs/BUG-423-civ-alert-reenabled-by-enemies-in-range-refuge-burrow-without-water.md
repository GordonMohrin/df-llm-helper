# BUG-423: civilian alert is switched on again by the watchdog while an enemy stays in `ALERT_RANGE`; the refuge burrow "Zuflucht" has no drink/food/well -> citizens died of thirst

- **Status:** fixed in 908dc28
- **Severity:** S1 (more than 10 citizens died of dehydration inside the alert burrow; the alarm cannot be switched off while an enemy stays in range)
- **Area:** `lua/claude/watchdog.lua:372-388` (civ alert on/off), `lua/claude/gefahr.lua:274-279` and `selbsttest` (`gefahr.lua:309`), `lua/claude/mil.lua:618-643` (`refuge`), `lua/claude/ueberwacher.lua:100` (`ZIVILWARNUNG` loop), `lua/claude/config.lua:119` (`ALERT_RANGE = 45`)
- **Reported:** 2026-10-02, commit `22b9b03`
- **Environment:** Windows 11, game running (DF 53.16 + DFHack), siege with 164 attackers (see `Bugs/LIVETEST-2026-10-02.md`)

## Command / steps
1. Enemy ground units stand permanently within `ALERT_RANGE` (45 tiles, Chebyshev from the fort centre, `config.lua:119/182`), e.g. a siege camp outside the walls.
2. Orchestrator: `claude/alert off` (civ_alert_idx = 0).
3. Within one watchdog cycle `watchdog.lua` switches it on again.
4. The supervisor (`ueberwacher.lua:100`) writes `notfall.flag`: `ZIVILWARNUNG seit > 3 Min AN (Watchdog-Enemies=N) -> claude/alert off + Watchdog neu starten`, every > 300 s, in a loop.
5. Burrow "Zuflucht" (alarm 1) contained neither drinks, food nor a well/hospital; the citizens ordered into it could not drink.

## Expected
- `claude/alert off` stays off for a configurable time (e.g. `alert_hold_off_min`) or until the enemy count/zone *changes* (hysteresis), or the watchdog respects an explicit manual-off flag written by `claude/alert off`.
- Switching the civilian alert on is only allowed if the refuge burrow is **supplied**: reachable drink (barrels/stockpile or well) and food inside the burrow tiles; otherwise report `ZUFLUCHT OHNE WASSER` and do not lock citizens in.
- The `ZIVILWARNUNG` flag must name the real cause (enemy inside ALERT_RANGE) instead of recommending a command that is undone within seconds.

## Actual
`watchdog.lua`:
```lua
if enemies > 0 then
  state.clean = 0
  ...
  if al.civ_alert_idx == 0 and #al.list > 1 and #al.list[1].burrows > 0 then
    al.civ_alert_idx = 1          -- on again, every cycle while enemies > 0
```
`gefahr.lua:276` does the same (`S.alarm > 0 and al.civ_alert_idx == 0 ... civ_alert_idx = 1`). Nothing checks what the burrow contains; `selbsttest` (`gefahr.lua:309`) only checks that alarm 1 exists and has *a* burrow (`ZUFLUCHT/ZIVILWARNUNG fehlt`). `mil refuge` builds the burrow from `config.ZUFLUCHT.rects` only (`mil.lua:627-643`).
Observed: `notfall.flag` text `ZIVILWARNUNG seit > 3 Min AN ... -> claude/alert off + Watchdog neu starten` repeated; citizens in the burrow died of dehydration (> 10 dead; see the orchestrator memory note `feedback_df_verbotene_fassen_verdursten.md`).

## Evidence
none recorded as raw files; `tools/notfall.flag` text as quoted above; the number of dead (> 10) is the orchestrator's observation. Mock repro: a fixture with `enemies_near > 0` for 3 watchdog cycles and `civ_alert_idx` forced to 0 between them should show the flip back to 1.

## Analysis (reporter's hypothesis)
The enable path has no memory of a manual `alert off` and no supply check; the supervisor's remedy is a command that the watchdog cancels (livelock between two helpers). Second cause of the deaths: drinks were additionally forbidden (see BUG-125 / FEATURE-003).

## Suggested fix
1. `claude/alert off` writes `tools/alert-manual-off.flag` with timestamp + enemy signature; watchdog/gefahr skip enabling while the flag is younger than N min and the enemy count has not grown by more than X.
2. Selftest `claude/mil refuge` (status): check **"burrow contains reachable water/drink/food/hospital"** - count in the burrow tiles: DRINK/FOOD items (not forbidden, in container or stockpile), a well (`building_type.Well`) or a drinkable water tile, a hospital zone/bed. Output `ZUFLUCHT OHNE WASSER` as problem text in the `selbsttest` list and refuse `civ_alert_idx = 1` from automation if it fails (warning wake only).
3. Add the ZUFLUCHT checks to `digest` (item `refuge_supply`).

## Acceptance (fixture based)
- Fixture "enemy in range, manual off": 3 watchdog cycles -> `civ_alert_idx` stays 0, status shows `manual_off_until`.
- Fixture "burrow without drink/food/well": selftest returns `ZUFLUCHT OHNE WASSER`; automation does not enable the alert.
- Fixture "burrow with barrel of drink and a table with food": no problem text.

## Info needed
Decision: should an unsupplied refuge block the *automatic* alarm completely (citizens walk around during a siege), or is a warning plus automatic burrow extension enough? Player: which `config.ZUFLUCHT.rects` were active when the citizens died.

## Nachtrag 2026-10-03 (second invasion, Run 5)
- **Gefangene Feinde loesen Alarm aus:** the watchdog keeps `civ_alert_idx` = 1 as long as a *caged* enemy (cave dragoness in a cage trap at (101,96,z130), d=5) is inside `ALERT_RANGE`. Loop: `ZIVILWARNUNG seit > 3 Min AN -> claude/alert off + Watchdog neu starten`. Caged/chained units (`flags1.caged`/`flags1.chained`) must be excluded from the enemy count in `watchdog.lua`/`gefahr.lua` (same cause as BUG-426).
- **Verpflegung im Burrow:** after invasion J125 citizens died of thirst; fixed by hand by extending the burrow with the well (139,99..140,99,z129), drink store (117..121,88..92,z132), food store (109..113,108..114,z130) and paths between them (idea: BFS from the hospital to the targets). Feature request: `Features/FEATURE-005-refuge-check-supply-reachability.md`.

## Fix
- **Livelock:** `claude/alert off` writes `tools/alert-manual-off.flag` (`<epoch> <enemies near> <class A near>`). `gefahr.civ_gate()` is
  asked by both enable paths (`watchdog.lua` alert section and `gefahr.handle`): while the flag is younger than
  `config.ALERT_MANUAL_HOLD_S` (900 s) and the enemies near the fort have not grown by more than `ALERT_MANUAL_GROW` (5) and no new
  class A threat appeared, the alert stays off (`civ_alert gesperrt: manual_off`). `claude/alert on` deletes the flag; the watchdog
  deletes it after 5 clean checks. `watchdog status` shows `civ_blocked` and `manual_off_until`; `gefahr status` shows
  `refuge.manual_off_until`.
- **Prisoners (Nachtrag):** new `config.is_captive(u)`: `flags1.caged`, `flags1.chained` or held in an item
  (`dfhack.units.getContainer`, covers a cage without the flag). Used by `is_ground_enemy`, `is_intruder`, `gefahr` (`excluded`),
  `mil enemies/kill`, `killorder`, `pilot_siege`, `report`, `status`. Each script has a fallback to the two flags if an old merged
  `config.lua` lacks the function.
- **Refuge supply:** `gefahr.refuge_supply()` counts inside the burrow `Zuflucht`: non-forbidden drinks and food (also in barrels/bins,
  forbidden containers excluded), wells, visible water tiles, hospital zones. Problems `ZUFLUCHT OHNE WASSER` (no drink, no well, no
  water) and `ZUFLUCHT OHNE ESSEN` go into the `gefahr` selftest (shown by `gefahr status`, used by the supervisor), into
  `refuge.supply` of `gefahr status`, into `mil refuge --apply`, and into the new read-only `claude/mil refuge check`. The snapshot sets
  `refuge_ok = False` and `refuge_problems` for an unsupplied refuge, so `digest` reports "Refuge burrow not ok".
- **Decision (Info needed):** automation does NOT switch the alert on while the refuge has no drink and no water source
  (`config.REFUGE_REQUIRE_WATER = true`); the watchdog writes `notfall.flag` `ZUFLUCHT OHNE WASSER: N Feinde in ALERT_RANGE,
  Zivilwarnung NICHT eingeschaltet ...` every 5 min instead. Missing food only warns. Set `REFUGE_REQUIRE_WATER = false` to keep the
  old behaviour (alert on, warning only). `claude/alert on` by hand always works.
- **Supervisor:** the `ZIVILWARNUNG seit > 3 Min AN` text now names the cause (`N Feinde in ALERT_RANGE`, refuge check, hold time of
  `alert off`); "Watchdog neu starten" is only suggested when no enemy is near.
- Tests: `tests/test_bugs_live_mil.py` (watchdog cycles with manual off / growing enemies / no supply / forbidden drinks / caged,
  chained and contained enemy; selftest texts; `mil refuge check`; `alert off/on`; supervisor text; snapshot).

## Info needed (live check after `install-lua --apply`)
1. `claude/mil refuge check` on the live fort: `refuge.drink/food/wells/water_tiles` must match what the player sees in the burrow
   (well (139,99,z129), drink store (117..121,88..92,z132), food store (109..113,108..114,z130) after the manual extension).
2. With an enemy in `ALERT_RANGE`: `claude/alert off`, then `claude/watchdog status` 3x over 1 min: `civ_alert_active = 0`,
   `civ_blocked = "manual_off"`, `manual_off_until` set; `tools/alert-manual-off.flag` exists.
3. Caged dragoness: `lua "local u=df.unit.find(ID) print(u.flags1.caged, u.flags1.chained, dfhack.units.getContainer(u))"` and
   `claude/gefahr status` (she must not be in `top`). If neither flag nor container is set, report the raw unit flags.
4. Reachability inside the burrow is not checked (FEATURE-005 covers the BFS repair).
