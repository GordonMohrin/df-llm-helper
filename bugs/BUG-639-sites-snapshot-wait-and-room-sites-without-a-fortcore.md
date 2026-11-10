# BUG-639 `no sites snapshot` AUTO_FAIL after 60 s, and no room sites without a fortcore
Status: fixed (offline, live-untested); open: tombs have no surface variant
Severity: medium (farms / tombs / bedrooms never placed for years in a fort without a dug core)
Found: 2026-11-10, Run 16b i2 Valleyhame y375-y378 (`AUTO_FAIL farms / tombs: no sites snapshot` every minute, `bp sites --fresh` 'no snapshot' in 60 s, tombs / bedrooms 0 sites, coffin_space DECISION), Run 16a i1 (`bp sites farms|office|...` 0 free sites after embark)
Module: `dfpilot/wake.py` (`AUTO_SNAP_TIMEOUT_S`, `_request_place`, `_run_jobs`, `_read_replies`), `dfpilot/cmd.py` (`fresh_wait`, `surface_alt`, `place`, `no_site_hint`), `dfpilot/cli.py`

## Actual
kern.log of Valleyhame: `snapshot: ... (sites, 168480 tiles, by inbox:follow) written 1 min / 2 min / 3 min after the request`; follow gave up at 60 s each time (`AUTO_FAIL x: no sites snapshot`) and asked again, so the queue held exports nobody waited for. `bp sites --fresh` (no explicit box) waited the CLI's 60 s. Without a fortcore, `bedrooms` / `dining` / `tavern` / `office` found 0 sites although their surface variant (BUG-387) needs no core; the hint said 'bp.place fortcore first'.

## Root cause
(1) wake.py `AUTO_TIMEOUT_S = 60` was the limit for a job waiting for its snapshot (`_run_jobs`, the cooldown in `_request_place`, the reply read in `_read_replies`); the export of a default box needs 59 s to 3 min on a busy kernel. cmd.py `fresh_wait(None, ...)` returned the flag for the kernel's default box (BUG-415 sized only the explicit fortcore box). (2) `cmd.place` tried the template as asked only.

## Fix
(1) `AUTO_SNAP_TIMEOUT_S = 300` for a job that waits for its snapshot and for a `snapshot` reply (not for other commands); the failure text names the wait. `fresh_wait(box, timeout, save_dir)`: without a box the newest sites snapshot's tile count (else `SNAP_DEFAULT_TILES` 170,000) sizes the wait (`30 s + tiles / 1500`, at most 300 s); `cli.py` passes the save dir. (2) `cmd.surface_alt` / `no_core_floor`: a dining / bedrooms / tavern / office placement that finds no site in a fort with no Z4 floor in the manifest and no fortcore project falls back to `p.surface = 1` inside `cmd.place` (so follow, `plan check`'s fit and the CLI all get it; PLACE_NOTES says so); `no_site_hint` names the surface variant, and for tombs says they have none (they dig off the Z4 floor of a dug core).

## Tests
`tests/test_bug637_641_f41_proj.py` (job waits 300 s, reply wait, fresh_wait sizing, bedrooms fallback, no fallback with a core floor / a core coming / tombs, the hints)

## Live check
`bp sites bedrooms` in a coreless fort ends with the surface-variant hint and `bp.place bedrooms` places `surface=1`; no `AUTO_FAIL ... no sites snapshot` while an export of 168k tiles is under way; `dfllm bp sites farms --fresh` waits ~140 s instead of 60.
