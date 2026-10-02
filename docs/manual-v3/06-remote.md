# Remote-worker protection (`python -m df_llm_helper remote`) – spec v3-06 ("python -m df_llm_helper care remote")

Status: implemented, **not yet live-tested**. Own command (the spec name was `care remote`; `python -m df_llm_helper care` is
unchanged). Lua: `lua/pilot_remote.lua`, installed as `claude/pilot_remote` (LIVE-UNTESTED).

## Commands
| Command | What it does | DF access |
|---|---|---|
| `python -m df_llm_helper remote status` | Hungry/thirsty or long-job dwarves with distance to the nearest food/drink place; pool sizes; labors held back | `claude/pilot_remote status FISH,HERBALISM,MINE,PLANT` |
| `python -m df_llm_helper remote [check] [--dry-run]` | One maintenance pass (rules below) | + `claude/pilot_remote cancel <id>`, `claude/pilot_remote labor <id> <LABOR> off\|on [WD,...]` |
| `python -m df_llm_helper remote restore [--dry-run]` | Gives back every labor held back (rescue and pool) | `labor ... on` |
| `python -m df_llm_helper check` | Runs the pass as a feature hook; lines only on actions, escalations or a fishing proposal | as check |

## Rules
1. **Rescue:** hunger or thirst > 40,000 and (more than `far_tiles` 40 from food/drink, or job in `long_jobs`
   Fish/GatherPlants) → cancel the job and take away the job's labor (`job_labors`: Fish→FISH, GatherPlants→HERBALISM,
   HarvestPlants→PLANT, Dig→MINE), incl. selective work details granting it. Plus a proposal: food stockpile/drink
   barrel near that place. Per dwarf at most once per 10 min.
2. **Return:** as soon as hunger AND thirst < 15,000 the labor and the work details come back (automatically).
3. **Labor pool:** more civilians than `labor_pool` (FISH: 3) hold the labor → the ones with the highest hunger lose it
   (kept in the record; back only via `remote restore`). Soldiers are not counted and never changed.
4. **Escalation:** > 55,000 `!! critical: <id> <name> ... at (x,y,z)`; > 65,000 "only moving the dwarf by hand helps".
   Each level once per dwarf (reset below 40,000); also a digest warning `remote:crit:<id>`.
5. **Fishing yield:** fish count per check (kv `remote_care.fish`); < 1 fish per real hour with fishers → proposal to
   switch FISH off.

**Never:** soldiers or children (Python and Lua refuse); no labor change for dwarves inside a hospital zone (the
return waits until they leave).

## Records
kv `remote_care.taken` = [{unit, labor, kind rescue|pool, reason, ts, work_details}]; every write in table `actions`
(rules `remote_rescue`, `remote_pool`, `remote_return`) with the reason. At most `max_actions_per_run` (20) writes.

## Config (`remote_care:`)
`far_tiles 40, hunger_warn 40000, thirst_warn 40000, hunger_crit 55000, hunger_hopeless 65000, recover_below 15000,
z_penalty 3, long_jobs [Fish, GatherPlants], job_labors {...}, labor_pool {FISH: 3}, repeat_block_s 600,
max_actions_per_run 20, fish_min_per_hour 1, in_check true`.

## Live check (open)
Install the Lua; compare `remote status` with the game (positions, food stockpiles, wells); check that
`cancel` really ends a Fish job (`dfhack.job.removeJob`) and that `labor off` sticks with work details (DF 50+
recomputes labors from work details); then `remote check --dry-run`, then live.
