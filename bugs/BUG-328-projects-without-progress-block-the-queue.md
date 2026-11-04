# BUG-328 Projects without progress hang for years and block the queue
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-04, Run 15c Inkintense (FR-BUGS y377-y378), Run 15d Drillchamber (y374-y377), Run 15b Earthboat (y373-y384)
Module: `lua/dfllm/aqshaft.lua` (dig_step), `lua/dfllm/runner.lua` (M.step watchdog, begin_run slots, Q.idle_scan, rows,
state, verb bp.resume), contract/schema/fairplay/brief/wake

## Actual
- Inkintense y377: aqshaft c1a188aab2c273bc01, then c1a188b5f1ae45b201 `l0.dig 0 %`, `runner: no run ended for 62 d, 97
  slices` / `176 d, 78 slices`, `runner demoted x8 (20-52 ms in work c1a188b5f1ae45b201 l0.dig)`; the seal queued at the same time
  stood `BLOCKED:queued` although seal first; the farm and the y377 digs `slot yielded`. kern.log: queued at tick 151981511,
  `runner watchdog: task 1/6 (work c1a188b5f1ae45b201) yielded 600 slices in a row` at 152140790 (132 game days). Only a
  `bp.cancel` of the shaft let the seal run.
- Inkintense y374-y378: seal y374s0b0 `seal.build 0 % BLOCKED:stalled` for 900-1399 days, the farm `queued behind y374s0b0`.
- Drillchamber: seal hatch 89,72,137 never built since y374 (job 10421, later 24715, 339 d); Earthboat: refuge hatch 55,82,133
  never built (job 8095, y373-y384).

## Root cause
1. `lua/dfllm/aqshaft.lua:204-205` (9b6f614): `dig_step` designates the level's tile; when quickfort designated nothing (the call
   returns false) the slice's one quickfort call is used up, so `X.room()` is false and the step returns `yield`. The next slice
   makes the same refused call: the task yields every slice for ever. A paced, demoted runner gets a few slices a game day.
2. `lua/dfllm/runner.lua:5000` (M.step): the watchdog skipped a task only after `task_slices` (600) slices in a row, whatever
   the game time: 600 slices took 132 game days, and no new run (no new slots, no seal first) began meanwhile.
3. `lua/dfllm/runner.lua:4846-4853` (begin_run `second`): a stuck seal and a stalled project go to pass 2 and take the slots
   left over in list order, however long they made no progress: the 1,000-day seal won the slot before every later project of
   pass 2 for ever. Only projects blocked for good (build_lost with its retries spent, breach, apply_fail ...) were parked.

## Fix
1. aqshaft `dig_step`: a refused designation never yields. A tile open already (no wall left) or designated already goes on
   as designated (kern.log `nothing more to designate, the level goes on`); else the refusal counts (`L.nd`, kern.log `quickfort
   designated nothing at x,y,z (tile c, refused n/3)`) and the task is done for this run; `refuse_max` (3) refusals block the
   shaft `apply_fail` (parked after park_days with its bp.cancel command, BUG-037).
2. Watchdog by game time: a task yielding for `task_days` (3) game days is skipped too (`... yielded N slices in a row (3
   days): skipped this run`).
3. Set aside: a project (not done, not blocked for good) whose own progress `R.ps` is `queue.idle_days` (30, config/baseline.json
   `runner.queue.idle_days`, 1..400) old in PEACE gets no runner slot any more (measured every meas_every like a stalled one, so
   a piece DF's builders finish is noticed). kern.log + PROJECT_BLOCKED (A) `... stalled 30 d at seal.build 0%: set aside, no
   runner slot (the others go first); resume: dfllm cmd bp.resume '{"proj":"..."}'; cancel: ...`, `d.idle` = days (`d.parts`:
   what it waits for); its row last `set aside N d: stalled (bp.resume)` (no word `parked`: plan.py reads that as blocked for
   good); state `sched.ip` {n, by}; status/brief `set aside (no progress): N: <id> <tpl> <d> d, ...; resume: dfllm cmd bp.resume
   proj=<id> or bp.cancel`; wake hint. It comes back by itself when its progress moves (a measure, the seal fallback's re-place or
   wall: `moved`), when its stage changes, or by the new verb `bp.resume {proj}` (a fresh idle_days). Never set aside: a mood
   project, the hospital care first leads, an aqshaft watching an open level. A stuck seal set aside keeps its seal-first
   record (it already paused nobody), so SEAL_STUCK, the burrow widening, the re-place and the wall fallback go on.
4. `bp.cancel` and its DF jobs: done by BUG-314 (a plain cancel removes the unbuilt pieces of the current build stage with their
   jobs); Drillchamber's y377 note (job 24715 new) shows it worked live. Unchanged here.

## Tests
`tests/lua/test_bug328_329_projects.lua` (5 BUG-328 cases), `tests/test_bug328_329_projects.py`; all fail on 9b6f614.
Adjusted: `tests/lua/test_runner_queue.lua` (watchdog line names the days), `tests/lua/test_runner.lua` and
`tests/lua/test_runner_seal_door.lua` (count PROJECT_BLOCKED without `d.idle`: their 84 / 144 game days set the stalled project
aside), `tests/test_runner_queue.py` (config queue).

## Live check
Inkintense after a kernel reload: an aqshaft whose top refuses names it in kern.log once a run, no `no run ended` line; status
`set aside (no progress): ...` for projects 30+ days without progress, their rows last; the farm/digs behind them get slots;
`dfllm cmd bp.resume proj=<id>` answers `resumed <id>`. Uncertain: whether 30 days is right for slow builds (a big stockpile room
waiting for stone): it only loses its slot, a measure still sees progress.
