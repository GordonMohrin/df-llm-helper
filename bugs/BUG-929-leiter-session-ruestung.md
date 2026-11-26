# BUG-929 `leiter --sitzung`: "Ruestung 5/6->0/6" counts soldiers of off-duty squads as unequipped and divides by the ladder's threshold
Status: fixed (offline, live-untested) for the session line; the ladder track itself is not changed
Severity: low (misleading balance line)
Found: Run 17 i2 Whirledrampart: session balance "Ruestung 5/6->0/6" with 9 soldiers in the squads. Diagnosis `leitung/neu10/DIAGNOSE-i4-drill-alarm.md` C.
Module: `dfpilot/leiter.py` (`kit_duty`, `start_session`, `session_lines`), `lua/dfllm/military.lua` (`M.kit_stats`, `M.state`), `lua/dfllm/util/contract.lua`, `dfpilot/schema.py`

## Cause (PROVEN in the code)
- `session_lines` compared `sess.full` with `state.mil.kit.full` and printed both over `RUESTUNG_FULL[0]` = 6, the ladder's level threshold, not a soldier count.
- `kit.full` (`military.kit_stats`) counts what is WORN: armor and a weapon. The militia squad B is on duty only in its own window (`off_season`); DF strips an off-duty soldier (BUG-864), so in the free months every soldier of that squad counted as unequipped (full 5 -> 0 with nobody losing a piece).

## Fix
- `military.kit_stats`: `off` (soldiers of squads off duty now), `nd` (on duty), `fulld` (of those fully equipped); `mil.kit` carries them (schema + contract optional keys).
- `leiter.kit_duty(kit)` returns (on-duty full, on-duty soldiers, off-duty soldiers); an older state without the keys reads as before. The session start stores `full` (on duty) and the new `fn`; the line reads `Ruestung 5/9->0/4 im Dienst voll (5 ausser Dienst nicht gezaehlt)`.

## Not done
- The ladder track `t_ruestung` still reads `kit.full` / `kit.n` against 6 / 10: off-duty months can still lower the track level (the test shows `Ruestung II->I`); changing it moves the ladder's levels and gates, not decided here.
- `inspect military` (assignments, not worn gear) was not read.

## Tests
`tests/test_bug929_leiter_session.py` (5).

## Live-Erwartung
After `leiter --start` in the militia's on-months and `leiter --sitzung` in its free months: no `Ruestung 5/6->0/6`; the line names the on-duty soldiers and the off-duty ones left out.
