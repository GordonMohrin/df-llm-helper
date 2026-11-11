# BUG-725 embark scan: a 'light' panel on little soil gave no core-span warning
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-11-10, Run 16c i3 Doorwings (embark panel 'light aquifer', soil 'little'; real aquifer z131-z140 = 10 levels, heavy z131-z133: four shafts stopped on the heavy ring, no core ever; E13)
Module: `tools/embark/checklist.lua`, `tools/embark/rules.json` (`core_reach_warn`)

## Root cause
BUG-531's core reach = soil levels + core_span (light 8): 1 + 8 = 9 is not above `core_reach_warn` 9, so a light panel on little soil showed no core warning at all.

## Fix
`core_reach_warn` 9 -> 8 (checklist DEFAULT and rules.json): a light panel on little soil (9) warns; on no soil (8) it stays quiet. The warning text says a light panel hides heavy layers (Basementflew, Doorwings) and that only the first aqshaft shows the real span.

## Tests
`tests/lua/test_embark_bug531.lua`: light + little soil warns with the Doorwings text, light + no soil does not; the Basementflew case still warns once; rules.json equals the defaults.

## Live check
`embark.py scan` of a light-aquifer site on little soil shows the aquifer item as `warn` with 'the core must go under the aquifer: up to 9 levels'.
