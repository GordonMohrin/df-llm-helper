# BUG-653 A refuge without a pre-plug is trusted against building destroyers
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-11-10, Run 16d i4 Trumpetrealms y438 (same case as BUG-651): `refuge_trust`, readiness and the status line called the refuge fine while a hatch was the only thing between building destroyers and 77 citizens
Module: `lua/dfllm/seal.lua` (`M.refuge_trust`, `M.PP.status`, publish), `lua/dfllm/readiness.lua`, `lua/dfllm/util/contract.lua`, `dfpilot/schema.py`, `dfpilot/brief.py`

## Actual
Nothing in state, readiness or the status line said that the refuge had no wall against building destroyers until they were on the stair.

## Root cause
`refuge_trust` (BUG-049) knows separation, the hatch and hostiles inside; a hatch or door counts as a closer although destroyers break it (BUG-337, BUG-479).

## Fix
`M.PP.status`: 0 none (with the reason: `foot has a stair or ramp`, `no gap tile with a way on`, `its way in is open`, `runner refused`, `a hostile in sight`, ...), 1 building (ring under way, or no spare block for the last wall), 2 ready. State `alert.ref.pp` / `ppw`, `refuge_trust().bd = {ok, why}` (its own field: `ok` is untouched, a foot no ring can be built round must not hold the fort's growth), state `ready.rp` (readiness; not an R0 blocker), the status line `refuge NOT TRUSTED against building destroyers: no pre-plug (<why>)` (and `pre-plug under way`). The kernel builds the ring itself (BUG-651); no plan template is needed.

## Tests
`tests/lua/test_bug651_653_preplug.lua` (1), (4); `tests/lua/test_readiness.lua` (ready.rp); `tests/test_bug651_653_f42_plug.py` (status line, schema, events); `tests/lua/test_seal_refuge.lua` (state shapes with `pp 0`).

## Live check
`dfllm status` of a fort in PEACE: `alert.ref.pp` 1 then 2 within days; a fort with an unusual foot: `pp 0` and the reason in the status line. Open: `plan propose` does not draw a pre-plug draft: the kernel queues it itself, nothing is asked of the player.
