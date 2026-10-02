# BUG-327: `bus post --md` writes the message to `inbox-<to>.md`; a later `bus import` (default: all inbox files) imports it again as a second message

- **Status:** fixed in 1e94283
- **Severity:** S3
- **Area:** `bus post --md`, `bus import` (`df_llm_helper/bus.py:export_to_inbox/import_inbox`)
- **Reported:** 2026-10-02, commit `50cee52`
- **Environment:** Windows 11, Python 3.14, game: running (DF 53.16 + DFHack) but PAUSED and untouched - this test uses the mock only

## Command / steps
```
cd <project folder>
mkdir tmp_bug && cp -r data tmp_bug/data && cp Bugs/evidence/BUG-327/cfg.yaml tmp_bug/cfg.yaml && mkdir tmp_bug/scopes tmp_bug/tools
python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 bus post "Fässer knapp" --from trinken --to bau --md --prio warn
python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 bus import
python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 bus read --to bau
```

## Expected
One message: the import recognises the line it exported itself (idempotent import is documented in `bus.py`: "Idempotent via dedupe_key=hash").

## Actual
```
$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 bus post 'Fässer knapp' --from trinken --to bau --md --prio warn
#1 to bau
[exit 0]

$ python -c "print(repr(tmp_bug/scopes/inbox-bau.md))"
'- from trinken, 02.10. 12:36: Fässer knapp\r\n'
[exit 0]

$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 bus import
inbox-bau.md: 1 new, 0 already present
[exit 0]

$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 bus read --to bau
! #1 trinken: Fässer knapp
! #2 trinken [02.10. 12:36]: Fässer knapp
[exit 0]

$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 bus import
inbox-bau.md: 0 new, 1 already present
[exit 0]
```

## Evidence
`Bugs/evidence/BUG-327/`.

## Analysis (reporter's hypothesis)
`export_to_inbox` writes `- from trinken, 02.10. 12:00: <text>` (CRLF); `import_inbox` hashes sender+date+text, while the original `post` stored the plain text without the date prefix, so the hashes differ. The default `bus import` (no file arguments) walks every `inbox-*.md`, so any scope that posts with `--md` (AGENT-PROMPT step 4 mentions the bus, MANUAL 3 the inboxes) can see its messages twice.

## Suggested fix (optional)
Store the exported line's hash as the message's dedupe key at `post --md` time, or have `export_to_inbox` mark the line (`<!-- bus:ID -->`) and skip marked lines on import.

## Info needed
None.

## Fix
`export_to_inbox` stores the key of the exported line (kv `bus.exported_md`); `bus import` skips it.
