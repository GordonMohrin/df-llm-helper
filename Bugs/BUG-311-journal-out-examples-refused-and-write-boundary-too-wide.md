# BUG-311: MANUAL 9.12 documents `journal metrics --out ../metrics.csv` / `postmortem --out ../POSTMORTEM-runN.md`, but both are refused with the shipped config; the same boundary lets `--out` overwrite any file inside the project (e.g. `data/exceptions.jsonl`)

- **Status:** open
- **Severity:** S3
- **Area:** `df_llm_helper/cli.py:_journal_target`, docs/MANUAL.md 9.12, docs/INTEGRATION.md
- **Reported:** 2026-10-02, commit `50cee52`
- **Environment:** Windows 11, Python 3.14, game: running (DF 53.16 + DFHack) but PAUSED and untouched - this test uses the mock only

## Command / steps
```
cd <project folder>                                   # no config.yaml (fresh checkout)
python -m df_llm_helper --mock fixtures/run5 journal metrics --out ../metrics.csv
python -m df_llm_helper --mock fixtures/run5 journal postmortem --out ../POSTMORTEM-runN.md
# in a THROW-AWAY copy of the repo only:
python -m df_llm_helper --mock fixtures/run5 journal postmortem --out data/exceptions.jsonl
```

## Expected
The documented examples work (or the docs show a path that is accepted: `runtime/metrics.csv`); the write boundary is limited to the configured `journal.*` files and an output folder, not to the whole project.

## Actual
```
$ python -m df_llm_helper --mock fixtures/run5 journal metrics --out ../metrics.csv
Write refused: <tmp>\metrics.csv lies outside df-llm-helper/ and is not configured
[exit 1]

$ python -m df_llm_helper --mock fixtures/run5 journal postmortem --out ../POSTMORTEM-runN.md
Write refused: <tmp>\POSTMORTEM-runN.md lies outside df-llm-helper/ and is not configured
[exit 1]

$ head -c 160 data/exceptions.jsonl   # (in a throw-away copy of the repo)
{"example": true, "ts": "2026-01-01T00:00:00Z", "action": "FP09", "objects": [], "reason": "example (ignored): send stuck traders home via flags1.left", "player
[exit 0]

$ python -m df_llm_helper --mock fixtures/run5 journal postmortem --out data/exceptions.jsonl
Postmortem skeleton -> <tmp>\repo_copy\data\exceptions.jsonl
[exit 0]

$ head -c 160 data/exceptions.jsonl
# POSTMORTEM

Skeleton from state.db (python -m df_llm_helper journal postmortem). Measured data only; add the assessment by hand.

## Timeline
- (no events in 
[exit 0]
```

## Evidence
`Bugs/evidence/BUG-311/*.txt`.

## Analysis (reporter's hypothesis)
`cli.py:917-923`: allowed = the three configured files (defaults are `RUNTIME/chronik.md` etc., absolute, not `../metrics.csv`), **or any path below the project folder** (`HOME.resolve() in p.parents`). So the documented `../metrics.csv` (parent of the project) is refused, while `--out data/exceptions.jsonl`, `--out config.yaml` or `--out df_llm_helper/cli.py` are accepted and overwritten. The fair-play register is the one file that must never be writable by a reporting command.

## Suggested fix (optional)
Allow only the configured files plus `<RUNTIME>/**`; update MANUAL 9.12 / INTEGRATION.md to `--out runtime/metrics.csv` or tell the reader to set `journal.metrics`/`journal.postmortem` in `config.yaml`.

## Info needed
Question: should the orchestrator be allowed to write `../metrics.csv` (the player's original folder layout)? If yes, document that `journal.metrics: ../metrics.csv` must be set in `config.yaml`.
