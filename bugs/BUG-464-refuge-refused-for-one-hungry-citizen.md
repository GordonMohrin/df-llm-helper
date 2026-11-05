# BUG-464 'Tiefe+ no food for 1 hungry citizen' made the refuge unusable for everybody during the breach
Status: fixed (offline, live-untested); open: nothing carries food into the refuge by itself
Severity: critical (the retreat of 90 citizens was refused)
Found: 2026-11-05, Run 16a i1 Syrupobeyed y387 (events #19480, #19708: `REFUGE_FAIL alert burrow Tiefe+ refused (Tiefe+: no food for 1 hungry citizen): no confinement; ... citizens flee on their own`)
Module: `lua/dfllm/seal.lua` (`dry_why`, `rate`, `choose`, `leave_why`, `alert_burrow`)

## Actual
siege's `relax_step` marked Tiefe+ dry (`seal.dry`) for ONE citizen over the hunger mark (75,000) with food on his walk group. `rate` refused a
dry burrow at every level for the rest of the episode. When O1 fell and Kern+ was breached (hostile inside at 63,114,138) nothing was left: no
confinement, the civ alert off, about 40 citizens killed while they fled.

## Root cause
`rate()` (seal.lua) returned `false, dry_why` before anything else: a mark counted the same for 1 citizen and for 40, in a BREACH and in a quiet
siege, for the last burrow as for one among several.

## Fix
- `dry_why` also says whether the mark is FEW (`seal.DRY_FEW` 3, or under a fifth of those inside).
- After `seal.lost` (the outer line is gone, BUG-462) a FEW mark neither refuses the refuge (`rate` `lenient`) nor makes the citizens held
  there leave it (`leave_why`).
- Last resort in `choose`: in a BREACH or after a loss, with everything else refused, the refuge separated, reachable, free of hostiles and
  inside the breach days (or with its drink), it is taken at BREACH/DEAD whatever the dry mark says (`r.last`): it takes them in short instead
  of 'no confinement'. A hostile in the refuge, the open stair head (BUG-336), the spent breach days and a SIEGE ask keep their refusals.
- REFUGE_STOCK (A, `fight` 1, once per game day and per news): `<refuge> took the citizens in short of food (...) as the retreat of the BREACH`,
  with the existing inspect command. No kernel command carries food in during a fight (no actuator): the stock ask is the player's.

## Tests
`tests/lua/test_bug462_464_retreat.lua` (4, all fail on the old code: one dry citizen with Kern+ breached, the held refuge after a loss, the
last resort with a 40-citizen mark, seal.lost); `test_seal_refuge.lua` and `test_stranded.lua` unchanged (a quiet BREACH still sends
dehydrating citizens to a closed Kern+).

## Live check
After a breach with a dry-marked refuge: alert burrow Tiefe+ (REFUGE_FAIL class A names the pick, REFUGE_STOCK `fight` 1), no `civ alert off ...
flee` while the refuge stands separated.
