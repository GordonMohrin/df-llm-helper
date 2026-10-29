# BUG-164 applied_builds counts fortcore stages of an older core at another anchor
Status: fixed (offline, live-untested)
Severity: medium (the current core's stage 2 is never drafted; stage 3 is drafted @same without it)
Found: 2026-10-29, live test round 2 instance i3 (finding NEW3, skeptic re-check): bp held y497s3b0 (fortcore stage 2 at 122,68,132, an older
core) and y722s2b0 (stage 1 at 70,82,132, the current one). After the bp.cancel of the damp core propose drafted only fortcore@same stage 3.
Module: `dfpilot/plan.py` (`core_anchor`, `applied_builds`, `core_gaps`, `propose`)

## Actual
`applied_builds` was keyed (tpl, stage) across every anchor, so ('fortcore', 2) of y497s3b0 marked stage 2 as done for the new core.

## Fix
`core_anchor`: the current core's anchor (bp/.placed-fortcore.json when a fortcore project stands there, else the newest fortcore stage 1).
`applied_builds` counts a fortcore stage (not a retrofit) only on that anchor. `core_gaps` (propose with known applied builds): a drafted
fortcore stage k >= 3 gets every stage 2..k-1 that is neither done on the current anchor nor drafted, inserted before it at the same site.

## Tests
`tests/test_bug162_164_fortcore_resite.py` (`test_applied_fortcore_stages_count_on_the_current_core_only`,
`test_a_lone_stage_3_gets_the_cores_stage_2_first`) fail on main b805745.

## Live check
With an older fortcore stage 2 elsewhere and the new core's stage 1 placed: `dfllm plan propose` drafts fortcore@same stage 2 before stage 3.
