# BUG-239 write_json_atomic: one fixed temporary name per file ('cannot save state: WinError 2 ..follow.json.tmp')
Status: fixed (offline, live-untested)
Severity: low (one lost `.follow.json` write per race, a stderr line; the symptom of BUG-238)
Found: 2026-10-29, Run 15 Inkintense (y373)
Module: `dfpilot/files.py` (`write_json_atomic`, `tmp_path`)

## Actual
`follow: cannot save state: [WinError 2] ... ..follow.json.tmp -> ...\.follow.json`. Every writer of a file used the
same temporary name `.<name>.tmp`; with two follow processes one `os.replace` moved the other's temporary file away and the
second replace raised FileNotFoundError, which the retry loop (PermissionError only) let through.

## Fix
The temporary file is `.<name>.<pid>.tmp` (`files.tmp_path`), so two processes never share one. A FileNotFoundError at the
replace writes the temporary file once more and retries; a second miss raises to the caller, which logs it as before
(`cannot save state`). After the last PermissionError the temporary file is removed.

## Tests
`tests/test_files.py::test_bug239_*` (pid in the name; a vanished temporary file is written again; a second miss raises
after one rewrite). All fail on 6dc0f19.

## Live check
No `cannot save state: [WinError 2]` on the follow's stderr in a whole session; no `..follow.json.*.tmp` left in the save
folder after follow ends.
