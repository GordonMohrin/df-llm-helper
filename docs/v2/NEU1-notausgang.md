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
  `EMERGENCY_END` (C), the stationed squads are released to the kernel, the tactical holds end.

Tactical verbs (`schema.VERB_EMG`, refused with `only while the emergency exit is open` otherwise):

| verb | what (the screen a human clicks) | act |
|---|---|---|
| `lever bridge=B want=up` | any mode while open (down still PEACE only: a sortie opens the gate itself) | gate's own pull |
| `squad.station squad=A pos=x,y,z` (`release=true`) | squads screen > station | `military.hold_order` (tag `player`) |
| `squad.sortie` | unchanged (already any mode but DRILL) | - |
| `burrow.unit burrow=N unit=U on=true` | burrows screen > units | `act.burrow_units` |
| `door.lock door=ID on=true` | door sheet > forbid | `act.door_forbid` |

### Rule 2: the kernel never undoes a player verb (holds)

Verbs marked `hold` in the contract (`schema.VERB_HOLD`, `contract.VERB_HOLD`) leave a **hold** on every object their
act calls touched. The kernel sets `in_verb` while a verb handler runs; act calls made then are never held and are
noted; after a successful hold verb `player.hold_acts` records the keys of those calls (`util/hold.lua` `H.keys`):

| act | key |
|---|---|
| `building_remove` | `bld:<id>` and the removed footprint `area:z:x1:y1:x2:y2` |
| `zone_assign` | `zone:<zone>` |
| `labor_set`, `work_detail`, `medic` | `labor:<unit>` |
| `appoint` | `office:<code>` |
| `link_lever`, `cancel_link_job` | `bld:<lever>` |
| `door_forbid` | `bld:<door>` |
| `burrow_units` | `burrow:<name>` |
| `quickfort`, `zone_place`, `sand_zone`, `fish_zone`, `water_zone`, `drink_pile`, `tool_pile`, `hospital_restore` | `tile:x,y,z` (query only: refused inside a held `area`) |

Every act call outside a verb asks `player.held(keys)`; a held object is refused with `held by the player (<verb>)`,
one commands.log line, **no ACT_FAIL** (a kernel loop retrying it is no failure). This one gate replaces finding every
reconcile loop; the loops it stops are: economy's work-detail staffing and labor switches, water's Orderlies ladder
and its zone/hospital redraw, economy's office replace (BUG-458), gate's stale-link cancel (BUG-546) and lever-room
burrow lists, reflex's lockdown doors, care's room assignment, runner/economy zone and quickfort placements on a
removed footprint. Stage-1 holds last `player.hold_days` (28) game days, tactical ones until the window closes.
The lever is not held by act: gate's own lever hold (BUG-236) already keeps a player's `down` in PEACE and ends it
on a threat (raising is never blocked).

### Stage-1 verbs (any time; `player.verbs`)

| verb | args | act | refused |
|---|---|---|---|
| `zone.remove` | `id` | `building_remove(id,'zone')` | not a zone |
| `building.remove` | `id`, `approve` | `building_remove(id,'building')` | a zone; a bridge, lever or depot without approve:true |
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
- **Holds are in-memory in the area sense only for footprints of `quickfort` origins**: a kernel blueprint whose
  origin lies outside a removed footprint but covers it is not stopped.
- `furniture.place` holds nothing (the kernel does not remove furniture); no material choice (quickfort's default).
- No free dig, no channel, no item or unit edit, no new `run` allowlist entry.
- `military.release` frees a squad on close only while its order is still the player's (siege's own hold stays).

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
