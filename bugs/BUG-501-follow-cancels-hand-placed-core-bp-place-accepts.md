# BUG-501 A hand-placed fortcore is accepted by bp.place and cancelled by follow 20 s later (BUG-441 re-site), the player is not told why
Status: fixed (offline, live-untested)
Severity: high (the player's decision for a core was undone silently; the fort stays without a core)
Found: 2026-11-05, Run 16a i1 Basementflew y396 (`runs/run-16a/FR-BUGS.md` "Runde 9 i1 Start"; runtime `r16a5-basementflew-site97/` cli.log lines 1482-1487, kern.log "queued c1a1ad00a5756e1c01 (fortcore, 5 stages)" and "258 dig designation(s) ... removed", read only)
Module: `dfpilot/plan.py` (`core_refusal`, `core_deepest`, `core_over_aquifer`), `dfpilot/cmd.py` (`send`)

## Actual
`bp.place tpl=fortcore site=S1` (anchor 75,102,131, stage 1, no p.aquifer) was answered `ok queued c1a1ad00a5756e1c01 (fortcore, 5 stages)`. 17 s later follow sent `bp.cancel` (cli.log 1484, by follow, "7 applied dig chunk(s) taken back"). The only trace was a PROJECT_STALE and a DECISION_NEEDED `core_resite` from follow ("reaches down to z123, the aquifer is known at z127, z126, z123, z120, z119, z116"): the player who reads the command replies saw an accepted core and a silent cancel.

## Root cause
`dfpilot/wake.py _check_core_site` (BUG-441, line ~1203) cancels a never-dug fortcore stage 1 whose deepest level is not under the lowest known aquifer level (`plan.py core_over_aquifer`), but `cmd.send` / `cmd._place` placed the same core without any such test: the follower and the verb disagreed about what a valid core is.

## Fix
- `plan.core_deepest` / `plan.core_refusal(save_dir, doc, snap)`: the same test as `core_over_aquifer` (anchor z - 2 - depth - refuge, not under `known_aquifer_levels()[0]`, no p.aquifer / retrofit, stage 1) applied to the emitted document.
- `cmd.send` (the `bp.place` path, after `emit_bp(write=False)`): a fortcore stage 1 that follow would cancel is refused at once with `BpError` "BUG-501: fortcore stage 1 at [...] reaches down to zN, the aquifer is known at ...; follow would take it back within a minute. Pass the aquifer: `dfllm plan propose` ..., or p.aquifer=above ..., `bp sites fortcore aquifer=pass`". No bp file is written.
- follow's cancel is unchanged (a core with a dug tile is never cancelled, PROJECT_STALE and DECISION_NEEDED stay).

## Tests
`tests/test_bug501_505_f31.py` (2: `core_refusal` on the tested cases and its agreement with `core_over_aquifer`; `bp.place` refused with the reason and nothing written, `p.aquifer=pass` placed). Both fail on d756064.

## Live check
`dfllm cmd bp.place tpl=fortcore site=S1` on a fort with a known aquifer and no p.aquifer: ERR "BUG-501: ...". With `p.aquifer=above` or `pass`: placed as before.
