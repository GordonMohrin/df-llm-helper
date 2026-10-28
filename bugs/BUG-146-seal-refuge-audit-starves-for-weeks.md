# BUG-146 seal's refuge audit is weeks of game time old (reach age 60339): the refuge choice works from it
Status: fixed in the fix-live-siege commit (offline, live-untested)
Severity: high (wrong decision: refuge choice, REFUGE_FAIL and REFUGE_STOCK on old data)
Found: 2026-10-28, live test instance i3 (E:/DF-test3, region2-site90 Trussroads y717), workflow wf_190bd773-8de, confirmed by its verifier
Module: lua/dfllm/seal.lua (`urgent`, `M.audit_overdue`, `M.step`), dfpilot/brief.py, schema/contract

## Actual
inspect reach `age 60339`, busy `[seal, items, edges]`, later `[seal, audit, items, edges]`; inspect refuge `tick` 289127197 at ~289190000;
kern.log `seal demoted x8 ... promotion after 10 quiet min` since 289118410 and no promotion afterwards. `audit_every` is 3 days.
REFUGE_STOCK (class A) never came in 8 minutes of watching with `floor_pct` 200 (RF.floor runs only in commit_audit).

## Cause
The periodic audit is a background job behind `perim`, `gates`, `seal`, `split`, `rpath` and `quick` in ORDER; demoted x8, seal steps
rarely and every slice went to the jobs ahead of it, so the audit had no freshness floor.

## Fix
`seal.audit_overdue`: an audit older than 2 x its period (audit_every in PEACE, audit_alert else) runs as an urgent job (rate_urgent, ahead
of background work, also while a busy boost holds background work back), kern.log `seal: the refuge audit is overdue (N ticks old ...)` once
per day; state `alert.aud` (ticks) while overdue, brief `alert ... | refuge data N d old`.

## Not built
Exempting seal from the kernel's perf demotion; the edges record from an older timeline (verifier) is left to its own period.

## Tests
`tests/lua/test_bug146_seal_audit.lua` (fails on dec5132), `tests/test_live_siege_i3.py` (the alert line).
