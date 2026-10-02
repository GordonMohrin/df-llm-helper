# df-llm-helper v3: further specs from Run 5 (Y109)

Addition to `../specs-v2/` (12 specs). These eleven specs came from things that appeared after the v2 list or only
showed up while playing. Framework and Definition of Done as in `../specs-v2/README.md`. All eleven are implemented
as feature plug-ins under `df_llm_helper/features/` (manual: `../manual-v3/`), not yet live-tested.

**Question "Should df-llm-helper take over the access guard?" Answer: yes** (spec 01). It is pure monitoring, repeats
forever and in Run 5 would have caught unnoticed breaches. The prototype (`lua/claude/zugaenge.lua`) is the base of
`python -m df_llm_helper perimeter`.

| No | Feature | Command | Prio | What happened in Run 5 |
|---|---|---|---|---|
| 01 | [Access guard](01-zugangswaechter.md) | `perimeter` | P0 | North opening (23 tiles) and stub stair created by dig programs; armies bypassed the traps |
| 02 | [Dig safety checker](02-dig-sicherheitsprufer.md) | `digcheck` / `dig check` | P0 | Holes to the outside, water access flooded a tunnel, stages ran into forbidden boxes |
| 03 | [Freeze profiler](03-freeze-profiler.md) | `perf` | P0 | 11 s hangs every 25 s from `raster`/`kohle`; diagnosed by hand |
| 04 | [Time-standstill and window guard](04-zeitstillstand-und-fensterwaechter.md) | in `waechter` | P0 | Game stood still 5 min (Info + Help open); MessageBox after trading |
| 05 | [Work-tool manager](05-arbeitsgeraete-manager.md) | `tools` | P0 | 15 instead of 34 work picks; idle 75 % |
| 06 | [Remote-worker protection](06-fernarbeiter-schutz.md) | `remote` | P1 | Fisher starving at the river; 15 dwarves with the fishing labor |
| 07 | [Item hygiene](07-item-hygiene.md) | `hygiene` | P1 | 12,000 loose stacks, no dump zone; boulder rule (never clean up) |
| 08 | [Defense designer](08-verteidigungs-designer.md) | `defense` | P1 | Kill box planned by hand; traps next to a free lane |
| 09 | [Settings manager](09-einstellungen-manager.md) | `settings` | P2 | Population caps in `d_init.txt` only take effect after restart |
| 10 | [Camera director profiles](10-kamera-regie-profile.md) | `camera` | P2 | Auto camera showed sparring instead of furniture, burials, harvest |
| 11 | [Reachability guard](11-erreichbarkeits-waechter.md) | `reach` | P0 | Emergency plugs P1/P2 cut farms, kitchens and stills off the fort for years (493x "Needs plump helmet spawn") |

## Relations
- 01, 02 and 08 form a chain: **check before digging (02)** → **watch accesses (01)** → **defense at the only access (08)**; 11 guards against cutting off your own fort.
- 03 and 04 are reliability guards (game hangs or stands still) and live in the watcher.
- 05, 06, 07 are maintenance rules with loop protection.
- 09 and 10 are comfort; 09 complements the restart runbook (v2-09).

## Measured benefit in Run 5 (for comparison)
The freeze (03) cost about 1.5 h real time unnoticed; the pick fix (05) cut idle from 75 % to 32 %; the access guard
(01) would have reported the two holes at its first check.
