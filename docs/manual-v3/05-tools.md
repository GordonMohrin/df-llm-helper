# Tool/pick manager (`python -m df_llm_helper tools`) – spec v3-05

Status: implemented, **not yet live-tested**. The Lua part (`lua/pilot_tools.lua`, installed as `claude/pilot_tools`)
is read-only and LIVE-UNTESTED; actions use the existing scripts `claude/pickfix` and `claude/workdetail`.

## Commands
| Command | What it does | DF access |
|---|---|---|
| `python -m df_llm_helper tools status` | `Picks 15/34: pickfix needed` or `Picks 34/34, miners 34, digging 29, open dig jobs 256`; free picks with location (`BIN (82,99,128) x19`); miners without pick; forge proposal | `claude/pilot_tools status` |
| `python -m df_llm_helper tools [check] [--dry-run]` | One maintenance pass (rules below) | + `claude/workdetail assign <id> Miners true`, `claude/pickfix --apply` |
| `python -m df_llm_helper tools after-load [--dry-run]` | Same, plus pickfix once even if balanced (after reloading a save) | as check |
| `python -m df_llm_helper check` | Runs the pass as a feature hook; prints lines only on an action or deviation; detects a reload (report id dropped) and runs `pick_after_load` | as check |

## Rules
1. **More miners first:** open dig jobs > `dig_jobs_min` (100) and miners < picks → up to `max_new_miners` (18 per hour)
   idle adult civilians join work detail `Miners`. **Never** soldiers, children, patients (cannot stand, resting,
   wounded in hospital), dwarves in a hospital zone, or hunger/thirst > `hunger_max` (30,000). Best mining skill first.
2. **Pick balance:** work picks < min(miners, picks) and free picks → `claude/pickfix --apply`.
3. **No free pick:** no call, forge proposal (`picks < miners + reserve`); missing iron/coke → `python -m df_llm_helper bottleneck`.

## Fair play: FP08
`claude/pickfix --apply` writes the per-unit pickup flag (`unit.uniform.pickup_flags.update`). df-llm-helper calls it only
with an exception-register entry **FP08** whose reason mentions the pick fix (entries bound to item ids, i.e. the
foreign-flag exception, do not count):
```
python -m df_llm_helper exception add FP08 --reason "pick fix: per-unit pickup flag" --ja "<player's words>"
```
Without it: `pickfix refused: ... needs an exception-register entry FP08 ...` plus a digest warning. `work_weapons`
itself is never written by df-llm-helper (lint rule L11).

## Safety
- Loop guard: max `max_pickfix_per_hour` (6) pick fixes per hour; the same observation (work picks, free picks, miners,
  picks) within `repeat_block_s` (600 s) after a pick fix → "waiting for the effect", no new call.
- Every action is in `state.db` (table `actions`, rules `tools_miners`, `tools_pickfix`; shown by `python -m df_llm_helper journal postmortem` and the dashboard events) with
  its reason; added miners in kv `tools.added_miners`.
- `--dry-run` writes nothing.

## Config (`tools:` in config.yaml)
`reserve 4, max_new_miners 18, hunger_max 30000, workdetail Miners, dig_jobs_min 100, max_pickfix_per_hour 6,
repeat_block_s 600, pickfix_cmd "claude/pickfix --apply", after_load true, in_check true`.

## Live check (open)
Install `lua/pilot_tools.lua` as `hack/scripts/claude/pilot_tools.lua`; compare `tools status` with the game
(picks, bin location, work picks); add the FP08 entry with the player's consent; run `tools check --dry-run`, then live.

**Consent for your installation:** put the FP08 entry into `data/exceptions.local.jsonl` (git-ignored, merged with
`data/exceptions.jsonl` when loading). Example line:
`{"action": "FP08", "objects": [], "reason": "pick fix: pickup flag for MINE dwarves", "player_consent": "<your words>"}`
