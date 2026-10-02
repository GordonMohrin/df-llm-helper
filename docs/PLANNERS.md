# Planners (F11) – pure functions, no DF access

Package `df_llm_helper/planners/`, tests `tests/test_planners.py` (`python -m pytest tests/test_planners.py -q`).

| Module | Function | Core |
|---|---|---|
| `trade.py` | `plan_trade(own, offer, ratio=2.3, reserves, priorities, max_weight, method="auto")` -> `TradePlan(buy, sell, buy_value, sell_value, ratio, weight, notes)` | Constraint sell >= ratio * buy (exact via Fraction), reserves per ID/category (minimum stock), weight limit. Goal: maximize weighted buy value, then minimize buy value, then minimize sell. Exact via branch-and-bound (<= 24 items, node limit), otherwise greedy (`plan.method`, `notes`). |
| `dig.py` | `parse_area(text)`, `plan_dig(grid, targets, starts, picks, max_open, access)` -> `DigPlan(batches, unreachable, notes)` | BFS/Prim over targets starting from walkable/designated area, priority (lower = earlier, inherited by access tiles), batch <= min(max_open, 10*picks) minus open jobs, `batch_to_csv` produces a `#dig` CSV. |
| `armor.py` | `soldier_quota(pop)`, `plan_armor(pop, soldiers, stock, bars)` -> `ArmorPlan` | Quota tiers, missing pieces from stock, the rest as forging orders (weapon, breastplate, helm, shield, greaves, boots, gauntlets), bars per metal. |
| `supply.py` | `forecast(stock, pop, consumption, production, growth, horizon_days)` -> `Forecast(days_left, curve, warn)` | Daily simulation; `days_left[res]` = days until stock hits 0, `None` = no shortage within the horizon (default 336 days). |
| `blueprint.py` | `validate_blueprint(text, map_size=None, origin=None)` -> `list[Finding(line, col, code, msg, level)]` | Syntax, zone keys, overlap, map, order, columns. Codes in `blueprint.CODES` (E_* errors, W_* warnings). |

Fixtures: `tests/blueprints_bad/` (10 errors, `EXPECTED.txt` = `file;code`), `fixtures/run5/blueprints_ok/` (10 valid CSVs of our own).

## Assumptions – verify live before productive use
- **Bars per piece** (`armor.BARS_PER_PIECE`: weapon 3, breastplate 3, helm 1, shield 2, greaves 2, boots 1, gauntlets 1) are NOT measured; the metal order `armor.METAL_ORDER` likewise.
- **Quota** 15/40/60 -> 2/4/6, above that 10 % rounded up: a project rule from CLAUDE.md, configurable (`tiers`, `percent`).
- **Consumption** `supply.DEFAULT_CONSUMPTION`: food 2, drinks 5 per dwarf and season (84 days), taken from `lua/claude/status.lua`.
- **Trade**: price ratio 2.3 and weight ("Excess Weight") are modeled as linear constraints; the actual merchant prices (markups, the broker's trading skill) come from `claude/handel plan` and must be fed in as `value`. The priority weight 2*(n-index) is a modeling choice.
- **Dig**: 4-neighborhood; walkable = `. " o + < > X ^ v S f D b @ ! a t`, diggable = `# , *`; furniture `n` and buildings `W w B` block, `?` is never diggable (no revealing, fair play).
- **Blueprint**: `(WxH)` = rectangle with the cell as its top-left corner; without a size, `w?`/`e?` (workshop/furnace) occupy 3x3 and `D` in `#build` 5x5, centered; `(WxHxD)` and negative sizes are accepted. Zone keys: quickfort's full zone table `m b h n p w j f s o D B a d t T g c`. CSV-quoted cells (`"n{name=""Nest""}"`) are unquoted; identical adjacent building keys without a size (`wj` in every tile of the 3x3) are one building. `W_COLS` only for content beyond the width of the section's first row. Overlaps are checked per section. Passive headers (`#notes`, `#meta`, `#query`, `#ignore`, `#aliases`) are not checked; `# comment` is an error (E_HEAD).
- The map boundary (E_BOUNDS) is checked only with `map_size` (CLI: `plan blueprint --map-size 192x192`), the lower boundary only when `origin` is given as well (`--origin x,y`; centered buildings in column 0 would otherwise appear to protrude).

## CLI input of `plan trade --json`
Items need `id, name, category, value, weight`, optionally `qty` (default 1) and `priority_category`; top level `own`, `offer`,
`ratio` (default 2.3), `reserves` (per id/category), `max_weight`, `priorities` (categories to buy, in order; default
`food, wood, metal, cloth, other` - other categories are never bought, the note names the skipped items). Example:
```json
{"own": [{"id": "o1", "name": "Rock mug", "category": "other", "value": 100, "weight": 2, "qty": 10}],
 "offer": [{"id": "f1", "name": "Plump helmet", "category": "food", "value": 10, "weight": 1, "qty": 20},
           {"id": "f3", "name": "Gem", "category": "gem", "value": 50, "weight": 0.1, "qty": 5}],
 "ratio": 2.3, "reserves": {"o1": 2}, "max_weight": 100, "priorities": ["food", "gem"]}
```
`plan supply` counts food as meals + fish + meat (raw plants are brewing stock); the digest's `Food Nd` is the game's
`food_days`, which includes raw plants - the output names both.
