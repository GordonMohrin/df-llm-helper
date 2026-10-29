# BUG-313 a refuge hatch walled in on its level is never taken by a builder
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-10-29, Run 15 (Earthboat, Drillchamber, Inkintense; FR-BUGS Runde 2/3)
Module: `dfpilot/cmd.py` (refuge_stair, stair_boxed), `lua/dfllm/seal.lua` (M.refuge_stair, M.boxed), `lua/dfllm/economy.lua` (M.boxed_in, build_state), `lua/dfllm/runner.lua` (Q.cls_of)

## Actual
The seal-first refuge hatch stood unbuilt for hundreds of days in three forts beside 8-10 idle dwarves:
Earthboat `hatch 55,82,133: job 8095 not suspended, no builder has taken it; 1 item attached` (y373-y384, re-placed three times:
jobs 146275, 205434, 282764, each again "no builder" or "suspended by DF: no cause readable"), Drillchamber `hatch 89,72,137`
(jobs 10421, 24715, since y374), Inkintense `hatch 86,53,126` (job 23293). gamelog.txt of Earthboat has no cancel of a hatch job.

## Root cause
All three hatches sit on the up/down stair one level above the refuge, inside the shaft fortcore digs: the newest snapshots
show `#X#` on that level with walls on all 8 sides (Earthboat s155173869-3 z133 and z134, Drillchamber s152514034-15 z137 and
z138, Inkintense s151883656-1 z126 and z127). A builder has no tile beside the hatch on its level to build it from, so no one
takes the job; a re-place on the same tile (BUG-274) cannot help. `cmd.refuge_stair` (cmd.py:808) and `seal.refuge_stair`
(seal.lua:3265) always took `zr + 1` as the hatch tile. (The DF rule "a builder needs a standable tile beside the site on its
level" is inferred from the three forts and the doors with a floor beside them that were built; not proven in the game.)

## Fix
- `seal at=refuge` (cmd.refuge_stair) and the kernel's trust check (seal.refuge_stair) move a head that is walled in on its level
  (all 8 neighbours revealed, none floor/stair/ramp/door/trap/bridge/shallow water) up the same stair to the first level that has a
  tile beside it or already a hatch (state `moved`, why `boxed`, the note `no tile beside it on its level to build from ... hatch
  moved to x,y,z`). A hidden neighbour or no such level keeps the head; a hatch built on the old head still counts.
- economy.build_state adds `: walled in on its level (no tile beside it to build from)` and `boxed` to an untaken job; runner's
  cause is `boxed` (SEAL_STUCK d.why) and the BUG-274 re-place is skipped for it.
- The levels between are walled in by construction, so the hatch one or more levels up separates the refuge the same way.

## Tests
`tests/test_bug313_boxed_hatch.py` (5; the two "stays" cases guard and pass before), `tests/lua/test_fix11_builders.lua`
(build_state, SEAL_STUCK boxed, seal.refuge_stair). Updated pins: `tests/lua/test_seal_refuge.lua` (the fixture shaft is walled in:
the hatch is now wanted on the hall level 6,6,9; the hatch on 6,6,6 still counts), `tests/bp/test_bp_seal_run11.py` and
`tests/test_plan_seal_closed.py` (the fortcore template's own shaft z3/z4 is walled in: 50,65,5; the refuge stays separated). Fail on 9ef2ccb.

## Live check
Earthboat: `dfllm cmd bp.cancel proj=<the stuck seal>`, then `bp.place tpl=seal site=S1 at=refuge`: the answer/plan check names
`hatch moved to 55,82,135`; a builder takes it within days (kern.log no SEAL_STUCK); `inspect refuge` trust.hatch pos 55,82,135
with man 55,82,133. Drillchamber the same (expected 89,72,139), Inkintense (86,53,128 or the next level with a floor). If a
moved hatch is not taken either, read its job's item position and the builders' labors.
