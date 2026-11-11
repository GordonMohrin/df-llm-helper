# BUG-765 surprise siege: pullers and civilians walk out to attack-side levers while the hostile is there first
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-11, Run 16a i1 Basementflew y540 win d76-d80 (kern 87b10464): surprise SIEGE (cave dragon 35944, 5 invading goblins, an ambush, a snatcher), 11 citizens lost (50 -> 39), 0 hostiles killed
Module: `lua/dfllm/gate.lua` (`fill`, `pullers_step`, `M.rooms`, `lever_room`, new `race_lost` / `race_safe`)

## Actual
ARRIVAL #28921 'recall: 24 of 25 still outside Kern+ after 15 t'; the recall took 2475 ticks (19 of 25 still out after 609 t at the ambush #28935). B1 pull queued at +15 ticks, 'B1 up 1650 ticks after the pull was queued' (kern.log tick 218122639). Deaths #28948-#29015: citizens 31379 and 33274 (at the levers / B1, x 33-40, 31379 'out since the alert' at +1095 t), 27163 and soldier 35855 (at B1's footprint), the rest in the field and in Kern+ (goblins 35935/35940/35943, the dragon). The log shows the cause of the west-side group: the manifest's B1 levers are (37,97,129) and (36,97,129), 5 tiles WEST of B1's footprint (42,100..102), outside Kern+ (the manifest has no refuge, so no refuge levers), and `dfllm-levers` was assigned pullers 26740 (97,65) and 35917 (99,86), 60 tiles from the room (BUG-511 allows 300 + 12 per tile), then 'let go ... away' and a new far pair, again and again (kern.log ticks 218121990, 218122015, 218122914, 218122989). The room was also in the civ alert list ('dfllm-levers' via `gate.rooms`), so every citizen with a free hand could take the PullLever job. The hostile stood 17-23 tiles from B1 (GATE_FORCED #28931, #28942, #28945, #28953, #28974, #28986: 'raised with citizen N next to it: a hostile 8-23 tiles from it and closing').

## Root cause
`gate.lua` `fill` chose the nearest citizens inside the walls for a lever room no matter where the room lay or where the hostile stood; `pullers_step` kept them for PULLER_MAX = 1800 ticks; `M.rooms` listed every allowed room in the alert mode-free (only BREACH had the BUG-027 safety, `breach_safe`, and only for the seal's lever burrow, never for a room). A lever room outside Kern+ and the refuge is a race that nobody checked: a citizen walks about 24 ticks a tile (1650 ticks for ~60 tiles in this log), a hostile far less.

## Fix
`gate.lua`: `race_lost(K, c, walk, home)` = the nearest uncleared hostile of a fresh census (<= RACE_FRESH 300 ticks) reaches the room before a walker of `walk` tiles could (RACE_FOE_TPT 8 ticks a tile for him, RACE_CIV_TPT 24 for the citizen, RACE_PULL 0 margin: a fort's own lever room a few tiles from Kern+ with a hostile 12 tiles off stays a won race, test_lockdown_gates); a walk under RACE_MIN_WALK (20) tiles, a room inside Kern+ / the refuge, a puller already standing in the room and a census without hostiles are never a lost race.
1. `fill` does not choose a candidate who loses the race (kern.log 'N citizen(s) not sent as pullers', GATE_FAIL no_worker text 'BUG-765: nobody sent').
2. `pullers_step` calls a puller still on his way back when the race turns (`why = 'danger'`, he may serve again).
3. `M.rooms` leaves a lever room that loses the race for the nearest citizen out of the alert list (a puller standing there stays).
4. `lever_room` (the seal's lever burrow) is listed only while `race_safe`.
Constants `RACE_CIV_TPT / FOE_TPT / PULL / FRESH / NEAR`.

Decision, soldiers at the gate: not changed. At this siege 1 of 5 soldiers of A and 0 of B and C held a real weapon and body armor (worn 23-32 %); military stands such squads down by design (< 30 % equipped) because unequipped soldiers at a gate die and leave it open. Equipped squads already hold the core station (SIEGE_DEEP) and the sorties exist. The log's cause of the equipment gap (8 melee weapons and 16 body armors free but not worn: 'the uniform specs do not match them') is a military/economy question that these logs do not settle.

## Open
With the race lost the attack-side bridge is not pulled at all (GATE_FAIL no_worker / outside_alert at T+900 as before, now with the race in the text); a fort whose levers lie outside the walls stays open to walking hostiles until the refuge levers (fortcore) exist (the DECISIONs bridge_levers / refuge_levers ask for them). The speeds are assumed (24 / 8 ticks a tile), not measured per race. GATE_FORCED raises with a citizen next to the footprint and the slow recall of 24 citizens 30-60 tiles out are unchanged (DF's civ alert walks them, there is no kernel lever for a faster walk; DF dropped their jobs within 315 ticks in this log, so cancelling jobs would not have helped); the 2475-tick recall is not fixed by this.

## Tests
`tests/lua/test_bug765_lever_race.lua` (3): levers outside, army 28 tiles from them, every citizen 36+ away: no puller, lever burrow out of the alert, nobody outside Kern+ or crushed (fails on the old code); a citizen 3 tiles from the room and the army 33 tiles from it: he is the puller, O1 and B1 rise (fails on the old code); SIEGE TRAFFIC with 24 civilians 12-20 tiles outside Kern+ at the ARRIVAL, real invaders, levers inside Kern+: the recall brings everyone in, O1 and B1 rise before T+900, nobody crushed or locked out.

## Live check
kern.log 'lever room dfllm-levers: N citizen(s) not sent as pullers: ... a hostile T tiles from it is there first' in a siege whose levers lie outside the walls; no citizen at the levers while the hostile is near; GATE_FAIL text with 'BUG-765'.
