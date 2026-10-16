# Post-mortem: the y421 spring siege of Run 10 (Erushthak Handlelock, region2-site97), 2026-10-16

Fort after a crash restart: autosave 2 (y421 spring d1, the quicksave before the restart wrote nothing), kernel main 94b9eed. Pop 110, 20 recruits.
Result so far (y421 spring d32): **pop 108 -> ~50, soldiers 19 -> 1, all three bridges destroyed, O1 gone, 6 trolls and ~50 goblins inside the fort.**

## Timeline (game days of y421 spring)
| day | what |
|----:|------|
| d9 | game resumed after the load; SIEGE_START 11 visible, later 58 visible (goblins + 6 trolls) |
| d21-22 | BREACH `B1 not up at T+900` (soldiers on/next to the footprint), `O1 not up at T+900`; STRANDED hold then `forced` (hostile 25-29 tiles) |
| d23 | first death (soldier shot); GATE_FAIL O1 `no_lever` after 3073 ticks |
| d24-26 | O1 destroyed (`inspect defense` lists only B1/B2), 40 hostiles on the citizens' walkable group at (100,127,122), the trap hall x=112..121 stayed unused (traps spent 0) |
| d27-31 | 25 soldiers/civilians dead within minutes, `GATE_FORCED B2 raised onto soldier ...` (2 crushed), B1 and B2 destroyed, REFUGE_FAIL Tiefe+ (open to the entrance 95,127,123, 58 steps), civ alert off |
| d32 | 9 invaders east of B2 in the Kern, 6 trolls, pop ~50 |

## Root causes
1. **The audit warned and nothing was built**: `bypass: edge->Z3/Z4 avoids the trap hall (reaches 139,128,117)`; `traps 0`. The `seal` template arrived after the siege.
2. **Drawbridges are not walls**: a troll group destroyed O1, B1 and B2 (building destroyers). The gates only hold goblins without destroyers.
3. **Stations in the kill field**: squads stood at `melee` (130,128,122) and `gallery` (123,123,122) between O1 and B2; with 19 recruits (worn 53 percent, no metal) they died first, then the civilians had no one between them and the invaders.
4. **Late alert**: 22-47 citizens were outside Kern+ when the siege arrived; children died outside.
5. **No refuge**: Tiefe+ refused for beds 8 < 27 and for the open entrance; Kern+ lies on the attack path (audit: `refuge: on the attack path`).
6. **No metal for soldiers**: iron stuck at 8 bars; worn equipment 38-53 percent; Fey/strange moods failed for lack of leather.

## What worked
BREACH -> SIEGE -> RECOVERY -> PEACE after the earlier small sieges (y419/y420), STRANDED rescue/hold, intake refused (Megabeast check), no bridge crush in the small sieges.

## Requests (written to the dev session)
- Readiness gate: while the audit lists a `bypass`, R0 stays UNREADY *and* the plan places the seal pieces automatically (`seal at=audit`) before the next phase.
- Bridges as the last line only against non-destroyers: when trolls/destroyers are seen, evacuate to a refuge that has no bridge in the way instead of relying on gates; refuge beds count must not block the confinement when the alternative is open fighting.
- Stations only inside the core, never in the corridor, when the army exceeds 3x the soldiers.
- Leather/metal supply as plan goals (hunters + tannery in the core; ore search deeper).
