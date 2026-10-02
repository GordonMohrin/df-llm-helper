# INTEGRATION – connecting dfpilot locally to the running game (checklist for Claude)

The cloud session had **no DF/DFHack**. Everything below is tested against mocks, replays and fixtures, but **live-untested**. Run each step individually and compare with the expected response. On deviations, record the real response with `--record` and put it under `fixtures/`; the parser is tolerant and does not crash.

Working folder: `cd "<path>/dfpilot"` (Git Bash, Python is called `python`).

## 0. Preparation
- [ ] `python --version` reports 3.12 or newer. Then `python -m dfpilot.selftest --quick`, expected: all `[ok]`, `Self-test GREEN`.
- [ ] `cp config.yaml.example config.yaml` and check the paths: `dfhack_run`, `paths.tools`, `paths.scopes`, `paths.gamelog`.
- [ ] Install the Lua scripts (live-untested): `cp lua/pilot_wd.lua "<DF install folder>/hack/scripts/claude/"`. Alternatively copy into `../lua/claude/` if that folder is linked.

## 1. RealClient – read commands (no effect in the game)
| Step | Command | Expected |
|---|---|---|
| [ ] 1.1 | `python -m dfpilot --record recordings/live1.jsonl record claude/status claude/report` | two `ok` lines. The responses resemble `fixtures/run5/status.txt` and `report.txt` (JSON) |
| [ ] 1.2 | `python -m dfpilot --record recordings/live2.jsonl record` | all collective commands `ok`, among them `lua "local r=df.global.world.status.reports …"` (a number) and the repeat-util query (`claude-watchdog=true …`) |
| [ ] 1.3 | `python -m dfpilot digest` | `Status Y… | Pop … | Drinks …d Food …d` ≤ 600 tokens, no `Query failed` |
| [ ] 1.4 | `python -m dfpilot digest` (immediately again) | `No change since HH:MM (…)` |
| [ ] 1.5 | `python -m dfpilot runbook diagnose` | matches with confidence, or `no runbook hits` |
| [ ] 1.6 | `python -m dfpilot brief infra` | briefing with KPIs and `gestoppte Dienste []` (stopped services) when all jobs are running |

The recordings from 1.1/1.2 replace the synthetic responses (fixture gaps in `CHANGELOG.md`). Please put them under `fixtures/run5_live/` and commit.

## 1b. Watcher replaces unpause-guard.ps1 (player decision, 2026-10-01)
- [ ] Only in peacetime: `python -m dfpilot waechter` (one pass). Expected: no error message, `tools/out/waechter.alive` exists, new messages appear in `tools/events.log`.
- [ ] Stop the PowerShell watcher and `wake.ps1` and start the permanent process (see `MANUAL.md` section 1). Then verify: a test message such as a migrant arrival appears in `events.log`. A manually set `pause.hold` prevents resuming; without `pause.hold` the watcher resumes a DF-native pause.
- [ ] Difference from the ps1: After it ends, the deadman restores the last seen NORMAL_FPS from `claude/config`, not a fixed 250.

## 2. Guard and heartbeat
- [ ] `python -m dfpilot heartbeat`, expected `Heartbeat set`. The orchestrator calls this on **every** check, at the latest every 20 min.
- [ ] `python -m dfpilot guard --dry-run` reports `Target fps <NORMAL_FPS>, time lapse allowed: …`. Verify that no warning `Watcher is not running` appears while the PowerShell watcher is running. The process check (`Get-CimInstance Win32_Process`) is live-untested.
- [ ] Deadman test in peacetime: make `heartbeat.txt` 25 min old (`touch -d '-25 min' ../tools/heartbeat.txt`), then `python -m dfpilot guard`. Expected: `set_fps=30` and a line `KRITISCH … [DFPILOT-GUARD] DEADMAN` in `tools/events.log`, 30 fps in the game. Then `python -m dfpilot heartbeat && python -m dfpilot guard`, expected `set_fps=<normal>`.
- [ ] Deadman is dfpilot only (player decision, 2026-10-01): do not run the PowerShell watcher in parallel (1b).

