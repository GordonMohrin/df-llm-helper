# BUG-033 The snapshot export queue stays full for months; the runner costs 35 ms/s in PEACE
Status: fixed in bfad790 (offline, live-untested): a K.call is the caller's cost; the snapshot queue (who asked, joins, inbox
requests first and boosted, age/stall/fault drops, a capped busy wait, a refusal that names the queue, state `snap`);
readiness' monthly audit waits for its pending snapshot; the runner's shaft check sliced and cheaper; doctor/status name
a starving queue and the top cost owner
Severity: high (wrong decision: readiness stood at `audit_old` for 4.5 years, `plan check` ran on a stale snapshot and
planned no explore while the fort had no iron and 0 bars; every `dfllm audit` and `bp sites --fresh` failed)
Found: 2026-10-17, Run 11 fort Kilrudrabed (site98), y438 winter, kernel e3a62ab, from the game session
Module: `lua/dfllm/kern.lua` (`K.call` -> `call_in`: the callee was booked and paced), `lua/dfllm/util/sched.lua`
(pacing), `lua/dfllm/snapshot.lua` (`export`, `step`), `lua/dfllm/readiness.lua` (`request_audit`),
`lua/dfllm/runner.lua` (`shaft_check`, `file_doc`, `opened_at`)

## Actual
```
dfllm bp sites <tpl> --fresh --timeout 150   ->  no snapshot c... within 150s          (for months)
dfllm audit                                  ->  audit: snapshot refused: export queue full
dfllm status / ready.fail                    ->  audit_old (the last audit 4.5 years old)
dfllm doctor (PEACE)                         ->  kernel 54 ms/s avg, runner 35 ms/s, max 447 ms (limit 25), frame gap 21 s
dfllm plan check                             ->  explore: only 0 free site(s)   (a stale sites snapshot)
```

## Expected
An export that someone waits for is written within a minute; the queue never holds requests nobody waits for; a refusal
says who holds the queue; the runner stays within its pacing share in PEACE.

## Who asks for exports (all paths)
- readiness: `purpose audit`, the manifest box plus the running projects' boxes, monthly (`AUDIT_EVERY` 33,600 ticks,
  about 75 s real time at 450 ticks/s) and after every defense stage (at least a day apart), in quiet modes.
- economy (glass chain, Run 11): one `purpose debug` export per boot while `snapshot.sand()` has seen none.
- Python through the inbox verb `snapshot`: `dfllm audit` (`aud*` ids, waits 60 s), `dfllm bp sites --fresh` (waits
  `--timeout`), follow's automatic placements (`sites`, waits 60 s), the LLM's `dfllm cmd snapshot`.
- Not exporters but heavy queries of the snapshot module: `snapshot.tile` (runner probes, seal pieces, gather zone,
  economy, military, care), `snapshot.liquids` (runner's breach test and daily shaft check, economy's fishing search
  over up to 97 x 97 x 6 tiles, water's scan), `snapshot.far` (economy's census: once per food and drink item),
  `outside_near`, `units_at`, `items_at`, `groups`.

## Cause
1. **Proven offline: the queries starved the exports.** kern booked every `K.call` to the CALLEE: the time of
   `snapshot.tile/liquids/far` went to snapshot's pacing debt (FR-62), never to the module that asked. An export only
   progresses in snapshot's own `'more'` slices, and those wait while its debt is over one second of its share (6 ms/s,
   halved in the PEACE pool). Once the other modules' queries cost about as much as that share, the debt never drained
   and the running export never got another slice. `tests/lua/test_snapshot_queue.lua` "BUG-033 live": 1,500 tile reads
   per runner run (5 us each) keep an 81,920-tile export from finishing for 10 minutes on the old kernel; it finishes in
   about a minute now. The callers in turn were never paced for those reads (the runner's own entry left them out).
2. **Proven offline: nothing ever left the queue.** No age limit, no dedup by purpose or box, FIFO, no priority: readiness
   added a new audit request every game month (about 75 s real time) whether its last one was exported or not, so a
   stalled queue filled to 4 + 1 within minutes and refused everything after it (`export queue full`, no hint who held
   it). A `--fresh` request accepted before the queue filled waited behind the stalled export forever.
3. **Checked, not the cause: trade's busy boost (BUG-026).** It is renewed only in trade-screen phases, lapses after 30 s
   without renewal, ends at LEAVE/IDLE, on a mode change and on a back-off. Now an export waits for it at most 3 min.
4. **Possible, not observed: a faulting export.** A slice that errored left the export in place; three faults backed the
   module off for 10 min, then the same export faulted again. Now dropped after 2 failed slices.
5. **The runner's cost (suspected for the live 35 ms/s; measured offline as work, not DF time).** The daily shaft check
   (8cc2e8e) after every boot decoded each bp file of the fort, every non-explore twice (`note_shaft` read it again when
   `file_doc` returned nil), 8 files a run, in one slice with up to 4 shaft looks; every look at a finished explore
   decoded its bp file again; each wet candidate tile read a 25 x 25 x 3 water box (also for a pocket of seepage); and
   with more shafts than `shaft_n` x 2 a day the check was saturated (`N more next run`). Offline model (12 finished
   explores beside seepage, `tests/lua/test_runner_load.lua`): 16,064 tile and water reads a day before, 1,970 now;
   the bp folder after a boot: each non-explore file decoded twice before, never now. `own_tiles` was rebuilt for every
   damp report and breach test; `M.remake` read every cell of a seal stage before it checked its budget. Pacing bounds
   the runner's steps to its share, so a sustained 35 ms/s must also include work outside its steps (its persist
   records, its handlers, the calls of others into it); kern.log now names site-data records of 64 KB or more, and
   `inspect persist` lists the sizes.

