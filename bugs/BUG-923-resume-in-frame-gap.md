# BUG-923 A resume sent during the yearly-autosave frame gap is refused and leaves the game paused, silently
Status: fixed (offline, live-untested)
Severity: medium (game stays pause:park until the player notices)
Found: Run 17 i3 run-17c, 26.11. 09:21:30 `resume` sent, 09:21:42 (end of a 45.9 s frame gap) `commands.log`: `verb:resume ERR resume: was pause:park, still paused (pause:park) after the pause key`; the CLI had already given up with "no reply yet (heartbeat 39s old)". Diagnosis `leitung/neu10/DIAGNOSE-follow-off.md` section 6.
Module: `lua/dfllm/arbiter.lua` (`M.verbs.resume`, `M.retry_resume`, `M.step`, `M.RESUME`), `lua/dfllm/kern.lua` (`K.last_gap`, ring entry `end_ms`)

## Cause
The command is read in the first frame after the gap; the pause key (`act.press_pause` = simulated D_PAUSE) did not take effect in that frame, `resume` observed "still paused" and refused (arbiter.lua ~993). Nothing tried again; the reply came after the CLI's wait limit.

## Fix (kernel retry, bounded)
- `K.last_gap()` (kern.lua) gives the newest frame gap (>= 3 s) with `end_ms`.
- `resume`: when the key did not take (no key error, same owner, no popup) and the gap ended less than `RESUME.gap_retry_s` (5 s) ago, `st.resume_retry` is set; the refusal text adds "the frame gap just ended: the kernel presses the key once more a moment later" and `data.retry = 1`.
- `M.retry_resume` (every `M.step`): after `retry_after_ms` (2 s: the inbox is read every 0.5 s, so a park sent meanwhile is seen first) presses the key ONCE, only while the same pause (owner and `pause_since`) stands, no popup is open and `retry_window_s` (30 s) has not run out; the result goes to kern.log (`resume retry after the frame gap ...`), the PAUSE event ends as usual when it works. `park`, `pause`, `unpause` and a newer `resume` clear the pending retry, so a later park wins. No gap = no retry (the old refusal).

## Tests
`tests/lua/test_bug923_resume_frame_gap.lua` (retry works, one retry only, later park wins, no gap no retry).

## Live-Erwartung
After a resume in a freeze: the reply says ERR with "kernel presses the key once more"; about 2 s later kern.log `resume retry after the frame gap (cmd ...): resumed` and `status` shows running. If the key still does not take, kern.log says `still paused` and the player resumes again. Unproven: that D_PAUSE works one frame after the gap (if DF is still stuck the retry fails and is logged); the CLI wording for "no reply yet" is unchanged.
