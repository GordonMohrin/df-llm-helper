# BUG-124: `autopilot --loop` and `guard --loop` print without `flush`; a monitor reading the pipe sees nothing for a long time

- **Status:** fixed in 626d04f
- **Severity:** S3
- **Area:** `df_llm_helper/cli.py:181-188` (`cmd_autopilot` loop), `cli.py:200-207` (`cmd_guard` loop) - plain `print()`; `cmd_waechter`/`cmd_wake` use `flush=True`
- **Reported:** 2026-10-02, commit `50cee52` (code identical to `6dedd96`)
- **Environment:** Windows 11 Pro, Python 3.14.3; bounded 3-second mock test (process killed afterwards)

## Command / steps
```
cd "<project folder>"
python Bugs/evidence/BUG-124/repro.py
```
(Both loops run with `--interval 0.2 --dry-run` against `fixtures/run5`, stdout is a pipe.)

## Expected
Every pass prints its line immediately (the loop modes exist to be read by a background monitor, OVERVIEW: `autopilot [--dry-run] [--loop]`, `guard [--dry-run] [--loop]`).

## Actual
```
guard --loop --interval 0.2 --dry-run       -> bytes received after 3 s (process still looping, then killed): 0
autopilot --loop --interval 0.2 --dry-run   -> bytes received after 3 s ...: 0
```
Python block-buffers stdout when it is not a console, so the lines appear only after ~8 KB or at exit. Same symptom seen by the tester with `timeout 5 ... | head` (no output at all).
Also: `--interval` is validated only after the first pass (`float(args.interval)` at the `sleep`, BUG-113) and `--once` is accepted but ignored (BUG-120).

## Evidence
`Bugs/evidence/BUG-124/repro.py`, `output.txt`.

## Suggested fix (optional)
`print(..., flush=True)` in both loops (or `sys.stdout.reconfigure(line_buffering=True)` in `main`, which also helps BUG-112).

## Info needed
None.

## Fix
`autopilot --loop` and `guard --loop` print with `flush=True` (stdout is also reconfigured in `main`); `--interval` validated by argparse. Test: `test_bug124_guard_loop_flushes` (pipe, line within seconds).
