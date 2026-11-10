# BUG-645 Host sleep is not a frame freeze
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-11-10, Run 16 all four instances after the PC slept ~10 h (10.11. 09:30): `PERF_DEGRADED frame freeze 35186xxx ms (not ours, cause unknown)`
Module: `lua/dfllm/kern.lua` (`note_gap`, `frame`, `CAD.sleep_gap_ms`), `lua/dfllm/perf.lua`, `dfpilot/doctor.py`

## Actual
`PERF_DEGRADED` 'frame freeze 35186xxx ms (not ours, cause unknown)' on every instance; the sleep also read as 9.8 h of unpaused run time (a tps collapse in the row) and, in the doctor, as an unknown or our own gap.

## Root cause
`kern.note_gap` knew `module`, `save` and `external` only; a DF clock that ran on through a PC sleep landed in `external`. `perf.step` turned any gap >= 20 s into a freeze event, `frame` added the whole gap to `unpaused_ms` (perf tps), `doctor.gap_problems` counted every cause but save/external as ours.

## Fix
- `kern.CAD.sleep_gap_ms` (600000): a gap of 10 min or more that is not our module's own frame is cause `sleep` (`frame gap N ms (blame sleep) (host slept ~M min ...)`); no save takes that long. It opens no quiet window, the gap is no unpaused run time (`p.slept`), and the perf row of that window feeds no tps baseline or degraded check.
- `perf.step`: `PERF_DEGRADED` `host slept ~N min (PC sleep/suspend, DF was not running)` with `why=sleep` (no freeze; supervise's freeze hints only read `why=freeze`).
- `doctor.gap_problems`: `sleep` is neither ours nor unknown.

## Tests
`tests/lua/test_kern_perf.lua` (+1), `tests/test_bug645_650_f41_misc.py` (1)

## Live check
After the next sleep of the PC the four instances show one `PERF_DEGRADED why=sleep` each and no tps degradation; `inspect what=perf` gaps list cause `sleep`.
