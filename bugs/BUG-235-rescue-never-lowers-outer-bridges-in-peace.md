# BUG-235 the rescue never lowers an outer bridge and demands a sealed outside even in quiet PEACE
Status: fixed (offline, live-untested)
Severity: high (STRANDED 'no rescue' for days in PEACE while the citizens starve)
Found: 2026-10-29, Run 15 Guildcleans (i2), fix5-gate
Module: `lua/dfllm/siege.lua` (`rescue_step`, `way`, `M.on.MODE`, `M.rescue`), `lua/dfllm/gate.lua` (`M.release`),
`lua/dfllm/drill.lua` (`M.gate_held`)

## Actual
Live data: Run 15 Guildcleans, instance i2, `E:/DF-test2/dfllm-runtime/r15-guildcleans-site97` (kern.log, events.jsonl, commands.log, cli.log; read only). STRANDED '8 citizens on walk group 580 without food ... no rescue (no raised inner or core bridge leads to food)' and
'... (an outer bridge is not up)': the BUG-028 rescue only crosses inner/core bridges and only once every outer bridge is up and
seal verified the outside sealed. Both make sense in a siege, none in PEACE without an enemy, where the gates are a convenience.

## Fix
In quiet PEACE (`M.calm`) the way may cross outer bridges too, the outer-up and sealed checks fall away (a hostile inside or on a
joined walk group still refuses); STRANDED rescue carries `peace` 1 and the text '(PEACE, no threat)'. The rescue record `pz`
(persisted) has no RESCUE_MAX: it ends when every rescued citizen ate/drank or is gone, and then `gate.release` drops each
'rescue' want so the mode default takes over (D-14 down: down; D-14 up: the peace gates). A mode change away from PEACE aborts it
(STRANDED abort `mode X`) and the new mode's rules raise. No automatic drill while a rescue runs ('stranded rescue').
Contracts: STRANDED d `peace:i`; appendix regenerated.

## Tests
`tests/lua/test_fix5_gate.lua` `BUG-235: ...` x2 (fail on 6dc0f19).

## Live check
Citizens hungry beyond a raised bridge in PEACE: STRANDED rescue with `peace` 1 and the bridges named, the bridge comes down,
STRANDED done '... back to the mode default', kern.log 'gate: B1 rescue want released, now down (peace)'.
