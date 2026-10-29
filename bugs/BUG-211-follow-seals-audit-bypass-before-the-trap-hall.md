# BUG-211 follow seals the audit's bypass before the trap hall exists, on fortcore tiles, and logs it on every audit
Status: fixed (offline, live-untested)
Severity: medium (walls on the core corridor beside room doors; they block later fortcore stages)
Found: 2026-10-29, live round 3, i-test3 "Earthboat"
Module: `dfpilot/wake.py` (`_request_seal`, `_request_place`), `dfpilot/cmd.py` (`audit_routes`, `seal_openings`), `dfpilot/brief.py`,
`dfpilot/plan.py` (`audit_gate`, `propose`)

## Actual
Every AUDIT began with 'manifest: no Z2 trap hall' and named 'bypass: wall 54,80,138 ... -> 53,81,138' (the door of a workshops room off
the core corridor). follow's auto seal at=audit built a wall on 54,80,138, a fortcore stage-1 (and stage-3) tile, and cli.log had
'auto:seal ... 55,84,138' six times: log_cli ran before `_request_place`'s cooldown return. Without a trap hall every way to the core is
a "bypass".

## Fix
`cmd.NO_HALL`, `audit_fails`, `no_trap_hall`; `audit_routes` returns `fails` and leaves walls on a fortcore footprint tile (`core_cells`:
cmd.footprint of every fortcore bp, later stages included) out of `open` (listed under `core`; seal_openings notes them as closed).
`_request_seal` returns while the audit says no trap hall; `_request_place` returns True only when it requested a snapshot, and the
auto:seal line comes after it, once per walls set within AUTO_TIMEOUT_S. The status UNREADY line says 'no trap hall yet: the bypass waits
for fortcore stage 2 (plan), no seal at=audit before it' instead of 'wall it'.
Review: `plan.audit_gate` only warns while the audit says no trap hall (before, it refused a plan that grew the fort, fortcore
stage 2 included, without the seal at=audit), and `plan.propose` drafts no seal at=audit then.

## Tests
`tests/test_bug209_213_cli.py` (follow without a hall, one log line, fortcore walls), fail on bd27973;
`tests/test_cli_plan.py::test_audit_gate_and_propose_wait_for_the_trap_hall` fails on 66496c8.

## Live check
On a fort without fortcore stage 2: after `dfllm audit` follow places no seal at=audit (cli.log has no auto:seal, no new seal bp file);
status shows the 'no trap hall yet' clause. With stage 2 done and a real bypass, follow places it once with one auto:seal line.
