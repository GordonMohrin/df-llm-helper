# BUG-325: A YAML file saved with a UTF-8 BOM (Notepad, PowerShell) makes `runbook list/diagnose` fail for ALL runbooks with "required field 'id' missing"; the same for `scopes.yaml` -> `brief`

- **Status:** verified fixed (retest 2026-10-02, 8e67f05)
- **Severity:** S3
- **Area:** `df_llm_helper/yamlmini.py:load_file`, `runbooks.py:load_runbooks`, `brief.py:load_scopes`
- **Reported:** 2026-10-02, commit `50cee52`
- **Environment:** Windows 11, Python 3.14, game: running (DF 53.16 + DFHack) but PAUSED and untouched - this test uses the mock only

## Command / steps
```
cd <project folder>
mkdir tmp_bug && cp -r data tmp_bug/data && cp Bugs/evidence/BUG-325/cfg.yaml tmp_bug/cfg.yaml && mkdir tmp_bug/scopes tmp_bug/tools
cp Bugs/evidence/BUG-325/inputs/rb98_bom.yaml tmp_bug/data/runbooks/rb98_bom.yaml          # rb09 saved with a BOM, id changed to rb98_bom
python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 runbook list
python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 runbook diagnose
rm tmp_bug/data/runbooks/rb98_bom.yaml
python -c "p='tmp_bug/data/scopes.yaml'; d=open(p,'rb').read(); open(p,'wb').write(b'\xef\xbb\xbf'+d)"
python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 brief bau
```

## Expected
A BOM is ignored (the project already reads other files with `utf-8-sig` tolerance); if a runbook file is bad, the message names the real problem and the other runbooks stay usable.

## Actual
```
$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 runbook list
Error: rb98_bom.yaml:?: required field 'id' missing
[exit 2]

$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 runbook diagnose
Error: rb98_bom.yaml:?: required field 'id' missing
[exit 2]

$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 brief bau
# Briefing bau
## Mission
Layout (LAYOUT-run5.md, bau owns ALL coordinates): accesses, stairs, gates, refuge, workshop halls, farms, crypt, depot, stockpiles, zones. Check every site with claude/area.
## Situation Y102 Hematite 12
Unfinished buildings 7 (target < 5); Full stockpiles 5 (target 0); Dig jobs 63 (target -)
## Known traps (python -m df_llm_helper kb get <id>)
- [fertigwaren_lager] Crafts unsellable: no finished-goods stockpile with containers: Finished-goods stockpile (quickfort g) with bins near the workshops; bins need wood; tie MakeCrafts to storage space. Runbook rb20.
[... 10 more lines, see evidence]
```

## Evidence
`Bugs/evidence/BUG-325/`.

## Analysis (reporter's hypothesis)
`yamlmini.load_file` reads with `encoding="utf-8"`; the BOM stays in the first key (`\ufeffid`), so `id` is "missing". `load_runbooks` aborts on the first invalid file (no per-file isolation), so one bad file disables `runbook list/show/run/diagnose`, the selftest and `check`'s runbook hints.

## Suggested fix (optional)
Open with `utf-8-sig`; in `load_runbooks`/`load_scopes` collect errors per file and keep the valid ones.

## Info needed
None.

## Fix
`yamlmini.load_file` reads `utf-8-sig`; the CLI loads runbooks per file and prints `Runbook skipped: <file>: <reason>` for an invalid one while the others stay usable (selftest/tests stay strict).
