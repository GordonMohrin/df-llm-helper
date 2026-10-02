# Retest BUG-400 .. BUG-422 (Lua scripts), 2026-10-02, HEAD 8e67f05

Environment limits: **no Lua interpreter on this machine** (no lua5.4/luajit, no `lupa`, not in WSL Ubuntu, Docker engine
down), so `tests/lua_mock/claude_mock.lua` and the Lua tests in `tests/test_lua_claude.py` could not run (all skipped).
Nothing was installed or downloaded. Method per bug: the report's reproduction replayed as far as possible without Lua
(`client.is_write` calls, `df_llm_helper lint`, `tools/luacheck_min.py`, `perf status`), plus a line-by-line review of the
fixed Lua against the report's "Expected". Full suite `python -m pytest tests -q`: all passed (Lua mock tests skipped).
Live game untouched (no dfhack-run calls). Please rerun `python -m pytest tests/test_lua_claude.py -q` on a machine with
lua5.4 to turn the "static" verdicts into executed ones.

| Bug | Verdict | Note |
|---|---|---|
| 400 | fixed (static) | `util.emit` -> `prepare()` swaps non-integer numbers for placeholders, `num_text` uses `%.10g` + `,`->`.`, NaN/inf -> null; works inside arrays. Mock test with `MOCK_DECIMAL_COMMA=1` not run. |
| 401 | fixed (static) | `to_utf8` only converts byte runs >= 0x80 and leaves valid UTF-8 alone; `util.cut` cuts on character boundary. |
| 402 | fixed (static) | `sperre.configured()`, `status` returns `aktiv:false, kopf:{state:"n/a"}` without KOPF/KAV_BARRIEREN; schacht write cmds refuse. |
| 403 | fixed (static) | `find_text` returns `{}` for empty needle and advances `init = max(e,s)+1`; `cmd.scan` rejects blank text with `abort: scan <text>`. |
| 404 | fixed (static) | `dismiss_popups()` only in `run` and `<ticks>` branches; `clock`/`0`/invalid argument are pure. `is_write("claude/advance clock")` = False. |
| 405 | fixed, live check pending | `timer.start/arm` re-arm on remaining calendar ticks (rest//10 frames) and pause at the calendar target; needs the timestream run from the report. |
| 406 | verified fixed | Replayed: `trinken lager` WRITE, `trinken status` read, `bauprog/raster status` read, `mil tabelle --file/--say` WRITE, `advance clock` read. |
| 407 | fixed (static) | essen/arbeit/trinken/material/orders/ueberwacher: unknown word -> JSON `error`+`usage`, no round; erzdig without ore -> usage; `mil update`/`refuge` need `--apply` (rb04, scopes.yaml, gefahr, watchdog pass it); refuge keeps tiles when no rects. No-argument = one round documented (decided). |
| 408 | fixed (static) | `x0` without `y0` prints usage; w/h clamped >= 1; ints floored. |
| 409 | fixed (static) | digcheck/reach/water/perimeter: `math.tointeger` for all coordinates, `box outside the map`; reach `check` keeps 1:1 results + `invalid`, start outside -> ok:false; siege usage before squad lookup. |
| 410 | fixed (static) | felder/muell `else` branches emit JSON error+usage; COMPANION.md names the plain-text reports. |
| 411 | fixed (static) | kohle/raster/watchdog/ueberwacher use `isScheduled(KEY) and true or false` (real booleans). |
| 412 | fixed (static) | `status` calls `selbsttest()` before `scan()`; `sim` checks `df.unit.find`. |
| 413 | fixed (static) | `pilot_batch.lua`: BOM stripped, `cut_utf8`, unpack inside pcall, per-entry validation, `max_bytes` floored. Only `lua/pilot_batch.lua` remains (duplicate removed, BUG-420). |
| 414 | fixed (static) | `pilot_water scan` normalises/clamps box, cap 200000, `near` radius 0..10. |
| 415 | fixed, live check pending | `ores`/`geo` stop after `--budget` ms with `unvollstaendig`; `is_write` True for ores/geo/zugaenge/kohle run/erzdig (also `--dry`), replayed OK. Actual runtime needs the player's `Measure-Command`. |
| 416 | fixed (static) | `config aquifer [box]`, tempo usage, `append_daily_row` (once per game date), positions refused, `util.append_log` rotates at 1 MB (handel/mil/gefahr/pickfix). |
| 417 | fixed (static) | `to_utf8` no longer touches control characters (`\n`, `\t`). |
| 418 | verified fixed | `lint lua/claude lua/`: no duplicate lines (11 unique findings); exit 1 remains by decision (L07 needs local FP09 consent, message says how); bauprog/dig findings gone; remaining 10 L10 warnings are listed in docs/LINT-FINDINGS.md. `luacheck_min`: 62 files, 0 findings. |
| 419 | fixed (static) | grep of the hard-coded coordinates finds nothing; muell/sperre/zugaenge/kohle/geo/bauprog read config (`HINTER_SPERRE`, `BAU_PHASES_RUN3=false`); COMPANION.md has the "Optional scripts" table. |
| 420 | fixed (static) | `mil ammo`, `handel keep_checker`, `erzdig spur`, muell zones, zugaenge MINCOMP present; `lua/claude/pilot_batch.lua` / `pilot_wd.lua` deleted; install note in COMPANION.md. Player still has to copy the repo files into the live script path. |
| 421 | fixed, live check pending | Diagnostics only (stall.log, `perf status`, watchdog `timing`); `perf status` works and prints a stall line. Root cause still needs the next live stall. |
| 422 | fixed (static) | orders flag sets joined with `+`, gesund CSV handle closed, aemter names, siege visitors only when not invaders, report nil checks, logs rotate, compact `mood plan` / `gesund status|gedanken` / `pilot_tools status` with `--full`. |

Counts: 23 bugs, 0 reopened; 2 verified fixed by executed replay (406, 418), 18 fixed by static review only (Lua not runnable here), 3 fixed with live check pending (405, 415, 421).
