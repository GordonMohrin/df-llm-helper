# BUG-907 An ALERT / RECOVERY / lockdown raise waits for walkers for ever: 'B1 not up after 132905 ticks ... never raised onto them'
Status: fixed (offline, live-untested)
Severity: high
Found: Run 17 i3 Orangering y469 autumn d30-31 and spring d66-67: ALERT, lone hostile, no ARRIVAL: GATE_FAIL `B1 not up after 132905 ticks ... blocked: soldier 26632 next to it (squad 99 on its way to its station 86,60,142), citizen 26661 moving 2 tiles from it, citizen 29130 walking onto it in 13 steps`; 8 kernel pulls cancelled for units walking toward it, DECISION gate_traffic #34301; raised only by the player's lever. y467 / y468 the same in PEACE with a lockdown (`B1 up waits: citizen walking onto it in 15 steps`).
Module: `lua/dfllm/gate.lua` (`M.bound_stage`, `holders`, `M.approach`, `control`, `new_epoch`)

## Cause
`holders()` outside SIEGE/BREACH/DRILL (`FORCE_MODES`/`TIMED_MODES`) has no force and no deadline escape: every crosser within `PATH_STEPS` 20 steps holds (`lim` nil), every unit within the 1-tile margin holds, movers within `RAISE_R` hold (BUG-543/758), and `M.approach` cancels a pending pull for any walker toward the footprint. The recall stream and the squads' marching keep that permanent; nothing but GATE_FAIL follows.

## Fix
`M.bound_stage(K, name, fp)`: in ALERT or RECOVERY while a hostile is in sight or a lockdown holds (`reflex.holding('gates')`), and in PEACE with a lockdown (the unforced raise of case B), the raise has a clock `r.bw` (first look in this mode episode, reset when the want is reached and by `new_epoch`). Stage 0 until `DEADLINE x CROSS_HELD` = 450 ticks: the old rules. Stage 1 (450..1500): `raise_movers` is not asked, crossers hold only within `CROSS_ESCAPE` (2) steps, the units beside the footprint (margin) still hold, `M.approach` cancels only for a unit within 2 tiles. Stage 2 (from `BOUND_FOOT` = 1500): only units ON the footprint hold (margin units, movers and every crosser with path > 0 are let go, `approach` cancels for none). A unit ON the footprint always holds (BUG-310; no deliberate crush: `GATE_FAIL` names him). Each stage emits GATE `state bounded` (`stage`, `waited`, `mode`) once, and kern.log. SIEGE/BREACH/DRILL and quiet PEACE keep their rules.

## Cost
After 450 ticks a walker more than 2 steps from the footprint no longer holds the raise, after 1500 ticks no walker does: a citizen who steps onto the footprint while the bridge moves (~100-300 ticks) is crushed, and citizens still outside are locked out by the raise (the recall stream is the accepted price; BUG-587/775/881 in SIEGE). A stream so dense that the 70+-tick pull never finds the footprint free is never crushed either: a unit ON it cancels the pull (GATE_FAIL, no force); from stage 2 those cancels do not count toward `gate.pull_cap` (else 15 cancels in a dense stream parked every lever for `giveup_wait` 7200 ticks, past the end of the stream). Units standing beside it are let go at 1500 ticks.

## Tests
`test_bug905_909_b1.lua` (ALERT, lockdown, ONE hostile 20 tiles out, first holders look at +9):
- three citizens crossing as a stream 3, 5 and 8 steps out and a soldier standing 1 tile beside B1: GATE bounded stage 1 at +477, stage 2 at +1530, pull +1530, B1 up (flip) +1611, 0 crushed, no GATE_CRUSH_RISK;
- the same with a citizen standing ON the footprint: B1 down after 3600 ticks, no pull, 0 crushed, GATE_FAIL `citizen 130 on the footprint`;
- RECOVERY with a lockdown: both stage events, B1 up, 0 crushed; quiet PEACE (no lockdown, no hostile) with a soldier beside it: no stage event, B1 stays down;
- cost: a recall stream (a citizen every 150 ticks, 27 ticks a tile, 41 citizens) with the hostile 20 tiles out: B1 up +1620, 0 crushed; a stream every 90 ticks (no gap for the 70-tick pull): 28 pulls queued and cancelled by the citizen on the footprint, no give-up, B1 up +4014 right after the last citizen passed (+3600 start), 0 crushed.
On main: the first test and the RECOVERY one fail (B1 never up while the soldier stands beside it).

## Live-Erwartung
An ALERT with a lone hostile (no ARRIVAL) and B1 wanted up: within the first ~450 ticks nothing changes (`B1 up waits: ...`), then `GATE bounded stage 1`, at 1500 ticks `stage 2` and B1 pulled and up right after unless somebody stands ON the footprint (then `GATE_FAIL ... on the footprint` as before). The `not up after 132905 ticks` GATE_FAIL for a bridge held by walkers disappears; no further pull is cancelled for a walker once stage 2 is reached (the `gate_traffic` count of cancelled pulls stops growing). NOT promised: that nobody is crushed after stage 2 (see Cost).
