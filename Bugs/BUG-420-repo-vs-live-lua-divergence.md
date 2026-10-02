# BUG-420: hint - repo Lua and the live Lua in the game folder differ (paths, feature set, tuning); duplicates inside the repo

- **Status:** open (info needed)
- **Severity:** S3
- **Area:** `lua/claude/*.lua`, `lua/pilot_*.lua` vs `C:\Users\admin\claude gordons projects\dwarf-fortress\lua\claude` (the folder DFHack really uses: `dfhack-config/script-paths.txt` has `+C:\Users\admin\claude gordons projects\dwarf-fortress\lua`)
- **Reported:** 2026-10-02, commit `6dedd96`
- **Environment:** Windows 11 Pro, game running (DF 53.16 + DFHack, **paused**, date `27. Granite, Jahr 118`)

## Command / steps
`Bugs/evidence/BUG-420/compare_script.py` strips `--` comments and whitespace and diffs repo vs live; result in `diff_repo_vs_live_comments_stripped.txt`. (Mostly English-vs-German comment translations; those are ignored.)

## Result (code differences only)
- **Identical** (code-wise): advance, alert, area, bauhelp, buildings, cam, dig, felder, geo, kohle (hard path aside), ores, pilot_caravan, pilot_care, pilot_defense, pilot_digcheck, pilot_hygiene, pilot_perimeter, pilot_reach, pilot_remote, pilot_siege, pilot_tools, pilot_water, positions, probe, raster, schacht, stages, status, task, timer, trinken, workdetail (+ `pilot_batch`/`pilot_wd` in `lua/claude/`).
- **Live hard-codes absolute paths** instead of `reqscript('claude/util').home()`: aemter, auslastung, bauprog, config (`SCHACHT_OFFEN_FLAG`), essen, gefahr, gesund (+ `dfhack.getDFPath()..'/dfhack-config/blueprints/...'`), handel, material, migranten, mil (incl. `KILL_SCRIPT` = `<game>/tools/killorder.lua` instead of `<DF>/hack/scripts/claude/killorder.lua`), mood, orders, pickfix, report, schau, sperre, tempo, ueberwacher, watchdog. Live `util.lua` home() reads only `DFPILOT_HOME` (old name) with the fixed fallback `.../dwarf-fortress`; the repo version reads `DF_LLM_HELPER_HOME` first. **If the player only sets the new variable name from README/COMPANION.md, the live scripts ignore it.**
- **Live has features the repo lacks:** `mil ammo <squad> ...`; `handel` reserve rule (`keep_ok`) and a second "Trade" button search; `erzdig.spur()` and multi-anchor reachability; `muell` dump-zone counting (`auf_stapelpunkt_entsorgt`) and per-call limit 150; `zugaenge` enclave filter (`MINCOMP 3000`); `arbeit` FISH-labor guard and `SUP.no_engrave`; `material` usable-item filter.
- **Repo has features the live copy lacks:** `schau profile reload|default` (live answer: usage text without `profile`, `Bugs/evidence/BUG-420/schau_profile_missing_in_live.out.txt`); `pilot_mood need` "held/mine" accounting (live `pilot_mood.lua` is the older version); `lua/claude/killorder.lua` (not in the live script path - `claude/killorder` is not callable; live runs it via `lua -f tools/killorder.lua`); different default `config.lua` (live `TIMESTREAM=true/200`, SMOOTH_SUPPLY box, mood minimums `rohgem 12, schliffgem 10, holz 14, seide 3`, material targets `t1/t2 16/24`, orders `wood(14)`, `SMALLGEM 120`).
- **Live-only file:** `zugaenge_dbg.lua`.
- **Duplicates inside the repo:** `lua/pilot_batch.lua` and `lua/pilot_wd.lua` exist a second time as `lua/claude/pilot_batch.lua` / `lua/claude/pilot_wd.lua` with different message languages (German in `lua/claude/`, English in `lua/`). Both would be copied to the same target by the install step ("copy `lua/pilot_*.lua` and `lua/claude/*.lua` into `hack/scripts/claude/`") - the last copy wins. The live folder has the German `lua/claude/` variants.

## Expected
One source of truth: the repo is what the cloud session fixes, the live folder is what plays.

## Actual
Fixes made in the repo (e.g. BUG-401 fixes) will not reach the game unless the live files are replaced, and replacing them would drop the live-only tuning/features above.

## Evidence
`Bugs/evidence/BUG-420/diff_repo_vs_live_comments_stripped.txt`, `compare_script.py`, `report_for_game_date.out.txt`.

## Suggested fix (optional)
Decide per script which side wins; keep tuning values out of code (`config.lua`), delete the duplicate pilot files, install by copying the repo files (paths via `util.home()`).

## Info needed
- Player: please say which differences are intended (live-only features to port into the repo: `mil ammo`, `handel keep`, `erzdig spur`, `muell` zones, `zugaenge` MINCOMP) and whether the live copies may be overwritten from the repo.

## Fix
No code change possible without the player's decision. Both pilot_batch copies got the same fixes (596a890). Recommendation: install from the repo, keep tuning in `config.lua`, delete one of the duplicate pairs (`lua/pilot_batch.lua`+`lua/pilot_wd.lua` vs `lua/claude/...`), port the live-only features (mil ammo, handel keep, erzdig spur, muell zones, zugaenge MINCOMP - now `config.PERIMETER_MINCOMP` for pilot_perimeter).
