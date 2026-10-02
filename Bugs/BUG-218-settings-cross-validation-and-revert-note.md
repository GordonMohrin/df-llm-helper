# BUG-218: `settings set` accepts STRICT_POPULATION_CAP lower than POPULATION_CAP (and vice versa); `settings revert` prints a false "file differs from the backup in other lines (edited by hand?)"

- **Status:** verified fixed (retest 2026-10-02, 8e67f05)
- **Severity:** S3
- **Area:** `df_llm_helper/features/settings.py` (`set`, `revert`), `data/settings.yaml`
- **Reported:** 2026-10-02, commit `6dedd96`
- **Environment:** Windows 11 Pro, Python 3.14.3; tests only against a COPY of `fixtures/v3/settings/d_init.txt` (temp folder with a space in the path, own backup dir); `settings get` and `settings pending` were also run against the real `prefs/d_init.txt` (read only). Game paused, fort date 27. Granite, Jahr 118.

## Command / steps
```
cd "<project folder>"
# temp config: settings: {file: '<tmp dir>/prefs/d_init.txt', backup_dir: '<tmp dir>/prefs/backups'}   (file = copy of the fixture)
python -m df_llm_helper --config <cfg> settings set STRICT_POPULATION_CAP 10 --reason "x"      # while POPULATION_CAP = 75
python -m df_llm_helper --config <cfg> settings set POPULATION_CAP 300 --reason "x"            # while STRICT = 10
python -m df_llm_helper --config <cfg> settings set VISITOR_CAP 0 --reason 'ö ü "q" 日本'
python -m df_llm_helper --config <cfg> settings revert BABY_CHILD_CAP; ... revert VISITOR_CAP; ... revert STRICT_POPULATION_CAP; ... revert POPULATION_CAP
```

## Expected
A refusal or at least a warning when the hard cap is below the soft cap (`STRICT_POPULATION_CAP 10 < POPULATION_CAP 75`: no migrants and no pregnancies at all while the fort has 174 inhabitants); no "edited by hand?" note when the file was only changed by this tool.

## Actual
```
STRICT_POPULATION_CAP: 100 -> 10 (backup d_init.txt.bak-2026-10-02-3)       accepted
POPULATION_CAP: 75 -> 300 (backup ...-4)                                    accepted (soft cap above the hard cap)
...
POPULATION_CAP: back to 75
NOTE: file differs from the backup in other lines (edited by hand?)         <- last revert; the file is byte-identical to the original afterwards
```
Everything else behaved: `--reason` required (also refused when empty), `abc`/`-1`/`99999`/`[75]` refused, unknown key refused, BABY_CHILD_CAP `a:b` format enforced, CRLF + the Latin-1 byte preserved (`cmp` against the original: identical after all reverts), one backup per change, special characters in `--reason` fine, `verify` correctly says "DF has been running since before the change (2802 min) - restart needed". Real file: `settings get` finds `prefs/d_init.txt` (75 / 100 / 266:1000 / 300) and the default list is right.

## Evidence
`Bugs/evidence/BUG-218/` (outputs of the set/revert sequence).

## Analysis (reporter's hypothesis)
Per-key validation only. The revert note compares the file with the backup taken at set time, which (after several changes) is not the original file.

## Suggested fix (optional)
Cross-check `STRICT >= POPULATION` on set; compare the file against "original + remaining recorded changes" for the note.

## Info needed
None. Gordon FYI (not a bug): live caps are POPULATION_CAP 75 / STRICT 100 while the fort has 174 inhabitants (the caps only stop new migrants).

## Fix
`settings set` warns `STRICT_POPULATION_CAP x < POPULATION_CAP y: the hard cap wins ... intended?` (warning, the player decides); the revert note compares with the backup taken before the first open change (kv `settings.origin_backup`), so the last revert reports `byte-identical`. Test: `test_bug218_*`.
