# BUG-564 A bypass over a stair or hatch zeroes the trap count (`traps 0` beside 61 armed traps) and holds max-pop at 40
Status: fixed (offline, live-untested)
Severity: high (the pop target G12 was tied to an unsolvable stair for years; `traps_short` / `defense_short` held max-pop on the citizens)
Found: 2026-11-06, Run 16c i3 Sealcertain y388-y406 (`runs/run-16c/FR-BUGS.md` "pop_ceiling bleibt auf Citizens-Zahl wegen 'traps 0' durch Treppen-Bypass", "Pop-Cap 40 haengt an traps_short, die der Treppen-Bypass erzeugt"; events.jsonl of `E:/DF-test3/dfllm-runtime/r16c4-sealcertain-site97/` read only: `audit failed: 0 traps min, bypass: via stair 54,132,137 -> 55,132,137`, status `ceiling defense_short 40`, brief `traps 63/63`)
Module: `dfpilot/bp/topo.py` (`audit`, new `via_tile`), `lua/dfllm/readiness.lua` (`trap_shortfall`), `dfpilot/wake.py` (`trap_note`)

## Actual
`pop 46 cap 40 gate 40` while plan ceiling was 100: readiness' `trap_shortfall` (BUG-481) reads the audit's `min_traps` (0) and froze max-pop on the citizens (`defense_short`), although 61 traps stood (42 of 56 armed in the hall). `min_traps` was 0 because of the stair bypass 54,132,137 (a hatch since the player built it): the audit counted it as a way in that meets no trap. No seal, no waiver and no template could change that (BUG-376 names `via stair`, no wall fits).

## Root cause
`bp.topo.audit` (topo.py ~455-475): with a bypass `min_traps` is the count once the walls the bypass findings name stand (`choke_pick`, up to `CHOKE_TRY` routes). A route whose foreign part holds only a stair, hatch, door or bridge has no wall tile (`choke_pick` -> None, BUG-376 only names it), the loop stopped, `closed` stayed False and `min_traps` stayed the plain minimum over every route: 0, the bypass itself. So the one unclosable tile zeroed the traps of every other way, and readiness (`trap_shortfall`, `defense_short`, plan.defense_cap) paid for the same bypass a second time.

## Fix
- `topo.audit`: when `choke_pick` finds no wall tile, `via_tile` (the tile `route_via` names) is counted as shut for the trap count (`vias`, up to `CHOKE_TRY` tiles together with the walls): `min_traps` is the fewest armed traps an attacker meets on every way that does not use that tile. The bypass stays its own finding (`fails` `bypass: via stair x,y,z -> ...`, `bypass` True, R0 `bypass`, `audit route:` in status); `info.traps.via` counts the tiles (the follow log line and `dfllm audit` say `counted with N bypass tile(s) ... shut; the bypass itself meets 0 (its own finding: R0 bypass ...)`, `wake.trap_note`). If shutting them does not close every route the count stays the plain minimum (nothing is invented).
- `readiness.trap_shortfall`: with a bypass in the last audit the shortfall text adds `(the bypass is its own item: audit route in status)`.

## Tests
`tests/test_bug564_568_f35.py`: a stair bypass beside a two-trap hall gives `min_traps` 2 (old: 0), `info.traps.via` 1 and the wake note; no other way: still 0; a wall-closable bypass is unchanged (`via` 0, `bypass: wall`). `tests/lua/test_bug564_568_siege_traffic.lua` (the siege test of the round).

## Live check
After the next audit (`dfllm audit`): `traps N` with N > 0 beside `bypass: via stair 54,132,137`; `status` `ceiling` follows the plan again once N reaches the target; R0 `bypass` stays until the stair is dealt with.
Open: the hatch on a stair is still a bypass of the hall for the siege itself (the audit counts hatches open); this bug only stops it from zeroing the other ways' traps.
