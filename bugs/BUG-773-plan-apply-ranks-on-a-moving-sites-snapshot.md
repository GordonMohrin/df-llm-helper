# BUG-773 plan propose / check / apply rank on a different sites snapshot each call, apply fails
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-11-11, Run 16c i3 Lancemoment y372 (Runde 31): `plan check` / `plan apply` said "0 free sites for fortcore" on changing snapshots, only the 3rd try (`bp sites fortcore --fresh` right before apply) worked; the anchor S1 moved from [101,107] to [147,59]
Module: `dfpilot/plan.py` (`run`, `_run`, `draft_pin`, `_pin_retry`), `dfpilot/cmd.py` (`pin_snapshot`, `snapshot_by_id`, `sites_snapshot`)

## Actual
`S<k>` is "the k-th free site at apply time". Every `plan` call first refreshed a stale sites snapshot (`snapshot_stale` / `auto_refresh`, BUG-369: a PROJECT_STAGE / PROJECT_DONE after its tick) and ranked on the newest one; in a fort that digs, a stage event arrives between propose and apply, a new export is made and the ranking (and the anchor of S1) differs from the one the draft was proposed on.

## Fix
`plan propose` writes the id of the snapshot it ranked on to `<draft>.snap` (`plan.draft.json.snap`). `plan check` and `plan apply` pin that snapshot (`cmd.pin_snapshot`: `sites_snapshot` returns it while the file exists, so every ranking of the call, check, placement and occupancy included, uses one map) and do not refresh it. A rejection on the pinned snapshot is tried once more on the newest, refreshed snapshot (`_pin_retry`; nothing was written, the apply is all or nothing); the output says which map the answer is from ("ranked on the proposed sites snapshot X", "rejected on ..., ranked again on the newest Y"). A pinned snapshot that was pruned or is more than one game year older than the newest is dropped.

## Open
The pinned map can predate a stage that finished after the propose: the occupancy (bp files) still excludes projects, and the kernel validates at place time; `plan propose` again ranks on the newest.

## Tests
`tests/test_bug772_773_nowood.py` (the pin keeps the proposed snapshot while a newer one exists; a rejection is retried on the newest; a gone or year-old pin is ignored).
