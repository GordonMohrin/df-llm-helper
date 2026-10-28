# BUG-111 The census counts as an invader every unit DFHack calls one: a merchant, diplomat, visitor, restrained unit or child holds the fort in BREACH and soldiers sent against it stand beside it
Status: fixed in the M3 commit (offline, live-untested): sense leaves an invader that DF's own flags mark as merchant, diplomat,
invited visitor, restrained or child out of the hostiles and names it (`census.h.benign`, state `alarm.ben`, one kern.log line);
an unconscious invader stays counted and is marked `uc` (it wakes up). What the live unit 39230 really was is not decided offline.
Severity: high (wrong decision: BREACH and the civ alert for 26 days, a patient suffocated, Gordon's kill orders had no effect)
Found: 2026-10-28, Run 14 (Trussroads) y707 Sommer d44-70, game session notes 94 and 96 (the addendum), kernel of 32994bb
Module: `lua/dfllm/sense.lua` (`consider`, new `benign_why`), `lua/dfllm/reflex.lua` (`harmless`), `lua/dfllm/util/k_mock.lua`

## Actual
- Note 94: a goblin (inv 39230, body size 6486, "harmless") walked into Kern+ and held the fort in BREACH / DEFCON 1 for 17+ days.
- Note 96 addendum: Gordon gave kill orders on it by hand; all the soldiers stood beside it and did nothing for days. Suspected by
  the game session: the unit is a visitor, diplomat, merchant, restrained, unconscious or a child, so DF does not treat it as an
  enemy the soldiers may attack, "but the kernel counted it as an invader".

## Cause (proved from the code at 32994bb)
`sense.lua` `consider` (:354-: the per-unit path of the hostile scan) takes every unit with `isDanger`/`isUndead` into the
hostile branch and decides only by `U.isInvader(u)` (:375): the own-unit checks that follow (`isCitizen`, `isTame`, own ghosts,
:376-395) never ask for the flags a player sees on the unit sheet. A unit that DFHack's `isInvader` answers for but that is also a
merchant, diplomat, visitor, restrained (bound) or a child therefore reaches `hs.inv`/`hs.vis` (:424-428) and the census list (:474-); from
there `threat.assess` counts it for the SIEGE rule and for `a.inside` (threat.lua:147, :193-196; `a.inv` :187), siege makes ALERT/BREACH of it
and reflex a lockdown (`sighting`, `inside_scan`). Nothing in the tree reads `flags2.restrained`, `flags2.visitor`,
`flags1.merchant`/`diplomat` or `isChild` for a hostile (`grep` over lua/dfllm: only `friend()` in sense.lua:226-227 reads
merchant/visitor/diplomat, for the units near a bridge footprint).
What is NOT proved: which of the flags unit 39230 carried (the size 6486 is a child's body: an adult goblin is about 60,000 cm3,
a dwarf 60,000) and whether DFHack's `isInvader` answers true for it. The classification below works whatever the reason is, and
BUG-112/BUG-113 make the fort end the lockdown even when the unit is classified as a hostile after all.

## Fix
- `sense.benign_why(u, U)`: first matching reason of `merchant` (flags1.merchant / isMerchant), `diplomat`, `visitor` (the raw
  `flags2.visitor` with none of `visitor_uninvited`, `flags1.active_invader`, `flags1.marauder`: a thief, an ambusher or a
  marauder is never a visitor, whatever an API predicate says), `restrained` (`flags2.restrained` or `flags1.chained`), `child`
  (`isChild`/`isBaby`). Applied only to units that DF calls invaders and that are neither undead nor a great danger. Such a unit
  is not counted (`vis`, `inv`, list, zones), but a friend near a watched bridge footprint is still reported to gate; the census
  carries `h.nben` and `h.benign = {{id, why}}` (<= 10), the first sighting of a unit is one kern.log line
  (`sense: unit 39230 is an invader by DF's flag but no hostile to the player: child (not counted)`), the state has
  `alarm.ben = ["39230:child"]` (<= 5) and status/brief print `not counted as hostile (id:why): ...`.
- An unconscious invader (`counters.unconscious > 0`) stays a hostile (a siege's knocked-out enemy wakes up) and gets `uc = 1`;
  reflex's `harmless` treats it as harmless so the lone-intruder rules of BUG-112 apply to it; they time out the moment it wakes
  and the size rule decides again.
- Safety: a real invasion, a thief, a snatcher, an ambusher and every unit whose flags cannot be read keep counting (every flag
  read is a `pcall`; an unreadable flag is `false`). The test pins that an uninvited visitor, an active invader and a marauder
  that also carry `visitor` stay hostile.

## Not decided offline
- Whether unit 39230 was one of these (and which), and whether `isInvader` is true for such units on DF 53.16. Read-only live data:
  `dfllm status` after the next such unit shows `not counted as hostile (id:why)`; if it shows nothing while a unit stands
  beside the soldiers, dump `u.flags1`, `u.flags2`, `u.counters.unconscious`, `dfhack.units.isInvader/isVisitor/isMerchant/
  isDiplomat/isChild/isOpposedToLife` of that id. BUG-113's `not_attackable` abort clears such a unit by behaviour.

## Tests
`tests/lua/test_m3_classify.lua` (2) and `tests/lua/test_m3_lone.lua` (BUG-111: a goblin child inside Kern+ makes neither a
lockdown nor a BREACH); all fail on 32994bb (checked in a pristine worktree with the new tests and the mock only).
`tests/test_m3_files.py` (state/event contract).

Related: BUG-065, BUG-112, BUG-113; game-session notes 94 and 96
