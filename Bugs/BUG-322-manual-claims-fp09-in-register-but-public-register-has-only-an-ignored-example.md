# BUG-322: MANUAL 9.2 says the standing exception FP09 "has been in `data/exceptions.jsonl` since 2026-10-01"; the shipped register contains only an ignored example, so `exception list` is empty and `lint` reports `pilot_caravan.lua` as an error

- **Status:** fixed in e4af55c
- **Severity:** S3
- **Area:** docs/MANUAL.md 9.2 (and 5), `data/exceptions.jsonl`, `data/README.md`
- **Reported:** 2026-10-02, commit `50cee52`
- **Environment:** Windows 11, Python 3.14, game: running (DF 53.16 + DFHack) but PAUSED and untouched - this test uses the mock only

## Command / steps
```
cd <project folder>
grep -n FP09 docs/MANUAL.md docs/INTEGRATION.md data/README.md
cat data/exceptions.jsonl
python -m df_llm_helper --mock fixtures/run5 exception list
python -m df_llm_helper --mock fixtures/run5 lint lua/pilot_caravan.lua
```

## Expected
The documentation of the public repository is consistent: either the register ships FP09 or MANUAL 9.2 says it is a local, git-ignored entry (like FP08/FP10 in `data/exceptions.local.jsonl`, see `data/README.md`) and that `caravan --loop` refuses the stuck-merchant release without it.

## Actual
```
$ grep -n FP09 docs/MANUAL.md docs/INTEGRATION.md data/README.md CHANGELOG.md README.md
docs/MANUAL.md:144: - **Stuck caravan** (`Leaving`, 0 ticks, longer than `stuck_ticks` game ticks): `claude/pilot_caravan release --apply` sets `flags1.left` for merchant units only. Works *
docs/INTEGRATION.md:79: - [x] Register entry FP09 (the player's standing permission, 2026-10-01) is in `data/exceptions.jsonl`; `python -m df_llm_helper exception list` shows it.
CHANGELOG.md:107: - `df_llm_helper/caravan.py` (trade/skip decision from the real offer + `data/trade/wants.yaml`, approval only with a must-have good and ratio ≥ 2.0, skip without pause, 
CHANGELOG.md:110: - Register FP09 entered (the player's standing permission, 2026-10-01: send stuck merchants home via `flags1.left`).
[exit 0]

$ cat data/exceptions.jsonl
{"example": true, "ts": "2026-01-01T00:00:00Z", "action": "FP09", "objects": [], "reason": "example (ignored): send stuck traders home via flags1.left", "player_consent": "<verbatim quote from the player>"}

[exit 0]

$ python -m df_llm_helper --mock fixtures/run5 exception list
[exit 0]

$ python -m df_llm_helper --mock fixtures/run5 lint lua/pilot_caravan.lua
lua\pilot_caravan.lua:21: L07 setting unit 'left' (stuck traders, exception required)
1 findings (1 errors)
[exit 1]
```

## Evidence
`Bugs/evidence/BUG-322/*.txt`. Related: BUG-418 (same shipped-register effect from the Lua-side view).

## Analysis (reporter's hypothesis)
Commit `6dedd96` moved FP10 into the ignored local register and the shipped `exceptions.jsonl` holds `{"example": true, ... "FP09"}` which the loader skips; MANUAL 9.2 still describes the original private register. A reader (or a cloud session) following the manual expects the caravan release to work (`claude/pilot_caravan release --apply`) and sees `lint` fail with `pilot_caravan.lua:21: L07` as an error.

## Suggested fix (optional)
Reword MANUAL 9.2: "requires register entry FP09 in `data/exceptions.local.jsonl` (player consent); without it the helper refuses".

## Info needed
Question for the cloud session: should `lint lua` exit 0 for the bundled `pilot_caravan.lua` (documented in LINT-FINDINGS as 'intended')? At the moment the documented, intended finding makes `lint lua` exit 1.

## Fix
MANUAL 9.2 and INTEGRATION.md say FP09 belongs in the local register `data/exceptions.local.jsonl` (public register has only an example) and that `lint lua` then reports `pilot_caravan.lua:21 L07`. Answer: `lint lua` stays exit 1 without FP09 - the documented finding is not suppressed (fair play must not get weaker).
