# BUG-335 drawbridges crush our own people: soldiers on their way walk onto a bridge that is already rising
Status: fixed (offline, live-untested), review fix 2026-11-04: squads kept off a busy bridge, cross-z walkers; open: tiles a bridge swings over, foreign lever pulls
Severity: critical
Found: 2026-11-04, Run 15b Earthboat y385 autumn d18 (i3), Run 15 Guildcleans y379 spring d53 (i2)
Module: `lua/dfllm/gate.lua` (holders, control, crossers, busy), `lua/dfllm/military.lua` (core_up, apply_squad, restation)

## Actual
Earthboat (`r15-earthboat-site97`, events #7429-#7516): in SIEGE/BREACH B2 waited for squads 99-101 "on its way to its
station 55,80,135 / 62,82,138" (their route runs over B2) and STRANDED said `B2 raised although it cuts 2 citizens off`;
gate queued 30+ pulls that were each cancelled for a unit within 3 tiles walking toward it (kern.log `B2 up pull cancelled:
... walking toward it`). The pull of 155454069 (job 503344) was taken 66 ticks later with nobody within the margin, B2 moved
at 155454170 (`B2 moving up with citizen 21852 next to it`), GATE_CRUSH_RISK soldier 26910 on the footprint at 155454210,
and at 155454270 five soldiers died (BRIDGE_CRUSH #7504/#7506/#7509/#7512/#7514: 26614, 26965, 27052, 27057, 27080, last
seen on it at 57,81..82,138). Guildcleans (`r15-guildcleans-site97`): pull of B1 at 152875086 taken after 49 ticks, B1 moved
at 152875413 with nobody within the margin, BRIDGE_CRUSH #2628 soldier 26418 (last seen 1 tile from it).

Root cause: `lua/dfllm/gate.lua:1212` `holders` (b35af6d) looked only at where units stand (within MARGIN 1, a forced raise
only d 0), and the pending check in `control` (`:1767-1800`) cancelled only for a unit within MARGIN_DOWN 3 that came
closer (`M.approach`, not at all for a forced raise). DF moves the bridge the moment the puller finishes, and the move takes
~100 ticks: a soldier running toward it from 5-15 tiles out (outside every check) reaches the footprint while it moves.
Nothing looked at where the units are going.

## Fix
`M.crossers(fp, far)`: every unit of the census scan within PATH_R 24 tiles whose walk path (`unit.path.path`, the tiles DF
steps it onto next) enters the footprint within PATH_STEPS 20 steps. `holders` adds them to the units that hold a pull, in
every mode and for a forced raise too (like one on the footprint); so a pull is never queued while one walks onto the bridge,
and our pending pull is cancelled (the UI cancel) the frame one sets off over it (the pending check runs every frame). The
pull's own worker is excluded as before (BUG-141). The census pass reads the wide radius once (`around` PATH_R, cut to SCAN_R
for everything else: `narrow`), the frames between re-read the paths of those units. GATE / kern.log text: `soldier 26614
walking onto it in 4 steps`. An unreadable path is no path (fail-open: the old margin rules still hold).

## Tests
`tests/lua/test_gate_crush.lua` (2: a path onto B1 holds the raise, beyond 20 steps it does not; a taken pull is cancelled
when a soldier sets off over B1, not for its own worker), `tests/lua/test_siege.lua` (2: the forced SIEGE raise waits for a
soldier whose path crosses B1; a pending forced raise is cancelled for a citizen 6 tiles away). All four fail on b35af6d.

## Live check
Earthboat/Guildcleans in a siege: kern.log `B2 up waits for soldier N walking onto it in K steps` while squads cross, no
GATE_CRUSH_RISK / BRIDGE_CRUSH; the raise follows once the squad has passed. Watch GATE_FAIL blocked counts in a busy corridor.

## Review fix (2026-11-04, merged with BUG-342's fix15-gates)
Verifier: our own squads were never routed off the bridge (gate only waited for them: in Earthboat squads 99-101 on their way
over B2 would hold every SIEGE close until the pull_cap give-up, a breach risk); a station switch in the ~100 move ticks (the
inner station flips melee -> b2 the moment B2 moves, `core_up` read 'moving' as up) was unprotected; units on stairs/ramps
(another z) were never scanned; a unit that reached the footprint between two census passes was in no list.
- Live fact (read-only, main agent): `unit.path.path.x/y/z[0]` is the NEXT step (adjacent to unit.pos), the last entry equals
  `unit.path.dest`, and the path crosses z levels (stairs). The crossers rule rests on exactly that.
- `gate.busy(name)` (gate.lua:2664): a pull taken on one of its levers (ours or a foreign one), the SETTLE window after our pull
  left the lever, or moving. A pull nobody took is not busy (a unit setting off over the bridge cancels it: crossers).
