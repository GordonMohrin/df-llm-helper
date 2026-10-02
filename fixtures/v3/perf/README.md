# fixtures/v3/perf (spec v3-03, freeze profiler)

| File | Origin | Content |
|---|---|---|
| `raster_11s_every_25s.jsonl` | SYNTHETIC | ReplayClient records of the probe `lua "print(df.global.world.frame_counter)"`: 40 probes, 0.6 s gap, freeze 11 s every 25 s (shape of the Run 5 meas.sh observations; the raw meas.sh output was not kept) |
| `list_scheduled.txt` | key list LIVE (01.10.2026), output format SYNTHETIC | answer of `LIST_CMD` (`S key key ...`) with the 13 repeat-util keys seen live |
| `service_runtimes.json` | LIVE measurements (01.10.2026), as numbers | run time per service round in seconds (kohle 9.4, bauprog 3.5, raster freeze 11 s every 25 s, guard cycle 5.9 s for 13 commands) |

Fixture gaps: real meas.sh latency series, real `repeat-util` listing output, a recorded bisect session.
