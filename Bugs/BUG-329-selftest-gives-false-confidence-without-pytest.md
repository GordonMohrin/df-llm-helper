# BUG-329: `selftest`: `--cov` is silently ignored, the check `Diagnosis on fixtures` is constant `True`, and the briefing-size check runs on empty memory (max 599 tokens) while real briefs reach 1165 tokens

- **Status:** verified fixed (retest 2026-10-02, 8e67f05)
- **Severity:** S3
- **Area:** `df_llm_helper/selftest.py`
- **Reported:** 2026-10-02, commit `50cee52`
- **Environment:** Windows 11, Python 3.14, game: running (DF 53.16 + DFHack) but PAUSED and untouched - this test uses the mock only

## Command / steps
```
cd <project folder>
python -m df_llm_helper.selftest ; echo "exit $?"
python -m df_llm_helper.selftest --cov ; echo "exit $?"
```

## Expected
`--cov` without coverage/pytest is an error; every check can fail; the briefing check exercises real-size memory/inbox input.

## Actual
```
$ python -m df_llm_helper.selftest
df-llm-helper self-test (without DF)
  [ok] Digest fixtures/run5 <= 600 tokens: 73 tokens
  [ok] Digest without change <= 30 tokens: 17 tokens
  [ok] Load rules, no conflicts: 13 rules
  [ok] Runbooks valid (>= 12): 19 runbooks
  [ok] Diagnosis on fixtures: rb01_e18_pick, rb08_hospital, rb20_fertigwaren_lager, rb06_karawane
  [ok] Load KB: 37 entries
  [ok] Briefings <= 1500 tokens (12 scopes): max 599 tokens
  [ok] Scenarios (10): all ok
  [ok] Fair-play block: createitem blocked
  [!] pytest not installed - only quick checks ran (pip install pytest after confirming with the player)
[exit 0]

$ python -m df_llm_helper.selftest --cov
df-llm-helper self-test (without DF)
  [ok] Digest fixtures/run5 <= 600 tokens: 73 tokens
  [ok] Digest without change <= 30 tokens: 17 tokens
  [ok] Load rules, no conflicts: 13 rules
  [ok] Runbooks valid (>= 12): 19 runbooks
  [ok] Diagnosis on fixtures: rb01_e18_pick, rb08_hospital, rb20_fertigwaren_lager, rb06_karawane
  [ok] Load KB: 37 entries
  [ok] Briefings <= 1500 tokens (12 scopes): max 599 tokens
  [ok] Scenarios (10): all ok
  [ok] Fair-play block: createitem blocked
  [!] pytest not installed - only quick checks ran (pip install pytest after confirming with the player)
[exit 0]

$ grep -n "Diagnosis on fixtures\|memory_text=None" df_llm_helper/selftest.py
selftest.py:44: res.append(("Diagnosis on fixtures", True, ", ".join(h.runbook.id for h in diagnose(rbs, ctx)[:4])))
selftest.py:48: worst = max(tokens(build_brief(sc, scopes_def=sd, ctx=ctx, snap=s, kb=kb, memory_text=None, inbox_lines=None,
[exit 0]

$ python -m df_llm_helper [--mock fixtures/run5] brief <scope> | tokens = len(text)//3
scope        mock(no memory)  live(real memory+inbox)
trinken        538     786
essen          530     894
bau            560    1165
erkundung      502     928
wirtschaft     608     780
auslastung     451     641
material       509     685
militaer       502     955
verteidigung   527     839
gesundheit     542     821
handel         595    1024
infra          549     919
(the selftest checks only the first column: max 599)
```

## Evidence
`Bugs/evidence/BUG-329/*.txt`.

## Analysis (reporter's hypothesis)
`selftest.py`: (the exit code 0 without pytest and the documented durations are already BUG-119 item 3); `--cov` without pytest/coverage is silently ignored; `res.append(("Diagnosis on fixtures", True, ...))` is constant `True`; the briefing check builds briefs with `memory_text=None, inbox_lines=None` (max 599 tokens) - real briefs with the real memory/inbox are up to 1165 tokens (bau, live), i.e. the budget check does not exercise the case that can exceed it.

## Suggested fix (optional)
Make `--cov` without pytest an error; feed the briefing check with `fixtures/run5/scopes_sample/*.md` as memory/inbox; make `Diagnosis on fixtures` assert at least the known hits.

## Info needed
None.

## Fix
`Diagnosis on fixtures` asserts the known hits; the briefing check also runs with real-size memory and inbox; `--cov` without pytest fails and `--cov --quick` is a usage error (the exit code without pytest in general is BUG-119).
