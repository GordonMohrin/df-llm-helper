# BUG-554 A wild plant eater (stegosaurus, diplodocus) walking beside an outdoor citizen is a PREDATOR lockdown, the clock drops to 30 t/s
Status: fixed (offline, live-untested)
Severity: medium (a year takes eight to sixteen times longer in real time; nothing is lost)
Found: 2026-11-06, Run 16a i1 Basementflew y416-y422 (`runs/run-16a/FR-BUGS.md` "OBS Runde 33: Stegosaurus (29268, wild, 342595 cm3) loest y416 sum d74-80 weiter PREDATOR-Lockdown + Uhr 30 t/s aus" and "lockdown unacked:PREDATOR haelt die Uhr ~16x langsamer"; events.jsonl #7460, #7468, #7486, #7509, #7522, #7576, #7582 PREDATOR for JURASSIC_STEGOSAURUS 29266-29338 and about 25 more for Diplodocus / Megaceros after BUG-532 was live; read only)
Module: `lua/dfllm/sense.lua` (`consider`, herb exemption), `lua/dfllm/reflex.lua` (`inside_scan`), `dfpilot/schema.py`

## Actual
BUG-532 (round 33) made a big wild plant eater wildlife beyond `HERB_NEAR` (20) tiles of every citizen. The log still holds 14 PREDATOR interrupts for the stegosaurus 29266-29338 in y416-y421 and more for diplodocus 29609-29612 and megaceros 29647-29650 (sz 311,000-1,038,000 cm3; raws: BENIGN, no LARGE_PREDATOR, no CARNIVORE, so `herbivore()` is true for all of them). Each one was a Kern+ lockdown; unacked for 60 s it applies the PREDATOR default (`clock`, `alert`) and the clock runs at 30 t/s instead of 250-480.

## Root cause (what the evidence allows)
The PREDATOR event carried no distances, so the zone cannot be read back from the log. The rules that let a plant eater through BUG-532 in `sense.consider`:
1. `sense.lua:670` (before) measured the distance to citizens outside Kern+ (`hs.out_pos`) with a Chebyshev distance that includes the z difference but **no level cap** (`civ_pos` had `DA_DZ` = 3). A miner in a shaft 14 levels under the surface counted as 14 tiles from a stegosaurus on the surface (the fort's shafts at 46,16 and 50,20 lie where the animals were met, y 6-30).
2. Within 20 tiles of any citizen the animal is the BUG-439 danger by design; the fort lies at z129 and the animals walk at z131, so one is near somebody on most days. `reflex.inside_scan` then made every such unit a PREDATOR with the lockdown defaults, although a BENIGN plant eater beside an outdoor worker is no army.
BUG-532 did apply beyond 20 tiles (the PREDATOR_FAR lines with dc 41-91 are the units it did not touch); it never covered the near case, which is the one the log shows.

## Fix
- `sense.lua`: `hbeast` (a big wild plant eater, no killer mark) is computed once; both distance lists are capped to `DA_DZ` levels (the exemption beyond `HERB_NEAR` ignores citizens on other levels); the entry carries `hb = 1`.
- `reflex.lua` `inside_scan`: an `hb` entry outside Kern+ and the intake zones (`zn` 0, no `ik`) is PREDATOR_FAR (class B: no interrupt, no lockdown, no clock hold, `plant eater` in the text, `hb` in the data) however near a citizen it is. Inside Kern+, in the intake / past-B1 zones, or once it killed someone (BUG-421 clears `hb`: `herbivore()` is false for a marked killer) it is the BUG-439 PREDATOR as before. The mode still goes to ALERT while it is in sight (fps cap 100), nothing else.
- The PREDATOR event now names `dc` (nearest citizen outside Kern+), `da` (nearest civilian on its levels), `zn` (2 = inside Kern+ / past B1) and `hb`, so the next log shows which rule fired (schema: optional fields; PREDATOR_FAR gets `hb`).

## Tests
`tests/lua/test_reflex.lua` (plant eater 12 tiles from a woodcutter: PREDATOR_FAR with hb, 0 PREDATOR, 0 LOCKDOWN, nothing unacked; after `sense.mark_killer` it is a PREDATOR without hb), `tests/lua/test_bug439_big_wild.lua` (hb on a near plant eater; a citizen 14 levels down is no neighbour; a carnivore has no hb).

## Live check
Next Stegosaurus / Diplodocus near the fort: PREDATOR_FAR with `hb 1` and no LOCKDOWN, the clock keeps its ALERT speed (100), `inspect what=unit key=<id>` still describes it. A plant eater that walks into Kern+ is a PREDATOR with `zn 2`.
Open: the animal still raises ALERT (fps cap 100) while it is in sight; a BENIGN animal that attacks outdoor workers is only caught by BUG-421 after the first death. The exact rule that fired could not be proven from the old events (no `dc`/`zn` in PREDATOR); the new facts will show it.