## 3. Autopilot
- [ ] `python -m dfpilot autopilot conflicts` reports only `erklaert (mutex_with)` (explained) lines.
- [ ] `python -m dfpilot autopilot --dry-run` lists `[dry] …` lines without effect.
- [ ] Switch `python -m dfpilot autopilot` live as soon as 3.2 looks plausible. Verify the effect: flags deleted and services started according to `python -m dfpilot autopilot rules`.
- [ ] Continuous operation: `python -m dfpilot check` every 5 min (heartbeat + guard + autopilot + digest), instead of reading `claude/status`, `claude/report` and the inbox yourself.

## 4. Wake-up filter instead of a monitor script
- [ ] Replace the monitor command with `python -m dfpilot wake --loop --interval 10`. Every output line is a wake call. Legacy flags at startup are not reported.
- [ ] Test: `echo test > ../tools/mood.flag` produces exactly one line `WAKE mood: test -> …`. A second line comes only after changed content or after deleting and recreating the file.

## 5. Verify runbooks live (individually, in peacetime)
- [ ] `python -m dfpilot runbook run rb10_timestream --dry-run`, then live if timestream is on and a blocker exists.
- [ ] `python -m dfpilot runbook run rb02_grabstau --dry-run`. Test `claude/pilot_wd mode Stonecutters OnlySelectedDoesThis` in the game first without `--apply`, expected `{"before": …, "dry": true}`.
- [ ] `rb01_e18_pick` only with `--param squad_id=<ID from claude/mil status>`. Never run `workmode` repeatedly.
- [ ] `rb06_karawane` up to the dry-run selection. The manual check step stops the run, that is intended.

## 6. Briefings, bus and memory for scope agents
- [ ] Switch the start prompt to `AGENT-PROMPT.md`: briefing instead of 5–9 mandatory files.
- [ ] `python -m dfpilot bus import` takes over all existing `inbox-*.md` once (idempotent). After that the agents post via `bus post`. `--md` additionally writes to the old Markdown inbox.
- [ ] `python -m dfpilot memory compact <scope> --dry-run`, then run it live. The original is stored byte-identical in `tools/scopes/archive/`, `memory restore <scope>` undoes it.

