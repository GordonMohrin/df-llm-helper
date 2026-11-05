# BUG-416 walk-group comparisons mix ids from different ticks: phantom CUTOFF, "out of reach", furniture jams
Status: fixed (offline, live-untested)
Severity: high (Run 16d: bedrooms/dining/tavern stuck 1000+ days, 15 homeless, mood materials "none reachable")
Found: 2026-11-05, Run 16d Mazelanterns y390-y391 (FR-BUGS "BELEG Walk-Group-Inkonsistenz"); main b4087f4
Module: `lua/dfllm/seal.lua` (audit_pass), `lua/dfllm/snapshot.lua` (far)

## Actual
`inspect what=reach` three times in 40 s: main 48575 / 48918 / 49301, the beds in 48575+48583 / 48918+48927 / 49305, the well in a
neighbour id, an old id (30586, 9 beds) in every answer. The fort is one connected fort; the classes read "off the main group":
phantom CUTOFF/REACH events (#4826..#5461), "133 logs out of his reach (another walk group)", "none reachable [133/133/0]" for the mood
material, furniture jobs that never ran.

## Cause
- `seal.lua audit_pass` (the reach/CUTOFF audit) is a coroutine that yields over many ticks (FR-62 slices). It read the citizens'
  groups first and the stock tiles, beds, wells, farm plots, depots and the edge tiles in later frames. DFHack renumbers every walk
  group whenever the map changes (BUG-021, BUG-390), so ids from different ticks were compared. BUG-021 only confirmed a CUTOFF with
  a re-read, the `inspect reach` classes, the REACH flags and the refuge audit kept the mixed numbering.
- `snapshot.lua far` (food/drink/logs "far", mood material reach, tool/item reach checks) compared a tile's group with the group of
  the FIRST citizen of `getCitizens` (a stranded woodcutter or the far side of a brook bridge made the whole fort "far").

## Fix
- `audit_pass`: the yielding loops only collect positions. The citizens and one anchor tile per citizen group (up to 16, the biggest
  first) are then read in ONE frame; their groups are the labels of the audit. Every later frame reads the anchors again first
  (`reanchor`) and gives a tile the label of the anchor whose group it shares at that moment (a connectivity test, never an id carried
  over a renumbering); a tile on no citizen's group gets a label of its own frame. The per-frame bound (FR-62) holds.
- `snapshot.far`: the home set (`home_set`: the group most citizens stand on plus every group with a fifth of them, BUG-390), read from
  the citizens' tiles in the same tick as the tile.
- Already same-tick and unchanged: `seal.groups` (siege STRANDED/CUTOFF confirm, `reread_cut`), `snapshot.groups`, `snapshot.reach`
  (`canWalkBetween`, care's mood reach and water's checks), economy's `home_set` users, the sites export (BUG-390).

## Tests
`tests/lua/test_bug416_417_reach_groups.lua` (far against the home set, not the first citizen; a renumbering between ticks),
`tests/lua/test_seal_refuge.lua` (BUG-021 case now: a renumbering in the middle of an audit leaves no cut and no off-group class).

## Live check
`dfllm cmd inspect what=reach` twice a minute apart on a fort with a brook bridge: `classes.bed/well/farm/food` all on the main group, no
REACH flag "off the main group" while everybody is home; the mood deadline line no longer says "N logs out of his reach" for logs in the fort.
