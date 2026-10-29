# BUG-206 A pending fortcore stage 1 that builds the Still and the Fishery did not count: fishery request and an A drink_low wake
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-10-29, live test round 3 Earthboat, i-test3 (F7-spam, F9; skeptic confirmed)
Module: `lua/dfllm/economy.lua` (`M.fishery_proj`, `M.drink_low`)

## Actual
`M.fishery_proj` read `workshops` projects only, so economy asked for a fishery while the fortcore stage 1 that builds one was queued (two
fisheries were built), and DECISION_NEEDED drink_low 'no still' (A) woke the session at spr d43 while that stage built the Still.

## Fix
- `M.fishery_proj` also accepts a pending fortcore project whose doc is stage 1 (`params.stage` 1, no retrofit; every fortcore stage's doc
  lists stage 1's workshops) and whose manifest lists the type. Fishery request, mood shops and `ws_queued` see it.
- `M.drink_low`: with 'no still' first among the blockers and such a project pending (drink days >= alarm.days, as before), kern.log notes
  `drink low: N drink days, no still yet: project <id> builds one (...)` once per episode instead of the class-A question.

## Tests
`tests/lua/test_economy_fishing.lua` (BUG-206), `tests/lua/test_economy_drink.lua` (BUG-206). Each fails on bd27973.

## Live check
A fresh fort with fortcore stage 1 applied: no PROJECT_REQUEST why=fishery while the stage moves; with drink below drink.low_d before the
Still stands, kern.log `no still yet: project <id> builds one` and no DECISION_NEEDED drink_low.
