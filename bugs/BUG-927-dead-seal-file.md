# BUG-927 a seal file the kernel does not know keeps `plan check` warning "seal <id> +6 is open" for years
Status: fixed (offline, live-untested) for the warning and the seal bookkeeping; why the kernel lost the project is not shown
Severity: medium (a false "the runner pauses bedrooms, stockroom" in every plan check; `bp sites seal` left an opening out for a project that builds nothing)
Found: Run 17 i2 Whirledrampart (run-16b y547-y560): `bp/c1a1c57ffc32132601.json` (tpl seal, stage seal.build): `bp.cancel` / `bp.resume` -> `no project c1a1c57ffc32132601`, `bp sites seal` -> "left out, seal project c1a1c57ff... builds its piece", `plan check` -> "seal c1a1c57ffc32132601 +6 is open: the runner pauses bedrooms, stockroom in PEACE until it is done" for 13 game years while status said "1 way in, all with a door". 278 bp files in the folder.
Module: `dfpilot/cmd.py` (`mark_orphan`, `read_orphans`, `orphan_seal_candidates`, `settle_orphan`, `seal_records`, `send`), `dfpilot/wake.py` (`_sweep_orphans`, `_read_replies`), `dfpilot/plan.py` (`open_seals`)

## Cause (PROVEN for the warning)
- `plan.open_seals` falls back to EVERY seal bp file without a PROJECT_DONE when the state has no `proj` list. The live state of i2 (state.a / state.b.json) has `proj` null although `sched.ip` names 34 set-aside projects: the fallback lists old seal files as open seals and `seal_gate` warns "the runner pauses ..." for them. The kernel pauses nothing for them (it does not hold the projects).
- BUG-442's sweep retires only a file that is PROVABLY never finished (`never_finished`: no PROJECT_DONE in a complete event log, or an untouched snapshot); a doubtful one (rotated events, a done project whose persist key is cleared) stayed and was asked of nobody; `seal_records` (`bp sites seal`) also read it.
- NOT shown: why the kernel lost that project (a finished one pruned from the list, or a plan apply that rewrote the file after a cancel: BUG-442's history); why state.proj is null live.

## Fix
- `cmd.mark_orphan`: `bp/.orphans.json` (`{"v":1,"ids":{id:{t,by}}}`, written by the code, a dot file `bp_files` never lists) records a seal project file the kernel does not hold. The FILE IS NEVER DELETED or moved by it; cli.log `orphan:ignored` once per id.
- Marked when: the kernel answers `none` for `inspect persist key=bp.<id>` in follow's sweep or `plan apply`'s sweep (`orphan_seal_candidates`: seal files older than 5 min, not a state row, no PROJECT_DONE, not marked) and the file cannot be retired; or `bp.cancel` / `bp.resume` answers `no project <id>` and the file cannot be retired (`settle_orphan`: retired when provably never finished as before, else marked).
- `plan.open_seals` and `cmd.seal_records` skip a marked id unless the state lists it as a running project again (a marked id the kernel holds counts at once).

## Verifier round (NEU19)
- `cmd.live_orphans(save, state)` = marks minus the ids the state's project list holds again; `plan.open_seals` AND `cmd.seal_records` use it, and a mark the kernel lists again is cleared in `bp/.orphans.json`.
- `cmd.mark_orphan` never marks a seal file whose pieces stand on the newest snapshot (`cmd.seal_built`: a door, hatch, grate or wall char on a piece tile): its PROJECT_DONE may have rotated out of events, so it may be a FINISHED project. Wall pieces read `#` like rock; a finished wall seal on a snapshot that does not cover the tile is not recognised (it is marked, the file stays).

## Not done
- The kernel (`runner.lua`) is not changed: it holds no such project and pauses nothing; a live project list that does hold the id is unaffected.
- Non-seal orphans (fortcore, explore ...) keep the BUG-442 rule (retired only when provably never finished); marking them is not done.

## Tests
`tests/test_bug927_orphan_seal.py` (9: + a finished seal is not marked, a marked seal listed again counts in seal_records and loses its mark); `tests/conftest.py` (the sweep stub also covers `orphan_seal_candidates`).

## Live-Erwartung
On i2 after follow's next sweep (first look ORPHAN_FIRST_S, then every ORPHAN_EVERY_S): cli.log `orphan:ignored {"proj": "c1a1c57ff..."}` once per dead seal file, `plan check` without the "seal ... is open" line, `bp sites seal` no longer "left out" for them. `bp/.orphans.json` lists the ids; the bp files are still there.
