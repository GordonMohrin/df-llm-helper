# df-llm-helper – Helper Program for LLM Control of Dwarf Fortress (Specification)

As of 01.10.2026. Client: the player. Author of the specification: Claude (Opus, orchestrator of runs Run 1–5).
This document is the assignment for a **cloud session without access to Dwarf Fortress/DFHack**. Everything must therefore be
**developable and testable offline against mocks and recorded fixtures**. The live integration is done afterwards by Claude locally.

## 1. What this is about

An LLM (Claude) plays Dwarf Fortress 53.16 via DFHack: `dfhack-run.exe` (localhost:5000) runs Lua scripts `claude/*` in the game.
This works, but runs 2–4 died of *control problems*, not of game knowledge:
the orchestrator was not awake, the watchdog was blind, diagnoses were worked out from scratch every time, agents read the same documents
over and over, and the game ran unsupervised for years. On top of that, every pass costs many tokens (status dumps, Markdown memory,
repetition).

**df-llm-helper** is meant to sit between LLM and game and (a) do routine work **deterministically without an LLM**, (b) give the LLM only **compact,
decision-ready summaries**, (c) keep **known knowledge available as executable runbooks**, (d) provide **safety nets**
(tempo, deadman, fair play), and (e) **measure token and time consumption**.

Non-goals: no replacement for DFHack, no game-mechanics cheats (fair play, see 3.), no GUI, no LLM of its own, no third-party cloud service
(the player does not want external services that trigger something in his systems).

## 2. Environment and constraints

- Target system: Windows 11, Git-Bash/PowerShell. **Python 3.12+ is available** (`python`), Node is available, `pip` only after consultation:
  **Python standard library only** (exception: `pytest` for tests). No `requests`, no `pydantic` – `dataclasses`, `json`, `subprocess`, `argparse`, `sqlite3`, `unittest`/`pytest`.
- Code language Python, identifiers in English, comments/docs in German or English (terse). The game side stays **Lua** (DFHack scripts);
  Lua code written by the cloud session is untested against DF and is secured only via syntax/structure checks and mock tests (see 8.3).
- Interface to the game: exclusively `dfhack-run.exe <command>` via an abstract class `DFClient` (see 5.). Responses are mostly JSON,
  sometimes text blocks. The game is **single-threaded and slow on large dumps**: few calls, small responses.
- Repo: the original private project repository (folder `dwarf-fortress/`). New code under `df-llm-helper/`. Do not restructure existing files
  (`lua/claude/*.lua`, `tools/`, `*.md`); additions only, additively. **No push** (only the player pushes) – committing in the cloud session is ok.
- Language of outputs to the player/LLM: German, terse.

## 3. Fair Play (hard rule, enforced technically)

Allowed: what a player can do through the interface (dig/build/zone orders, stockpiles, work orders, work groups, squads/uniforms, offices, alert,
trade, saving, DFHack convenience automations, quickfort with own grids).
Forbidden: `createitem`, `dig-now`, `build-now`, `reveal`, `prospect all`, direct unit/item manipulation (changing owner, setting flags),
changing terrain, revealing the map, reading and using cavern/underworld positions. **Exceptions only with the player's explicit yes** (examples from practice:
`foreign=false` when picking embark items, `flags1.left=true` for stuck traders; deleting zones/stockpiles in the game is allowed).
Every exception must be in the **exception register** (`df-llm-helper/data/exceptions.jsonl`: time, action, object IDs, reason, "player_consent: <quote>"); without an entry df-llm-helper refuses it.

## 4. Architecture

