# BUG-068 A lever whose pull has no effect is pulled again every 50 ticks, for ever; `act.run failed for baseline: nil`
Status: fixed in 304535f, docs d77a187 (offline, live-untested): a lever pulled `gate.noeffect_max` (3) times in a row without its bridge
moving is parked for `gate.noeffect_wait` (1200) ticks (a quarter of it in SIEGE/BREACH/DRILL), doubled per further parking; LEVER_NOEFFECT (B) reports it once per
lever; a bridge with every lever parked fails as GATE_FAIL `no_effect`; ACT_FAIL names the command line of a failed
`act.run` and says "raised an error without a message" for `error(nil)`
Severity: medium (noise and wasted pullers; in a siege a retry storm on a lever that cannot work hides the real fault)
Found: 2026-10-18, Run 12 Trussroads (a reclaimed fort), note 28 of bugs/RUN11-offene-bugs-und-FR.md: "the kernel pulls
lever 11808 several times in a row (`LEVER pull X11814 up` x6 within one second) without effect; ACT_FAIL `act.run failed for
baseline: nil`". The old fort's bridges are X10972 and X11814 (unmanaged, found from the lever links).
Module: `lua/dfllm/gate.lua` (control, pick, noeffect), `lua/dfllm/act.lua:1913-1920`, `lua/dfllm/kern.lua` (act env.fail)

## Cause (proved from the code at f17e2b3)
1. **The retry loop.** A pull whose job has left the lever's queue while the bridge still stands in the state it had
   (`s == r.job.before`) only set `r.bad[lever] = true` (gate.lua:1364) and `r.settle = now + M.SETTLE` (SETTLE = 50, line 106).
   `pick` (gate.lua:790-808) skips bad levers, but when every linked lever is bad it empties `r.bad` and starts again
   (798-799): a bridge with ONE linked lever (the old fort's X11814 had lever 11808) gets the same lever again 50 ticks
   later, and `K.emit('LEVER', 'C', 'pull ...')` (1462) goes out at each pull. 50 ticks are 0.1 s at timestream speed
   (450 ticks/s) and a bridge with two levers still alternates every 50 ticks: six `LEVER pull X11814 up` lines within a second.
   Nothing bounds the retries per lever per period, and nothing reports a lever that never works (the only report is the
   bridge's GATE_FAIL at the deadline, `timeout`).
2. **Why the pull had no effect is not provable offline.** Candidates in the code: DF drops the pull job at once (no path to
   a lever in the old fort's ruins: `job_on` finds no job at the next pass), or a worker pulls and the bridge does not move
   (the link points to a bridge that is broken). `r.job.taken` (a worker was seen) separates them; the old code did not
   record it.
3. **`act.run failed for baseline: nil`.** `api.run` wraps `pcall(f, ...)` (act.lua:1913): `if not pok then ok, res = false,
   tostring(a)`. A command that raises `error(nil)` (a DFHack script with an empty error, e.g. a plugin command in a
   world it does not know) gives `a == nil`, so the reason is the string `nil`; and the ACT_FAIL (`env.fail(fn, trim(res, 160),
   who)`, 1920) carries neither the command nor the arguments, so the failed baseline command cannot be named. (`trim(nil)`
   is '' and `cmd_run` always returns a message, so the literal `nil` can only come from this `tostring(a)`.)

## Fix
- **gate.lua:** after a pull job leaves the queue the verdict waits `SETTLE` ticks (`r.nec`, judged at the top of the next pass,
  so a bridge that starts to move a moment late is no failure). `M.noeffect` counts consecutive no-effect pulls per lever; at
  `noeffect_max` it parks the lever (`r.park[lever]`, `noeffect_wait` ticks, a quarter of it in a fight, doubled per further parking, at most 8x), logs
  once and emits `LEVER_NOEFFECT` (B) `{bridge, lever, pulls, state, wait, worker}` (`worker` = pulls a worker took; 0: DF dropped
  every job unclaimed) once per lever (util/cadence, persisted `m.gate.ne`; a lever that works again re-arms it). `pick` skips
  parked levers; with all parked `r.stuck = 'no_effect'`, and the bridge's GATE_FAIL says `no_effect` whenever a lever of it was parked. A mode change or a pull
  that moves the bridge clears the record, so a siege gets a fresh try.
- **Config** (`config/reflex.json` `gate`, validated by `fairplay.py`, `python -m dfpilot.lint --config`):
  `noeffect_max` 1..20 (3), `noeffect_wait` 100..24000 ticks (1200).
- **act.lua / kern.lua:** `error(nil)` becomes "raised an error without a message"; the ACT_FAIL of a failed `run` carries
  `cmd` (the command line, <= 80 bytes) and shows it in brackets; the rate limit keys on it.

## Not decided offline
- **Why lever 11808 never worked.** Decides it: the `LEVER_NOEFFECT` event (`worker` 0 = no one took the job: look at
  `dfhack-run lua` read-only `dfhack.buildings.findAtTile(<lever>)`, the lever's `linked_mechanisms`, and the walk group of
  the lever tile against a citizen's; `worker` > 0 = pulled but the bridge stayed: the bridge's `gate_flags`).
- **Which baseline command raises `error(nil)`.** The next ACT_FAIL says `act.run failed for baseline: raised an error without
  a message [control-panel enable ...]`; `commands.log` has the same line with the arguments.

## Tests
- `tests/lua/test_gate_noeffect.lua` (a siege that wants an unmanaged bridge up, a frame hook that drops every pull job):
  the parking and its doubling, one report per lever, GATE_FAIL `no_effect`, a lever tried again after its wait and cleared by
  a pull that works, working levers never reported, the config keys and bad values.
- `tests/lua/test_kern_act.lua`: `error(nil)` and the command line in the failure.
- `tests/test_c2_reclaim.py`: the config keys are validated.
- All new tests fail on f17e2b3.

Related: BUG-027 (pull rules), BUG-030 (destroyed bridges), A2 package (lost bridges), FR-76
