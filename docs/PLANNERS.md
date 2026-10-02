# Planners (F11) – pure functions, no DF access

Package `df_llm_helper/planners/`, tests `tests/test_planners.py` (`python3.12 -m pytest tests/test_planners.py -q`).

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
- **Blueprint**: `(WxH)` = rectangle with the cell as its top-left corner; without a size, `w?`/`e?` (workshop/furnace) occupy 3x3 and `D` in `#build` 5x5, centered; `(WxHxD)` and negative sizes are accepted. Zone keys: `m b h D B o T d` plus `a` (archery range, used in `blueprints-bau/bau_o5_zone.csv`). Overlaps are checked per section. Passive headers (`#notes`, `#meta`, `#query`, `#ignore`, `#aliases`) are not checked; `# comment` is an error (E_HEAD).
- The lower map boundary is checked only when `origin` is given (centered buildings in column 0 would otherwise appear to protrude).
