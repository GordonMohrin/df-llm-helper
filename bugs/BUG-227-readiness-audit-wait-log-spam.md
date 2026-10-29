# BUG-227 kern.log spam: readiness "monthly audit waits for snapshot"
Status: fixed (offline, live-untested)
Severity: low (log noise)
Found: 2026-10-29, live round 4 (i-test3 Earthboat, FRICTION-readiness-log) and skeptic
Module: `lua/dfllm/readiness.lua` (`request_audit`)

## Actual
`readiness: monthly audit waits for snapshot s153212559-1 (still queued or exporting)` 18 times in about 50 real seconds after
the boot, 76 such lines in kern.log: request_audit logged it on every pass while the snapshot was pending.

## Fix
The line is logged once per snapshot id (`M.audit_wait_logged`); a new audit snapshot that waits logs once again.

## Tests
`tests/lua/test_snapshot_queue.lua` BUG-227 test, fails on 5e9e719.

## Live check
After `dfllm reload` with a slow audit export: `grep -c "monthly audit waits for snapshot <id>" kern.log` is 1 per id.
