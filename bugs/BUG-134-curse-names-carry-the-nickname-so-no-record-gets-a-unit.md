# BUG-134 Curse records never get a unit: the game names a citizen without his nickname, the index kept it
Status: fixed in the fix-live-curse commit (offline, live-untested)
Severity: high (no ids in CURSED/TRANSFORM/status/inspect, no `curse_kill` question, dead werecavies counted for months)
Found: 2026-10-28, live test i2 (E:/DF-test2, DFHack port 5001, region2-site90 y717, DF 53.16 / DFHack 53.16-r3) of the M4 curse package, confirmed by the verifier; the name-only popup in live test i1 (port 5000, y715)
Module: `lua/dfllm/curse.lua` (`nonick`, `name_key`, `short`, `index`, `own_ids`, `find_unit`, `forget`, `finish`, `kill_question`,
`inspect_curse`), `lua/dfllm/sense.lua` (`own_ids`), `dfpilot/guide.py`

## Actual
- All 51 citizens of i2 have a nickname. `getReadableName` = `Urvad Kûbukarban "Lancedcradles", Planter`; the game's texts say
  `Urvad Kûbukarban, Werecavy Planter has transformed into a dwarf!`. Every CURSED (#32253, #32412) and TRANSFORM (#32274, #32293,
  #32379, #32389) had no `d.unit` and no `d.ids`; every record stayed `n:<name>`; state `curse` = `{ids:[], n:1, tf:1}`.
- No DECISION_NEEDED `curse_kill` after four beast waves; the dead werecavies 41736 and 41657 stayed `tf=1` ("1 in were-form", `dead 0`).
- `inspect what=unit key=Lorbam Ekastreg` -> `no such citizen`; it worked only with the full nicknamed name and only after the census ran.
- i1: a popup "Urist McTest has been cursed ..." naming nobody kept `CURSED 1`, and `next` offered the brief for good ("1 cursed citizens").

## Causes
1. `short()`/`name_key()` (curse.lua:46-47) kept the quoted nickname; `index()` keyed every citizen by it, `parse()` gave the bare name,
   so `resolve()` never matched. `M.look` built its `n:` key from the nicknamed name too (a second record and a second CURSED).
2. `forget()` skipped non-numeric keys: an `n:` record lived forever. `kill_question` and `ids_of` took numeric keys only.
3. `find_unit` compared the nicknamed name and read the census only.

## Fix
- Names are compared without the quoted nickname (`"..."`, a backquote pair, guillemets), lower case, the part before the comma, in
  UTF-8 (a text still in CP437 goes through `dfhack.df2utf` first). The record name is the bare name.
- `finish` re-keys an `n:` record to its unit and drops a duplicate; `forget` drops an `n:` record that no unit matched for one moon cycle
  (`YEAR / curse_moon_cycles`; not counted as dead; kern.log says so); `inspect what=curse` lists such names (`unresolved`, "by name only").
- `kill_question` also asks about a were-form record known by name only, by name.
- `inspect what=unit key=<name>`: with or without the nickname, or the first name alone when one citizen has it; before the first census
  the fort's own come from the new `sense.own_ids` (unit iteration stays in sense, lint `unit-iter`).
- guide: "1 cursed citizen" in the TELL line.

## Tests
`tests/lua/test_curse_live.lua` (BUG-134 x3, the census test of BUG-137), `tests/test_curse_live.py` (the plural); they fail on dec5132.
