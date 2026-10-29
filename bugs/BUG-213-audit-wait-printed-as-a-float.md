# BUG-213 dfllm audit prints its wait as a float
Status: fixed (offline, live-untested)
Severity: low (cosmetic)
Found: 2026-10-29, live round 3 skeptic
Module: `dfpilot/wake.py` (`run_audit`)

## Actual
'audit: waiting up to 112.5 s ...': audit_timeout returns a float and the line formatted it with `:g`.

## Fix
The line prints `int(round(timeout))`.

## Tests
`tests/test_bug209_213_cli.py::test_audit_prints_its_wait_as_whole_seconds`, fails on bd27973.

## Live check
`python -m dfpilot audit` prints 'audit: waiting up to N s' with a whole number.
