# BUG-366 `bp sites fortcore` stays at 0 ranked after bp.cancel, the draft keeps the cancelled fortcore
Status: fixed (offline, live-untested)
Severity: critical (no core site for 100+ days after every cancel)
Found: 2026-11-04, Run 16a (i1) and Run 16b (i2), main 2fcd6e0
Module: `dfpilot/cmd.py` (sites_box, box_hint), `dfpilot/cli.py`, `dfpilot/plan.py` (stale_core_keys)

## Actual
i1: before the cancel `bp sites fortcore` listed 12 sites; after `bp.cancel` of the fortcore (and `--fresh`) `0 ranked, 0
projects hold them` for good, also with `depth=2`, `aquifer=above`, `--near ... --within 80`. The manifest still held the
cancelled project's breach (water at 99,88,102) and aquifer_levels [105,107,108]; the player blamed them. i2: the same, and
`plan propose` kept `fortcore@same st3` of the cancelled core (ERROR `site 'same': fortcore was never placed from this save
folder`); the player counted the year up.

## Root cause
- Not the breach (checked on the i1/i2 runtime files with the offline ranking): `_dry` keeps off BREACH_R=10 tiles of a breach
  and the wet layers only; the ranking never got that far. The latest sites snapshot of i1 is [43,66,108,86,116,112] (44 x 51
  tiles): the kernel's default sites box is the fort's pieces + margin 16 (`snapshot.lua` margin_steps); with the fortcore
  project gone the pieces were two farms, and a fortcore (u -14..20, v -2..49 = 35 x 52 tiles) fits nowhere: of the anchor x
  rotation candidates 6,946 were 'outside box' (the rest met a wall or water). i2: 1,470 of 2,288. While the project stood, its
  own tiles held the box open. The ranking returned [] and `no_site_hint` said nothing about it.
- Plan: `plan.propose` took every build of the applied plan for done (`done = {_build_key(b) ...}`); a cancelled core's
  `fortcore@same st3` kept `any(t == "fortcore" for t, _ in done)` true, so the BUG-197 reduction (core stage 1 + seal only) was
  skipped and the draft added the same-anchor stages again.

## Fix
- cmd.py `sites_box`: `bp sites fortcore --fresh` asks the kernel for a sites box reaching CORE_PAD=52 tiles round the fort's
  pieces (anchors of the bp files, manifest workshops), 3 levels under and above the surface pieces, the pad shrunk to 40/30/20
  under 300,000 tiles, the kernel's own box when no piece is known or the pieces are spread too far. The explicit bbox of the
  snapshot command is clamped by the kernel as before (no contract change).
- cmd.py `box_hint` (cli): an empty fortcore ranking on a snapshot smaller than the fort says so and names the way out.
- plan.py `stale_core_keys`: with no fortcore project on file (fort.core_any False) the fortcore builds of the due seasons of
  the applied plan that no project stands behind do not count as done; the draft starts the core again (stage 1 @S1 and the
  seal, BUG-197) instead of stages @same. The applied plan itself is not changed (append-only).
- The breach of a cancelled project stays in the manifest on purpose: the water is still there, the ranking keeps 10 tiles away.

## Open
A box chosen by hand (`dfllm cmd snapshot` with a small bbox) still ranks nothing; the hint says why.

## Tests
tests/test_bug364_367_aquifer_core.py (44 x 51 box ranks [], 100 x 100 ranks; box geometry; stale keys and the draft).

## Live check
i1/i2-like: bp.cancel the fortcore, `bp sites fortcore --fresh`: the sites are listed (snapshot box about 150 x 150); `plan
propose` after the cancel: fortcore stage 1 @S1 (and the seal) instead of `fortcore@same st3`.