- Military freezes a station switch across a busy bridge (military.lua:2171 `crosses_busy`, :2224 in apply_squad): a squad
  member and the new station on different sides of a busy footprint (`dfllm.stations.side`), or a member on it -> no move order,
  kern.log `squad N (A) to station x,y,z waits: bridge B2 is being pulled or moves`, military looks again every SO_EVERY (100)
  ticks while one waits. `core_up` (military.lua:1765) keeps its answer from before while a core bridge is busy and counts a
  gate want 'up' as up, so the inner station switches to b2 when the raise is wanted (the squads cross the lowered bridge and
  gate's crossers wait for them) instead of when it moves.
- `military.restation` (military.lua:3103): a soldier in `gate.holds()` whose path crosses the footprint (`units[].path`, new)
  to a station of his squad on the bridge's outer side (zone rank below its inner side) gets his squad a station on the inner
  side at once (STATION_MOVED why `cross`), so the raise does not wait for him until the give-up. Walking in (station inside)
  he is left alone: the raise waits until he is through. Not in INTAKE (the melee walk out to the killing field on purpose).
- Cross-z: the census pass also keeps the units within PATH_R tiles and PATH_Z 3 levels of the footprint (gate.lua:120, :937)
  for crossers only; their path steps onto the footprint hold the pull like any crosser.
- `crossers` returns a unit of the walker list standing on the footprint now as `path = 0` (the refresh frames between two
  census passes). A unit beside the footprint that also walks onto it is held as the crosser (holders: drop_own keeps it).

Tests (all fail on the merge base ce10642^): `tests/lua/test_gate_crush.lua` (2: a citizen on the level below whose path
climbs onto B1 holds the raise; crossers path 0 and gate.busy false/true/false), `tests/lua/test_stations.lua` (2: a station
switch over B2 with a taken pull waits and is given once B2 settles; a soldier walking over B2 to his outer station gets an
inner one, STATION_MOVED cross, walking in he is left alone).

## Open
- A unit that gets a path after the lever was pulled for a reason military does not set (a new job, a player's squad order)
  in the ~100 move ticks is still unseen: the pull cannot be taken back. Military's own switches across a busy bridge wait now.
- After the freeze the switch to b2 can come with B2 already up: the squad stays outside the core seal (BUG-170's walk-group
  chain falls back to melee) instead of being crushed. Counting the want 'up' gives the switch before the pull whenever
  military looks in between; ordering military before gate's first pull is not done.
- The tiles a raising bridge swings over beyond its footprint are not checked (not observed in Run 15; needs a live look at
  which tiles DF flings from).
- Pulls not queued by gate (the player's own lever jobs) are not cancelled (DESIGN §5.9: only our own job is removed); they
  count as busy for military's freeze.

## Review fix (merge15)
- A unit only walking onto the footprint from farther away (a crosser, not within MARGIN) made every queued pull a 'blocked'
  cancel counted toward gate.pull_cap: 15 of them in busy SIEGE traffic gave the bridge up and parked every lever for
  giveup_wait. Now a blocked cancel with nobody on or next to the footprint is a walker cancel (r.ap, AP_CREDIT credit, then
  DECISION_NEEDED gate_traffic and GATE_FAIL `cancelled`), gate.lua:1980/:2053. Units on or next to it count as before (BUG-141).
- The 'blocked' give-up's parks (`r.bpark`, gate.lua:1264) do not stop a forced raise (SIEGE/BREACH, a hostile within
  force_near): pick(..., forced) pulls past them (gate.lua:904, :2108); no-effect parks (BUG-068) still hold.
- A bridge destroyed or replaced within SETTLE ticks of our pull kept `r.nec` for ever (gone_check/rep_check returned before the
  settle check): gate.busy listed it and military froze station switches across its old footprint. gone_check and rep_check
  clear `nec`/`settle` (rep_check also `mv`), and `gate.busy` is false for a bridge in st.gone (gate.lua:1828, :1874, :2783).
- Not fixed (minor, military.lua:2224): a squad frozen outside while B2 rises stays out once it is up (see Open above); a safe
  fix needs gate to lower B2 again for our squad, not a cheap change.

Tests: `tests/lua/test_merge15_gate_review.lua` (3: the 10-tile crosser no give-up; give-up then a goblin at O1 raises it;
destroyed in the settle window not busy; all fail on d40fb59).

## Hotfix (live BREACH)
- **Live (Run 15, 2026-11-04):** Drillchamber (i4, y402, 47 -> 1) and Guildcleans (i2, y392, 66 -> 18) lost B1 to a BREACH
  `B1 not up at T+900`. Drillchamber kern.log (r15d-drillchamber-site97, ~7908-7957): `B1 up still waits for ... walking onto
  it in 20 steps` for the whole SIEGE, one citizen, visitor or animal after the other (a stream that never ends in a fort
  under siege); the crosser hold of this bug kept the bridge down until the hostiles were inside.
- **Policy now (the fight goes before far walkers):** in SIEGE/BREACH a raise waits only for crossers within `M.PATH_SIEGE`
  = 6 path steps of the footprint (gate.lua holders, the non-forced branch); with a hostile within force_near (the forced
  raise) only units ON the footprint hold it (crossers with path 0 included), as BUG-310 had it: units next to it are
  named in GATE_FORCED, walkers farther out are let go. Outside SIEGE/BREACH (PEACE, ALERT) and for every lowering the PATH_STEPS
  (20) crossers hold as before.
- **Tests:** test_siege.lua (the BUG-335 forced tests turned round: a soldier 4 steps out no longer holds the forced raise, a
  citizen setting off 6 tiles away no longer cancels the pending forced pull; new: a stream of 4 citizens 20 steps out never
  holds the SIEGE raise of O1 (fails with PATH_SIEGE 20), a walker 5 steps out still holds it); test_merge15_gate_review.lua
  (the crosser enters the footprint at step 6, so its approach cancels still happen in a SIEGE).
- **Open:** units within MARGIN (next to the footprint) still hold a non-forced SIEGE raise; a stream passing through the
  doorway itself can still hold it until a hostile is within force_near. A raise with a unit 1-6 steps out in a forced raise
  can crush him if he arrives before the bridge swings (the BUG-310 risk, accepted: losing the gate kills more).
