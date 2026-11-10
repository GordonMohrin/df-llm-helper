# BUG-649 Embark scan no brook with a light aquifer only warns
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-10, Run 16b i2 Valleyhame y372: embark scan 'no stream shown; light aquifer as well source' (warn), brook 13 embark tiles away, drink 0 d on day 78, STRANDED; the panel said 'light aquifer', the site had 8 heavy layers
Module: `tools/embark/checklist.lua`

## Actual
The scan took the site as `ok ... warn=water`; the fort had no water source before its aquifer was passed.

## Root cause
`checklist.evaluate`: `rec.aquifer == 'light'` and no `rec.water` was a `warn` ('light aquifer as well source') whatever the aquifer's span.

## Fix
A full panel read (no sweep) with a light aquifer and no brook in the rectangle is a FAIL of `water` (acceptable with a reason, `--accept water=...`); the text says the panel class is not a span (8 heavy layers at Valleyhame, 14 levels at Basementflew). A sweep (few hovered tiles) stays a warning that names the span.

## Tests
`tests/lua/test_embark_bug649.lua` (2)

## Live check
`embark.py scan` on a rectangle without a brook but with a light aquifer lists `fail=water`; `embark ... --accept water=<reason>` still embarks.
