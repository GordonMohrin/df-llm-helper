# BUG-335 drawbridges crush our own people: soldiers on their way walk onto a bridge that is already rising
Status: fixed (offline, live-untested)
Severity: critical
Found: 2026-11-04, Run 15b Earthboat y385 autumn d18 (i3), Run 15 Guildcleans y379 spring d53 (i2)
Module: `lua/dfllm/gate.lua` (holders, control)

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

## Open
- A unit that only gets its path after the lever was pulled (a new job, a new squad order in the ~100 move ticks) is still
  unseen: the pull cannot be taken back. Military stations whose route crosses a core bridge (stations.b2 / melee flipping with
  B2's state) keep sending squads over it; gate now waits for them instead of raising, military does not re-route them
  (restation moves only squads standing at their station).
- Units on another z level (stairs/ramps up to the bridge) are not in the scan (around is same-z, as before).
- Pulls not queued by gate (the player's own lever jobs) are not cancelled (DESIGN §5.9: only our own job is removed).
