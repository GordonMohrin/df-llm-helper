# BUG-150 Verb replies named the verb twice (`view: view: ...`) and view replies carried raw CP437 unit names (mojibake)
Status: fixed (offline, live-untested)
Severity: low (cosmetic, but every refusal and every name with an umlaut read wrong)
Found: 2026-10-28, live tests i1 (NEW3, NEW9) and i2 (NEW5); confirmed by the verifiers
Module: `dfpilot/cmd.py` (`fmt_reply`), `lua/dfllm/viewlib.lua` (`unit`)

## Actual
- `ERR ... view: view: no saved player position`, `ERR ... resume: resume: the game is not paused`, `zone.place: zone.place: the box
  overlaps`: the Lua verbs start their messages with their name and `fmt_reply` printed `<verb>: <msg>`.
- `camera on Kumil Cogn?ng "Bootburn", Administrator (39052)` (an invalid UTF-8 byte): `viewlib` read `getReadableName` without
  `dfhack.df2utf`.

## Fix
- `fmt_reply` drops a leading `<verb>: ` from the message (the common reply path: every verb, every caller).
- `viewlib.unit` converts the name with `dfhack.df2utf`. The other name reads in lua/dfllm already convert (snapshot.find_units,
  care.uname, deaths).

## Tests
- `tests/test_bug150_reply_text.py` (prefix not repeated: fails on main; other messages unchanged: pin).
- `tests/lua/test_bug150_151_view.lua` (a CP437 0x81 in the name comes back as UTF-8: fails on main).
