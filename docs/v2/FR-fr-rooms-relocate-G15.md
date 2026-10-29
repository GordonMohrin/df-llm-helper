# FR-102 / FR-103: large rooms and a later move into a deep core (G15, also G12, G17)

Gordon's goal G15: beautiful, large rooms, a good overall layout, later a move into a large fortress deeper in the
mountain. Before this package the room templates had fixed small sizes, beauty (DESIGN §5.7) was designed but nothing
smoothed or engraved, fortcore anchored once at S1 and no plan moved anything. Offline only; nothing is confirmed live.

## FR-102 room tiers (`dfpilot/bp/grand.py`)
| Template | large | grand | Zone |
|---|---|---|---|
| `suites` (n 1-30) | 4x4 bedrooms: bed, chest, cabinet, table, chair | 5x5, + a statue | one bedroom zone each, a door at the corridor mouth |
| `grand_dining` (seats 8-80) | the dining layout + a 1-tile walking ring, cabinets | a 2-tile ring with statues every 3 tiles | dining hall |
| `grand_tavern` (seats 8-60) | as dining + 2 goblet chests | as dining | tavern location, 20 goblets |
| `grand_temple` | 9x9, offering place, 2 statues | 11x11, 6 statues | temple location |

- `stage` 1 (class living): dig, furniture, zone, burrow Kern+, manifest room (`use` used, `tier` = the size's room-value
  target unless p.tier is set: suites 1000/2500, halls 2500/10000, temple 2000/10000).
- `stage` 2 (class beauty): `beauty.smooth` (dig `s` over the room and its wall ring), then `beauty.engrave` (`e`). Only
  these used rooms get it, never corridors, shafts or utility rooms. The runner's class gate (CONTRACTS §9.8) runs a
  beauty project only in PEACE with R1 and policy beauty used_rooms. Tiles under furniture or doors are skipped by quickfort.
- Furniture quality is not set: quickfort has no quality filter; the value comes from size, statues and engraving.
- sites: suites and grand_temple are private (rooms.NO_THROUGH); a beauty stage digs nothing and joins no Z4.

## FR-103 the deep core (`grand.deepcore`, `dfpilot/bp/deep.py`, `dfpilot/relocate.py`)
- Geometry (rot 0): anchor = a public core floor; (0,1) vestibule with a door (the old room stays closed), stair shaft at
  (0,2) `depth` levels down; on the deep level a hub (dining zone), dorm, a 15x7 workshop hall (Carpenters, Masons,
  Craftsdwarfs, Still, Kitchen, Mechanics) and a store room. Stages: 1 dig (+ vestibule door; manifest Z4 = shaft and deep
  box), 2 furnish (doors, 12 beds, hub tables, the shops; rooms dorm/wshop/store), 3 move (piles `dfllm-deep-food/furn/
  stone/wood`, zones DeepDorm and DeepDining, Kern+ over the shaft and every deep room; room hall). All class living
  (PEACE only).
- Anchor search (`deep.candidates`, revealed tiles only): public Z4 anchors above the refuge level; every check rect (the
  shaft ring per level, the rooms' ring at the bottom) free of revealed open, wet or marked tiles, no soil mark on the deep
  level (hard stone), no liquid above; the shaft passes no cavern/damp/warm/recorded-cavern level, no aquifer level or the
  one below it, no level within 1 of a recorded breach; the deep level not within 3 levels above a cavern level and not on or
  beside the refuge level; the footprint 2 tiles clear of the refuge rooms and the civilian stairs and of the attack path /
  military pieces. `bp sites deepcore depth=N` ranks this way by hand.
- Known dry level (plan only): `relocate.known_floors` = tunnel levels of finished explore shafts (PROJECT_DONE) without a
  recorded breach of that project; `deep.pick` takes the deepest valid one. Without one the plan note says explore first.

## Plan integration (`plans/year1.json` P7, `plan.propose` -> `relocate.gate`)
P7 (a star phase: Gordon's approval; nothing waits for its deliverables) lists stage 1 and 2 of the four rooms and the
deep core's stages 1-3. `propose` drafts per deliverable through `gate`:
1. a stage already placed (bp file) is skipped; stage k >= 2 needs stage k-1 placed (silent) and done (else a note);
2. readiness: R1 for rooms, R2 for the deep core; no open seal; no drink/food emergency (BUG-243's test);
3. a deep-core stage k >= 2 waits for the plan year after the one that placed stage k-1 (bp id y<Y>);
4. stage k >= 2 is drafted `@same` with stage k-1's params; deep stage 1 at the explicit anchor `A<x>_<y>_<z>_<rot>` with
   the depth; room stage 1 at S1 (suites size large, n = citizens / 3 in 8..30; the halls and temple grand).
Notes: `FR-102/103: <what waits or where the deep core goes>` (deep notes first, at most 3). Rebuild policy and seal first
still filter or pause them (build kind `work`). Status (rank 4) and brief: `rooms: suites large st1 ok, grand_dining grand
st2 40%, deep core z14 st2/3 30% (next move)`.

## Limits (not built)
- The old core is not sealed or emptied: no verb removes a stockpile or zone; after stage 3 the brief line says
  `old piles/zones: by hand` (the player's call, RULES §10 Beauty row).
- No room value is read from the game (no proven DFHack field offline); the line shows stages, not values.
- The runner's daily cavern shaft check and the automatic plug cover `explore` only; the deep shaft relies on the generic
  dig hazard stop (BREACH_STOP) and on the known-dry rule.
- One deep core per fort; `same` follows the template's last placement.

## Live checks
- At P7 with R2: `dfllm plan propose` drafts suites/grand_dining/grand_tavern/grand_temple@S1 st1 and, after a finished
  explore, `deepcore@A..` st1 with its depth; `plan check` places them; `bp preview` of each looks sane.
- After a suites st1 is done: the next propose drafts `suites@same st2`; in PEACE with R1 the engravers smooth, then
  engrave (kern.log quickfort lines, `inspect projects`); the stage never runs in ALERT.
- Deep core: st1 digs the shaft and the rooms; a damp/cavern stop shows BREACH_STOP; st2 next plan year; st3 moves the
  dorm zone and the piles (DF's stockpile list shows dfllm-deep-*), Kern+ covers the deep level (burrow screen).
