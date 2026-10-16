# BUG-028 BREACH/SIEGE lock soldiers and civilians without water behind raised inner bridges; `dfllm stop` leaves popups and fps unattended
Status: fixed (offline, live-untested): rescue, BREACH -> SIEGE, raise hold, SUPPLY_OUTSIDE (Claude, 2026-10-16); `dfllm stop`: FR-68 (guard)
Severity: critical (13 people trapped 23+ days, 2+ died of thirst, recruits trapped again after the kernel restart)
Found: 2026-10-16, Run 10 fort Erushthak Handlelock (region2-site97), y419 spring/summer, siege of 48 goblins in front of O1, Claude playing
Module: `lua/dfllm/siege.lua` (apply: BREACH wants every bridge up, BREACH ends only by `quiet_for`), `lua/dfllm/military.lua` (stations), `lua/dfllm/gate.lua` (BLOCK_WAIT), kern `stop`

## Actual
1. BREACH (entered after GATE_FAIL T+900 during the ambush) wanted B1, B2, O1 up every round and left only via RECOVERY on 2400 quiet ticks. 47 goblins stayed in view for 60+ days, so the mode never ended. The verb `lever` and any 'down' are refused in BREACH.
2. Stations: `stations.melee` (130,128,122) and `stations.gallery` (123,123,122) lie on the corridor side of B1/B2, `stations.b2` (138,127,122) east of B2. Squads 100/101 and 11 civilians stayed between O1 and B2 when B1/B2 rose. They had no water: thirst up to 74090, 2 recruits/planters died ('found dead, dehydrated'). The drink stock of 3093 units lay on the surface outside O1 (stockpile (102..106,119..123,124)), the Kern group held 737 (60 days).
3. Rescue by hand: `dfllm stop` (arbiter restores fps 500 and a death popup 'has been found dead, dehydrated' froze the simulation; `popups:erase(0)` clears it, SELECT does not), then `lever pull --id 17587 --priority` (B2) and `--id 17867` (B1): the 13 walked east, thirst fell from 73560 to <55000 within seconds.
4. After `dfllm reload` (mode BREACH again) the kernel raised B1 and B2 again at once, trapping 10 recruits again; I kept the kernel stopped, a Lua repeater clears popups, B1/B2 stay down, O1 up (sealed: `inspect entrances` no route).
5. The same session found BLOCK_WAIT forced raises (BUG-027).

## Expected
- Before cutting a group off, the gate checks that nobody of the group needs to cross and that the group has drink/food; BREACH falls back to SIEGE once the gates are up and nothing is inside; inner bridges may be lowered when O1 is sealed and a group is thirsty (> 30000).
- Stations and drink/food stock on one side (the Kern); an alarm `SUPPLY_OUTSIDE` when the main drink stock lies outside the lockable area.
- `dfllm stop` keeps a minimal popup dismisser and an fps clamp, or refuses while a lockdown is active.

## Workaround in the live fort
Kernel stopped, `pw_popups` repeat-util erases popups, fps 30, B1/B2 down, O1 up. `require('dfllm.gate').BLOCK_WAIT = 10000000` after any reload.

Related: BUG-027 (bridge crush), BUG-013/014, POSTMORTEM-run9-test-siege

## Cause
- `siege.apply` in BREACH wanted every manifest bridge up on every pass, and BREACH had one exit only: RECOVERY after
  2,400 ticks without a visible hostile (`quiet_for`). With 47 goblins in view that never came; the contract had no
  BREACH -> SIEGE transition.
- Nothing looked at the walk groups the raised bridges create: the SIEGE timer raised B1 at T+450 whoever stood
  between O1 and B1, BREACH raised B2 the same way, and gate refused every 'down' in SIEGE/BREACH/DRILL and during a
  lockdown. The thirst only reached economy's supply alarm (`DECISION_NEEDED thirst`), which cannot open a gate.
- seal's CUTOFF is turned into a class B `SEAL ... shut out by a raised bridge` in the gated modes (by design: the gate
  raises on purpose), so the stranding never woke anybody either.
