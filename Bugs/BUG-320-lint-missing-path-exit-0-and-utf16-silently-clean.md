# BUG-320: `lint <typo path>` exits 0 with `0 errors`; a UTF-16 Lua file (PowerShell default) containing `dig-now` is reported clean

- **Status:** fixed in 6e0db06
- **Severity:** S2
- **Area:** `lint` (`df_llm_helper/lint.py:lint_paths/lint_file`, `cli.py:cmd_lint`)
- **Reported:** 2026-10-02, commit `50cee52`
- **Environment:** Windows 11, Python 3.14, game: running (DF 53.16 + DFHack) but PAUSED and untouched - this test uses the mock only

## Command / steps
```
cd <project folder>
mkdir tmp_bug && cp -r data tmp_bug/data && cp Bugs/evidence/BUG-320/cfg.yaml tmp_bug/cfg.yaml && mkdir tmp_bug/scopes tmp_bug/tools
mkdir tmp_bug/lint && cp Bugs/evidence/BUG-320/inputs/*.lua tmp_bug/lint/
python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 lint tmp_bug/nonexist.lua ; echo "exit $?"
python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 lint tmp_bug/nonexist_dir ; echo "exit $?"
python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 lint tmp_bug/lint/u16.lua    # UTF-16 LE with BOM, content: dfhack.run_command("dig-now")
python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 lint tmp_bug/lint/plain.lua  # same content in UTF-8
```

## Expected
A path that does not exist is an error (exit 2, `no such file`), so a CI/agent gate `lint <path>` cannot pass by typo; a file that cannot be decoded as text is reported (error), not skipped.

## Actual
```
$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 lint tmp_bug/nonexist.lua
tmp_bug\nonexist.lua:0: IO not readable: [Errno 2] No such file or directory: 'tmp_bug\\nonexist.lua' (warning)
1 findings (0 errors)
[exit 0]

$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 lint tmp_bug/nonexist_dir
tmp_bug\nonexist_dir:0: IO not readable: [Errno 2] No such file or directory: 'tmp_bug\\nonexist_dir' (warning)
1 findings (0 errors)
[exit 0]

$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 lint tmp_bug/lint/u16.lua
0 findings (0 errors)
[exit 0]

$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 lint tmp_bug/lint/plain.lua
tmp_bug\lint\plain.lua:1: L02 dig-now digs instantly
1 findings (1 errors)
[exit 1]
```

## Evidence
`Bugs/evidence/BUG-320/`.

## Analysis (reporter's hypothesis)
`lint.py:178-187` `lint_paths`: `OSError` becomes `Finding(..., "IO", ..., "warn")`; `cmd_lint` counts only `error` level for the exit code (`cli.py:490-498`), so the exit code is 0. `lint_file` reads with `errors="replace"`: UTF-16 text turns into `d\x00f\x00h...` which no regex matches, so a real violation passes silently (Lua cannot run UTF-16 files, so the practical risk is low; the missing-path case is the real one).

## Suggested fix (optional)
Missing path -> `Finding(level="error")` or argparse error; decode via `read_text_tolerant`/`utf-16` BOM detection or report `IO error: not text`.

## Info needed
None.

## Fix
A missing path is an error finding (exit 1); unreadable files are errors; UTF-16 with BOM is decoded (`read_text_tolerant`), NUL bytes without BOM are an error `not a text file`.
