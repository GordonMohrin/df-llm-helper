# BUG-637 Projects parked by `build_lost` stand 300+ days and are cancelled only by hand
Status: fixed (offline, live-untested)
Severity: medium (the parked bedrooms / hospital / seal hold their tiles ('taken by'), the plan's next builds and the DECISIONs until the player cancels each one)
Found: 2026-11-10, Run 16b i2 Valleyhame y376-y378 (bedrooms 58 %, hospital 25 %, seal y376s0b1 build_lost 300+ days; only hand `bp.cancel` made room), Run 16a i1 Basementflew y447-y448 (hospital c1a1c154 build_lost / parked again after 8 retries)
Module: `lua/dfllm/runner.lua` (`Q.lost_cancel`, `Q.replace_cmd`, `end_run`), `dfpilot/wake.py` (`autocancel_hint`), `dfpilot/schema.py`, `dfpilot/fairplay.py`

## Actual
`retry_step` retries a build_lost project `retry_max` (8) times, one per season; then `Q.parked` takes it out of the seal-first pause, the keepers and PLAN_EXHAUSTED after `park_days` and announces it once ("cancel: dfllm cmd bp.cancel ..."). Nothing ever cancelled it ("Never cancelled by the kernel", runner.lua header): its tiles stayed taken for the site ranking, `M.lost(tpl)` kept economy from asking again for farms, `plan propose` kept the template as 'kept', and the player had to cancel and place each one.

## Root cause
`runner.lua` `Q.terminal` / `Q.parked` (about :3800) end the story at "parked"; no code path goes from parked to cancelled. A cancel without undo (`cancel(K, P, false)`, runner.lua:3368) drops only the unbuilt pieces and their jobs, so the reason for never cancelling (an undo removes built work) does not apply to it.

## Fix
`Q.lost_cancel` (runner.lua, in `end_run`, PEACE only, one a run): a project with `blocked == build_lost`, retries spent (`Q.terminal`) and blocked for `queue.lost_days` (config, default 60, 0 = off, 0-3000) is cancelled without undo. PROJECT_BLOCKED (A) `d.autocancel` (days) names the missing pieces, the material and footprint reason (`mat_why`, `remake_why`, `lost_why`) and `d.cmd`, the `bp.place` of the same template and params at S1 (`Q.replace_cmd`; none for a seal: the next audit places a seal if one is still needed). Not cancelled: fortcore, surfacecore, aqshaft, explore, plug, depot (its keeper replaces it), repair, mood projects. At most `lost_max` (2) cancels per template until one of its projects finishes (`rt.lostc`), then it stays parked with the old park event: no cancel / place loop. wake.py `autocancel_hint` tells the player to place it again after `bp sites <tpl> --fresh`.

## Tests
`tests/lua/test_bug637_lost_cancel.lua` (3: hospital cancelled after lost_days once with the command, lost_max, kept templates / retries not spent / lost_days 0), `tests/test_bug637_641_f41_proj.py` (event schema, hint, config range)

## Live check
A build_lost project in PEACE shows `parked` 30 d after its eighth retry and is gone 60 d after the block (kern.log "cancelled by the kernel"), PROJECT_BLOCKED carries `autocancel` and `cmd`; `dfllm cmd bp.place ...` from it takes a fresh site.
