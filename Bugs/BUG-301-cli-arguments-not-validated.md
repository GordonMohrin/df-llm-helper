# BUG-301: Several CLI arguments are not validated: `--param x`, `kb -k -1`, empty `bus post`, `kb import` junk, `dashboard unmap` unknown, unknown ids reported as `None`

- **Status:** fixed in 793a4b7
- **Severity:** S3
- **Area:** `runbook`, `kb`, `bus`, `dashboard` in `df_llm_helper/cli.py`
- **Reported:** 2026-10-02, commit `50cee52`
- **Environment:** Windows 11, Python 3.14, game: running (DF 53.16 + DFHack) but PAUSED and untouched - this test uses the mock only

## Command / steps
```
cd <project folder>
mkdir tmp_bug && cp -r data tmp_bug/data && cp Bugs/evidence/BUG-301/cfg.yaml tmp_bug/cfg.yaml
python -c "open('tmp_bug/binary.md','wb').write(bytes(range(256))*3); open('tmp_bug/empty.md','w').close()"
python -m df_llm_helper --mock fixtures/run5 runbook run rb21_flut --dry-run --param x
python -m df_llm_helper --mock fixtures/run5 runbook show
python -m df_llm_helper --mock fixtures/run5 kb get
python -m df_llm_helper --mock fixtures/run5 kb get nonexistent
python -m df_llm_helper --mock fixtures/run5 kb search -k -1 pickaxe
python -m df_llm_helper --mock fixtures/run5 kb import
python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 kb import tmp_bug/binary.md tmp_bug/empty.md
python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 bus post "" --from a --to b
python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 bus post x --to bau
python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 dashboard unmap nonexistent
python -m df_llm_helper --mock fixtures/run5 brief bau --budget 0
python -m df_llm_helper --mock fixtures/run5 brief bau --budget -5
```

## Expected
Each bad argument gets a one-line usage error (exit 2): `--param` without `=`, missing runbook/KB id (say "id missing", name the unknown id),
`-k` must be >= 1, an empty `bus post` text and a missing `--from` are refused, `kb import` of a binary/empty file warns, `unmap` of an unknown map says so.

## Actual
```
$ python -m df_llm_helper --mock fixtures/run5 runbook run rb21_flut --dry-run --param x
Error: dictionary update sequence element #0 has length 1; 2 is required
[exit 2]

$ python -m df_llm_helper --mock fixtures/run5 runbook show
Unknown runbook: None. List: python -m df_llm_helper runbook list
[exit 2]

$ python -m df_llm_helper --mock fixtures/run5 kb get
unknown ID (python -m df_llm_helper kb search ...)
[exit 2]

$ python -m df_llm_helper --mock fixtures/run5 kb get nonexistent
unknown ID (python -m df_llm_helper kb search ...)
[exit 2]

$ python -m df_llm_helper --mock fixtures/run5 kb search -k -1 pickaxe
[e18_pick] E18: miners do not pick up pickaxes
Cause: Only dwarves with a brought/assigned pick dig; free picks (often foreign=true from the wagon) are not picked up. work_weapons stays small.
Fix: Militia squad 'Miners' (leader: claude/mil create <name> <id> --apply), claude/mil add <squad> <id> --apply, claude/mil workmode <squad> on --apply (uniform = pick only, labor MINE, group Miners). Verify: work_weapons/diggers rise within <= 90 s. Do not run workmode repeatedly (it wipes assignments). Runbook rb01_e18_pick.
Source: SPEC appendix A1; session Run 5 (12 interventions 07:04-08:50)
+ [fairplay_foreign] Fair play: foreign flag on the embark tools
+ [e18_release] E18: pick assigned but not picked up (stale assignment)
+ [deadman_heartbeat] Deadman: game runs on without supervision
+ [makler_squad] Broker loses the trade job (squad/labors)
[exit 0]

$ python -m df_llm_helper --mock fixtures/run5 kb import
[exit 0]

$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 kb import tmp_bug/binary.md tmp_bug/empty.md
tmp_bug/binary.md: 1 entries -> imported_binary.jsonl (unreviewed)
tmp_bug/empty.md: 0 entries -> imported_empty.jsonl (unreviewed)
[exit 0]

$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 bus post '' --from a --to b
#1 to b
[exit 0]

$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 bus read --to b
- #1 a: 
[exit 0]

$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 bus post x --to bau
#2 to bau
[exit 0]

$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 bus read --to bau
- #2 orchestrator: x
[exit 0]

$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 dashboard unmap nonexistent
[exit 0]

$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 dashboard unmap
[exit 0]

$ python -m df_llm_helper --mock fixtures/run5 brief bau --budget 0
# Briefing bau
## Mission
Layout (LAYOUT-run5.md, bau owns ALL coordinates): accesses, stairs, gates, refuge, workshop halls, farms, crypt, depot, stockpiles, zones. Check every site with claude/area.
[... 13 more lines cut]
[exit 0]

$ python -m df_llm_helper --mock fixtures/run5 brief bau --budget -5
Error: Scope 'bau': the mandatory parts alone exceed the budget -5 (shorten the mission)
[exit 2]
```

## Evidence
`Bugs/evidence/BUG-301/*.txt`, `cfg.yaml`.

## Analysis (reporter's hypothesis)
- `cli.py:314`: `dict(kv.split("=", 1) ...)` raises ValueError that `main()` prints raw (`dictionary update sequence element #0 ...`).
- `cli.py:301-302` / `cli.py:358`: `Unknown runbook: None` / `unknown ID` do not name the id or the cause.
- `kb search -k -1` is passed to a list slice (`[:k]`) and returns all but the last hit; `-k 0` prints "No hits".
- `bus post` accepts empty text (message `#6 a:` with empty body) and silently defaults `--from` to `orchestrator`, so an agent that forgets `--from` posts as the orchestrator.
- `kb import` of a 768-byte binary file creates the entry `bin.bin: bin` (unreviewed) instead of refusing; an empty file writes an empty `imported_empty.jsonl`; the target file name keeps spaces/umlauts of the source (`imported_lessons ä.jsonl`).
- `dashboard unmap <unknown>` and `unmap` (no name) are silent no-ops.
(Related: BUG-114 covers the same class for `autopilot enable`, `guard ack-gate`, `plan ...`.)
- `brief --budget 0` silently falls back to the default (1500; `args.budget or cfg`), `--budget -5` answers "the mandatory parts alone exceed the budget -5 (shorten the mission)" instead of "budget must be positive".

## Suggested fix (optional)
Use argparse `type=` validators (`positive int`, `key=value`), reject empty text, print a clear message for unknown ids/maps.

## Info needed
None (cosmetic/robustness).

## Fix
Runbook part in e4af55c (`--param` without `=`, missing/unknown id). 793a4b7: `kb get/search/import` (`-k >= 1`, id named, binary/empty files, slug target names), `bus post` (empty text, `--from` required), `bus read --limit >= 1`, `dashboard unmap` (usage / unknown map), `brief --budget >= 1`. All exit 2 with a one-line message (unknown map: exit 1).
