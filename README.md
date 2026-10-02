# df-llm-helper

A deterministic co-pilot for LLM agents that play **Dwarf Fortress** through **DFHack**.

An LLM orchestrator (e.g. Claude) is good at judgement and bad at watching a game every few seconds. df-llm-helper takes
the routine off its hands: it collects the game state in one call, turns it into a short delta report, runs
maintenance rules, keeps known fixes as runbooks, guards against unsupervised time-lapse, and enforces
**fair play** (no cheating commands) technically.

Package `df_llm_helper` (formerly *dfpilot*); every command is `python -m df_llm_helper <command>`, run from the
project folder. Shared runtime folder: environment variable `DF_LLM_HELPER_HOME` (old name `DFPILOT_HOME` still works).

Built and battle-tested while Claude played a real fortress (Run 5 "Windrings", DF 53.16 + DFHack, 2026).
Documentation lives in `docs/` (`MANUAL.md`, `OVERVIEW.md`, `INTEGRATION.md`); this README, the code and the tests are enough to get started.

## What it does

| Area | Commands |
|---|---|
| Situation report (≤ 600 tokens, delta only) | `check`, `digest`, `cycle` |
| Maintenance autopilot with loop protection | `autopilot`, `guard`, `waechter` (real-time watcher), `tempo` |
| Knowledge | `runbook diagnose/show/run`, `kb search`, `brief <scope>` (agent briefing ≤ 1500 tokens) |
| Agents | `agents prompt/lint-report/cost`, `bus` (message bus), `memory compact` |
| Autopilots (v2) | `siege`, `caravan`, `trade`, `mood`, `care`, `workload`, `bottleneck`, `water`, `reboot` |
| Autopilots (v3) | `perimeter`, `digcheck`, `reach`, `perf`, `tools`, `remote`, `hygiene`, `defense`, `settings`, `camera`; standstill/window guard inside `waechter` – see `docs/manual-v3/` |
| Reporting | `forecast`, `dashboard` (static HTML), `journal` (chronicle, lessons, post-mortem), `metrics`, `budget` |
| Fair play | `lint` (30+ rules on Lua), exception register `exception list/add` |

Every write action is logged in `data/state.db` with its reason; every rule has a `max_per_hour`.

## Quick start (no game needed)

```bash
python -m df_llm_helper --mock fixtures/run5 check          # report from recorded real game answers
python -m df_llm_helper --mock fixtures/run5 runbook diagnose
python -m df_llm_helper --mock fixtures/run5 dashboard --out runtime/dashboard.html
python -m df_llm_helper.selftest                            # full test suite (~10 s), needs pytest
```

Requirements: Python 3.11+, standard library only (pytest for tests; `lua5.4` optional for Lua tests).
Run all commands from this folder.

## Against a real game

1. `cp config.yaml.example config.yaml`, set `dfhack_run` and `paths.gamelog`; fortress-specific values
   (squad name, water boxes, rally point) go there too.
2. Copy `lua/pilot_*.lua` and `lua/claude/*.lua` to `<Dwarf Fortress>/hack/scripts/claude/` and set the
   environment variable `DF_LLM_HELPER_HOME` (shared folder for flags/logs) – see **`COMPANION.md`**.
3. Adjust the fortress-specific values in `lua/claude/config.lua` after embark (example values ship from the original fortress).
4. Orchestrator loop: `python -m df_llm_helper check` every 5 minutes, `python -m df_llm_helper waechter --loop` as a background
   process, `python -m df_llm_helper wake --loop` as the wake-up filter. Details: `docs/MANUAL.md`.

## Fair play

Only what a human player could do through the UI: designations, build orders, stockpiles, work orders, labors,
squads, alerts, trading, quickfort with *own* blueprints, DFHack convenience automation. Refused by the linter and
the client: `createitem`, `dig-now`, `build-now`, `reveal`, `prospect all`, direct unit/item manipulation.
Exceptions only via an entry in `data/exceptions.jsonl` that quotes the human player's explicit consent.

## Status

- Core (M1–M3) is live-tested; v2 and v3 autopilots are tested against recorded data, their Lua parts are marked
  *live-untested* (`docs/INTEGRATION.md` lists the live checks). See `CHANGELOG.md`, open deviations included.
- Specs: `docs/SPEC.md`, `docs/specs-v2/`, `docs/specs-v3/`.

## Layout

```
df-llm-helper/      Python package (CLI: python -m df_llm_helper)
lua/          DFHack scripts: pilot_*.lua + companion toolkit lua/claude/*.lua
tools/        luacheck_min.py (Lua structure check), embark/ (menu automation without a desktop)
data/         rules, runbooks, knowledge base, graphs, scopes, services
fixtures/     real recorded game answers (Run 5), anonymised agent transcripts
scenarios/    replay scenarios; tests/  pytest suite incl. a minimal DFHack mock for Lua
docs/         manual, overview, specs, integration checklist
```

## License

Public domain ([The Unlicense](LICENSE)) – do whatever you want with it.
