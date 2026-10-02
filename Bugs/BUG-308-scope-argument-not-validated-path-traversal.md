# BUG-308: `memory compact|restore <scope>` and `agents lint-report --scope` use the scope name as a file name without validation (`../victim` compacts a file outside the scopes folder)

- **Status:** verified fixed (retest 2026-10-02, 8e67f05)
- **Severity:** S3
- **Area:** `df_llm_helper/cli.py:cmd_memory`, `cmd_agents` (`lint-report --scope`)
- **Reported:** 2026-10-02, commit `50cee52`
- **Environment:** Windows 11, Python 3.14, game: running (DF 53.16 + DFHack) but PAUSED and untouched - this test uses the mock only

## Command / steps
```
cd <project folder>
mkdir tmp_bug && cp -r data tmp_bug/data && cp Bugs/evidence/BUG-308/cfg.yaml tmp_bug/cfg.yaml && mkdir tmp_bug/scopes tmp_bug/tools
cp fixtures/run5/scopes_sample/militaer.md tmp_bug/victim.md          # any *.md outside tmp_bug/scopes
python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 memory compact ../victim
python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 agents lint-report tmp_bug/victim.md --scope "x/../../../escape"
ls tmp_bug/tools          # escape.md next to out/, i.e. outside tools/out/berichte
```

## Expected
`Error: unknown scope '../victim'` (the brief/prompt commands already validate scope names against `data/scopes.yaml`).

## Actual
```
$ wc -c tmp_bug/victim.md; ls tmp_bug/scopes
16738 bytes  tmp_bug/victim.md (OUTSIDE tmp_bug/scopes)
tmp_bug/scopes: []
[exit 0]

$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 memory compact ../victim
victim.md: 16738 -> 5687 bytes, archive victim.20261002T123223.md
[exit 0]

$ wc -c tmp_bug/victim.md; ls tmp_bug/scopes tmp_bug/archive
5745 bytes  tmp_bug/victim.md
tmp_bug/scopes: []
tmp_bug/archive: ['victim.20261002T123223.md']
[exit 0]

$ ls tmp_bug/tools
[]
[exit 0]

$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 agents lint-report tmp_bug/victim.md --scope x/../../../escape
Original archived: tmp_bug\tools\out\berichte\20261002-123224-x\..\..\..\escape.md
Report: Mandatory fields missing: Result, Measurements, Changed, Open, Risk; 56 lines > 12
# Scope militaer+verteidigung – Gedächtnis (Run 5, Windrings, Wüste, Weltkachel (26,10))
[... 11 more lines cut]
[exit 1]

$ ls tmp_bug/tools      # escape.md was written OUTSIDE tools/out/berichte
['escape.md', 'out']
[exit 0]
```

## Evidence
`Bugs/evidence/BUG-308/`.

## Analysis (reporter's hypothesis)
`cli.py:cmd_memory` builds `scopes / f"{args.scope}.md"` for any string; `memory compact`/`restore` therefore operate on any `*.md` reachable from the scopes folder. `lint-report --scope` puts the raw string into the archive file name (`agents.py:archive_report`). Agents run these commands with LLM-generated arguments.

## Suggested fix (optional)
Validate the scope against `brief.SCOPES` plus `orchestrator`/`inbox-<scope>` (as the `all` branch already does) and reject path separators.

## Info needed
None.

## Fix
`memory compact|restore` accept only scopes of `brief.SCOPES` or `inbox-<scope|orchestrator>` (`memory.valid_memory_name`); `lint-report --scope` must match `[A-Za-z0-9_-]{1,40}`.
