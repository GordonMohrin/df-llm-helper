# BUG-181 A pending workshops project holds back the slab and mandatory workshop requests even when it does not build the missing types
Status: fixed (offline, live-untested)
Severity: medium (live i4: a skip=Masons project held the Masons request back; ghosts waited without a mason's shop)
Found: 2026-10-29, live test round 2 instance i4 (BUG-133d, NEW4; skeptic reproduced with skip=Masons)
Module: `lua/dfllm/economy.lua` (`M.slab_why`, `M.ws_queued`), `lua/dfllm/runner.lua` (`M.pending_types`, `M.uncovered`, the reclaim scan)

## Actual
`M.slab_why` and the runner's reclaimed-fort request tested `runner.pending('workshops') > 0`, whatever types the pending project builds. With
c1a18553e07da50601 (skip=Masons) queued, `slab_why` returned `asked 'queued'` and the mandatory `Masons, Still, Kitchen` request stopped.

## Fix
- economy `M.ws_queued(K, t)`: the pending workshops project whose doc's manifest lists t (as `M.fishery_proj`), `'unknown'` when a pending
  project's doc lists no workshop (held back as before), else nil. `slab_why` says `queued` only then (`sb.queued` = the id).
- runner `M.pending_types(K, tpl)` (the union of the pending projects' manifest workshop types; `all` for a doc without them) and `M.uncovered`;
  the mandatory request asks for the types no pending project builds (`types` = the rest).

## Tests
`tests/lua/test_economy_b2.lua` (a Craftsdwarfs/Jewelers project: the Masons are asked; unknown doc: held back; the old W4 case now with a doc that lists Masons), `tests/lua/test_runner_manifest.lua` (Carpenters pending: only Craftsdwarfs asked) (fail on b805745).

## Live check
In i4: `bp.place tpl=workshops site=S1 skip=Masons` with a ghost and no Masons: `dfllm events --type PROJECT_REQUEST` shows `workshops: no mason's workshop for the memorial slabs` (why slabs, types [Masons]); the runner's `reclaimed fort without ...` request names only the types the pending project skips; `inspect orders` slabs.asked is 1, not 'queued'.
