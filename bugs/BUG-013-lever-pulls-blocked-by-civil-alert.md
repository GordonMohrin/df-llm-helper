# BUG-013 the civil alert confines everybody to Kern+, the lever pulls for the bridges are never done, only 1-3 of 4 bridges go up
Status: open
Severity: high (the siege reflex "gates up" half-fails exactly when the alert works; worse than before BUG-011 was fixed, when the alert flipped off and the pulls got done)
Found: 2026-10-15 15:02-15:15, Run 9 save autosave 1 (y371), dfpilot main 677bc3e (kernel reloaded), forced arrival popup (see BUG-011)
Module: `lua/dfllm/reflex.lua` (gates up + `act.civ_alert`), alert burrow choice in `lua/dfllm/siege.lua` / `seal.lua`

## Reproduction
All four drawbridges lowered, popup injected (see BUG-011). Three runs, same fort, same levers (15961 at 57,61,117; 15963 at 59,61,117; ...):
```
run   civ_alert in probe   bridges_up after 120-170 s
2     0 (flip-flop)        4 of 4 after 16 s   (lever_latency_s 14)
4     1 (stays on)         3 of 4, the 4th never        (pulls pending)
5     1 (stays on)         2 of 4, 2 pulls pending for 5 min of game time
```
Run 5, `status`: `lever_latency_s 9 (526 t), 2 pulls pending 5 s`, alarm.txt: `gates 4 wanted up (1 up, 3 pulls pending)`.
Lua at that moment: levers 15961 and 15963 each have a `PullLever` job, `susp=false`, `worker=nil`, for minutes. Both lever tiles
(57,61,117) and (59,61,117) are **not** in the burrow `Kern+` (`dfhack.burrows.isAssignedTile` false). The kernel put `civ-alert` (burrow Kern+)
on within 6 s of the popup; setting `civ_alert_idx=0` by hand is reverted by the kernel within one frame (so the alert is held on during the lockdown).

## Cause (likely, consistent with all three runs)
With the alert on, every non-military citizen is confined to Kern+ and cannot path to levers outside it, so `PullLever` jobs stay unclaimed.
In run 2 the alert flipped off after 12 ticks (BUG-011) and the pulls were done; the fix for the flip-flop exposes this.

## Expected
The gates are pulled first (they are the first line of defense) and the alert goes on after the pulls are done or after a short deadline,
or the alert burrow contains the lever tiles and the route to them, or a soldier (not confined) takes the pulls. `LOCKDOWN` text
should say `gates: 2 of 4 up, 2 pulls blocked (levers outside the alert burrow)` instead of `alert on Kern+`.

## Fix proposal
In `reflex`: order of actions: (1) queue lever pulls, (2) wait until `pulls pending == 0` or N ticks (the measured latency is 9-16 s real time at 30 t/s),
(3) then `act.civ_alert true`. Alternatively add the lever tiles of the gate levers to the alert burrow before turning the alert on (the audit
`refuge_sep`/`civ_sep` should treat "levers reachable inside the burrow" as a requirement). Also: `LOCKDOWN_END` should lower the bridges again
only after the alert is off (it did: the remaining bridges went down only after `alert 0`).

Related: BUG-011, BUG-012, FR-52, FR-54
