# BUG-862 Squad A empty while the soldiers sit in B and C: squad.add and squad.leader refused each other and the kernel never filled A
Status: fixed (offline, live-untested)
Severity: high
Found: Run 17 i1 (`runs/run-17a`): squad A empty, soldiers in B and C; `squad.add` said 'squad N has no leader: squad.leader first', `squad.leader` said 'unit is in a squad' (the act refuses a unit that sits in a squad).
Module: `lua/dfllm/military.lua` (`M.borrow`, `seat_leader`, `M.first_fill`, `M.seat_leader_verb`, verbs `squad.add` / `squad.leader`)

## Root cause
A leaderless squad needs a leader before `addToSquad` works; the leader seat refuses a unit that is in a squad. The kernel's `seat_leader` took a member of the squad itself or a recruit (a citizen in no squad); with no recruit left it stayed `stuck`. `first_melee_key()` then named B the 'first squad' (the first with members), so the ladder read B while A was empty.

## Fix
- `seat_leader` of the first melee squad (A) with no member and no recruit takes the best healthy non-leader of another squad (`M.borrow`: melee squads first, never a position-0 leader, never a unit passed over lately).
- `M.first_fill` (after `fill`, not in a siege): while the first melee squad has fewer than `min(growth.armed_min, its target)` members it takes members of the other squads the same way, `ADD_PER_STEP` a step, a refusal backs off; so A has `armed_min` members before B and C hold more than their leaders.
- Verbs: `squad.add` into a squad WITHOUT a leader seats the unit as its leader (answer `joined squad N as its leader`); `squad.leader` and `squad.add` of a unit that sits in another squad take him out of it first (`seat_leader_verb`); a leader of another squad is refused with 'leads squad N: give that squad another leader first'.

## Tests
`tests/lua/test_bug860_squad_ready.lua` (BUG-862 i1: the kernel fills A from C with no recruit left, C keeps its leader, nobody is lost; the verbs seat a leader without the deadlock; both fail without the fix), `tests/lua/test_a4_offices.lua` (squad.add into a leaderless squad).

## Live-Erwartung
On i1 (after reload): kern.log `military: squad A: leader taken from squad B (no member, no recruit)` and `military: squad A: unit N moved in from squad B (k of 3: the first squad is filled first)` within the next upkeeps; `state mil.kit.sq` = members of A. NOT promised: that A is armed (BUG-860 / 861), nor that B and C keep their strength (they give up non-leader members until A has `armed_min`).
