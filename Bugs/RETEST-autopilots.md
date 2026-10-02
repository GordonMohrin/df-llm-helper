# Retest 2026-10-02 (commit 8e67f05): autopilots BUG-200 .. BUG-220

Method: evidence replays (`--replay-file`), `--mock`, fixtures and isolated temp configs (own state.db/tools folder); live game only with read-only commands (`water check`, `digcheck`, `reach`, `hygiene --dry-run`, `defense stats`, `mood reserve --dry-run`, `bottleneck --dry-run`, `perf sample`) against a temp state. `pytest tests/test_bugs_autopilots.py tests/test_bugs_decided.py` and `-k "bug2 or mood ..."`: all green (3 Lua tests skipped, no `lua` on this machine). The live `data/state.db` main file is byte-identical (md5 before/after), no `data/` change in `git status`; only the live process itself grows the WAL. Live-only items were not touched (no trade/caravan/siege/water watch/pause/advance).

| Bug | Verdict | Note |
|---|---|---|
| 200 | verified fixed | caravan call 2: one `advance run`, call 3: no command, one `Trade completed`, foreign `pause.hold` survives |
| 201 | verified fixed | `trade approve` reaches the REVIEW caravan, refused (rc 2) outside REVIEW, no pile-up, `trade status` shows the caravan line, `trade step` REVIEW names the next command |
| 202 | verified fixed | DONE -> IDLE when the caravan is gone, `approved` cleared, hint `run trade reset` while the caravan is still at the depot |
| 203 | verified fixed | siege/mood/caravan `--dry-run`: 0 warnings, no flags in the (temp) state |
| 204 | verified fixed | `--grid` runs of reach/digcheck/perimeter leave state.db empty (no warnings/kv/actions) |
| 205 | verified fixed | replay and live: `unsafe: ... outside the map (192x192x153)`, rc 1 |
| 206 | verified fixed | front inside fort box: "wall breached/not tight? check them", no `rb21_flut` proposal |
| 207 | verified fixed | 0 targets -> `refused - nothing to check` rc 2; R1 judged before "unrevealed"; negative coords = outside the map (live + replay) |
| 208 | verified fixed | missing points file rc 2; out-of-map point = config error |
| 209 | verified fixed | live `reach`: 7/7; old points file: "point on a wall tile: fix the points file", level warn |
| 210 | fixed, live check pending | Python side verified by replay + live (`!! area classification failed ...`, ghost line uses `leichen_offen`). Lua part (`FORT_REFS` reachability) not testable here (no lua) and the live copy of `pilot_hygiene.lua` differs from the repo (not deployed) |
| 211 | **reopened** | tail/perf/validation fixed (1.7 s, `--tail` >= 1, reload problems separate), but `siege`/`thief` still match combat lines: 273 of 283 "invasion announcements" are false (see Retest section in the report) |
| 212 | verified fixed | `--name` and `--lane-len` validated (rc 2), huge lane fails in 0.4 s, nothing written outside `--out` |
| 213 | verified fixed | default file + one-line errors, `--horizon` >= 1, header check; live series copy -> `Food ?, Drink ?` |
| 214 | verified fixed | all 17 listed calls: one-line errors, rc 2, no traceback (`water lint-cmd` without command = usage error) |
| 215 | verified fixed | care lines name the cause/action and cut no quotes; live `remote check`: `Remote ok (0 labors held back)` + labelled fish counter |
| 216 | verified fixed | `Restart (dry run): would start 10 services ... - nothing started`; plan lines listed consistently with and without `-v` |
| 217 | fixed, live check pending | `perimeter allow` (range check, tolerance warning, notes in the list) verified; seal note for stair entry only via pytest (the recorded scan replay no longer matches the `start` command, which gained a `min_outside` argument; a live `perimeter scan` was not run); Gordon's trap-bypass question stays live |
| 218 | verified fixed | warning for STRICT < POPULATION, last revert says `byte-identical`, file identical to the fixture afterwards |
| 219 | verified fixed | unreadable status = `ERROR` rc 2 for all four variants, no warning, no `notify.flag`; replay of live "no attackers" ok; real-attack check stays (INTEGRATION v2-01) |
| 220 | fixed, live check pending | live: `mood reserve` uses claude/mood minima (`rough gems 4/12`), `bottleneck` no longer says "no stock data", workload lists stopped services (replay), zones/perf-paused covered by tests (game is running now, 104 ticks/s). Repo Lua (`material status` stock, `mood.lua` MIN) untested (no lua) and needs deploy |

Counts: 17 verified fixed, 3 fixed with live check pending (210, 217, 220), 1 reopened (211).
