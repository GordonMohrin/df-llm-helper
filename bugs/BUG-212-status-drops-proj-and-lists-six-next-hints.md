# BUG-212 status drops the proj line and lists six next: hints in the UNREADY line
Status: fixed (offline, live-untested)
Severity: low (PLAYBOOK 9.3 reads proj in status; a weak model got six commands at once)
Found: 2026-10-29, live round 3, i-test3 "Earthboat"
Module: `dfpilot/brief.py` (`status_text`, `line_unready`, `line_proj`)

## Actual
Status line 2 at aut d30 was about 700 characters with six `next:` commands, and the `proj` line (rank 4) was dropped before the long
UNREADY line (rank 2).

## Fix
Status keeps `proj` at rank 1: blocked projects first, the first two, clipped to PROJ_STATUS_TOKENS (32). `line_unready(cmds=False)`
(status) keeps only the first `next:` hint; brief keeps them all.

## Tests
`tests/test_bug209_213_cli.py` (status under a long UNREADY line), fails on bd27973; test_cli_status, test_hospital_sites and
test_perimeter_escalation now read the further hints in the brief.

## Live check
A fort at R0 with several blockers: `python -m dfpilot status` has one `next:` in the SIEGE UNREADY line and a `proj` line (blocked
first); `python -m dfpilot brief` lists every hint.
