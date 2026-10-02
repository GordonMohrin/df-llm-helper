# BUG-331: `kb import` prints each per-file message twice

- **Status:** fixed in 4012e2e
- **Severity:** S3 (cosmetic)
- **Area:** `df_llm_helper/cli.py` (`cmd_kb`, `main`)
- **Reported:** 2026-10-02 (retest of BUG-301/302), commit `61e5c13`

## Actual
`main()` copies the positional words into `args.files`, and `cmd_kb` joins `args.query + args.files`. Every file was
processed twice, so every message appeared twice.

## Fix
`cmd_kb` de-duplicates the file list and keeps the order. Test: `tests/test_bugs_know.py::
test_bug301_kb_bus_dashboard_brief_arguments` (each message exactly once).

## Info needed
none.
