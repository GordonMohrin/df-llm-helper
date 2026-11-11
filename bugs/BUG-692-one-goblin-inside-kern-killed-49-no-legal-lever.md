# BUG-692 One goblin inside Kern+ killed 49 of 69 citizens: no legal lever (sortie, uniform, kernel kill order all refused for unequipped squads)
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-11, Run 16d i4 Trumpetrealms y461 winter, INVASION 38 (main 414d2ea, rounds 35-44): FR-BUGS 'Sortie wird als DECISION angeboten, ist aber nicht ausfuehrbar', STAND 01:07-01:16 'kein Eingriff moeglich'
Module: `lua/dfllm/military.lua` (`inside_set`, `inside_override`, `kill_inside`, `kill_lone`, `squad.sortie`, `fight_free`), `lua/dfllm/reflex.lua` (`inside_step`, `ack_step`), `lua/dfllm/care.lua` (`deaths_recent`)

## Actual
- events.jsonl / kern.log (r16d4): ARRIVAL 'invasion 38' at 186184618, BREACH (gate_fail) at 186186995. Goblin 32544 (size 6924, 'harmless lone inv' by `reflex.harmless`) inside Kern+: 186192509 'kernel kill order refused: squad A worn 0% < 80%', 186241409 (43.8 days of BREACH) the same. At 186243128 it stood in the refuge shaft 84,111,135 and 'killed a citizen: a wild danger from now on'; pop 69 -> 20: deaths 21 -> 33 -> 42 -> 48 within ~1,200 ticks (186243126-186244359), the rest later.
- `squad.sortie A/B/C` x3 (186197392-186197572, 186245625): 'not equipped: 0 of 3 hold weapon + body armor (free: 2 weapons, 6 armors)'; `squad.uniform` x2 (186197707): 'not allowed in BREACH' (BUG-674 opened it for an animals-only BREACH only). Three DEATHS_3PLUS interrupts (186190409, 186244959, 186254699) each ended in 'kernel applied its default: clock 30 t/s, alert: Tiefe+, recall: 20 in ...': the same lockdown, nothing else. 4-13 soldiers, `squad.sortie` offers (DECISION 'send squad A (3 soldiers)') that no command could carry out.

## Root cause
- `military.lua` `unfit_text` (BUG-510) refused every sortie of a squad under UNFIT_PCT (30 %) fit in a SIEGE / BREACH, whatever the enemy: 0 of 3 fit -> refused, for one goblin as for 14. The kernel's own kill (`kill_lone`) wanted `worn >= 80 %` and `unfit_text` too, and only for a harmless lone picture: a hostile with a kill mark (`kl`) is no longer harmless, nothing at all started a fight against it.
- `military.lua` `fight_free` (BUG-674) opened the squads screen only when `threat.assess` counted no invader: the goblin (an invader of INVASION 38) kept `squad.uniform` shut.
- `reflex.lua` `ack_step`: the DEATHS_3PLUS default only `engage`d the lockdown acts (clock, alert, recall).

## Fix
- `military.inside_set(K)`: BREACH, fresh census, the hostiles inside Kern+ (`ik` / `zn` 2, not cleared): 1..`INSIDE_MAX` (3), none a great danger, undead or building destroyer, the census list not cut; `killer` = a kill mark, `deaths` = citizens dead of a fight (killed, bled, siege, drowned, suffocated) within a day (`care.deaths_recent`; thirst and old age do not count). `inside_override(K, harmless)` = that picture + (a killer or a death, or `harmless`) + all squads' soldiers >= `INSIDE_RATIO` (3) per hostile.
- `squad.sortie` (verb): with the override an unequipped squad goes, but only on a kill order against the hostiles inside (`inside_only`: a position / killbox move, or a unit outside Kern+, is refused with the old 'not equipped' text); not kept against the posture (no `keep`: the order holds as 'sortie:').
- `squad.create / leader / add / uniform` (`fight_free`): open in a BREACH with that picture and a killer or a death (the squads must be manned and equipped).
- `military.kill_inside(K, by)`: every squad with members (not held by a siege sortie) gets a kill order on the inside hostiles (SORTIE event `inside=1`), squads whose target is on another walk group are skipped with the reason, 'running' on the second call. `kill_lone` (the harmless lone intruder, kill_hours) uses the same override (one squad that outnumbers them 3:1 goes at worn 0 %).
- `reflex.inside_step` (every `KILL_RETRY` 600 ticks in a BREACH) asks `kill_inside`; the unacked DEATHS_3PLUS default in a BREACH asks it first and names it in the LOCKDOWN text ('kernel applied its default (3 squads sent against ... inside): ...', `d.fight`), the lockdown still holds for the rest.
- `care.deaths_recent(K)`.

## Tests
`tests/lua/test_care_deaths.lua` (+1, deaths_recent), `tests/lua/test_bug692_inside_killer.lua` (5: sortie of unequipped squads against the killer inside only, squads screen with / without killer or death, kill_inside / running, no exception with 4 inside / too few soldiers / a SIEGE, equip hold), `tests/lua/test_bug692_693_traffic.lua` (3, siege traffic: reflex asks every 600 ticks; the DEATHS_3PLUS default names the sortie and keeps the lockdown; a goblin siege outside and a never-killing intruder inside give the same event trace, mode and lockdown with and without `kill_inside`).

## Squads without a leader (B, C)
DECISION 'squads [S2]: appoint a militia commander/captain (nobles screen) to lead squad B, C' (186253295) is `military.stuck`'s once-per-boot notice; the same log shows B and C later 'led by unit ...' (the kernel promotes), and `members(s)` / `squad_order` do not read the leader. In the code nothing makes a leaderless squad ignore an order, the refusals of this run are the unfit test and the BREACH rule above, not the leader. Not proven live: whether DF itself ignores a station / kill order on a squad whose captain position is vacant.

## Live check
After the reload, in a BREACH with <= 3 inside hostiles one of which killed: kern.log 'reflex: BREACH with a killer inside Kern+: N squads sent against ...', SORTIE go `inside=1` for each squad, `squad.sortie` / `squad.uniform` accepted. Open: soldiers without kit fight with fists (the exception trades that for deaths, the 3:1 ratio is a judgement from one fort); unreachable targets (walk group) are skipped with the reason; `INSIDE_MAX` / `INSIDE_RATIO` are constants.
