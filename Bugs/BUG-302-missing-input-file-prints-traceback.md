# BUG-302: Missing or unreadable input file produces a Python traceback in `kb import`, `bus import`, `agents lint-report`, `replay`, `journal ingest`

- **Status:** verified fixed (retest 2026-10-02, 8e67f05)
- **Severity:** S2
- **Area:** `kb import`, `bus import`, `agents lint-report`, `replay`, `journal ingest --events <dir>`
- **Reported:** 2026-10-02, commit `50cee52`
- **Environment:** Windows 11, Python 3.14, game: running (DF 53.16 + DFHack) but PAUSED and untouched - this test uses the mock only

## Command / steps
```
cd <project folder>
mkdir tmp_bug && cp -r data tmp_bug/data && mkdir tmp_bug/dir_as_file && cp Bugs/evidence/BUG-302/cfg.yaml tmp_bug/cfg.yaml
python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 kb import tmp_bug/nonexist.md
python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 bus import tmp_bug/nonexist.md
python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 agents lint-report tmp_bug/nonexist.txt
python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 agents lint-report tmp_bug/dir_as_file
python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 replay tmp_bug/nonexist.jsonl
python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 journal ingest --events tmp_bug/dir_as_file
```

## Expected
A one-line error message and a non-zero exit code (like `journal ingest --events <missing file>` and `lint <missing file>` already do); no traceback.

## Actual
```
$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 kb import tmp_bug/nonexist.md
  ...
           ~~~~~~~^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
FileNotFoundError: [Errno 2] No such file or directory: 'tmp_bug\\nonexist.md'
[exit 1]

$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 bus import tmp_bug/nonexist.md
  ...
           ~~~~~~~^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
FileNotFoundError: [Errno 2] No such file or directory: 'tmp_bug\\nonexist.md'
[exit 1]

$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 agents lint-report tmp_bug/nonexist.txt
  ...
           ~~~~~~~^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
FileNotFoundError: [Errno 2] No such file or directory: 'tmp_bug\\nonexist.txt'
[exit 1]

$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 agents lint-report tmp_bug/dir_as_file
  ...
           ~~~~~~~^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
PermissionError: [Errno 13] Permission denied: 'tmp_bug\\dir_as_file'
[exit 1]

$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 replay tmp_bug/nonexist.jsonl
  ...
           ~~~~~~~^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
FileNotFoundError: [Errno 2] No such file or directory: 'tmp_bug\\nonexist.jsonl'
[exit 1]

$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 journal ingest --events tmp_bug/dir_as_file
  ...
           ~~~~~~~^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
PermissionError: [Errno 13] Permission denied: 'tmp_bug\\dir_as_file'
[exit 1]
```
Contrast (these two handle the same mistake properly):
```
$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 journal ingest --events tmp_bug/nonexist.log
Event log missing: tmp_bug\nonexist.log
[exit 1]

$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 lint tmp_bug/nonexist.lua
tmp_bug\nonexist.lua:0: IO not readable: [Errno 2] No such file or directory: 'tmp_bug\\nonexist.lua' (warning)
1 findings (0 errors)
[exit 0]
```

## Evidence
`Bugs/evidence/BUG-302/*.txt` (full tracebacks).

## Analysis (reporter's hypothesis)
Same root cause as BUG-113 / BUG-214 (other commands: replay, plan, metrics, heartbeat); this report adds `kb import`, `bus import`, `agents lint-report`, `journal ingest`. `main()` (`cli.py:1206-1214`) only catches `FairPlayError`, `ValueError`, `KeyError`; `OSError` (FileNotFoundError, PermissionError, IsADirectoryError) escapes. Affected call sites:
`cli.py:345` (`import_markdown`), `bus.py:131` (`import_inbox`), `cli.py:851` (`Path(args.target).read_text`), `client.py:294` (`load_records`), `cli.py:940` (`read_text_tolerant(src)` for a directory).
A typo in an agent's command therefore burns tokens on a 20-line traceback.

## Suggested fix (optional)
Catch `OSError` in `main()` (print `Error: <strerror>: <path>`, exit 2) or check `Path.is_file()` at each call site.

## Info needed
None.

## Fix
Module-specific causes only: `kb import`, `bus import`, `agents lint-report`, `replay` and `journal ingest` check `is_file()` and print one line (exit 1/2). The generic OSError handling in `main()` is the core agent's BUG-113.
