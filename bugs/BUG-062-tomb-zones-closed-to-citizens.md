# BUG-062 Hundreds of tomb zones closed to citizens: no burials, 26-44 unburied citizens, ghosts 1 -> 30, "0 free" every round
Status: fixed in 2cca90e, 207163f (offline, live-untested; who closes the unassigned zones is not decided offline, the
fix does not depend on it and TOMBS_LOCKED answers it live)
Severity: critical (the dead of a fort lie unburied for years, ghosts break buildings and stress the citizens)
Found: Run 14 (Trussroads, unretired, region2-site90) y529-y531 and y577 (23.10.2026), from the game session's notes 48,
52 and 56 in bugs/RUN11-offene-bugs-und-FR.md (read-only Lua counts, kern.log, `inspect tombs`)
Module: `lua/dfllm/care.lua` (tomb_repair, free_zones, body_causes, finish), `lua/dfllm/sense.lua`, `lua/dfllm/act.lua`
(tomb_zone, unchanged), `dfpilot/schema.py`, `dfpilot/brief.py`

## Actual
- y529-y531: 163 tomb zones + 163 coffins, `0 free`, every care round `tombs: ... freed 20`; 26 unburied citizens (cause
  no_coffin), ghosts 1 -> 10, the brief `tombs 19 -> 0`.
- y577: 284 of 287 tomb zones `no_citizens = true` ("288 coffins, 0 free" with 0 coffins holding a real corpse: the lock
  itself blocked assignment, not an over-full crypt); 44 loose citizen corpses, 30 ghostly units while the brief showed 12.
  After the player set `no_citizens = false` 32 burial jobs appeared at once (entombed +1, free 0 -> 4), and 90 seconds
  later the flag stood true again.
- Nine ghosts had a tomb zone and a coffin, but their corpses lay in walk group 859 (an old surface battlefield) against the
  fort's 9: the burial never comes; the report called it `no_coffin`.

## Causes (from the code at f17e2b3; DFHack from the 53.x tree)
1. **entomb closes the zone it assigns.** DFHack `scripts/entomb.lua` `AssignToTomb` (lines 152-154) sets
   `tomb.zone_settings.tomb.flags.no_pets = true` and `no_citizens = true` ("Make tomb zone unavailable for automatic
   assignment to other dead units"). care calls `entomb --unit <id> --haul-now` for every unburied body with a usable
   zone (care.lua:1047), so every zone held by a dead citizen is closed by design. That is correct for an owned zone and
   wrong as a count of "free" ones.
2. **One shared act budget of 20 per run.** `tomb_repair` (care.lua:996 `local budget = c.tomb_acts_per_run`) spends it on
   removals, frees, assignments and, last, on the opening of the remaining free zones (1021-1024). The frees of stale
   owners (a dead owner without remains here, FR-41) and of zones over unusable coffins use up the 20 first: `freed 20`
   every round, the closed unassigned zones wait for the next round, and the next. With 163-284 zones that is years.
3. **A locked zone counted as a free tomb.** `free_zones` (care.lua:830) did not look at `no_citizens`; `r.tombs_free`
   (1122) fed the state (`care.tombs_free`), the coffin provisioner's slots (`q.free`), and body_causes' `no_zone` vs
   `no_coffin` (884). Four closed zones looked like four free tombs: no coffin was ordered (`short = 0`), DF handed no body
   to a closed zone, and the cause said "DF never gave it one".
4. **The ghost number came from the death record only.** finish counted `isGhost` over `p.dead` (care.lua:2804-2809), which
   holds at most 200 deaths care saw (remember_dead, 250-253): ghosts of an earlier run, of a reclaimed fort or of a
   death past the record were never counted (12 against 30).
5. **No cause for a body nobody can walk to.** `unreachable` (care.lua:893) compared the body with its coffin only; a body
   on another walk group got `no_coffin` / `no_zone`, a zone assigned to it and a coffin provisioned for it.
6. **Not a writer:** nothing in `lua/dfllm` writes `no_citizens = true`. In the DFHack tree the writers are entomb.lua:154
   and quickfort's `zone.lua:68` (only with `citizens=false`; `burial -c` passes none). `preserve-tombs`
   (preserve-tombs.cpp) only calls `setOwner` for the dead of a living owner; `preserve-rooms` switches zones off
   (`spec_sub_flag.active`), it does not touch the flag.

## Fix
- **Open pass on its own budget** (`tomb_open_per_run` 120, config/baseline.json `care`): after removals, frees and
  assignments, every standing unassigned closed zone over a usable coffin is opened (`act.tomb_zone open`, a flag write);
  a failed open counts against the zone (3 strikes, as before). An assigned zone stays as it is: it belongs to its dead
  (entomb closes it again).
- **Locked zones are no free tombs** (`free_zones(T, locked)`): `care.tombs_free`, the provisioner's `free` and the
  `zone_locked` cause (a body with free-but-closed zones only) count open ones; the closed ones left after a failed or
  budget-limited open are `care.tombs_locked` (state, optional), `inspect tombs` `locked`.
- **`corpse_far`** (`far_bodies`): a body that no one of the first three citizens can walk to (snapshot's `reach` hook,
  canWalkBetween; no hook: nothing is far; `far_check` 60 bodies a run): no zone is assigned to it, no entomb, no coffin
  counted for it (`prov.far`, `tombs` request), GHOSTS `d.far`, the hint "slab for corpse_far (another walk group, no
  coffin helps)". `unreachable` keeps its meaning (the body walks to the citizens but not to its coffin).
