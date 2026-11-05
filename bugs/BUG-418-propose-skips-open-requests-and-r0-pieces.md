# BUG-418 plan propose does not draft the open PROJECT_REQUESTs, the missing mood shops or the refuge pieces R0 asks for
Status: fixed (offline, live-untested)
Severity: high (Run 16d i4 Mazelanterns: 15 homeless, `mood shops missing 4124 days`, refuge_dry for years; the player added the builds by hand every year)
Found: 2026-11-05, `runs/run-16d/FR-BUGS.md` (y384-y391: 'bedrooms x19', 'propose liefert Mood-Werkstaetten nicht', 'propose soll refuge_drink selbst zeichnen'), main b4087f4
Module: `dfpilot/plan.py` (`propose`, `fort_facts`, new `request_facts`, `request_drafts`, `mood_ws_missing`, `drink_draft`)

## Actual
- The kernel asks `PROJECT_REQUEST bedrooms n=19 why "free 0 < homeless 15 + 4"` every ~9 days (events #5385-#5404); follow places only the
  why values it knows (stone dig, farms, shops, tombs, office), so nothing built bedrooms; `propose` had no input from requests at all.
- `status` said `mood shops missing N days: Jewelers,MetalsmithsForge,Clothiers +4` (R0 `mood_ws`) and `propose` y384/y385/y386 had no `workshops`
  entry; the player wrote `workshops@S1 only=...` into s0 every year.
- R0 `refuge_dry` since y384 (Tiefe+ drink 0<66) and `propose` y384-y390 never drafted `refuge_drink`: `drink_draft` (plan.py, FR-69) returned
  None as soon as a store stood (`_drink_store`, 6 tiles, 0 barrels) or `(refuge_drink, None)` was applied once, so an empty store was waited
  on for years.

## Cause
`propose` (plan.py, after the phase deliverables) drafted only phase deliverables and the fixed gap drafts; open requests and the R0 blocker
list (`state.ready.fail`: `mood_ws`, `refuge_dry`) were warnings or status lines, never builds; `drink_draft` had no way to ignore a store that stands.

## Fix
- `request_facts(save_dir, state)` -> `fort.requests`: the open PROJECT_REQUESTs of the last 40 game days before the newest event, newest per
  template, for `bedrooms` (not the stone dig `why` mood_rock/rock, follow places those), `refuge_beds`, `refuge_drink` and `workshops` with
  `types` (reduced to the types the fort manifest lacks); closed by a later PROJECT_DONE of a project of that template, and not open while a
  project of that template is under way (not done, not parked in `state.proj`).
- `mood_ws_missing` -> `fort.mood_ws`: `cmd.workshops_missing` while R0 names `mood_ws`.
- `request_drafts` (called from `propose` right after the phase deliverables): `bedrooms`/`refuge_beds` with the request's `n` (clamped to the
  template limit), one `workshops` build with `p.skip` = the other moodable types (+ `p.add` for non-moodable types) for the requested/missing
  shops, `refuge_drink` while R0 says `refuge_dry` and the standing store is smaller than the citizens' need (`drink_draft(force=True)`: the missing
  part, want - tiles, as a second store; a store of the right size still waits for barrels (FR-69); none under way, a site exists). Each is drafted once: the same template+params in the draft, in the same year's plan that stays, or
  already drafted is not repeated. The notes say `BUG-418: open requests and R0 blockers drafted: ...`.

## Tests
`tests/test_bug418_419_requests_wet_core.py`: request facts (newest per template, stone dig/old/other templates left out, closed by DONE or a
project under way, parked stays open); propose drafts bedrooms x19 + refuge_beds once and not again in a second draft; mood shops with `skip`;
`mood_ws_missing`; refuge_drink for the part a small standing store lacks under R0 refuge_dry (not for one of the right size / under way / no site / no blocker).

## Open
- A standing store of the right size that stays empty (haulers bring no barrels) is not changed: no second store helps there, `inspect what=refuge`
  stays the diagnosis.
- `refuge_beds` is drafted from a request or from the existing alert.ref shortfall (`refuge_drafts`); R0 has no `refuge_beds` blocker of its own.

## Live check
A fort with a recent `PROJECT_REQUEST bedrooms` (not rock) and no bedrooms project under way: `dfllm plan propose` lists `bedrooms@S1 n=<n>` and
the BUG-418 note; with R0 `mood_ws` a `workshops` build with `skip=...`; with R0 `refuge_dry` and a standing store a `refuge_drink` build.
