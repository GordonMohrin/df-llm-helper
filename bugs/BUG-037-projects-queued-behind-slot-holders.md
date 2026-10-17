# BUG-037 Projects stay 'queued' at 0 % for months behind slot holders that build nothing; terminal blocks never leave
Status: fixed in 5799e85 (offline, live-untested): slot holders without progress yield, a stuck seal competes like a stalled
project, a run watchdog, the seal-first count fault-contained, `sched.q/run/pk` and `queued behind <id>` rows, parked
projects (blocked for good past `queue.park_days`), `inspect workload` names the runner's queue. The live trigger
(y451, e11d17a) is a pacing starvation after one 68.6 s runner step: BUG-039, see "Live trigger".
Severity: high (wrong decision: six projects and a prio-2 trade depot never started for months, 15 of 27 adults idle,
the game session queued wood crafts as filler)
Found: 2026-10-17, Run 11 fort Kilrudrabed (site98), y449 spring d46, kernel 784399f, mode PEACE, ~39 citizens, from the
game session (`inspect workload`, `inspect projects`, `status`)
Module: `lua/dfllm/runner.lua` (`begin_run` pass rule, `progress` shared-miners rule, `focus`, `rows`, `M.step`),
`lua/dfllm/economy.lua` (`inspect workload`, idle rule)

## Actual
```
inspect workload  ->  15 of 27 adults without a job (15 without reachable work), 0 unclaimed jobs ...   (idle 55-80 % for weeks)
inspect projects (done=0): id tpl class prio stage chunk blocked pct created since
  c1a145d32caa7c6f06 farms     infra  1 1 1 build_lost          34 169944427 171082009   (y424, retries spent)
  y432s1b0           explore   infra  4 0 3 breach:cavern_lake   0 174504868 174510222   (y432)
  c1a14831718f432f01 bedrooms  living 4 1 0 ''                  25 179917933 179963069   (stage 1 since y446.3)
  c1a148317945f66101 stockroom infra  4 3 0 ''                  75 179918503 179967869   (burrow stage since y446.3)
  c1a1484d0449597801 bedrooms  living 4 0 0 ''                   0 180521312
  c1a1484d088187e701 tavern    living 4 0 0 ''                   0 180521442
  depot7             depot     infra  2 0 0 ''                   0 180853282             ('trade depot missing (caravan)')
  c1a14867db95857619 tombs     living 4 0 0 ''                   0 181083705
  c1a148696a3d6da701 seal      defense 4 0 0 ''                  0 181107462             (placed after the idle weeks)
status / brief    ->  c1a14831718f432f01 build 25% BLOCKED:queued, ... depot7 depot.build 0% BLOCKED:queued ...
kern.log          ->  only 'queued <id> ...' runner lines since y446; no 'seal first', no 'paused projects'; no sched
```

## Expected
At most three projects run at once, but a slot holder that builds nothing gives its slot to a waiting project; the
status says who holds the slots; a runner whose runs stop is visible at once and recovers; a project blocked for good is
moved out of the way and the player is asked once to cancel it.

## Cause
Proven offline (k_mock, `tests/lua/test_runner_queue.lua`, each test fails on 784399f):
1. **Seals held their slots for good** (`runner.lua` 784399f:3054): `(P.blocked == 'stalled' and not SEALS[P.tpl]) ==
   (pass == 2)` gave every open seal or plug a pass-1 slot, stalled or not; SEAL_STUCK (`focus`, :2300-2357; `paused`, :2359) only ended
   the pause, never the slot. Three seals whose doors nobody can make (each `seal at=last` closes at most six openings,
   so a fort gets several) held all three slots for good; the tombs and the depot (never paused) and, once the seals
   were stuck, every other project read 'queued'.
2. **A dig that digs nothing never stalls while another project digs** (`progress`, :401-413 (:408), the live L1b
   shared-miners rule `S.rt.dpt`): a dig stage whose designations nobody reaches kept its slot as long as any other
   dig progressed.
