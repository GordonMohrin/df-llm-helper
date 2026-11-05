# BUG-442 A bp file the kernel does not know blocks every new fortcore stage 1 for ever
Status: fixed (offline, live-untested)
Severity: high (i2 Roadvises: all later templates '0 ranked' for a game year; the player may not delete in dfllm-runtime)
Found: 2026-11-05, Run 16b i2 Roadvises y373: `bp/y372s0b0.json`; `bp.cancel` -> "ERR bp.cancel: no project y372s0b0"; `plan check` / `bp.place`: "fortcore stage 1: y372s0b0 is the fort's fortcore already ... take it back first"
Module: `dfpilot/cmd.py` (`retire`, `send`, `orphan_candidates`, `kernel_knows`, `retire_orphans`), `dfpilot/wake.py` (`_sweep_orphans`, `_read_replies`), `dfpilot/plan.py` (`apply`)

## Actual
`cmd.retire` (move the bp file to `bp/.cancelled`) ran only after an OK bp.cancel reply. A project the kernel had dropped already (cancelled earlier, the reply lost, a reload) answered 'no project', the file stayed,
`cmd.first_core` found it and refused every new stage 1; `plan apply` kept writing the plan's files again.

## Root cause
`dfpilot/cmd.py send()` (retire only on `reply.ok`), `dfpilot/wake.py _read_replies` (the same) and no rule that compares the bp folder with the kernel's projects.

## Fix
- A bp.cancel reply 'no project X' retires the file (CLI `send` and follow).
- `cmd.orphan_candidates`: bp files older than 5 min, no PROJECT_DONE, not a row of the state's project list, and (plan builds of the applied plan.json) only once their season is due (the runner queues them from then on);
  the kernel is asked per candidate `inspect persist key=bp.<id> field=tpl` (`kernel_knows`: ok + 'none' = not held; any other answer = unknown, nothing is retired). Follow does it at start / reload and every 15 min without waiting
  (`_sweep_orphans`, no AUTO_FAIL on a missing reply), `plan apply` before it checks (`retire_orphans`, waiting for the replies). Retired files go to `bp/.cancelled` (kept for the record) and cli.log says `retire:orphan`.

## Tests
`tests/test_bug441_445_f28.py` (candidates skip young files, done projects, state rows, plan builds not due; `kernel_knows`; bp.cancel 'no project' frees `first_core`; `retire_orphans`; follow sweep and reply; plan apply order).

## Live check
After a reload with a dead file in bp/: cli.log `retire:orphan {"proj": ...}` within 15 min (or at the next `plan apply`), `bp sites fortcore --fresh` ranks again.
Open: a project beyond the 8 rows of state.proj is asked too and answers 'held'.
