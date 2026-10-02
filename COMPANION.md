# Companion Lua scripts (`claude/*`) – what df-llm-helper expects

df-llm-helper talks to Dwarf Fortress only through `dfhack-run` and DFHack Lua scripts installed under
`hack/scripts/claude/`. Everything is bundled:

1. `lua/pilot_*.lua` – thin scripts written for df-llm-helper (siege, caravan, mood, care, water, work details, batching).
2. `lua/claude/*.lua` – the fortress toolkit the original project played with (`claude/status`, `claude/report`,
   watchdog, trade, military, mood, …). Comments are English; output keys and in-game texts are still German
   (df-llm-helper parses them, so they are part of the protocol).

Install: copy `lua/pilot_*.lua` and `lua/claude/*.lua` into `<Dwarf Fortress>/hack/scripts/claude/` and **overwrite the
live copies**. The repo is the single source of truth (BUG-420): live-only features were ported into it, so nothing is lost
by overwriting. If `dfhack-config/script-paths.txt` adds another folder with older `claude/*.lua` copies (DFHack searches
those first), overwrite the copies there as well or remove that line; otherwise the old scripts keep running. Each
`pilot_*` script exists once (in `lua/`), so the copy order does not matter. Tuning stays in `config.lua`.

**Fortress-specific values** live in `lua/claude/config.lua` (coordinates, burrows, interior boxes) and
`lua/claude/stages.lua` (dig stages). Both ship **neutral** (nil/empty); until you set them, safe defaults are derived
from the loaded map (`claude/config` lists what is still unset). Fill them in right after embark (checklist at the top
of `config.lua`). A complete real example from the original fortress is in `examples/windrings/` – reference only, do
not install it on another map. Own quickfort blueprints go to `dfhack-config/blueprints/claude/`.

**Shared folder:** set the environment variable `DF_LLM_HELPER_HOME` (system-wide, so DF sees it) to e.g.
`C:\df-llm-helper\runtime`. The Lua scripts write flags/logs below it (`util.home()`), df-llm-helper reads `<DF_LLM_HELPER_HOME>/tools`.
Without the variable the Lua side uses `<Dwarf Fortress>/df-llm-helper-runtime` and df-llm-helper `<df-llm-helper>/runtime` – so set it.

The exact output format of each command is the matching file in `fixtures/run5/` (real answers recorded in a live
game). Parsers are tolerant: missing fields are reported, not fatal.

Shared state between the scripts and df-llm-helper lives in `paths.tools` (default `runtime/`): `*.flag` files,
`events.log`, `out/`. All scripts print one JSON object (`util.emit`), except the plain-text reports `claude/area`,
`claude/mil report`, `claude/mil tabelle` and `claude/felder list` (errors of `felder` are JSON). `claude/report` also
appends one row to `<home>/metrics.csv`, at most once per in-game day: when the last row already has the same game date
(column `spieldatum`) nothing is written (field `metrics_zeile` says whether a row was added). `claude/ores`, `claude/geo`, `claude/zugaenge`,
`claude/kohle run` and `claude/erzdig` scan the whole map in the game's main thread (seconds): never poll them
(`ores`/`geo` stop after a time budget and say how to continue).

**No argument = one round.** `claude/essen`, `claude/trinken`, `claude/material`, `claude/arbeit`, `claude/orders` and
`claude/ueberwacher` called without an argument (or with `once`) run ONE work round immediately (they change the game;
`ueberwacher` only writes flag files). This is intended: the orchestrator, the watchdog and the scope agents call them
that way. The read-only command is `status` (`orders` also `list`; `arbeit` has none, use `claude/auslastung`); any other
word prints a usage error and changes nothing.

**Answer sizes.** Big per-citizen answers are compact by default; `--full` gives the old answer:
`claude/mood plan` (only at-risk mood skills), `claude/gesund status` (`buerger` only with stress >= LOW or at rest),
`claude/gesund gedanken` (15 most stressed citizens; aggregates complete), `claude/pilot_tools status` (no `name`).
No df-llm-helper parser reads the dropped fields.

**Optional scripts** (generic, but only meaningful once their config keys are set after embark; not called by
df-llm-helper on its own):

