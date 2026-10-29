# BUG-167 The TRANSFORM ack default clamps the clock after the were-forms are gone
Status: fixed (offline, live-untested)
Severity: medium (clock 30 t/s for a cause that no longer exists, and again after a reload)
Found: 2026-10-29, live test round 2 i2 (NEW4)
Module: `lua/dfllm/reflex.lua` (`ack_step`, `M.no_were`), `lua/dfllm/care.lua` (`M.curse_tf`)

## Actual
LOCKDOWN #33782 "interrupt #33766 TRANSFORM unacked for 60 s: kernel applied its default: clock 30 t/s" went to "Thikut Rulzas is back in
dwarf form", 7,500-15,000 ticks after the wave was dead. ack_step applies a default by wall age alone (60 real s = 5-14 game days at speed).

## Fix
When the TRANSFORM default would apply, reflex asks `care.curse_tf` (the cursed citizens in were-form in care's curse view). 0 = no default
(done 2, kern.log says why); no answer (care off) keeps the default. Review: `curse.tf_now` is nil until care built its curse view
after the boot (a reload before care's first run is unknown, not 'nobody'), so the default stays then too.

## Tests
`tests/lua/test_bug167_transform.lua` (the no-were case and curse_tf fail on b805745; the were-form and no-care cases pin the default).

## Live check
After a TRANSFORM wave whose units are back in dwarf form: leave the TRANSFORM interrupt unacked for 60 s: no LOCKDOWN, no clock clamp,
kern.log 'no citizen is in were-form now: no default'. During a wave (a unit still in were-form) the clamp still comes.
