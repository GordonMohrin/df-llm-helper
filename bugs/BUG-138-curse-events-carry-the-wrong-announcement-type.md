# BUG-138 CURSED says `ann=POPUP` and a TRANSFORM carries the curse's type: the live data the field exists for was wrong
Status: fixed in the fix-live-curse commit (offline, live-untested)
Severity: low (a diagnostic field)
Found: 2026-10-28, live test i2 (E:/DF-test2, DFHack port 5001, region2-site90 y717, DF 53.16 / DFHack 53.16-r3) of the M4 curse package, confirmed by the verifier
Module: `lua/dfllm/curse.lua` (`M.popup_type`, `M.LIVE_TYPES`, `M.report`), `lua/dfllm/care.lua` (`M.curse_text`)

## Actual
`#32253 ... CURSED ... [ann=POPUP ...]`: the BOX announcement DEITY_CURSE pauses the game as a popup before its report reaches kern,
so the arbiter's pull hook (`care.curse_text`, type `POPUP`) came first; the report changed the record later, silently. `#32274` (Olon's
first transformation) said `ann=DEITY_CURSE`; it should say `BODY_TRANSFORMATION` (reports 173685, 173894, 173906).

## Fix
`care.curse_text` passes `CU.popup_type(text)`: the type of a recent report (the last 50) with the same text, else the type 53.16 uses
(live: `DEITY_CURSE` for "has been cursed by", `BODY_TRANSFORMATION` for "has transformed into"), `POPUP` only for neither. The TRANSFORM
queue entry carries the type of its own report (`ev.type`); the record keeps the curse's.

## Tests
`tests/lua/test_curse_live.lua` (BUG-138).
