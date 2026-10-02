# BUG-309: `journal chronik --append` appends the whole chronicle again on every call (duplicates in `chronik.md`)

- **Status:** fixed in 1e94283
- **Severity:** S2
- **Area:** `journal chronik --append` (`df_llm_helper/journal.py:append_chronik`, `cli.py:cmd_journal`)
- **Reported:** 2026-10-02, commit `50cee52`
- **Environment:** Windows 11, Python 3.14, game: running (DF 53.16 + DFHack) but PAUSED and untouched - this test uses the mock only

## Command / steps
```
cd <project folder>
mkdir tmp_bug && cp -r data tmp_bug/data && cp Bugs/evidence/BUG-309/cfg.yaml tmp_bug/cfg.yaml && mkdir tmp_bug/scopes tmp_bug/tools
python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 journal ingest --events fixtures/run5_live/events_run3.log --date 2026-09-30
python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 journal chronik --append
python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 journal chronik --append     # second session end / retry
```

## Expected
Lines that are already in `chronik.md` are not appended again (MANUAL 9.12: "`journal chronik` shows the draft ... `--append` appends it"); a repeated call reports `nothing new`.

## Actual
```
$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 journal ingest --events fixtures/run5_live/events_run3.log --date 2026-09-30
318 chronicle events in the log, 318 new; 0 critical df-llm-helper warnings taken over
[exit 0]

$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 journal chronik --append
(coverage 100 % of the events)
appended to <tmp>\repo_copy\tmp_bug\chronik.md
[exit 0]

$ wc -l tmp_bug/chronik.md
51 lines in tmp_bug/chronik.md
[exit 0]

$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 journal chronik --append
(coverage 100 % of the events)
appended to <tmp>\repo_copy\tmp_bug\chronik.md
[exit 0]

$ wc -l tmp_bug/chronik.md
102 lines; 100 non-empty; 50 distinct (every chronicle line now exists twice)
[exit 0]
```

## Evidence
`Bugs/evidence/BUG-309/*.txt`.

## Analysis (reporter's hypothesis)
`journal.py:222-226` `append_chronik` writes `"\n" + "\n".join(lines)` unconditionally; `chronik()` (line 208) always returns the full draft of all events in `state.db`, with no marker of what was already appended. A retry after a crash or a second end-of-session run duplicates the chronicle; the orchestrator's `chronik.md` is a hand-curated file.

## Suggested fix (optional)
Store the id/hash of appended clusters in `kv` (like `journal.lessons`) and append only new ones, or skip lines already present in the target file.

## Info needed
None.

## Fix
`append_chronik` appends only lines not yet in the target file and returns the count; a repeated call prints `nothing new`.
