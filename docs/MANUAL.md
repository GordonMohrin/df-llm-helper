# df-llm-helper – Manual for the orchestrator, scope agents and the player

df-llm-helper sits between Claude and Dwarf Fortress (DFHack). It delivers compact situation reports, handles routine work without an LLM, keeps known knowledge ready as runbooks and a knowledge base, and slows the game down when nobody is supervising. Since 2026-10-01 it also replaces the PowerShell watcher `tools/unpause-guard.ps1`.

**Important:** Parts that touch DF are tested against mocks but still **live-untested**. Before first use, go through the checklist in `INTEGRATION.md` once.

## 1. One-time setup (the player's machine, Git Bash)

```bash
cd "<path>/df-llm-helper"
python --version                      # 3.11+ ("python", not "python3")
python -m df_llm_helper.selftest --quick    # must report "Self-test GREEN"
cp config.yaml.example config.yaml    # optional: the default paths fit the player's machine
cp lua/pilot_*.lua lua/claude/*.lua "<DF install folder>/hack/scripts/claude/"
```

**Replacing the PowerShell watcher** (player decision: only df-llm-helper's deadman brake from now on):
1. Stop the old watcher: `Get-CimInstance Win32_Process | ? CommandLine -like '*unpause-guard*' | % { Stop-Process $_.ProcessId }`. `wake.ps1` is no longer needed either.
2. Start the new watcher as a standalone process so it does not die with the shell:
   `Invoke-CimMethod Win32_Process -MethodName Create -Arguments @{CommandLine='python -m df_llm_helper waechter --loop'; CurrentDirectory='<path>\df-llm-helper'}`
3. Verify: `tools/out/waechter.alive` is refreshed every 2 s, and `python -m df_llm_helper guard --dry-run` shows no "Watcher is not running" warning.

What the watcher does (like the old ps1, plus the deadman):
- It writes game messages to `tools/events.log`.
- On enemies: `alert.flag`, `pause.hold`, pause, civilian alert and time-lapse pause. On a siege additionally `siege.flag`.
- Caravan: `caravan.flag` and pause.
- Supplies low: `food.flag`.
- Report-ID reset on a new game.
- It closes message windows and then lifts the pause.
- **Deadman:** If `tools/heartbeat.txt` is older than 20 min, it sets fps 30. Only when the heartbeat is younger than 10 min does it return to the normal fps.

## 2. Orchestrator: the normal cycle

| When | Command | Result |
|---|---|---|
| every 5 min (mandatory) | `python -m df_llm_helper check` | sets the heartbeat, runs guard and autopilot and returns the situation report as a delta (≤ 600 tokens, ≈ 26 when unchanged) |
| monitor (background) | `python -m df_llm_helper wake --loop --interval 10` | one line per event that needs action, e.g. `WAKE caravan: … -> python -m df_llm_helper runbook show rb06_karawane` |
| something looks off | `python -m df_llm_helper runbook diagnose` | matching runbooks with confidence |
| view/test a recipe | `runbook show <id>`, `runbook run <id> --dry-run [--param k=v]` | exact command list. Only then run without `--dry-run` |
| knowledge on a symptom | `python -m df_llm_helper kb search "Koks refined coal"`, `kb get <id>` | ≤ 400 tokens instead of whole Markdown files |
| start an agent | prompt from `AGENT-PROMPT.md`; the agent calls `python -m df_llm_helper brief <scope>` | briefing ≤ 1500 tokens |
| caravan at the depot | call `python -m df_llm_helper trade step` repeatedly, `trade approve` after the dry run | state machine with rollback |
| time-lapse state | `python -m df_llm_helper tempo status` | display only: time lapse, fps, guard blockers (changes nothing) |
| time-lapse on | `python -m df_llm_helper tempo on` | switches on only if the guard reports no blocker, otherwise names the blockers |
| inform the player | `python -m df_llm_helper overlay --send` | ≤ 3 lines in the game, no repetition within 10 min |

Reading the situation report:
- `!!` is critical: drink or food days below 30, hunger or thirst above 40k, enemies, deaths, moods, alert or siege flag, watcher blind, deadman.
- `!` is a warning: caravan, civilian alert, idle ≥ 40 %, abort loop with KB hint, trend anomaly.
- `~` is a trend, `>` a new message from the inbox or bus.
- `still open:` marks known items that are unchanged, `ok resolved:` marks resolved ones.

## 3. Scope agents

- Start with `python -m df_llm_helper brief <scope>`. It contains the mission, KPIs, open items from memory, known pitfalls, commands, fair play and the report format. Scopes: trinken, essen, bau, erkundung, wirtschaft, auslastung, material, militaer, verteidigung, gesundheit, handel, infra.
- Messages go over the bus instead of Markdown: `python -m df_llm_helper bus post "<text>" --from <scope> --to <scope|orchestrator> [--prio crit|warn] [--key <key>]`. With `--key` messages are deduplicated; identical messages then count up.
- Inboxes: `bus read --to <scope>`, mark done with `bus ack --to <scope> <ids>`.
- Memory `tools/scopes/<scope>.md` with sections "Status", "Offen" (open), "Erkenntnisse" (findings), "Durchlauf N" (run N). Afterwards `python -m df_llm_helper memory compact <scope>`; the original goes to `tools/scopes/archive/`, `memory restore <scope>` brings it back.
- Do not call `claude/arbeit status` or `claude/ueberwacher status`; both trigger a work round. Running services are shown by `brief infra` or `check`.

## 4. Autopilot: what happens without asking

By player decision the classes `maintenance` and `safety` run automatically. `game` only appears as a suggestion in the situation report. Rules live in `data/rules/maintenance.yaml`; `python -m df_llm_helper autopilot rules` lists them with their rationale.
- **Maintenance:**
  - delete stale flags (alert/siege only when there is no danger),
  - delete `food.flag` when stocks are full,
  - restart watchdog, Ueberwacher, Arbeit and Trinken,
  - correct fps drift,
  - brewing loop when drinks fall below 30 days.
- **Safety:** civilian alert when an enemy is in the fort; pause and `caravan.flag` when the caravan is at the depot.
- **Loop protection:** If a rule repeats the same action more than 6× (or `max_per_hour`) per hour, it switches itself off and raises a critical warning. Re-enable with `python -m df_llm_helper autopilot enable <id>`.

## 5. Fair play

Forbidden commands (createitem, dig-now, build-now, reveal, prospect all, direct unit and item manipulation …) are technically refused by every client. The linter checks Lua code (`python -m df_llm_helper lint <path>`, 30 rules).

Exceptions exist only with the player's consent in the register:

```bash
python -m df_llm_helper exception add FP08 --objects 187405,187429 --reason "E18 embark picks" --ja "<verbatim quote>"
```

The quote is stored in the field `player_consent` of `data/exceptions.jsonl` (older register files with the previous field name are still read).

If the rule ID (FPxx or Lxx) is in the register, the client lets the command through for exactly those objects.

`exception add` accepts only known rule ids (FP01-FP13, L01-L31), numeric object ids, `--max-uses` >= 1 and a real
calendar date for `--expires` (`YYYY-MM-DD` = valid through the end of that day, or `YYYY-MM-DDTHH:MM:SSZ`). A broken
register line is listed as `Register error: ...` by `exception list` and never grants anything.

## 6. Extending (for the next agent)

| What | Where | Required fields | Verify with |
|---|---|---|---|
| Autopilot rule | `data/rules/*.yaml` | `id, why, when, do` (+ `class`, `cooldown_s`, `verify`, `mutex_with`) | `python -m df_llm_helper autopilot conflicts`, `pytest tests/test_rules.py` |
| Runbook | `data/runbooks/<id>.yaml` | `id, title, needs_player_approval, symptom.when, steps, verify.when` (the previous key name is still accepted as an alias) | add a test case to `tests/test_runbooks.py` (`CASES`), otherwise the test fails |
| Knowledge | `data/kb/curated.yaml` | `id, title`, ideally `symptom_keywords, ursache, fix, quelle, run` | `python -m df_llm_helper kb search "<symptom>"` |
| Import Markdown | `python -m df_llm_helper kb import ../NEW-FILE.md` | becomes `unreviewed` | |
| Scope | `data/scopes.yaml` | `mission, kpis (name/expr/ziel), commands, kb_query` | `python -m df_llm_helper brief <scope>` |
| Lint rule | `df_llm_helper/lint.py` (`RULES`) | positive and negative case `tests/lint_cases/Lxx_pos.lua` / `_neg.lua` | `pytest tests/test_lint_bus.py` |

Expressions in `when`/`verify`/`expr` are safe Python (no eval). Available, among others:
- `drink_days, food_days, meals, drinks, plants, idle_pct, pop, enemies, danger, civ_alert, caravan_active, moods, fps, timestream`
- `flags['alert'].exists/.age_min`, `services.trinken.running`, `guard.slowed`, `citizens`, `squads`, `workdetails`, `miners`, `diggers`, `pick_holders`, `cancels`
- Functions: `wd('Miners')`, `job_count('Dig')`, `cancel('refined coal')`, `len/min/max/sum/any/all/join`
- `th.<threshold>` and `cfg.<path>`

Texts may contain `{expression}`. `{{` and `}}` are literals.

After every change: `python -m df_llm_helper.selftest` (≈ 30 s, no DF needed; needs pytest, without it the result is `Self-test INCOMPLETE`, exit 2; `--quick` < 1 s).

## 7. Troubleshooting

| Symptom | Cause/remedy |
|---|---|
| Situation report: `Query failed` | DF is not running, or `dfhack_run` in `config.yaml` is wrong |
| `Watcher is not running` | Restart the watcher (section 1); check `tools/out/waechter.alive` |
| `Watcher blind: last-report-id …` | df-llm-helper resets the file itself. If it persists, restart the watcher |
| `DEADMAN` | The orchestrator has not run `check`/`heartbeat` for more than 20 min. After `python -m df_llm_helper check` it returns to normal within < 10 min |
| Rule "deaktiviert … Endlosschleife?" (disabled … endless loop?) | Find the cause, then `python -m df_llm_helper autopilot enable <id>` |
| `FAIR PLAY: [FPxx] …` | intended. Release only with the player's consent via `exception add` |
| DF response format unknown | record it with `python -m df_llm_helper --record x.jsonl record <command>` and put it in `fixtures/`. The parsers are tolerant |

## 8. Player decisions (2026-10-01)

- **Start agents itself:** No, not for now; the orchestrator keeps doing that. df-llm-helper only supplies data and briefings.
- **Protective actions without asking:** Yes. Civilian alert on enemies and pause on caravans run automatically (class `safety`).
- **Daily token budget:** none. `metrics.daily_token_budget: 0` switches the warning off; `budget` only shows consumption.
- **E18 release of equipment data:** Moving item IDs to `items_unassigned` stays a manual step with an orchestrator decision. It is a direct intervention in game data at the fair-play boundary, so df-llm-helper does not automate it (Claude's decision).
- **Deadman:** df-llm-helper only. The PowerShell watcher is replaced by `python -m df_llm_helper waechter`.
- **Switching on time-lapse:** The orchestrator may do it, but only via `python -m df_llm_helper tempo on`. That refuses on any guard blocker: deadman, danger, mood, caravan, supplies below 100 days, no supervision, unacknowledged pop gate (Claude's decision).
- **Zone key `a` (archery range):** stays allowed because a real blueprint of our own uses it (Claude's decision).

## 9. Autopilots v2 (`specs-v2/`, live-untested)

### 9.1 Siege: `python -m df_llm_helper siege` (spec 01)
- **When:** `WAKE alarm`/`WAKE siege` with real attackers (not just combat lines). One call works through the whole siege: `python -m df_llm_helper siege` (report ≤ 12 lines). `--once` = one step, `--dry-run` = show only, `-v` = all commands.
- **Flow:** pause → assess (count/types) → civilian alert as soon as an attacker is ≤ `alert_radius` (40) away → loop: kill order to the squad `squad_alias` (guard) for targets ≤ `kill_radius` (45), `claude/advance 300/120/60` depending on distance, wait until paused → end: clear orders, alert off, remove `alert/siege.flag` + `pause.hold`, `advance run`.
- **Safety:** kill only against `isInvader` (never citizens/pets/merchants/guests; berserk citizens are only reported). Never the miners. Orders are cleared even on errors. Burrows are never touched.
- **Abort → orchestrator:** more than `max_losses` (2) dead soldiers, `max_steps` (60) reached, or squad not found: pause, `tools/notify.flag` + critical warning (the orchestrator sends the push to the player). A soldier below `min_blood_pct` (60 %): retreat to the rally point `siege.rally: [x, y, z]` (set it in `config.yaml`!), otherwise only a message.
- **Fleeing enemies** (≥ `flee_dist` 70 tiles and distance growing) are not pursued.
- **Lua:** copy `lua/pilot_siege.lua` to `hack/scripts/claude/` (`status|kill|move|clear`).

### 9.2 Caravan: `python -m df_llm_helper caravan` (spec 02)
- **When:** `WAKE caravan`. `python -m df_llm_helper caravan --loop` drives the trade automaton (F15) to completion or to the approval wait point; `caravan status` shows the report (≤ 8 lines), `caravan reset` resets.
- **Decision:** As soon as the trade window is open, df-llm-helper reads the offer (`claude/handel list 0`) and compares it with `data/trade/wants.yaml` (must-have goods: wood, fuel, tools/chains/buckets, metal, food, seeds). No must-have good → **skip**: window closed, broker freed, `caravan.flag`/`pause.hold` removed, `advance run` (no more long pauses).
- **Approval:** The dry run `select --dry` is released only if it buys a must-have good and the ratio is ≥ `caravan.min_ratio` (2.0). Otherwise trading waits; warning in the situation report → `python -m df_llm_helper trade approve` by hand, or adjust `tools/scopes/handel-regeln.md`.
- **Stuck caravan** (`Leaving`, 0 ticks, longer than `stuck_ticks` game ticks): `claude/pilot_caravan release --apply` sets `flags1.left` for merchant units only. Works **only with register entry FP09** (the player's consent, quoted in the entry). The public repository ships only an ignored example line: the entry belongs to your own installation in `data/exceptions.local.jsonl` (git-ignored, see `data/README.md`) or is added with `python -m df_llm_helper exception add FP09 ...`. Without the entry df-llm-helper refuses, and `lint lua` reports `pilot_caravan.lua:21 L07` as an error (documented in `docs/LINT-FINDINGS.md`). Log `tools/out/caravan-release.log`.
- **Abort** (caravan leaves, window closed, timeout): clean way back (abort/finish/release/advance run); the quicksave from the start of trading stays, loading only via the title menu.
- **Lua:** copy `lua/pilot_caravan.lua` to `hack/scripts/claude/`.

### 9.3 Moods: `python -m df_llm_helper mood` (spec 03)
- **When:** `WAKE mood` / `mood.flag`, otherwise useful with every `check` cycle. `python -m df_llm_helper mood` checks all running moods (report ≤ 6 lines), `mood reserve` checks the stocks from pop ≥ 20 against the `minimum` of `claude/mood status` (authoritative; `mood.reserves` in the config is the fallback, defaults = mood.lua: rough gems 12, cut gems 10, wood 14).
- **Demand:** `claude/pilot_mood need <id>` reads the real job elements (type, quantity, flags) and, per type, free/bound stock and the nearest distance. Equal types are summed (DF creates `ROUGHx1, ROUGHx1` separately). `NONE` elements are interpreted through their flags (`bone` → bones etc.); unknown flags appear as an `unbekannt(...)` (unknown) gap, never silently.
- **Actions (operations only):** Rough gems missing but enough are tied up in jobs → `claude/pilot_mood release-cutgems --apply` (removes CutGems jobs; at most `max_releases_per_hour`, logged). Wood missing → kv `trade.boost = ['wood']` (the caravan buys wood first, as a must-have good) and `mood.block_charcoal = true`: **do not start charcoal production** while this is set.
- **Warning "will fail":** timeout < travel time (`nearest` × 2 × `ticks_per_tile` + `work_ticks`) or a gap with timeout < `warn_timeout_ticks` → critical warning in the situation report; plan: keep civilians away, treat berserkers as in spec 01 (never a kill order against citizens without the player).
- **Aftercare:** Mood gone → `mood.flag` deleted, wood boost and charcoal block lifted. Failed (insane) → one-time message, reserve of the category raised by `fail_reserve_bump` (kv `mood.reserve_extra`).
- **Lua:** copy `lua/pilot_mood.lua` to `hack/scripts/claude/` (live-untested).

### 9.4 Care: `python -m df_llm_helper care` (spec 04)
- **When:** on `notfall.flag` (HOSPITAL/REST), injured dwarves or hunger/thirst warnings, otherwise gladly with every check. `python -m df_llm_helper care [--dry-run]` → critical patients (id, name, hunger/thirst, place; top 5), actions, hints; otherwise "Pflege ok" (care ok).
- **Automatic (labor menu):** Fewer than `care.min_doctors` (3) doctors (DIAGNOSE/SURGERY/BONE_SETTING, excluding soldiers) → up to 5 idle civilians get all care labors (`claude/pilot_care labors <id> ...`), chosen by care skill. **Never** soldiers, dwarves with a pickaxe, children or patients (the Lua also refuses soldiers/pickaxe). At most 1 pass per hour, every assignment with its reason in `state.db`.
- **Hospital** = a place (location) of type HOSPITAL on a zone (DF 53 has no zone type "hospital"). **Patient** = cannot stand, lies down (job `Rest`) or has wounds and is in the hospital; `#wounds` alone also counts healed scars (live: 56 instead of 6).
- **Report only:** overlapping hospital zones, multiple or orphaned hospital locations (live: 3 locations, 2 without a zone; never delete), lying patients outside the hospital, "Give water: No water source" > 50 in the gamelog (→ `kb wasser_quelle`), meals < 0.2 per capita.
- **Lua:** copy `lua/pilot_care.lua` to `hack/scripts/claude/` (live-untested).

### 9.5 Forecast: `python -m df_llm_helper forecast` (spec 05)
- **Automatic:** Every `python -m df_llm_helper check` appends a point to the time series (kv `forecast.series`, ≤ 50 points). A line appears in the check **only when crossing** `warn_days` (30) or `crit_days` (10), with measures (trade for food/seeds, farms, population stop, `tempo off`).
- **By hand:** `python -m df_llm_helper forecast` → `Forecast: Food 11±3 days (−8.0/day), Drinks stable (+2.0/day)` (≤ 120 characters) and confidence. `forecast backtest [--file metrics.csv --horizon 3]` measures the error on a measurement series.
- **Model:** per-capita eating rate = median of the falling intervals (harvest/cooking jumps never count as negative consumption), production = increases/time, net = production − rate × population **now**. Food = meals + fish + meat (+ plants with `include_raw_plants`). The "±" band = fastest/slowest measured rate.
- **Limits:** In Run 5 the food forecast is hardly better than "stays the same" (cooking bursts, measurement points days apart). The line is an early-warning signal, not an exact number; at `confidence < 0.7` the line says so.

### 9.6 Workload: `python -m df_llm_helper workload` (spec 06)
- **When:** `wirtschaft.flag`, idle ≥ `workload.idle_warn` (40 %) in the situation report. `python -m df_llm_helper workload [--dry-run]` → header line + up to 5 lines `cause -> measure (command)`, ordered by importance.
- **Decision tree:** coke 0 and wood 0 → spec 07 (`python -m df_llm_helper bottleneck`). Many open jobs → picks (`claude/pickfix --apply` as a **suggestion**, or buy/forge), "Needs refined coal" (coke chain/trade; with coal 0 the suggestion `claude/kohle run 10` by hand – the kohle permanent job freezes the game for ~9 s per run and stays off), blocked jobs, "Inappropriate dig square", "Could not find path". Dig queue < 100 → `claude/raster start|next` automatically; without a further stage → suggest exploration (`stages.lua`). Hardly any jobs → `claude/orders start`/`claude/arbeit start` (if off), full storage, filler orders.
- **Automatic** only `raster start|next`, `orders start`, `arbeit start`; at most 2 per run, the same measure not within 10 min. After `measure_after_s` (300 s) the next run reports `ok done: …` or `no effect: …` (also in the situation report); tally in kv `workload.effects`.
- **Data:** snapshot + `claude/auslastung status`, `claude/pickfix` (dry run), `claude/material status`, `claude/raster status` (resets waiting lines, like raster itself), `claude/kohle status`, gamelog aborts.

### 9.7 Bottleneck: `python -m df_llm_helper bottleneck` (spec 07)
- **When:** idle high and `workload` points to spec 07, "Needs refined coal", before every caravan. `python -m df_llm_helper bottleneck [--dry-run]` → e.g. `Bottleneck: wood (0). Blocks: charcoal starter → coke → forge → 15 pickaxes; also well +2. Solution: Caravan wood ≥ 20, do not burn reserve 12` (≤ 160 characters).
- **Graph:** `data/graphs/produktion.yaml` (nodes with a `stock` path in `claude/material status`, `needs` = all, `any` = one alternative, goals with `target`). Add new chains there; `bottleneck validate` checks for cycles and unknown nodes (also in the self-test).
- **Coal reserve:** `coal_reserve` 20 (player, 2026-10-01: "Try to keep a bit of coal as a reserve in case the coke runs out" (translated)); below it coal counts as a bottleneck if no other fuel path is free.
- **Wood reserve:** The charcoal starter only with wood above `wood_reserve` (12) and only with coke < `fuel_reserve` (2); the line `Starter: burn at most N wood` or `Starter blocked` says so. `material.lua` is **not** changed: correct deviations by hand.
- **Trade:** Bottleneck categories land in kv `trade.boost_bottleneck`; the caravan autopilot (spec 02) puts them, together with the mood boost (spec 03), at the top of the wish list (as a must-have good). Every change is logged.
- **Duration:** A bottleneck lasting ≥ `escalate_days` (20) game days → critical warning in the situation report.

### 9.8 Water: `python -m df_llm_helper water` (spec 08)
- **Before any digging near water:** `python -m df_llm_helper water check x y z` → `ok` / `unsafe` / `forbidden` (exit 0 only for ok). Forbidden means water orthogonally, **diagonally** or z±1 adjacent, or a blocked box. Unsafe means hidden neighbors or water at distance 2. Run 5 flooded tunnel W via a diagonal access.
- **Reservoir:** Behind the emergency wall (128,99,z128) there is deliberately water (~1000 units, well (140,99,z129)); that is why the watcher only monitors the fort box, not the `watch_box`.
- **Watcher:** Every `check` scans the fort box (`water.fort_box`, ends at x=127 before the emergency wall). If water rises there is a critical warning, `wasser.flag` (wake call `WAKE flut`) and an emergency-wall suggestion at the nearest planned chokepoint (`water.chokepoints`) between front and fort. Execute with `python -m df_llm_helper runbook run rb21_flut --param x=.. --param y=.. --param z=..` (Quickfort `claude/r5_notwand.csv`, an ordinary build order). `water watch` and `water scan` show the situation by hand.
- **Forbidden boxes:** `water.forbid_dig` (Run 5: tunnel W x127..181/y97..101/z127..129, x=180 and tunnel end/shore x181..189/y42..49/z127..128 with gate (182,48) and diagonal spot (184,43)). The RealClient refuses `claude/dig` and `quickfort run *dig*` inside them (lint rule L31). Exception only with register entry L31. Check: `water lint-cmd "<command>"`.
- **Lua:** `lua/pilot_water.lua` (scan/near, discovered tiles only) to `hack/scripts/claude/`; copy the emergency-wall blueprint `blueprints/r5_notwand.csv` only if none exists there.

### 9.9 Restart/load: `python -m df_llm_helper reboot` (spec 09)
- **Automatic:** `check` notices the loading of a save (the report ID drops) and calls `reboot` itself.
- **By hand:** after every load or DF restart `python -m df_llm_helper reboot` (`-v` shows every command, `--dry-run` only the plan).
- **Flow:**
  1. Wait until the map is loaded (`reboot.wait_s`); never start services without a map.
  2. Pause the game and check `claude/config`.
  3. Start missing services from `data/services.yaml` in dependency order (watchdog before ueberwacher/milguard). Running ones are never started twice.
  4. `advance run` as soon as all are running. If a service does not start, the game stays paused and there is a critical warning.
- **Situation report:** shows `Neustart: N Dienste gestartet (…)` (restart: N services started).
- **Deliberately not automatic:** `kohle` (the permanent job freezes the game for ~9 s per run), `schau` (HUD), `watchdog_alert` (comes with watchdog). Also `tempo`. Time-lapse only via `python -m df_llm_helper tempo on` (player decision 6).
- **Adding services:** one line in `data/services.yaml` (`name`, `key` = repeat-util key or `check`, `start`, `depends`), then `reboot validate`.
- **Load helper in the title menu** (`reboot load`): clicks "Continue active game" and "autosave 1" via `findclick.lua`. Off as long as `reboot.auto_load: false`; switch on only at the player's request (live-untested).

### 9.10 Subagents: `python -m df_llm_helper agents` (spec 10)
- **Prompt (mandatory):** `python -m df_llm_helper agents prompt <scope> --task "<one sentence>"`. Pass the output unchanged as the agent prompt.
  - It contains the marker `[df-llm-helper-brief v1]`, mission, briefing, report format, fair play and commands (≤ 1,500 tokens; the briefing is shortened if necessary).
  - Same scope and task within 10 min → refused (exit 1; `--force`).
- **Report:** fields `Result`, `Measurements (before/after)`, `Changed`, `Open`, `Risk` (German field names such as `Ergebnis` are accepted), ≤ 12 lines. `agents lint-report <file|-> [--scope s]` checks; reports that are too long are output shortened, the original goes to `tools/out/berichte/`.
- **Cost:** `agents cost [--dir <folder>] [--compare]` reads Claude Code transcripts (`**/subagents/*.jsonl` under `agents.transcript_dir`). Two measuring rules:
  - **Count each requestId once:** The transcript contains every response per content block; a naive sum would be about twice as high.
  - **Output is estimated:** column `Out~` = the larger of the block-length estimate and the summed `usage.output_tokens` (usually only the stream-start value, but larger for long agents whose thinking blocks are empty in the transcript); the warning uses the same figure.
- **Comparison:** `--compare` sets runs with the marker against old prompts. Meaningful from 3 runs each (acceptance 4).
- **Warning:** over 60 calls or over 40k estimated output → "stuck? check the result, shrink the task".

### 9.11 Dashboard: `python -m df_llm_helper dashboard` (spec 11)
- **Automatic:** Every `check` rewrites `tools/out/dashboard.html`, but only if the content changed (hash).
- **By hand:** `python -m df_llm_helper dashboard [--out file] [--offline]`. Without `--offline`, `claude/buildings` is read first (build-plan counters).
- **Content** (from `state.db` only; a section without a source is omitted):
  - header and key figures with history (6 h)
  - forecast (spec 05)
  - warnings: exactly the open items of the situation report
  - build plan (`dashboard.buildplan`, default: hospital, temple, tavern, library, guildhall, barracks, dining hall, dormitory, crypt 20, well, depot)
  - bottleneck and stocks (spec 07), trade (spec 02/03/07)
  - events (warnings and actions)
  - map excerpts
- **Maps:** `dashboard map <name> x y z w h` stores `claude/area` in `state.db` (e.g. `map Tunnelende 170 40 127 20 15`); `dashboard unmap <name>` removes the map.
- **Publishing:** The file is readable offline (no external resources, < 200 KB, light/dark, phone width). The orchestrator publishes it as an artifact; df-llm-helper itself has no network access.

### 9.12 Chronicle and lessons: `python -m df_llm_helper journal` (spec 12)
- **At session end:**
  1. `python -m df_llm_helper journal ingest [--events <log> --date YYYY-MM-DD]`: take the watcher event log and critical df-llm-helper warnings into the `events` table. Combat and everyday noise is filtered, duplicate entries are detected, names are repaired (CP437).
  2. `journal chronik` shows the draft (date + fact, clustered per type in 30-min clusters). `--append` appends the lines that are not in `journal.chronik` yet (a repeated call adds nothing). `ingest` warns (exit 1) when no line of the file is in the watcher format (wrong file or encoding).
- **Lessons:** `journal lessons` lists patterns with at least 2 identical causes (e.g. `mood failed | wood`), each pattern exactly once. Approval via `--accept '<key>'` writes a KB draft to `data/kb/journal.jsonl`. Memory files stay manual work.
- **Metrics:** `journal metrics [--out runtime/metrics.csv]` outputs one line per game month, header like `metrics.csv`.
- **Downfall:** `journal postmortem [--out runtime/POSTMORTEM-runN.md]` generates the skeleton from `state.db`: timeline, causes of death, actions with outcome, open critical warnings, key figures, fair-play exceptions from the register. Add the assessment by hand.
- **Write boundary:** only the files from `journal.chronik|metrics|postmortem` and report files below the runtime folder (`runtime/`, or `DF_LLM_HELPER_HOME`); everything else is refused (project files such as `data/exceptions.jsonl` or `config.yaml` can never be overwritten). To write the player's `../metrics.csv` or `../POSTMORTEM-runN.md`, set `journal.metrics` / `journal.postmortem` in `config.yaml`.

## 10. v3 features (`specs-v3/`, not yet live-tested)
Access guard, dig checker, freeze profiler, standstill guard, tool manager, remote-worker protection, item hygiene, defense designer, settings, camera profiles, reachability guard: see **[manual-v3/README.md](manual-v3/README.md)** (one page per feature).
