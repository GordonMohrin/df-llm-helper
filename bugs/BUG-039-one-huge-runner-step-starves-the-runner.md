# BUG-039 One 68.6 s runner step left the runner without a slice for 49+ game days; the cavern check logged the same line every run
Status: fixed in 3e2d39c (offline, live-untested): the pacing debt is capped and a due module gets a slice after 30 s
whatever its debt (pacing floor); a step of 1 s or more is named in kern.log (what the module did, its slowest act call);
KERNEL_SLOW names the task; the shaft check converges (finished unchanged shafts wait longer while it is saturated) and
logs only news; kern.log names every project that is done or cancelled; `inspect persist` reads one field.
Severity: high (wrong decision: every project waited for 49+ game days, 15 of 27 adults idle; DF froze 68 s)
Found: 2026-10-17, Run 11 fort Kilrudrabed (site98), y451 winter d63, kernel e11d17a, PEACE, 293 units, from the game
session (`inspect workload`, `inspect modules`, kern.log), read-only
Module: `lua/dfllm/util/sched.lua` (`spend`, `paced`), `lua/dfllm/kern.lua` (frame loop, `call_in`, `charge`),
`lua/dfllm/runner.lua` (`shaft_prep`, `shaft_one`, `shaft_trim`, `check_task`)

## Actual
```
inspect workload  -> ...; runner: no run ended for 49 days (at task 1/3 work y451s3b0, 1 slices), 0 projects wait
inspect modules   -> runner {debt 67760, demotions 2, factor 4, ms 69424, paced 78381, share 4, svc 38}
kern.log          -> 182157789 runner: y451s3b0 build: 2 manager orders, 2 items
                     182164588 kern: runner demoted x4 (68603 ms; ...)
                     182164589 warn kern: frame gap 68640 ms (blame runner)
                     182164589 warn selftest: selftest quick failed: state_fresh, budget (635 ms/s > 31 ... top runner 623)
heartbeat         -> 59 s old, DF 'Process Responding=False' for ~60 s, then normal
kern.log (d782dfa and e11d17a) -> nearly only 'cavern check: y433s3b0 116,129 ... no cavern; ...; 11 more next run',
                     the same four groups again and again
```

## Expected
A module that once costs a lot waits a bounded time, not hours; a run in hand always gets slices; a huge step is
named with what it did; the daily shaft check keeps up or says why, and does not repeat the same line every run.

