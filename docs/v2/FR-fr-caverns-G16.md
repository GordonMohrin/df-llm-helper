# FR-98/FR-99: the military clears the caverns (Gordon's goal G16)

Status: built offline 2026-10-29 (branch `fr-caverns`), not yet checked in a live game.

## Goal
G16: "Military clears the caverns of beasts". Measure: dead cavern beasts (DEATH of enemies), and the caverns stay sealed until
the fort is ready. Before this, the kernel only sealed caverns: CAVERN_PLUG walls an explore shaft that broke into a cavern.
Nothing ever opened a plug again.

## How it works (`lua/dfllm/cavern.lua`, a new WP6 module, last in `contract.MODULES`)
| Phase | What happens | Ends |
|---|---|---|
| wait | once a game day: plan `caverns.sweep`, phase >= P6, PEACE, no lockdown, no hostile in sight, a rest after the last sweep, a plugged shaft (`runner.cav_sealed`), R1, squad A >= 3 soldiers and worn >= 80 %, a visible cavern beast near the shaft bottom (`snapshot.cave_units`), no great danger | start: `runner.sweep_open`, CAVERN_SWEEP_START (B) |
| open | the `unplug` project: u0.rm (quickfort dig `n`, remove construction), u0.stair `Cd`, u0.hatch `H`, then u1.rm `n`, u1.stair `Cx`. The top is rebuilt while the lower wall still seals the shaft | done; blocked or 4 months: close (why blocked) |
| muster | the hatch is forbidden (`act.door_forbid`, which now also takes hatch covers). Squad A gets a held station order on a revealed floor beside the top (`military.hold_order`, so the posture leaves it alone) | half the squad there: the hatch opens, kill. 2 days: recall (why muster) |
| kill | a held kill order on the visible beasts in the cavern box. The order is renewed as the picture changes | done (3 scans without a beast), losses (1 soldier), worn, great, timeout (20 days): recall |
| recall | a station order. The shaft closes only when no living soldier is below the top, or after 5 x `recall_max` | close |
| close | hatch forbidden, the squad released, `runner.sweep_close`. The unplug leaves the list and its pending removal designation is undone. A `plug` project walls the shaft: lower tile first, the stair removed with `n`, then `Cw`. CAVERN_PLUG done follows when the walls stand | CAVERN_SWEEP_END (A): why, killed, lost, left, sealed |

SIEGE, BREACH, RECOVERY or a drill at any point: the kernel's defense wins. The squad is released at once, so its posture takes
it home through the hatch. The sweep goes to recall, or straight to close while the shaft is still being opened, and ends
with why `siege`. ALERT is allowed: once the shaft is open, the beasts share the fort's walk group, and sense, threat and reflex
see them as usual (lockdown, PREDATOR).

Safety: the plug walls are the seal. The hatch is the bypass while the shaft is open, forbidden whenever the squad is not
fighting. The squad is never walled in. A great danger (forgotten beast, titan, building destroyer) never starts a sweep and
ends a running one: those are Gordon's decision. `runner.cavern_open` (readiness R0 `caverns`) counts a shaft the sweep opened
as open once no sweep runs on it. A shaft left open by a lost sweep (persist `m.cavern` gone) is walled again at the next look.

## Plan phases (FR-99)
- `plans/year1.json` P6 has the deliverable `sweep` (runner CHECK -> `cavern.cleared`: no sweep running, and at the last look
  no plugged shaft had a beast in sight, or none is known). With the module absent, the deliverable is skipped.
- Plan key `caverns: {sweep: bool}`. `plan propose` sets it once phase_target reaches a phase with the deliverable, and keeps it
  from the previous plan. While P6 still needs approval, the notes say to set it. `plan check`: an ERROR before P6; warnings
  for R0, the army's worn %, no plugged shaft, and a P6+ plan without it while beasts are in sight.
- `plan apply` writes plan.json and plan.reload. The kernel reads `K.plan.caverns.sweep`.

## Surfaces
State `cav` {st, why, n, k, l, acc, clr} (only while it matters). Status/brief line: `caverns: sweep kill (killed 1, lost 0):
...; 2 beasts in sight at 1 plugged shaft`. `inspect what=cavern` lists the shafts, their beasts and the first gate. Wake
hint for CAVERN_SWEEP_END. RULES section 7 (the CAVERN_PLUG row), section 10 (water and caverns) and section 11 (P6), all
edited in place.

## Fair play
Units are read only when visible and not hidden (`snapshot.cave_units`, the one place that walks the unit list besides
sense). Tiles are read only through `snapshot.tile` (revealed). Every action is the player's: designations (remove
construction, stairs, a hatch, walls), the hatch sheet's forbid toggle, and the squads screen's move and kill orders.

## Limits (offline only)
- DF physics not proven: that quickfort dig `n` designates removal on the plug walls (and `v.dig` shows it), that a miner
  reaches the lower wall from the rebuilt top, that a hatch cover stands on a constructed down stair, and that removing a
  constructed stair under the hatch works when walling again. The plug's "lower wall given up" fallback applies to the close
  too (only the top is walled).
- The close's `p0.free` (removing the hatch) runs only in PEACE, like the plug's. Mostly not needed, because the wall below the
  hatch already closes the shaft.
- Readiness does not count the guarded opening as R0 while the sweep runs. A follow audit during the sweep may still report
  `caverns` (the hatch is no barrier to the audit).
- One shaft per sweep (the one with the most beasts). Squad A only. No verb starts or stops a sweep by hand: the plan key and
  the modes do.
- Cavern beasts are what `isDanger`, `isUndead`, LARGE_PREDATOR, great danger or building destroyer mark. Harmless cavern
  wildlife is ignored.
