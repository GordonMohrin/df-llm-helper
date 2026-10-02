# BUG-114: missing/unknown arguments are accepted as success (`autopilot enable`, `guard ack-gate`, `plan ...`) and some write junk into `state.db`

- **Status:** open
- **Severity:** S3
- **Area:** `df_llm_helper/cli.py:177-180` (`autopilot enable`), `:191-199` (`guard ack-gate`), `:578-584` (`_kv`), `:589-652` (`plan ...`)
- **Reported:** 2026-10-02, commit `50cee52` (code identical to `6dedd96`)
- **Environment:** Windows 11 Pro, Python 3.14.3, mock + temp folder

## Command / steps
```
cd "<project folder>"
python Bugs/evidence/BUG-114/repro.py
```

## Expected
Unknown rule id / missing gate number / unknown gate / malformed `k=v` -> `Error: ...`, exit 2, nothing stored (like `guard ack-gate abc` already does via argparse: `invalid int value`).

## Actual
```
$ autopilot enable                    ->  Rule None active again          [exit 0]   (rule_state gets a row with rule = NULL)
$ autopilot enable no_such_rule       ->  Rule no_such_rule active again  [exit 0]   (row 'no_such_rule' created; the real, disabled rule stays disabled if the id was mistyped)
$ guard ack-gate                      ->  Pop gate None acknowledged      [exit 0]   (gates_acked = [None])
$ guard ack-gate -5 / 61              ->  Pop gate -5/61 acknowledged                 (valid gates are config guard.pop_gates [60, 80]; a mistyped 6 reports success while `tempo on` stays blocked)
$ plan armor --bars iron              ->  silently ignored (no '=')  -> "available 0, missing 78"
$ plan supply --prod bogus=5          ->  silently ignored (unknown resource; only drink/food exist)
$ plan supply --growth -1             ->  accepted (negative immigrants) -> "no shortage within the horizon"
$ plan dig --area-file <file>         ->  no output, exit 0 (no --targets)       ; plan blueprint (no files) -> no output, exit 0
```
`guard.state.gates_acked` ends as `[None, -5, 61]` and `rule_state` contains the junk rows (output.txt). The corrupt `gates_acked` list is persisted JSON that later code compares with ints.

## Evidence
`Bugs/evidence/BUG-114/repro.py`, `output.txt`.

## Analysis (reporter's hypothesis)
`cmd_autopilot enable` / `cmd_guard ack-gate` never check their positional arguments (both are `nargs="?"` in `build_parser`). `_kv` accepts any `k=v` pair and drops parts without `=`.

## Suggested fix (optional)
`enable`: require the id and check it against `p.rules()` (`Error: unknown rule 'x' (see autopilot rules)`); `ack-gate`: require `gate in cfg.guard.pop_gates`; `_kv`: raise `ValueError` for parts without `=` and for unknown resource names; `plan dig`/`plan blueprint`: require `--targets` / at least one file.

## Info needed
None.
