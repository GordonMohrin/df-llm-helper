# dfpilot v2: Follow-up Specs from Run 5

Twelve specs for functions that the orchestrator performed by hand in Run 5 (01.10.2026) and that dfpilot can take over. Each spec contains goal and benefit with an estimated efficiency gain, the Run 5 as-is state, behavior, configuration, fair-play limits and testable acceptance criteria.

| No | Feature | Prio | File |
|---|---|---|---|
| 01 | Siege autopilot | P0 | [01-belagerungs-autopilot.md](01-belagerungs-autopilot.md) |
| 02 | Caravan autopilot | P0 | [02-karawanen-autopilot.md](02-karawanen-autopilot.md) |
| 03 | Mood manager | P0 | [03-stimmungs-manager.md](03-stimmungs-manager.md) |
| 04 | Hunger and hospital watchdog | P0 | [04-hunger-und-hospital-waechter.md](04-hunger-und-hospital-waechter.md) |
| 05 | Famine forecast | P1 | [05-hungersnot-prognose.md](05-hungersnot-prognose.md) |
| 06 | Utilization control | P1 | [06-auslastungs-steuerung.md](06-auslastungs-steuerung.md) |
| 07 | Shortage watchdog material/fuel | P1 | [07-engpass-waechter.md](07-engpass-waechter.md) |
| 08 | Water and flood watchdog | P1 | [08-wasser-und-flutwaechter.md](08-wasser-und-flutwaechter.md) |
| 09 | Restart and load runbook | P0 | [09-neustart-runbook.md](09-neustart-runbook.md) |
| 10 | Enforce subagent briefing, measure costs | P0 | [10-subagenten-briefing-erzwingen.md](10-subagenten-briefing-erzwingen.md) |
| 11 | Dashboard for the player | P2 | [11-dashboard.md](11-dashboard.md) |
| 12 | Chronicle and lessons writer | P2 | [12-chronik-und-lehren-schreiber.md](12-chronik-und-lehren-schreiber.md) |

## Recommended implementation order
1. **P0:** 01 Siege autopilot, 02 Caravan autopilot, 09 Restart runbook, 03 Mood manager, 04 Hunger/hospital watchdog, 10 Subagent briefing.
2. **P1:** 05, 06, 07, 08.
3. **P2:** 11, 12.

## Overall effect (estimate, not measured)
- Orchestrator: 25–35 % less consumption; measured so far approx. 37 % less per hour with M1–M3.
- Subagents: largest item (approx. half of the tokens); briefing and short reports bring an estimated 20–40 %.
- Game quality: fewer losses due to moods, care, hunger and water.

## Framework (applies to all specs in this folder)
- Code only under `dwarf-fortress/dfpilot/`, Python 3.12+, standard library only (plus pytest), no network access.
- Everything testable against `DFClient` (Real/Mock/Replay) and `Clock`; fixtures from Run 5 under `fixtures/run5/` or record anew (`--record`).
- Fair play remains technically enforced (exception register, linter). New exceptions only with the player's literal yes; standing permissions are in `CLAUDE.md` (e.g. stuck traders via `flags1.left`).
- Lua parts thin, marked as "not yet live-tested", with structure check (`tools/luacheck_min.py`).
- Every autopilot action is logged with its reason in `state.db`; loop protection (`max_per_hour`) is mandatory.
- Definition of Done per feature: self-test green (`python -m dfpilot.selftest`), new tests, `CHANGELOG.md` entry, section in `docs/MANUAL.md`.
- No `git push` by the development session; commits small, trailer as in the project.
