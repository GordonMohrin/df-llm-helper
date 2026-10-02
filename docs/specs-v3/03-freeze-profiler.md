# Spec v3-03: Freeze profiler (`dfpilot perf`)

Priority: P0 | As of: 01.10.2026 (Run 5, Y109) | Status: implemented (v3), not yet live-tested | Framework: see `../specs-v2/README.md`

## Goal and benefit
Measure game hangs (e.g. 11 s every 25 s) automatically, attribute them to the permanent job that causes them and propose a limit. In Run 5 `claude/raster` (every 1500 ticks `reapply()` and the map scan `erzdig ALL`) and `claude/kohle` (9 s) caused the hangs; the diagnosis via latency measurement + bisect (`repeat-util.cancel`) took 15 turns.
**Expected gain:** diagnosis in 1 call; the player no longer notices hangs first.

## Behaviour
1. **Latency probe:** `dfpilot perf sample --n 40 --gap 0.6`: a short command (`lua print(1)`) at intervals; output: number of outliers (> 1.5 s), maximum, estimated period (distance between outliers in seconds and, with `frame_counter`, in ticks).
2. **Auto watcher:** the watcher measures the latency of its queries on every tick. If the 5-minute rate of outliers exceeds 5 %, it sets `perf.flag` and reports in the digest `Game hangs: 2 outliers/min (max 10.5 s, period 25 s)`.
3. **Attribution:** `dfpilot perf bisect`: lists `repeat-util.listScheduled()`, measures the run time of each service individually (`claude/<name> run|status`), switches suspicious services off in groups (halving) only when there are outliers, measures again, restarts them. Result: service and measured run time. Safety: alarm/watcher services (`watchdog`, `milguard`, `watchdog-alert`) are only switched off briefly (< 40 s) and only in peace, and are guaranteed (finally) to be restarted.
4. **Heuristics (KB `perf_hanger`):** services with a map scan (`erzdig`, `reapply`, `kohle`) need rate limiting; the period ≈ interval of the service in ticks / tick rate; timestream raises the tick rate.
5. **Proposal:** raise the interval, split the scan into blocks, run only on demand. No automatic patch of Lua files; a proposal with a line reference.
6. **Regression:** `perf sample` is run as a test after every Lua update of the repo (mandatory in the agent briefing).

## Configuration
`perf: {outlier_ms: 1500, warn_rate_pct: 5, bisect_pause_s: 40, protected: [claude-watchdog, claude-watchdog-alert, claude-milguard]}`

## Fair play
Only reading and switching services on/off.

## Acceptance criteria
1. Replay "raster 11 s every 25 s": `sample` reports period 25 ± 3 s and maximum 11 s.
2. Mock bisect over 20 services finds the one slow service in ≤ 6 measurements; all services are on again afterwards.
3. Protected services are never switched off longer than `bisect_pause_s` (test with a crash in the middle of the bisect: recovery from the state file).
4. Watcher auto detection sets `perf.flag` only after ≥ 5 outliers in 5 min.
5. Digest line ≤ 120 characters.

## Fixtures/tests
Latency series from Run 5 (`meas.sh` outputs), `listScheduled` output, run-time measurements of the services (kohle 9 s, bauprog 3.5 s).

## Implementation notes (v3)
- Code: `dfpilot/features/perf.py` (commands `perf sample|bisect|status [--clear]`, `check_hook`), watcher part in `dfpilot/waechter.py` (`LatencyMonitor` fed by the light queries `MAX_REPORT_ID_CMD` and `CLEAR_CMD`). Tests: `tests/test_perf.py`; fixtures: `fixtures/v3/perf/` (see its README).
- AC → test: AC1 `test_ac1_replay_raster_period_and_max`, AC2 `test_ac2_*`, AC3 `test_ac3_*`, AC4 `test_ac4_*`, AC5 `test_ac5_digest_line_length`.
- Further config keys: `min_outliers: 5`, `window_s: 300`, `sample_n: 40`, `sample_gap_s: 0.6`, `max_off_s: 600` (limit for non-protected services), `flag_repeat_min: 30`, `max_bisect_per_hour: 2`, `in_check: true`.
- Deviations: the probe prints the frame counter instead of `1` (needed for the period in ticks). The service list is read from the `repeat-util` table `scheduled` (a `listScheduled()` function is not known to exist; LIVE-UNTESTED). Run times are not measured per service with `claude/<name> run` (scripts without a status command run a work round = side effect); instead the bisect reports the freeze length measured while the culprit was on. The search treats "no listed service" as one more hypothesis, so a hang outside the services is reported as such and 20 services need at most 1 + 5 measurements. Services without a start command in `data/services.yaml` (e.g. `claude-watchdog-alert`) are never switched off and are listed as untestable. Item 6 (briefing duty) is only documented here and in the KB entry; the briefing templates belong to another module. The digest line appears via `dfpilot check` (feature check hook), `digest.py` is unchanged.
