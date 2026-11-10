# BUG-671 PREDATOR sortie offers are stale when sent; a PREDATOR lockdown holds the clock at 30 t/s for days
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-10, Run 16a i1 Basementflew y460 (commands.log:9341, 9426; events.jsonl:16807-16816): a PERMIAN_DIMETRODON (31428, 8,897 cm3, reach 1) walked through the fort; every PREDATOR event offered `squad.sortie ... "unit":31428` and every send was `ERR unit 31428 is not in sight`; the unacked PREDATOR default (`clock 30 t/s, alert: Kern+, recall 7`) held the clock for days (player file: the lockdown throttles the clock to 30 t/s for days)
Module: `lua/dfllm/reflex.lua` (`unit_facts`, `M.last_seen`, `clock_step`, `ack_step`), `lua/dfllm/military.lua` (`squad.sortie`), `dfpilot/schema.py`

## Actual
- Three offers (5,67 -> 20,58 -> 43,49: 23 tiles in 2,030 ticks) were each invalid by the time the player agent sent them; the verb (BUG-519) refuses a unit that is not in the census now, and the census lists only units in sight. Sight is lost within seconds for a unit that walks through hidden tiles.
- The lockdown default of PREDATOR is `clock + alert`; the clock part stayed as long as the lockdown stood (a quiet clock of 2 days and the 10 day confinement limit, both restarted by every new PREDATOR default): 30 t/s instead of 250, a game year at 8x the real time.

## Root cause
`reflex.lua` `unit_facts` built the command for every `danger` / `inv` unit with no notion of how long it stays valid; `military.lua` `squad.sortie` has no memory of units seen a moment ago. Nothing bounded the clock half of a PREDATOR lockdown (`engage` re-added it with each default).

## Fix
- Offer discipline (`unit_facts`): the command is offered only for a unit in the census now and not out of reach (`rc ~= 0`; before: out of reach too), and the event carries `exp` = tick + `M.OFFER_TTL` (1,200).
- `reflex.last_seen(id)` (inside_scan keeps the place of every hostile it saw, pruned after 4 TTL): `{x, y, z, age, fresh, ttl}`. `squad.sortie` with a `unit` that is not in the census takes it while `fresh` and the unit is alive: kill order on the unit, `pos_target` the last place, reach check as before, and the sortie's own unseen clock (`sortie.idle_ticks`, 1,200) ends it cleanly (SORTIE abort `gone`). After the TTL it is refused with `the offer is stale (last seen N ticks ago ...), wait for the next PREDATOR/INTRUDER event, it carries a fresh command`; a unit never seen keeps the BUG-519 text; `move=true` is unchanged.
- Throttle (`clock_step`, each reflex step): a lockdown whose only cause is an unacked PREDATOR default (`why unacked:PREDATOR`, kinds only `unacked`), in PEACE / ALERT, with a fresh census showing nothing inside Kern+, releases its `clock` act after `M.PRED_CLOCK_DAYS` (3) game days: `acts.clock` removed, `hold.clk_off` set (persisted), `arbiter.hold`, LOCKDOWN_CLOCK (B) once. The civ alert, the recall and the doors stay. `ack_step` drops `clock` from a later PREDATOR default of the same lockdown. Anything inside Kern+, a siege or an army keeps the clamp as before.

## Tests
`tests/lua/test_bug671_sortie_offer.lua` (a fresh offer for a hidden unit goes and ends `gone`; stale / dead / never seen are refused with the reasons); `tests/lua/test_reflex.lua` (BUG-671 x3: `exp` and `last_seen`, no offer out of reach; the clock released after 3 days, said once, the second default brings the alert only; a hostile inside Kern+ keeps the clamp); `tests/test_bug669_671_f43_trade.py` (schema: `exp`, LOCKDOWN_CLOCK).

## Live check
A wandering predator in a fort with a sortie squad: PREDATOR carries `exp`; a `squad.sortie` sent up to 1,200 ticks later is `kill order on N (out of sight for X ticks ...)`; after that the stale text. With the PREDATOR unacked and nothing inside Kern+: `LOCKDOWN_CLOCK` 3 days after the lockdown began and `status` clock back to the mode's own speed while the alert stays.
Open: a unit that left sight for good is followed for 1,200 more ticks at most (one wasted march); 3 days and 1,200 ticks are judgements; the bound covers PREDATOR defaults only (INTRUDER / ARRIVAL lockdowns keep their clamp: an army is a different case); the bound runs in PEACE / ALERT only and touches no bridge, gate or refuge behaviour, so there is no new siege traffic test for it.
