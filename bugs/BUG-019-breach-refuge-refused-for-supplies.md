# BUG-019 during a breach the only reachable emergency burrow is refused for missing supplies
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-10-15 20:03, test fort y376, siege in progress, dfpilot main 95fe16d
Module: `lua/dfllm/seal.lua` (refuge audit), `lua/dfllm/siege.lua` (BREACH choice `Tiefe+`)

## Actual
`inspect what=refuge`: `choice BREACH: burrow Kern+ want Tiefe+` and `Tiefe+ ... missing` the whole session. When the burrow was painted by hand (shaft 30,66,z80-108, 29 stair tiles, a dead end below the halls),
the kernel answered `REFUGE_FAIL alert burrow Tiefe+ refused (Tiefe+: drink 0<8, food 0<8, beds 0<2): confining to Kern+` (#12589, #12595), i.e. it put the citizens back into the burrow with the enemy.

## Expected
In `BREACH` the audit may not require beds/food/drink: the refuge's job is to survive days, not to live. `Tiefe+` should be created by the kernel (deepest dead end behind a stair) before a siege, not only wanted.

## Fix proposal
Two audit levels: `SIEGE` (supplies, as now) and `BREACH` (separated + reachable only); create `Tiefe+` from `inspect what=reach` data at boot and keep it in the alert list as a fallback.

Related: BUG-018, FR-67, `docs/v2/POSTMORTEM-run9-test-siege-2026-10-15.md`

## Fix (Claude, 2026-10-16)
- **Two levels** (`seal.rate`): SIEGE (separated, reachable, tiles >= max(20, citizens), drink and food >= citizens, beds as a rank) and
  BREACH (separated, reachable from the citizens, >= `breach_tiles` 9 tiles, no drink/food/bed/size-per-citizen counts). In BREACH (and
  while the refuge is held after one) the refuge is taken at the BREACH level first; outside BREACH it is the fallback when an entrance
  reaches the other candidates. The BREACH level and the dead end hold for `breach_days` (7; `config/reflex.json` `refuge.breach_days`)
  from the first such pick of an episode (dehydration), then the counts apply again. Reachable = a citizen inside or a sample tile of
  the burrow on a citizen's walk group, both read in one go.
- **`Tiefe+` is created** (FR-67): the scan (boot, every 14 days, after projects; at once in BREACH or when an entrance reaches the
  burrows) finds the dead end behind the deepest stair (from the deepest inside tile of the citizens' group upward, level by level, while
  a level has no citizen, no bed, at most 400 tiles and links only below and to one place above; Run 9: the shaft 30,66 z80-107) and
  paints it as the refuge burrow when that is missing (burrows screen: add burrow, paint tiles). kern.log `seal: Tiefe+ painted with N
  tiles: the dead end behind the stair at x,y,z (zA-B)`; `inspect refuge` `dead`, `hint` (what the refuge lacks for a siege: plan a
  stockpile and bedrooms there).
- Live case from the coordinator (Run 10 y419, 109 citizens): `REFUGE_FAIL Tiefe+: 63 tiles<109, beds 8<28 -> confining to Kern+` with an
  unseparated Kern+ now gives Tiefe+ (BREACH or DEAD level), never Kern+.
- Tests: `tests/lua/test_seal.lua` (BUG-019 levels and `breach_days`, config knob), `tests/lua/test_seal_refuge.lua` (the painted dead end in
  BREACH with a goblin in Kern+; the live case with 30 citizens and a 19-tile refuge), failing on 6e34f8a.
