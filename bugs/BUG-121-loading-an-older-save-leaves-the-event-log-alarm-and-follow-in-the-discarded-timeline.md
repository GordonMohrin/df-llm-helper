# BUG-121 after loading an older save of the same fort, `events.jsonl`, `alarm.txt` and follow's cursor stand in the discarded timeline: `follow` replayed BREACH / INTRUDER / DEATHS_3PLUS of the abandoned line while `status` said PEACE
Status: fixed in the BUG-121 commit (offline, live-untested): the kernel writes `TIMELINE_RESET` at a boot whose clock jumped back; follow, events, status and brief drop the events of the discarded line
Severity: high (wrong decision: the session was woken for a siege and deaths that never happened in the loaded line)
Found: 2026-10-27, Run 14 (region2-site97 line), game session note 101
Module: `lua/dfllm/kern.lua` (`disk_tick`, boot), `lua/dfllm/reflex.lua` (`init`), `dfpilot/files.py` (`iter_events_rev`, `EventTail`), `dfpilot/wake.py`, `dfpilot/alarm.py`, `dfpilot/brief.py`, `dfpilot/events.py`, `dfpilot/guide.py`

## Actual
The player loaded an older save of the fort. `<runtime>/<save>/events.jsonl` still held the events up to #29900 of the line he had left (ticks far
ahead of the loaded clock), the new line restarted at an older tick. `dfllm follow` replayed the BREACH, INTRUDER and DEATHS_3PLUS wakes of the
abandoned line, while `dfllm status` (the kernel's fresh state) said PEACE.

## Cause (from the code at f3f684b)
- Event numbers continue across a load on purpose (`kern.lua` boot: `st.ev_n = max(persist kern.ev, last n on disk)`), but the runtime folder is
  not part of the save: nothing marked that the events with a later tick than the loaded clock belong to a timeline that no longer exists.
- Every reader took the log at face value: `files.iter_events_rev` (brief, status, events, cmd, plan), `files.EventTail` (follow, wait) and
  `alarm.read_alarm`. The class-A scan of `brief.Ctx` and the replay of follow (`--since`, a cursor inside the abandoned line) therefore met them.
- `alarm.txt` is written in place by reflex; until reflex's first step it still told the old line's DEFCON and lockdown.

## Fix
- Kernel (`kern.lua`): at boot, before `BOOT`, the clock (`abs_tick`) is compared with the newest tick the runtime folder remembers: the last event
  of `events.jsonl` (else `events.1.jsonl`) and the state slot with the highest `seq` (the other slot may still be the old line's). Clock before
  it: class-B event `TIMELINE_RESET {n_alt, tick_alt, tick_neu}` (`d` about 60 bytes), `alarm.txt` deleted, one kern.log line. Equal or later
  (a plain reboot, a timestream restart), no log (first boot) or an already reset log (the BOOT of the reset boot is newer than the clock): nothing.
- Reflex (`reflex.lua` init): persisted interrupts and a lockdown hold stamped after the clock are not taken over (kern.log names the hold).
- Python: `files.iter_events_rev` / `tail_events` skip an event before a marker (smaller n) whose tick is later than the marker's `tick_neu`
  (every later marker cuts too, a marker of a discarded line included) and, with `max_tick`, any event later than the current tick; `events`,
  `brief`/`status` (`Ctx`) and `follow`/`wait` (`EventTail(tick_fn=...)`) pass the state's tick plus a one game day slack
  (`files.TICK_SLACK`: a state lags the newest event by seconds of timestream). The follow cursor passes the dropped events; on the marker
  follow forgets its auto jobs and `plan_auto`. `alarm.read_alarm(max_tick)` ignores items stamped after the clock. The brief digest lists
  `TIMELINE_RESET` first.
- Class B, so no RULES section 7 row (it wakes nobody). CONTRACTS §12 row, §9.4 sentence and the schema appendix.

## Not decided offline
- Whether the live DF/DFHack gives the lower `cur_year_tick` already when `dfllm boot` runs after loading an older save.
- Events before the marker with a tick up to `tick_neu` stay (the shared past of both timelines); the note could also be read as "drop everything
  before the marker". Other files of the runtime folder that carry the old line (`snap/`, `bp/`, pending `inbox/`) are not touched.

## Tests
- `tests/lua/test_timeline_reset.lua` (10): the marker with `n_alt/tick_alt/tick_neu` before BOOT and the old alarm.txt gone; no marker on a
  clock moving forward, on the very tick of the last event, on a first boot, on later boots (also with a stale state slot); a reset detected from
  the state slot alone and from the rotated log; reflex drops the future interrupt and hold.
- `tests/test_bug121_timeline.py` (20): the marker rule in `files` (one and two resets, rotation, caps, limit, cls), `events`, the tail
  (one batch, replay, rotation, current-tick cap), alarm.txt items, follow (replay and in flight), brief and status, schema.
