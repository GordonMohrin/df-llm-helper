# BUG-423: civilian alert is switched on again by the watchdog while an enemy stays in `ALERT_RANGE`; the refuge burrow "Zuflucht" has no drink/food/well -> citizens died of thirst

- **Status:** open
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
