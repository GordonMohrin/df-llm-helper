# FEATURE-006: `df_llm_helper loops` - registry of background loops, duplicate detection

- **Status:** implemented in 59511e5
- **Priority:** P2
- **Requested by:** Gordon (player), 2026-10-03, via the local orchestrator
- **Area:** new `df_llm_helper loops`, lockfile/heartbeat convention for every loop (`holdguard.sh`, guard, siege, watchdog helpers)

## Problem
Several background loops were started more than once (multiple `holdguard.sh`, one forgotten siege loop). They produced contradicting orders (e.g. kill orders set again after deletion, see BUG-426) and were hard to find.

## Proposed behaviour
1. Every loop takes a lockfile (`tools/loops/<name>.lock` with PID, start time, command) and writes a heartbeat timestamp.
2. `loops list [--json]`: all registered loops, heartbeat age, stale/duplicate marks; `loops stop <name>` ends one (kill PID or stop flag).
3. A second start of the same loop name refuses or warns; `wake`/`digest` warn on duplicates and on loops without heartbeat.

## Safety
Manages only helper-own processes; read-only by default.

## Acceptance (fixture based)
Two lockfiles with the same name -> `DUPLICATE`; stale heartbeat -> `STALE`; `stop` removes the lock.

## Info needed
List of loop names/scripts used on the orchestrator side and where they are started.

## Implementation
- **Registry** `df_llm_helper/loops.py`: `LoopLock` takes `tools/loops/<name>.lock` (JSON: name, pid, started,
  heartbeat, interval_s, command) with an exclusive create; `beat()` once per pass (throttled to `loops.beat_min_s`)
  returns False after `loops stop`. The lock is removed on exit, Ctrl+C and SIGTERM (handler -> SystemExit).
  Status per lock: DUPLICATE (> 1 live lock of one name), STALE (alive, heartbeat older than
  max(`stale_min_s` 120, 3 x interval + 30 s)), DEAD (process gone). A dead lock, or one with a heartbeat older than
  `loops.reclaim_s` (6 h, PID reuse), is taken over at start.
- **Second start** (item 3): refused by default (`Error: loop 'wake' already runs (pid ...) -> loops list; loops stop
  wake`, exit 2); `loops.on_duplicate: warn` starts anyway as `<name>.<pid>.lock`, listed as DUPLICATE.
- **CLI** `df_llm_helper/features/loops.py`: `loops list [--json]` (exit 1 when anything is marked), `loops stop <name>
  [--pid N] [--kill] [--wait S]` (stop file, then kill only if the live command line still matches the lock),
  `loops clean` (dead locks), `loops wrap <name> --cmd "<command>"` (runs a foreign loop such as `holdguard.sh` under the
  registry).
- **Adopted loops**: `waechter --loop`, `wake --loop`, `autopilot --loop`, `guard --loop`, `caravan --loop`, `siege`
  (unless `--once`; `loops stop siege` ends it after the step and clears its orders), `camera watch --loop`. One pass and
  `--dry-run` take no lock.
- **Warnings**: `check` hook (duplicates, hanging loops), digest items `Loops` (delta: once, then "still open"), wake
  lines `WAKE loops: Loop siege runs 2x ...` (files + PID check only).
- **Windows/Linux**: PID liveness via psutil when installed, else `os.kill(pid, 0)` on POSIX (zombies count as dead)
  and `OpenProcess`/`GetExitCodeProcess` via ctypes on Windows (never `os.kill(pid, 0)`, which would terminate the
  process there); command line via psutil, `/proc` or PowerShell CIM.
- **Not done**: the orchestrator-side shell loops (`holdguard.sh`, watchdog helpers) live outside this repo; they join
  the registry only when started through `loops wrap` (Info needed: their names and start places).
- **Tests**: `tests/test_loops.py` (two lockfiles of one name -> DUPLICATE; stale heartbeat -> STALE; `stop` removes the
  lock; kill only on a matching command line; refusal and warn mode; a real `wake --loop` subprocess registers, refuses
  a second start and ends on `loops stop`; wake/digest/check lines; without psutil).

### Live check (Windows, Git Bash)
1. Start `python -m df_llm_helper waechter --loop` as usual; `python -m df_llm_helper loops list` shows `OK waechter`
   with its pid and a heartbeat younger than 10 s.
2. Start a second `waechter --loop` in another shell: it must exit with `Error: loop 'waechter' already runs ...`.
3. `python -m df_llm_helper loops stop wake` on a running `wake --loop`: the monitor ends within ~10 s and its lock is
   gone. Kill a loop hard (Task Manager): `loops list` shows DEAD, the next start takes the lock over.
4. `python -m df_llm_helper loops wrap holdguard --cmd "bash holdguard.sh"`: listed; `loops stop holdguard` ends the
   script.