## Cause
1. **Proven offline: one huge step starves a paced module for hours** (`util/sched.lua` e11d17a:110-136). `spend` added
   every ms to the module's debt without a bound; `paced` lets a module run only while its debt is at most one second of
   its share, and the debt drains at the share (runner 4 ms/s, halved by the PEACE pool's g). A 68,603 ms step left
   ~68,600 ms of debt: about 17,000-34,000 s (4.8-9.5 h) real time before the next slice; at ~450 ticks/s that is 15-30
   game years. The run in hand (`work y451s3b0`, task 1/3) was due every frame and paced every frame (`paced 78381`), so
   `run.sl` stayed 1 and the BUG-037 watchdog (it counts slices that run) never fired. `note_paced` logs only the first
   paced frame of a boot, so nothing said it. `tests/lua/test_kern_pacing.lua` "BUG-039 live" (the real kernel, a runner
   stand-in whose second run's first slice costs 68.6 s): on e11d17a no further slice within 31 s (the old math: ~17,000
   s); now the next slice comes within 30 s and the runs go on.
2. **Probable, not proven: what took 68 s** (DFHack, not dfllm code). The slice was the first of a run: `begin_run`, then
   `work y451s3b0`. y451s3b0 is a stockroom with a still: stages dig, build (door, still: the '2 manager orders' line),
   place (three food stockpiles in one chunk), burrow. Five runs measured the build stage cheaply; then the build stood,
   `stage_done`, and the same slice applied the place chunk: one `quickfort place` call with three `f` cells. quickfort
   `configure_stockpile` (`internal/quickfort/place.lua:256-260`) runs `stockpiles.import_settings('library/cat_food',
   {mode='enable'})` per pile; for each food sub-list in 'all' mode `unserialize_list_organic_mat`
   (`plugins/stockpiles/StockpileSerializer.cpp:479-484`) calls `OrganicMatLookup::food_mat_by_idx` per element, which
   copies the whole `world.raws.mat_table` by value (`OrganicMatLookup.cpp:28`, `df::special_mat_table table =
   raws.mat_table;`): O(N^2) in the organic materials, and a 451-year-old world has a great many (generated creatures).
   Every other step of that slice is bounded (one quickfort call, `probe` 300 tile reads). The decisive read-only check is
   below; the new kernel names it directly.
3. **Proven offline: the shaft check could not keep up and said so every run** (`runner.lua` e11d17a:1961-2084). The
   runner ran every 4,800+ ticks (demoted x8, paced). Each `cavern check:` line ends one run (`S.chk` is reset only by
   `begin_run`, the check's end and the e11d17a watchdog), so lines 30-50 apart are back-to-back runs; kern.log's first
   column is the wall clock in seconds, its second the tick: 30-50 s apart fits a paced run, 30-50 ticks does not.
   15 finished shafts were due daily, a run looks at `shaft_n` (4), so every
   run had 11-12 due and rotated through the same groups by the oldest look, and logged the full line with `N more next
   run`. The trim (`shaft_trim`, ranks 0/1 first) also dropped the record of a done explore still in the project list; the
   next run noted it again (no last look: due at once). `tests/lua/test_runner_load.lua` "BUG-039 live" (15 finished dry
   shafts, runs 4 days apart: on e11d17a `12 more next run` in every one of 14 lines, the same groups rotating) and "the
   trim keeps the record of a done explore".
4. **Checked: the check did not starve the work tasks by order** (work tasks come first in a run, the check after them),
   but its slices are paced like the rest: up to `shaft_n` + 1 slices of a run's pacing budget. It stays bounded at
   that.
5. **Not reproduced: 'p has only 3 entries' and 'm.runner has no p key'.** Every path that removes `S.rt.p[id]` also
   leaves the list (`finish`: done = 1, PROJECT_DONE; `remove`: bp.cancel or depot_move) or replaces it (`R_of`, a stage
   change, a retry); every `begin_run` gives each open, unhalted project a slot (R_of in its work task) or `R_of` in the
   else branch; nothing else writes persist `projects` or `m.runner` (owner checks), `init` keeps both. An `inspect
   persist` reply over 8 KB is `{trunc: 1, bytes}` (kern `reply`), which reads as 'no p key'; m.runner (keep boxes, xs,
   skip, rty, cadence records) is near that size. The projects that left the list after the reload most likely finished:
   a depot stands at 114,84,142, 251 beds; a done project emits PROJECT_DONE (B) but wrote no kern.log line, and
   `dfllm events` shows the newest 30 matches unless `--limit 0`.

## Fix
- **sched (kern and k_mock):** `spend` caps the debt at `PACE.debt_cap_s` (30) seconds of the module's share (boosted: of
  its boost share; runner 120 ms); `paced` returns `false, 'floor'` once a due module waited `PACE.floor_ms` (30 s real
  time) whatever its debt (`e.floor_n`). kern.log `runner waited 30 s for a slice with its run in hand (debt N ms over its
  share of 4 ms/s): one slice anyway (pacing floor, N so far)` once per module per 10 min; `inspect modules` `floor`.
- **kern:** a call of `KERN.big_ms` (1 s) or more: kern.log `runner step took 68603 ms (work y451s3b0 place chunk 1/1
  (task 1/3, slice 1); slowest act: quickfort place 68590 ms); debt capped at 120 ms (30 s of its share)`; `inspect
  modules` `big {ms, what, ago_s}`. A slow step's demotion and KERNEL_SLOW name the task (`runner demoted x4 (68603 ms in
  work y451s3b0 ...)`, `d.task`). Act calls are timed on the kernel's cost clock. `inspect persist` takes `field` (one
  top-level field: `{"what":"persist","key":"m.runner","field":"p"}`); a reply over 8 KB says so in its msg.
- **runner:** `M.doing()` names the slice (`work <id> <stage> chunk i/n (task i/n, slice s)`, `begin run`, `check`, `end`);
  kern.log `<id> (<tpl>) done` and `<id> (<tpl>) cancelled at stage N: removed from the list`.
- **shaft check:** the never seen first, then live explores, then the oldest look; while more are due than a run looks
  at, a finished shaft whose look did not change (`xs.sg`, a signature without numbers) waits `per` days: 8, doubled per
  unchanged look, at most `fin_max_d` 64; a change is daily again (wet: 8). The line names only news (`...; 3 unchanged;
  2 more next run`); without news `cavern check: nothing new (N looked at, M shafts watched)` at most once per
  util/cadence (7 days and 10 min, again only after news). The stopped-dig recheck lines likewise (`br.sg`). The trim
  keeps a done explore still in the list and never notes a dropped record again that boot.
- Not changed: the food stockpile import itself (a DFHack call; one per pile). Proposal: set a food pile's settings
  without the stockpiles plugin's 'all' import, or one pile per quickfort call; first confirm the cost live.

## Live data that decides it (read-only)
1. commands.log near tick 182164588: the runner's `act.quickfort` line with `"mode":"place"` and its `"ms"` (68,000 =
   cause 2 confirmed); events `PROJECT_STAGE` y451s3b0 `build done` at the same tick.
2. The earlier stockroom c1a148317945f66101: its place call's `ms` in commands.log (y446.3; another long freeze there
   would also explain BUG-037's 'no work since y446.3').
3. `dfllm events --type PROJECT_DONE,PROJECT_STAGE --since 17000 --limit 0` for the ids that left the list; `ls
   <save>/bp/.cancelled/` (a bp.cancel moves the file there); commands.log `verb:bp.cancel`.
4. With this kernel: `dfllm cmd inspect '{"what":"persist","key":"m.runner","field":"p"}'`; `inspect modules` runner
   `debt` (≤ 120 ms), `floor`, `big`; kern.log `runner step took ...`, `pacing floor`; status no longer `runner: no run
   ended for N d` beyond a day; `cavern check:` lines only on news.

## Tests
`tests/lua/test_kern_pacing.lua` (the 68.6 s step on the real kernel, the cap and the floor, KERNEL_SLOW `task`; all
fail on e11d17a), `tests/lua/test_runner_load.lua` "BUG-039 live" (15 finished shafts, runs 4 days apart), "the trim
keeps the record", "the runner names what a slice does" (the first two fail on e11d17a); adjusted: `test_runner_shaft`
(an unchanged look is counted, not named again), `test_runner_load` (a dry finished shaft's daily looks counted on the
record).

Related: BUG-037 (projects queued; its live trigger), BUG-033 (pacing, the shaft check), BUG-026 (boost), FR-62 (pacing)
