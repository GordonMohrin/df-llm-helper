# BUG-700 `supervise --once` starts DF, the process is gone when the supervise process exits
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-11-10, Run 16b i2 (`timeout 200 python -m dfpilot supervise --once` from Git Bash: after two 'DF down' answers it restarted DF, then `--load` said 'DF is not running'; PowerShell Start-Process worked)
Module: `dfpilot/supervise.py` (`WinOS.start_df`, `detached_start`)

## Root cause
`WinOS.start_df` called `os.startfile(steam://rungameid/975370)`: the launcher process is a child of the caller (same job object / console group), so when `timeout` / the shell tears the job down after supervise exits, the started Steam and DF go with it.

## Fix
`detached_start(url)`: `cmd.exe /c start "" <url>` through `Popen` with `DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP | CREATE_BREAKAWAY_FROM_JOB`, `close_fds=True`, stdin / stdout / stderr to DEVNULL (no inherited handles); where the job forbids breakaway (Popen raises OSError) the same start without that flag. `start_df` uses it.

## Tests
`tests/test_supervise.py`: `test_detached_start_flags` (flags, breakaway fallback, handles; fake Popen, no process is started), `test_winos_start_df_uses_detached`.

## Live check
`timeout 200 python -m dfpilot supervise --once` against a down DF: `Dwarf Fortress.exe` is still running after the supervise process exited. Open: if the job object forbids breakaway the fallback start is only detached from the console / group, not from the job.
