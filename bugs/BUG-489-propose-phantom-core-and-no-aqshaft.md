# BUG-489 PROPOSE draws fortcore st2/st3 and seal@refuge on phantom depths and no aqshaft while stage 1 is parked for a heavy aquifer
Status: fixed (offline, live-untested)
Severity: high (the fort never got a way under the aquifer; the plan was copied by hand for years)
Found: 2026-11-05, Run 16a i1 Basementflew y388-y390 (FR-BUGS "plan propose zeichnet den aqshaft nicht", "Aquifer-Ebenenliste inkonsistent (119 vs 123)"): `bp sites aqshaft` listed two columns (S1 45,15,129), `plan propose` drew fortcore st2/st3 + seal@refuge instead; `bp sites fortcore aquifer=pass/above` found 0 sites
Module: `dfpilot/plan.py` (`aq_shafts`, `core_stands`, `aquifer_late`, `aquifer_late_swap`, `surface_facts`, `propose`)

## Actual
Stage 1 of the fortcore was parked on `breach:heavy_aquifer` (nothing of it dug); an earlier aqshaft (placed by hand, finished) lay in the files. `propose` kept the later fortcore stages (@same) and the refuge seal, which hang on a core that does not exist ("phantom depths"), and drew no aqshaft.

## Root cause
`plan.py` `aquifer_late` (BUG-429, the aqshaft for the rest of a core) returned `None` as soon as ANY aqshaft was placed (`any(t == AQSHAFT in applied)`), and `propose` again tested `fort.aqshaft` (placed in any state); `surface_facts` computed it only with a fortcore applied. A shaft that had ended above the known levels (BUG-490) therefore counted as "the pass is done"; the parked stage 1 kept its later stages in the draft, and `aquifer_core_swap` was called with `have_shaft = fort.aqshaft`.

## Fix
- `aq_shafts` (bp files + AQ_PASS_DONE `bot`): placed / live (not finished) / lowest bottom. `aquifer_late` is due again when every placed shaft is finished and its bottom lies at or above the lowest known aquifer level (`late.gap` {bottom, below, parked}); a live shaft, an unknown bottom or a shaft below every known level is None as before. It is computed with or without a fortcore applied.
- `aquifer_late_swap`: with `gap.parked` (no fortcore stage 1 finished: `core_stands`) the aqshaft comes first and every fortcore build and every `seal at=refuge` of the draft is dropped (note "BUG-489 ... parked core piece(s) left out"); the core is drafted again once the shaft passed. With a standing core the later stages get `p.aquifer=pass` as before.
- `fort.aq_live` replaces `fort.aqshaft` in `propose`'s test; `aquifer_core_swap` gets `have_shaft = False` when the placed shaft is short (`aq_late.gap`).
- Level list: see BUG-490 (the manifest `aquifer_levels` now holds the heavy levels too; `sites.known_aquifer` already unites manifest, snapshot and breach layers).

## Tests
`tests/test_bug488_490_f30.py` (gap detection; no gap for a passed or live shaft; propose draws the aqshaft first without the parked core; a standing core keeps its stages with p.aquifer=pass); `tests/test_bug429_431_aqprop.py` unchanged and green.

## Live check
A fort with a parked fortcore stage 1 and a finished short aqshaft: `plan propose` shows `aqshaft` first, no fortcore, no `seal at=refuge`, note "BUG-489"; after the new shaft passes (`AQ_PASS_DONE`), the next propose draws the core (`bp sites fortcore aquifer=pass` finds sites).
