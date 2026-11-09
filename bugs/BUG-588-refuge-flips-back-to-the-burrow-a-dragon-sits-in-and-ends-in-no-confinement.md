# BUG-588 The alert walks the citizens back into the burrow a dragon sits in; the run ends in "no confinement"
Status: fixed (offline, live-untested)
Severity: high (REFUGE_SWITCH / REFUGE_FAIL ten times in a row, each walk met the dragon; the last pick was "no confinement, citizens flee on their own")
Found: 2026-11-09, Run 16c i3 Sealcertain y422 summer (events #10623-#10909 read only): `Tiefe+ breached (hostile inside at 62,127,136)` -> Innen+, 80-1000 ticks later `Innen+ -> Tiefe+ ... deeper`, again and again; at #10887 `Innen+ breached ... no confinement`
Module: `lua/dfllm/seal.lua` (`hostile_in`, new `rlatched`, `rate`, `choose`, new `hostile_gap`, `area_ok`)

## Actual
A cave dragon stood on the refuge's stair foot on and off. Whenever the census did not show it (it was out of view for a few ticks) the refuge passed `rate` again, `choose` picked it in a BREACH ('deeper', the BREACH move to the refuge needs no reason) and `fight_rule` walked the citizens back down the stair; the next census showed the dragon again (`breached`).

## Root cause
`seal.lua` `rate` / `hostile_in`: a hostile counts only while it is IN the census list (`h.vis`, `h.list`, `h.rin`), so out of sight meant gone. And `choose` had no step that kept a separated, reachable, hostile-free burrow for a fight when the refuge and the usual levels failed: it ended with `r.flee`.

## Fix
- `seal.rlatched` (`RLATCH` 1200 ticks): a hostile seen in the refuge keeps the refuge refused in SIEGE / BREACH for 1200 ticks after the last sighting (`hostile inside at x,y,z, last seen N ticks ago`, danger); `hostile_in` records the sighting. PEACE / ALERT are no matter.
- `choose` last resort (`area`): in a BREACH or with danger known, before "no confinement" the best of Kern+ / Innen+ / the refuge that is separated, reachable, big enough, without a hostile (the refuge: not latched, no open way in, the breach days not spent unless wet) and not marked dry (BUG-031) is the pick, the one farthest from the visible hostiles (`hostile_gap`), level `AREA` (REFUGE_FAIL says `farthest separated burrow without a hostile`). A quiet SIEGE with no drink anywhere is still no confinement (the citizens fetch it, BUG-031).

## Tests
`tests/lua/test_bug588_589_refuge_destroyers.lua` (1) eight sightings and gaps with no `deeper` switch, the refuge again after RLATCH, PEACE ignores the latch; (4) BREACH with the refuge latched and a dry Kern+: Kern+ holds them (old: nil, flee), a quiet SIEGE with no drink: no AREA pick. `tests/lua/test_seal_refuge.lua` BUG-049 adapted (the refuge stays refused for RLATCH ticks after the goblin left it).

## Live check
No `REFUGE_SWITCH ... deeper` within 1200 ticks of a `breached`; REFUGE_FAIL tail `farthest separated burrow without a hostile` instead of `no confinement` while Kern+ or Innen+ stands.
Open: the latch is runtime state (lost on a reload); when every separated burrow holds a hostile the pick is still no confinement.
