# df-llm-helper

df-llm-helper sits between an LLM agent (e.g. Claude) and **Dwarf Fortress** running with **DFHack**. It reads the game state in one batched call and turns it into a short report of only what changed, runs routine fortress maintenance (supplies, moods, caravans, sieges, digging safety…) with deterministic rules instead of LLM turns, keeps known fixes as runbooks and a searchable knowledge base, slows the game down when the agent stops checking in, and blocks cheat commands in code. The LLM keeps the decisions; the helper does the watching. The result: far fewer tokens per check and faster reactions in the game.

![Claude (left) running the fortress Windrings in Dwarf Fortress (right): Year 118, 174 citizens, Metropolis rank](docs/img/claude-playing-windrings.png)

<sub>Left: Claude as orchestrator, reporting what its sub-agents did (new dig designations, living quarters, storage hall). Right: the fortress Windrings, embarked with 7 dwarves in Year 100, still alive in Year 118 with 174 citizens and Metropolis rank (DF 53.16 + DFHack, 2026).</sub>

## Let your LLM play

**Requirements:** Dwarf Fortress (Steam, 53.x) with DFHack installed, and an LLM agent that can run shell commands on the same machine as the game (e.g. Claude Code). Developed and played on Windows with Git Bash.

Start the game **through DFHack** (DFHack launches Dwarf Fortress; started any other way, DFHack and the helper cannot see the game). Then paste this prompt into your agent. It clones the repo, sets everything up and starts playing:

```
Play Dwarf Fortress for me through DFHack, using df-llm-helper as your helper layer.
Dwarf Fortress is installed on this machine and running, launched through DFHack.

Setup
1. Clone https://github.com/GordonMohrin/df-llm-helper and work from that folder.
   Read README.md, COMPANION.md and docs/MANUAL.md.
2. Run: python -m df_llm_helper.selftest --quick  (must end with "Self-test GREEN").
3. Find my Dwarf Fortress install. Copy config.yaml.example to config.yaml and set
   dfhack_run (path to dfhack-run) and paths.gamelog (gamelog.txt in the DF folder).
4. Copy lua/pilot_*.lua and lua/claude/*.lua to <Dwarf Fortress>/hack/scripts/claude/.
5. Set the environment variable DF_LLM_HELPER_HOME to a shared runtime folder so the game
   and the helper see the same flags and logs (see COMPANION.md). Ask me before changing
   system-wide settings; the game may need a restart (again through DFHack) to see the variable.
6. Check the connection with the read-only steps of docs/INTEGRATION.md
   (python -m df_llm_helper digest must return a status line). Parts of the Lua side are
   live-untested: if an answer differs from the expected one, record it and tell me.

New fortress
7. If no fortress is loaded, ask me to create a world and embark (prefer a site without an
   aquifer), or try the experimental embark scripts in tools/embark/.
8. lua/claude/config.lua ships neutral (no map values; examples/windrings/ shows a filled-in file).
   Run claude/config via dfhack-run, set every value from the checklist at the top of config.lua
   for this map, then restart the permanent jobs as described there.
9. Start as background processes and keep them running:
   python -m df_llm_helper waechter --loop
   python -m df_llm_helper wake --loop --interval 10

Playing
- Fair play: only what a human player could do through the UI. Never createitem, dig-now,
  build-now, reveal or direct unit/item edits. The linter refuses them; do not work around it.
- Every 5 minutes: python -m df_llm_helper check, and act on what it reports.
- React to every WAKE line from the wake filter.
- When something looks wrong: runbook diagnose, then runbook run <id> --dry-run before the
  real run. Knowledge: kb search "<symptom>".
- Delegate bigger jobs to sub-agents with the prompt from
  python -m df_llm_helper agents prompt <scope> --task "<one sentence>" (pass it unchanged).
- After every load or restart of the game: python -m df_llm_helper reboot.
- Time-lapse only via python -m df_llm_helper tempo on (it refuses while a guard blocker is active).
- Plan the first year (shelter, food, drinks, workshops) and report to me in at most 10 lines,
  then keep playing and report only what needs my decision.
```

Prefer to set it up by hand? The same steps are in `COMPANION.md` and `docs/MANUAL.md`.

## Why this exists

**To save tokens and to control the game faster.** Without a helper, every check means the LLM reads raw status dumps, re-reads its notes and re-derives known fixes, and every routine fix costs a full LLM turn. That is expensive, and it is slow: an LLM turn takes seconds to minutes, while a Dwarf Fortress fortress can get into trouble in a few in-game days.

df-llm-helper moves everything that does not need judgement out of the LLM:

