# BUG-306: `memory restore <scope> --dry-run` really restores (overwrites the working memory file); `--dry-run` is accepted but ignored

- **Status:** fixed in 793a4b7
- **Severity:** S2
- **Area:** `memory restore` (`df_llm_helper/cli.py:cmd_memory`)
- **Reported:** 2026-10-02, commit `50cee52`
- **Environment:** Windows 11, Python 3.14, game: running (DF 53.16 + DFHack) but PAUSED and untouched - this test uses the mock only

## Command / steps
```
cd <project folder>
mkdir tmp_bug && cp -r data tmp_bug/data && cp Bugs/evidence/BUG-306/cfg.yaml tmp_bug/cfg.yaml
mkdir tmp_bug/scopes tmp_bug/tools && cp fixtures/run5/scopes_sample/militaer.md tmp_bug/scopes/militaer.md
python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 memory compact militaer
python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 memory restore militaer --dry-run
wc -c tmp_bug/scopes/militaer.md        # before and after the dry-run
```

## Expected
`--dry-run` for `restore` prints what would be restored and leaves the file untouched (as for `compact --dry-run`).

## Actual
```
$ size of tmp_bug/scopes/militaer.md
16738 bytes tmp_bug\scopes\militaer.md
[exit 0]

$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 memory compact militaer
militaer.md: 16738 -> 5687 bytes, archive militaer.20261002T123222.md
[exit 0]

$ size of tmp_bug/scopes/militaer.md after compact
5745 bytes tmp_bug\scopes\militaer.md
[exit 0]

$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 memory restore militaer --dry-run
militaer.md: restored from militaer.20261002T123222.md
[exit 0]

$ size of tmp_bug/scopes/militaer.md after 'restore --dry-run'
16738 bytes tmp_bug\scopes\militaer.md
[exit 0]
```

## Evidence
`Bugs/evidence/BUG-306/*.txt`.

## Analysis (reporter's hypothesis)
`cli.py:431-455` (`cmd_memory`, `restore` branch): the `restore` branch never looks at `args.dry_run` (only the `compact` branch passes `dry_run=args.dry_run`). A tester/agent that uses `--dry-run` as a safety habit overwrites a freshly edited memory file with an old archive.

## Suggested fix (optional)
Honour `args.dry_run` in the restore branch (print `(dry-run) would restore X from archive Y`), or reject `--dry-run` for `restore` with an error.

## Info needed
None.

## Fix
`memory restore --dry-run` prints `(dry-run) X: would restore from Y` and copies nothing (`memory.restore(dry_run=True)`).
