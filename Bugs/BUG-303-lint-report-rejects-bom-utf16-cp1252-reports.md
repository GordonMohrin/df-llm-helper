# BUG-303: `agents lint-report` cannot read reports saved by Windows tools (UTF-8 BOM, UTF-16, cp1252): false "Mandatory fields missing" or a decode error

- **Status:** fixed in 793a4b7
- **Severity:** S2
- **Area:** `agents lint-report` (`df_llm_helper/cli.py:851`), `df_llm_helper/agents.py:lint_report`
- **Reported:** 2026-10-02, commit `50cee52`
- **Environment:** Windows 11, Python 3.14, game: running (DF 53.16 + DFHack) but PAUSED and untouched - this test uses the mock only

## Command / steps
```
cd <project folder>
mkdir tmp_bug && cp -r data tmp_bug/data && cp Bugs/evidence/BUG-303/cfg.yaml tmp_bug/cfg.yaml
cp Bugs/evidence/BUG-303/inputs/*.txt tmp_bug/           # r_utf8 / r_bom / r_utf16 / r_cp1252: the same valid report in four encodings
for n in r_utf8 r_bom r_utf16 r_cp1252; do
  python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 agents lint-report tmp_bug/$n.txt
done
```
(`r_utf16` is what Windows PowerShell 5.1 `>`/`Out-File` writes by default; `r_bom` is what Notepad / `Set-Content -Encoding UTF8` writes.)

## Expected
All four files contain the same valid five-field report: `ok` for every one (the project reads other text files via `toolsfs.read_text_tolerant`, which handles BOM and cp1252).

## Actual
```
$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 agents lint-report tmp_bug/r_utf8.txt
ok
[exit 0]

$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 agents lint-report tmp_bug/r_bom.txt
Report: Mandatory fields missing: Result
[exit 1]

$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 agents lint-report tmp_bug/r_utf16.txt
Error: 'utf-8' codec can't decode byte 0xff in position 0: invalid start byte
[exit 2]

$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 agents lint-report tmp_bug/r_cp1252.txt
Error: 'utf-8' codec can't decode byte 0xe4 in position 57: invalid continuation byte
[exit 2]

$ type tmp_bug\r_cp1252.txt | python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 agents lint-report -
Error: 'utf-8' codec can't decode byte 0xe4 in position 57: invalid continuation byte
[exit 2]
```

## Evidence
`Bugs/evidence/BUG-303/` (outputs + the four input files).

## Analysis (reporter's hypothesis)
`cli.py:851`: `Path(args.target).read_text(encoding="utf-8")` is strict UTF-8 without BOM handling (`utf-8-sig`); `sys.stdin.read()` has the same problem on Windows consoles (code page). The BOM case is reported as a misleading *"Mandatory fields missing: Result"* (the first field name is hidden behind U+FEFF), the other two as a raw decode error (exit 2).

## Suggested fix (optional)
Use `read_text_tolerant` (utf-8-sig, UTF-16 BOM, cp1252 fallback) for files and `sys.stdin.buffer.read()` + the same decoder for stdin.

## Info needed
None.

## Fix
`agents lint-report` decodes files and stdin bytes with `toolsfs.decode_tolerant` (UTF-8 BOM, UTF-16 BOM, cp1252).
