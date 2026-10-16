# BUG-018 the refuge audit passes a burrow that contains the fort's entrances and main halls
Status: fixed (offline, live-untested)
Severity: high (the civil alert confined 50 citizens in the area the invaders entered; 50 -> 1)
Found: 2026-10-15 20:00, test fort y376, dfpilot main 95fe16d + local trade fix, first real siege (17 goblins, 2 cave dragons, 5 jabberers)
Module: `lua/dfllm/seal.lua` (refuge audit, `inspect what=refuge`), `lua/dfllm/siege.lua` (burrow choice)

## Actual
`inspect what=refuge`: `Kern+ ok:1 (tiles 6960, drink 1031, food 912, beds 55)`, choice SIEGE/ALERT `Kern+`. The same status line said `R0 fail: audit_old, audit_fail, bypass, refuge_sep, civ_sep, no_inner, no_outer`
for the whole session (`refuge_sep`: the refuge is not separated from the entrances). `Kern+` covers z108-112 of the main halls; the three open entrances (shaft head 55,62,117, north ramp room 61,55,117, east stair 75,70,117)
lead into it. 1360 ticks after the arrival: `BREACH: hostile inside Kern+`; the alert kept all citizens inside.

## Expected
The audit rates a refuge `ok` only if no entrance route reaches it without a door/wall/gate (`refuge_sep`), otherwise `REFUGE_FAIL` names the entrances inside, and the siege module does **not** confine civilians to it
(alert off and flee, or the nearest separated dead end).

## Fix proposal
Take `refuge_sep` and the `entrances` BFS into the burrow `ok` flag; with no passing burrow choose the best dead end (BUG-019) instead of the whole fort.

Related: BUG-019, FR-65, FR-67, `docs/v2/POSTMORTEM-run9-test-siege-2026-10-15.md`

## Fix (Claude, 2026-10-16)
- **Separation in the burrow rating** (`lua/dfllm/seal.lua` `expose`): after every entrance BFS, a flood from the inside tile of each opening
  without a gate on it, over the inside tiles the BFS read (no walk group read again), stopping at built doors, hatches, bridges, floodgates,
  grates and bars. Floods that meet are one component; a component of at most `porch_max` (12) tiles is a porch (a door right behind the
  opening) and exposes nothing. Per burrow: exposed tiles, the entrances that reach it, the fewest steps. A burrow is confined to only when
  no entrance reaches it this way and no visible hostile (census) stands in it; `inspect refuge` shows `ok` (now with the separation),
  `counts` (the old flag), `sep` (1/0/-1 unknown), `open`, `exp`, `steps`. A burrow painted or changed since the flood asks for a new check.
- **REFUGE_FAIL names the entrances**: `alert burrow Kern+ refused (Kern+: open to 1 entrance 20,10,9 stair_up (5 steps)): confining to
  Tiefe+ ...`, `d.open = ["x,y,z kind", ...]`, `d.level`, `d.flee`.
- **No confinement to an unseparated burrow** (`seal.choose`, `siege.set_alert`): Kern+ and `Innen+` are refused; the fallback is the refuge
  (BREACH level, BUG-019) and then the dead end behind the deepest stair (FR-67, at least `dead_gap` 10 steps from any entrance); with
  none, `nil` and `flee`: siege turns the civ alert off even while a reflex lockdown holds it (BUG-011's "never off" yields here), the
  ARRIVAL text says `alert: none (REFUGE_FAIL Kern+, citizens flee)`, REFUGE_FAIL (`flee` 1) goes out at once. siege never substitutes
  Kern+ for seal's pick (live L1b fallback only without seal). `Innen+` is painted without the exposed tiles (and only after the first
  flood), so a fort whose doors stand right behind its entrances keeps BUG-011's interior fallback.
- Side fix (the same renumbering as BUG-021): the entrance check starts over (at most three passes) when the citizens' tiles changed group
  while it ran (edge groups or the BFS read with another numbering).
- Tests: `tests/lua/test_seal_refuge.lua` (BUG-018 cases: entrance into Kern+, door behind it, hostile inside), `tests/lua/test_lockdown.lua`
  (the arrival in a fort with a doorless shaft: no confinement; a door lost during the lockdown switches the sounding alert off), all
  failing on 6e34f8a.
