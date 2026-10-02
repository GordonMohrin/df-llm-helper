# RESULTS: autopilots (v2 + v3) - test run 2026-10-02, commit `6dedd96`

Environment: Windows 11 Pro, Python 3.14.3, DF 53.16 + DFHack, game **paused** the whole time (fort "Windrings", 27. Granite, Jahr 118), `config.yaml` of the player. Bug numbers BUG-200..220 (this area).
Columns: Mock = `--mock fixtures/run5`, `--replay-file` (my replays from `fixtures/run5_live`, `fixtures/v3`, live recordings) or `--grid`/`--file`/`--terrain` fixtures. Live = against the running game (read commands, or `--dry-run`; where a command writes helper state I used a temp config with its own `state.db`/tools folder). Edge = missing/wrong arguments, coordinates outside the map, special characters, paths with spaces. "skipped" = not allowed by the test rules or only meaningful with time running.

| Command | Mock | Live | Edge cases | Result |
|---|---|---|---|---|
| `siege` / `--once` / `--dry-run` / `-v` | ok (replay: full 4-step siege incl. alert, kill order, cleanup); no fixture -> ABORT | `--dry-run -v`: ok ("no attackers on the map", 0.5 s, squads match `claude/mil`); real/`--once`: skipped (writes) | extra arg -> argparse error | BUG-203, BUG-219 |
| `caravan status` / `step` / `--loop` / `--dry-run` / `reset` | ok with replay of real handel answers (trade to DONE, low-ratio hold) | status/dry/loop dry: ok (`IDLE`, no caravan on the map) | bogus action, `--max-steps 0/-1`, `--interval x` | BUG-200, BUG-201, BUG-203 |
| `trade status` / `step --dry-run` | ok (replay) | ok (shows DONE, approved True) | bogus action | BUG-201, BUG-202 |
| `trade approve` / `trade reset` | ok in mock only | skipped (writes live store) | approve in IDLE accepted | BUG-201, BUG-202 |
| `mood` / `mood check --dry-run` | ok (replay with 2 moods: CutGems release, wood boost, unknown flag) | ok (`no running mood`) | bogus action | BUG-203 (dry-run) |
| `mood reserve` | ok | ok (`reserve ok`, but `claude/mood` lists rohgem 6/12) | `--dry-run` ignored | BUG-203, BUG-220 |
| `care` / `care --dry-run` | ok (replay of the live answer) | ok, data matches `claude/report`/hospital | extra arg | BUG-215 |
| `forecast` / `forecast --dry-run` | ok (1 point) | ok (`Food 267±6409 days`, confidence 0.3) | - | BUG-213 |
| `forecast backtest` | ok with `fixtures/run5_live/metrics_run5.csv` | default file missing -> traceback | `--horizon x/0/-3/9999`, garbage/missing file | BUG-213, BUG-214 |
| `workload` / `--dry-run` | ok (replay of live answers: executed / blocked / dry) | `--dry-run`: ok, numbers match `claude/status` | - | BUG-220 (info) |
| `bottleneck` / `--dry-run` | no fixture (`material status` not readable) | ok (no bottleneck; coal 697, coke 12, wood 177) | bogus action | BUG-220 (info) |
| `bottleneck validate` | ok (17 nodes, 4 goals) | same | - | ok |
| `water scan` / `water watch` | no fixture; replay with rising water | ok (fort 0 tiles, watch box 188, 0.6 s) | `watch --dry-run` | BUG-206 |
| `water check x y z` | no fixture | ok for the well (140,99,129: forbidden), (184,43,128: forbidden diagonal), (100,100,130: unsafe hidden) | out-of-map, missing/non-numeric args | BUG-205, BUG-214 |
| `water lint-cmd` | ok (L31 refuses dig in the water box) | n/a (pure check) | no command -> `ok`; createitem -> `ok` | BUG-214 |
| `reboot --dry-run` / `-v` | 20 s wait (no map fixture) | ok plan: 10 services missing (matches `brief infra`) | bogus action | BUG-216 |
| `reboot validate` | ok | ok | - | ok |
| `reboot load --dry-run` | rc 1 (off) | rc 1 (off, by design) | - | ok |
| `reboot run` (real) | n/a | skipped (writes) | - | not tested |
| `perimeter` / `scan` | ok (open/sealed grid, WAKE lines) | ok, 5-7 s while paused; matches `claude/zugaenge` (only the trap stair leads to the core) | nonexistent grid, path with spaces/umlaut | BUG-204, BUG-214, BUG-217 |
| `perimeter status` | ok | ok (temp state) | - | BUG-204 |
| `perimeter seal` (dry only) | ok (24 walls, CSV valid shape) | "nothing to do" for the stair access | `seal --apply`: deliberately never run | BUG-217 |
| `perimeter allow` (temp allow file only) | ok | ok (changes the verdict) | missing/non-numeric/out-of-map, special characters | BUG-217, BUG-214 |
| `digcheck rect` | ok (R2, R3, R4, R6 fixtures reproduce the doc example) | ok vs `claude/area` (z116 hall already dug, well water, z131 opening) | out-of-map, z103/141/150, reversed rect, > 3000 cells, mode arg | BUG-207, BUG-214 |
| `digcheck --csv` / `--stages` / `--gamelog` / `--strip` | ok | ok (stage N11_Wohn1 395 tiles R6) | unknown stage, empty CSV, `#build` CSV, missing files | BUG-207, BUG-214 |
| `dig check` (alias) | ok (river-diagonal grid) | not separately run | - | ok (same code) |
| `reach` / `points` / `correlate` | ok (built/removed grid, correlation with cancel gamelog) | ok, 0.5 s; Brunnen counter-test passed (well and neighbour reachable); Kitchens false alarm | missing points file, out-of-map point, broken YAML | BUG-208, BUG-209 |
| `reach what-if` | ok | ok (stair T1 cuts F1+Stills; core wall cuts 6) | no `--wall`, 2 values, letters, 9999 | BUG-214 (arg errors) |
| `perf status` / `sample` | ok | ok (0 outliers; 27.5 s for the default 40 probes) | - | BUG-220 (info) |
| `perf bisect --dry-run` | ok (no services) | ok (4 services, 2 testable) | - | ok |
| `perf bisect` (real) | n/a | skipped (switches services off) | - | not tested |
| `tools status` / `check --dry-run` / `after-load --dry-run` | ok (3 fixtures incl. FP08 refusal) | ok, matches `claude/pickfix` (38 picks, 30 in use, 10 free) | - | ok |
| `remote status` / `check --dry-run` / `restore --dry-run` | ok (river, 15-fish fixtures) | ok | - | BUG-215 |
| `hygiene` / `status --dry-run` | ok (no-zone / far-zone fixtures) | ok, 0.4-1.3 s for 32,814 items | bogus action | BUG-210, BUG-220 |
| `hygiene zones` / `hygiene mark` (dry) | ok | ok (`would mark 0 items`) | - | BUG-210, BUG-220 |
| `hygiene mark --apply` | n/a | skipped (writes) | - | not tested |
| `defense design` | ok (doc example reproduces: 20-tile lane, 53 Cw + 3 CF) | n/a (offline) | `--name` with space/`../`, `--lane-len 0/9999`, missing terrain, `--apply` without `--confirm` (refused, rc 2) | BUG-212, BUG-214 |
| `defense status` | ok (fixtures) | ok (58/58 stone traps, 81 traps = `claude/buildings`) | missing file | BUG-214 |
| `defense stats` | ok (fixture log) | 10.7 s, meaningless counts | `--tail 0/-5/500` | BUG-211 |
| `defense design --apply --confirm` | never run (rules) | never run | - | not tested |
| `settings get` | ok | ok on the real `prefs/d_init.txt` (75/100/266:1000/300) | unknown key | ok |
| `settings set` / `pending` / `verify` / `revert` / `restart-plan` | ok on a temp copy (CRLF + Latin-1 byte preserved, backups, byte-identical after reverts) | `get`/`pending` only; `set` skipped | invalid values, `[75]`, empty/special-char reason, missing args | BUG-218 |
| `camera` / `stats` / `profile` (list) | ok (default + menu fixtures) | ok (mode off, gate pause.hold) | unknown profile refused | ok |
| `camera profile <name>` | ok (mock only) | skipped (writes) | menu open -> no action | ok |
| `camera watch` | ok once (mock); `--loop` not run | skipped | - | not tested live |

Not testable with the game paused (needs time running): live siege with attackers, caravan arrival/trade at the depot, mood `need` for a real mood, `perf sample/bisect` with real freezes (raster/kohle), wasser.flag path with really rising water, hygiene dump jobs being hauled, `defense` gamelog patterns with a real attack, `camera watch` during an attack, the standstill guard (`waechter`).
