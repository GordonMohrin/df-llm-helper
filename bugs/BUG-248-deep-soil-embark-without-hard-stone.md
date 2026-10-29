# BUG-248 deep-soil embarks without hard stone within reach (stone accepted without a plan)
Status: fixed (offline, live-untested)
Severity: medium (no levers, mechanisms or mood boulders for years; Guildcleans lost a strange mood)
Found: 2026-10-29, Run 15 Guildcleans ("stone free 0", "moods missed rock") and Run 15b Earthboat ("Mechanismen fehlen: kein
Hartgestein")
Module: `tools/embark/checklist.lua` (`stone`, `C.soil_levels`, `C.NEEDS_PLAN`), `tools/embark/rules.json`
(`hard_stone_levels`, `soil_levels`), `tools/embark/steps.lua` (`S.gate`), `tools/embark/embark.py` (`--explore-first`)

## Actual
`stone` failed for deep soil, but `--accept stone --reason TEXT` let the fort embark anyway, with nothing that made it reach
stone; there was no "hard stone within N levels" rule.

## Fix
rules.json `hard_stone_levels` (6) and `soil_levels` (estimated soil levels per panel soil depth: little 1, some 3, deep 8, very
deep 15, extremely deep 25; calibrate live): `stone` also fails when the estimate of the best hovered tile exceeds the limit,
and its reason names the estimate. Waiving or accepting `stone` (checklist `C.NEEDS_PLAN`) needs `--explore-first TEXT` (10+
characters: how the fort reaches stone in its first season), checked by embark.py and the gate; the plan goes into the run
warnings (`site.gate: explore first (...)`) and into accept.log's line of `stone`.

## Tests
`tests/lua/test_embark_fix6.lua` `BUG-248 ...` (the level limit; accept stone refused without a plan, passed with one);
`tests/test_bug245_250_embark_tools.py::test_bug248_...`; `tests/test_embark.py` main test now passes `--explore-first`. Fail on
6dc0f19.

## Live check
`embark.py scan` on a deep-soil site: `stone` fails with "about 8 levels of soil, hard stone wanted within 6". `embark ...
--accept stone --reason x` is refused before any DF call; with `--explore-first "..."` accept.log's stone line ends with
`explore first: ...`. Compare the first stone z-level in the fort with the estimate after the first explore shaft.
