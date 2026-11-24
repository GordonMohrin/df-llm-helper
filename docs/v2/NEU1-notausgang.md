# NEU1 P7: Notausgang (emergency exit) and Stage-1 player verbs (decision E5)

Package P7 of the Neuausrichtung (leitung/PLAN-NEUAUSRICHTUNG.md). Success criterion of the plan: **0 log lines
"kein Befehl moeglich" while dwarves are dying**. Offline, live-untested.

## Old decision

"Kernel does everything, the LLM plans yearly, tactics forbidden." The player had about 40 verbs, none of them for the
situations in which the Run 16 players wrote "kein Befehl moeglich": a thirsty patient (16c y386/y390), one goblin
killing six citizens inside Kern+ while `squad.uniform` / `lever` answered `not allowed in BREACH` (16b y461), an
uncleaned fish stack and no labor verb (16a), a hospital without a table (16a y421), a lever link that waited 446 days
(16d). And where a kernel function existed (`act.zone_remove`, `act.link_lever`, `act.labor_set`, ...), the player
could not reach it, and a reconcile loop of the kernel would have undone the change anyway.

## New behaviour

One new kernel module **`player`** (lua/dfllm/player.lua, every 1200 ticks, not critical) and one small library
**`util/hold.lua`**. Two rules, no special cases per situation:

### Rule 1: the emergency exit (Notausgang)

Once a game day the module reads the state document the kernel already builds (`K.view()`) and the mode. A
condition is critical when

| key | reading |
|---|---|
| `inside` | mode BREACH, or the lockdown's quiet clock waits for a hostile `inside` (`alarm.qw`) |
| `gate` | mode SIEGE or BREACH and a manifest bridge reads `down` |
| `thirst` | `water.patients` > 0 and `water.thirst_max` >= `player.thirst` (50,000) |
| `deaths:<cause>` | `player.deaths_n` (2) citizens died of the same cause (care `died_y`, old age and `other` excluded) within `player.deaths_days` (14) |

A missing key counts as not critical (fail closed: nothing is unlocked on missing data). A condition that holds
`player.exit_days` (1) game days in a row (deaths: at once) **opens** the exit:

- event **`EMERGENCY` (class A, wakes the player at once, in `wake.URGENT`)** with the causes, the unlocked verbs and
  the tick the window ends; again when a new cause joins;
- state `emg` = `{o: 1, why, left}` (days left) while open; `brief`/`status` print one `NOTAUSGANG` line;
- the clock is clamped (arbiter asks `player.clock`, like the reflex lockdown clamp; `player.slow`);
- the **tactical verbs** below work, for as long as a condition holds plus `player.grace_days` (3); then
  `EMERGENCY_END` (C, `d.doors` / `d.burrows`), the stationed squads are released to the kernel, the tactical holds end,
  and the player's tactical changes are **undone** (BUG-812/814): every door `door.lock` locked that was open before his
  first `door.lock` is unlocked; every burrow member `burrow.unit` added or dropped gets its membership from before his
  first change back (other members, e.g. pullers gate added meanwhile, are kept). Nothing the window unlocked outlives it.

Tactical verbs (`schema.VERB_EMG`, refused with `only while the emergency exit is open` otherwise):

| verb | what (the screen a human clicks) | act |
|---|---|---|
| `lever bridge=B want=up` | any mode while open: kern lifts the contract mode list of `VERB_EMG` verbs while `player.open()`; gate's verb then takes only `up` (down stays PEACE: a sortie opens its own gate) | gate's own pull |
| `squad.station squad=A pos=[x,y,z]` (`release=true`) | squads screen > station | `military.hold_order` (tag `player`) |
| `squad.sortie` | unchanged (already any mode but DRILL) | - |
| `burrow.unit burrow=N unit=U on=true` | burrows screen > units (no hold, restored on close) | `act.burrow_units` |
| `door.lock door=ID on=true` | door sheet > forbid (lock held until close, unlocked on close) | `act.door_forbid` |

### Rule 2: the kernel never undoes a player verb (holds)

Verbs marked `hold` in the contract (`schema.VERB_HOLD`, `contract.VERB_HOLD`) leave a **hold** on every object their
act calls touched. The kernel sets `in_verb` while a verb handler runs; act calls made then are never held and are
noted; after a successful hold verb `player.hold_acts` records the keys of those calls (`util/hold.lua` `H.keys`):

