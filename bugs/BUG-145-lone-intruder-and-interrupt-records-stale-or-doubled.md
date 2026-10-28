# BUG-145 Status shows a dead intruder's kill order for the next one, LOCKDOWN_END names a far unit twice, an interrupt delivered twice is recorded twice
Status: fixed in the fix-live-siege commit (offline, live-untested)
Severity: medium (wrong report)
Found: 2026-10-28, live test instance i3 (E:/DF-test3, region2-site90 Trussroads y717), workflow wf_190bd773-8de, confirmed by its verifier
Module: lua/dfllm/reflex.lua (`lone_step`, `M.state`, `record`)

## Actual
- For 10 days of the 41875 picture the status read `kernel kill order: kill order on 41877` (dead since tick ~289189000).
- LOCKDOWN_END cause=limit: `far` = the same `inv 41875 TROGLODYTE at 170,170,130 (61 tiles)` twice, `nfar 2`.
- alarm.txt held DEATHS_3PLUS #32617 twice (ticks 289149747 and 289149749), kern.log the ack-timeout line twice; also #31169 in an older session.

## Cause
- `M.state` copied `rt.kl.msg` with no picture or age check; `lone_step` renewed `st.lone` on a new signature but kept `rt.kl`.
- `lone_step`'s release passed every picture entry as `near`; `release()`'s `far_mark` named the far one, `hl_clear` again.
- `record()` appended without checking the event number (the second delivery path is not pinned offline).

## Fix
`rt.kl` carries the picture signature and is dropped when the picture changes; `alarm.ln.kill` only for this picture and within
2 x KILL_RETRY + one look; with a lockdown only near or unmeasured units go to `hl_clear`; `record()` keeps one record per event number.

## Tests
`tests/lua/test_bug143_145_reflex.lua` (3, fail on dec5132).
