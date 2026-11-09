# BUG-616 Drink 0 days for years with water only outside the walls; STRANDED 'no rescue (no raised bridge leads to drink)' repeats without a fix
Status: fixed (offline, live-untested)
Severity: medium (a fort without brewing lives on one outside water zone; 150+ STRANDED lines in Wallfree)
Found: 2026-11-09, Run 16c i3 Wallfree y373-y380 (drink 0 d, no farm, citizens drink at the water zone 17718 at 91,59,142; STRANDED `no rescue (no raised bridge leads to drink)` for single citizens 150+ times, `stranded_drink` with `inspect` and `bp sites cistern --near` only)
Module: `lua/dfllm/water.lua` (`M.drink_fix`, `M.stranded_fix`), `lua/dfllm/siege.lua` (`rescue_step`, `dry_decision`), `dfpilot/schema.py` (STRANDED `fix`)

## Actual
`drink_fix` answered `accepted water: zone 17718 at 91,59,142` (no source inside, no word that every drink is a walk outside) with only `inspect what=water_sources`; economy appended the farm command. The STRANDED text named the cause (`no raised bridge leads to drink`) and nothing to do about it; the decision `stranded_drink` listed read commands and a cistern search without saying where the water is or how far.

## Root cause
- `water.lua drink_fix` (first return): the accepted-source branch ignored `s.inn` (the burrow each source stands on, set in `finish`), so a fort whose only water lies outside Kern+ / Tiefe+ looked served.
- `siege.lua rescue_step` (refused branch) / `dry_decision`: no look at the water module's sources for a drink case.

## Fix
- `drink_fix`: with a Kern+ burrow and no accepted source inside it or the refuge: `accepted water: <label> lies OUTSIDE the core (the citizens walk out for every drink): bring water inside, a cistern piped from it (dfllm bp sites cistern --near x,y,z --fresh)` (+ the aquifer well when a level is known), the same command in the list.
- `M.stranded_fix(K, pos)` (public, report only, no tile reads): the nearest accepted source and its distance (`open a walk path (ramp or stair) to it, or a cistern beside them`), else the nearest scan body with a bank (`open a walk path to the bank and zone it as Water Source`), else the cistern. STRANDED `refused` for a drink case carries it as `; fix: ...` and `d.fix`; `stranded_drink` puts `way to drink: <fix>` first and `d.fix`. STRANDED schema `fix:s`.

## Tests
`tests/lua/test_bug615_617_water_deaths.lua` (outside / inside text and command, `stranded_fix` text and bound), `tests/lua/test_stranded.lua` (STRANDED msg + `d.fix`, `stranded_drink` q and `fix`)

## Live check
Wallfree-like fort: the next `thirst` decision shows `lies OUTSIDE the core` and `bp sites cistern --near <zone> --fresh`; a STRANDED refused line ends in `; fix: zone N at x,y,z is D tiles off ...`. Not done: the kernel builds no cistern or well inside by itself (a piped cistern needs a site ranking and the player's plan); the walk path (ramp / stair) is named, no template digs it.
