# BUG-318: Fair-play linter misses indirect forms: `reveal` via a variable, variables named like `order` (`border.pos.x = ...`), `unit.pos = {...}`, `blk.tiletype[i][j] = ...`, `mat_type` on variables not named item/it/itm, `getTileType` when `.hidden` appears anywhere else in the file

- **Status:** verified fixed (retest 2026-10-02, 8e67f05)
- **Severity:** S2
- **Area:** `df_llm_helper/lint.py` (rules L04, L08, L10, L17, L21)
- **Reported:** 2026-10-02, commit `50cee52`
- **Environment:** Windows 11, Python 3.14, game: running (DF 53.16 + DFHack) but PAUSED and untouched - this test uses the mock only

## Command / steps
```
cd <project folder>
mkdir tmp_bug && cp -r data tmp_bug/data && cp Bugs/evidence/BUG-318/cfg.yaml tmp_bug/cfg.yaml && mkdir tmp_bug/scopes tmp_bug/tools
mkdir tmp_bug/lint tmp_bug/sane && cp Bugs/evidence/BUG-318/inputs/L*.lua tmp_bug/lint/ && cp Bugs/evidence/BUG-318/inputs/sane_*.lua tmp_bug/sane/
python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 lint tmp_bug/lint     # six files, each contains a forbidden manipulation
python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 lint tmp_bug/sane     # the direct form of the same rules is reported
```

## Expected
Each of the six files is reported with the rule named in its file name (`L04_...` -> L04, ...). (The test tasks asked for a positive and a negative example per rule; all 30 rules have the direct form detected, see BUG-319 for false positives.)

## Actual
```
$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 lint tmp_bug/lint
0 findings (0 errors)
[exit 0]

$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 lint tmp_bug/sane
L04_direct.lua:1: L04 reveal/revflood uncovers the map
L08_direct.lua:1: L08 setting position directly (teleport)
L10_direct.lua:1: L10 reading a tile without checking 'discovered' (designation.hidden) (warning)
L17_direct.lua:1: L17 changing terrain
L21_direct.lua:1: L21 changing item material
5 findings (4 errors)
[exit 1]
```

## Evidence
`Bugs/evidence/BUG-318/` (inputs: 6 evading files + 5 direct forms; outputs). Full matrix of 146 pos/neg cases for L01-L30 (all direct forms detected, 12 mismatches = the ones in BUG-318/319) was run with a generator script kept at `Bugs/evidence/BUG-318/lint_matrix/` (`cases.py`, `run.py`).

## Analysis (reporter's hypothesis)
`lint.py` is line-regex based:
- L04 (`:46`) only matches `'reveal'`/`"reveal"` or `run_command(...reveal`; a command string built first (`local c = "reveal hell"; run_command(c)`) passes.
- L08 (`:49-51`) `unless_line=order|\bjob\b|job_item` is a substring test: the identifier `border` (or `recorder`, `jobless`) disables the rule for that line; the pattern covers `.pos.x =` and `setPos(` but not `u.pos = {...}`.
- L17 `\.tiletype\s*=(?!=)` does not match `blk.tiletype[1][1] = 5` (indexed assignment, the usual form).
- L21 `\b(item|it|itm)\.mat_(type|index)` is name-dependent.
- L10 `unless_file=\.hidden\b|...` switches the rule off for the whole file when `.hidden` occurs anywhere.
An LLM-written script is not adversarial, but renaming a variable is exactly what it does by accident.

## Suggested fix (optional)
Cheap hardening: L04 also match `reveal` as a whole word inside any string literal; L08 `\b(order|job)\b` word-boundary and add `\.pos\s*=(?!=)`; L17 `\.tiletype(\[[^\]]*\])*\s*=(?!=)`; L21 drop the variable-name list (`\.mat_(type|index)\s*=(?!=)` outside `job`/`order` lines); L10 require the `hidden` check within N lines.

## Info needed
Question for the cloud session: is the linter meant to be a hard gate against deliberate evasion, or a safety net against accidental cheating? (This decides how far to go with AST-based checks.)

## Fix
L04 any string starting with `reveal`; L08 also `.pos = {...}` and the order/job exemption only for whole words; L17 indexed `tiletype[..][..] =`; L21 `.mat_type/.mat_index =` on any variable outside job/order/filter objects; L10 needs a hidden check within 30 lines before / 10 after the read. Answer: the linter is a safety net against accidental cheating (regex), not a hard gate against deliberate evasion; a `.hidden` reference right next to the read still counts as a check.
