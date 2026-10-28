# BUG-139 An event a handler emits while kern delivers the eventful queue arrives twice: two LOCKDOWNs for every unacked TRANSFORM
Status: fixed in the fix-live-curse commit (offline, live-untested)
Severity: medium (a doubled default and a doubled interrupt record for every event emitted from a REPORT or UNIT_DEATH handler)
Found: 2026-10-28, live test i2 (E:/DF-test2, DFHack port 5001, region2-site90 y717, DF 53.16 / DFHack 53.16-r3) of the M4 curse package, confirmed by the verifier
Module: `lua/dfllm/kern.lua` (frame: the queue swap), `lua/dfllm/reflex.lua` (`record`)

## Actual
LOCKDOWN pairs #32279/#32280 (ticks 289139889/289139899), #32304/#32305, #32306/#32307, #32393/#32394: `interrupt #32274 TRANSFORM
unacked for 60 s: kernel applied its default` twice. reflex's `st.irq` held every TRANSFORM twice, 1-9 ticks apart; the old DEATHS_3PLUS
31169 too. CURSED 32253 (emitted from the arbiter's step) only once.

## Cause
kern.lua:1289-1293 swapped `st.evq` only when it was not empty. In a frame with eventful items (a REPORT) but no pending EV events, `eq`
WAS `st.evq`: care's TRANSFORM (emitted in `on.REPORT`) was appended to it, delivered by the second loop of `deliver_queues` in the same
frame, stayed in `st.evq` and was delivered again in the next frame. reflex `record` had no dedup.

## Fix
Both queues are swapped whenever either is delivered (an event emitted now arrives next frame, once). reflex `record` ignores an event
number it already holds (one default per interrupt).

## Tests
`tests/lua/test_curse_live_kern.lua` (BUG-139, the real kernel; on dec5132 two events reach the listener three times).
