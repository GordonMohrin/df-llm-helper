# BUG-163 The fortcore re-site drafts only the stopped anchor's stages; a moved core never gets its stages 2 and 3
Status: fixed (offline, live-untested)
Severity: high (the new core has no B1 (stage 2) and, after the bp.cancel, a lone stage 3 @same; readiness keeps R0 no_inner)
Found: 2026-10-29, live test round 2 instance i3 (BUG-130 PARTIAL, finding NEW3, confirmed by the skeptic): with bp files y707s0b1 (stage 1)
and y707s0b3 (stage 3) at the damp anchor, propose drafted fortcore@S1 stage 1 + @same stage 3 (no stage 2). After the re-site was applied
(y722s2b0 stage 1 at 70,82,132) propose drafted no fortcore stage at all ("re-sited to y722s2b0; free its tiles"). The note cut the why text
mid-word (`core['why'][:100]`), and `plan check` warned "duplicate fortcore@same in one season" for stages 2 and 3.
Module: `dfpilot/plan.py` (`propose`, `core_need`, `core_resite`, `_cut`, `check`), `dfpilot/cmd.py` (`place`, `stage_anchor`, `anchor_label`)

## Actual
The re-site discarded and drafted only `core['stages']` (the stages applied on the stopped anchor); the moved branch drafted nothing.

## Fix
`core_need`: the later stages (>= 2) a re-sited core needs = the stopped anchor's stages plus the fortcore deliverables of every phase up to the
target. The re-site discards every fortcore stage from `done` and drafts stage 1 @S1 plus each needed stage @same. When the re-site was applied
(`core.moved`, now with its `rot` and the `stages` standing at its anchor; the current core's stage 1 is preferred) the needed stages the moved
core lacks are drafted at its explicit anchor `A<x>_<y>_<z>_<rot>` (not `same`, which may still name another placement), never a stage 1.
`cmd.place` lets a stage >= 2 at an explicit anchor overlap its own template's earlier stages there (as `same` does). `plan check` accepts
`A..` labels and counts duplicates per stage. The why text is cut at a word boundary (`_cut`).

## Tests
`tests/test_bug162_164_fortcore_resite.py` (`test_the_resite_drafts_stage_2_although_an_older_core_had_one`,
`test_a_moved_core_gets_its_missing_stages_at_its_explicit_anchor`, `test_an_explicit_anchor_stage_does_not_clash_with_its_own_stage_1`,
`test_the_why_text_is_cut_at_a_word_boundary`) fail on main b805745.
`tests/test_bug130_damp_fortcore.py::test_an_applied_resite_is_never_drafted_again` now allows the explicit-anchor stages and still forbids a
second stage 1.

## Live check
Re-site case: `dfllm plan propose` drafts fortcore@S1 stage 1, @same 2, @same 3; `plan check` OK without the duplicate warning. After it was
applied (bp has the new stage 1): propose drafts fortcore@A70_82_132_1 stages 2 and 3; `plan check` lists both at [70,82,132] rot1.
