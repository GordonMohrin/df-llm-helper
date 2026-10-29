# BUG-204 'act.manager_office failed for economy: no free office zone' as ACT_FAIL every 4-10 game days (x39)
Status: fixed (offline, live-untested)
Severity: low
Found: 2026-10-29, live test round 3 Earthboat, i-test3 (F7-spam; skeptic confirmed)
Module: `lua/dfllm/economy.lua` (`validation_watch`, `M.office_none`)

## Actual
`validation_watch` called `act.manager_office` every day; with no Office zone it failed, and the kernel throttles ACT_FAIL to once a game day
per key, so a lasting state read as a stream of failures (doctor lists them).

## Fix
- `M.office_none(K)` reads read-only whether the act can help (`no manager`, `no free office zone`); then the act is not called and kern.log
  says it once per 7 game days and 10 min (util/cadence `p.office_none`). A free zone: the act assigns it as before.

## Tests
`tests/lua/test_economy_drink.lua` (BUG-204). Each fails on bd27973.

## Live check
A fort without an Office zone: no new ACT_FAIL `manager_office` in `dfllm events`; kern.log `manager office: no free office zone (...)` at
most once per week and 10 min.