| Task | Without helper | With df-llm-helper |
|---|---|---|
| Situation check | read 8–15 KB of status/report/inbox ≈ 3–5k tokens | delta report ≤ 600 tokens (Run 5 sample: ~170); "no change" ≈ 15 tokens |
| Routine fixes (flags, services, fps, stockpiles…) | one LLM turn each, ~1–3k tokens | **0 tokens**, autopilot rules |
| Knowledge for one symptom | read a whole notes file (30–100 KB) | `kb search` / `runbook diagnose` ≤ 400 tokens |
| Starting a sub-agent | read 15–40 KB of docs ≈ 5–12k tokens | `brief <scope>` ≤ 1,500 tokens |
| Reaction time | next LLM check (minutes) | watcher every 2 s, deterministic |

<sub>"Without helper" figures are the measured/estimated baseline from the runs before, see `docs/SPEC.md` §7; token ≈ characters / 3.</sub>

How it gets there:

- **One call, one short report.** `check` collects the whole game state in one batched call and returns only what changed, what is urgent and what is still open.
- **Routine runs itself.** Maintenance rules (food flags, stockpiles, caravans, moods, sieges, water…) run on an autopilot with cooldowns and loop protection. Every write action is logged with its reason.
- **Known problems have runbooks.** `runbook diagnose` matches symptoms to fixes learned in earlier runs, instead of the LLM working them out again.
- **The LLM sleeps until it is needed.** `wake` filters events down to decision-ready ones; a deadman switch and tempo governor slow the game when the orchestrator stops checking in. (Run 4 died exactly that way: years at 250 fps with nobody watching.)
- **Fair play is enforced in code**, not by prompt. `createitem`, `dig-now`, `reveal` and friends are refused by the client and a Lua linter.

```
 LLM agent (Claude, …)  ──  python -m df_llm_helper check / runbook / brief …
          │                                │
          │  decisions                     │  ≤ 600-token delta reports, wake-up events
          ▼                                ▼
                  df-llm-helper (Python, stdlib only)
          autopilot · guard · watcher · runbooks · fair-play linter
                               │
                        dfhack-run + Lua scripts
                               │
                         Dwarf Fortress
```

## Try it in 30 seconds (no game needed)

Recorded answers from the real Run 5 fortress ship with the repo, so everything works without Dwarf Fortress:

```
git clone https://github.com/GordonMohrin/df-llm-helper && cd df-llm-helper
python -m df_llm_helper --mock fixtures/run5 check
```

```
Status Y102 Hematite 12 | Pop 24 (7 idle 30%) | Drinks 76d Food 189d | Jobs 199 (dig 63, 3 digging) | fps 250 | PAUSE
!! Hunger>40k: Tekkud414=47k, Eral3473=40k
! Caravan Muboomon: Approaching, 3055 ticks (prepare trade)
```

That is what the LLM sees every five minutes instead of the raw game. More:

```
python -m df_llm_helper --mock fixtures/run5 runbook diagnose
python -m df_llm_helper --mock fixtures/run5 dashboard --out runtime/dashboard.html
python -m df_llm_helper.selftest                            # full test suite (~10 s), needs pytest
```

Requirements: Python 3.11+, standard library only (pytest for tests; `lua5.4` optional for Lua tests). Run all commands from the project folder; the package was formerly called *dfpilot* (`DFPILOT_HOME` still works as an alias for `DF_LLM_HELPER_HOME`).

## What it does

Every command is `python -m df_llm_helper <command>`; add `--mock fixtures/run5` to try it without the game.

**Orchestrator loop**

| Command | What it does |
|---|---|
| `check` | The one call per orchestrator check: heartbeat, guard, autopilot and situation report together |
| `digest` | Compact situation report, only what changed (≤ 600 tokens) |
| `cycle` | One round of guard, autopilot and digest |
| `heartbeat` | Tells the guard the orchestrator is still awake |
| `wake` | Filters events down to the ones that need a decision, one line each |

**Safety and tempo**

| Command | What it does |
|---|---|
| `guard` | Deadman switch and tempo governor: slows the game when nobody is supervising |
| `waechter` | Real-time watcher in the background (messages, flags, pauses, frozen game, stuck windows) |
| `tempo` | Shows or switches time-lapse, only when no guard blocker is active |
| `perf` | Finds what freezes or slows the game (latency sampling, safe bisect) |
| `reboot` | After a restart or save load, brings back the background jobs that do not survive loading |
| `settings` | Edits `d_init.txt` with backup, verify and revert |

**Routine autopilot**

