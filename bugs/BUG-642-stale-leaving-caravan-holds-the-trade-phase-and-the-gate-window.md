# BUG-642 A caravan listed as Leaving for years holds the trade phase, the gate window and the supervisor flag; nothing says why no caravan comes
Status: fixed (offline, live-untested); open: the kernel does not remove the stray merchant itself (D-08, no `flags1.left`)
Severity: high (no trade for 6 game years in a fort without iron, wood or mechanisms)
Found: 2026-11-10, Run 16c i3 Wallfree y376-y389 (`inspect trade`: Catten `state=Leaving left_ticks 0` for years, no caravan since y383, merchant 26506 `merchant=1 wild=1` wandering ownerless from 82,1,148 to 54,28,148; the first `left` came 3.9 years after the visit began)
Module: `lua/dfllm/trade.lua` (`track_visits`, `stale_visit`, `overdue_check`, `M.step`), `lua/dfllm/seal.lua` (`M.depot_access`), `lua/dfllm/sense.lua` (`M.merchants`)

## Actual
DF keeps a caravan on `plotinfo.caravans` while one of its merchants is still on the map; it sends no new caravan of that civ meanwhile. The kernel took that entry for a visit in progress for years:
- `trade.lua` (old `M.step`, LEAVE branch, HEAD 1981): the phase LEAVE ended only when the caravan vanished from the list, so `maybe_begin` (IDLE only) never started a visit for a caravan of another civ;
- `state.trade.caravan = 1` the whole time (old `M.step` 1988): gate `window_open` (gate.lua:2645) held the PEACE window open (outer bridge down, `o1_window`), the supervisor's `_caravan` too;
- nothing said how long it lasted, which merchants were left, or whether the depot could be reached at all.

## Root cause
The visit ends in the kernel's records only when DF drops the caravan. `read_caravans` (trade.lua) lists every state but None; a `Leaving` caravan that never leaves was never told from one that is walking out.

## Fix
- `CFG.LEAVE_STALE` (7,200 ticks): a caravan Leaving that long (`v.lv`, `v.stale` in the visit record, trade.lua:1548) is stale (`stale_visit`, trade.lua:1459): CARAVAN `stale` (B) with days, merchants on the map (ids and positions via `sense.merchants`), merchants off the map, and `seal.depot_access`'s answer; `fix/stuck-merchants` runs once (it dismisses merchants that are off the map); DECISION_NEEDED `caravan_stale` (A) when merchants stand on the map (kill a lone stray one with `squad.sortie`; the kernel writes no `flags1.left`, D-08).
- A stale caravan no longer holds the LEAVE phase (trade.lua:2173; the next caravan of any civ starts a visit), opens no O1 window (trade.lua:2157) and is not counted in `state.trade.caravan` (new `state.trade.stale`, trade.lua:2185).
- `seal.depot_access` (seal.lua:5230, read-only, from the last reach audit): does a built depot share a walk group with a map-edge tile? Said in the stale event, in the `overdue` event and in `inspect what=trade` (`depot_access`).
- `CFG.OVERDUE_TICKS` (504,000; `overdue_check`, trade.lua:1480): no caravan listed for a year and a quarter -> CARAVAN `overdue` once per period with the depot access (`last_caravan_days` in `inspect what=trade`).
- `inspect what=trade` marks a stale caravan (`stale`, `leaving_days`, `merchants_on_map`, `merchants_off_map`, ids and positions).
- Own code that keeps wagons out: nothing in the kernel forbids or closes a depot; the seal's wall reach checks (BUG-458) keep the depot on the citizens' group, but nothing checked it against the map edge until `depot_access`. In Wallfree the depot stood on the surface (75,62,148) and the seal had no part in the missing caravans.

## Tests
`tests/lua/test_bug642_644_trade.lua` (4: stale event once and `fix/stuck-merchants` once, decision, state; no O1 window; the phase of a traded visit ends and the next caravan begins; overdue with depot access), `tests/lua/test_seal.lua` (`depot_access` field / hall).

## Live check
`dfllm cmd inspect what=trade` with a long-Leaving caravan shows `stale=1` and the merchants; kern.log `trade: caravan X still listed Leaving ...`. Not tested live: whether `fix/stuck-merchants` frees a caravan whose merchant is active, and whether killing the stray merchant makes DF drop the caravan.
