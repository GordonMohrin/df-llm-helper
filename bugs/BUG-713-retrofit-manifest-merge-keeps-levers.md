# BUG-713 A fortcore retrofit must not drop a lever the manifest lists
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-11-10, Run 16b i2 Whirledrampart y430 (after `bp.place fortcore same stage=3 retrofit=2` the inspect defense reading of B2 / O1 changed from 'lever 122,134,140 stands, not linked' to 'no lever at 122,134,140 / 124,134,140', GATE_FAIL no_lever stayed)
Module: `lua/dfllm/runner.lua` (`M.merge_manifest`)

## Root cause
`merge_manifest` replaces a bridge's whole entry (`MAPS`: `dst.bridges[name] = fragment`). A fortcore fragment (retrofit or a later stage) carries the template's lever list; every lever the entry listed that the fragment does not (placed by hand, by another project, at other tiles than the template's) left the manifest, and with it gate's knowledge of the lever and its link. The i2 logs do not prove that this is what happened (the template positions equal the manifest's; two levers were toppled by tantrums afterwards, `BUILDING_TOPPLED` at 173635052 and 173643452), so this is the one place where a retrofit can lose a lever; the live case is not reproduced.

## Fix
`merge_manifest`: for a bridge whose entry has the same footprint the new `levers` = the old list plus the fragment's (no duplicates, at most 12); a moved bridge (another footprint) takes the fragment as before. Idempotent.

## Tests
`tests/lua/test_bug712_714_levers.lua` (BUG-713: union, idempotent, moved bridge replaced); `tests/lua/test_runner.lua` merge test stays green.

## Live check
`manifest.json` bridges[B].levers after a retrofit lists every earlier lever plus the retrofit's. Open: a position that is wrong for good stays in the list (reads 'no lever at ...'; R0 `levers:` is unaffected while two others are linked).
