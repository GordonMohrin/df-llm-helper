# BUG-310: `journal chronik`: ordinary game messages are classified as `Emergency`/`Mood` (finished floodgate order, magma pool discovery, artifact naming) and a combat dodge line is not filtered as noise

- **Status:** verified fixed (retest 2026-10-02, 8e67f05)
- **Severity:** S3
- **Area:** `df_llm_helper/journal.py:TYPE_OF`, `NOISE`
- **Reported:** 2026-10-02, commit `50cee52`
- **Environment:** Windows 11, Python 3.14, game: running (DF 53.16 + DFHack) but PAUSED and untouched - this test uses the mock only

## Command / steps
```
cd <project folder>
mkdir tmp_bug && cp -r data tmp_bug/data && cp Bugs/evidence/BUG-310/cfg.yaml tmp_bug/cfg.yaml && mkdir tmp_bug/scopes tmp_bug/tools
cp Bugs/evidence/BUG-310/inputs/events.log tmp_bug/events.log       # 5 lines taken from fixtures/run5_live/events_run3.log and the live events.log
python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 journal ingest --events tmp_bug/events.log --date 2026-10-02
python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 journal chronik
```

## Expected
Only the death line is a chronicle fact. `QUOTA_FILLED` (a work order is complete), `FEATURE_DISCOVERY` (magma found: at most an `Info`), `NAMED_ARTIFACT` (not a strange mood) and `DODGE_FLYING_OBJECT` (combat noise) must not appear as `Emergency`/`Mood`/`Attack` items.

## Actual
```
$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 journal ingest --events tmp_bug/events.log --date 2026-10-02
5 chronicle events in the log, 5 new; 0 critical df-llm-helper warnings taken over
[exit 0]

$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 journal chronik
- 10-02 10:00 Emergency: Make rock floodgate (1) has been completed.; You have discovered a magma pool. (+1 more)
- 10-02 10:10 Mood: Id Ozkaktun, militia captain has bestowed the name Nolethkib upon a iron battle axe!
- 10-02 10:20 Death: 1 deaths: Urist McMiner has been found dead (? 1x)
(coverage 100 % of the events)
[exit 0]
```

Real examples from the live log (`dwarf-fortress/tools/events.log`, 2026-10-02): `10-02 08:42 Emergency: The goblin Pikemaster jumps out of the goblin Pikemaster's flight path!` and from the Run 3 fixture `10-01 16:18 Emergency: Make rock floodgate (1) has been completed.`, `10-01 11:37 Emergency: You have discovered a magma pool.`, `10-01 15:07 Mood: ... has bestowed the name Nolêthkib upon a iron battle axe!`.

## Evidence
`Bugs/evidence/BUG-310/`.

## Analysis (reporter's hypothesis)
`journal.py:TYPE_OF`: the type is decided by regex on the tag **and the text**: `FLOOD` matches `floodgate`, `ARTIFACT` matches `NAMED_ARTIFACT`; unknown `KRITISCH` tags fall through to a default type (`Emergency`). `NOISE` lacks `DODGE_FLYING_OBJECT`, `QUOTA_FILLED`.

## Suggested fix (optional)
Match on the tag only (anchored: `^(CITIZEN_)?DEATH$`, `^ARTIFACT_(BEGUN|CREATED)$`...), add `DODGE_*`, `QUOTA_FILLED`, `NAMED_ARTIFACT`, `FEATURE_DISCOVERY` to NOISE or give them their own low-priority type.

## Info needed
None.

## Fix
Types match whole tag words (`FLOOD` no longer matches `FLOODGATE`); `NAMED_ARTIFACT`/`FEATURE_DISCOVERY` are type `Info`; `DODGE*` and `QUOTA_FILLED` are noise.
