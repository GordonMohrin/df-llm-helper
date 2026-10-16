# BUG-031 Run 11: no usable refuge at any invasion, thirsty citizens only reported, HOSPITAL_DRY beside a cistern
Status: fixed (offline, live-untested)
Severity: critical (every invasion ended in "no confinement, citizens flee"; confined citizens could go thirsty without a reaction)
Found: 2026-10-16, Run 11 fort Kilrudrabed (site98), y429, pop 54, dfpilot main 99f69f2, from the game session's events
Module: `lua/dfllm/seal.lua` (expose, entrance_doors, choose/rate, alert_burrow, episode, groups), `lua/dfllm/siege.lua` (rescue_step), `lua/dfllm/water.lua` (well_wet, finish, recipe), `lua/dfllm/snapshot.lua` (liquids)

## Actual
A) At every invasion: `REFUGE_FAIL Kern+: open to 1 entrance 127,121,143 Door (62 steps)` and `no confinement, citizens flee`, although fortcore
   stage 3 had built the refuge `Tiefe+`. The named entrance is itself a door.
B) `STRANDED ... no rescue (the outside is not verified sealed)` for single thirsty or hungry citizens, repeated, while the civ alert held them in
   `Tiefe+` without drink; nothing changed the confinement.
C) `HOSPITAL_DRY` every month with `no reachable water >= 4/7 within 30 tiles: a cistern (bp sites cistern)`, although a cistern stands since y426.
   The session also found 7/7 cavern water (a lake of 1146 tiles on z127, x111-161 y48-98) reached through an aborted exploration shaft
   (136,73, z137 down to z127).

## Expected
A) A door on an entrance counts as a barrier for the refuge separation (BUG-018 rule, unchanged), so a refusal names a way in without one and
   what to build there; the fortcore refuge is taken when Kern+ is open. B) When the confinement itself keeps citizens from drink or food on their
   own walk group, the kernel moves or ends the alert. C) The message says why the cistern does not count.

## Cause
A1 **A door on one tile of a wider opening.** The entrance check joins touching inside tiles next to the outside into one opening and reports
   its first tile; the `seal` template (`at=last`, `door on a floor`) puts its door on that tile. The exposure flood (BUG-018) starts from every
   member tile of the opening that is no closer: the door tile is skipped, the doorless tiles beside it are not, and the flood reached Kern+
   (62 steps). The refusal named the opening by its first tile (`127,121,143 Door`), not by the tiles the flood entered by, and
   `seal.entrance_doors` listed the opening as closed (it has a door), so neither the lockdown text, nor SIEGE_UNREADY, nor `seal at=last`
   ever named the open tiles. Reproduced offline: a door on one tile of a 3-wide mouth gives exactly `open to 1 entrance 25,9,9 Door (10 steps)`
   with `entrance_doors.open = []`. A door the template placed and nobody built (a planned building) read like a built one too (`Door`), while
   the flood correctly passed it. The rule itself is right: a built door is a barrier for the separation (no forbidden flag needed), a door
   within `porch_max` tiles behind an opening closes it; a door does not split DF's walk groups, so it never seals for the gates' checks.
A2 **The breach days never ended.** The BREACH level and the dead end hold without counts for `breach_days` (7) from the first such pick
   (`st.bsince`). It was cleared only on a mode change to PEACE without a held lockdown, or by `alert_burrow` in PEACE without `hold`, which
   siege never asks (it asks only while the alert is wanted). A lockdown in PEACE (arrival, predator) that took the dead end opened the window
   and nothing ever closed it; 7 days later every invasion found the BREACH and DEAD levels spent: no burrow, `flee`. Reproduced offline:
   lockdown in PEACE -> Tiefe+ DEAD, 10 days later SIEGE -> `nil, citizens flee`.
A3 **The fortcore refuge was never a SIEGE-level candidate.** Outside BREACH the chain was want -> Kern+ -> `Innen+`; the refuge came only at the
   no-count BREACH/DEAD levels with the 7-day window, even with its own well, food and beds. And fortcore's refuge hangs below Kern+ on the
   civilians' stair without a door or hatch, so any opening that reaches Kern+ reaches Tiefe+ as well: it can only be taken at the DEAD level
   (an opening >= `dead_gap` steps away) until the entrances are closed.
B  **Thirst in the alert's own burrow went unnoticed.** BUG-028's rescue looks only at citizens on a walk group without drink/food (a raised
   bridge in the way). Citizens the civ alert holds in a burrow without drink, with drink on their walk group, were nobody's case. The rescue's
   own refusal `the outside is not verified sealed` is right in a fort with a doored entrance (doors do not split walk groups: the check always
   finds a route), but it did not say where the route was.
C  **The recipe ignored the cistern.** A well counts when water stands under its shaft (any depth: 'w' 1-3/7 or '~' 4-7/7); a Water Source zone
   needs >= 4/7 on its own level; the reach is `near` (30) tiles Chebyshev from the hospital zone (z included), so the cistern's well was dry
   (nothing under it), out of reach, or not built. The recipe came only from the water-sources scan (deep bodies with a bank or a dig) and fell
   back to "a cistern" whatever stood; the cistern PROJECT_REQUEST went out monthly as well. The scan boxes are the hospital zone +-30 x/y and
   +-3 z (`ws_dz`), so the z127 lake counts only for a hospital zone on z124-130 within 30 tiles; `inspect water_sources` shows `boxes` and
   each body's `d` (the coordinator can read the real distance there). Cavern water would have been offered as "zone the water ..." once a bank
   was reachable, against the doctrine (caverns stay sealed).

