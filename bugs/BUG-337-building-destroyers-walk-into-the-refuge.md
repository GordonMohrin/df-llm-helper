# BUG-337 building destroyers walk into Tiefe+: the deep defense trusts a hatch
Status: partly fixed (offline, live-untested): the open refuge (BUG-336), the text and the soft-refuge flag (state
alert.ref.sf, status); open: ranking burrows by what closes their ways in (walls/raised bridges before doors/hatches)
Severity: high
Found: 2026-11-04, Run 15b (Earthboat, i3, `runs/run-15b-earthboat/FR-BUGS.md` "FORT VERLOREN y387"), kernel main b35af6d
Module: `lua/dfllm/siege.lua` (deep_step), `lua/dfllm/seal.lua` (M.refuge_open)

## Actual
Earthboat y387: SIEGE_DEEP #8745 `4 building destroyers in sight (TROLL x4, 108 tiles from O1): the bridges are no barrier;
civilians to Tiefe+ (the separated refuge)`. 5 trolls broke O1 (#8891 `O1 destroyed`), entered Kern+ (#8907 `hostile inside at
64,82,138`) and Tiefe+ (#9111 `hostile inside at 54,82,132`); 34 then 39 citizens died in two days. The deep defense
(siege.lua:1963-2026, b35af6d) sends the civilians to the refuge because of the destroyers but never asks what closes it: a
building destroyer breaks a door or a hatch; walls and raised bridges hold. Here it had not even a hatch (BUG-336).

## Fix (this round)
- An open refuge is never the civilians' burrow in a fight (BUG-336); SIEGE_DEEP names it first (d.ropen).
- With building destroyers in sight SIEGE_DEEP names a refuge closed only by a hatch or a door: `the bridges are no barrier,
  nor the refuge hatch 55,82,133` (d.soft = hatch|door; seal `M.refuge_open` second value {kind, pos}). The refuge stays the
  deep defense's pick: it lies behind Kern+'s ways in, so its hatch is one barrier more than Kern+ has.

## Fix (review round, the safe core of (c))
- seal `refuge_closure` (public): what closes the refuge's way in against building destroyers: `hard` (a bridge: raised they
  cannot break it), `soft` (a hatch, door, floodgate, grate, bars; the foot doors of BUG-336), nil open/unknown.
- With building destroyers in sight (sense census.h.bd > 0) and a soft-closed refuge: state `alert.ref.sf` 1, status `| refuge
  closed by a hatch/door only: building destroyers in sight break it`; SIEGE_DEEP keeps `nor the refuge hatch x,y,z` (d.soft).
- The refuge is not ranked below Kern+ for it: it hangs below Kern+'s ways in (one barrier more). A chain order putting a
  bridge-closed refuge first was tried and dropped: a bridge cannot stand on the stair head (the only per-burrow closer the
  kernel reads), so it never fires (the test world showed the stair broken by it, reach 0).

## Open
A real preference for burrows whose ways in are walls/raised bridges needs a per-burrow flood with doors and hatches passable
(the exposure flood stops at every closer, seal.lua `expose`). In the forts of the runs the refuge is nested in Kern+, so an
order by a burrow's own closer changes no pick; it is not built. Next round: readiness naming a refuge whose only closure is a
hatch while destroyers are known, and a seal option to close the refuge stair with a wall + a raised bridge.

## Tests (fail on b35af6d)
`tests/lua/test_intake.lua` (BUG-337: trolls in sight, the refuge closed by a hatch -> `nor the refuge hatch 55,82,133`, d.soft,
the alert still on Tiefe+), `tests/test_bug336_337_refuge.py` (SIEGE_DEEP ropen/soft in the schema). Review round:
`tests/lua/test_seal_refuge.lua` (destroyers in sight + hatch -> alert.ref.sf 1, refuge_closure soft; a raised bridge -> hard, no
flag), `tests/test_bug336_337_refuge.py` (brief line, state schema sf).

## Live check
A siege with trolls: SIEGE_DEEP `..., nor the refuge hatch x,y,z; civilians to Tiefe+`. Uncertain: DF's destroyer levels
(BUILDINGDESTROYER:1 breaks doors and hatches, raised bridges hold) as the wiki says; not checked in this DF version.
