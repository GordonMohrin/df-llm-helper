# BUG-119: documentation contradictions found by running the documented examples (`record --record` form, Python version, selftest duration/exit code, file names, which Lua files to install)

- **Status:** open
- **Severity:** S3
- **Area:** `docs/OVERVIEW.md:7,33,45,47`, `README.md:37,40,47`, `docs/MANUAL.md:11,14,106,118`, `docs/PLANNERS.md:3`, `docs/INTEGRATION.md:8`, `df_llm_helper/selftest.py:150-153`
- **Reported:** 2026-10-02, commit `50cee52` (code identical to `6dedd96`)
- **Environment:** Windows 11 Pro, Python 3.14.3, no game needed

## Command / steps
```
cd "<project folder>"
python Bugs/evidence/BUG-119/repro.py      # prints the contradicting doc lines and runs the examples
```

## Findings (`output.txt`)
1. **`record` example does not work as documented.** OVERVIEW.md:33: `record --record x.jsonl [commands…]` -> `error: unrecognized arguments: --record` (exit 2); `--record` is a *global* option and must precede the sub-command (the MANUAL.md:118 form `--record x.jsonl record <command>` works).
   The error message does not say that global options (`--mock --config --replay-file --record`) must come first.
2. **Python version:** README.md:40 "Python 3.11+", OVERVIEW.md:7, MANUAL.md:11, INTEGRATION.md:8 "3.12+", PLANNERS.md:3 `python3.12`. (Tested with 3.14.3 only.)
3. **Selftest:** README.md:37 "~10 s", MANUAL.md:106 "≈ 30 s"; `selftest --quick` takes 0.7 s. README says the full suite "needs pytest"; without pytest `python -m df_llm_helper.selftest` prints
   `[!] pytest not installed - only quick checks ran (pip install pytest after confirming with the player)` and **exits 0** without the line `Self-test GREEN` (selftest.py:150-153 `return 0 if ok else 1` before the final verdict) - a script cannot tell "full suite green" from "not run".
4. **File name:** OVERVIEW.md:47 "Known lint findings: `LINT-BEFUNDE.md`" - the file is `docs/LINT-FINDINGS.md`.
5. **Which Lua files to install:** README.md:47 and COMPANION.md:11 say all `lua/pilot_*.lua` (14 files) + `lua/claude/*.lua` (50 files); MANUAL.md:14 copies only `pilot_wd.lua` and `pilot_batch.lua`; OVERVIEW.md:47 describes `lua/` as "thin ... scripts (`pilot_wd.lua`, `pilot_batch.lua`)". (The v2/v3 chapters of the MANUAL name more `pilot_*.lua` files one by one.)
6. **Old names:** OVERVIEW.md:45 still calls the package folder `df-llm-helper/` (it is `df_llm_helper/`); an empty leftover folder `dfpilot/` (only `__pycache__`, untracked) still exists in the project root.
7. README quick start: `dashboard --out runtime/dashboard.html` works (checked with a temp path). `check`, `runbook diagnose` examples work.

## Evidence
`Bugs/evidence/BUG-119/repro.py`, `output.txt`.

## Suggested fix (optional)
Fix the OVERVIEW row (`--record x.jsonl record [commands…]`) and make the parser say "global options must precede the command"; one Python requirement everywhere (whatever is true); make `selftest` exit 2 + `Self-test INCOMPLETE (pytest missing)` without pytest unless `--quick`; correct names/paths.

## Info needed
Cloud session: which minimum Python version is real (3.11 or 3.12)? Does the code use 3.12-only features?
