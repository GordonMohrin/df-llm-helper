# BUG-108: `plan supply` food forecast (42 days) disagrees with the digest's `Food 85d` for the same live data (plants counted differently, not documented)

- **Status:** fixed in 626d04f
- **Severity:** S3
- **Area:** `df_llm_helper/cli.py:643-652` (`plan supply`: `food = meals + fish + meat`), `df_llm_helper/digest.py:252-253` (status line uses `claude/status` `food_days`), `df_llm_helper/forecast.py` (`include_raw_plants: True`)
- **Reported:** 2026-10-02, commit `50cee52` (code identical to `6dedd96`)
- **Environment:** Windows 11 Pro, Python 3.14.3, game running (DF 53.16 + DFHack, **paused**), fort "Windrings", date `27. Granite, Jahr 118`

## Command / steps
```
cd "<project folder>"
python -m df_llm_helper digest --full        # "Drinks 49d Food 85d"
python -m df_llm_helper plan supply          # "food: ... empty in 42 days"
python Bugs/evidence/BUG-108/repro.py        # same discrepancy with the mock fixture (189 d vs 126 d)
```

## Expected
The same stock must give the same order of magnitude in the tools of one product, or the difference must be named in the output.

## Actual
Live: `claude/status` says `food_days 85` (`stock.food` 354 = 176 meals + 174 plants + 4), `claude/report` says `mahlzeiten 176, pflanzen 174, fisch 0, fleisch 0`.
```
Status ... Drinks 49d Food 85d ...                       (digest)
drink: stock 512, empty in 49 days                        (plan supply: matches 49 d - the consumption model of PLANNERS.md fits drinks)
food: stock 176, empty in 42 days                         (plan supply: plants are not counted)
```
Mock `fixtures/run5`: digest `Food 189d`, `plan supply` `food: stock 72, empty in 126 days`. `forecast` (spec 05) counts raw plants (`include_raw_plants: True`), `plan supply` does not, and nothing says so.
Also: with an unreadable game the command prints `stock 0 ... no shortage` (see BUG-106), `--prod bogus=5` (unknown resource) and `--growth -1` (negative immigrants) are accepted silently (BUG-114).

## Evidence
`Bugs/evidence/BUG-108/live_values.txt` (raw excerpts of `claude/status`, `claude/report` and the live `plan supply` output), `repro.py`, `output.txt`.

## Analysis (reporter's hypothesis)
Not necessarily a defect: Gordon's rule is "Plump Helmets are for alcohol only, never cooked" (project memory), so excluding plants from *food* is plausible - then the digest's `Food <n>d` (taken from the game's own `food_days`, which includes plants) is the optimistic one.
Either way the product shows two different numbers without an explanation.

## Suggested fix (optional)
Print the composition in `plan supply` (`food: stock 176 (meals 176, fish 0, meat 0; plants 174 not counted)`), and decide whether the digest should use the same definition (a `digest.food_days_source` option).

## Info needed
Cloud session / Gordon: which definition of "food days" is wanted for decisions - game `food_days` (incl. plants) or meals+fish+meat only?

## Fix
`plan supply` prints the composition (`meals, fish, meat; raw plants N not counted`) and a note that the digest's `Food Nd` is the game's `food_days` incl. plants; documented in PLANNERS.md. The definition itself (decision for Gordon) is unchanged. Test: `test_bug108_*`.
