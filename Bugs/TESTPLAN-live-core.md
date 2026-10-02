# Live test plan - core commands (what the core tester could NOT verify without changing the game)

Only for Gordon / the local orchestrator, with the game running. Everything below is either a write action on the game or needs real events. Attach the output as evidence to the named bug.
Test state when written (2026-10-02 12:30): game paused, `pause.hold` = `alarm`, hostile thieves on the map, pop 174, `Y118 Granite 27`, services arbeit/trinken/ueberwacher/essen/orders/gesund/auslastung/material/migranten/schau **off**, watchdog + tempo **on**.

| # | Command (from the project folder) | Expected | Why only live | Bug |
|---|---|---|---|---|
| 1 | `python -m df_llm_helper waechter` (one step, paused game with `pause.hold`) | no output, exit 0, `tools/out/waechter.alive` refreshed, game stays paused (pause.hold exists -> no `advance run`) | the step sends `claude/advance`, `claude/alert on`, `claude/tempo suspend` and erases popups | BUG-106 |
| 2 | `python -m df_llm_helper check` (not `--dry-run`) | deletes stale `dig/migranten/notfall/wirtschaft/food/mood` flags (`dig.flag` 140 min, `food.flag` 135 min, ...); `service_restart` starts `arbeit`, `trinken`, `ueberwacher` (they are off) -> decide first whether you want that; `alert/siege.flag` stay (danger) | writes flags and starts game services | BUG-117 (D) |
| 3 | let `heartbeat.txt` age > 20 min, then `python -m df_llm_helper guard` | `set_fps=30 (DEADMAN ...)`; `claude/tempo status` shows `enabler_fps 30`; after `heartbeat` + `guard` fps back to 250 | writes `enabler.fps` | BUG-105/106 |
| 4 | `python -m df_llm_helper tempo on` | `Time lapse NOT switched on, blockers: danger, supplies, pop_gate_60, pop_gate_80`, exit 1 (this is safe to run: it refuses) | only meaningful with the real danger state | BUG-106 |
| 5 | `python -m df_llm_helper overlay --send` | up to 3 short lines appear in the game HUD (`claude/schau say`), a second call within 10 min sends nothing; **expected to be wrong today** (BUG-101: sends "No change since ...") | writes an in-game message | BUG-101 |
| 6 | start `python -m df_llm_helper wake --loop --interval 10` in a second terminal and wait for a real ambush/death | exactly one `WAKE` line per event, within 10 s, also when `tools/events.log` has more than 5000 lines (today 4326) | needs real events and a long-running process | BUG-100, BUG-116 |
| 7 | in the shell/process that runs the orchestrator: `python -c "import sys; print(sys.stdout.encoding)"` | `utf-8` (else `PYTHONUTF8=1` is missing: events with `☼` crash `wake`) | environment of the real orchestrator | BUG-112 |
| 8 | `python -m df_llm_helper --record equip.jsonl record "claude/mil equip"` (read-only) | one `ok` line; attach `equip.jsonl` (already recorded once in `Bugs/evidence/BUG-107/live_mil_equip_raw.txt`) | live data | BUG-107 |
| 9 | after a fix of BUG-105: let `claude/config` fail once (e.g. call `check` while a heavy script runs) and verify no `NEW GAME detected` line appears | no reset, `guard ack-gate` acknowledgements survive | needs a real timeout | BUG-105 |

Information the cloud session may want from Gordon
- BUG-104: the live `data/state.db` contains two mock snapshots (ids 1 and 4) and two mock rows in `kpis`; say if they should be deleted (the tester did not touch the database).
- BUG-116: which `events.log` tags should wake the orchestrator (statistics of the live log in `Bugs/evidence/BUG-116/live_events_log_tag_statistics.txt`).
- BUG-108: is "food days" meals+fish+meat (plants only for alcohol) or the game's `food_days` (incl. plants)?