## Fix (Claude, 2026-10-16)
- **A1** (`seal.expose`): every flood starts from one tile (a seed) and keeps its own label; per opening the seeds in a component bigger than a
  porch are its gaps (`openings[i].gap`, at most `gaps_per` 3). A burrow's `open` lists those tiles (`x,y,z kind`, kind = the tile shape the
  seal template reads), `why` says `open to 1 entrance 25,10,9 floor +1 beside door 25,9,9 (10 steps)` or `(door not built)`, and `fix` is the
  seal template's `at` for them (`25,10,9 floor;25,11,9 floor`, at most 6, unbuilt doors left out). `seal.entrance_doors().open` lists the gaps
  of each opening (`door` 1 beside a door, `note`), so the lockdown text, SIEGE_UNREADY `ents` and `seal at=last` name and close them.
  REFUGE_FAIL: `...: confining to Tiefe+; close it: seal at=...; <tail>`, `d.fix`; `inspect refuge`: per burrow `fix`, `hint` with the
  `bp.place` command.
- **A2** (`seal.episode`): the breach days (and B's marks) end once neither a gated mode nor a lockdown holds; kern.log `seal: episode over:
  breach days and thirst marks reset`. A refuge that has its drink/well and food is not bound to the window. When the window is spent the flee
  text says so (`no separated burrow (Tiefe+: the 7 days without counts are spent (since tick N))`).
- **A3** (`seal.choose`): the chain at the SIEGE and SOFT levels is want -> Kern+ -> `Innen+` -> the refuge.
- **B** (`siege.relax_step`, `seal.dry`): every 100 ticks with somebody over the thirst/hunger mark (30,000), citizens (soldiers and patients
  excluded) standing in a burrow of the sounding civ alert whose walk group has the drink/food: seal marks that burrow dry when its audit
  finds none there (drink items; a well in it serves nobody, the thirst says so), the mark refuses it at every level for the episode, and the
  same step's alert decision confines to a burrow that has it or turns the alert off (`flee`, also in a lockdown). STRANDED (A) phase `relax`
  (`burrow`), REFUGE_FAIL `dry` 1. `refused` with `the outside is not verified sealed` now names seal's leak (`seal.groups().leak`:
  `leak at 30,13,5 Door closed`, or `check pending after the last change`).
- **C** (`water.lua`, `snapshot.liquids`): `well_wet` says what the shaft ends on (water with its depth, dry floor 0/7, rock, a hidden tile);
  the nearest manifest cistern room (tpl `cistern`) to the dry hospital zone is named in `why`, `d.cistern` and the recipe: `cistern <id>: its
  well 77 stands over 0/7 (dry) at x,y,z (cistern max 0/7): fill it (pond zone and bucket carriers, or its pipe)`, `has no well`, `is not
  built`, `is 47 tiles from the hospital (> 30)`; no cistern PROJECT_REQUEST while one stands within `near`. `snapshot.liquids` flags revealed
  cavern tiles (`designation.feature_global`, the export's cavern mark); a body with one is listed in `inspect water_sources` (`cavern` 1) but
  never searched for a bank or a dig and never offered: `no reachable water >= 4/7 within 30 tiles (the cavern water at x,y,z is none: caverns
  stay sealed): a cistern`. No cavern access was added.
- Tests (all failing on 99f69f2): `tests/lua/test_seal_refuge.lua` (3-wide entrance with a door on one tile, then sealed; an unbuilt door; the
  PEACE lockdown's breach days; the stocked refuge at the SIEGE level; the dry mark), `tests/lua/test_stranded.lua` (BREACH in a drinkless
  Tiefe+ -> STRANDED relax, alert to Kern+; the leak in `refused`), `tests/lua/test_water_fr.lua` (dry cistern, far cistern, cavern water,
  `snapshot.liquids` cavern flag).

## Open
- Whether DF needs more than 1/7 under a well (the coordinator's 4/7) is not established here: the kernel keeps counting any water under the
  shaft and now prints the depth, so a live HOSPITAL_DRY line shows it. If GiveWater still fails on a well over 1-3/7, raise the well rule.
- A Water Source zone or well the player already made on cavern water still counts as served (the kernel only stops offering it).
- The fortcore template's refuge has no closer on the civilians' stair, so it is exposed whenever Kern+ is; a hatch at the refuge's stair head
  would separate it on its own (template work, another agent).
- The rescue (BUG-028 a) still needs the outside verified sealed by walk groups; in a fort with a doored entrance that never holds, so citizens
  cut off by a raised inner/core bridge get only the STRANDED `refused` line (now with the leak tile).

Related: BUG-018, BUG-019, BUG-028, BUG-015 (entrance doors forbidden by the lockdown), FR-47, FR-67
