# BUG-191 A dug aqshaft level that flooded is never noticed when the shaft lost its runner slot
Status: fixed (offline, live-untested)
Severity: high (7/7 water in an open shaft for 139+ days: no AQ_HEAVY, no plug)
Found: 2026-10-29, FR-95 live test 1, instance i4 (kernel b805745)
Module: `lua/dfllm/aqshaft.lua` (`A.work`, new `A.holds`), `lua/dfllm/runner.lua` (`second()`, the measure pass)

## Actual
Shaft c1a1858c02562d7101 at 56,56 top 129 (soil aquifer z128): the miners dug z128 (STAIR_UPDOWN, now flow 7/7), record
`levels.128 = {state:"dig", samples:[]}` without `opened`; runner row `no progress 139 d: slot yielded`. The BUG-037 yield
(no own progress for yield_days) put the shaft into pass 2 while older stalled projects held the slots; its measure-only
pass returned in `A.work` before `dig_step` (the only place that set `opened`), and `check_level` samples only opened levels.

## Fix
- `A.work`: before the measure/hold return, a read-only check: a level in state dig with its designation made whose centre
  tile is dug (no wall, no pending dig job) is `opened`, so `check_level` samples its flow and a heavy aquifer stops and plugs
  the shaft in a measure-only or held pass too; nothing is designated there.
- `A.holds(rt, id)`: the shaft has a level designated, open, sealing or watched. `second()` never moves such a shaft to
  pass 2 (it keeps its slot, as a seal does), and while it waits for a slot in pass 1 it gets the measure-only pass too.

## Tests
`tests/lua/test_bug191_194_aqshaft.lua` (BUG-191: no "slot yielded" with a designated level; the flooded level gives AQ_HEAVY
and CAVERN_PLUG; `A.work` measure/hold passes stop a heavy aquifer read-only), fail on 9da84d6.

## Live check
i4: an aqshaft whose current level is designated while the miners are busy elsewhere: its row stays `""` or `queued`, never
`slot yielded`; once the level is dug and wet, `levels.<z>.opened` is set and samples grow; >= 4/7 gives AQ_HEAVY and CAVERN_PLUG.
