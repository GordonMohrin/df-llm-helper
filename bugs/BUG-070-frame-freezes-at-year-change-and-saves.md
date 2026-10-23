# BUG-070 Frame freezes of 24-27 s at the year change and at saves; the doctor cannot say whose they are
Status: fixed in c80a2fe (offline, live-untested): every frame gap of 3 s or more gets one cause (our module and its
task, a DF save, unknown) in kern.log, `inspect perf`, perf.csv, PERF_DEGRADED and doctor; heavy background work (snapshot
exports, seal's background jobs, the timed persist flush, the periodic selftest) waits `perf.quiet_s` (60 s) in PEACE after a new year and after
a gap a DF save explains
Severity: medium (the freeze itself is DF's; what we could not do was tell DF's save from our own stalls, and our
background work ran into the save window)
Found: 2026-10-22, Runs 11-13, y456 and y483 (PERF_DEGRADED freeze 24-27 s at the year change and at saves; doctor y483:
max frame gap 172,094 ms, 13 gaps > 3 s; DF `Responding=False` up to 4 min), from the game session (note 1)
Module: `lua/dfllm/kern.lua` (`M.note_gap`, `M.quiet`, `K.busy`, the persist flush), `lua/dfllm/perf.lua`,
`dfpilot/doctor.py` (`gap_lines`, `gap_problems`)

## Actual
```
PERF_DEGRADED  frame freeze 25012 ms                    (no cause)
kern.log       frame gap 25012 ms (blame external)     (same text for DF's save and for anything else)
dfllm doctor   13 frame gap(s) > 3 s in 10 min (autosave?) ; max frame gap 172094 ms
```

## Expected
A freeze is attributed: DF's own save (not ours to change), a module of ours (named, with what it was doing), or unknown.
Our own heavy work stays out of the save window.

## Cause
1. **Proven: the 24-27 s are DF's.** The profile sets `d_init.feature.autosave = YEARLY` (arbiter.lua `PROFILE`), so DF
   saves at every year change; after an autosave `cur_savegame.save_dir` is `autosave N` (docs/v2/STATUS.md §0a point 6) and the
   game loop stands still while DF writes the world. Our frame callback does not run during it; the next frame sees a
   frame-to-frame gap of the whole freeze. The kernel's own cost per frame is measured on the cost clock and was a few ms
   in those rows (perf.csv `ms_s` 11-25), so a 25 s gap with `prev_cost * 2 < gap` is not ours. DF cannot be changed here
   (rule 1.1, no savegame tricks).
2. **Proven: the meter could not say so.** base kern.lua:1128-1131 logged `blame` = our previous frame's top owner when
   that frame took half the gap, else `external`, with nothing to tell a save from a sleep or a debugger; perf.csv and
   the doctor carried only the maximum and the count (doctor.py "frame gap(s) > 3 s ... (autosave?)"); PERF_DEGRADED's
   `why = freeze` had no cause either.
3. **What the kernel contributes around the save (from the code):** (a) the year-change frame emits YEAR_REVIEW (class A)
   and `follow` wakes the LLM within seconds; its first moves (`audit`, `plan propose`, `bp sites --fresh`) queue snapshot
   exports at the moment DF starts to save; (b) `snapshot` slices (1000 tiles a frame) and seal's background jobs run on;
   (c) the timed persist flush (every 10 s) JSON-encodes dirty keys of up to 64 KB and more (persist.lua, BUG-033 notes
   keys of 64 KB); (d) after a freeze every paced module has an empty debt (sched.lua leaky bucket drains in real time), so
   each runs once in the first frame after it. None of these is the freeze; (a)-(c) put kernel work next to it, which is
   what the quiet window removes.
4. **Not decidable offline: how much of the 172 s gap and of the "up to 4 minutes Responding=False" is DF's save and how
   much anything of ours.** A 4-minute stall of the whole process is far above any kernel cost in perf.csv; the cause is
   not visible from our files.

## Fix
- **One cause per gap** (`kern.M.note_gap`, every gap >= `gap_ms` 3 s): a module name or `kern` when the previous frame
  took at least half the gap (and the task it said it was doing, `M.doing()`, for a frame of 1 s or more); `save` when
  not ours and the save folder name changed since the last look (`autosave N` rename) or the year changed across the gap;
  `external` otherwise. kern.log `frame gap 25000 ms (blame save) (new year: the yearly autosave)`; ring of 12 in
  `inspect perf` (`gaps`: wall, tick, ms, cause, task); perf.csv `gap:<cause>` ms and `gapn:<cause>` count per row;
  PERF_DEGRADED `d.cause` and msg `frame freeze 25000 ms (DF save)` / `(ours: runner)` / `(not ours, cause unknown)`.
- **doctor:** `frame gaps > 3 s by cause: save 9 (210 s), runner 1 (4 s), external 2 (7 s)`; a problem only for ours and
  unknown gaps ("N frame gap(s) > 3 s ... not DF's save: 1 ours (runner), 2 unknown") and for a DF save freeze alone from
  60 s ("DF save freeze 172 s (> 15 s target)"); rows of an older kernel (no fields) stay unknown.
- **Quiet window** (`perf.quiet_s` 60, config `perf`, 0 = off; PEACE only, never in a fight): opened at the YEAR_REVIEW
  frame and by a `save` gap. `K.busy()` answers `save`: snapshot exports and seal's background jobs wait (urgent seal
  work and an export that has waited `busy_max_ms` 3 min do not), the timed persist flush waits (a mode change,
  `persist_now` and the stop flush do not), the periodic quick selftest skips its run. Nothing is scanned or written more often than before; work only moves later.
- PERF_DEGRADED stays class A and the supervisor's DEGRADED rule (DESIGN §10: a freeze past 20 s at a save) is unchanged.

## Not decided offline (live data that decides it)
Whether any of the observed freezes were ours and how long a quiet window must be. After the next year change:
`dfllm doctor` ("frame gaps > 3 s by cause"), `dfllm cmd inspect '{"what":"perf"}'` (`gaps`, `quiet_s`), kern.log
`frame gap` lines (cause and task), perf.csv `gap:` fields around the year change. Many `save` gaps with a long
`external` tail = DF/the OS; any module name = a bug of that module (its `M.doing()` task names the step). If `save` gaps
stay unexplained (the folder rename is not seen), read `dfhack.getSavePath()` before and after an autosave.

## Tests
`tests/lua/test_kern_gaps.lua` (new, 12): a gap across the year change is `save`; a renamed save folder is `save`, the
next unexplained gap `external`; our slow frame is blamed on the module and its task; perf.csv `gap:`/`gapn:` fields;
K.busy, the persist flush and the periodic selftest wait in the window and go on after it; not in a fight; `quiet_s` 0 switches it off.
`tests/test_doctor_gaps.py` (new, 4), `tests/test_status_keep.py` (config mirror).
