# BUG-113 `squad.sortie` to a position sets a station order only: no kill order, no result, the BREACH posture takes the squad back, "no killbox" refuses a lone enemy
Status: fixed in the M3 commit (offline, live-untested): a position with a visible hostile within `sortie.kill_near` tiles is a kill
order, the sortie is tracked and reported (SORTIE go / arrived / dead / done / abort + why), a sortie against a lone harmless
intruder is kept against the posture, "no killbox" falls back to the one hostile in sight, an unreachable target is refused with
the walk groups named, soldiers who stand beside the target without an attack end it (`not_attackable`) and the unit is cleared
Severity: high (the one tool the session had against a lone intruder did nothing, silently)
Found: 2026-10-28, Run 14 (Trussroads) y707 Sommer d64-70, game session note 96 (and note 77 for "no killbox")
Module: `lua/dfllm/military.lua` (`squad.sortie`, `sortie_pass`, `kill_lone`, `apply_squad`, `step`), `lua/dfllm/siege.lua` (`so_conf`),
`lua/dfllm/reflex.lua` (`ignore`, `lone_ids`)

## Actual
Gordon released `{"squad":"A","target":[77,67,128],"approve":true}`: reply `ok ... move to 77,67,128`. Six days later goblin 39230
stood where it had stood, "1 visible, harmless", `on_station=11` (all soldiers back at their core stations), no SORTIE or WAVE
event, 6 of 11 soldiers `hurt`. A sortie by killbox id is refused with `no killbox` in a fort whose manifest has none (note 77).

## Cause (proved from the code at 32994bb)
1. **A position is a station order.** The verb (military.lua:1996-2026) builds `{kind = 'station', pos}` for a position
   (:2019-2020) and a `kill` order only for hostiles inside a named killbox (:2012-2017); no census lookup around a position.
2. **The order is spent on arrival and the posture comes back.** `apply_squad` keeps an order only while `order_count(s) > 0`
   (military.lua:1866 `held`), the move order disappears when the soldiers have arrived, and the upkeep (`M.step` :2762,
   every 600 ticks outside PEACE) sees `drift` (:1868: `pos and order_count(s) == 0`) and gives the BREACH station back; a posture
   change forces it at once (`M.posture` :1879 `changed`). The comment of `M.posture` says it: "a new posture re-issues orders and
   ends sorties".
3. **No result is ever reported.** The verb answers once (`ok`); `SORTIE` (siege.lua, `so_event`) belongs to the sortie through
   O1 (`gate`) and military is not allowed to emit it (contract `by = 'siege'`).
4. **"no killbox".** :2011 refuses every string that is not a manifest killbox; a fort without a killbox manifest (note 77, "wave:
   no fortcore O1/B1/killbox in the manifest") can not use the verb on a lone enemy at all.
5. **Soldiers beside a unit DF does not treat as an enemy.** Nothing in the tree watches whether a kill order has an effect (not
   provable offline why the soldiers did not attack: BUG-111).

## Fix
- `squad.sortie` (military.lua): a position (or `"x,y,z"`) with visible hostiles within `sortie.kill_near` (5) tiles of it is a kill
  order on them; otherwise a station order, which becomes a kill order as soon as a member is within 3 tiles and a hostile stands
  within `kill_near` of the target, else ends as `done` / `no_target`. A killbox id the manifest lacks: a kill order on the one hostile
  in the census list (0 or more than one: refused with the reason, "give a position"). A target on another walk group than every
  member (`snapshot.groups`: revealed tiles only; a raised bridge or a wall between) is refused: `target unreachable: x,y,z is on walk
  group 7, the squad on 3 (...)`.
- The sortie is tracked in `rt.so[key]` and looked at every 100 ticks (`M.every`, back to 600 when none runs): SORTIE (B, military
  may emit it now: contract `by = any`) with `phase` `go` (why kill/station), `arrived`, `dead` (why killed), `done` (why no_target),
  `abort` with `why` `worn` (kept sorties only: worn < `sortie.worn`), `timeout` (`sortie.hold_ticks`, 4800), `mode` (PEACE),
  `gone` (target out of sight `sortie.idle_ticks`), `not_attackable`, `order_dropped` (DF dropped the kill order 3 times while the
  target lives), `more_hostiles`, `no_squad`. Every event names squad, units, position and ticks.
- **Kept against the posture** (`apply_squad` returns early for `rt.so[k].keep`): only when the target was a lone harmless intruder
  at the order time (`reflex.lone_ids`, BUG-112); the sortie ends when the picture changes (`more_hostiles`: at once when the census shows a second or a dangerous hostile, after two looks when the reflex scan only lags), the squad is worn below
  `sortie.worn` or the target is dead; a sortie against a real enemy is not kept (the posture takes the squad back as before).
- **`not_attackable`**: members within 2 tiles of the target for `sortie.idle_ticks` (1200) with no new wound on it end the sortie;
  for a lone harmless target `reflex.ignore` clears the unit like a released harmless intruder (inside Kern+ too), so the lockdown ends by itself; a real enemy is only reported.
- `military.kill_lone(ids)` is the kernel's own kill order for BUG-112 (the best squad, kept).
- Config: `sortie.kill_near` 5 (0 = a station order only), `idle_ticks` 1200, `hold_ticks` 4800 (config/reflex.json,
  `fairplay.SORTIE_LIM`; siege `M.SO`). Existing test changed with its meaning: a position within 5 tiles of a hostile is now a kill
  order, a killbox id the manifest lacks is a kill order on the lone hostile.

## Not decided offline
- Whether DF drops a spent `squad_order_movest` from `squad.orders` on arrival (the code relies on `order_count` as before) and
  whether a `squad_order_kill_listst` on a unit DF does not treat as an enemy stays in the list or is dropped (`order_dropped`
  covers the second, `not_attackable` the first). Read-only live data: `SORTIE` events of the next sortie, `#squad.orders` and the
  wounds of the target (`#u.body.wounds`) at `go`, `arrived` and the abort.
- Whether `body.wounds` really grows when a soldier hits a unit (the attack test): with a field that never grows, a real fight
  next to the target would end as `not_attackable` after 1,200 ticks and clear a unit that is being fought (only for a lone
  harmless one, so the cost is small); the kern.log line says `ticks`.

## Tests
`tests/lua/test_m3_sortie.lua` (13; 12 fail on 32994bb, the wound control passes there): kill order within 5 tiles, arrival upgrade
and `done`, kept against a forced posture and `dead`, not kept for a group, `not_attackable` with `reflex.ignore`, wounds restart
the clock, `order_dropped`, `timeout` and `mode`, unreachable (walk groups), "no killbox" (one, two, none hostiles; `x,y,z`),
`kill_lone` (worn gate, running, out of sight), `more_hostiles`. `tests/lua/test_military.lua` (two assertions follow the new meaning).

Related: BUG-065, BUG-111, BUG-112
