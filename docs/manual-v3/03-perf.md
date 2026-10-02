# Freeze profiler (`dfpilot perf`, spec v3-03)

**When:** the game stutters or stops for seconds at regular intervals, `dfpilot check` shows `Game hangs: ...`
(perf.flag), or after every Lua update of the companion scripts (regression probe).

## Commands
- `python -m dfpilot perf sample [--n 40] [--gap 0.6]` - probes the game (frame counter) n times; prints outliers
  (> 1.5 s), maximum, period in seconds and ticks, tick rate. Exit code 1 if there were outliers.
- `python -m dfpilot perf bisect [--dry-run] [--force]` - baseline sample; only with outliers it switches the
  repeat-util services off half by half (`repeat-util.cancel`), measures again and restarts them
  (`claude/<name> start` from `data/services.yaml`). Prints the culprit, the measured freeze and a proposal with line
  references into `lua/claude/<name>.lua`. `--dry-run` only lists what it would test. At most 2 runs per hour.
- `python -m dfpilot perf status [--clear]` - perf.flag, services still switched off, last sample/bisect; `--clear`
  deletes perf.flag after you handled it.

## What happens automatically
- The watcher measures the latency of its two light queries every tick. >= 5 outliers in 5 min and an outlier rate
  > 5 % -> `tools/perf.flag` with `Game hangs: 2.0 outliers/min (max 10.5 s, period 25 s) -> dfpilot perf bisect`
  (shown by `dfpilot check`; set again at most every 30 min after you deleted it).
- Crash safety: before a bisect switches anything off it writes `tools/out/perf_bisect.json`. The watcher restarts
  every listed service whose deadline passed (protected: 40 s, others: 600 s); `perf` and `check` restart everything
  when the bisect process is gone (no heartbeat for 30 s).
- Every cancel/restart/recover is logged in state.db (`actions`, rule `perf`).

## Config (`perf:`)
`outlier_ms 1500, warn_rate_pct 5, min_outliers 5, window_s 300, bisect_pause_s 40,
protected [claude-watchdog, claude-watchdog-alert, claude-milguard], sample_n 40, sample_gap_s 0.6, max_off_s 600,
flag_repeat_min 30, max_bisect_per_hour 2, in_check true`

## Limits
- Protected services are switched off only in peace (no alert/siege flag, no 'alarm'/'gefahr' hold) and never longer
  than `bisect_pause_s`; services without a start command (watchdog-alert) are never switched off.
- No automatic Lua patch; the fix (bigger interval, scan in blocks, on demand) is yours.
- The service listing uses `repeat-util.listScheduled()` (DF 53 has no `scheduled` table; fixed after the live test 02.10.2026; keys with `/` such as `control-panel/...` are not bisected). The probe works live; the very first probe of a sample can be a one-off outlier (game busy). A bisect takes 3-4 minutes.
