# FR-96/FR-97: traps at every way in (goal G14, package fr-traps)

Status: built offline on 2026-10-29. Not yet checked in a live game.

## Problem
G14 ("Alles mit Fallen gesichert") was red in every Run 15 fort. The only traps were the 41 stone-fall traps that
fortcore stage 4 puts in the Z2 hall (P6). `traps N` counted only the audit's cheapest route through that hall. A side
way in, such as a seal door or a door the player built in the perimeter, never got a trap. Nothing looked at a trap after
it was built:
- a cage trap that caught something stayed full;
- a destroyed trap stayed gone.

## Pieces
| Piece | File | What |
|---|---|---|
| template `traps` | `dfpilot/bp/traps.py` | One build stage of cage traps (`Tc`) or stone-fall traps (`Ts`) on absolute tiles, like `seal`. It uses quickfort orders (mechanism, wooden cage) and writes a manifest entry per way: `traps` `{id T<x>_<y>_<z>, kind, way, tiles}`. |
| ways in | `bp.traps.ways_in` | Works on the newest snapshot (revealed tiles only) with doors, hatches and bridges closed. A door counts as a way in when an outside walkable tile (reached from `topo.sources`) and an inside one (reached from the fort's own boxes) are among its 8 neighbours. Its lane is every outside floor tile around the door. With depth 2 or 3 the lane also takes the tiles straight out from the door. A tile that is already a trap is left out, and so is a tile a traps project under way builds. |
| CLI | `dfpilot/traps.py`, `cmd.place` / `free_sites` | `at=ways` (or empty) fills in the lanes still to trap. `at=hall` fills in the stone-fall tiles of a finished stage 4 that the snapshot shows as floor. When nothing is left, the call raises `SealClosed`: `plan apply` leaves the build out and `bp.place` refuses it. |
| fortcore stage 4 | `fortcore._manifest` | Manifest entry `traps` id `Z2` with the 41 hall tiles. |
| plan | `plan.propose` / `plan.check` (`traps.draft` / `traps.gate`) | From P5 on, while a way wants a lane, `propose` drafts `{"tpl":"traps","site":"S1","p":{"at":"ways"}}` once per plan year and `check` warns while the plan has none. Not during the rebuild policy. `build_kind` is defense, so a seal does not pause it. |
| kernel | `lua/dfllm/traps.lua` (module `traps`, every 1,200 ticks) | Reads the trap buildings (type, built, `ready_timeout`, a cage in a cage trap) and the census `u.caged` (cage, then its holder building, gives a full cage trap). Publishes state `traps` {n armed of m listed, b, w/wn ways, f full, c free cages, l lost, lh, ord}. In PEACE it orders `MakeCage` (wood, tag `dfllm:traps`) when the free cages are fewer than full + without a cage + `cage_spare` (2). It orders at most `cage_batch` (5) at once and keeps one live order. A Z2 zone without the Z2 entry (an older fort) counts its built traps through `snapshot.traps`. |
| status / brief | `traps.status_line` | One line, for example `traps 38/44 ways 2/3, 1 full, cages 0 (MakeCage x3 ordered), lost 2 (bp.place traps at=hall)`. |

## Safety
- **Where lanes go.** A lane lies outside a door. Lanes never go on a door, stair, ramp, bridge or edge tile, and never
  inside the manifest's own geometry: zones Z1-Z4 (bailey, depot, hall), rooms, killboxes, stations, stairs and the
  refuge.
- **Open ways.** An open way in has no door, so it gets no lane. `seal` closes it first, and the room behind it then
  counts as outside.
- **Hall.** The hall is stone-fall only. DOCTRINE: caged invaders are freed by their comrades, and `topo.audit` fails a
  cage trap on the main path.
- **Citizens.** DF traps do not fire on citizens or their tame animals. In a fight the door is the citizens' bypass (the
  lockdown forbids entrance doors).
- **What the kernel does.** The module only reads. Its one action is a work order in PEACE, nothing more. Siege and
  lockdown keep the final say.
- **Fair play.** Every trap is a quickfort `#build` that a player places from the build menu. Every cage is a work
  order.

## Limits (deliberate or unproven)
- **Ways checked.** Only doors on the same z level count for `at=ways`. A hatch at a stair head gets no lane. BUG-317
  (Earthboat, bridges only: `0 door(s)`, traps 0): `at=bridges` lays a stone-fall lane of 8 tiles behind each outer and
  inner bridge (O1: the hall past the bailey exit; B1: the killing field K1), off Z1 and the bridge rings; plan propose
  drafts it from P5 beside `at=ways`.
- **Kind and size.** One kind per project. At most 6 ways and 16 tiles per project, and `at` fits in 200 characters
  (whole lanes only). The next `traps at=ways` takes the rest.
- **Mechanisms.** No mechanism orders of its own. Each placed project's quickfort orders cover them, and economy's
  supply pass (fix6-econ-supply) owns the stock. `traps.need` gives economy the number of listed traps that have no
  building.
- **Readiness.** It does not judge a way per trap. R2 still uses the audit's `min_traps`.
- **Wagons.** The wagon path to the depot is not computed. Lanes stay off Z1 and the edge tiles, and side doors are not a
  wagon route.
- **Detection guesses.** A cage trap counts as without a cage when no item in `contained_items` is an `item_cagest`. A
  trap counts as full when a caged unit's cage is held by the trap building, or when the trap's cage holds any creature (its
  CONTAINS_UNIT ref; a caught wild animal is in no census list). Both are unproven live.

## Live checks
1. In a fort past P5 with a seal door, run `dfllm bp sites traps --fresh` and then `dfllm plan propose`. The notes
   should say `FR-96: N way(s) in without a trap lane (x,y,z ...)`. `plan apply` should place `traps@S1` with
   `at=x,y,z:dx,dy ...` (cmd.log). After apply, check:
   - the cage traps stand outside the door;
   - the work orders show a mechanism and a wooden cage per trap;
   - `inspect manifest` lists `traps` `T<x>_<y>_<z>`.
2. `dfllm status` should show `traps N/M ways w/wn`. After a capture, check:
   - `f` grows;
   - kern.log `traps: order <id> MakeCage xN (wood)`;
   - the order is on the work orders screen;
   - care marks the full cage for dumping and the trap is reloaded (state `c` and `f` fall back).
3. Remove a hall trap (deconstruct it) in a fort with stage 4 done. Status should say `lost 1 (bp.place traps
   at=hall)`. Then `dfllm cmd bp.place '{"tpl":"traps","site":"S1","p":{"at":"hall"}}'` should place one stone-fall
   trap there.
4. If a cage trap shows `cages` short while its sheet shows a cage, read `contained_items` (item types) of that trap
   building read-only.
