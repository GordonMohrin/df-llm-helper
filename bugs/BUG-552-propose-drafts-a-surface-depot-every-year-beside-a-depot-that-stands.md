# BUG-552 `plan propose` adds a surface depot every year although a depot stands and traded
Status: fixed (offline, live-untested)
Severity: medium (a wrong draft the player strikes every year; a second depot would split the caravan trade)
Found: 2026-11-06, Run 16b i2 Brotherarrow y399 ("Es wollte ausserdem eine Oberflaechen-Depot (77,92,139), obwohl 84,88,137 steht: gestrichen"; `E:/DF-test2/dfllm-runtime/r16b4-brotherarrow-site97/` events.jsonl and manifest.json read only)
Module: `dfpilot/plan.py` (`depot_lost`)

## Actual
The kernel manifest names the depot `[84, 88, 137]`, four caravans traded after tick 162689369 (events 7597, 7843, 7907). `fort_facts.depot` was False, so the draft added `depot@S1` (BUG-368) with the note "the last depot was toppled".

## Root cause
`depot_lost` (BUG-536) read the newest BUILDING_TOPPLED of a "depot" as the newest word on THE depot: event 7517 (a cave dragon, `pos [94,74,139]`) was an older depot of the fort (y372s0b1's); the one in the manifest (84,88,137) had been rebuilt, and no PROJECT_DONE of a depot / core project followed because the rebuild was not a project of ours. Offline on the i2 files: `depot_lost` True, `depot_planned` False.

## Fix
`depot_lost` reads the events newest first: a CARAVAN `traded` is proof that a depot stands (False); a topple of a depot at a tile other than the manifest's depot position is another building (skipped); a DEPOT_MISSING, or a topple at the manifest's own position (or with no manifest depot), is lost as before (BUG-536 unchanged). On the i2 files: `depot_lost` False, `depot_planned` True.

## Tests
`tests/test_bug549_553_f35.py`: topple at the manifest tile = lost; a trade after it = not lost; another depot toppling = not lost; no manifest depot = lost; DEPOT_MISSING = lost; a standing depot is not drafted (`depot_planned`).

## Live check
`plan propose` on a fort with a standing, trading depot after a topple of another one: no `depot@S1` and no BUG-368 note.
Open: there is no stored "no surface" wish: a fort that really has no depot still gets the surface depot (caravans need one on open ground); a player's strike of a depot build in last year's plan is not remembered when the depot is truly missing.
