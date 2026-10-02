# BUG-316: `exception add`: impossible dates (`2026-13-45`, `2026-02-30`) are accepted and never expire, a date-only `--expires` is already expired at noon of that day, unknown rule ids (`FP0`, `L99`) and junk objects are accepted

- **Status:** fixed in 4bfefa4
- **Severity:** S2
- **Area:** `df_llm_helper/fairplay.py:ExceptionRegistry.add/find`
- **Reported:** 2026-10-02, commit `50cee52`
- **Environment:** Windows 11, Python 3.14, game: running (DF 53.16 + DFHack) but PAUSED and untouched - this test uses the mock only

## Command / steps
```
cd <project folder>
mkdir tmp_bug && cp -r data tmp_bug/data && cp Bugs/evidence/BUG-316/cfg.yaml tmp_bug/cfg.yaml && mkdir tmp_bug/scopes tmp_bug/tools
for d in 2026-13-45 2026-02-30 2026-10-02 30.09.2026 tomorrow 2026-1-1; do
  python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 exception add FP11 --reason r --ja q --expires "$d"
done
python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 exception add L99 --reason r --ja q
python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 exception add FP0 --reason r --ja q
python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 exception add FP13 --objects ",, ,a b,ä" --reason r --ja q
python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 exception list
```

## Expected
The task asked to test invalid rule ids and wrong date formats: `FPnn`/`Lnn` must be a **known** rule (FP01-FP10 in use, L01-L31), `--expires` must be a real calendar date (or timestamp) and a date-only value must be valid through the **end** of that day, objects must be numeric ids.

## Actual
```
$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 exception add FP11 --reason r --ja q --expires 2026-13-45
Exception registered: FP11 []
[exit 0]

$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 exception add FP11 --reason r --ja q --expires 2026-02-30
Exception registered: FP11 []
[exit 0]

$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 exception add FP11 --reason r --ja q --expires 2026-10-02
Exception registered: FP11 []
[exit 0]

$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 exception add FP11 --reason r --ja q --expires 30.09.2026
FAIR PLAY: [FP11] expires must be an ISO date (YYYY-MM-DD), got '30.09.2026'
[exit 3]

$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 exception add FP11 --reason r --ja q --expires tomorrow
FAIR PLAY: [FP11] expires must be an ISO date (YYYY-MM-DD), got 'tomorrow'
[exit 3]

$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 exception add FP11 --reason r --ja q --expires 2026-1-1
FAIR PLAY: [FP11] expires must be an ISO date (YYYY-MM-DD), got '2026-1-1'
[exit 3]

$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 exception add FP0 --reason r --ja q
Exception registered: FP0 []
[exit 0]

$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 exception add L99 --reason r --ja q
Exception registered: L99 []
[exit 0]

$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 exception add fp08 --reason r --ja q
FAIR PLAY: [fp08] unknown rule id (expected FPnn or Lnn, e.g. FP08, L31)
[exit 3]

$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 exception add FP1000 --reason r --ja q
FAIR PLAY: [FP1000] unknown rule id (expected FPnn or Lnn, e.g. FP08, L31)
[exit 3]

$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 exception add FP13 --objects ',, ,a b,ä' --reason r --ja q
Exception registered: FP13 [' ', 'a b', 'ä']
[exit 0]

$ python -c "for several 'now' values print whether each FP11 entry would still be valid (fairplay.py find(): expires < now)"
2026-10-02T00:00:00Z expires=2026-13-45             -> still valid: True
2026-10-02T00:00:00Z expires=2026-02-30             -> still valid: False
2026-10-02T00:00:00Z expires=2026-10-02             -> still valid: False
2026-10-02T12:00:00Z expires=2026-13-45             -> still valid: True
2026-10-02T12:00:00Z expires=2026-02-30             -> still valid: False
2026-10-02T12:00:00Z expires=2026-10-02             -> still valid: False
2026-10-03T00:00:00Z expires=2026-13-45             -> still valid: True
[... 3 more lines, see evidence]
```

`exception list` afterwards: see `Bugs/evidence/BUG-316/list.txt` (all accepted entries are listed, incl. `FP13 [' ', 'a b', 'ä']`).

## Evidence
`Bugs/evidence/BUG-316/*.txt`.

## Analysis (reporter's hypothesis)
`fairplay.py:150` accepts any `FP\d{1,3}` / `L\d{1,3}` (FP0, FP999, L99) - a typo that matches the pattern silently never matches a rule; `:153` validates `expires` only with a regex (`\d{4}-\d\d-\d\d`), so month 13 / day 45 pass, and because `find()` compares **strings** (`e.expires < self._now_iso()`), `2026-13-45` sorts after every real date: **a typo makes the exemption permanent**; `2026-10-02` < `2026-10-02T12:00:00Z`, so a date-only expiry is over at 00:00 of the named day (an exception "until 2026-10-02" is dead at noon that day).
`cli.py:420`: `objects` are split on commas with no trimming/numeric check (`' '` and `'a b'` become object ids; `find()` then compares them as strings).

## Suggested fix (optional)
Parse with `datetime.date.fromisoformat` / `datetime.fromisoformat`, treat a date-only value as end of day (`< now.date()`), check the rule id against `lint.RULES` + `FP01..` known list (plus `L31`), strip/validate object ids with `\d+`.

## Info needed
Question for the cloud session: which FPnn ids exist (docs mention FP08, FP09, FP10)? A list in `data/` would let `exception add` reject unknown ids.

## Fix
Rule id must be a known rule (FP01-FP13 from `FORBIDDEN_COMMANDS`, L01-L31 from the linter); `expires` must be a real ISO date or timestamp, a date-only value is valid through the end of that day and expiry is compared as datetime; objects must be numeric ids; `max_uses` an integer >= 1.
