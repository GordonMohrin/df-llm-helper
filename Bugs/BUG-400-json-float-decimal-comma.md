# BUG-400: util.emit prints non-integer numbers with a decimal comma -> invalid JSON (gefahr `fps: 250,0`, migranten `gefaehrlichkeit: 3,9375`)

- **Status:** verified fixed (retest 2026-10-02, 8e67f05) [static code review; lua5.4 not available, mock not run]
- **Severity:** S2
- **Area:** `lua/claude/util.lua` (`emit`), triggered by `lua/claude/gefahr.lua:330`, `lua/claude/migranten.lua:103,109`
- **Reported:** 2026-10-02, commit `6dedd96`
- **Environment:** Windows 11 Pro (German locale), Python 3.14.3, game running (DF 53.16 + DFHack, **paused**, fort "Windrings", date `27. Granite, Jahr 118`), live scripts from `dwarf-fortress/lua/claude` (identical to repo for these files except hard-coded paths)

## Command / steps
```
cd "E:/Program Files (x86)/Steam/steamapps/common/Dwarf Fortress/hack"
./dfhack-run.exe claude/gefahr status
./dfhack-run.exe claude/migranten status
```
Then `python -c "import json,sys; json.loads(sys.stdin.read())"` on the output.

## Expected
Exactly one valid JSON object (COMPANION.md: "All scripts print one JSON object (`util.emit`)").

## Actual
`claude/gefahr status` (line 5 of the output):
```
	"fps": 250,0,
```
`claude/migranten status` (line 26):
```
		"gefaehrlichkeit": 3,9375,
```
`json.loads` -> `Expecting property name enclosed in double quotes: line 5 column 13` / `line 26 column 24`.
Both outputs are otherwise complete. The known legacy defect (`"fps": 250,0,`) is therefore **still current**, and it is **not specific to gefahr**: any Lua float that is not rendered through `math.floor` hits it (migranten is a second hit; I found no third one in the 90+ read-only calls I made, but every script that emits a raw DF float field is exposed).

## Evidence
`Bugs/evidence/BUG-400/gefahr_status.out.txt`, `Bugs/evidence/BUG-400/migranten_status.out.txt` (raw stdout; `.cmd.txt` has command, exit code and runtime).

## Analysis (reporter's hypothesis)
- `df.global.enabler.fps` (gefahr.lua:330) is a float; `migranten.lua` `danger()` returns a float. DFHack's `json.encode` uses Lua `tostring()` for numbers, and Lua's number-to-string honours `LC_NUMERIC`. The DF/DFHack process runs with the Windows system locale (German: decimal comma), so `250.0` becomes `250,0`.
- The Python side already works around it: `df_llm_helper/client.py:116` `_DEC_COMMA` / `parse_json_tolerant`. That regex cannot repair a decimal comma **inside arrays** (`[1,5]` is indistinguishable from two integers) and any other consumer (jq, a second parser, fixtures read with `json.loads`) fails.
- Related type instability in the same function: an empty Lua table is encoded as `[]` even where an object is meant (e.g. `claude/buildings 999` -> `"counts": []`, `claude/pilot_water scan` -> `"by_z": []`, `claude/pilot_hygiene status 1000000 10` -> `"area": []`). Python consumers are tolerant today (`hygiene._add` checks `isinstance(src, dict)`), but it is the same class of problem.

## Suggested fix (optional)
Rounding the float in `to_utf8` is not enough (the encoder formats it again with the locale). In `util.emit` either (a) wrap the encode: `local old = os.setlocale(nil, 'numeric'); os.setlocale('C', 'numeric'); local s = json.encode(t); os.setlocale(old, 'numeric'); print(s)`, or (b) convert every non-integer number to a string with `string.format('%.4f', v):gsub(',', '.')` and accept strings in the consumers. Option (a) is one place and keeps arrays intact.

## Info needed
- Cloud session: can the Lua mock (`tests/`) set `LC_NUMERIC=de_DE` and assert that `util.emit({x=1.5})` yields `1.5`? (Only possible if the mock uses a real Lua; `lua5.4` is optional.)
- Player: please run `os.setlocale(nil,'numeric')` once via `dfhack-run lua` to confirm the game's numeric locale (I did not run ad-hoc Lua against the game on purpose).

## Fix
`util.emit` encodes a copy in which non-integer numbers are placeholders, replaced after `json.encode` by locale-independent text (`250.0`, also inside arrays); NaN/inf -> null. Mock test with an emulated German locale (`MOCK_DECIMAL_COMMA=1`, `tests/test_lua_claude.py`), also end to end on `gefahr status`. Not changed: empty tables still encode as `[]` (consumers are tolerant). Player: re-install `util.lua`; `os.setlocale` check no longer needed.
