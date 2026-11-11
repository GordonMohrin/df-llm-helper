# BUG-702 Plant eaters reflex cleared still hold bridge B1 up
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-11, Run 16b i2 Whirledrampart y419-y423 (main 932ff09, woolly mammoths 29103 to 29106 and a calf, ~600000 cm3, never attacked)
Module: `lua/dfllm/sense.lua` (`consider`), `lua/dfllm/reflex.lua` (`pv_plant`), `lua/dfllm/gate.lua` (`list_dist`, `breach_safe`)

## Root cause
BUG-672 clears a passive plant eater in reflex (`far.ids/hl/pv`) and threat subtracts it, but sense still measured every listed unit against the bridge footprints: `sense.lua` `hs.near_bridge[b.name]` (the loop in `consider`) took the cleared mammoths too. `gate.down_guard` (`gate.lua`, 'down refused: hostile within 30 tiles', `DOWN_GUARD`), siege's `near_bridge` (CUT_NEAR forced raise 'B1 raised although it cuts 9 citizens off', the rescue abort, the stuck-bridge test) and the inner hold all read that map; `gate.list_dist` (unmanaged bridges) and `breach_safe` read the raw list. So `lever B1 down` and the rescue were refused for good while the herd stood within 30 tiles and B1 stayed raised between 25-31 citizens and their food and drink (HUNGRY 30-38, 7 drowned).

## Fix
`reflex.pv_plant(K)` (new, public): the ids reflex cleared as passive or released by the operator, never an unreachable hostile. `sense.hscan_begin` fetches it once per scan (`hs.pvp`); in `consider` a plant eater (`hbeast`) of that set without a killer mark is `clr`: its list entry carries `pp = 1`, it sets no `near_bridge` distance (and no `db`), it is not counted into `rin`, and `census.h.vpp` counts them. `gate.list_dist` and `breach_safe` skip `pp` entries. A kill (`mark_killer`) or a carnivore never matches, an invader or a building destroyer never is a `hbeast`.

## Tests
`tests/lua/test_bug702_704_cleared.lua`: the guard holds for an uncleared mammoth and lets the lever through after the clearing (fails on the old code), a kill brings the bridge distance back at once, the operator release, an invader never carries `pp`; siege traffic: eight goblins outside with and without a mammoth beside B1 (same mode changes, O1 and B1 up, recall, down refused), two goblins at B1 beside a cleared mammoth (B1 stays up, `near_bridge` counts the goblins).

## Live check
A cleared mammoth within 30 tiles of B1 in PEACE: `lever bridge=B1 want=down` is accepted. Open: the unreachable kind ('u') still counts for the bridge guard (it may stand at a raised bridge); the 3 quiet days of BUG-672 still pass before the clearing.
