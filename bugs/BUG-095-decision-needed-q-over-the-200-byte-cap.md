# BUG-095 Three DECISION_NEEDED emitters send a `q` of 245-345 bytes, the event schema caps every string of `d` at 200
Status: fixed in the integration audit J3 commit (offline, live-untested): the three emitters keep `d.q` within 200 bytes, and
k_mock refuses a longer string in any event's `d`, so the test suites would have found it
Severity: low (a contract violation no reader checks: events are not validated on read, `msg` was cut at 200 as always; the
tail of `q` was only in events.jsonl)
Found: 2026-10-23, integration audit J3 (all 10,324 events the Lua suites emit through k_mock were validated against
`schema.validate('event')`; 101 of 104 event types occur in them, 12 events failed, all of them this)
Module: `lua/dfllm/military.lua` (`stuck`, id `squads`), `lua/dfllm/reflex.lua` (`offer_step` id `intruder_sortie`,
`need_step` id `confined_need`), `lua/dfllm/util/k_mock.lua` (`emit_as`)

## Actual
`schema.EVENTS['DECISION_NEEDED']` types `q` as `s`, a string of at most 200 bytes like every string field of an event's `d`
(`_DT['s']`). Package A4 (BUG-055) extended the `squads` question with the refusal and a fix hint ("fix: dfllm cmd
squad.create {name, leader} / squad.leader {squad, unit} / appoint {code, unit}; inspect offices"): 309-329 bytes. Package C1
(BUG-065) put the whole sentence including the `squad.sortie` command into `q` of `intruder_sortie` (244-343 bytes) and of
`confined_need` (278 bytes). `K.emit` accepts any `d` up to 1 KB, k_mock did not look at string lengths, the tests read `d.q`
whole, and the Python readers never validate an event, so nobody noticed. The wake line shows `msg` (cut at 200), so the
text beyond 200 bytes reached nobody but events.jsonl.

## Fix
`stuck` builds `d.q` in the order squads, the act's refusal (40 bytes), the fix (verbs without their argument lists), cutting
the squads part to what fits: at most 200 bytes. `intruder_sortie` and `confined_need` emit `q:sub(1, 200)` (the sentence
stays whole in kern.log; the command is `d.cmd`, which the wake hint reads). `k_mock.emit_as` treats a string over 200 bytes in
`d` (any depth up to 4) as a contract violation, like an unregistered type: strict worlds raise, others refuse the event.
CONTRACTS section 4 (`K.emit`) and the DECISION_NEEDED row say it.

## Tests
`tests/lua/test_k_mock.lua` (the guard; fails on c038ce9), `tests/lua/test_a4_offices.lua` and `tests/lua/test_reflex.lua`
(`#d.q <= 200` for the three ids; with only k_mock's guard applied to c038ce9 both fail with the contract violation, the
reflex assertion on the sortie command now reads `d.cmd`).