## Fix
- **kern (`K.call`):** a call from one module into another is the caller's cost: its time stays in the caller's step
  (booked and paced there; a slow call is judged on the module's own code, so it demotes neither side, and the slow
  messages name the callee); the callee's part is kept as the edge `caller>callee` (perf.csv
  `mods`, `inspect what=modules` `svc`, state `k.top` = `runner 35 (snapshot 20)`); faults still count against the
  callee; a call from kern itself (inspect) stays with the callee.
- **snapshot queue:** every request names who asked (`by`; inbox requests `inbox:<by>`). Inbox requests go ahead of the
  kernel's own (a running kernel export waits at its row and resumes after them), may push the newest kernel request out
  of a full queue, and run boosted (`sched.BOOST.shares.snapshot` 12 ms/s, never busy). A request for the same purpose
  whose box equals, contains or lies in a waiting one joins it (one scan of the union box, one file and one
  SNAPSHOT_READY per request id). `any` (economy's sand) is satisfied by any export queued or running. Dropped (kern.log
  `snapshot: dropped ...`): a waiting request after 15 min (inbox) / 30 min (kernel), a running export without a slice
  for 10 min, one whose slice failed twice. Another module's busy boost holds an export at most 3 min. A full queue is
  refused with `export queue full: running <id> <purpose> by <by> P% for T (<why it waits>); queued N: ...`. kern.log
  `snapshot: <ids> (<purpose>, N tiles, by <by>) written T after the request (T scanning)`. State `snap`.
- **readiness:** the monthly audit waits while its last audit snapshot is still queued or exporting
  (`snapshot.pending`).
- **runner (shaft check):** its own task, sliced: the stopped digs and the bp scan in one slice, then one shaft a slice;
  only an explore's bp file is decoded (the compact JSON names `"tpl":"explore"`), once a boot (S.xdoc keeps its tiles);
  the water box grows 3x3, 9x9, 25x25 only while the flood reaches its edge; candidates inside a flood already read are
  skipped and share the reads; a finished shaft whose last look found water in reach but no cavern is looked at every
  `fin_every` (8 days; dry ones and live explores stay daily); the look uses the run's start tick (exactly daily).
  `own_tiles` cached per project; `M.remake` checks its budget first.
- **doctor/status:** `top cost: runner 35.0 ms/s (snapshot 20.0 of it, in its calls)`; `snapshot queue: 5 waiting,
  oldest 12 min; first <id> <purpose> by <by> P% (<wait>)`; a problem `snapshot exports starve (...)` once the oldest
  request waits 5 min while the first one gets no slices; status shows that line and `top` in the kern line.

## Tests (fail on the old code)
- `tests/lua/test_snapshot_queue.lua` (new; 9 of 10 fail on e3a62ab): the live starvation on the real kernel, the
  caller-pays accounting and its perf.csv/inspect/state traces, the boosted inbox export ahead of a kernel one, joins,
  the full queue, age/stall/fault drops and the busy cap, `any`/`pending`/state, readiness' monthly wait, the persist
  size line.
- `tests/lua/test_runner_load.lua` (new; all 3 fail on e3a62ab): the bp folder after a boot, the daily check's reads and
  slices, the remake budget.
- `tests/test_doctor_load.py`: the edges are no owners, the top cost line, the starving queue line and problem.

## Live check
See the CHANGELOG entry (2026-10-17).

Related: FR-62 (pacing), BUG-026 (boost, busy), BUG-007 (kernel cost), 8cc2e8e (shaft check)
