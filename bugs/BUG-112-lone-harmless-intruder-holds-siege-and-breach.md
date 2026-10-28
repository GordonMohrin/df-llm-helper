# BUG-112 A lone harmless intruder holds the fort for weeks: SIEGE 48 days (threat's quiet clock counts every invader), BREACH 26 days (the confinement limit runs in PEACE/ALERT only), and the kernel never kills it
Status: fixed in the M3 commit (offline, live-untested): in SIEGE/BREACH a lone harmless intruder has a clock of its own: the
kernel orders the kill itself inside Kern+ (`confine.kill_hours`), asks with the ready command (`confine.ask_days`, DECISION_NEEDED
`kill_lone_intruder`), and clears the unit at `confine.max_days` with the soldiers at their stations; defaults chosen safe, every
part has a switch
Severity: high (wrong decision: the whole fort confined or in lockdown for weeks by one harmless unit, a patient suffocated,
HUNGRY 19, projects stalled)
Found: 2026-10-28, Run 14 (Trussroads) y640 (note 77: lockdown 48+ days, goblin 39156 "harmless", 70 tiles from the entrance, 13
from a citizen) and y707 (notes 94, 96, 97: goblin 39230 in Kern+, BREACH 17+ days, "der Kernel muss ihn toeten" - Gordon 28.10.)
Module: `lua/dfllm/reflex.lua` (`lone_step`, `confine_step`, `calm_picture`, `far_scan`, `quiet_block`), `lua/dfllm/threat.lua`
(`assess`), `lua/dfllm/military.lua` (`kill_lone`), `lua/dfllm/sense.lua` (`ik`)

## Actual
- Note 77: DEFCON 2 for 48+ game days (the config limit is 10), `quiet clock: a hostile is near`; `squad.sortie` refused with "no killbox".
- Note 94: one goblin inside Kern+, BREACH, lockdown 18.5 of 10 days "past the limit", civil alert, a patient outside the alert burrow.
- Note 96(d) / 28.10.: a lone harmless invader inside Kern+ must be killed by the kernel after X hours of BREACH.

## Cause (proved from the code at 32994bb)
1. **The confinement limit stops at the fight modes.** `confine_step` (reflex.lua:2038) releases only through `calm_picture`
   (:1931), whose first line returns nil unless `FAR_MODES[K.mode()]` (:575, `{PEACE, ALERT}`); `far_now` (:696) and so the
   quiet clock past far invaders are PEACE/ALERT only for the same reason. `offer_step` (:1996) asks `K.mode() ~= 'ALERT'`.
   So in SIEGE and BREACH nothing of BUG-065 applies: the lockdown has no limit and no offer.
2. **The mode FSM waits for the last invader on the map.** `threat.assess` counts an invader at any distance (`counts`,
   threat.lua:123 `if e.k == 'inv' then return true end`) and `a.quiet` needs `a.inv == 0` (threat.lua:195); `siege.decide`
   leaves SIEGE only on `quiet_for` (siege.lua:733) and BREACH only on `quiet_for` or a sealed fort (:735-736). A lone goblin that
   stands 70 tiles away keeps the SIEGE (note 77) for ever; a lone harmless one in Kern+ keeps `a.inside > 0` and the BREACH.
3. **A cleared harmless intruder counts again inside Kern+.** `far_scan` (reflex.lua:643) drops a cleared unit from the list when
   `r.how == 'inside'` (BUG-065's rule, meant for the lockdown), and `threat.assess` takes `a.inside` from the raw `h.inside`
   (threat.lua:147), `quiet_block` (reflex.lua:1863) too. So even a released unit would end no BREACH.
4. **Nothing kills it.** The kernel gives kill orders only for hostiles in a killbox (siege.lua `kills`, military.lua `kill`
   with `valid_targets`); a unit in Kern+ outside every killbox gets none, and `squad.sortie` set a station order only (BUG-113).

## Fix
- `reflex.lone_step` (every 100 ticks, SIEGE/BREACH): the picture "every counted hostile of the fresh census is harmless
  (`harmless`: BUG-065's rule, plus an unconscious one), at most `confine.lone_max`, no list cut, no great danger or undead"
  has a clock (`m.reflex.lone`, persisted; a gap in sight up to 1,200 ticks keeps it, anything else restarts it):
  * `confine.kill_hours` (24 game hours = 1,200 ticks; 0 = off): BREACH, the unit inside Kern+: `military.kill_lone` orders the
    best squad to kill it (a squad order of the squads screen; refused below `sortie.worn`, out of sight or unreachable), retried
    every 600 ticks, one that started at most once a game day and `KILL_MAX` (5) times per picture;
  * `confine.ask_days` (3; 0 = off): DECISION_NEEDED `kill_lone_intruder` (A, util/cadence: again only for another unit or a
    changed state of the kernel's order) with unit, position, squad, the ready `squad.sortie` command and `kill` = running or why
    refused; wake hint `wake.lone_hint`;
  * `confine.max_days` (10) with `confine.siege_release` (true): with more than half of the soldiers (at least one) at their
    stations the unit is cleared (`far.hl` and the new `far.ig`: stays cleared inside Kern+ too; `threat.assess` subtracts such
    units from `inside`, sense marks the entries `ik` = inside Kern+ itself), the lockdown ends (LOCKDOWN_END cause `limit`) and
    the mode falls back by its own rules: quiet clock 2,400 ticks, RECOVERY, PEACE.
- State: `alarm.ln = {age, n, rel?, kill?}`, status/brief `lone harmless intruder x1 for 4.0 d, released in 8.0 d; kernel kill order: ...`.
- Config (config/reflex.json `confine`, `fairplay.CONFINE_LIM`): `ask_days` 3, `kill_hours` 24, `siege_release` true; `max_days` 0 or
  `siege_release` false switch the release off, `kill_hours` 0 the kill, `ask_days` 0 the question.
- Not changed: a group (more than `lone_max`), a unit of adult size, a great danger, undead, a building destroyer, a large
  predator, a flier, soldiers off their stations, a fort without soldiers: all keep the old behaviour (SIEGE/BREACH until the
  enemy is gone). A real invasion of 20 goblins, and a fort of 5-7 citizens, are pinned by tests.

## Not decided offline
- The live size of 39156 / 39230 (`sz` in `alarm.by`, status `size N` / `size unknown`): a unit of unreadable or large size is not
  harmless and none of this applies. If it is, the race token goes into `confine.harmless_races` or `harmless_size` is raised.
- Whether the kernel's kill order makes the soldiers fight: BUG-113's `not_attackable` abort and SORTIE events answer it.
- Whether 24 game hours is the right wait: it is config.

## Tests
`tests/lua/test_m3_lone.lua` (10; 8 fail on 32994bb, the config-off test and the 20-goblin regression pass there as they must):
the BREACH fixture of note 94 (kill after 600 ticks, one question with the ready command, release at the limit, LOCKDOWN_END
limit, RECOVERY and PEACE, the cleared list persisted), the SIEGE fixture of note 77, a real invasion, an adult-sized goblin,
soldiers off their stations, a fort without soldiers, a refused kill order, the cap of one kernel order a day and five a picture, a gap in sight, a child. `tests/test_m3_files.py`.

Related: BUG-065, BUG-087, BUG-111, BUG-113, BUG-114
