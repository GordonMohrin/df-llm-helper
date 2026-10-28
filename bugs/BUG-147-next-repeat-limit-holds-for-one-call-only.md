# BUG-147 `dfllm next`: the repeat limit held for one call only (the "tried 3x" answer and any other command reset it)
Status: fixed (offline, live-untested)
Severity: medium (the 635-inspect loop FR-85 was built against came back every 4th call)
Found: 2026-10-28, live test i1 (region2-site90 y715), feature FR-85-88a and NEW2; confirmed by the verifier
Module: `dfpilot/guide.py` (`read_memory`, `tried_cmds`, `remember`, `decide`)

## Actual
- 5 calls of `python -m dfpilot next` on a stale plan: plan propose, plan propose, plan propose, `NEXT: nothing (tried 3x ...)`, plan propose.
  `remember()` unlinked `.next.json` for every step without a command, the "tried 3x" idle step included.
- 6 calls with two candidates: brief (n=1), brief (2), brief (3), bp.place seal (1), brief (1), brief (2): the memory kept only the last
  command, so one other step in between reset the count.

## Fix
- `.next.json` v2: `{v:2, cmd, n, wall, cmds:{<cmd>:{n, wall}}}`, one entry per command printed within `REPEAT_WINDOW_S` (30 min after its
  last print). `tried_cmds` returns every command with n >= `REPEAT_MAX`; `remember` counts only the printed command and keeps the others.
- The "tried N x" step (`Step.stuck`) keeps the memory; only a green answer (nothing applies, nothing skipped) clears it. A v1 file is read as
  one entry. `danger` is counted but never skipped (unchanged).

## Tests (`tests/test_bug147_next_repeat.py`)
- the stuck answer keeps the memory (fails on main: the skipped command again on call 5), another command in between does not reset the count
  (fails on main), the count is per command and expires (fails on main); "green clears" and "danger is never skipped" pin the boundaries.
