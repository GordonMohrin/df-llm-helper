# BUG-130 A fortcore stopped on `breach:damp` is parked for good and never re-sited; no_outer/no_inner stay R0, every drill is refused
Status: fixed in the BUG-130 commit (offline, live-untested)
Severity: critical (R2 and every military goal out of reach for the rest of the run)
Found: 2026-10-28, goal audit of Run 9 (site96: P0 the whole run, fortcore breach:damp) and the Run 14 replay (site90 y707-y708:
"y707s0b1 (fortcore) blocked: breach:damp", PROJECT_BLOCKED breach:damp 6x; SIEGE_UNREADY no_outer 420x, no_inner 312x; DRILL_RESULT
664x "drill failed: raised -1", then refused)
Module: `lua/dfllm/runner.lua` (breach, boot), `dfpilot/bp/sites.py` (fortcore ranking), `dfpilot/plan.py` (fort_facts, propose, check),
`dfpilot/schema.py` (manifest), `lua/dfllm/util/contract.lua`

## Actual
- The fortcore's dig met aquifer seepage (DIG_CANCEL_DAMP). The runner stopped it (`breach:damp`, its applied chunks undone) and after
  `queue.park_days` parked it (BUG-037). A parked project is never retried, and nothing drafted another fortcore.
- The breach tile lived only in the runner's own record (m.runner `br`) and in the rotating event log. The fortcore ranking only rejected
  snapshot marks, so `bp sites fortcore` offered the same or a neighbouring damp site again (FR-76 left this open).
- `plan propose` counted the parked stage 1 as applied (never drafted again) and drafted stages 2 and 3 `@same`, i.e. on the damp anchor;
  a parked stage 3 counted as "under way" for the refuge and stage-3 gates, its manifest fragment (O1) as `o1`; `plan check` printed the
  "fortcore stage 1 is not dug yet" order line for a core that would never dig.
- Without O1/B1 readiness kept R0 `no_outer`/`no_inner`, the drill was refused (`no_outer`/`no_inner`/`no bridges`, BUG-110), R2 impossible.

## Fix
- runner.lua: every breach stop (BREACH_STOP, also a recheck that raises it) is remembered, one entry per project: m.runner `dz` =
  `{pos, why, proj, tpl, t}` (<= 32, newest kept), mirrored into the fort manifest as `breaches` (`runner.note_breach`,
  `runner.publish_breaches`, module fields: runner.lua is at the 200-locals limit). At boot the older records (`br`) of the known projects
  are taken over (`runner.breach_boot`), so the live forts whose fortcore is parked already get their tile.
- bp/sites.py: the fortcore ranking drops a candidate whose dig (the box over all its levels) lies within `BREACH_R` 10 tiles (x/y) of a
  recorded breach (`breaches`, `caverns`) on a level from one above to one below it, and every candidate whose dig reaches a wet layer (a
  level with damp/water stops of `LAYER_MIN` 2 projects: a light aquifer is a layer, a second stop shows it). Nothing left: ValueError
  `fortcore: no dry fortcore site: ... (<the breaches>)`.
- plan.py: `core_breaches` (manifest `breaches`, the state row `breach:<why>`/`parked: breach:<why>`, BREACH_STOP events; a fortcore bp file
  not done, not cancelled) and `core_resite` (`fort.core`: the stopped projects, every fortcore project on that anchor, whether a stage 1 was
  dug there, and whether `free_sites(fortcore)` finds a dry site).
  - **Re-site** (no stage 1 dug on the anchor, a dry site exists or is unknown): propose drafts `{"tpl":"fortcore","site":"S1","p":{"stage":1}}`
    first, the stages that were applied on the old anchor `@same` after it (the phase deliverables add the rest), and notes
    `BUG-130: ... re-sited to S1 ...; then dfllm cmd bp.cancel proj=<old>`.
  - **No dry site** (or stage 1 dug and a later stage stopped): no fortcore build on the anchor (all of them, resp. the stopped stages), a
    `seal at=last` (wall + door on the open ways in, when there is one to close), phase_target held below P3 when no core exists (no refuge
    can be built), and the note says what the gates need.
  - `plan check` (`core_gate`): a new fortcore build `@same` while the core can move needs the re-sited stage 1 before it (ERROR); a plan that
    re-sites nothing gets the warning; with no dry site a build `@same` on the stopped anchor is an ERROR and the closure a warning naming
    what counts. A stopped stage 3 is not "under way" (`refuge_projects` skip), the parked anchor's O1 fragment is no `o1` (only the
    kernel's manifest counts), the core order line ignores a row stopped on a breach, a re-sited stage 1 counts as a refuge fix.
- What counts (RULES §8, CONTRACTS `breaches?`): R0 `no_outer`/`no_inner` clear only with a manifest bridge of role outer (O1) / inner (B1)
  with 2 linked levers (readiness `check_levers`; a bridge replaced by wall + door is no gate, BUG-048). A wall + door closure clears
  `open_perimeter` only. The drill raises the bridges and is refused without them. So the closure keeps the fort shut, not ready: R1/R2 stay
  out of reach until a dry fortcore (or a later standalone gate) stands.
- Review: once the re-site is applied (a fortcore stage 1 stands on another anchor) and the parked project is not cancelled yet,
  `core_resite` sets `moved`: propose drafts no second fortcore (the note names `bp.cancel`), check refuses a new stage 1 @S1.
- Fair play: no draining, no reveal: the ranking reads revealed tiles and the vanilla breach reports only; re-siting is a new designation.

## Tests
- `tests/lua/test_runner_breaches.lua` (2, fail on dec5132): a damp stop lands in `manifest.breaches` with tile, kind, project, template and
  survives a reload; an older kernel's `br` record is taken over at boot.
- `tests/test_bug130_damp_fortcore.py` (13, fail on dec5132): schema and CONTRACTS row; the ranking keeps away from a recorded breach, not
  from one on a level the dig never reaches; no dry site raises; two damp stops on one level make it a wet layer (warm ones do not);
  `core_breaches` from manifest, state row and events, a cancelled project drops out; propose re-sites (stage 1 @S1 first, stages @same) and
  check accepts it; propose closes and holds the phase below P3 when no dry site is left, check warns with what counts; check refuses a
  stage @same without the re-site; a parked stage 3 is no stage 3 under way and no O1; the core order note ignores a parked core; RULES; an applied
  re-site is never drafted again.

## Not built
- A standalone lever-linked drawbridge on an existing dry entrance (a `gate` template with a manifest bridge role): it needs the inside
  side of the opening and lever tiles off the attack path on the snapshot, and live testing; until then the closure keeps
  `no_outer`/`no_inner` red on purpose rather than counting a door as a gate.
- Re-siting a fortcore whose stage 1 is dug and a later stage stopped (the core geometry is fixed): the closure only.

Related: BUG-037 (parked projects), FR-76 (the damp memory left open), BUG-110 (refused drills), BUG-048 (wall + door is no gate)
