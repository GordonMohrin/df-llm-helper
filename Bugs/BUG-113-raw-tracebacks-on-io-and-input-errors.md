# BUG-113: missing/unreadable files, wrong JSON shapes and wrong config types end in raw Python tracebacks (exit 1) instead of a one-line error (exit 2); `replay` of an empty file says `OK`

- **Status:** fixed in 626d04f
- **Severity:** S2 (the orchestrator parses stderr/exit codes; a traceback is long, unstable and costs tokens)
- **Area:** `df_llm_helper/cli.py:1208-1214` (`main` catches only `ValueError`, `KeyError`, `FairPlayError`), call sites `cli.py:392` (`replay`), `:592/:599/:614` (`plan`), `:515` (`metrics --out`), `:263` (`heartbeat`), `df_llm_helper/config.py:171-183` (`load_config`, no type checks), `df_llm_helper/scenario.py:70`, `df_llm_helper/client.py:294` (`load_records`)
- **Reported:** 2026-10-02, commit `50cee52` (code identical to `6dedd96`)
- **Environment:** Windows 11 Pro, Python 3.14.3, no game needed

## Command / steps
```
cd "<project folder>"
python Bugs/evidence/BUG-113/repro.py       # 17 error cases, temp folder; one verdict line per case
```

## Expected
Every user/input error gives `Error: <what, which file>` on one line and exit 2 (like the existing `Error: ...: line 1: string without closing '` for broken YAML and `Error: Expecting value: line 1 column 1` for broken trade JSON).

## Actual (`output.txt`; "TRACEBACK" = full Python traceback on stderr)
```
TRACEBACK exit=1  replay <missing file>            | FileNotFoundError: [Errno 2] No such file or directory: '...\nope.jsonl'
TRACEBACK exit=1  replay <directory>               | PermissionError: [Errno 13] Permission denied: '...'
message   exit=0  replay <empty file> (false OK)   | empty: OK (0 steps)
TRACEBACK exit=1  plan blueprint <missing file>    | FileNotFoundError ...      (also <directory> -> PermissionError)
TRACEBACK exit=1  plan trade (no --json)           | TypeError: argument should be a str or an os.PathLike object ... not 'NoneType'
TRACEBACK exit=1  plan trade --json <missing>      | FileNotFoundError ...      (also <directory>)
TRACEBACK exit=1  plan trade --json <list root>    | AttributeError: 'list' object has no attribute 'get'
TRACEBACK exit=1  plan trade --json <item w/o fields> | TypeError: TradeItem.__init__() missing 4 required positional arguments: 'name', 'category', 'value', and 'weight'
TRACEBACK exit=1  plan dig --area-file <missing>   | FileNotFoundError ...
TRACEBACK exit=1  metrics --out <missing dir>      | FileNotFoundError ...      (also <directory> -> PermissionError)
TRACEBACK exit=1  heartbeat (tools path is a file) | FileExistsError: [WinError 183] Cannot create a file when that file already exists
TRACEBACK exit=1  --config <directory>             | PermissionError: [Errno 13] ...
TRACEBACK exit=1  --config guard: 5 (wrong type)   | TypeError: 'int' object is not subscriptable
TRACEBACK exit=1  --config thresholds: abc         | TypeError: '<' not supported between instances of 'int' and 'str'
```
Also: `heartbeat` with an unreachable drive (`Z:\...`) gives `FileNotFoundError: [WinError 3]`; `guard --loop --interval x` (and `autopilot --loop --interval x`, same code) runs one full pass and only then fails with `Error: could not convert string to float` (validate the option before the work).
`replay` of an empty or meta-only `.jsonl` reports `empty: OK (0 steps)` and exit 0 - a scenario file without steps must be an error (a typo in the file name that created an empty file would look "green").
Side effect worth knowing: a `PermissionError` for a *directory* argument is how Windows reports "is a directory".

## Evidence
(Related, other commands of the same kind: BUG-214 - the central `except OSError/TypeError` in `main()` would fix both.)
`Bugs/evidence/BUG-113/repro.py`, `output.txt`. The full traceback of e.g. `replay nonexistent.jsonl` ends in `scenario.py:70 -> client.py:294 load_records -> Path.read_text`.

## Analysis (reporter's hypothesis)
`main()` only translates `ValueError/KeyError`. Add `except (OSError, TypeError, AttributeError) as e: print(f"Error: {e}", file=sys.stderr); return 2` as a safety net (keeping tracebacks behind `DF_LLM_HELPER_DEBUG=1`), and validate the specific inputs where a friendlier text is possible
(`plan trade`: required `--json`, required keys per item `id,name,category,value,weight[,qty]` - the format is not documented anywhere, see BUG-123; config values: type-check the sections that the code indexes (`guard`, `thresholds`, `flags`, ...)).

## Suggested fix (optional)
As above + a test per row of the table (`pytest` parametrised, `main([...])` returns 2 and prints no traceback).

## Info needed
None.

## Fix
Shared handling in `cli.main`: `OSError`, `TypeError`, `AttributeError`, `IndexError`, `ValueError`, `KeyError` -> one line `Error: ...` (file not found / is a directory / ...) and exit 2; traceback only with `DF_LLM_HELPER_DEBUG=1`. `load_config` type-checks sections (mapping), numbers and lists against the defaults; `plan trade` validates `--json`; `replay` of a scenario without steps is `FAIL`; `--interval` is parsed by argparse (`type=float`) before any work. Tests: `test_bug113_*` (one per row of the report).
