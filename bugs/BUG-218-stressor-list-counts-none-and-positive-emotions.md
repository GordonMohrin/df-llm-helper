# BUG-218 The weekly stressor list counts 'None' and emotions that lower stress
Status: fixed (offline, live-untested)
Severity: low (misleading text: the list does not show what stresses the fort)
Found: 2026-10-29, live round 4 (Earthboat, E:/DF-test3) and its skeptic; the care part of BUG-205's re-check
Module: `lua/dfllm/care.lua` (`thoughts`, `M.stressor`)

## Actual
'top stressors this week' was led by 'None=361 ... SatisfiedAtWork=21'. `thoughts()` counted every emotion of a stressed
citizen by its thought name: emotions with no thought (df.unit_thought_type[-1] = 'None') and emotions that lower stress
(satisfaction, contentment) included.

## Fix
`M.stressor(e)` reads `df.emotion_type.attrs[e.type].divider`: DF adds strength / divider to the stress
(hack/scripts/add-thought.lua:36-38), so a divider > 0 is a stressor and <= 0 is not. `thoughts()` skips the name 'None' and
emotions whose type is not a stressor; an emotion whose type cannot be read counts as before. The FR-74 sources (`src`) use
the same filter.

## Tests
`tests/lua/test_care.lua`: 'BUG-218 (live 4: None=361 ... SatisfiedAtWork=21) ...', fails on 5e9e719.

## Live check
After a game week kern.log's 'care: top stressors this week: ...' (and `inspect` stress top) has no 'None' and no positive
thought such as SatisfiedAtWork; only thoughts of stress-raising emotions are listed.
