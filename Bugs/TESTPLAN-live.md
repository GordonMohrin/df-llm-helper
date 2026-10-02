# Live test plan (needs a running Dwarf Fortress + DFHack)

Run from the project folder with the game running and `config.yaml` pointing at `dfhack-run.exe`.
Each line: command -> expected result. Anything else is a bug (see `Bugs/README.md`). Read-only or `--dry-run` only.

(filled in by the test run; see `Bugs/LIVE-RESULTS.md` for what was verified when.)

## Autopilots (v2/v3) - checks that need time running (from the autopilot test run, BUG-200..220)
Run in peacetime unless stated; attach the output under `Bugs/evidence/<BUG>/`.
| Command | Needs | Expected | Related |
|---|---|---|---|
| `python -m df_llm_helper caravan --dry-run` twice after a finished trade (caravan still on the map) | next caravan | no `[dry] claude/advance run`, no second `Trade completed` | BUG-200 |
| `python -m df_llm_helper trade reset; python -m df_llm_helper trade step` at the next arrival | next caravan | PAUSE -> SAVE -> ... -> REVIEW, `trade approve` then also moves `caravan` | BUG-201, 202 |
| `python -m df_llm_helper siege --once -v` | real attackers (isInvader) | kill order only for invaders, `claude/pilot_siege status` -> `orders: 0` afterwards | BUG-219 |
| `python -m df_llm_helper mood` while a real mood is running | strange mood | demand matches the workshop job; `claude/pilot_mood need <id>` raw answer attached | BUG-220 |
| `python -m df_llm_helper perf sample` with `claude/raster start` running | time running | outliers (> 1.5 s) with period; then `perf bisect --dry-run` | BUG-220 |
| `python -m df_llm_helper water watch` when the fort box really has water | flood | `wasser.flag` + an emergency wall that is on the fort side of the front | BUG-206 |
| `python -m df_llm_helper hygiene` after `FORT_REFS[1]` was moved inside the fort | config change | `areas: fort=...` > 0, `mark` dry run lists candidates | BUG-210 |
| `python -m df_llm_helper defense stats --tail 2000` during/after an attack | attack | trap/attack counts match the gamelog lines you read | BUG-211 |
| `python -m df_llm_helper reach` after correcting `data/reach.yaml` | player edit | `Reachable: 7/7 mandatory points` | BUG-209 |
