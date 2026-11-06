# BUG-532 Wild plant-eating megafauna (Stegosaurus, Diplodocus) 47-76 tiles from every citizen raise a PREDATOR lockdown, the clock drops to 30 t/s
Status: fixed (offline, live-untested)
Severity: medium (a year takes eight times longer in real time; nothing is lost)
Found: 2026-11-06, Run 16a i1 Basementflew y408-y410 (`runs/run-16a/FR-BUGS.md` "Wilde Pflanzenfresser-Dinos loesen PREDATOR-Lockdown aus"; events.jsonl #6040-#6266 PREDATOR for JURASSIC_DIPLODOCUS 28298/28300/28301 and JURASSIC_STEGOSAURUS 28399/28400; read only)
Module: `lua/dfllm/sense.lua` (`herbivore`, `consider`), tests `tests/lua/test_bug439_big_wild.lua`

## Actual
Every wild Diplodocus or Stegosaurus that wandered on a roofed tile got a PREDATOR (`1 wild dangers inside the fort ... [JURASSIC_STEGOSAURUS, 376461 cm3, reachable]`), each one a Kern+ lockdown with a recall and the clock at 30 t/s instead of 250. 356 PREDATOR events in that fort's log; the first sightings were PREDATOR_FAR at 47-63 tiles, the PREDATOR came as the animal walked under 40 tiles.

## Root cause
The raws of both animals (`data/vanilla/vanilla_creatures_extinct/objects/creature_jurassic.txt`) carry [BENIGN] and neither LARGE_PREDATOR nor CARNIVORE. They became a danger through BUG-439: `sense.big_wild` counts any wild unit of 300,000 cm3 or more on a tile that is not open to the sky, and `consider` listed it as k `danger` with `pr 1`; reflex's `inside_scan` turns a danger within `predator_near` (40) of a citizen into PREDATOR plus lockdown. A Diplodocus (721,000 - 1,180,000 cm3) and a Stegosaurus (315,000 - 376,000 cm3) are always "big".

## Fix
`sense.herbivore(u)`: a big wild unit that is no LARGE_PREDATOR, no CARNIVORE (new raw read `cv`, cached with the other caste flags) and no marked killer. In `consider`, before the unit counts as a hostile: such a herbivore farther than `M.HERB_NEAR` (20) tiles from every citizen (outside Kern+ by `out_pos`, anywhere on its levels by `civ_pos`) and not inside Kern+ / past B1 is wildlife: not counted (`vis`, mode, PREDATOR, PREDATOR_FAR, lockdown). `census.h.herb` / `herb_d` say how many stood by and how near the nearest was. Within 20 tiles, inside Kern+, once it killed someone (BUG-421) or when it is a carnivore, BUG-439 applies as before: the mammoth that walked into the fort is still a PREDATOR. Real predators (LARGE_PREDATOR, CARNIVORE) are untouched.

## Tests
`tests/lua/test_bug439_big_wild.lua` (the BUG-439 cases now stand next to the citizen; +2: a far herbivore is no hostile and is counted in `herb` / `herb_d`, within 20 it is the BUG-439 danger; a far carnivore of the same body still counts).

## Live check
Next Diplodocus / Stegosaurus in a fort: no PREDATOR / PREDATOR_FAR beyond 20 tiles, `census.h.herb` > 0, the clock stays at its PEACE speed. `HERB_NEAR` 20 is a constant; raise it if one wanders in and a hall is trampled before the alarm.
Open: a herbivore that gets within 20 tiles still locks the fort down (BUG-439's reason: a mammoth killed two). A unit DFHack lists as `isDanger` is not touched here.
