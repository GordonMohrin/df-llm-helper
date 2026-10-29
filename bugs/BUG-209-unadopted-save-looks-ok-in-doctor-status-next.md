# BUG-209 an unadopted save looks OK in doctor, status and next
Status: fixed (offline, live-untested)
Severity: medium (a weaker model on a new embark plays on the numbers of an earlier fort)
Found: 2026-10-29, live round 3, i-test3 (E:/DF-test3, fresh fort Berkogan "Earthboat"), main 9da84d6
Module: `dfpilot/doctor.py`, `dfpilot/paths.py`, `dfpilot/brief.py`, `dfpilot/guide.py`, `dfpilot/cli.py`

## Actual
Before `dfhack-run dfllm adopt`, `dfllm reload` said 'no dfllm marker: save not adopted, kernel idle'. `status` and `doctor` then read
the newest runtime folder of an earlier fort ('region2-site96 (not ACTIVE) ... BLOCKED') and doctor said `verdict: OK`. paths.save_name
falls back to `_last_save()` when ACTIVE is missing; doctor.diagnose flagged the heartbeat only when ACTIVE names the folder; `next`
answered `dfllm doctor`.

## Fix
`doctor.df_up()`: is a Dwarf Fortress process running from this DF folder (the runtime root's parent; tasklist plus the process image
path, so another DF copy on the machine does not count). doctor: ACTIVE missing while DF runs here is a problem line 'ACTIVE missing:
the loaded save is not adopted (or kern is idle): dfhack-run dfllm adopt ...'; with DF closed it is a note. `paths.fell_back()`; status
line 1 says `(fallback: newest folder, not ACTIVE)`. `dfllm next` answers `NEXT: dfhack-run dfllm adopt`, also with no runtime folder.

## Tests
`tests/test_bug209_213_cli.py` (doctor, df_up, status line 1, next), each fails on bd27973.

## Live check
New embark, before adopt: `python -m dfpilot doctor` lists the ACTIVE-missing problem; `status` line 1 has `(fallback: newest folder,
not ACTIVE)`; `python -m dfpilot next` prints `NEXT: dfhack-run dfllm adopt`. After adopt all three are back to normal.