3. **A fault in the seal-first count stops every project** (`begin_run`, :3037-3041): `S.active = {}` is set before
   `focus()`; a throw there (or later in the pass loop) leaves the run without slots and tasks, and every later
   `rows()` (they run on `register`/`bp.place`, plan builds, trade's `depot_keep`, `bp.cancel`, REPORT and MODE, not
   only at a run's end) shows every allowed project 'queued', the prio-2 depot too, with no `sched`: the live picture.
4. **Nothing showed who held the slots or that runs had stopped.** `rows()` (:2425-2443) said 'queued' without a holder; a run that
   never ends (`M.step`, :3136: its continuation `ctx.cont` keeps the old `S.run` and the `S.active` of its `begin_run`) leaves every
   project registered later 'queued'; no state field, no log line, no watchdog.
5. **Projects blocked for good stayed in every count** (`exhausted` :2553, `keeper_on` :2585, `M.pending`, `depot_keep`, `focus`):
   the farms' `build_lost` (retries spent since y426) and the explore's `breach:cavern_lake` (since y432) kept
   PLAN_EXHAUSTED from ever firing, and would have kept the bedrooms/tombs keepers, care's coffins and the depot keeper
   waiting had they been of those templates; a seal blocked for good stayed in the seal-first state.

What the live data shows (reasoning, not proven): before the new seal (y449.17) no seal or plug was open, and depot7
(prio 2, never paused) would have taken a slot from the first run after y448.54; bedrooms1 and the stockroom (a burrow
stage completes in one quickfort call) have not moved since y446.3. So in the live game no `begin_run` reached its slot
pass after y448.54 and no work task ran after y446.3: the runner's runs stopped (a run that never ends, a module that is
paced or never due) or `begin_run` died before the slots (3). Causes 1, 2 and 5 are real, but are not what stopped
Run 11 at y449. A runner fault in `begin_run` would back the module off, and then `bp.place` and trade's
`depot_keep` would be refused ('module disabled'), yet both worked; so a run that never ends or a starving pace is the
likelier one. Reading found no task that yields for ever (`work`, `measure_dig`, `undo`, `check_task` all advance).

## Fix
- **Slots:** a slot holder whose own progress (`R.ps`: a chunk applied, manager orders made, measured progress, a stage
  done; waiting for a slot, frozen or paused resets it, holding one does not) is `queue.yield_days` (7) old competes with
  the stalled projects for the slots left over; a seal or plug keeps its pass-1 slot only until it is stuck
  (`seal_first.stuck_days`), then it is treated like a stalled project (still measured, done once its pieces stand).
- **Visibility:** rows `queued behind <first holder> +2`, `no progress 9 d: slot yielded`, parked rows last; state
  `sched.q` `{n, by = [[id, tpl, days without own progress]]}`, `sched.run` `{d, i, n, task, sl, age}` once no run ended
  for `run_idle_d` (3) days, `sched.pk`; status/brief `queued: 6 behind c1a148696a3d6da701 seal, depot7 depot 9 d no
  progress, ...`, `runner: no run ended for 30 d (task 2/9 work ..., 900 slices): dfllm doctor, inspect modules`.
- **Watchdog:** a task that yields `task_slices` (600) slices in a row is skipped for that run (kern.log `runner
  watchdog: task i/n (...) yielded N slices in a row: skipped this run`); the next run goes on from where it was.
- **Containment:** a fault in the seal-first/rebuild count leaves that run without them (kern.log `seal first/rebuild
  failed, this run without them: <error>`, once per message); slots and work go on.
- **Parked** (`queue.park_days`, 30): `build_lost` with the retries spent, `breach:*`, `apply_fail`, `bp_missing`,
  `plug_refused`: no longer counted by the seal-first pause and state, `runner.pending`, the bedrooms/tombs keepers, the
  depot keeper and PLAN_EXHAUSTED; PROJECT_BLOCKED (A) once, `d.park`, msg `<id> (<tpl>) blocked 30 d: build_lost at
  build; parked; cancel: dfllm cmd bp.cancel '{"proj":"<id>"}' (no undo: what it built stays)`; wake `next:` asks the
  player first. **Never cancelled by the kernel:** an undo removes built work, an explore stays in the audit box and its
  shaft in the shaft check, its breach undo already removed its designations.
