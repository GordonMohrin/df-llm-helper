# BUG-123: `plan trade --json`: item field names are not documented anywhere, `priorities` (documented for `plan_trade`) cannot be passed, other categories than food/wood/metal/cloth/other are silently never bought

- **Status:** verified fixed (retest 2026-10-02, 8e67f05)
- **Severity:** S3
- **Area:** `df_llm_helper/cli.py:598-611` (`cmd_plan` kind `trade`), `df_llm_helper/planners/trade.py:36-52` (`TradeItem`), `docs/PLANNERS.md` (row `trade.py`), `--help` of `plan`
- **Reported:** 2026-10-02, commit `50cee52` (code identical to `6dedd96`)
- **Environment:** Windows 11 Pro, Python 3.14.3, no game needed

## Command / steps
```
cd "<project folder>"
python Bugs/evidence/BUG-123/repro.py
```

## Expected
`plan trade --help` (or PLANNERS.md) shows a complete example of the JSON: item fields `id, name, category, value, weight[, qty, priority_category]`, top-level `ratio`, `reserves`, `max_weight` and, as documented for the planner function, `priorities`.

## Actual
- The only help is `--json JSON  trade: input {own:[...], offer:[...], ratio, reserves, max_weight}`. A hand-written file with natural field names (`price`, `amount`) ends in `TypeError: TradeItem.__init__() got an unexpected keyword argument 'price'` (traceback, BUG-113); a file with a missing field in `TypeError: ... missing 4 required positional arguments`. A working example had to be reverse-engineered from the dataclass: `Bugs/evidence/BUG-123/working_example_trade.json`.
- `cmd_plan` never passes `priorities` (PLANNERS.md: `plan_trade(own, offer, ratio=2.3, reserves, priorities, max_weight, ...)`; trade.py: "categories not listed are never bought", default `food, wood, metal, cloth, other`). Adding `"priorities": ["gem", "food"]` to the JSON is silently ignored (section B, same output).
- Consequence for real use: an offer item with category `gem`, `seeds`, `leather`, ... is never bought; the only hint is `Note: 1 offer items in unlisted categories are not bought` (no names, no way to change it from the CLI).
- Output sample (section A): `Buy 320 / sell 800 (ratio 2.5), weight 100.0, method exact` - fine and correct (320 = 20x10 + 8x15, 800 >= 2.3 x 320, weight 100 = limit).

## Evidence
`Bugs/evidence/BUG-123/repro.py`, `output.txt`, `working_example_trade.json`.

## Analysis (reporter's hypothesis)
The CLI wrapper was written as a thin pass-through (`TradeItem(**x)`); `priorities` is a keyword of `plan_trade` but not read from `d`.

## Suggested fix (optional)
Pass `priorities=d.get("priorities")`; validate keys with a friendly message listing the allowed ones; put the example JSON into PLANNERS.md and `--help` epilog; list the names of the skipped items in the note.

## Info needed
Cloud session: is the trade planner meant to be fed by `claude/handel list` output (live JSON in `fixtures/run5_live/handel_list_*.json`)? If yes a converter (`plan trade --from-handel`) would remove the need for hand-written JSON.

## Fix
`plan trade` validates the JSON (object root, item fields `id, name, category, value, weight[, qty, priority_category]`, friendly message with the allowed fields and an example), passes `priorities`, and the note names the skipped items and their categories; format documented in PLANNERS.md (6d7faa3). Not done: a `--from-handel` converter (Info question). Test: `test_bug123_*`.
