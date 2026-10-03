# BUG-426: `killorder.lua` / `claude/mil guard` issue permanent KILL_LIST orders against a caged (trapped) enemy; the squads stay "in combat" and starve

- **Status:** fixed in 908dc28
- **Severity:** S1 (soldiers did not eat or drink: hunger up to 71 000, thirst up to 48 000, `NOTFALL` wakes)
- **Area:** `lua/claude/killorder.lua` (`is_target`), `claude/mil guard`, library module `siege` (same check needed)
- **Reported:** 2026-10-03, commit `841361d`
- **Environment:** Windows 11, game running (DF 53.16 + DFHack), Run 5, after the second invasion (see `Bugs/LIVETEST-2026-10-02.md`)

## Command / steps
1. A cave dragon (Hoehlendrache) is caught alive in a cage trap inside the fort at about (101,96,z130); the unit has `flags1.caged`.
2. `claude/mil guard` (guard loop) calls `killorder.lua`, which sets `KILL_LIST` orders for squads 45, 46, 47 against every unit accepted by `is_target`.
3. `is_target` only evaluates `cfg.is_intruder`; the caged dragon counts as intruder -> order is issued.
4. The soldiers cannot kill the dragon (cage) and stay in "combat" permanently, never go to eat/drink.

## Expected
Units with `flags1.caged` or `flags1.chained` are never kill targets. Existing kill orders against such units are not renewed.

## Actual
Orchestrator observation: squads 45/46/47 hold the order for hours; hunger up to 71 000, thirst up to 48 000; `NOTFALL` messages and "TRUPP-BEFEHL" lines in the supervisor output. After the orders were deleted they were set again (source: a second, parallel orchestrator loop, see FEATURE-006; the library `siege` module needs the same caged check so that no path re-creates the order).

## Evidence
none recorded as raw files (supervisor lines and the hunger/thirst values are the orchestrator's observation).

## Analysis (reporter's hypothesis)
`is_target` lacks the state check. Local fix, live-verified by the orchestrator, at the top of `is_target` in `killorder.lua`:
```lua
if u.flags1.caged or u.flags1.chained then return false end
```
The library `siege` module (target selection for kill orders) should apply the same condition; check `watchdog`/`gefahr` target filters for the same gap (see BUG-423 Nachtrag: the same unit keeps the civilian alert on).

## Suggested fix
1. One shared helper (not caged, not chained, not dead) used in `killorder`, `siege`, `watchdog` enemy count and `gefahr`.
2. Self-healing: when a squad's KILL_LIST contains a caged/chained unit, remove it and log once.
3. Guard: if soldiers show hunger/thirst above a threshold while a kill order is active, drop the order so they can eat.

## Acceptance (fixture based)
- Fixture with one caged enemy: `killorder` creates no order; with a free enemy it does.
- Fixture with an existing order on a caged unit: the order is removed.

## Info needed
Raw `unit` dump of the caged dragon (flags1 bits) and the squad order list before/after, if the player can capture them next time.

## Fix
- One shared helper `config.is_captive(u)` (caged, chained, or held in an item via `dfhack.units.getContainer`); `is_intruder` and
  `is_ground_enemy` use it, `killorder.is_target` checks it first (as in the live workaround), `mil kill` skips such ids,
  `pilot_siege` status/kill exclude them (also chained, before only caged), and the Python siege flow drops invaders reported as
  `caged`/`chained`/`captive`.
- Self-healing: `killorder.lua` is now also a module. `scrub_orders()` removes caged/chained/dead/missing units (and their histfigs) from
  every kill order of the fort squads, deletes empty orders and logs each (squad, unit) once in `tools/out/killorder.log`. It runs on
  every killorder run and watch tick and on every `claude/mil guard` tick, so no path keeps such an order alive.
- Starving squads: a squad with a member at thirst > 40000 or hunger > 60000 gets no kill order and loses an existing one
  (`apply`, and `relieve_starving()` on every `mil guard` tick); the next run sets the order again once they have eaten. The siege
  flow does the same (`starve_thirst`/`starve_hunger`, `pilot_siege status` now reports member thirst/hunger): `pilot_siege clear`
  plus a notice instead of a kill order.
- Tests: `tests/test_bugs_live_mil.py` (caged/chained/contained enemy -> no order; free enemy -> order; old order on a caged unit
  scrubbed; starving squad without order; `relieve_starving`; `mil kill`; siege flow; `pilot_siege status`).

## Info needed
Live check after `install-lua --apply`: `lua -f <hack>/scripts/claude/killorder.lua -- --status` with the caged dragoness in the fort:
"Ziele im Inneren: 0"; squads 45/46/47 without KILL_LIST; `tools/out/killorder.log` shows `scrub ... (gefangen)` once if an old order
was still there. The duplicate parallel loop (FEATURE-006) is not covered here.