- **Workload:** `inspect workload` and the idle rule's `useful backlog empty` line end with `runner.queue()`'s clause
  (`; runner: 6 projects queued behind 3 slot holders without progress (...)`, `; runner: no run ended for N days (at
  task i/n ...), N projects wait`), data `runner`.
- Config: `config/baseline.json` `runner.queue {yield_days 7 (1-60), park_days 30 (1-400)}` (`fairplay.RUNNER_LIM`).

## Live data that decides it (read-only)
1. `dfllm cmd inspect '{"what":"modules"}'`: the runner entry (`disabled`, `backoff_s`, `faults`, `factor`, `paced`,
   `debt`, `share`, `ms`, `svc`).
2. `dfllm doctor`: the runner's ms/s and `top cost`.
3. kern.log since y446: every line with module `runner` (`grep -P '\trunner\t' kern.log`), above all `error`
   (`step: ...`); kern lines `runner paced`, `runner demoted`, `runner backed off`, `runner promoted`.
4. `dfllm events --type KERN_FAULT` and `--type KERNEL_SLOW` (`d.module` runner).
5. commands.log: the runner's last `act.quickfort` lines and their ticks (when did it last apply anything).
6. `dfllm cmd inspect '{"what":"persist","key":"m.runner"}'`: `p.<id>` of c1a14831718f432f01, c1a148317945f66101 and
   depot7 (`si`, `prog`, `last`, `mt`, `fail`, `of`, `oc`, `undo`), `sf`, `pz`, `cav`/`xs` of y432s1b0.
7. With this kernel: `dfllm status` (`runner: no run ended for N d (task i/n <task>, S slices)` names the stuck task;
   `queued: N behind <holders>`), kern.log `runner watchdog:` / `seal first/rebuild failed`.

## Live trigger (Run 11, y451 winter d63, kernel e11d17a; BUG-039)
After the reload to e11d17a the projects ran at once (seal first, `build: N manager orders` for both bedrooms, the
tavern and the tombs) and left the open list within ~20 days; then `inspect workload` said `runner: no run ended for 49
days (at task 1/3 work y451s3b0, 1 slices)`, `inspect modules` runner `debt 67760`, kern.log `runner demoted x4 (68603
ms)`, `frame gap 68640 ms (blame runner)`. **Proven offline (BUG-039, `tests/lua/test_kern_pacing.lua`): one 68.6 s
runner step left a pacing debt that drains at 2-4 ms per real second, so the run in hand got no slice for hours (15-30
game years at 450 ticks/s); the watchdog here counts slices that run, so it never fired.** The 68 s were most likely
quickfort placing the stockroom's three food stockpiles (DFHack's stockpiles import, O(N^2) in the world's organic
materials; BUG-039 cause 2). The same mechanism fits this bug's first picture (no work since y446.3, when the stockroom
c1a148317945f66101 reached its place and burrow stages): a long freeze there leaves a debt that takes real hours, years
of game time, to drain; unproven until commands.log shows that call's `ms`. Fix: BUG-039 (debt cap, pacing floor, the
huge step named). Causes 1-5 above are real but were not the live trigger.

## Tests
`tests/lua/test_runner_queue.lua` (three stuck seals, the yielding dig, parked projects, the seal-first fault, the
watchdog, `sched.run` of a paced run), `tests/lua/test_economy_jobs.lua` (the workload and idle clause),
`tests/test_runner_queue.py` (state, status, event, wake hint, config, RULES); each fails on 784399f.

Related: BUG-022 (build_lost retries), BUG-033 (pacing, the shaft check), Run 11 siege 8 seal first (346c4ff, 069bb61)
