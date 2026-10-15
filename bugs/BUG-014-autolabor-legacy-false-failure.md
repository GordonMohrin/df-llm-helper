# BUG-014 AUTOLABOR_LEGACY says "mode monitor failed, still legacy" although the mode was switched
Status: open
Severity: low (the fix works, the report is wrong and raises a class A interrupt for nothing)
Found: 2026-10-15 15:05, Run 9 save autosave 1 (y371), dfpilot main 677bc3e, `dfllm reload`
Module: `lua/dfllm/baseline.lua` (autolabor guard, BUG-010 fix)

## Actual
```
#10881 y371 sum d5 A AUTOLABOR_LEGACY autolabor ran in legacy mode (the engine of the Run 9 crashes, found at boot):
       autolabor mode monitor failed, still legacy [after=legacy fixed=0 why=boot]
commands.log:  baseline act.run ["autolabor","mode","monitor"] ok   (twice, with "autolabor","status" in between)
dfhack-run autolabor mode        ->  Mode: monitor (starvation warnings)
dfhack-run autolabor status      ->  Error: The plugin is not enabled in legacy mode.
```
So the plugin is in monitor mode afterwards (the goal of BUG-010 is reached) but the event reports `after=legacy fixed=0` and is an
unacked class A event.

## Expected
`AUTOLABOR_LEGACY ... switched to monitor` (fixed=1), or no event beyond a log line when the switch worked. The check that decides
"still legacy" probably reads `autolabor status` right after the switch (its output now is the error text above) or the mode before the switch settled.

## Fix proposal
Verify with `autolabor mode` (prints `Mode: monitor`) or the Lua plugin API instead of `status`; treat "not enabled in legacy mode" as success.

Related: BUG-010
