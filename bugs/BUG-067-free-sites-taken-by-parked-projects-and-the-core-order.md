# BUG-067 "only 0 free site(s)" with sites free: ranked sites held by parked projects, depth 12 refused, rooms before a dug core
Status: fixed in FIXCOMMITS (offline, live-untested): `place()` looks down to 60 ranked sites when the best 12 are all taken,
every "no free site" names the holders with their state and the way out, an explore refused at depth 12 names the
shallower depth it accepts, and `plan propose`/`check` and the placement error give the order fortcore -> dug -> sites
Severity: medium (wrong report that blocks growth: `plan check` rejects a plan for lack of sites that exist)
Found: 2026-10-22/23, Run 12 Trussroads and Run 13 Wheelsblows (notes 5, 31 and 41 of bugs/RUN11-offene-bugs-und-FR.md)
Module: `dfpilot/cmd.py` (place, no_site_hint, depth_hint), `dfpilot/plan.py` (core_order_note), `dfpilot/bp/sites.py:531`
(`_rooms`), `:615` (`_explore`)

## Actual (live, from the notes)
- Note 5: `plan check explore: only 0 free site(s)` although many free sites exist; "taken c1a145ce63f0770a02" (a cancelled
  or parked project); explore depth 12 is refused every time (caverns at z127/z131), depth 6-8 goes.
- Note 31: after the abort of y497s2b0 (fortcore S1, `breach:damp`) `bp sites fortcore` said "none (taken by other
  projects or no valid site)" and nothing told which of the two it was.
- Note 41: after `bp.place(fortcore)` the drafts for farms, dining and the office at S1 said "0 free sites" although there
  had been sites before; the order of `bp.place` and `plan propose` was documented nowhere.

## Cause (proved from the code at f17e2b3)
1. **Only the best 12 are looked at.** `ranking()`/`rank_sites` return `RANK_N = 12` sites (cmd.py:58, `sites.rank` greedy
   non-overlapping top n, sites.py:175-210) and `place()` (cmd.py:950-966) tries exactly those. An explore's candidates lie
   on and around the core's stairs, so one big explore project (or any parked one: decision 9, parked projects stay
   parked, bp.cancel is the player's) covers all 12 (`Occupancy.clash`: its tiles and the ring of one tile around them) and
   the 13th..60th site, which are free, are never asked: `only 0 free site(s) ... (12 ranked; taken ...)`.
2. **The message does not say what holds the sites or what to do.** It lists three `anchor~project` pairs; no template, no
   state, no `bp.cancel`; "none (taken ... or no valid site)" of `bp sites` (cli.py) cannot tell a held ranking from an empty
   one.
3. **Depth 12 is the explore default and `_explore` refuses it** when every anchor's shaft reaches an avoided level
   (sites.py:653); the error says "give a smaller depth" but not which. `plan propose` fits the depth for new explore builds
   (`fit_explore`); a draft edited by hand, an older draft or `bp.place explore` without `p.depth` meets the refusal.
4. **Room sites hang on the dug Z4 floor.** `_rooms` takes anchors from `_anchor_tiles` (sites.py:484-492): walkable floor of
   the snapshot inside the manifest's Z4 boxes, and `fort_manifest` has Z4 as soon as the fortcore project is placed
   (its fragment). A snapshot taken before the dig has no such floor: 0 ranked, so farms/dining/office @S1 find "0 free
   sites" right after `bp.place(fortcore)` and until `bp sites <tpl> --fresh` ranks on a snapshot after `s1.dig`. Before the
   fortcore is placed the same call raises "room sites need the fort manifest with zones.Z4". (If the old fort's rooms are
   in the snapshot the ranking is not empty but sits next to the new core's footprint: cause 1.)

## Fix
- **`cmd.place` (S<k> labels):** when the best `RANK_N` sites are all taken or unusable it ranks `RANK_WIDE` = 60 and tries the
  rest (the first 12 of the wide ranking are the same sites, only new ones are tried). The cache of the wide ranking serves
  the next call. `S1` stays "the best free site".
- **`bp sites` (`free_sites`) resolves what `place` resolves:** the same wide ranking, and "none (30 ranked, 1 project(s) hold them): try
  --fresh; taken by ..." with the hint instead of "none (taken by other projects or no valid site)".
- **`no_site_hint`:** `taken by c1a145ce63f0770a02 (explore s2.dig 60%, blocked breach:damp)`, then "a parked or blocked project
  keeps its tiles: `dfllm cmd bp.cancel proj=<id>` frees them"; with 0 ranked for a room template: "no ranked site: farms rooms
  open from the dug Z4 floor of the fortcore (c9 placed; snapshot predates its dig). Order: bp.place fortcore, wait for s1.dig
  (`status` proj), `dfllm bp sites farms --fresh`, then plan propose / check", or "no fortcore project placed (room sites
  hang on its Z4 floor)".
- **`depth_hint`:** an explore refused for an avoided level: "depth 9 would be accepted at [x, y, z]: p.depth=9 (`dfllm bp sites
  explore depth=9`)" (the deepest of `EXPLORE_DEPTHS` below the asked one with a free site), else "no shallower depth (9/6/4/2)
  has a free site either". `EXPLORE_DEPTHS` moved to cmd.py (plan.py imports it).
- **`plan.core_order_note`:** `plan propose` prints, and a rejected `plan check` repeats, "order: fortcore stage 1 (c9: s1.dig
  40%) is not dug yet; dining, farms open from its dug Z4 floor ..." while the state shows a `s1.*` project and the draft has room
  builds (the required order is also in docs/v2/DESIGN.md 5.5).

## Not decided offline
- **Which project held the 12 sites in Run 12/13.** The note names c1a145ce63f0770a02; whether it was parked, cancelled but not
  retired (`bp.cancel` confirmed by kern moves the file to `bp/.cancelled/`; a cancel that kern never answered leaves it) or
  done is not in the notes. Decides it: `ls <save>/bp/` and the project's row in `dfllm inspect projects`
  (`blocked`, `done`); the new message prints both.
- **The fortcore S1 `breach:damp` site (note 30).** The ranking keeps proposing a site where a dig broke into damp ground
  (the snapshot marks are a soft penalty, sites.py `_Pref(marks)`); whether the `damp` mark is in the snapshot of the reclaimed fort
  (`snapshot marks.damp`) decides if the ranker can avoid it. Decides it: `dfllm cmd snapshot purpose=sites` and the `marks` of
  the newest `snap/*.json` around 122,68,132.

## Tests
- `tests/test_c2_reclaim.py`: the 13th ranked site is found past a parked explore (`place` and `bp sites`), the failure names the holder and `bp.cancel`,
  0 ranked with a placed core gives the order, 0 ranked without a core says so, explore depth 12 refused names depth 9 (and
  "no shallower depth"), `core_order_note` (propose/check output).
- All new tests fail on f17e2b3.

Related: BUG-037 (parked projects), decision 9, FR-76, BUG-043 (explore shaft boxes)