| Script | Used for | Needs config keys |
|---|---|---|
| `claude/muell` | marks corpses for the garbage dump, counts loose items | none (dump zones from the game) |
| `claude/kohle` | coal designations on maps without wood | `FORT_X`, `FORT_Y`, `DIG_MIN_Z` (+ `AQUIFER_CONFIRMED`), `SPERR_BOXEN` |
| `claude/bauprog` | standing construction programme | `Z_MIN`/`Z_MAX` + own phases in `state/bauprog_extra.lua`; run-3 phases only with `BAU_PHASES_RUN3 = true` |
| `claude/geo` | where rock/ore/aquifer layers lie (world geology) | `SURFACE_Z`/`Z_DOWN` (ceil default `Z_MIN - 1`) |
| `claude/zugaenge` | entrances into the fort, trap coverage | `FORT_REFS`, `Z_MIN`/`Z_MAX`, `PERIMETER_MINCOMP` |
| `claude/schacht` | cavern access behind a double wall barrier | `KAV_BARRIEREN`, `KAV_ORDER`, `KOPF`, `SPERR_BOXEN`, `SCHACHT_PRUEF`, `HINTER_SPERRE` |

| Command | Used by (df-llm-helper module / rule / runbook) | Reference answer |
|---|---|---|
| `claude/advance` | caravan, cli, client, maintenance, rb06_karawane, rb06b_karawane_absch | – |
| `claude/aemter` | client, curated, rb18_manager_buero, scopes | `fixtures/run5/aemter_status.txt` |
| `claude/alert` | rules, scopes, siege, waechter | – |
| `claude/arbeit` | client, curated, rb19_dienste_starten, scopes, services, workload | – |
| `claude/area` | cli, client, scopes | `fixtures/run5/area_z130.txt`, `fixtures/run5/area_z133.txt` |
| `claude/auslastung` | client, rb19_dienste_starten, scopes, services, workload | `fixtures/run5/auslastung_status.txt` |
| `claude/bauprog` | client | – |
| `claude/buildings` | cli, client, dashboard, rb20_fertigwaren_lager, scopes | `fixtures/run5/buildings.txt` |
| `claude/config` | client, config, guard, rb09_aquifer, scopes, services, snapshot | `fixtures/run5/config.txt` |
| `claude/dig` | lint, scopes | – |
| `claude/essen` | client, rb03_kochschleife, rb19_dienste_starten, scopes, services | `fixtures/run5/essen_status.txt` |
| `claude/gefahr` | client, config, digest, rb04_alarm_burrow, scopes, snapshot | `fixtures/run5/gefahr_status.txt` |
| `claude/geo` | client, scopes | – |
| `claude/gesund` | client, curated, rb08_hospital, rb19_dienste_starten, scopes, services | `fixtures/run5/gesund_krypta.txt` |
| `claude/handel` | caravan, cli, client, config, curated, rb06_karawane, rb06b_karawane_a | `fixtures/run5/handel_status.txt` |
| `claude/kohle` | services, workload | – |
| `claude/material` | bottleneck, produktion, rb17_koks_brennstoff, scopes, services, worklo | – |
| `claude/migranten` | client, services | `fixtures/run5/migranten_status.txt` |
| `claude/mil` | client, config, curated, rb01_e18_pick, rb01b_e18_foreign, rb04_alarm_ | `fixtures/run5/mil_report.txt`, `fixtures/run5/mil_tabelle.txt` |
| `claude/mood` | client, config, curated, moods, rb07_stimmung, scopes, snapshot | `fixtures/run5/mood_status.txt` |
| `claude/orders` | client, config, rb16_abbruchschleife, rb19_dienste_starten, scopes, se | `fixtures/run5/orders_status.txt` |
| `claude/ores` | client, scopes | – |
| `claude/pickfix` | workload | – |
| `claude/probe` | client | – |
| `claude/raster` | client, services, workload | – |
| `claude/report` | client, config, curated, digest, scopes, snapshot | `fixtures/run5/report.txt` |
| `claude/schau` | cli, overlay, rules, services | – |
| `claude/status` | cli, client, config, digest, moods, snapshot | `fixtures/run5/status.txt` |
| `claude/tempo` | cli, client, config, guard, rb07_stimmung, rb10_timestream, rb19_diens | `fixtures/run5/tempo_status.txt` |
| `claude/trinken` | client, curated, maintenance, rb19_dienste_starten, scopes, services | `fixtures/run5/trinken_status.txt` |
| `claude/ueberwacher` | client, rb19_dienste_starten, services | – |
| `claude/units` | client, config, rb15_hunger_trotz_essen, scopes, snapshot | `fixtures/run5/units.txt` |
| `claude/watchdog` | rb19_dienste_starten, services | – |
| `claude/workdetail` | client, config, rb02_grabstau, scopes, snapshot | `fixtures/run5/workdetail_list.txt` |
`claude/advance N|0|run|clock` (timer/pause), `claude/alert on|off` (civilian alert), `claude/schau say "<text>"`
(in-game message) have no fixture: they return `{"ok": true}`-style JSON; `advance clock` must contain `"paused"`.
