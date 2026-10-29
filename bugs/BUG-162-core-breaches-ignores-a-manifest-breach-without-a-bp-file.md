# BUG-162 `plan propose` ignores a manifest breach of a fortcore without a bp file; `plan check` rejects the draft
Status: fixed (offline, live-untested)
Severity: high (propose and check disagree: every automatic plan of the fort is refused, BUG-130 never takes the closure path)
Found: 2026-10-29, live test round 2 instance i3 (region2-site90 Trussroads y723, finding NEW4, confirmed by the skeptic): the runtime's `bp/`
held no files while manifest.breaches had `{proj y707s0b1, tpl fortcore, why damp, pos 50,42,127}`. propose drafted seal@S1 at=refuge,
refuge_beds and a plain fortcore@S1 stage 1 + @same 2, 3 without a BUG-130 note; `plan check` refused it: "bp.sites.rank(fortcore): fortcore:
no dry fortcore site: every site's dig lies within 10 tiles of a recorded breach (wet level z128 (4 damp/water stops))".
Module: `dfpilot/plan.py` (`core_breaches`, `core_resite`)

## Actual
`core_breaches` collected only fortcore bp files and returned `[]` without one, so the manifest row was ignored, `fort.core` stayed None and
propose drafted the normal fortcore deliverable, which the ranking (it reads every manifest breach) has no site for.

## Fix
A manifest `breaches` row with `tpl == "fortcore"` and no bp file counts as a stopped core (stage from its state.proj label `s<N>.`, else 1;
anchor unknown), unless the project is done (PROJECT_DONE) or cancelled (`bp/.cancelled/<id>.json`, written by `cmd.retire`). An AQ_OBSERVE
newer than its stop (FR-95 observe mode) clears it as before. `core_resite` ignores the unknown anchor. With no dry site propose takes the
BUG-130 closure (seal at=last, phase_target below P3, the bp.cancel line), which check accepts.

## Tests
`tests/test_bug162_164_fortcore_resite.py` (`test_a_manifest_breach_without_a_bp_file_is_a_stopped_core`,
`test_propose_and_check_agree_without_bp_files` fail on main b805745; the cancelled/done and observe-mode cases are pins).
`tests/test_bug130_damp_fortcore.py`: its "cancelled" case now retires the project (`cmd.retire`) instead of deleting the bp file, the real
cancel path.

## Live check
In a runtime whose bp/ lacks the parked core's file (i3): `dfllm plan propose` drafts `seal@S1 at=last`, no fortcore, phase_target P2, note
"BUG-130 ... cannot move (...)"; `dfllm plan check` on that draft: no fortcore ERROR.