| Command | What it does |
|---|---|
| `autopilot` | Runs the deterministic maintenance rules (cooldowns, loop protection) |
| `care` | Watches hunger, thirst and the hospital |
| `mood` | Strange moods: checks material gaps and reserves supplies |
| `workload` | Turns a high idle rate into the right fix (empty dig queue, too few picks, missing material, full stockpiles) |
| `bottleneck` | Spots material and fuel shortages before production stalls |
| `water` | Flood and water watcher; checks commands for flooding risk |
| `hygiene` | Loose stacks, dump marking, refuse zone proposals |
| `tools` | Keeps enough picks and miners, suggests forging |
| `remote` | Rescues dwarves stuck on long, far-away jobs |

**Military and trade**

| Command | What it does |
|---|---|
| `siege` | Handles sieges, raids and beasts without LLM turns: pause, targets, kill orders, civilian warning, cleanup |
| `defense` | Designs kill boxes and traps; builds only with `--apply --confirm` |
| `caravan` | Caravan arrival and preparation, step by step |
| `trade` | Trading as a state machine, from opening the depot to finishing |

**Map and digging**

| Command | What it does |
|---|---|
| `digcheck` (alias `dig check`) | Checks dig orders before designating: no new openings to the outside, no aquifer, water or cavern breach |
| `perimeter` | Finds open access paths into the fortress, plans sealing |
| `reach` | Checks which places dwarves can still walk to, and what cut them off |
| `camera` | Camera profiles for watching (ambient, combat, build, events, calm) |

**Knowledge and agents**

| Command | What it does |
|---|---|
| `runbook` | Known problems as recipes: diagnose symptoms, show and run fixes |
| `kb` | Searches the knowledge base (≤ 400 tokens per hit) |
| `brief` | Builds a compact briefing for a sub-agent (≤ 1,500 tokens) |
| `agents` | Sub-agent prompts, report linting and cost measurement |
| `bus` | Message bus between agents (priorities, dedupe) |
| `memory` | Compacts agent memory files, keeps the original in an archive |
| `overlay` | Short in-game text for the human player watching |

**Planning and reporting**

| Command | What it does |
|---|---|
| `plan` | Planners for blueprints, trade, digging, armor and supply |
| `forecast` | Predicts famine before it happens |
| `dashboard` | Static HTML dashboard of the fortress |
| `journal` | Chronicle, lessons learned and post-mortem from the event log |
| `metrics` | KPI time series as CSV |
| `budget` | Token consumption per agent scope against a daily budget |

**Fair play and testing**

| Command | What it does |
|---|---|
| `lint` | Fair-play linter for Lua scripts (30+ rules) |
| `exception` | Register of exceptions, each with the player's quoted consent |
| `record` | Records real game answers as fixtures |
| `replay` | Replays recorded scenarios and checks the results |

Every rule has a `max_per_hour`; a rule that fires too often switches itself off and raises a warning. Full reference: `docs/MANUAL.md`, `docs/OVERVIEW.md`.

## Fair play

Only what a human player could do through the UI: designations, build orders, stockpiles, work orders, labors, squads, alerts, trading, quickfort with *own* blueprints, DFHack convenience automation. Refused by the linter and the client: `createitem`, `dig-now`, `build-now`, `reveal`, `prospect all`, direct unit/item manipulation. Exceptions only via an entry in `data/exceptions.jsonl` that quotes the human player's explicit consent.

## Status

- Core (M1–M3) is live-tested; v2 and v3 autopilots are tested against recorded data, their Lua parts are marked *live-untested* (`docs/INTEGRATION.md` lists the live checks). See `CHANGELOG.md`, open deviations included.
- Some Lua output keys and in-game texts are still German (they are part of the protocol between Lua and Python); all user-facing Python output is English.
- Specs: `docs/SPEC.md`, `docs/specs-v2/`, `docs/specs-v3/`.

## Contributing

Issues and PRs welcome, especially live test reports for the *live-untested* parts, runbooks from your own fortress, and experiences with other LLMs as orchestrator. Bug report template: `Bugs/TEMPLATE.md`.

## Layout

```
df_llm_helper/  Python package (CLI: python -m df_llm_helper)
lua/            DFHack scripts: pilot_*.lua + companion toolkit lua/claude/*.lua
tools/          luacheck_min.py (Lua structure check), embark/ (menu automation without a desktop)
data/           rules, runbooks, knowledge base, graphs, scopes, services
fixtures/       real recorded game answers (Run 5), anonymised agent transcripts
scenarios/      replay scenarios; tests/  pytest suite incl. a minimal DFHack mock for Lua
docs/           manual, overview, specs, integration checklist
```

## License

Public domain ([The Unlicense](LICENSE)) – do whatever you want with it.
