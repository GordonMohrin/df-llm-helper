# BUG-168 reflex record() checks for a duplicate interrupt twice (merge artifact)
Status: fixed (offline)
Severity: low (harmless, redundant code)
Found: 2026-10-29, live test round 2 i2 (NEW7)
Module: `lua/dfllm/reflex.lua` (`record`)

## Actual
The BUG-145 and BUG-139 merges each left the loop `for _, r in ipairs(st.irq) do if r.n == n then return end end` in `record()`.

## Fix
One loop, both bug tags in its comment.

## Tests
`tests/test_bug165_169_reflex.py::test_reflex_record_has_one_duplicate_check` (fails on b805745).

## Live check
None (no behaviour change).
