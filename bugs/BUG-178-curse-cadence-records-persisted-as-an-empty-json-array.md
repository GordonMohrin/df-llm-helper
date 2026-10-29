# BUG-178 The curse cadence records (`m.care.cur.ev`) are saved as an empty json array
Status: fixed (offline, live-untested)
Severity: medium (CURSE_MOON and curse_kill come again as 'first' after every reload or load; inspect shows `"ev":[]`)
Found: 2026-10-29, live test round 2 i2 (NEW9-curse-ev-persisted-as-array: `inspect what=persist key=m.care field=cur` and the raw site data
`dfllm.m.care` hold `"ev":[]` although marks were set this boot)
Module: `lua/dfllm/curse.lua` (`M.cur`)

## Actual
`c.ev = type(c.ev) == 'table' and c.ev or {}`: a plain `{}` encodes as `[]`, decodes as a json array (ARRAY metatable), and an array encodes as
`[]` whatever string keys (`moon`, `kill`) are added later.

## Fix
`c.ev = json.object(...)`: the records are a keyed object, also when the save held `[]`.

## Tests
`tests/lua/test_curse_live2.lua` BUG-178 (two tests: the round trip, and no second CURSE_MOON for the same moon after a reload; fail on b805745).

## Live check
After a CURSE_MOON: `dfllm cmd inspect '{"what":"persist","key":"m.care","field":"cur"}'` shows `"ev":{"moon":{...}}`; after `dfhack-run dfllm
reload` the same moon gives no second CURSE_MOON.
