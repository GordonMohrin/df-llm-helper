# BUG-676 `ack` has no effect on a PREDATOR lockdown, the lockdown_long limit offers only a sortie
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-10, Run 16b i2 Whirledrampart (`alarm.ack 439` with `unacked 0` and `lock 1`; `events.jsonl:499` `lockdown_long ... no squad can go; the lockdown stays while they are near`)
Module: `lua/dfllm/reflex.lua` (`release_units`, `M.verbs.ack`, `M.verbs['lockdown.release']`, `overlimit_step`), `lua/dfllm/util/contract.lua`, `dfpilot/schema.py`, `dfpilot/wake.py`

## Root cause
`reflex.lua` (base `M.verbs.ack`, line 2862) only moved `st.ack.n`: the lockdown a PREDATOR default made (`why unacked:PREDATOR`) has no ack path out, `overlimit_step` (BUG-452) deliberately never ends a lockdown in SIEGE/BREACH, and its only command was the squad sortie.

## Fix
- New verb `lockdown.release {unit?, approve:true}` (any mode; contract + schema): without `unit` it clears every plant eater of the census (`hb`, BUG-672's list), with `unit` that one wild animal; never an invader, an undead, a great danger or a unit that killed a citizen (`kl`); the mode and the lockdown then end by their own quiet clock (HOSTILE_RELEASED why `operator`).
- `ack` does the same for the plant eaters while a lockdown stands for an unacked PREDATOR default (the reply says `N wild animals cleared`); with other lockdowns it is the ack of old.
- DECISION_NEEDED `lockdown_long` carries `rel` (that command for the nearest unit) when only wild animals are counted (no invader, great danger or undead in sight); `wake.lockdown_long_hint` prints it. The kernel still never ends a SIEGE/BREACH lockdown by itself for invaders.

## Tests
`tests/lua/test_bug672_676_lockdown.lua` (ack clears four mammoths, the BREACH ends; `lockdown.release` refuses without approve, an invader, a killer, an unknown unit, takes one animal), `tests/test_bug672_676_f44_lock.py` (verb schema, wake line). The `rel` field of `lockdown_long` has no Lua test of its own (the Python hint is tested).

## Live check
`dfllm ack` in a mammoth BREACH answers `acked up to #N ...; 4 wild animals cleared`; `lockdown_long` carries `rel`.
Open: `lockdown.release unit=<id>` on a predator that did not kill clears it too (that is the operator's word, logged); the kernel's own 3-day rule (BUG-672) makes the command rarely necessary for plant eaters.
