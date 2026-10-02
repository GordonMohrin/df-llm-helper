# BUG-420: hint - repo Lua and the live Lua in the game folder differ (paths, feature set, tuning); duplicates inside the repo

- **Status:** verified fixed (retest 2026-10-02, 8e67f05) [static code review; lua5.4 not available, mock not run]
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
- Decided (player delegated the decision): the repo is authoritative and the live copies may be overwritten from it. Port the live-only features where the evidence shows their code (`mil ammo`, `handel keep`, `erzdig spur`, `muell` zones, `zugaenge` MINCOMP), remove the duplicate pilot pair, add an install note.

## Fix
No code change possible without the player's decision. Both pilot_batch copies got the same fixes (596a890). Recommendation: install from the repo, keep tuning in `config.lua`, delete one of the duplicate pairs (`lua/pilot_batch.lua`+`lua/pilot_wd.lua` vs `lua/claude/...`), port the live-only features (mil ammo, handel keep, erzdig spur, muell zones, zugaenge MINCOMP - now `config.PERIMETER_MINCOMP` for pilot_perimeter).

Decision applied (4c66249), from `Bugs/evidence/BUG-420/diff_repo_vs_live_comments_stripped.txt`:
- `mil ammo <squad> [amount=25] [subtype=0] [--apply]`: ported 1:1 (dry run without `--apply`, argument check added).
- `handel keep`: the reserve rule now also holds in the trade window (`select`, new module function `keep_checker`); also ported the second "Trade" label search in `confirm` and the "Confirm trade" text in `accept`. Not ported: the live change of `accept` to `ok=false` when no dialog is open (no reason in the evidence; behaviour kept).
- `erzdig spur [ORE|GEMS] [zmin] [zmax] [max] [--dry]`: ported; the live hard-coded second anchor (99,94,130) became "walk group of any `config.FORT_REFS` point" (also used by the normal run). Path tiles must be discovered walls.
- `muell`: dump-zone counting (`auf_stapelpunkt_entsorgt`), `dump [N=150]` marks the corpses nearest to a reachable dump zone, skips the fort's own race (burial) and unreachable ones; additionally skips items already lying on the dump.
- `zugaenge`: enclave filter reads `config.PERIMETER_MINCOMP`; undiscovered tiles now count as not walkable (fair play).
- Small live fixes ported as well: `arbeit` does not give FISH back on restore, `SMOOTH_SUPPLY.no_engrave`; `material` usable-item filter; `mood` counts items in containers but not carried ones.
- Not ported: map tuning of the live copy (config values, material/mood targets, orders thresholds, Jewelers threshold) - tuning belongs in `config.lua`/state files of the player's map; `zugaenge_dbg.lua` (debug copy). Hard-coded live paths are replaced by `util.home()` in the repo anyway. Features that exist only in the repo (`schau profile`, `pilot_mood` held/mine, `killorder.lua`) reach the game by the install below.
- Duplicates: the client calls `claude/pilot_batch` / `claude/pilot_wd` (`df_llm_helper/transport.py`, runbook rb02); docs and tests use `lua/pilot_*.lua`, so `lua/claude/pilot_batch.lua` and `lua/claude/pilot_wd.lua` were deleted (test parametrisation and `docs/SPEC.md` updated).
- Install note (COMPANION.md, README.md): copy `lua/pilot_*.lua` and `lua/claude/*.lua` to `hack/scripts/claude/` and overwrite the live copies, also in any folder listed in `dfhack-config/script-paths.txt` (DFHack searches those first).
Tests: `test_mil_ammo_dry_and_apply`, `test_handel_keep_checker_holds_back_the_reserve`, `test_erzdig_spur_designates_a_short_tunnel_over_discovered_walls`, `test_muell_status_counts_dump_zone_items_separately`, `test_muell_dump_marks_nearest_reachable_corpses_only`, `test_zugaenge_enclave_filter_reads_perimeter_mincomp`, `test_pilot_duplicates_removed_from_lua_claude`.
