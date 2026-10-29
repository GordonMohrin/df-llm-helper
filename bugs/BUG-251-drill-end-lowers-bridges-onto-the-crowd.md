# BUG-251 The drill's end lowered B1 in PEACE while the crowd walked home over it: soldier crushed
Status: fixed (offline, live-untested)
Severity: critical (an avoidable death: soldier 24165 crushed by B1 after an automatic drill)
Found: 2026-10-29, Run 15b Earthboat (y374 summer d74), fix6-crush
Module: `lua/dfllm/drill.lua` (`finish`, `M.restore_end`, `restore_step`, `skip_late`, `M.restoring`), `lua/dfllm/gate.lua`
(`M.drill_end`, `M.drill_skip`, `M.up_refusal`, `down_guard`, `M.quiet_wait`, `M.approach`, `M.at_station`, `control`)

## Actual
Player report (runs/run-15b-earthboat/FR-BUGS.md): #1057 BRIDGE_CRUSH / #1058 DEATH 'citizen 24165 died: crushed (bridge B1 17824
down (pulled at 150984669), last seen 1 tile from it at 67,82,138)'. kern.log: lever pullers (DRILL) 150980759, PEACE 150981959,
18 lines 'B1 down still waits for citizen', the pull 150984669, 'B1 moving' 150985009, the crush 150985484. The player had not
ordered a drill. Cause: `drill.finish` set PEACE ('gate lowers the bridges, siege ends the alert'): the alert ended and the whole
crowd walked home over B1 while it was to come down. The lowering waited only for the 1-tile margin (`M.MARGIN`), so the pull was
queued the moment nobody stood next to the footprint in a busy corridor, and the bridge moved 340 ticks later with him 1 tile away.

## Fix
(1) Restore phase: at T+1,200 the drill measures, `gate.drill_end` wants every outer/inner bridge down whose PEACE want is down (D-14
up leaves the peace gates up) while the mode stays DRILL (civ alert on, squads at their stations, the siege FPS cap held: arbiter caps
by mode, so arbiter.lua needs no change); siege's DRILL raise is refused for them (`up_refusal`: 'the drill wants it down
(drill_end)'); PEACE comes once they are down or after `RESTORE_MAX` (1,200) ticks ('drill done, restore timeout', kern.log warn).
DRILL_RESULT comes then with `d.restore` (ticks, -1 not down or cut short by another mode) and `d.why`. A bridge not up at T+900 with
no pull under way is dropped (`gate.drill_skip`): no late raise. A reload mid-restore continues from persist (m.drill rs/rl/res).
(2) Quiet window for every lowering that is not siege's (rescue, intake, sortie: BUG-028): nobody within `MARGIN_DOWN` (3) tiles;
units within SCAN_R are looked at for `QUIET_LOOK` (25) ticks, and after the last step seen the ring must stay clear `QUIET_DOWN`
(50) ticks, counted also from the last tick a unit stood within `MARGIN_DOWN` tiles, held the 1-tile margin or made a taken pull
cancel (review: the clock was cleared there, so a unit that left the ring at once let the pull go the next pass); a soldier standing within 2 tiles of his own squad's station order does not count (fortcore's melee station is 2 tiles
from B1); after `QUIET_MAX` (2,400) ticks only the 1-tile margin holds it (kern.log once). A taken lowering pull is cancelled when a
unit within 3 tiles walks toward the footprint ('B1 down pull cancelled: citizen N 3 tiles from it and walking toward it'; no
give-up count).

## Tests
`tests/lua/test_drill_restore.lua` (6), `tests/lua/test_gate_crush.lua` BUG-251 x4 (all fail on 2b9c009); updated pins:
test_drill.lua, test_drill_a3.lua, test_drill_home.lua (PEACE after the restore), test_siege.lua (three windows: the quiet look; 'footprint in PEACE after an ALERT': O1 now 50 ticks after the citizen left).

## Live check
After the next automatic drill: kern.log 'gate: drill over: B1, O1 wanted down before PEACE', GATE B1/O1 down while MODE is still
DRILL, then MODE DRILL>PEACE 'drill done'; DRILL_RESULT d.restore >= 0. With traffic at B1: 'B1 down waits for 50 quiet ticks:
<unit>' and no pull while someone walks within 3 tiles. Uncertain: whether DF keeps soldiers on their station tiles while the
restore waits (else `RESTORE_MAX` decides), and the 475 ticks between 'B1 moving' and the crush report (crush detection lag or a
re-pull: compare the next GATE_CRUSH_RISK tick with gate's move record of B1).
