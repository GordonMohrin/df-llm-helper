# BUG-614 After a DF restart the kernel stays pause:df and `status` / `follow` do not say `dfllm cmd resume`
Status: fixed (offline, live-untested)
Severity: low-medium (a freshly loaded fort stands for minutes until the player guesses the command)
Found: 2026-11-09, Run 16b i2 (R35 y407: after the DF restart / save load the game stood pause:df, `cmd resume` needed, `follow --takeover` does not start it), Run 16d i4 and Run 16a i1 R15b (`status` / `follow` without a hint to `cmd resume` after a DF restart)
Module: `dfpilot/wake.py` (`Follower._check_paused`), `dfpilot/brief.py` (`line_paused`, `status_text`, `brief_text`)

## Actual
`status` printed `pause:df` as a fragment of the first line; `follow` printed nothing. The existing helpers come late: TICK_STALL after 120 s of a static tick (`wake.py _check_stall`), the kernel's PAUSED_BY_DF after 5 min (`arbiter.lua paused_by_df`, `RESUME.wake_min`), and a follow that was restarted just then saw neither.

## Root cause
`brief.py line_head` shows `pause:<owner>` only; no line says what releases a pause by DF. `wake.py` had no check on the pause owner alone (`_check_stall` needs a static tick, the kernel's wake a 5 min stand).

## Fix
- `brief.line_paused(ctx)`: `PAUSED by df: the game stands, nothing runs (a DF restart or a load leaves it so): run dfllm cmd resume` (popup: `... it reads the popup and refuses threat or curse words`), rank 0 right under the clock line in `status`, second line of `brief`; nothing for the player's (`gordon`) or the inbox's pause.
- `Follower._check_paused`: heartbeat paused and `owners.pause` df / popup for `PAUSED_HINT_S` (30) real seconds while the kernel beats -> one synthetic PAUSED_BY_DF wake per pause (`PAUSED_BY_DF 35 s (pause:df, ...): dfllm cmd resume`, plus the popup text of the log when there is one; the NEXT hint of the type describes the reply). No command is sent: `resume` stays the player's call.

## Tests
`tests/test_bug613_614_follow_status.py` (3 for BUG-614: the wake after the window and once per pause, no wake for the player's pause or a running game, status and brief lines)

## Live check
Load a save (or restart DF) and start follow: after about 30 s `WAKE ... PAUSED_BY_DF 3x s (pause:df ...): dfllm cmd resume`; `dfllm status` shows `PAUSED by df` under the clock line until `cmd resume` runs.
