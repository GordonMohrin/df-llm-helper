# dfpilot

A helper program between Claude (orchestrator/scope agents) and Dwarf Fortress/DFHack. It handles routine work deterministically, delivers compact situation reports, keeps known knowledge ready as runbooks and slows the game down when nobody is supervising. **Usage: `MANUAL.md`.** Mission: `SPEC.md`. Status: `../CHANGELOG.md`. Local hookup: `INTEGRATION.md`.

## Installation

- Python 3.12+ (usually `python` on Windows). The package needs only the standard library; `pytest` (and optionally `coverage`) is only for the tests.
- Configuration: copy `config.yaml.example` to `config.yaml` and check the paths (`dfhack_run`, `paths.tools`, `paths.gamelog`).
- Always run from this folder: `python -m dfpilot <command>`.
- Self-test without DF: `python -m dfpilot.selftest` (with `--cov` for coverage, `--quick` without pytest).

## Commands (examples)

With `--mock fixtures/run5` everything runs against the real sample responses instead of DF. `--replay-file x.jsonl` replays a recording, `--record x.jsonl` records one.

| Command | Purpose | Example output |
|---|---|---|
| `check [--dry-run]` | **Orchestrator check in one call**: heartbeat + guard + autopilot + digest (incl. bus) | like `digest`, plus `Autopilot: …` |
| `digest [--scope trinken] [--full]` | Situation as a delta, ≤ 600 tokens | `!! Hunger>40k: Tekkud414=47k, Eral3473=40k` / second call: `No change since 10:40 (3 open: …)` |
| `cycle [--dry-run]` | one cycle: guard → autopilot → digest | digest plus `Actions: …` |
| `autopilot [--dry-run] [--loop]` | run maintenance rules (`data/rules/*.yaml`) | `food_flag_clear: delete_flag flag:food -> deleted` |
| `autopilot rules / conflicts / enable <id>` | rules with rationale, conflict check, re-enable a rule after loop protection | |
| `guard [--dry-run] [--loop]`, `guard ack-gate 60` | deadman, tempo governor, watcher self-check | `Target fps 30, time-lapse allowed: False (blockers: deadman, …)` |
| `heartbeat` | set the orchestrator heartbeat (at least every 20 min) | `Heartbeat set` |
| `waechter [--loop]` | real-time watcher, replaces `tools/unpause-guard.ps1` (messages, flags, pauses, deadman) | lines as in events.log |
| `tempo on / off` | time-lapse on only without guard blockers | `Time-lapse NOT switched on, blockers: caravan` |
| `wake [--loop --interval 10]` | wake-up filter for the monitor: only decision-ready events, one line per event | `WAKE caravan: Caravan at the depot … -> dfpilot runbook show rb06_karawane` |
| `runbook diagnose` | check symptoms, matches with confidence | `rb16_abbruchschleife (0.80): … Make bed: Needs logs 314x` |
| `runbook list / show <id> / run <id> --dry-run [--param k=v]` | known knowledge as a recipe | exact command list |
| `kb search "Koks refined coal"`, `kb get <id>`, `kb import <md…>` | knowledge on demand (≤ 400 tokens) | `[koks_brennstoff] … Fix: wood furnace …` |
| `brief <scope> [--budget 1500]` | briefing package for a scope agent | mission, KPIs, open items, pitfalls, commands, fair play, report format |
| `replay [file…] [-v]` | play back and check scenarios (`scenarios/*.jsonl`) | `s03_deadman: OK (3 steps)` |
| `record --record x.jsonl [commands…]` | record DF responses (supply fixtures) | |
| `exception list / add FP08 --objects 187405 --reason … --ja "<quote>"` | fair-play exception register | |
| `bus post "<text>" --from bau --to orchestrator [--prio crit] [--key k] [--md]`, `bus read/ack --to <scope>`, `bus import` | event bus instead of inbox Markdown (dedupe, priorities) | `!! #3 gesundheit (x2): …` |
| `memory compact <scope\|all> [--dry-run]`, `memory restore <scope>` | condense memory, original kept in the archive | `militaer.md: 16738 -> 5687 bytes` |
| `lint <paths…>` | fair-play linter for Lua (30 rules, exceptions via the register) | `mil.lua:297: L08 …` |
| `budget`, `metrics [--out file.csv]` | token consumption per scope (daily budget), KPI time series in the format of metrics.csv | |
| `trade step [--dry-run] / status / approve / reset` | caravan as a state machine (pause … finish) | `State now: REVIEW` |
| `overlay [--send]` | ≤ 3 lines for the player in the game (`claude/schau say`), without repetition | |
| `plan trade|dig|armor|supply|blueprint …` | planners as pure functions (see `PLANNERS.md`) | |

## Structure

`dfpilot/`: `client` (Real/Mock/Replay/Recording), `snapshot` (tolerant parser), `digest`, `rules` (autopilot), `guard`, `runbooks`, `kb`, `brief`, `memory`, `wake`, `bus`, `lint`, `transport` (batching/compression), `metrics`, `anomaly`, `trade_flow`, `overlay`, `planners/`, `scenario`, `pilot` (cycle), `fairplay`, `expr` (safe expressions), `yamlmini`, `store` (SQLite), `toolsfs`, `clock`, `cli`, `selftest`.
`data/`: `rules/`, `runbooks/`, `kb/` (curated + imported), `scopes.yaml`, `exceptions.jsonl`.
`lua/`: thin, **live-untested** DFHack scripts (`pilot_wd.lua`, `pilot_batch.lua`). Short start prompt for agents: `AGENT-PROMPT.md`. Known lint findings: `LINT-BEFUNDE.md`. `tools/luacheck_min.py`: Lua structure check.
`tests/`: pytest suite, `make_fixtures.py` (synthetic fixtures + scenario generator), `kb_queries.yaml`, `lua_mock/`.

## Safety principles

- Fair play is enforced technically. Every client checks every command (`fairplay.py`). Exceptions exist only with a register entry that contains the player's quote.
- Dry run executes no writing DF command; this is secured by a test.
- Every rule has a cooldown and a maximum rate. If it repeats the same action too often per hour, it switches itself off and raises a digest warning.
- The guard never makes the game faster. The only exception: after a deadman it restores the normal fps. Switching on time-lapse remains a decision of the player or the orchestrator.
- Game decisions (rule class `game`) appear only as a suggestion in the digest.
