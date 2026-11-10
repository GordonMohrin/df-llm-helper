# BUG-647 Aquifer cistern at an explicit anchor unchecked
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-10, Run 16c i3 Wallfree y383-y385: `bp.place cistern site=S1` refused (no aquifer site), the label A106_48_146_3 with p.water=aquifer passed, the basin lay on z145 (aquifer z141-143): `CISTERN_DRY 'no pond zone, no pipe: nothing fills it'`, no buckets (no wood) to carry
Module: `dfpilot/cmd.py` (`anchor_checked`), `lua/dfllm/water.lua` (`cistern_dry`)

## Actual
A done cistern with a dry well for 31 days; the placement note said 'basin on a known aquifer level'.

## Root cause
`cmd.anchor_checked` (BUG-502) ran the ranking's own test for explicit anchors of WATER_TPLS (hospital) and the aqshaft only; a cistern with `p.water=aquifer` (set by `cistern_fill_guard`, BUG-469) at an `A<x>_<y>_<z>` label skipped `sites.aquifer_well` (basin one level below the room on a known aquifer level, room and the level above dry).

## Fix
- `anchor_checked`: tpl cistern with `water=aquifer` is ranked at that anchor (`where={at}`); the BpError says why (basin level, aquifer levels, heavy ones) and that the cistern would stay dry.
- `water.cistern_dry`: CISTERN_DRY says `no free bucket in the fort (MakeBucket needs wood)` when a bucket-fed or unfed cistern has no free bucket (field `buckets`).

## Tests
`tests/test_bug645_650_f41_misc.py` (2), `tests/lua/test_water.lua` (the CISTERN_DRY text adapted: no free bucket in its world, the `no drink for a hospital` tail no longer fits 200 chars)

## Live check
On Wallfree: `bp.place cistern site=A106_48_146_3` is refused with the basin/aquifer reason; the S1 label and the aquifer ranking site are placed as before.
