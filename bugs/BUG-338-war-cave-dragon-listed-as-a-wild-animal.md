# BUG-338 the army's war cave dragon is listed as a wild animal: no lockdown of its own, O1 toppled, 5 killed at B1
Status: fixed (offline, live-untested)
Severity: critical
Found: 2026-11-04, Run 15c (Inkintense y379 sum d64-67, i1 r15c-inkintense-site97)
Module: `lua/dfllm/sense.lua` (hostile scan, Run 11 animal-invader rule), `lua/dfllm/reflex.lua` (inside_scan)

## Actual
events.jsonl #2899 siege popup "... With them comes a war cave dragon from the dark goblin fortress of Lakeshates!"
(gamelog), #2907 `PREDATOR_FAR 26704 at 17,74,133, nearest citizen 59 tiles: no lockdown` (map edge, surface), #2950
`BRIDGE_DESTROYED O1 (86,91,131, last up, SIEGE, races CAVE_DRAGON)`, #2955 `limestone Bridge toppled by Utes Olngöuznuk,
war Cave Dragon`, #2952/#2953 SIEGE>BREACH, #2957 PREDATOR inside at 86,92,131, then #2983 `PREDATOR_FAR 26704 at 85,80,131,
nearest citizen 63 tiles: no lockdown` while it killed citizens at 84-87,69-72,131 (DEATH #3031-#3039 `killed by cave
dragon 26704`). Pop 56 -> 43.

Not a cavern breach: no cavern was opened (no cavern event in events.jsonl), the dragon came over the surface with
invasion 4. The FR-98 cavern sweep is not involved.

Root cause:
- `lua/dfllm/sense.lua:444` (Run 11, ELK_BIRD): an invader whose raws cannot learn or speak is an `an` animal: `inv = false`,
  k `danger`. The war cave dragon (no CAN_LEARN/CAN_SPEAK, BUILDINGDESTROYER) thus left the invader count and fell under the
  predator rule.
- `lua/dfllm/reflex.lua:1773` (Run 10 predator_near): a wild danger outside zone 2 farther than predator_near from a citizen
  outside Kern+ (or with none outside: dc -1, the normal case in a lockdown) is PREDATOR_FAR (B, no lockdown) - also between
  O1 and B1 after O1 fell.

## Fix
- sense: an animal invader that is a building destroyer (`rf.bd`) stays an invader (k `inv`, counted in `inv`, bd = 1).
- reflex: a wild danger with `bd = 1` on a roofed tile of the citizens' walk group is never "far": PREDATOR (A: clock, alert)
  at once, whatever dc says.
BREACH itself did come at once when O1 fell (siege `destroyed`); the gap was before and after it.

## Tests
`tests/lua/test_reflex.lua` (2 new: the war cave dragon is k inv, bd 1, no PREDATOR_FAR; a wild building destroyer at the
spot where the Run 10 animal is PREDATOR_FAR is PREDATOR). Both fail on b35af6d.

## Live check
Next siege with war beasts: census.h lists a war troll/dragon as `k inv`, no PREDATOR_FAR for it; a cavern dragon or other
building destroyer on the fort's walk group under a roof gives PREDATOR (alarm.txt) even with every citizen in Kern+.
Uncertain: whether DF's raws give war cave dragons BUILDINGDESTROYER as caste flag or misc level (both read, BUG-030);
a raised drawbridge still falls to it (DF), so this only buys the alarm and the deep defense, not the bridge.