- The stock: 3093 drink units on the surface stockpile in front of O1, 737 in the core; no check compared the stock
  inside the lockable area with the whole stock.

## Fix (Claude, 2026-10-16)
- **(a) rescue** (`siege.lua`, every 100 ticks in every mode but DRILL/RECOVERY): citizens (soldiers and recruits
  included) with thirst or hunger > 30,000 on a walk group without drink / food (`seal.groups`: citizens, stock groups
  and hostile groups read in one go, BUG-021) get the inner and core bridges on the shortest way to a group with the
  stock lowered (`seal.sides` per raised bridge; never an outer bridge), once every outer bridge is up, seal's entrance
  check after the last bridge move says no route (`groups().sealed`, a fresh check is asked for otherwise), no hostile
  is inside and none stands on a group to be joined. gate takes `want(b, 'down', 'rescue')` for an inner/core manifest
  bridge in SIEGE/BREACH and during a lockdown (its 30-tile hostile guard and the BUG-027 footprint rules hold; the
  lockdown pass and a BREACH entry leave that want alone; the pulls are gate's usual ones, lever burrow included). The
  bridges go up again when every rescued citizen drank or ate (back under 30,000), stands in the civ alert's burrow or is
  gone, after 2,400 ticks, or at once when a hostile comes inside, onto the citizens' group or within 30 tiles of a
  lowered bridge (abort). STRANDED (A) `rescue`: `2 citizens on walk group 412 without drink (thirst 41000, hunger 0):
  lowering B2, B1 (outside sealed, outer gates up)`, then `done` / `abort`; `refused` says why not (`an outer bridge is
  not up`, `the outside is not verified sealed`, `a hostile on walk group N`, `no raised inner or core bridge leads to
  drink`). An open rescue survives a reload (persist `m.siege.str`).
- **(b) BREACH -> SIEGE** (`contract.TRANSITIONS`): once every outer bridge (and every inner one a rescue does not hold
  down) is up, the fresh entrance check says no route and no hostile is inside or on a citizens' group, for 600 ticks.
  SIEGE_START `siege again (sealed): breach over ...`; seal releases the refuge (the citizens may go back to Kern+).
- **(c) raise hold**: before siege first wants a bridge up (the SIEGE timer, BREACH), `seal.split` floods each side of
  the footprints to be raised (footprints blocked; the outward side of an outer bridge is the outside; it stops once
  only the rest of the fort still grows, so it costs the zones between the gates) and counts the census stock per part;
  a part with citizens (soldiers excluded: their stations lie there, (a) rescues them) and no drink or no food holds
  the bridges on its way to a part with both: STRANDED `hold` (no BREACH for a held bridge) until a hostile is within
  30 tiles of that bridge, then the raise goes ahead and STRANDED `forced` names whom it cut off.
- **(d) SUPPLY_OUTSIDE** (A, seal, util/cadence: once, again only with news after 28 days and 30 min): more than half of
  the drink or food stock (>= 20 units) lies outside Kern+ and the refuge; `d.days` = economy's stock days x the share
  inside. The state `alert.core_d/core_f` carries those days; `dfllm plan check` warns below 90 (`build a still and a
  barrel stockpile inside the core`); `inspect refuge` shows `supply`.
- **(e) runtime hotfix obsolete:** `require('dfllm.gate').BLOCK_WAIT = 10000000` does nothing since 0b0abec: gate has
  no BLOCK_WAIT and never forces a raise onto units except with a hostile within `gate.force_near`
  (config/reflex.json). The `dfllm stop` part is FR-68 (`lua/dfllm/guard.lua`, a72bf17).
- Open: the military stations (`stations.melee/gallery` between B1 and B2) are unchanged; the rescue covers the
  soldiers' thirst, a plan should still put their water on their side.
- Tests: `tests/lua/test_stranded.lua` (rescue with BREACH -> SIEGE and the raise afterwards, refused with O1 down,
  abort on a hostile in the zone, the raise hold and its forced end, no hold with nobody in the zone, SUPPLY_OUTSIDE
  and the core days; all but the no-hold guard fail on 0b0abec), `tests/test_cli_plan.py` (the core days warning).
