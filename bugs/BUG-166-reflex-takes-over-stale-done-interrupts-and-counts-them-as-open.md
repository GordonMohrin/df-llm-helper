# BUG-166 Reflex takes over stale done interrupts at boot and counts them as open for ever (DEFCON 1 in PEACE)
Status: fixed (offline, live-untested)
Severity: high (DEFCON 1 / 3 for interrupts whose defaults ran years before; the wake text and `next` disagree with alarm.txt)
Found: 2026-10-29, live test round 2 i2 (DEFCON-AFTER-LOAD, NEW5; skeptic: 15 'default'/'far' interrupts kept DEFCON 3 in PEACE)
Module: `lua/dfllm/reflex.lua` (`M.init`, `M.irq_keep`, `defcon`)

## Actual
`M.init` took over every persisted interrupt with tick <= now, of any age and done state, without a dedupe by n (#32617 twice from a pre-BUG-145
kernel). `defcon()` put every interrupt with n > ack into `open` unless done 2 (and done 2 as 'far' gave DEFCON 3), so a done=1 INTRUDER gave
DEFCON 1 until acked. `M.init` never wrote alarm.txt: the previous line's file stood until the first unpaused step.

## Fix
`M.irq_keep`: a persisted interrupt is dropped when its n was seen already, it lies after the clock (BUG-121), or it is done (1/2) and either
older than `M.IRQ_STALE` (one game month) or the boot found another line (`K.reset`, BUG-165). `defcon()` counts done 0 as open, done 1 only
while a lockdown holds, done 2 never. `M.init` ends with `alarm_write(K, true)`.

## Tests
`tests/lua/test_bug165_166_boot.lua` (last two tests); fail on b805745.

## Live check
Right after a load (still paused): `dfllm status` / alarm.txt show the save's own interrupts, each n once, no DEFCON 1 in PEACE without a
hostile; an interrupt in 'default' state with the lockdown ended no longer raises DEFCON.