| act | key |
|---|---|
| `building_remove` | `bld:<id>` and the removed footprint `area:z:x1:y1:x2:y2` (not for a Door / Hatch, BUG-815) |
| `zone_assign` | `zone:<zone>` |
| `labor_set` | `labor:<unit>:<labor>` (BUG-813: per labor) |
| `medic` | `labor:<unit>:medic` |
| `work_detail` | `wd:<unit>:<detail>` (BUG-813: per detail) |
| `appoint` | `office:<code>` |
| `link_lever`, `cancel_link_job` | `bld:<lever>` |
| `door_forbid` | `bld:<door>`; a kernel **unlock** (`on=false`) is never refused (`H.query`, BUG-812) |
| `burrow_units` | none (BUG-814: gate's level-triggered lever-room pullers must win in BREACH) |
| `quickfort`, `zone_place`, `sand_zone`, `fish_zone`, `water_zone`, `drink_pile`, `tool_pile`, `hospital_restore` | `tile:x,y,z` (query only: refused inside a held `area`) |

Every act call outside a verb asks `player.held(keys)`; a held object is refused with `held by the player (<verb>)`,
one commands.log line, **no ACT_FAIL** (a kernel loop retrying it is no failure). This one gate replaces finding every
reconcile loop; the loops it stops are: economy's work-detail staffing and labor switches (only the held labor /
detail of that unit), water's Orderlies ladder (only if the player set that unit's Orderlies), its zone/hospital
redraw, economy's office replace (BUG-458), gate's stale-link cancel (BUG-546), reflex's lockdown **forbid** of a door
the player set, care's room assignment, runner/economy zone and quickfort placements on a removed footprint. Stage-1
holds last `player.hold_days` (28) game days; tactical ones last until the window closes (BUG-816: not a fixed tick
computed at the verb's time, which ran out while the exit was still open; bound `M.EMG_HOLD_MAX` = 400 days).
Fail safe: a hold may keep a door open, it never keeps one shut (unlocks pass), and it never stops gate's pullers.
The lever is not held by act: gate's own lever hold (BUG-236) already keeps a player's `down` in PEACE and ends it
on a threat (raising is never blocked).

### Stage-1 verbs (any time; `player.verbs`)

| verb | args | act | refused |
|---|---|---|---|
| `zone.remove` | `id` | `building_remove(id,'zone')` | not a zone |
| `building.remove` | `id`, `approve` | `building_remove(id,'building')` | a zone; a bridge, lever, depot, door or hatch without approve:true (BUG-815) |
| `labor.set` | `unit`, `labor` (mechanic, farm, cook, brew, herb, burn, furniture, clean_fish, hunt), `on` | `labor_set(unit,labor,on,true)` (both directions) | child, dead |
| `workdetail.set` | `detail` (the builtin tool details), `unit`, `on` | `work_detail` | other details |
| `lever.link` | `lever`, `target` (building id) or `bridge` (manifest name) | `link_lever` | not built, no mechanisms |
| `appoint` | unchanged (economy), now with a hold on the office | `appoint` | |
| `furniture.place` | `kind` (bed, table, chair, door, cabinet, chest, coffin, weapon_rack, armor_stand, statue, hatch), `pos` | `quickfort` build, one tile | quickfort placed nothing |
| `room.assign` | `zone`, `unit` | `zone_assign` | unit already owns a room |

No free digging, no item creation, no `dfhack lua`: every verb is one click of a vanilla screen.

## Config switches (config/baseline.json `player`, checked by `lint --config`, all new behaviour ON)

`exit` (true), `exit_days` (1, 0..30), `grace_days` (3, 0..60), `thirst` (50000, 10000..200000), `deaths_n` (2, 1..20),
`deaths_days` (14, 1..120), `slow` (true), `verbs` (true), `hold` (true), `hold_days` (28, 1..400).
`exit=false`: no window, the tactical verbs are refused, `lever` is PEACE only again. `hold=false`: nothing is held.

## Deliberately not done

- **No pause.** The window clamps the clock; the dead-man pause is P3's.
- **No new sortie rule.** `squad.sortie` keeps its armour/odds refusal (P4 changes the sortie).
- **Lever down outside PEACE stays refused**, also in the window (fail safe; the sortie lowers its own gate).
- **A removed footprint stops only creators whose origin tile lies in it** (`tile:` of the quickfort / zone `pos`): a
  kernel blueprint whose origin lies outside the footprint but covers it is not stopped.
- Holds live in the player module's site data (`m.player`, at most 200, oldest dropped); a disabled or missing player
  module holds nothing and opens nothing (the kernel then behaves as before).
- `furniture.place` holds nothing (the kernel does not remove furniture); no material choice (quickfort's default).
- No free dig, no channel, no item or unit edit, no new `run` allowlist entry.
- `military.release` frees a squad on close only while its order is still the player's (siege's own hold stays).

## Verification fixes (retry 1, BUG-812 to BUG-816)

| bug | defect of the first version | fix | test |
|---|---|---|---|
| BUG-812 | `door.lock` could leave a door forbidden for good: after the close no verb unlocks it, and a player hold on a door reflex had forbidden made reflex's `open_doors` unlock refused quietly (then dropped from `st.doors`, never retried) | `util/hold.lua` `H.query`: a kernel `door_forbid(id,false)` is never held; `player` records each door's state before the first `door.lock` (`emg.dr`) and unlocks the ones that were open on `EMERGENCY_END` | tests/lua/test_neu1_door_restore.lua (real reflex lockdown + player; fails without `H.query`) |
| BUG-813 | hold key `labor:<unit>` blocked every labor_set / medic / work_detail on the unit for 28 days (care's doctor, water's Orderlies) | keys `labor:<unit>:<labor>`, `labor:<unit>:medic`, `wd:<unit>:<detail>` | test_neu1_notausgang (Orderlies, other labor pass), test_neu1_acts (real kern: care's `medic` passes) |
| BUG-814 | `burrow.unit` held the whole burrow; gate's BREACH pullers blocked; nothing restored membership after the close | no burrow key; `emg.bu` records each (burrow, unit) membership before the first change, restored on close (kernel-added members kept) | test_neu1_notausgang burrow test |
| BUG-815 | `building.remove` of a door/hatch in any mode, area hold then kept seal/runner from re-placing it for 28 days | door and hatch need `approve:true` (`A.REMOVE_GUARDED`); a removed Door/Hatch leaves no `area` hold | test_neu1_notausgang util/hold test |
| BUG-816 | (found by the new door test) a tactical hold ended at the grace end seen at the verb's time, i.e. 3 days later even while the exit stayed open | e=1 holds last until close (bound 400 days) | test_neu1_door_restore (the door stays held through the lockdown) |

## Open risks

- The `gate` condition (manifest bridge `down` in SIEGE/BREACH for a day) also fires on long intake waves and sortie
  lowerings, and a chronically thirsty patient keeps the window (and the clock clamp) open without an upper bound.
  Both are noise (a class A wake, a slower clock), not unsafe; `player.exit_days` / `player.slow` are the knobs.
- A door the player **unlocked** during the window that someone else had locked stays unlocked after the close
  (fail open on purpose: an entrance must never end up shut; reflex re-forbids it at the next lockdown).
- `burrow.unit` on a gate lever room is overwritten by gate's next pullers step (by design: the pullers win).
- Live-untested; the restore runs in `player.step` (once a game day), so it lags the close by at most a day.

## Live-Erwartung

1. When a patient's thirst stays >= 50,000 for a game day, `events.jsonl` holds an `EMERGENCY` line (cls A) with
   `why` containing `thirst`, and within 60 s the player's log shows a `water.unstick` / `well.retire` /
   `burrow.unit` / `door.lock` command instead of "kein Befehl moeglich".
2. In a BREACH that lasts a day, `lever bridge=<B> want=up` answers `queued`/`already up` (not `not allowed in
   BREACH`), and `squad.station` answers `ordered`; after the BREACH plus 3 days an `EMERGENCY_END` follows and the
   same `squad.station` is refused `only while the emergency exit is open`.
3. A `labor.set unit=<u> labor=clean_fish on=true` (or `workdetail.set`) stays in force for 28 days:
   commands.log shows `held by the player (labor.set)` for economy's later `work_detail`/`labor_set` on that unit and no
   ACT_FAIL for it.
4. `zone.remove id=<z>` on a zone the kernel drew (dfllm-sand, a water zone) is not drawn again on that place within
   28 days (no new zone of the kind there in `inspect what=water_sources` / the zones screen).
5. Across a run with the exit on, no player log line says "kein Befehl moeglich" next to a DEATH / PATIENT_DYING.
6. Every `EMERGENCY_END` after a `door.lock on=true` shows `d.doors` >= 1 and the door sheet of that door reads not
   forbidden afterwards; after a lockdown that ended while the exit was open, commands.log has `act.door_forbid ... false`
   by reflex with result `ok` (never `held by the player`).
7. While a player `labor.set` hold is active on a unit, care's `act.medic` and water's `act.work_detail Orderlies` on that
   unit appear in commands.log with `ok`, not `held by the player`.
