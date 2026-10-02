# BUG-312: `dashboard --out <file>` reports `(unchanged)` and skips the write when the file is stale (the hash is global, not per file); `--out <directory>` also reports `unchanged`

- **Status:** fixed in 1e94283
- **Severity:** S2
- **Area:** `dashboard` (`df_llm_helper/dashboard.py:write_if_changed`)
- **Reported:** 2026-10-02, commit `50cee52`
- **Environment:** Windows 11, Python 3.14, game: running (DF 53.16 + DFHack) but PAUSED and untouched - this test uses the mock only

## Command / steps
```
cd <project folder>
mkdir tmp_bug && cp -r data tmp_bug/data && cp Bugs/evidence/BUG-312/cfg.yaml tmp_bug/cfg.yaml && mkdir tmp_bug/scopes tmp_bug/tools
python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 dashboard --offline --out tmp_bug/a.html
python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 dashboard map Kaserne 80 90 130 40 28
python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 dashboard --offline --out tmp_bug/b.html
python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 dashboard --offline --out tmp_bug/a.html    # a.html is older than the map
python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 dashboard --offline --out tmp_bug            # a directory
```

## Expected
`a.html` is rewritten (it lacks the map section); `--out <directory>` fails with an error.

## Actual
```
$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 dashboard --offline --out tmp_bug/a.html
tmp_bug\a.html (1 KB, newly written)
[exit 0]

$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 dashboard map Kaserne 80 90 130 40 28
Map 'Kaserne' saved (32 lines)
[exit 0]

$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 dashboard --offline --out tmp_bug/b.html
tmp_bug\b.html (3 KB, newly written)
[exit 0]

$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 dashboard --offline --out tmp_bug/a.html
tmp_bug\a.html (3 KB, unchanged)
[exit 0]

$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 dashboard --offline --out tmp_bug
tmp_bug (3 KB, unchanged)
[exit 0]

$ grep -c 'Map Kaserne' tmp_bug/a.html tmp_bug/b.html
a.html contains the map: False
b.html contains the map: True
[exit 0]
```

## Evidence
`Bugs/evidence/BUG-312/*.txt`.

## Analysis (reporter's hypothesis)
`dashboard.py:248-255`: `store.get("dashboard.hash") == h and Path(out).exists()` - one hash for all output paths. The orchestrator publishes the file as an artifact (MANUAL 9.11), so a stale file is published as if current; `check` writes the default file and records its hash, a later manual `--out my.html` of the same content is skipped although `my.html` is old. `Path(dir).exists()` is also true.

## Suggested fix (optional)
Key the hash by resolved output path (`dashboard.hash.<path>`) or compare with the hash of the file content (`sha1(out.read_bytes())`); `if out.is_dir(): error`.

## Info needed
None.

## Fix
`write_if_changed` compares with the content of the target file itself (not a global hash), writes bytes (LF), and `--out <directory>` is refused (exit 2).
