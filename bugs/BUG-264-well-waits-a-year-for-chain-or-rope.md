# BUG-264 The hospital well waits a year for "chain x1": no producer for a well's chain or rope
Status: fixed (offline, live-untested)
Severity: high (the hospital stays unbuilt: G3/G4 red)
Found: 2026-10-29, Run 15 Earthboat y372-y375, fix6-water
Module: `lua/dfllm/water.lua` (`M.chain_wait`, `M.chain`, `M.chain_metal`, `M.chain_order`, `M.shops`, `phase_sites`)

## Actual
#342 PROJECT_BLOCKED y372s2b2 (hospital) `Well 49,90,135: job 6483 suspended by buildingplan: waits for chain x1` from spring d29 at
47 %. 0 bars (gold/zinc ore only, none found), 0 cloth, 244 thread; the order "Make cloth rope" stood open with no Loom and no
Clothier's shop; `inspect what=orders` 11 orders "workshop missing" for 344 days; nothing asked for those shops until the player
placed Loom/Clothier in y375. water.lua orders buckets (`M.BUCKET_ORDER`), never a chain or rope.

## Fix
Per water run a well under construction whose job wants a CHAIN item none is attached for (`M.chain_wait`: job_items vs the items'
job_item_idx) gets a route, its acts at most every `M.CHAIN_EVERY` (14 days): hard-metal bars (ITEMS_HARD) and a Metalsmith's forge ->
a `MakeChain` order of the metal with the most free bars (`dfllm:chain`); free cloth -> a cloth rope (`MakeChain` material_category
cloth) with a Clothier's shop, else PROJECT_REQUEST workshops why=well types [Clothiers]; thread only -> PROJECT_REQUEST workshops
why=well [Loom, Clothiers] (economy's cloth floor weaves); bars but no forge -> [MetalsmithsForge]; nothing -> the text "buy rope or a
chain (trade.want chain)". A live MakeChain order (quickfort's too) is never doubled, no request while a workshops project is pending.
The route is in HOSPITAL_DRY's cause, kern.log (once per route) and `inspect water_sources` (`chain`).

## Tests
`tests/lua/test_bug262_266_water.lua` `BUG-264 ...` x2 (fail on 2b9c009).

## Live check
Earthboat-like (well suspended for a chain, thread but no cloth): kern.log `water: well N at x,y,z waits for a chain: a rope: thread
244, no cloth: Loom+Clothiers`, PROJECT_REQUEST workshops why=well types [Loom, Clothiers], follow places the shops. With iron bars
and a forge: `inspect what=orders` a `dfllm:chain` MakeChain order of iron. Uncertain: the job_items field names of a buildingplan
well in 53.16 (read with pcall; a miss means no route) and whether DF's rope reaction takes cloth (material_category cloth) as assumed.
