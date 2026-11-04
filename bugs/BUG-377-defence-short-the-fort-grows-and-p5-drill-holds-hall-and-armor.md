# BUG-377 the year plan lets the fort grow while the defence is short; phase P5 'waits for drill' holds the hall and the armor
Status: fixed (offline, live-untested); open: whether the kernel's own gates (R2 cap) should hold the same line without a plan
Severity: critical
Found: 2026-11-04, Run 16d (Plankscale, i4, `runs/run-16d/FR-BUGS.md` "FORT GEFALLEN y382"), kernel main ec9bd8e
Module: `dfpilot/plan.py` (propose, check, new defense_gaps / defense_on / defense_cap / defense_order / defense_gate)

## Actual
Plankscale (r16d-woodmill-site97) fell in y382: two goblin sieges, pop 66 -> 1 (22 then ~40 lost, 0 attackers killed; events
`SIEGE_END lost 22 killed 0`, `DEATHS_3PLUS` 11 in a day). Every cause was known for a year and the plans went on:
- the refuge was dry at every siege (`REFUGE_FAIL Tiefe+: no drink (drink 53<64, 1 well, none wet)` x20, R0 refuge_dry);
- 6 traps on the attacker paths (state `ready.audit.min_traps` 0, `traps n 6`), readiness R2 wants 30;
- soldiers in worn 30-55 % armor (`mil.worn` 38, kit armor 0), no ore (`stock.ore 0`), the explore digs all dig_lost / stalled;
- state `phw {"wait": ["squads 3", "drill", "ready 1"]}`: phase P5 waited for a drill that needs R1 (audit, bypass) for ten
  years; the trap hall (fortcore stage 4) and the iron/steel kits are P6 deliverables (P6 needs approval), so they were never drafted;
- the plans y377-y382 (`runs/run-16d/plan-y377.json` ...) drafted refuge_beds, explore x2-x4, bedrooms, tavern, temple, dining;
  `policy.pop_ceiling` stayed 100 (the R0 cap) and the fort grew 7 -> 66 (migrants, y372-y381) with nothing to defend it.

## Root cause
`plan.propose` (plan.py, builds from the phase deliverables `cur..target`) takes the traps from `_traps.draft` only for
`target >= P5` and only the door/bridge lanes; the hall (`fortcore stage 4`), the armor and the population have no link to the
fort's actual defence. `policy.pop_ceiling` was `min(level_cap, ...)` = 100 at R0 whatever stood (plan.py `cap =` in propose,
the line before `pop = ...`). The phase list (`plans/year1.json`) puts the hall and the kits in P6, behind P5's drill, so a fort
stuck at P5 for R0 reasons never got them.

## Fix
- `plan.defense_gaps(state)`: the holes, named: `refuge_dry` (readiness R0 blocker), `traps 0` (`ready.audit.min_traps` 0, an attacker
  path without one armed trap; readiness R2's 30 stays the kernel's gate, not a reason to stop growth; or no audit and no trap in
  state `traps`), `armor worn N %` (soldiers, `mil.worn` under
  `DEFENSE_WORN` 60) or `armor 0` (kit with no armor). `defense_on(state, target)` applies them from P3 (REFUGE_PHASE), for 20+
  citizens, not while the fort rebuilds.
- `propose` while gaps stand: `policy.pop_ceiling` = the citizens now (at least 20, never above the level cap; readiness reads it
  as the `plan` ceiling, so no migrant wave is invited past what the fort can defend); `_traps.draft` runs as if at P5; the hall
  `fortcore stage 4 @same` is drafted when a fortcore stands in the plan history, no breach parked it, stage 1 is dug and stage 4 is
  not applied or drafted (the P6 deliverable, without P6's approval and without the drill); `defense_order`: traps and the hall go
  ahead of the growth builds (behind the seals, the refuge's pieces - beds, drink store, stage 3 - and the water/food builds that
  already came first); `bar:iron` first in trade.want for an armor gap (the depot of BUG-368 and the explore draft already follow
  ore_goal); notes: `BUG-377: defence short (...): pop_ceiling N ..., phase P5 waits for squads 3, drill, ready 1: the P6 hall is
  drafted all the same`. The refuge drink store itself was already first (refuge_drafts, FR-69).
- `plan check` warns (`defense_gate`): pop_ceiling above what the fort has, no hall/traps build in the plan, no iron in trade.want.
  Warnings only: the draft passes its own check; a player who raises the ceiling by hand is told once.
- Not changed: the phase list, the R2 cap, the kernel's famine hold. The orders library `library/military` is not forced into the
  plan (economy imports it itself once a forge stands; importing it earlier only adds stuck orders).

## Tests
tests/test_bug377_379_defense.py (gaps named; propose holds the ceiling, drafts the hall + traps first with the P5 note; no gap =
unchanged draft; hall not twice / not on a digging core; check warnings). Fail on ec9bd8e.

## Live check
A fort at P3+ with 20+ citizens, refuge dry, `ready.audit.min_traps` < 30 or worn < 60 %: `dfllm plan propose` prints
`BUG-377: defence short (...)`, `policy.pop_ceiling` = the citizens, `fortcore stage 4 @same` and `traps` before bedrooms/tavern/
temple; POPCAP `max-pop N (plan)`; once the gaps close, the next propose raises the ceiling again.
Risk: a fort whose kernel sends no audit `min_traps` counts only `traps n == 0`; `bar:iron` in trade.want does nothing without a
depot (BUG-368 drafts one).
