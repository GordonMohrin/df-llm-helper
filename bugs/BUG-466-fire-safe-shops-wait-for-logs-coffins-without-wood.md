# BUG-466 furnaces and forges wait 300+ days for 'building material' with 200 logs in stock, nobody says why; coffins never use the last logs
Status: fixed (offline, live-untested); open: whether buildingplan takes blocks for a furnace job the way `getGlobalSettings` suggests
Severity: high (Mazelanterns: 17 ghosts, 95 bodies without a coffin; Basementflew: no glass furnace, no forge)
Found: 2026-11-05, Run 16a i1 Basementflew (`runs/run-16a/FR-BUGS.md` "Werkstaetten (GlassFurnace, MetalsmithsForge, Mechanics) stehen ewig bei 50-59 % 'waits for building material'"), Run 16d i4 Mazelanterns (Geister/Sarglosigkeit)
Module: `lua/dfllm/economy.lua` (`building_info`, `fire_safe`, `bm_route`, `bm_kind`, `mat_for`, `T.jmat`, `T.jmake`, `supply_wants`), `lua/dfllm/care.lua` (`coffin_order`, `coffin_wants`), `lua/dfllm/trade.lua` (`coffin` token)

## Actual
Basementflew y374-y376: four `workshops` projects 300-395 days at 50-59 % 'waits for building material' (GlassFurnace, MetalsmithsForge; the kernel's events name only these two kinds) with 203 logs in the fort, while shops any material builds were built from logs without trouble. Nothing was ordered and MATERIAL_SHORT stayed silent. Two moods died for glass / gems. Mazelanterns y405: 43 bodies, `no_coffin 36`, coffins want 43, stock 11, no stone and 20 logs held back as the coffin keep; nobody asked the caravans.

## Root cause
`economy.bm_route` answered `logs` for ANY building waiting for building material while a log was in stock: `T.jmake` then did nothing, no short, no order. A furnace and a forge (MetalsmithsForge, MagmaForge) need fire-safe material (stone or blocks, logs burn). `care.coffin_order` kept `coffin_wood_keep` (20) logs back whatever the situation and had no way to ask for material when `q.missing > 0` (only the DECISION_NEEDED).

## Fix
- `economy.fire_safe(kind, sub)`; `building_info` records the subtype and `fire`; `T.jmat` keeps the fire-safe building material of the furnaces / forges as its own class (`q.fire`), `bm_route(r, s, kind, fire)` never answers `logs` (and never switches buildingplan's logs on) for it: MATERIAL_SHORT "no material for furnace: no rock, no blocks (logs burn: a furnace or forge needs stone)", `mat_for(K, 'furnace', n)`. Shops any material builds (Carpenters, Kitchen, Still, Butchers, Farmers, Craftsdwarfs, Mechanics, Masons ...) keep the logs route.
- `economy.supply_wants`: `stone` (furnaces/forges waiting, up to 6) while that material is short.
- `care.coffin_order`: with no hard stone and a body waiting the logs go down to `care.coffin_wood_floor` (5); `care.coffin_wants()` (wood with a carpenter's shop, stone with masons, always `coffin`, up to 30) joins the caravans' wants through `economy.supply_wants`; trade knows `coffin` / `coffins`.

## Tests
`tests/lua/test_economy_pieces.lua` (BUG-466), `tests/lua/test_care_coffins.lua` (BUG-466; the BUG-126 material alarm test uses 4 logs, below the floor).

## Live check
A fort with logs and no stone and a planned GlassFurnace: MATERIAL_SHORT names the furnace, `trade.want` shows `stone`; a fort with 95 bodies and no stone: coffins in wood down to 5 logs, `coffin` / `wood` in the caravan wants.
Open: the caravans must bring stone / logs; a fort without a depot (Mazelanterns y405) still waits for the depot.
