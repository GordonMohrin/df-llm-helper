# BUG-330: `journal ingest` reports `0 chronicle events ... 0 new` (exit 0) for a UTF-16 event log or for a file that is not an event log at all; invalid `--date` shows the raw Python error

- **Status:** verified fixed (retest 2026-10-02, 8e67f05)
- **Severity:** S3
- **Area:** `journal ingest` (`df_llm_helper/cli.py:cmd_journal`, `df_llm_helper/journal.py:parse_events_log`)
- **Reported:** 2026-10-02, commit `50cee52`
- **Environment:** Windows 11, Python 3.14, game: running (DF 53.16 + DFHack) but PAUSED and untouched - this test uses the mock only

## Command / steps
```
cd <project folder>
mkdir tmp_bug && cp -r data tmp_bug/data && cp Bugs/evidence/BUG-330/cfg.yaml tmp_bug/cfg.yaml && mkdir tmp_bug/scopes tmp_bug/tools
cp Bugs/evidence/BUG-330/inputs/*.log tmp_bug/
python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 journal ingest --events tmp_bug/utf8.log --date 2026-10-02
python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 journal ingest --events tmp_bug/u16.log --date 2026-10-03        # same two lines, UTF-16 (PowerShell redirect)
python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 journal ingest --events tmp_bug/cfg.yaml --date 2026-10-04      # not a log
python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 journal ingest --events tmp_bug/utf8.log --date 30.09.2026
python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 journal ingest --events tmp_bug/utf8.log --date 2026-13-45
```

## Expected
A non-empty file in which no line matched the event format produces a warning (`0 of N lines recognised - wrong encoding or not a watcher log?`); UTF-16 is decoded; `--date` errors name the expected format (`YYYY-MM-DD`).

## Actual
```
$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 journal ingest --events tmp_bug/utf8.log --date 2026-10-02
2 chronicle events in the log, 2 new; 0 critical df-llm-helper warnings taken over
[exit 0]

$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 journal ingest --events tmp_bug/u16.log --date 2026-10-03
0 chronicle events in the log, 0 new; 0 critical df-llm-helper warnings taken over
[exit 0]

$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 journal ingest --events tmp_bug/cfg.yaml --date 2026-10-04
0 chronicle events in the log, 0 new; 0 critical df-llm-helper warnings taken over
[exit 0]

$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 journal ingest --events tmp_bug/utf8.log --date 30.09.2026
Error: Invalid isoformat string: '30.09.2026'
[exit 2]

$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 journal ingest --events tmp_bug/utf8.log --date 2026-13-45
Error: month must be in 1..12, not 13
[exit 2]
```

## Evidence
`Bugs/evidence/BUG-330/`.

## Analysis (reporter's hypothesis)
`toolsfs.read_text_tolerant` tries `utf-8-sig`, then `cp1252`, then `latin-1`: UTF-16 text is accepted by `cp1252` (nearly every byte value decodes) and becomes `i\x00n\x00f\x00o...`, which no log regex matches. The chronicle then silently misses a whole session. `date.fromisoformat` messages are not wrapped (`cli.py:942`).

## Suggested fix (optional)
In `read_text_tolerant` check the BOM for UTF-16 (`ÿþ`/`þÿ`) first; print `N lines, M recognised` and warn when `M == 0`; catch `ValueError` for `--date`.

## Info needed
None.

## Fix
UTF-16 with BOM is decoded (`read_text_tolerant`, 6e0db06); `journal ingest` warns and exits 1 when no line has the watcher format; a bad `--date` gives `--date must be a real date YYYY-MM-DD`.
