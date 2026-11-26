# BUG-928 drills "failed (occupied:...)" and GATE_FAIL for bridges the kernel itself keeps down
Status: fixed (offline, live-untested), EVENT WORDING ONLY
Severity: medium (8 of 8 drills "failed", the retry back-off and `drill never` followed; A events for a hold the kernel chose)
Found: Run 17 i3 Orangering (26.11.): events.jsonl 8 of 8 DRILL_RESULT failed, fails `occupied:B1` / `occupied:O1` (+ `outside:1`); kern.log "B1 not up by the drill's T+900: no late raise (occupied: soldier 28091 moving 3 tiles from it (squad 101 on its way to its station), citizen 27544 3 tiles away, can reach it in 27 ticks ... +28 more)"; an ALERT after a plant eater 19 tiles from a citizen ("PREDATOR_FAR ... no lockdown", then "PEACE>ALERT hostile"), GATE_FAIL "B1 not up after 3900 / 40825 / 799475 ticks". Diagnosis `leitung/neu10/DIAGNOSE-i4-drill-alarm.md` A, B.
Module: `lua/dfllm/drill.lua` (`measure`, `finish`), `lua/dfllm/gate.lua` (`M.reach_held`, `check_fail`, `M.reach_day`, `M.step`), `dfpilot/schema.py`, `docs/v2/CONTRACTS.md`

## Cause (PROVEN in the code, diagnosis A and B)
- DRILL is in `gate.REACH_MODES`: the reach rule holds every non-animal unit of the census within `max(latency, 600) + TIMED_WIN` = 894 ticks (~99 steps) against a raise. A drill cannot pass while anyone is that close; the measurement reported the kernel's own hold as `occupied:<bridge>` in a "drill failed" line.
- `gate.check_fail` emitted GATE_FAIL class A (`blocked ... can reach it in N ticks`) at the deadline for a raise the reach rule holds on purpose (outside SIEGE / BREACH), and for a leftover quiet want (`peace_gates` / `window_end`, `QUIET_UP`) in an ALERT / RECOVERY with the age of the PEACE it came from (QUIET_UP exempted PEACE only; `since` is kept while the same want persists).
- `reach_day` asked its DECISION_NEEDED once per want and per bridge: two bridges, two questions per alert.

## Fix (no raise / lower decision changed; nothing of the bridge logic of the 15b rounds)
- Drill: a result whose only failures are `occupied:*` (`M.traffic_only`) carries the word `held` (`DRILL_RESULT.word`: `passed` | `failed` | `held`), the message `drill held (not measured): occupied:B1; citizens inside N after T ticks, footprint clear no, outside X, worn Y%, dbl 0`, and `inside`, `clear`, `ticks` in `d`. `pass` stays 0; the failure streak and DRILL_FAIL are unchanged (BUG-580 already excluded traffic failures).
- Gate: `M.reach_held(K, r, mode)` (ALERT / RECOVERY / PEACE with the reach rule on, every holder in `r.block` a unit the reach rule added: none ON or beside the footprint); `check_fail` then emits ONE GATE `state=reach_hold` (class C, `held down by the reach rule on purpose: soldier 5 4 tiles away, can reach it in 36 ticks`, `units`, `ticks`) per FAIL_REPEAT instead of GATE_FAIL; `br.failed` is not set, so a real failure after the hold ends still fires. A leftover `peace_gates` / `window_end` want in an ALERT / RECOVERY without lockdown is no GATE_FAIL either.
- `M.reach_day`: ONE DECISION_NEEDED `gate_reach_traffic` per alert (`M.rdn_alert`, forgotten in PEACE).
- Unchanged: GATE_FAIL in SIEGE / BREACH / DRILL (no reach exemption there), for a unit ON the footprint, no worker, no lever, and the hold itself (when bridges rise or fall).

## Not done / unproven
- The honest measure the diagnosis proposes (`settle` as the drill's pass measure, traffic as its own class) is a change of the drill's pass rule: not done. A `held` drill still does not pass R2.
- The alert itself (a plant eater 19-20 tiles from a standing citizen holds ALERT for 84,900 ticks, `calm` needs `wide == 0`): `threat.lua` / `siege.lua` / `sense.lua` untouched; the cause of the long alert is code-read, not measured on i3's logs. Which jobs the civ alert stops in that time is not checked.
- The 799,475-tick GATE_FAIL ages come from `since` kept across modes; fixed only as far as the QUIET_UP wants.

## Verifier round (NEU19)
The two new early returns of `gate.check_fail` (the reach hold; the leftover quiet want in an ALERT / RECOVERY without lockdown) set `br.failed` as the GATE_FAIL path did, only the A event is gone: `gate.not_up` reports `failed = true` as before, so `siege.failed_bridge` / `breach_stuck` read the same. Test: the ALERT -> SIEGE switch with a reach-held bridge was measured identical on 0f4f08a4 (before BUG-928), the first BUG-928 commit and this one (SIEGE raises B1 with one pull, nobody crushed).

## Tests
`tests/lua/test_bug928_drill_held.lua`, `tests/lua/test_bug928_gate_reach_hold.lua` (SIEGE TRAFFIC fixtures of `b1_world`: soldiers pacing at the station under a real hostile, nobody crushed, B1 still down); older tests that pinned the GATE_FAIL text for a reach hold now read the `reach_hold` line.

## Live-Erwartung
i3 in an ALERT with soldiers at the station: no GATE_FAIL for B1 / O1, one `GATE reach_hold` line per game day per bridge and one DECISION_NEEDED `gate_reach_traffic` per alert; the next drill with people within reach ends `drill held (not measured) ...; citizens inside N after 1200 ticks, footprint clear no` with `word held`.
