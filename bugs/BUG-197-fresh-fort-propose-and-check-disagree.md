# BUG-197 fresh fort: `plan propose` drafts room builds `plan check` can never site and prints no ERROR
Status: fixed (offline, live-untested)
Severity: high (year 1 of a new fort has no plan: check rejects with an ERROR that names no fix)
Found: 2026-10-29, live test round 3, Earthboat y372 (finding F5, skeptic re-check)
Module: `dfpilot/plan.py` (`propose`, `run`, `_dry_place`, `core_order_note`, `fort_facts`)

## Actual
(1) propose ran `check()` only; check also runs the `place_all` dry run, so check said `ERROR blueprint: bp.sites.rank(farms):
farms: room sites need the fort manifest with zones.Z4` for a draft propose printed without ERROR. A fort with no fortcore and
no Z4 got farms, dining, office ... in year 1 and target P5, and core_order_note stayed silent (it needs a core project row).
(2) core_order_note tested `startswith('s1.')`, so s1.build said "is not dug yet". (3) propose's own hospital note said
"Water Source zone", which the fair-play word list ('source') flags.

## Fix
`fort_facts` adds `z4` (the fort manifest has zones.Z4) and `core_any` (a fortcore project in any stage). propose with z4 False
and no fortcore applied, planned or parked: only fortcore stage 1 (added when the phases lack it) and seal builds, no explore,
phase_target = the current phase, order libraries of the current phase only, and the note "apply, wait for s1.dig, propose
again". `plan propose` runs the same placement dry run as check (`_dry_place`) and prints its ERROR and placement lines.
core_order_note needs `s1.dig` and, given fort facts, also speaks when there is no core and no Z4. The note reads "a well or a
water zone on deep water". Review: the other texts that reach the notes say so too (hospital_water's `why`, the stress causes
"no cause named", bp/sites.py's hospital refusals), and in the fresh-fort case the notes name no stone dig, cistern or temple
that was left out and end with the fresh-fort line (offline on a copy of Earthboat the first fix still gave `warn fair play:
$.notes mentions 'source'`).

## Tests
`tests/test_bug195_198_plan_place.py` (`test_propose_prints_the_placement_dry_run`, `test_a_fresh_fort_drafts_only_the_core_first`,
`test_core_order_note_needs_the_dig_and_speaks_without_a_core`, `test_the_hospital_water_note_has_no_blocked_word`), fail on bd27973.

## Live check
A new embark: `python -m dfpilot plan propose <scratch>/p.json` drafts only fortcore@S1 stage 1 (and seal), target P0, notes end
"apply, wait for s1.dig, propose again"; `python -m dfpilot plan check <scratch>/p.json` says OK.
