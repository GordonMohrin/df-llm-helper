# BUG-476 The temple's offering place waited 58-240 days for "tool x1": no order made the altar
Status: fixed (offline, live-untested)
Severity: medium (the temple project stalled at 37 %, set aside, no runner slot)
Found: 2026-11-05, Run 16b i2 Roadvises (y378s2b0 58 d, y381s2b0 240 d: "waits: OfferingPlace ... suspended by buildingplan: waits for tool x1")
Module: `lua/dfllm/economy.lua` (`job_missing`, `need_class`, `T.jmat`, `T.jmake`, `M.TOOL_PIECES`), `lua/dfllm/orderlib.lua`

## Actual
`bp.place temple` draws an offering place (`~a`). DF's offering place needs a TOOL item with the use PLACE_OFFERING (DFHack `buildings.lua`; vanilla ITEM_TOOL_ALTAR, a hard-material tool). buildingplan suspended the job until one existed; quickfort `orders` makes none, and economy ordered only doors, hatches, grates and furniture (`M.PIECES`): the temple finished only when a caravan or a mood happened to leave an altar.

## Root cause
`economy.need_class` knew a TOOL only as "tool"; `T.jmake` has no route for it, so nothing made the altar and nothing said why.

## Fix
`job_missing` reads `job_item.has_tool_use`; `need_class` names a TOOL class by its use (`M.TOOL_PIECES`: PLACE_OFFERING -> "altar"); `T.jmat` counts only tools whose definition lists that use (`M.tool_has_use`, a free pick is no altar). `T.jmake`: with no altar free or forbidden and none ordered (`M.tool_orders`: open MakeTool orders of that raws subtype) an order `MakeTool ITEM_TOOL_ALTAR` in stone (tag `dfllm:piece_altar`) goes in while the Masons stand and stone covers it; otherwise MATERIAL_SHORT says "no material for altar: no Masons / no rock" (the temple waits with a reason, not unseen). `orderlib.WS` knows MakeTool (Masons for rock, Carpenters, forge). The project's wait line now reads "altar x1".

## Tests
`tests/lua/test_economy_pieces.lua` (altar ordered once at the Masons; no Masons -> MATERIAL_SHORT; a display-case tool is no altar).

## Live check
A temple stage with the offering place and no altar: kern.log shows the order `dfllm:piece_altar` (MakeTool, altar) and the wait line "altar x1"; the Masons make it; the temple finishes. Check that DF accepts the order (item_subtype ITEM_TOOL_ALTAR, material stone) and that the real job item reports `has_tool_use`.
Open: other furniture tools (display case, bookcase, nest box) are still waited for unseen.
