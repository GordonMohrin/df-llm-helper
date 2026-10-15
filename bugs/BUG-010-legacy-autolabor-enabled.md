# BUG-010 `autolabor` runs in legacy mode after map load, the engine that crashed DF in Run 9
Status: fixed in 1d9b6a9 (offline, live-untested)
Severity: high (risk of a DF crash; the two crash logs of 14.10. 10:41 and 10:47 name autolabor_plug)
Found: 2026-10-15, Run 9 save autosave 1, dfpilot main 3edc277
Module: `lua/dfllm/baseline.lua:158-165` (engine choice), `config/allowlist.json:7` (only `mode monitor|modern` allowed)

## Actual
```
$ dfhack-run autolabor
Automatically assigns labors to dwarves by writing the labor matrix directly (legacy mode). ...
Current state: 1, mode: legacy.
$ dfhack-run plug | grep autolabor
autolabor                      loaded        2 enabled
```
Found enabled right after the fort load; `kern.log` shows `baseline rechecked: 4 tasks, failed [], pending [idle_crafting melt trade_piles]`
every ~75 s and `slow ... baseline` in `doctor` (baseline is demoted by KERNEL_SLOW, BUG-007). Only `economy` calls `labormanager status|mode`
(read only). Nobody sets `autolabor mode`.

The Run 9 crash logs of 14.10. (10:41:01 and 10:47:33) have the top frames in `autolabor_plug!plugin_shutdown+...`; the player disabled the
plugin by hand, it was switched on again by the load.

## Fix proposal
At boot and after every load: if `autolabor` is enabled and the mode is `legacy`, set `autolabor mode monitor` (or `modern`) before
anything else, and do it outside the demotable baseline module; raise a class A event when the legacy engine is found running.

Related: BUG-007, FR-16

## Fix (1d9b6a9, offline)
`baseline.legacy_guard` reads the engine (`autolabor status`, else `labormanager mode`; the "mode: X" field first) and,
enabled in legacy mode, runs `autolabor mode monitor` (allowlisted) and raises AUTOLABOR_LEGACY (A, new; `fixed`,
`after`). It runs in baseline's init, a boot step before the demotable queue (so also after every load), as the first
task of every full apply, and when economy's daily `labormanager mode` read names legacy. kern.lua is unchanged.
Live check: load a save with autolabor legacy enabled: `dfhack-run autolabor` says mode monitor right after the boot,
`commands.log` has `autolabor mode monitor` from baseline, `events` AUTOLABOR_LEGACY fixed=1.
