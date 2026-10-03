# Forbidden supplies: `python -m df_llm_helper forbid-watch` (FEATURE-003, live-untested)

**Why:** Run 5 lost more than 10 dwarves to thirst while 475 drinks stood in the fort: the barrels (and 743 blocks) were
forbidden, the dwarves cancelled `Drink: Forbidden area`, and nothing warned (BUG-125). `forbid-watch` counts the
forbidden own items, finds the cause and proposes the unforbid.

## Commands
- `python -m df_llm_helper forbid-watch [--json] [--dry-run]` (read only):
  ```
  ! Forbidden own items: 1043 (drinks 475/475, food 0/220)
  !! FORBID: 1043 own items forbidden (drinks 475 = 100 %), 37 Forbidden-area cancels in 10 min -> drinking blocked
  classes: containers 300, drinks 0, food 0, material 743, other 0; drinks blocked 475/475 (475 in forbidden containers), food blocked 0/220
  causes: dense area (mass forbid designation or a script) 1043
  where: z130 x86..101 y112..127: 900 (container 260, material 640, stockpile #495)
  standing orders on: forbid_other_dead_items (they forbid dead units' items on purpose; keep them during sieges)
  cancels: Drink 30, Eat 7
  script logs: no claude/* log mentions forbidding
  for comparison: own items claimed by a job 12, dump-marked 0
  fix: python -m df_llm_helper forbid-watch fix (dry run, 300 own drink/food/container items; --apply unforbids them)
  ```
  "drinks blocked" counts drinks/food forbidden themselves or sitting in a forbidden barrel/pot/bin (a drink in a
  forbidden barrel is not flagged itself). Own = not trader/foreign/hostile goods, not built in. Items on undiscovered
  tiles are only counted (fog of war).
  **Causes** (per item, first match): on a dump zone (DF forbids what it dumped), own dead / other dead (standing orders
  `forbid_own_dead_items` / `forbid_other_dead_items`), used ammo (`forbid_used_ammo`), foreign-made (siege loot), dense
  area (>= 20 forbidden items in one 16x16 map block: a mass forbid designation or a script), unknown. `claude/*` logs
  below `paths.tools` (`out/*.log`, `events.log`) that mention forbidding are listed as a hint.
  **Game log:** `X cancels <job>: Forbidden area` lines from `paths.gamelog` (own read offset; the first read counts only
  the last `first_tail_lines`), summed over `log_minutes` (10). Cancels without forbidden items: `Forbidden-area cancels
  without forbidden items (burrow/zone?)` - check burrows and restricted zones instead.
- `forbid-watch fix [--classes drink,food,container] [--max 2000] [--apply]`: clears the forbid flag of own items of
  those classes (the item menu's forbid toggle). Without `--apply` a dry run (count, ids). Never touched: siege loot
  (`other`, refused), foreign/trader goods, items on undiscovered tiles, items lying on a dump zone. `material` (blocks,
  logs, bars, boulders) only when asked. Every changed id goes to `<home>/tools/out/forbid-fix.log` and the action log;
  at most `fix_per_hour` (3) applied runs per hour. `--fix` is an alias of the action `fix`.

## In `check` and the digest
Every `every_s` (5 min, one item scan). State `warn` when drinks or food blocked > `drink_warn_pct`/`food_warn_pct` (20 %)
or Forbidden-area cancels > `cancel_warn` (10) while items are forbidden; state `area` for many cancels without forbidden
items. Then the two lines above (repeated only on a change or after 30 min); on a change INTO a warning state one crit
warning: one wake line and one line in the next digest (`[forbid-watch] Forbidden own items: ...`). Back to normal:
`Forbid-watch: resolved - ...`. Forbidden siege loot alone is `info` (never warned). While forbid-watch reports,
hygiene's own forbidden-supply warning stays quiet (no duplicate). The digest status line keeps `Drinks Nd (+M forbidden)`
from BUG-125.

## Configuration (`config.yaml`, section `forbid_watch`)
`log_minutes` (10), `cancel_warn` (10), `drink_warn_pct` (20), `food_warn_pct` (20), `first_tail_lines` (300),
`every_s` (300), `fix_classes` ([drink, food, container]), `fix_max` (2000), `fix_per_hour` (3), `repeat_s` (1800),
`in_check` (true).

## Install
`python -m df_llm_helper install-lua --apply` copies `lua/pilot_forbid.lua` to `hack/scripts/claude/`. Without it
forbid-watch falls back to `claude/pilot_hygiene forbid` (counts only, no causes, no fix).

## Not done
- "who forbade it" is a hint, not a record: DF stores no author per item flag. The causes are derived from the item
  (position on a dump zone, corpse race, maker race, density) and the standing orders.
- The fix needs no exception-register entry (unforbidding own items is a normal UI action; the request's draft asked
  for one); it is never run automatically, only with `--apply`.
