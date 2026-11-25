# BUG-857 The ladder printed commands the tool or kernel had refused with a reason, again and again
Status: fixed (offline, live-untested)
Severity: medium
Found: Run 17 round 4 (`leitung/neu3/LIVE-DIAGNOSE-2026-11-24.md` Nachtrag 25.11.): NAECHST repeated `tombs.repair` for unreachable corpses ('not repairable: memorial slab'), `bp.place seal at=last` ('nothing to close'), `bp.place refuge_drink` ('no site') and a Still although DF said containers were missing.
Module: `dfpilot/leiter.py` (`refusal_evidence`, `blocked_evidence`, `_state_blocked`, `t_versorgung`)

## Root cause
`blocked_evidence` knew three kinds of evidence (a breach block event, `bp sites ... free 0`, trade `nb`); a refused command left no trace the ladder read. The Versorgung step named a Still unless the state flag `dcx` was set (it is set only together with the drink cause text).

## Fix
`refusal_evidence(save_dir, cmd, hours)`: the newest reply (`cli.log`, written by the tool itself: `verb:<v>` with the args and the command id, `reply:<v>` with `ok ...` / `ERR ...`) to the verb behind the track's command (and its `tpl=` / `job`) inside `leiter.blocked_hours` (6 real hours). A reply that starts with ERR or says refused / not repairable / nothing to close / no site / cannot is evidence: `bp.place seal abgelehnt: ERR refused: seal: nothing to close ... (cli.log, vor 3 min)`. The track is then BLOCKIERT with the tool's reason (it leaves the NAECHST / OFFEN candidates, the next track becomes NAECHST); a later ok reply of the same command clears it. No file the player writes is read (cli.log is the CLI's own log, read the same way for `bp.sites`).
Versorgung: `stock.dcx` OR DF's words 'empty food storage' in `stock.dwhy` name containers, not a Still; the command is `order.add MakeBarrel amount 15` with `mat rock` when `stock.wood == 0` or `nowood` (the players' working command), else wood.

## Tests
`tests/test_neu7_vorrat.py`: tombs.repair refused -> BLOCKIERT Wohl I with the reason, NAECHST moves on, an ok clears it; seal matched by template (a refused `workshops` is no evidence for `seal`) and by window; refuge_drink 'no site'; Versorgung rock / wood and the dwhy-only case.

## Live-Erwartung
After a refused command (any of the four above) the next `brief` / `status` LEITER block shows `BLOCKIERT <Spur> <Stufe>: <verb> abgelehnt: <reason>` and NAECHST names another track (PROMISED where the refusal went through the CLI, so cli.log holds it; a refusal the kernel only logs in kern.log or announces later as an event is NOT seen). Versorgung on i4 (wood 0 usable): NAECHST `order.add ... "mat":"rock"`.
