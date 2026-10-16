# BUG-028 BREACH/SIEGE lock soldiers and civilians without water behind raised inner bridges; `dfllm stop` leaves popups and fps unattended
Status: open (reported to the cloud session 2026-10-16)
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