## 7. Batching (F10) – switch on only after a single test
- [ ] `cp lua/pilot_batch.lua ".../hack/scripts/claude/"`.
- [ ] Single test: create the file `../tools/out/pilot_batch_request.json` with `{"cmds": [["claude/status"], ["claude/mil", "tabelle"]], "max_bytes": 20000}`, then `dfhack-run claude/pilot_batch "<absolute path>"`. Expected is a JSON line `[{"ok":true,"out":"{…"},{"ok":true,"out":"Trupp | Id …"}]`.
- [ ] Check whether `dfhack.run_command_silent` also returns the `print()` output of the claude/* scripts (live-untested). If not, `transport.batch: false` stays.
- [ ] `config.yaml`: `transport: {batch: true}`. Then leave `python -m dfpilot digest` as is and compare with `--record`: one snapshot then corresponds to one dfhack-run process instead of twelve.

## 8. Trade (F15) and display (F16)
- [ ] With a caravan at the depot: `python -m dfpilot trade step --dry-run` shows the next commands. Then proceed step by step without `--dry-run`, `trade status` shows the state. After `select --dry` check and then `trade approve`.
- [ ] `--stable-s` is the focus stability in seconds; the caller measures it, live-untested. Without a measurement the default 2 applies, then wait for one `claude/handel status`.
- [ ] `python -m dfpilot overlay` shows the text, `--send` writes it into the game via `claude/schau say`.

## Live acceptance by Claude (open)
- `RealClient` against real DF (1.1–1.6), `ProcessProbe` on Windows (2.2), `pilot_wd.lua` (5.2), repeat-util query (1.2), `pilot_batch.lua` (7), trade automaton against a real caravan (8): all **live-untested**.
- Response formats without a real fixture are listed in `CHANGELOG.md` under "Open fixture gaps". Please supply `--record` recordings; the parsers are tolerant.

## v2-01 Siege (spec 01) – verify live
- [ ] `cp lua/pilot_siege.lua ".../hack/scripts/claude/"`; in peacetime `dfhack-run claude/pilot_siege status` → JSON with `invaders: []`, `squads` incl. guard (blood 100).
- [ ] `config.yaml`: `siege: {rally: [x, y, z]}` = a reachable point in the barracks.
- [ ] On the next attack first `python -m dfpilot siege --once -v` (one step), check the squad orders in the game; then `python -m dfpilot siege`.
- [ ] Afterwards: `claude/pilot_siege status` → guard `orders: 0`; no `alert/siege.flag`, no `pause.hold`.

## v2-02 Caravan (spec 02) – verify live
- [ ] `cp lua/pilot_caravan.lua ".../hack/scripts/claude/"`; with a stuck caravan first `dfhack-run claude/pilot_caravan release` (without `--apply`) → `candidates` = merchant IDs only.
- [x] Register entry FP09 (the player's standing permission, 2026-10-01) is in `data/exceptions.jsonl`; `python -m dfpilot exception list` shows it.
- [ ] Next caravan: `python -m dfpilot caravan --dry-run`, then `python -m dfpilot caravan --loop`; verify that `claude/handel list 0` in the open window returns the offer and the decision is right.
- [ ] `claude/handel` finds the trade-window buttons by text search (`scan`), not via fixed coordinates – on failure `claude/handel scan Trade`.

## v2-03 Moods (spec 03) – verify live
- [ ] `cp lua/pilot_mood.lua ".../hack/scripts/claude/"`; on the next mood `dfhack-run claude/pilot_mood need <id>` → `elements` with `item_type`, `quantity`, `flags1..3`, `free/bound/nearest`. Record the response with `--record` (fixture gap).
- [ ] NONE elements: note the set flags; add unknown flags to `moods.FLAG_HINTS`.
- [ ] `dfhack-run claude/pilot_mood release-cutgems` (without `--apply`) → `found` = number of CutGems jobs; only then `python -m dfpilot mood`.
- [ ] Compare `python -m dfpilot mood reserve` against the real stock (`claude/mood status`).

## v2-04 Care (spec 04) – verify live
- [ ] `cp lua/pilot_care.lua ".../hack/scripts/claude/"`; `dfhack-run claude/pilot_care status` → `citizens` with `hunger/thirst/wounds/cant_stand/hospital/squad/pick/labors`, `hospitals`, `care_jobs`, `meals`. Record with `--record` (fixture gap). Check: `u.status2.limbs_stand_count` and `z.location_id` exist in 53.16 (otherwise defaults).
- [ ] `python -m dfpilot care --dry-run`; compare the candidate list with the labor menu, then run without `--dry-run`.

## v2-05 Forecast (spec 05) – verify live
- [ ] After several `check` cycles: `python -m dfpilot forecast` → points > 5, line plausible against `claude/essen status`.
- [ ] After a game month: run `forecast backtest --file ../metrics.csv` again, note the error (Run 5: food 0.33, drinks 0.20).

## v2-06 Workload (spec 06) – verify live
- [ ] `python -m dfpilot workload --dry-run` with a high idle rate; compare the cause with your own judgement.
- [ ] Verify that `claude/pickfix` without `--apply` changes nothing (dry run) and returns `picks`/`work_weapons`.
- [ ] After an automatic measure wait 5 min, run `workload` again → `ok done` / `no effect`.

## v2-07 Bottleneck (spec 07) – verify live
- [ ] Record `dfhack-run claude/material status` (`--record`); check the keys `stock.wood/coke/coal/ore/bars/have` against the graph (ore IDs like `HEMATITE`). `chain/bucket/mechanism/blocks` are not provided by material.lua → they stay "without stock data" until a counter exists.
- [ ] Compare `python -m dfpilot bottleneck` with your own diagnosis; before the next caravan `caravan status` → the bottleneck good is at the front.

## v2-08 Water (spec 08) – verify live
- [ ] `cp lua/pilot_water.lua ".../hack/scripts/claude/"`; `python -m dfpilot water scan` → fort_box water 0 (baseline), watch_box > 0 (river/tunnel W). Measure the scan runtime (box 130×90×6).
- [ ] `python -m dfpilot water check 184 43 128` → `forbidden` (diagonal). Verify that `df.tile_liquid.Magma` and `flow_size` are named that way in 53.16.
- [ ] Test `quickfort run claude/r5_notwand.csv -c <x>,<y>,<z>` at a harmless spot (a build order appears), then remove it.

## v2-09 Restart (spec 09) – verify live
- [ ] After the next load: `python -m dfpilot reboot -v` → all services `true` according to repeat-util; verify that `claude/mil guard start`, `claude/schau start`, `claude/kohle start`, `claude/raster start` are named that way.
- [x] Services via `tempo.schedule` (watchdog, ueberwacher, migranten, milguard) are visible live via `isScheduled('claude-…')` (2026-10-01).
- [ ] After the restart POPULATION_CAP 75 / STRICT 100 from `d_init.txt` (player, 2026-10-01) apply at pop 161: no more migrants, no error.
- [ ] `reboot load` only after the player's yes (`reboot.auto_load: true`), window size 150×66, texts in `reboot.load_texts`.

## v2-10 Subagents (spec 10) – verify live
- [ ] Set `agents.transcript_dir` in `config.yaml` to the project folder of the orchestrator session (Windows: `<user profile>/.claude/projects/<project>`); `python -m dfpilot agents cost` → check the sums against your own measuring script.
- [ ] Next 3 agent starts only with `agents prompt`; then `agents cost --compare` (acceptance 4: mean output ≥ 30 % smaller).

## v2-11 Dashboard (spec 11) – verify live
- [ ] After several `check` runs open `tools/out/dashboard.html` in the browser; compare the values against `dfpilot digest --full`.
- [ ] `python -m dfpilot dashboard` (with building counters), check zone names in `claude/buildings` (`Zone:Hospital`, `Zone:Temple`, …) against the build plan, otherwise adjust `dashboard.buildplan`.

## v2-12 Journal (spec 12) – verify live
- [ ] `python -m dfpilot journal ingest` with the current `tools/events.log`; check the start date (`--date`, otherwise the file's modification date).
- [ ] Read `journal chronik` against your own recollection; only then `--append`.
- [ ] Adjust `journal.postmortem` in `config.yaml` per run (`../POSTMORTEM-run5.md`).

## v3 – live checks (all features are fixture-tested only)
- [ ] Copy new Lua: `pilot_perimeter`, `pilot_digcheck`, `pilot_reach`, `pilot_tools`, `pilot_remote`, `pilot_hygiene`, `pilot_defense`, updated `lua/claude/*` (schau profile hook, orders fix).
- [ ] `reach check`: set real points in `data/reach.yaml`; verify `canWalkBetween`/`findAtTile` under DF 53.16; ≤ 1 s for 20 points.
- [ ] `perimeter scan`: full-map scan ≤ 15 s, chunked (does `dfhack.timeout` run while paused?); compare with `claude/zugaenge`; test that a generated seal CSV builds.
- [ ] `digcheck` on a real stage before designating; R5 uses configured cavern boxes (lint L28 forbids cavern data).
- [ ] `perf sample` with raster on/off to tune the 1.5 s outlier threshold; does reading `repeat-util` `scheduled` work?
- [ ] Standstill guard: does LEAVESCREEN close Info/Justice, does SELECT close the DFHack MessageBox, is `cur_year_tick` right; trade aftercare after a real trade.
- [ ] `tools`: add FP08 with the player's consent before the first automatic pick fix; check `work_weapons` after the fix.
- [ ] `remote`: does `dfhack.job.removeJob` end a Fish job; does `labor off` stick with DF 50+ work details.
- [ ] `hygiene`: field names `corpse_flags`, `civzone_type.Dump`, `flags.rotten`; block time for 20,000 items; do marked wild corpses get DumpItem jobs.
- [ ] `defense status`: how DF 53 shows a loaded stone-fall trap, job name of the reload job; does quickfort accept `CF`/`r`/`a`.
- [ ] `settings`: location of `d_init.txt` in DF 53 (`settings.file`).
- [ ] `camera`: does DFHack `json.decode` read the weight file; idle sparring soldiers have no `current_job`.

