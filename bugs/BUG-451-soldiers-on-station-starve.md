# BUG-451 Soldiers on station starve in a lockdown without STRANDED
Status: fixed (offline, live-untested)
Severity: high (three soldiers at hunger 70,000+ of 75,000)
Found: 2026-11-05, Run 16a i1 Syrupobeyed y386 spring d27-d31 (`runs/run-16a/FR-BUGS.md` "Soldaten verhungern auf Station im Lockdown")
Module: `lua/dfllm/military.lua` (`feed_pass`, `apply_squad`), `lua/dfllm/economy.lua` (`solo_check`)

## Actual
DECISION_NEEDED thirst_unit #18344/#18358: three soldiers (wrestler, militia captain, one more) at hunger 70,657-73,815, "job none", at 49-52,107-109 z135 (Kern+), food 3842 and drink 1775 in Kern+, inside the siege burrow. No STRANDED, `status` "starving 0".

## Root cause
A squad on a `station` order stays on it; its soldiers took no food job (job none) although the group had stock. `siege.lua` STRANDED needs a walk group without stock and leaves soldiers on their stations on purpose; `economy.solo_check` only listed them. Nothing released the squad.

## Fix
`military.feed_pass` (every 600 ticks, squads on a station order only): a member over `FEED_HUNGER` 50,000 or `FEED_THIRST` 40,000 with no job releases the squad (`squad_order clear`) for `FEED_HOLD` 1200 ticks or until nobody is over the marks, then the station is ordered again (`apply_squad` force).
Not for a squad on a kill order or a sortie, never in a BREACH, not twice within `FEED_COOL` 2400 ticks. kern.log names the soldiers ("released from its station to eat and drink", "back to its station after ..."); `solo_check` adds "squad member" to its reason.

## Tests
`tests/lua/test_stations.lua` (release, return, cool-down; a hungry soldier with a job and a BREACH release nobody).

## Live check
A soldier over hunger 50,000 with "job none": kern.log "military: squad A released from its station to eat and drink: <id> (hunger ..)" and the squad's order list empty for up to a game day, then `station@` again.

## Review fix

While a squad is released to eat (`rt.feed[k].on`, order `feed`), a sortie or kill order that takes the squad over now ends the release without re-stationing it (the running order stands). A BREACH ends the release at once. Test: `tests/lua/test_stations.lua` (BREACH ends the release).
