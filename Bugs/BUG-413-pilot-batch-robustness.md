# BUG-413: `claude/pilot_batch` cuts UTF-8 characters in half when truncating (invalid UTF-8 output), aborts on a non-list command entry, rejects a BOM

- **Status:** verified fixed (retest 2026-10-02, 8e67f05) [static code review; lua5.4 not available, mock not run]
- **Severity:** S2 (output of the batch transport is not valid UTF-8 as soon as a truncated sub-command output contains a non-ASCII character; `transport.batch` is off by default - `config.py:35` "batch=true only after a live test")
- **Area:** `lua/pilot_batch.lua:24-30` (and the identical `lua/claude/pilot_batch.lua`)
- **Reported:** 2026-10-02, commit `6dedd96`
- **Environment:** Windows 11 Pro, Python 3.14.3, game running (DF 53.16 + DFHack, **paused**, date `27. Granite, Jahr 118`); live script = `lua/claude/pilot_batch.lua` (German messages)

## Command / steps
Request files are in the evidence folder (path with spaces is handled correctly, quoted):
```
cd "E:/Program Files (x86)/Steam/steamapps/common/Dwarf Fortress/hack"
./dfhack-run.exe claude/pilot_batch "C:/Users/admin/claude gordons projects/dfpilot-public/Bugs/evidence/BUG-413/req_utf8_truncate_max110.json"
./dfhack-run.exe claude/pilot_batch ".../req_cmds_element_is_number.json"
./dfhack-run.exe claude/pilot_batch ".../req_with_utf8_bom.json"
```
(`{"cmds": [["claude/units"]], "max_bytes": 110}`; `{"cmds": [123]}`; `\xEF\xBB\xBF{"cmds": [["claude/alert"]]}`.)

## Expected
Valid UTF-8 JSON in every case; one failing entry does not kill the others ("An error in one sub-command does not stop the others (pcall per command)").

## Actual
1. **Truncation inside a multi-byte character.** `out:sub(1, max_bytes)` (line 30) is byte based. With `max_bytes` 110 and 114 (scan 95..140) the text ends in `"name": "Stinth\xC3` + `\n... gekuerzt`, i.e. the first byte of `ä` without its second byte. Python's `bytes.decode("utf-8")` of the whole answer fails: `'utf-8' codec can't decode byte 0xc3 in position 168: invalid continuation byte` (verified).
2. **Non-list entry**: `{"cmds": [123]}` -> exit 1 and a Lua error, no JSON at all: `attempt to get length of a number value ... in function 'table.unpack' ... pilot_batch.lua:24`. `table.unpack(parts)` is an argument of `pcall(...)`, so it is evaluated **before** the protection. `{"cmds": ["claude/alert"]}` (string instead of list) is caught but with the cryptic `dfhack.lua:1158: Invalid arguments`. All remaining entries of the request are lost in case 2.
3. **BOM**: a request file written by PowerShell (`Set-Content`/`>` -> UTF-8 with BOM) gives `"Anfrage kein gueltiges JSON"`. The Python writer (`transport.py`) writes without BOM, so only hand-made requests are affected.
4. Documentation: header says "Output (stdout, one line)" - the real output is pretty-printed over several lines with `\r\n` and tabs (still valid JSON).
Working as intended (verified): empty list -> `[]`; nonexistent file -> `"Anfrage nicht lesbar: <path>"`; invalid JSON; unknown command -> `{"ok":false,"err":"Status -1","out":"claude/nonexistent_xyz is not a recognized command.\n"}`; `max_bytes: "abc"` -> default 20000; sub-commands that print text (`claude/area`) are returned as strings; paths with spaces (single-quoted for the shell).

## Evidence
`Bugs/evidence/BUG-413/utf8_truncate.out.txt` (raw bytes, invalid UTF-8 at the cut), `element_number.out.txt`, `bom.out.txt`, `element_string.out.txt`, plus the four `req_*.json` request files.

## Analysis (reporter's hypothesis)
See above. Also: the live copy and the top-level repo copy (`lua/pilot_batch.lua`) differ only in message language (BUG-420).

## Suggested fix (optional)
Cut at a character boundary: `local cut = max_bytes; while cut > 0 and (out:byte(cut + 1) or 0) >= 0x80 and (out:byte(cut + 1) or 0) < 0xC0 do cut = cut - 1 end`; wrap the whole per-entry body in one `pcall(function() ... table.unpack(parts) ... end)` and `type(parts) == 'table'`; strip a leading `\xEF\xBB\xBF` from `raw`.

## Info needed
- Cloud session: does `transport.py` decode with `errors="strict"`? (then case 1 raises). The mock in `tests/` cannot show it.

## Fix
Both copies: truncation at UTF-8 boundaries, non-list entries reported per entry (unpack inside the pcall), BOM stripped, `max_bytes` floored, header corrected. `client.py`/`transport.py` decode with `errors=replace`, so they never raised.
