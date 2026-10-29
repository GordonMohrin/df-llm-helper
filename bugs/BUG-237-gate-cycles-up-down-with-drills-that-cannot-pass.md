# BUG-237 B1 cycles up and down: automatic drills that cannot pass, no cooldown between up and down
Status: fixed (offline, live-untested)
Severity: medium (every retry locks soldiers and citizens beyond B1 out and calls everybody into Kern+)
Found: 2026-10-29, Run 15 Guildcleans (i2), fix5-gate
Module: `lua/dfllm/drill.lua` (`M.gate_held`, `check`, `step`), `lua/dfllm/gate.lua` (`M.linked`, `M.up_refusal`, `M.FLIP_COOL`)

## Actual
Live data: Run 15 Guildcleans, instance i2, `E:/DF-test2/dfllm-runtime/r15-guildcleans-site97` (kern.log, events.jsonl, commands.log, cli.log; read only). MODE PEACE>DRILL 'drill: auto: retry' at 150800134, 150868534, 150970534, 151072534, 151174534, 151276534, 151378534;
every DRILL_RESULT 'failed ... (up:O1, ...)': O1 never had a linked lever, so no drill could pass, and each retry raised B1 (up
then down about 100,000 ticks apart) with the soldiers' gallery station beyond it.

## Fix
No automatic drill while an outer/inner gate bridge has no linked lever (`gate.linked` 0; hold 'no lever:O1'), a lever hold runs
or a STRANDED rescue runs; kern.log names a new such reason once ('drill: automatic drills held: no lever:O1 ...'); once the
lever is linked the drill is due again. gate: in quiet PEACE an automatic 'up' within `FLIP_COOL` (1,200) ticks after the
bridge's 'down' want began is refused ('no up/down cycling within 1200 ticks', kern.log with both reasons); `lever:*` and a
lockdown pass.

## Tests
`tests/lua/test_fix5_gate.lua` `BUG-237: ...` x2 (fail on 6dc0f19).

## Live check
Guildcleans with O1 unlinked: no PEACE>DRILL; `dfpilot status` drill hold 'no lever:O1', kern.log 'automatic drills held' once;
after O1 is linked (2 mechanisms) the next automatic drill starts.
