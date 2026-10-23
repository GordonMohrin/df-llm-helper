# BUG-045 A stair designation DF took while an alert froze the project is never designated again: the deep shaft stood still
Status: fixed in 73b429d (offline, live-untested): a dig project frozen by a mode marks the freeze; once it runs again
the chunk's walls that lost their designation are designated anew (not counted against `dig_lost`); which DF rule dropped
the designation is not decided offline
Severity: high (an explore shaft, hence the ore search, stops for good; the metal-less fort of Run 11 lost its sieges)
Found: 2026-10-18, Run 11 fort Kilrudrabed (site98), from the game session's note 47 (triage A1)
Module: `lua/dfllm/runner.lua:487` (probe), `:524-548` (lost), `:577-660` (measure_dig), `:3514` and the begin_run freeze
branch (step/begin_run)

## Actual (live, game session, note 47)
"Tiefer Schacht: the stair designation at z127 vanished after a BREACH/lockdown (the ones below stayed) -> the shaft stood
still. Probably the kernel cancels dig jobs in an alert; not restored after the alert."

## Cause (proved from the code at f17e2b3)
1. **The kernel cancels no designation.** The writes to designations are quickfort `run` (dig stages), `undo` (BREACH_STOP
   and cancels) and the seal's gather `x`; none runs in an alert (`allowed` freezes the project: runner.lua:3514 and the
   begin_run branch call no dig code). So DF dropped it while the alert had the miners confined or the project frozen. What
   in DF dropped it is not decidable offline (below).
2. **A designation that was lost before the first measure is read as "never designated".** `probe` answers `skip` for a
   wall without designation that the measure never saw designated (runner.lua:487, "quickfort never designated it": the
   map edge, soil, engravings), and `measure_dig` completes a chunk with its skips counted done. A freeze between the apply
   and the first measure (an alert right after the stage began) hides exactly that: the lost tile is skipped, the stage
   goes on, and the shaft below has no stair above it.
3. **A designation lost after it was seen is re-marked once, then the project blocks.** `lost()` designates the chunk again
   once (`R.rl`), the second loss sets `dig_lost` (runner.lua:543-547) whatever the cause; the block stays until a reload.
   Two alerts in the life of one dig stage (an explore's shaft stage lasts for months) are enough.
4. Nothing marked that the project had been frozen, so neither path could tell an alert's loss from quickfort's refusal.

## Fix
- `Q.froze` marks a dig project with applied chunks that is frozen: by its mode (step and begin_run) or by the civil alert
  being on (`plotinfo.alerts.civ_alert_idx` read each run: the miners are confined to the alert burrow in every mode, a
  reflex lockdown and an infra project in ALERT mode included): `p[<id>].fz`.
- `Q.redesignate` (once per freeze and chunk `fd`, at most `redig_max` 6 times a chunk `ar`; waits while the alert is on;
  never when a DIG_CANCEL_DAMP/WARM report lies near the stage, that stays the BREACH_STOP rule's): the chunk's walls are
  designated anew by quickfort (it marks only walls still standing, so a refused tile stays refused); `lost()` calls it
  first, `measure_dig` calls it for walls skipped as "never designated" (`probe` now answers `skip, 'wall'` for them); the
  chunk counts them pending until they are dug. This loss does not count against the second-loss block. kern.log: `<id>
  <stage> chunk N: K tiles lost their designation (an alert froze the project): designated again (n/6)`.
- Without a freeze everything is as before: a tile never seen designated is skipped, the second loss blocks `dig_lost`.
- A refused tile (map edge, soil, engraving) costs one extra quickfort call per freeze and chunk and is skipped again.

## Not decided offline
- **Which DF rule drops the designation in an alert** (the miners' burrow confinement cancelling the job and DF removing
  the tile's designation, a "cannot reach" cleanup, the announcement of a cave-in): the kernel cannot say. Decides it,
  read-only, at the next alert with a dig project running: the new kern.log line (K tiles, n/6), `dfllm cmd inspect
  persist key=m.runner field=p` (`fz`, `fd`, `ar` per project and stage), the announcement log near the tile (`DIG_CANCEL_*`
  or a cancel text; `inspect` reports), and `designation.dig` of the tile before and after the alert (`snapshot.tile`).
- Whether the redesignation reaches the lost tile of a stair chain that is below the dug part: quickfort designates a
  `j`/`i`/`u` on any standing wall; the miners reach it once the stair above is dug.

## Tests
`tests/lua/test_runner_seal_door.lua`: a designation lost in a BREACH is designated again (never seen), twice in two
alerts without `dig_lost` (seen), the second loss without an alert still blocks, the civil alert on in ALERT mode (wait,
then once), a damp report near keeps the stop's rule, a refused tile costs one extra call and is skipped. Each fails on
f17e2b3.

## Related
BUG-022 (skipped tiles), Run 11 L1/L6 (`lost` without a damp report), BUG-044, BUG-046
