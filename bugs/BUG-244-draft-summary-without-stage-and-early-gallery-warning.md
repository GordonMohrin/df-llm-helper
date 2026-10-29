# BUG-244 draft summary prints fortcore@same without the stage; gallery_o1 warning before stage 2 is dug
Status: fixed (offline, live-untested)
Severity: low (confusing output: the player swapped two core stages and check refused it; advice check then refuses)
Found: 2026-10-29, Run 15 Earthboat y372 and Drillchamber y373 (FR-BUGS.md)
Module: `dfpilot/plan.py` (`_summary`, new `build_label`, `_outer_gallery`, new `core2_dug`, `fort_facts.core2`)

## Actual
The propose/check summary listed builds as `tpl@site`, so stage 3 in s2 and stage 2 in s3 both read `fortcore@same`. The
warning "add tpl gallery_o1 to a season" came without the build's JSON and while fortcore stage 2 was not dug, when `plan check`
refuses the gallery anyway.

## Fix
`build_label` prints `tpl@site`, ` st<N>` for a staged build and ` (refuge)` for fortcore stage 3 (`fortcore@same st3 (refuge)`);
`_summary` uses it. `_outer_gallery` warns only when `core2_dug`: fortcore stage 2 applied (`fort_facts` `core2`) and no state
project at label `s2.dig`; the warning names `{"tpl":"gallery_o1","site":"S1"}`.

## Tests
`tests/test_bug241_244_plan_propose.py`: `test_summary_shows_the_stage`, `test_gallery_warning_waits_for_stage_2_dug`;
`tests/test_cli_plan.py::test_outer_gallery_warning_from_the_o1_phase` (new text). Fail on 6dc0f19.

## Live check
`dfllm plan propose` in a fort below stage 3: the draft line shows `fortcore@same st3 (refuge)` and `fortcore@same st2`; at P5
with stage 2 still digging there is no gallery warning, after s2.dig it comes with the JSON to add.
