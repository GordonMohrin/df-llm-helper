# BUG-234 a refused STRANDED rescue in PEACE wants the bridge that cut the citizens off up again
Status: fixed (offline, live-untested)
Severity: critical (citizens and soldiers locked out from food in PEACE without an enemy; soldier 25905 starved)
Found: 2026-10-29, Run 15 Guildcleans (i2), fix5-gate
Module: `lua/dfllm/siege.lua` (`rescue_step`)

## Actual
Live data: Run 15 Guildcleans, instance i2, `E:/DF-test2/dfllm-runtime/r15-guildcleans-site97` (kern.log, events.jsonl, commands.log, cli.log; read only). PEACE, no hostile, D-14 down, O1 without a linked lever (ACT_FAIL link_lever 'needs 2 free reachable mechanisms, 1
found'). After the drill of tick 151277353 B1 (role inner) stood up; at 151277734 PEACE wanted it down (LEVER 'pull B1 down', job
20217); 15 ticks later siege's rescue step found 2 soldiers on walk group 580 without food, refused ('no rescue (an outer bridge
is not up)', STRANDED d.bridges B1) and, on every refusal, wanted the bridges of the way UP ('rescue_end', `want(K, b, 'up', ...)`).
gate cancelled the lowering pull and kept B1 up; each further refusal (every 100 ticks, the event itself is cadenced) re-wanted it.
Later 9 citizens stood behind B1, GATE_FAIL 'B1 not up after 29399 ticks (timeout)' and 15 cancelled pulls for the crowd at B1
('15 pulls cancelled ... no pull for 7200 ticks'); DEATH 25905 starved (hunger 100871). The desired 'up' came from neither the
D-14 table (peace_want = down), a lockdown nor the open perimeter: only from the refused rescue.

## Fix
`M.calm(K, a)`: PEACE, no lockdown (`reflex.holding('gates')`), nobody hostile in sight or inside. In that state a refused rescue
raises nothing (only bridges this attempt itself lowered are handed back with `gate.release`); the threat-mode rule (BUG-028) is
unchanged. A rescue that outlives its episode into PEACE follows the PEACE rules (no raise at its end).

## Tests
`tests/lua/test_fix5_gate.lua` `BUG-234: ...` (fails on 6dc0f19: B1 stays up).

## Live check
In PEACE with a stranded group: kern.log/events show STRANDED refused or rescue, but no 'pull B1 up' LEVER and no GATE_FAIL B1 in
PEACE; `dfllm status` bridges B1 down within a day after a drill.
