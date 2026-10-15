# BUG-013 the civil alert confines everybody to Kern+, the lever pulls for the bridges are never done, only 1-3 of 4 bridges go up
Status: fixed in 055c92f (offline, live-untested)
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

## Cause
Two parts, both confirmed by the code. (1) The alert burrow list was the mode's burrow plus the manifest lever rooms
(`dfllm-levers*`, `gate.rooms`); a fort without a manifest has no lever rooms, so the list was `Kern+` alone and every
lever outside it was out of reach for every civilian. (2) The reflex deferred the alert only until `gate.sealed()` or
a fixed 450 ticks after the trigger (15 s at 30 t/s, 8 s at the ~57 t/s the live clock really ran: 526 ticks in 9 s);
the four pulls needed 526-801 ticks, so the deadline sounded the alert with pulls still queued.

How DF treats burrow-restricted dwarves (the basis of the fix; live-untested in this form): a citizen restricted to
burrows (his own burrow assignment, or every civilian while the civ alert sounds, confined to the alert's burrows)
takes only jobs whose site lies inside one of those burrows, and uses only items there; his path is not restricted,
he walks over tiles outside every burrow to reach a job site or another of his burrows (a dwarf of two disjoint
burrows walks between them). A PullLever job's site is the lever's tile (a 1x1 building; the puller stands on it).
The live evidence fits: the jobs on 57,61,117 and 59,61,117 stayed `worker=nil`, `susp=false` with both tiles
outside Kern+. So a burrow holding only the lever tiles, listed in the alert, lets a confined civilian take the pull
and walk there through the corridor outside both burrows.

## Fix (055c92f, offline)
- **Lever burrow.** `seal.lever_burrow(tiles)` paints `Hebel+` (`seal.CFG.levers`; burrows screen add + paint,
  `act.burrow_tiles`, seal owns the act) with every linked lever tile of the bridges gate holds (manifest and unmanaged,
  at most 64), kept current: a new lever is added on the next ask, a tile the player erased is read again after
  `lever_check` (100) ticks and repainted, a refused paint is retried after `lever_retry` (600). Tiles are never
  removed (a stale lever tile is listed only while a pull is pending).
- **Alert list.** `gate.rooms(mode, main)` (siege passes the alert's burrow) appends the lever burrow while a pull is
  pending (`needs_pull`: wanted state not reached, a linked lever, not waiting for a citizen on the footprint) on a
  bridge none of whose linked levers lies on `main` or a lever room; never in BREACH (attacker-side levers, the
  lever-room rule). siege's list is then `{Kern+, Hebel+}` and goes back to `{Kern+}` once the pulls are done
  (`siege.alert_names()` exposes the list it set).
- **Timing.** The lockdown's alert waits for `gate.pulls()` (no pull left: every wanted bridge up, or none left to
  pull), at most `2 x` the last measured lever latency (`lat_t`, ticks), at least 450 and at most 1500 ticks, 900 before
  the first measurement (gate's DEADLINE: an `up` not reached by then is GATE_FAIL anyway). At once only when a hostile
  is within 30 tiles of a citizen outside Kern+ or inside, or the lockdown raises no gate. The deadline is set once per
  lockdown and persisted (`hold.alert_at`, `hold.wait`, `hold.alert_t`).
- **Doors (BUG-012 consistency).** A door waits for the citizens outside at most 450 ticks after the alert began to
  call them in (`hold.alert_t`), not after the trigger: with the alert deferred for the pulls, the old rule closed the
  door at the moment the alert first called them. Without the `alert` action, 450 after the doors were first wanted.
- **Texts.** ARRIVAL/LOCKDOWN: `gates: 0 of 4 up, 4 pulls pending`, `... pending (levers in Hebel+)`, `gates: 2 of 4 up,
  2 pulls blocked (levers outside the alert burrow)`, `... waiting for a citizen on the bridge`, `... without a linked
  lever`, computed after the alert step; `d.up/left/blocked`. kern.log `reflex: civ alert: Kern+ (deadline 900 ticks, 4
  pulls left); gates: ...` (or `(gates up)`, `(hostile near)`), then `reflex: alert on, gates: ...` on every change of
  the pulls left (warn when some are blocked). GATE_FAIL `why=outside_alert` ("no worker: its levers lie outside the
  alert burrow") when the pull's no-worker cancels happened while the alert kept everybody away from its levers.
- **LOCKDOWN_END** switches the alert off before the gate pass that queues the lowering pulls (it was the other way
  round in the same step; live it already looked right because nobody could take the pull before the alert went off).
- Regression test `tests/lua/test_lockdown_gates.lua`: the real sense, threat, siege, gate, reflex and seal on a fort
  without a manifest, four lever-linked surface drawbridges, the levers in a room outside Kern+ (Kern+ passes its
  audit), and a PullLever simulator with DF's burrow rule. A goblin near a woodcutter: the alert at once, the list
  `{Kern+, Hebel+}` with every lever tile, all four pulls taken under the alert, `Hebel+` dropped after the last bridge
  rose. No hostile: the alert sounds right after the gates are up, `Hebel+` never listed, LOCKDOWN_END's `civ_alert
  false` comes before the four lowering pulls. Busy dwarves: the alert at T+900 (unmeasured), the pulls done under it.
  Measured latency 600/100/2000 ticks: deadline 1200/450/1500. A citizen outside: the door waits 450 after the alert.
  Painting refused: the pulls stay blocked, `4 pulls blocked (levers outside the alert burrow)` in kern.log and
  LOCKDOWN, GATE_FAIL `outside_alert`, the paint retried at most every 600 ticks. `test_reflex.lua` follows the texts
  and the deadline rule.

## Live check (the same forced popup on the Run 9 save, all four drawbridges lowered)
Before: `dfllm status` shows `lever_latency_s` (the deadline is 2x its ticks, 450-1500). Inject the popup as in §0h.
Expected: ARRIVAL `... alert: after the gates (<= N ticks), ... gates: 0 of 4 up, 4 pulls pending`; all four bridges up
(probe `bridges_up` 4) and only then kern.log `reflex: civ alert: Kern+ (gates up); gates: 4 of 4 up`, commands.log one
`siege act.civ_alert [true] ok` after the last `GATE ... up`. To test the lever burrow, keep the dwarves from the levers
until the deadline (or let a citizen stand outside near a hostile): kern.log `seal: Hebel+ painted with 4 lever tiles`,
commands.log `siege act.alert_burrows [["Kern+","Hebel+"]] ok`, `plotinfo.alerts.list[1].burrows` holds both ids,
`dfhack.burrows.isAssignedTile(Hebel+, 57,61,117)` true; the PullLever jobs get a worker (`dfhack.job.getWorker`) within
seconds and all four bridges rise with `civ_alert=1`; afterwards `act.alert_burrows [["Kern+"]]`. Watch and report:
whether an idle confined civilian wanders onto the lever tiles while `Hebel+` is listed (harmless, but tells us how DF
spreads idle dwarves over the alert's burrows), and whether the puller walks back into Kern+ afterwards. After `dfllm
ack` and 2 quiet days: LOCKDOWN_END, `[false]` before the four lowering `act.pull` lines, all bridges down.
