# BUG-159 The brief trims the TIMELINE_RESET marker, status clips the hospital.retire hint
Status: fixed (offline, live-untested)
Severity: medium (the session never learns that an older save was loaded, and never sees the one command that clears R0 hospital_out)
Found: 2026-10-29, live test round 2, instance i1 (Trussroads y721-y722), items NEW7 and BUG-131b, both confirmed by the skeptic
Module: `dfpilot/brief.py` (`Ctx._scan`, `line_reset`, `line_hosp_retire`, `line_unready`, `status_text`, `brief_text`)

## Actual
1. NEW7: a TIMELINE_RESET inside the 1-year window lived only in `## digest B (last year)`, the last section; `fit()` trims that one first, so
   the default `dfllm brief` (1500 tokens) of a big fort never named it. Only `brief --budget 20000` did.
2. BUG-131b: `hospital_retire_hint` was the last `next:` item of the long R0 line; status ranks that line 2 and clips it to 90/60 tokens, so
   status ended `... | next: wall it: dfllm~` and named neither zone 26207 nor `hospital.retire`. The line also said "plan it inside Tiefe+
   next to accepted water (a cistern there first)" while a finished hospital inside existed (`water.hout.ok == 1`).

## Fix
1. `Ctx._scan` keeps the newest TIMELINE_RESET of the window (beyond the B limit); `brief_text` puts `line_reset` right after the clock line:
   `TIMELINE RESET y3 sum d18: older save loaded (tick A -> B); events up to #N belong to the discarded timeline and are dropped`. The digest
   keeps its entry.
2. Status: `line_hosp_retire` = `hospital_out: <hint>` as its own rank-1 line; `line_unready(cmds=False)` leaves the hint out. With
   `hout.ok == 1` the R0 line says "a finished hospital inside exists, retire the old zones" instead of the plan-it-inside sentence.

## Tests
`tests/test_bug159_161_live2.py` (the TIMELINE RESET head line, the status line, the advice with ok 1/0); `tests/test_bug131_hospital_retire.py`
expects the hint on its own line. All fail on main b805745.

## Live check
Emit a fake TIMELINE_RESET at the current tick, `dfllm brief` (default budget): line 2 is `TIMELINE RESET ...`. With an outside hospital zone
and a lying patient, `dfllm status` shows `hospital_out: zone Z at x,y,z blocks it: ...; dfllm cmd hospital.retire zone=Z`.
