# BUG-220: plausibility findings against the live game: `mood reserve` says ok while `claude/mood` lists a gap; `workload` ignores stopped services when many jobs are open; `bottleneck` says "no stock data" for items that exist; `hygiene zones` proposes a dump zone next to an existing one; `perf sample` on a paused game is meaningless

- **Status:** fixed, live check pending (see TESTPLAN-live)
- **Severity:** S3
- **Area:** `df_llm_helper/config.py` (`mood.reserves`) vs `lua/claude/mood.lua` (`minimum`); `df_llm_helper/workload.py` `diagnose` (`if not many_open:` around the service checks); `data/graphs/produktion.yaml`; `df_llm_helper/features/hygiene.py` (`suggest_zone`); `df_llm_helper/features/perf.py` `sample`
- **Reported:** 2026-10-02, commit `6dedd96`
- **Environment:** Windows 11 Pro, Python 3.14.3, game running (DF 53.16 + DFHack, paused), fort date 27. Granite, Jahr 118; live reads, `--dry-run` where available

## Command / steps and findings
```
cd "<project folder>"
python -m df_llm_helper mood reserve --dry-run
python -m df_llm_helper workload --dry-run
python -m df_llm_helper bottleneck --dry-run
python -m df_llm_helper --config <temp cfg> hygiene zones
python -m df_llm_helper --config <temp cfg> perf sample
```
1. **mood reserve vs claude/mood.** Helper: `Mood reserve ok` (config reserves: rough_gems 4, cut_gems 3, wood 10, bone 5, leather 3, metal 3). Game script `claude/mood status`: `"luecken": ["rohgem 6/12"]`, `minimum` rohgem 12, schliffgem 10, holz 14 (stock: rohgem 6, schliffgem 23, holz 177). Two thresholds for the same thing: which one is binding? (`l_mood_res.jsonl`)
2. **workload.** Output: `Idle 57 % (68 idle, 101 jobs open, dig queue 0)`, proposals: raster start, 17 blocked jobs. Not mentioned: `claude-arbeit`, `-orders`, `-auslastung`, `-trinken`, `-essen` are **not running** (`reboot --dry-run`, `brief infra`). `diagnose` checks stopped services only `if not many_open` (open jobs 101 >= max(50, idle 68)), so with a job backlog and 57 % idle the obvious cause is skipped. Also the line `17 jobs blocked -> check suspendmanager, clarify building material/access (proposal)` names no command.
3. **bottleneck.** `No bottleneck in the production chains` / `no stock data: block, mechanism`. Both exist in the game (`claude/muell status` BLOCKS=482 loose, `defense status` stock mechanisms 65). Coal 697, coke 12, wood 177, iron 32 (`claude/material status`): "no bottleneck" is plausible.
4. **hygiene zones.** Live: `dump zone #3743 z130 x90..92,y112..114` exists; proposal: `zone D z130 x86..88,y112..114 (near refuse room/crypt/barracks)` = the same rows, 2 tiles west: an adjacent duplicate. The diagnosis `zone too far (nearest zone 55 tiles from the marked items)` is a consequence of BUG-210 (items classified wrongly).
5. **perf sample** (live, 27.5 s for 40 probes, the helper cannot shorten it): on a paused game it only measures the `dfhack-run` round trip (max 0.1 s) and says `0 outliers`; `tick_rate`/`period_ticks` are `None`. The line should say that the game is paused (then outliers cannot be seen). `perf bisect --dry-run` listed `4 services, testable 2: claude-milguard claude-watchdog` (correct: only 4 repeat-util keys are scheduled).

## Expected / Actual
See each item. No crash; no wrong game action.

## Evidence
`Bugs/evidence/BUG-220/` (`l_mood_res.jsonl` raw `claude/mood status` + `claude/status`, `l_wl.jsonl` raw workload inputs, outputs).

## Info needed
Gordon: (1) which reserve values are authoritative (`config.py` or `mood.lua`)? (2) are the five services off on purpose? (3) should `hygiene zones` ignore proposals within ~5 tiles of an existing dump zone? The cloud session can adopt whatever you decide.

Decided (player delegated the decision): (1) `claude/mood` (`minimum`) is authoritative, `config mood.reserves` is the fallback, config defaults follow mood.lua; (2) the services were not off on purpose, the restart proposal stays; (3) `block` and `mechanism` get a stock source; (4) the 5-tile zone gap stays.

## Fix
- Item 2: `workload` reports stopped `orders`/`arbeit` services also with a job backlog (restart proposal, auto + loop guard as before); the blocked-jobs line names `suspendmanager`/`unsuspend`.
- Item 4: `hygiene` proposes no dump zone within `hygiene.zone_min_gap` (5 tiles) of an existing one (default chosen; Gordon may change it).
- Item 5: `perf sample` says `game PAUSED (frame counter did not move)` when the frame counter is constant.
- Tests: `tests/test_bugs_autopilots.py::test_bug220_*`.
- Items 1 and 3 and the item 2 question: decided, see below.
- Item 1 (50b7560): `mood reserve` checks against the `minimum` of `claude/mood status` when the answer has one (per category, the config fills categories the script does not list) and says which minima it used (`Mood reserve missing: rough gems 6/12 (minima: claude/mood minimum)` on the evidence = the game's own gap). Config defaults: rough gems 12, cut gems 10, wood 14 (live mood.lua), bone 5, leather 3, metal 3, cloth 3, stone 5, silk 2 (repo mood.lua). Note: the repo copy of `lua/claude/mood.lua` still has `MIN` rohgem 3 / schliffgem 2 / holz 10 / seide 2, the live game reports 12 / 10 / 14 / 3 (Lua side to sync).
- Item 3 (50b7560): `data/graphs/produktion.yaml` gets `sources`: `mechanism` <- `claude/pilot_defense status` `stock.mechanisms`, `blocks` <- `claude/muell status` `typen` `BLOCKS=N` (loose blocks outside stockpiles: a lower bound; absent = unknown, never 0). Only used when `claude/material status` `stock` lacks the key, so `stock.mechanism` / `stock.blocks` reported by `claude/material status` win (Lua field wanted there; `claude/muell status` is a full item scan).
- Tests: `tests/test_bugs_decided.py::test_bug220_*`, `tests/test_moods.py`.

Lua side (merge commit of the decisions): `claude/material status` now reports `stock.mechanism` (free, reachable TRAPPARTS) and `stock.blocks` (free, reachable BLOCKS incl. stockpiles), so the graph's fallback sources are only needed with an old live copy; `claude/mood` `MIN` synced with the live game (rohgem 12, schliffgem 10, holz 14, seide 3). Tests: `tests/test_lua_claude.py::test_material_stock_counts_mechanisms_and_blocks`, `test_mood_minimum_matches_the_live_game`.
