# BUG-148 `inspect what=items key=trash` said "ok" while 1056 marked items got no dump job and named the smallest zone; zone.place zones kept site_realization 0
Status: fixed (offline, live-untested); why DF makes no DumpItem job in Trussroads is still open
Severity: medium (a misleading view: "ok" while nothing was dumped for 1.5 game months)
Found: 2026-10-28, live test i1 (region2-site90 y715), features FR-90b and NEW8; confirmed by the verifier
Module: `lua/dfllm/trash.lua` (`scan`, `diagnose`, `inspect`), `lua/dfllm/act.lua` (`I.zone_place`)

## Actual
- `trash: 13315 loose item(s) (1056 marked to dump), 68 on dump zones, 0 dump job(s) (0 waiting), 2 zone(s); dump zone 24812 is reachable
  with 1 free of 2 tiles`, reason `ok`, over four polls of ~13000 ticks. `diagnose` judged only the zones and returned on the first usable
  zone in list order; it never saw `marked` or the jobs. The 12-tile zone 26126 was not named.
- Zone 26126, placed by `zone.place` (quickfort zone mode), had `site_realization_building_id` and `site_realization_sul_id` 0; the
  player's zone has -1/-1 (no visible effect: both zones got no jobs).

## Fix
- `diagnose` names the usable zone with the most free tiles. `inspect` reports reason `no_jobs` when a zone is usable, items are marked and
  no DumpItem job exists: `no dump job for N marked (F forbidden, W off the walk group, B in a building): check refuse hauling; dump zone ...`.
  `scan` counts `marked_forbid`, `marked_far` (snapshot `far`, at most `trash.FAR_MAX` = 400 asked) and `marked_bld`; the data carries
  them. CANCEL_LOOP keeps its four reasons (a cancel means a job existed).
- `act.zone_place` sets both fields from 0 to -1 on the zones it created, as a zone drawn on the zones screen has them (UI-equal; other
  zones untouched).

## Tests (`tests/lua/test_bug148_trash.lua`)
- no_jobs with the three counts and the 12-tile zone named (fails on main: `ok`); ok with a job or nothing marked and the most-free zone
  named (fails on main: the first zone); zone.place -1/-1 (fails on main: 0, 0).
