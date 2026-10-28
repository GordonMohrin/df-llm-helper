# BUG-118 `bp.place tpl=workshops only=Millstone|Quern` is refused as "unknown types"; the template knows 17 shop types, DF 53.16 offers more
Status: fixed in the M6 commit (offline, live-untested): Quern, Millstone, Ashery, Dyers, MagmaForge, Kennels and Siege join the `add`/`only` types
Severity: low (a missing building the player could place by hand; a mill shop for plant processing never came)
Found: 2026-10-26, Run 14 (region2-site90), game session note 83 ("FR 83")
Module: `dfpilot/bp/rooms.py` (`EXTRA`, `SHOP_SIZE`, `workshops`), `dfpilot/bp/emit.py` (`MATERIAL`), `dfpilot/cmd.py` (`place`)

## Actual
`only=Millstone` and `only=Quern` answered `workshops only=Quern: unknown types ['Quern']; known: Carpenters, ..., Farmers`. The Metalsmith's
Forge x76 stuck orders (Run 14 y707) could be re-placed with `MetalsmithsForge`, the mills could not.

## Cause (proved from the code at 32994bb)
- `dfpilot/bp/rooms.py:30` `EXTRA = [Still, Kitchen, Butchers, Fishery, Farmers]` is the only list of non-moodable shops;
  `dfpilot/cmd.py:1025` (`place`, `only=`) accepts the names of `MOODABLE_TYPES + EXTRA_TYPES` and nothing else.
- quickfort's `build.lua` (DFHack 53.16, `scripts/internal/quickfort/build.lua` workshops table) places the other workshop types
  `df.workshop_type` has: `wq` Quern and `wM` Millstone (both exactly 1x1: `min_width = max_width = 1`), `wy` Ashery, `wd` Dyer's Shop,
  `wv` Magma Forge, `k` Kennels and `ws` Siege Workshop (both exactly 5x5), `wS` Soap Maker's and `wp` Screw Press (`Custom` workshops
  with `custom = 0|1`).
- The layout (`rooms.py` `workshops`) put every shop in a 3x3 cell: a 1x1 shop would be refused by quickfort ("extent"), a 5x5 shop does not
  fit a cell.

## Fix
- `EXTRA` gains Quern, Millstone, Ashery, Dyers, MagmaForge, Kennels, Siege (their quickfort keys); `SHOP_SIZE` says which are 1x1 and 5x5.
  A 1x1 shop is one tile in the middle of its 3x3 cell; the two 5x5 shops go into a strip of their own below the rows, 6 apart, so the layout
  of the usual 3x3 shops (and its golden files) does not change. The materials list counts Kennels (`k`) as a workshop.
- Not added: Soap Maker's and Screw Press. They are `Custom` workshops (`df.workshop_type.Custom` plus a custom index); the manifest, the kernel's
  census and the runner's reconciliation know a shop by its `df.workshop_type` name, so a second name would never match a standing building.
  They need their own name in all three places; left for a request.
- Nothing else changes: `only=` and `add=` take the new names, an unknown name is still refused.

## Not decided offline
- Whether DF takes a 1x1 Millstone/Quern inside a 3x3 cell with a wall ring around it (quickfort accepts the extent; the dwarves need an
  adjacent floor tile, which the cell's other tiles give). A Millstone needs power (a mechanism-linked axle) which no template builds.
- The 5x5 Kennels and Siege Workshop need a room of 11+ tiles: `sites.rank` finds the site, `bp sites workshops only=Siege` says if none fits.

## Tests (`tests/test_m6_orders.py`)
The keys and sizes, a 1x1 Quern/Millstone, all seven new types in one room without overlap and inside the dug box (`bp.check_doc`, schema),
the default 12-shop layout unchanged, `cmd.place only=<each new name>`, an unknown name still refused. All but the layout test fail on 32994bb.
