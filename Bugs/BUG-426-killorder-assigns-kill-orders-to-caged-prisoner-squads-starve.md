# BUG-426: `killorder.lua` / `claude/mil guard` issue permanent KILL_LIST orders against a caged (trapped) enemy; the squads stay "in combat" and starve

- **Status:** open (local workaround applied in the live game, not yet in the repo)
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
