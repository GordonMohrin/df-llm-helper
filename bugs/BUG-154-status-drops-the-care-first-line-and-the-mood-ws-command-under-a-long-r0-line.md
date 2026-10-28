# BUG-154 `dfllm status` never shows `care first` and the R0 `mood_ws` command (token budget); a stalled project that care first pauses says only `stalled`
Status: fixed (offline, live-untested)
Severity: medium (the session does not see what runs first, nor the ready command that fixes a mood blocker)
Found: 2026-10-28, live test i4 (M6-BUG-116, M6-BUG-117, new bug 2), reproduced offline by the verifier
Module: `dfpilot/brief.py` (`status_text`, `line_unready`, `line_r0_cmd`, `line_sched`), `lua/dfllm/runner.lua` (`rows`)

## Actual
- status: `line_sched` (rank 3) was dropped by `fit_ranked` before the rank-2 UNREADY line was clipped; the clip then cut the UNREADY line to 60
  tokens (`... | traps 0 |~`), before its `next:` list, where the mood_ws command (`... only=Loom`) stood after the long hospital_out sentence.
  `brief` showed both (its line 3 is never clipped).
- `inspect projects` / brief: `c1a1776fe995f76b01 dig 22% BLOCKED:stalled` while care first paused it: runner `rows()` set `paused: care <id>`
  only for projects with `blocked == ''`; a stalled project is not halted and is paused all the same.

## Fix
- status: the mood_ws command is its own line (`line_r0_cmd`, rank 1) under the UNREADY line, which no longer carries it in status (brief keeps it
  in `next:`); the care-first part of `line_sched` is its own rank-1 line (`line_sched(ctx, "care")`); seal, rebuild and the slot queue stay rank 3.
- runner `rows()`: a stalled project that `paused()` holds says `stalled, paused: care <id>` (or seal/rebuild).

## Tests
- `tests/test_care_live_i4.py`: the live R0 blockers + ways in + an audit refusal + sched.care: status <= 300 tokens holds `"only":"Loom"` and
  `care first: ...` once each (fails on main 2c0ffa3); the generic command without a kernel hint.
- `tests/lua/test_care_live_i4.lua`: `stalled, paused: care hos` (fails on main). `tests/test_m6_orders.py` follows the new line layout.

## Live check
A fort at R0 with `mood_ws` and a hospital that leads: `dfllm status` shows the `mood shops missing ...: dfllm cmd bp.place ...` line and
`care first: <id> (...) runs first, N paused`; `inspect projects` rows of stalled paused projects say `stalled, paused: care <id>`.