- **The ghost number** = the ghostly units: sense publishes the fort's own ghosts it meets in the hostile scan as
  `K.census.g` (`{tick, n, ids}`, CONTRACTS §6.5; the only module that walks the unit list), care counts them with the
  death record's, remembers the ones it did not know and logs it once (`care: 18 ghostly citizen(s) were not in the death
  record`). A census older than two days is not trusted.
- **TOMBS_LOCKED** (B, once per set of news, util/cadence): found closed (free = unassigned, usable, owned, off), what care
  opened, what is left, zones care opened that are closed again (`again_free`: nobody owns them; `again_owned`: an owner
  now, `by_entomb` of them care's own entomb), zones care freed that DF gave to another body (`churn`) and this run's
  frees by reason (`bad`, `stale`, `elsewhere`). `inspect tombs` adds `lock`, `locked`, `again`, `far_n`, `unusable`
  (unbuilt, bedroom, other_zone, occupied, zones != 1).
- RULES §7 GHOSTS row, CONTRACTS (TOMBS_LOCKED, GHOSTS far, state `care.tombs_locked`, §6.5), DESIGN §5.10.
- Safety: nothing runs in SIEGE/BREACH (tomb_repair stays off there, the verb forces it); a fort of 7 pays a handful of
  flag writes; at 80 the pass is capped (120 writes, 60 reach calls a run); a kernel reloaded with an old `m.care` finds
  the new fields missing and builds them; a reclaimed fort's zones owned by long-dead historical figures are freed
  (stale) and opened by the same passes.

## Not decided offline
- **Who closes an unassigned zone again** (the 90 seconds of note 52). The code above shows two writers (entomb for the
  zone it assigns, quickfort only with `citizens=false`); the rest must be DF's own assignment of a body to an open zone.
  Read live: `dfllm cmd inspect '{"what":"tombs"}'` -> `again.free` (zones care opened that stand closed and unowned: not
  DF's assignment, not entomb: look for a plugin or script), `again.owned - again.by_entomb` and `again.churn` (DF gave
  a zone care freed to another body and closed it), `lock.closed/free/owned/inactive`, `unusable` (why the coffins are no
  free tombs: unbuilt coffins explain a loop of freed-and-reassigned zones). The same numbers come in TOMBS_LOCKED
  (digest) and kern.log `tombs: removed ..., freed ..., opened ...`. If `churn` stays high, the freed zones lie over
  coffins that cannot take a body (unbuilt, bedroom): the coffins, not the flag, are the fix.
- Whether a closed unusable zone should stay closed so DF stops assigning bodies to it (not done: it would be a deliberate
  closing; decide with the `churn` numbers).

## Tests
`tests/lua/test_care_b3.lua` (the BUG-062 group: the 60 closed zones opened in one run, a failed open is no free tomb and
the body says `zone_locked`, closed again by owner with entomb apart, churn, why coffins are no free tombs, `corpse_far`
and no reach hook, the ghost number against `census.g`), `tests/lua/test_sense_ghosts.lua` (`census.g`),
`tests/lua/test_care_fr.lua` (the 'unreachable' case now walks to the citizens but not to its coffin),
`tests/test_care_b3_files.py` (events, state and inspect on the real kernel, config). Each new test fails on f17e2b3.