```
Claude (orchestrator / scope agents)  <──  compact digests, runbook hits, tool commands
             │
        df-llm-helper (Python process, "daemon" + CLI)
   ┌─────────┼─────────────────────────────────────────────┐
   │ Collector  │ Rules/Autopilot │ Runbooks │ Knowledge │ Bus │ Metrics │ Guard │
   └────┬───────┴──────────┬──────┴─────┬────┴─────┬─────┴──┬──┴────┬────┘
        │                  │            │          │        │       │
   DFClient (Real | Mock | Replay)   SQLite (state.db)   File system (inbox/, scopes/, flags/)
        │
   dfhack-run.exe → Lua `claude/*`
```

Principles: **delta instead of dump** (report only changes), **numbers instead of prose**, **one call instead of ten** (batching), **knowledge as data** (YAML/JSON instead of long Markdown),
**LLM only for decisions**, everything **idempotent** and **testable via mock**.

## 5. Interfaces (binding)

### 5.1 `DFClient` (abstract)
```python
class DFClient:
    def run(self, cmd: str, *, timeout: float = 40.0) -> Result: ...   # one dfhack-run call
    def run_many(self, cmds: list[str], *, timeout: float = 60.0) -> list[Result]: ...  # batching
@dataclass
class Result: ok: bool; stdout: str; stderr: str; elapsed_s: float; json: dict | list | None  # json=parsed if possible
```
Implementations: `RealClient` (subprocess `dfhack-run.exe`, path from configuration), `MockClient` (fixture responses per command, deterministic, with error/delay injection),
`ReplayClient` (replays recorded sessions `*.jsonl` time step by time step, see F12).
`MockClient` and `ReplayClient` must be usable in **all** tests; `RealClient` has only a minimal smoke test that is skipped automatically without DF.

### 5.2 State model `Snapshot` (from `claude/status`, `claude/report`, `claude/units`, `claude/mil tabelle`, `claude/config` etc.)
Normalized dataclasses (`Snapshot`, `Citizen`, `Squad`, `Stocks`, `JobsSummary`, `Alerts`, `Time`). Sources and real examples are in
`fixtures/run5/*.txt` (responses of the commands on 01.10.2026 with 23 citizens). Parsers must be **tolerant** (missing fields → `None`, never an exception).

### 5.3 Files/flags of the existing system (read/write only, do not restructure)
`tools/events.log` (watchdog log), `tools/*.flag` (`alert`, `caravan`, `food`, `siege`, `mood`, `migranten`), `tools/pause.hold`, `tools/heartbeat.txt`
(deadman heartbeat), `tools/scopes/*.md` (agent memory), `tools/scopes/inbox-<scope>.md` (lines `- von <scope>, <zeit>: <text>`), `tools/out/*.csv|json|log`.
Examples: `fixtures/run5/logs/`, `fixtures/run5/scopes_sample/`.

### 5.4 Game commands (Lua, existing; excerpt, see `lua/claude/*.lua`)
`claude/status|report|units|buildings|area z x y w h|dig z x1 y1 x2 y2 [d|j|u|i|r|h|x]|ores|geo|probe`, `claude/mil tabelle|report|create|add|remove|workmode|update|refuge|uniform|barracks`,
`claude/workdetail list|assign`, `claude/aemter status|assign|vacate`, `claude/handel status|plan|prep|open|select|confirm|finish|release`, `claude/tempo on|off|status`,
`claude/advance N|0|run|clock`, `claude/schau say|show`, `claude/config`, `claude/gefahr status|sim`, `claude/mood status|plan|prebuild`, `claude/orders`, `claude/essen`, `claude/trinken`, `claude/gesund`,
`quickfort run <blueprint> -c x,y,z`, `lua -f <file>`. df-llm-helper may add new Lua scripts under `lua/pilot_*.lua` (additive, syntax-checked).

## 6. Features (prioritized) – each with benefit, behavior and acceptance criteria

Priority: **P0** = mandatory in milestone 1, **P1** = milestone 2, **P2** = milestone 3/optional. All criteria are **verifiable offline**.

### F1 (P0) Digest: compact situation report with delta  – `python -m df_llm_helper digest [--since last] [--scope X]`
Benefit: Today the orchestrator reads 8–15 KB of `claude/status`+`report`+inbox per check. Goal: **≤ 600 tokens**, only changes and anomalies.
Behavior: Fetches a snapshot (batching: one set of calls), compares with the last snapshot (SQLite), produces a ranked list: (1) critical thresholds (drink/food days < 30, hunger > 40000, dead, alerts, caravan, mood), (2) trends (idle %, population, open jobs, dig jobs), (3) new inbox lines (deduplicated, shortened), (4) "nothing new" if empty (≤ 20 tokens).
Acceptance: (a) Output for `fixtures/run5` ≤ 600 tokens (token = `len(text)//3` as approximation, tested), (b) A second call without changes → "no change" ≤ 30 tokens, (c) Thresholds are configurable (`config.yaml`), (d) Property test: randomly mutated snapshots → every threshold violation appears in the digest (nothing swallowed), (e) Order is stable and deterministic.

### F2 (P0) Autopilot rules (deterministic routine without LLM)  – `python -m df_llm_helper autopilot [--dry-run] [--once|--loop]`
Benefit: Many decisions repeat (deleting flags, detecting stale flags, tempo, reviving stopped jobs, alert follow-up steps). The LLM should not spend tokens on these.
Behavior: Rule set (YAML) `when: <condition on snapshot/events> → do: <action(s)> → verify: <check condition> → cooldown`. Every action runs via `DFClient`, is **logged** (`state.db`), has **dry-run**, **cooldown** and **maximum rate**.
Bundled rules (examples from real errors): delete stale `*.flag` older than N min; delete `food.flag` when meals > threshold; watchdog/ueberwacher/arbeit/trinken not `running` → `start`; fps not equal to target → set; `civ_alert` vs. danger consistent; deadman (F8).
Acceptance: (a) Every rule has unit tests (condition true/false, action correct, verify, cooldown), (b) Dry-run executes **no** `DFClient.run` with write effect (test via mock spy), (c) Infinite-loop protection (same action > N times per hour → rule disabled + digest warning), (d) Rule conflicts are detected (two rules with opposing actions) and reported at load time.

### F3 (P0) Runbooks: known knowledge as executable recipes  – `python -m df_llm_helper runbook list|show|run <id> [--dry-run]|diagnose`
Benefit: The same problems were diagnosed from scratch several times (pick registry, work groups, burrow, cooking ban …). Runbooks = symptom → check → fix → verification, as data (YAML) with Lua/command steps.
Behavior: `diagnose` checks all symptom conditions against the snapshot and names **hits with confidence** and the matching runbook call. Runbooks have preconditions, steps, `verify`, `rollback`, and a field `needs_player_approval` (fair-play exception, destruction).
Initial set (from the runs, details in Appendix A): E18/pick assignment, dig jam due to work groups (Stonecutters/Engravers EverybodyDoesThis), cooking loop/ban-cooking, alert burrow too small, watchdog blind (stale last-report-id), caravan procedure, strange-mood precaution, sleepless/injured dwarf without hospital, aquifer site check, timestream safety.
Acceptance: (a) ≥ 12 runbooks with tests (mock: symptom fixture → `diagnose` finds it; `run --dry-run` produces exactly the expected commands), (b) Runbook schema validator (CI test rejects incomplete runbooks), (c) every runbook has ≥ 1 negative test (symptom not present → no hit), (d) Runbooks with `needs_player_approval` refuse without an entry in the exception register.

### F4 (P0) Knowledge base instead of Markdown mountains  – `python -m df_llm_helper kb search "<symptom>"`, `kb get <id>`
Benefit: Agents read 10–20 Markdown files (ERFAHRUNGEN 96 KB, UEBERWACHUNG 30 KB, …) at every start. Goal: **retrieval on demand**, ≤ 400 tokens per hit.
Behavior: Structured entries (`id, symptom_keywords, ursache, fix, quelle, gilt_ab, run`) in `data/kb/*.yaml` (format: own minimal YAML subset or JSON Lines, parser in stdlib). Full-text search (BM25-like, self-implemented) with German/English keywords. **Import tool** `python -m df_llm_helper kb import <md>` splits existing Markdown files (headings → entries) and marks them `unreviewed`.
Acceptance: (a) Import of `ERFAHRUNGEN.md`, `UEBERWACHUNG.md`, `agent-berichte/*.md` without errors, (b) `kb search` top-3 hits for 20 given symptom queries (test file `tests/kb_queries.yaml`, expected entries) with a hit rate ≥ 80 %, (c) Response size ≤ 400 tokens (test), (d) Entries are versioned (run number) – hits from outdated runs are marked.

### F5 (P0) Briefing generator for scope agents  – `python -m df_llm_helper brief <scope> [--budget 1500]`
Benefit: Every scope agent today gets a long prompt ("read A, B, C first …") and burns tokens on reading. Goal: **one briefing package**.
Behavior: Builds from template + KB hits + current scope memory + inbox + snapshot excerpt a **briefing ≤ budget tokens**: assignment, situation in numbers, open tasks, known pitfalls (only the KB entries matching the scope), command list (only relevant ones), report format. The scope memory is **compacted** (see F6).
Acceptance: (a) For all scopes (`trinken, essen, bau, erkundung, wirtschaft, auslastung, material, militaer, verteidigung, gesundheit, handel, infra`) briefing ≤ budget, (b) always contains: fair-play block (≤ 80 tokens), report format, target KPIs, (c) contains no duplicates (test: n-gram overlap), (d) deterministic (same inputs → same output), (e) Missing mandatory fields → clear error instead of silent omission.

### F6 (P1) Memory compactor  – `python -m df_llm_helper memory compact <scope>`
Benefit: `tools/scopes/<scope>.md` grows endlessly (logs, pass reports). Goal: status/open tasks/findings stay, logs are rotated.
Behavior: Parses the sections (Status, Offene Aufgaben, Erkenntnisse, Log), keeps the last N log lines, condenses older ones into short lines (rule-based, **no LLM**), moves the original to `archive/`. Reversible.
Acceptance: (a) Idempotent (running twice = same file), (b) never loses "Offene Aufgaben"/"Erkenntnisse" (test), (c) Size reduction ≥ 40 % on `fixtures/run5/scopes_sample/*`, (d) Archive contains the original byte-identical.

### F7 (P1) Event bus instead of inbox Markdown  – `python -m df_llm_helper bus post|read|ack`
Benefit: Agents write free text into `inbox-*.md`; critical items get lost, duplicates, no status.
Behavior: SQLite table `messages(id, ts, from, to, prio, topic, text, status, dedupe_key)`; `post` deduplicates by `dedupe_key`; `read` returns only **unread** ones for the scope, shortened; `ack` marks as done; export/import of the old Markdown inboxes (backward compatibility: writes lines to `inbox-<scope>.md` on demand).
Acceptance: (a) Dedupe test (same key → one message, counter incremented), (b) Priorities (`crit` first), (c) Importer reads `fixtures/run5/scopes_sample/inbox-orchestrator.md` completely (all lines as messages), (d) Concurrency: 4 parallel processes write without data loss (SQLite WAL or file lock; test with `multiprocessing`).

### F8 (P0) Deadman, tempo governor and watchdog health  – module `guard`
Benefit: Run 4 died because the game ran for years unsupervised at 250 fps and the watchdog was blind.
Behavior: (a) **Heartbeat**: `tools/heartbeat.txt`; older than N min → fps to 30 and an entry `KRITISCH` (today in the PowerShell watchdog; Python equivalent plus self-test), (b) **Tempo governor**: permitted fps/timestream depending on state (supply days, danger, active mood, open caravan, pop gates); never faster if drink/food days < threshold or no agents active, (c) **Watchdog self-check**: process running? `last-report-id.txt` plausible (greater than the currently highest message ID → reset), `events.log` growing? otherwise alarm, (d) Flags: detect stale flags.
Acceptance: (a) State machine with table tests (≥ 30 cases), (b) Replay of the Run 4 scenario ("heartbeat 8 h old", "last-report-id > max") → alarm/fps reduction within **1 cycle**, (c) no action flapping (hysteresis test), (d) all thresholds in `config.yaml`.

### F9 (P1) Fair-play linter and exception register  – `python -m df_llm_helper lint <paths>`
Benefit: Agents write Lua; forbidden calls must never reach the game.
Behavior: Static check of Lua files/`lua -e` strings for forbidden things (`createitem`, `dig-now`, `build-now`, `reveal`, `prospect all`, `flags.foreign=`, `flags.forbid=` on foreign items, direct assignment of `pos`/`flags` to units, reading hidden tiles `designation.hidden`, `getTileType` outside discovered tiles, etc.) with an **allowlist mechanism** per exception (register, 3.). Output: file:line, rule ID, reason.
Acceptance: (a) ≥ 25 rules, one positive and one negative test case each (`tests/lint_cases/`), (b) all existing `lua/claude/*.lua` run through: findings appear as a **list**, nothing crashes (findings there are known and documented, not to be "repaired"), (c) `RealClient` refuses `lua` code that does not pass the linter unless the rule ID is on the allowlist.

### F10 (P1) Batching and response compression  – module `transport`
Benefit: Many small `dfhack-run` calls are slow (a new process each) and bloat the output.
Behavior: `run_many` bundles commands into **one** Lua session (`pilot_batch.lua` takes a JSON list, returns a JSON list), responses are **projected** (only requested fields) and truncated to a maximum size (`--max-bytes`), text blocks summarized (`"… +37 more"`).
Acceptance: (a) Mock test: 10 commands = 1 process call, (b) Projection/truncation correct (property tests), (c) A failure of one sub-command does not prevent the others (result list with `ok=false` per entry), (d) Lua script `pilot_batch.lua` passes the structure check (8.3) and a mock Lua test (see 8.3).

### F11 (P1) Planners as pure functions (offline testable)  – module `planners`
Benefit: Recurring computational tasks that agents today solve by prompt-thinking.
Parts (each pure functions on data structures, no DF calls):
1. **Trade planner**: given supply/demand (items, values, weight, trader list) → optimal selection of sales and purchases at a price ratio (default 2.3:1), reserves, priority list (food, wood, metal, …), weight limit ("Excess Weight").
2. **Dig planner**: given grid (z-level, walkable/wall), priorities, pick carriers → order of designations (reachability, distance, batch size ≤ N open jobs), avoiding duplicates and unreachable targets.
3. **Armor requirement calculator**: soldier quota (10 % of the population, tiers pop 15/40/60), bar requirement per equipment set, missing pieces → smithing orders in sequence.
4. **Supply forecast**: drink/food days from consumption (per head), production, growth (migrants) → time to shortage.
5. **Blueprint validator**: checks quickfort CSV (`#dig/#build/#zone`) for syntax, overlaps, footprint, zone keys (list in `LAYOUT-run5.md` sect. 9: m, b, h, D, B, o, T, d), order.
Acceptance: each planner ≥ 10 tests including edge cases; trade planner: optimal per brute-force reference on ≤ 12 items (property test), weight/reserve constraints never violated; dig planner: never unreachable targets, result stable; blueprint validator finds 10 prepared faulty CSVs (`tests/blueprints_bad/`) and accepts all `fixtures/run5/blueprints_ok/` (located in the repo folder copy of `dfhack-config/blueprints/claude`, see 9.).

### F12 (P0) Record and replay  – `python -m df_llm_helper record`, `python -m df_llm_helper replay <file>`
Benefit: Testable in the cloud without DF; regression tests from real runs.
Behavior: `record` logs every `DFClient.run` (command, time, response) as JSONL; `ReplayClient` returns the next recorded response for the same command (by timeline), with `--strict` (any deviation = error) or `--lenient`. Scenario files `scenarios/*.jsonl`: the cloud session **builds them synthetically** from the fixtures (time series: drinks fall, idle rises, caravan arrives, alarm …).
Acceptance: (a) Record→replay roundtrip identical, (b) ≥ 8 scenarios (Appendix B) run as an end-to-end test of collector→digest→autopilot→guard, (c) Scenario runs are deterministic (fixed random seeds, no real-time dependency: own `Clock` abstraction).

### F13 (P1) Metrics and token budget  – `python -m df_llm_helper metrics`, `python -m df_llm_helper budget`
Benefit: The player wants to see where tokens/time go.
Behavior: Every df-llm-helper command logs duration/bytes/approximate tokens per scope; `budget` shows a table (scope, calls, bytes in/out, token approximation, trend) and warns when a daily budget (`config.yaml`) is exceeded. Game KPIs (utilization, days of drinks/food, guard skills, idle) as a time series in `state.db`, CSV export (compatible with the `metrics.csv` header).
Acceptance: (a) Numbers match synthetic runs (test), (b) CSV export loads in the `csv` module without errors, (c) Warning on budget overrun (test).

### F14 (P2) Anomaly/trend detection  – module `anomaly`
Behavior: Simple robust statistics (EWMA, MAD) on time series: drink/food days falling, idle % rising, cancellation messages accumulating (count gamelog "cancels …" by type, detect loops like "Make bed: Needs logs" 5600×), death rates.
Acceptance: Detects the top-3 cancellation loops in `fixtures/run5/logs/gamelog_selected.txt`; false-alarm rate on stable synthetic data ≤ 1 per 1000 points; every anomaly has a cause hint from the KB (F4).

### F15 (P2) Trade orchestration as a state machine  – module `trade_flow`
Behavior: Formalizes the caravan procedure (arrival → pause → quicksave → broker → mark goods → open window → selection (dry) → check → live → confirm → finish → release broker → resume) as an automaton with preconditions (focus exactly `dwarfmode/Trade/Default`, `stable_seconds ≥ 2`, never `goodflag` blindly), timeouts and abort rollback; calls the trade planner (F11.1).
Acceptance: Automaton tests with mock (all paths including errors "window not open", "broker loses job", "caravan leaves"), no action in a wrong state (property test).

### F16 (P2) Status display for the player  – `python -m df_llm_helper overlay`
Behavior: Produces a short German text (≤ 3 lines) for `claude/schau say` from the top digest messages (the player sees only the DF window, not the chat), with rate limiting.
Acceptance: Text ≤ 120 characters/line, no duplicate sending of the same content within 10 min (test).

## 7. Token targets (measurable, approximation `len(text)//3`)

| Task | Today (measured/estimated) | Target |
|---|---|---|
| Orchestrator check (situation) | 8–15 KB ≈ 3–5 k tokens | **≤ 600** (F1) |
| Agent start (briefing) | 15–40 KB reading ≈ 5–12 k | **≤ 1 500** (F5) |
| Knowledge for one symptom | whole file (30–100 KB) | **≤ 400** (F4) |
| Memory file of a scope | up to 17 KB and growing | **≤ 6 KB** after compactor (F6) |
| Routine cases (delete flag, restart service, fps) | LLM turn (~1–3 k) | **0 tokens** (F2) |

## 8. Test strategy and success criteria (Definition of Done)

### 8.1 Mandatory criteria (all must be met)
1. `python -m df_llm_helper.selftest` runs **without DF** and reports all tests green; runtime < 60 s.
2. `pytest -q` ≥ **90 %** line coverage of the modules `digest, rules, runbooks, kb, brief, guard, bus, lint, transport, planners` (measured with `coverage` if installable, otherwise own counter `sys.settrace` test; the goal must be demonstrable, not merely claimed).
3. All P0 features F1, F2, F3, F4, F5, F8, F12 are implemented and meet their acceptance criteria.
4. There are **no** network accesses, no third-party packages (except pytest), no write accesses outside `df-llm-helper/` (except explicitly named paths: `tools/scopes/*`, `tools/scopes/inbox-*.md` for the F7 export).
5. All new Lua files pass the **structure check** (8.3) and the fair-play linter (F9, if already present).
6. Documentation: `df-llm-helper/README.md` (installation, commands with examples), `docs/INTEGRATION.md` (how Claude connects locally, see 10.), `CHANGELOG.md`.

### 8.2 Quality criteria (spot checks, verified by Claude/the player)
- The digest looks **information-dense** on the fixtures (every line allows a decision); no filler sentences.
- Every autopilot rule explains itself (`why:` field), is revocable and can be switched off individually.
- Error messages are action-oriented ("command X failed, try Y").
- All times UTC+local time correct: **game time** (ticks, year/month) and **real time** are never mixed (own types).

### 8.3 Securing Lua code without DF
The cloud session has no DFHack. For Lua: (1) **structure checker** `tools/luacheck_min.py` (bracket/`end` balance, strings, forbidden patterns; a similar check already exists in the repo history – rewrite it), (2) optionally install `lua5.4` in the cloud environment and load it with a **mock DFHack** (`tests/lua_mock/dfhack_mock.lua`: tables `df`, `dfhack`, minimal functions) and test the pure functions, (3) keep Lua **thin**: logic in Python, Lua only transport (`pilot_batch.lua`) and access functions. Lua features count as "implemented, not yet live-tested" and are listed in `INTEGRATION.md` under "Live acceptance by Claude".

### 8.4 Fixtures and scenarios
`fixtures/run5/` contains **real** responses (as of 12 Hematite, year 102, 23 citizens): `status, report, units, buildings, mil_tabelle, workdetail_list, tempo_status, config, handel_status, mood_status, orders_status, essen_status, trinken_status, aemter_status, area_z130/z133` and `logs/` (`events_head.log, auslastung_tail.csv, metrics_tail.csv, gamelog_selected.txt`), `scopes_sample/` (real memory files). The cloud session should generate **additional synthetic** fixtures (generator `tests/make_fixtures.py`, parameterizable: pop, supplies, idle, alerts) so that edge cases are testable.

## 9. Repo layout (proposal, adjustable)
```
df-llm-helper/
  SPEC.md  README.md  INTEGRATION.md  CHANGELOG.md  config.yaml.example
  df-llm-helper/                # Python package: client.py (DFClient/Real/Mock/Replay), snapshot.py (parser), digest.py, rules.py, runbooks.py,
                          # kb.py, brief.py, memory.py, bus.py, guard.py, lint.py, transport.py, planners/, metrics.py, anomaly.py, trade_flow.py, cli.py
  data/                   # rules/*.yaml, runbooks/*.yaml, kb/*.yaml, briefing_templates/*.md, exceptions.jsonl (empty + example)
  lua/pilot_batch.lua     # optional, thin
  tests/                  # pytest, fixtures loader, make_fixtures.py, kb_queries.yaml, lint_cases/, blueprints_bad/
  fixtures/run5/          # real example responses (already in the repo)
  scenarios/              # *.jsonl replay scenarios
```
The existing blueprints are in the game folder (`E:\...\Dwarf Fortress\dfhack-config\blueprints\claude\*.csv`) and **not** in the repo; the cloud session should fill `fixtures/run5/blueprints_ok/` with **self-written** example CSVs in quickfort format (format see Appendix C).

## 10. Milestones and handover

- **M1 (core, P0):** `client` (mock/replay), `snapshot` parser, F1, F2, F3 (with ≥ 8 runbooks), F4, F5, F8, F12 + self-test + README. Then commit "df-llm-helper M1".
- **M2 (P1):** F6, F7, F9, F10, F11 (all planners), F13, remaining runbooks (≥ 12). Commit "df-llm-helper M2".
- **M3 (P2):** F14, F15, F16, polish, `INTEGRATION.md` complete. Commit "df-llm-helper M3".
After each milestone: `python -m df_llm_helper.selftest`, summary (≤ 15 lines) with test counts and open points in `CHANGELOG.md`.
**Live integration (done by Claude locally, not the cloud session):** `RealClient` against real DF, load `pilot_batch.lua` into the game, use digest/autopilot in the orchestrator, verify runbooks live. For this, `INTEGRATION.md` must contain a checklist with commands and expected responses.

## 11. Working rules for the cloud session
1. First read `SPEC.md`, then `fixtures/run5/*`, then test scaffolding + mock, **then** features (tests first).
2. No assumptions about DF outputs without evidence in the fixtures; where something is missing: be tolerant in the parser and add a note in `CHANGELOG.md` under "Open fixture gaps" (Claude delivers the fixtures later).
3. Do not invent anything the game can *do*: use only commands from 5.4; clearly mark new Lua functions as "untested".
4. Do not restructure existing code; additions only, additively. Existing `lua/claude/*.lua` are read-only (linter/parser may use them as test material).
5. Every decision that concerns the player (fair-play exception, deletion, time-lapse) is an **entry in the digest to the orchestrator**, never a silent action.
6. Small, frequent commits. No `git push`.

## Appendix A – Initial runbooks (symptom → fix), documented from the runs

1. **Pick/tool stuck (E18)**: Symptom: miner with labor MINE, open dig jobs, small `work_weapons`, picks lying on the ground. Fix: squad ("Bergleute", leader with `claude/mil create <Name> <id> --apply`), `claude/mil add`, `claude/mil workmode <squad> on --apply`; if picks are `foreign=true` (player exception!) → `foreign=false`; if assigned but not picked up: move item IDs from `squad.positions[].equipment.assigned_items` and `plotinfo.equipment.items_assigned.WEAPON` into `items_unassigned.WEAPON`, run `workmode` again **once**. Verify: `work_weapons` rises within ≤ 90 s. Do not run `workmode` repeatedly (deletes assignments). A squad without a leader does not accept `add`.
2. **Dig jam due to work groups**: Symptom: many `Dig` jobs open, all dwarves smoothing/engraving. Cause: groups `Stonecutters`/`Engravers` mode `EverybodyDoesThis`. Fix: mode `OnlySelectedDoesThis`, only 2–3 dwarves; miner group `OnlySelected`.
3. **Cooking loop**: Symptom: hundreds of cancellations "Prepare easy meal: Needs unrotten cookable solid item". Cause: order without ingredients (watchdog). Fix: create only when meat ≥ 2, eat PH raw (ban cooking), `ban-cooking brew mill fruit --unban` if plants are banned.
4. **Alert burrow too small**: Symptom: at alert ≥ 50 % idle, `PickupEquipment` fails. Fix: burrow = beds+food+water+workshops+stockpiles; never rebuild during combat.
5. **Watchdog blind**: Symptom: `events.log` empty, `last-report-id.txt` greater than the currently highest message ID (new game). Fix: delete/reset the file, restart the watchdog (independent process).
6. **Caravan**: Pause, `claude/handel prep --live` (broker without squad, nolabors), `plan`, mark goods, `open`, `select --dry` → check → `select --live` → `confirm` (dialog `SELECT`) → `finish` → `release`; `quicksave` beforehand; buy food/wood/metal first; never `goodflag` blindly.
7. **Strange-mood precaution**: Symptom: mood without material → death. Fix: `claude/mood status|prebuild`, workshop type in advance, keep stock of stone/metal/rough gems/wood/leather/silk/bone; time-lapse off during a mood.
8. **Injured dwarf without hospital** (sleep 100k+): Fix: hospital zone (`m{location=hospital allow=residents}`) + 2 beds, wait for rescue.
9. **Check site for no aquifer**: Embark popup "light aquifer" = unsuitable; ground layers carry the `AQUIFER` flag.
10. **Timestream safety**: never on while drink days < 100, no active agent supervision, mood active, danger.
11. **Quickfort pitfalls**: in Git-Bash `MSYS_NO_PATHCONV=1`; zone keys `m b h D B o T d`; double execution creates double zones (crypt blueprints only once).
12. **DF crash protection**: rapid UI click sequences/double clicks at embark with pauses; `quicksave` before a caravan.
13. **Dig-priority trap**: script-set dig priorities (only single tiles ≠ 4000) stop jobs; do not touch priorities.
14. **Ghost items**: items with `pos.x < 0` (not in a container) do not count as stock.

## Appendix B – Scenarios for replay tests (minimum scope)
1. Drinks fall from 150 to 0 over 10 time steps, plants 0 → digest warns, autopilot starts brewing, tempo stays low.
2. Watchdog blind (last-report-id > max) → guard alarm and reset within 1 cycle.
3. Heartbeat 8 h old → fps 30 + `KRITISCH`.
4. Idle rises from 10 % to 60 % due to dig jam → runbook 2 is proposed (not executed blindly).
5. Caravan arrives → pause + trade automaton + flags.
6. Strange mood without material → alarm + runbook 7.
7. Hunger-endangered ≥ 3 with meals > 100 (reachability/cancellation loop) → anomaly "cancellation loop".
8. Pick stuck (E18) → runbook 1 with all verify steps; repetition after stale assignment.
9. Danger (beast in the fort) → slow motion/pause, refuge consistency, no burrow change during combat.
10. New game (run change): reset all counters/caches, digest shows "New game detected".

## Appendix C – Quickfort blueprint short format
File CSV, header line `#dig`, `#build`, `#place`, `#zone` per section (`#build wall`, `#zone zones`), cells per tile, rows = y, columns = x, cursor sets the origin (`quickfort run <file> -c x,y,z`).
Example (building a wall and zone): `#build wall` + row `Cw`; depot 5x5: cell `D(5x5)`; zones: `m` meeting, `b` bedroom, `h` dining hall, `D` dormitory, `B` barracks, `o` office, `T` tomb, `d` dump, `m{location=hospital allow=residents}` for hospital. Errors: unsuitable tiles ("Unsuitable tiles"), material missing.

## Appendix D – Open questions for the player (the cloud session must not answer them itself)
1. Should df-llm-helper later also *start* the scope agents (orchestration of the Claude sessions) or only deliver data?
2. Which autopilot actions may run **without** asking (proposal: only maintenance actions from section F2, no game decisions)?
3. Daily token budget (target value for F13).
