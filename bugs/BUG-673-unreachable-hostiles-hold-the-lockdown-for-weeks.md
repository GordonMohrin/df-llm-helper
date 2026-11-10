# BUG-673 An ambush group on a cave level no citizen can walk to holds the lockdown and the 30 t/s clock for 50+ days
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-10, Run 16d i4 Trumpetrealms y447-y450 (`r16d4-trumpetrealms-site97/events.1.jsonl:23451` INTRUDER `reach 0`, `:23473` "dangerous inv 31955 GOBLIN ... 12 tiles from an entrance keeps the lockdown arrival:ambush for 10.0 days", `:23512`)
Module: `lua/dfllm/reflex.lua` (`pv_kind`, `pv_step`, `outer_groups`, `quiet_block`, `far_now`), `config/reflex.json`

## Actual
An ambush of 5 goblins (reach 0, z147-154, a cave level no walk group of the citizens reaches) was `near` by the tile distance to an entrance (Chebyshev with z: 12 tiles), a group over `lone_max` (so `dangerous`), and invaders count map-wide in threat: ALERT, the arrival lockdown (clock 30 t/s, doors, alert) and `lockdown_long` / `intruder_sortie` offers with a sortie the squad could not walk, for 50+ days.

## Root cause
`reflex.lua` `far_scan` measures "near" by distance only (`dc` / `de`), never by whether anyone can walk there; `sense.lua` lists an invader on another walk group (the non-invader drop at `sense.lua` ~l.660 does not apply to invaders) with `rc 0`, and nothing used that beyond the offer text (BUG-671: no sortie offer for `rc 0`).

## Fix
`reflex.pv_kind` / `pv_step`: a hostile with `rc == 0` that is no flier / building destroyer / great danger (`dz`, `bd`) and not inside Kern+ is timed like BUG-672's plant eater. After `confine.unreach_days` (5, 0 = off) game days, in PEACE / ALERT / RECOVERY only (never SIEGE / BREACH), it is cleared (far.ids + far.hl, NOT far.ig; HOSTILE_RELEASED why `unreachable`) when its own walk group is none of `outer_groups`: the groups of the tiles within `OG_R` 4 of every entrance point (gate's bridge centres, the lockdown's doors, seal's entrance tiles) minus the citizens' own. An army at a raised bridge or a locked door stands on such a group and is a siege, never "unreachable". No entrance point known: nothing is cleared. `far_scan` re-reads `rc` every census: one that can be walked to (a bridge down, a way dug) or that comes inside Kern+ counts again at once. `quiet_block` / `far_now`: the cleared invaders do not hold the lockdown's quiet clock.

## Tests
`tests/lua/test_bug672_676_lockdown.lua`: five goblins on a cave level (ALERT, lockdown, cleared after 5 days, ALERT and the lockdown end; `unreach_days 0`: still locked down); the cave joins the citizens' group: all five count at once; goblins at the far side of the entrance door: nothing cleared; seven unreachable goblins (SIEGE): never cleared.

SIEGE TRAFFIC TESTS (same file, last three; the siege / lockdown / refuge code is touched through `far_scan`, `quiet_block`, `far_now` and `seal.groups`): (1) eight goblins outside O1 with three citizens in the killing field, run with the new bounds and with both off: same event trace tick for tick, SIEGE, lockdown, recall done, O1 and B1 up, all three citizens inside; (2) four cave goblins and a building destroyer at the door (ALERT): only the four goblins are cleared, the destroyer holds the lockdown, the mode and the bridges are those of the old rule; (3) four mammoths inside Kern+ in the middle of a goblin siege: the mammoths are cleared, eight invaders counted, no hostile inside, the lockdown stands, O1 and B1 up, nobody outside.

## Live check
`HOSTILE_RELEASED unreachable` 5 days after a cave ambush shows up and ALERT / lockdown end; nothing is released for goblins at the gate (`inspect census` `rc 0` beside a raised bridge).
Open: a goblin group that digs or climbs out of its level is caught by the next census (`rc`), not before; the outer side is read from tiles round the entrance points (at most 6,000 reads per 2,400 ticks); 5 days is a judgement; the `intruder_sortie` offer for them is unchanged.
