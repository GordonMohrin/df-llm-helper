# BUG-341 a mood material out of reach ends in a berserk murder: the unreachable stock hides the need
Status: partly fixed (offline, live-untested): unreachable stock counts as missing; open: locking a moody dwarf who will fail,
opening the way (a raised bridge) for him
Severity: critical
Found: 2026-11-04, Run 15 (Guildcleans, i2, `runs/run-15-guildcleans/FR-BUGS.md` "Mood-Material 'logs none reachable' fuehrt
zu Berserk-Mord (y376 Sommer d68)"), kernel main b35af6d
Module: `lua/dfllm/care.lua` (mood_report wants, the decision hint), `lua/dfllm/economy.lua` (care_hooks)

## Actual
Guildcleans y376 (i2 events.jsonl): MOOD_START #1464 Possessed unit 26504 (tick 151697120); MOOD_RISK #1468 / MOOD_NEED #1469
`logs x1: none reachable [89/89/0]` (89 free logs, none on his walk group), `acq logs:chop`, `far 89`; MOOD_CRITICAL #1471
(39 d left), #1484 (32 d), #1525 (20 d, `waiting`); DECISION_NEEDED #1476 `89 outside Kern+: haul in or open the way; cut
trees`. kern.log over the same weeks: `order ... ConstructBed ...: no job for 11 days (Carpenters: 4 shops, 0 jobs ...; 89
logs)`, `Woodcutters blocked (jobs): 1 can take none of the first 6 open FellTree jobs (off their walk group or burrows)`; no
autochop line. The mood failed (MOOD_END ok=0 #1598), 26504 killed 26509 and 26377 (#1620, #1793) and was killed (#1596).

Root cause economy.lua:1492 (b35af6d): care.mood_wants hands economy `{cls = 'logs', n = 1}` and economy raises the wood
floor to 1, far below the 89 logs it counts; nothing is felled or made for the mood (care.lua:3375 drops nd.far from the
want, care's own `acquire` acts for corpse classes and boulders only). The hint (care.lua:3467) says `outside Kern+` although
the walk-group hook said another walk group.

## Fix
- care: each mood want carries `far` = the free items of the short need the dwarf cannot reach (care.mood_wants, CONTRACTS).
- economy care_hooks: the need is `n + far` (at most `M.MOOD_FAR_CAP` 100): the floor stands above the unreachable stock, so
  T.chop raises autochop's min over the log count (reachable trees are felled), and the other keys order, tan or hunt more
  the same way (89 far logs, 1 needed: `autochop target 200 110` instead of nothing).
- care's decision hint with the walk-group hook: `N out of his reach (another walk group): the kernel makes more; open the
  way` (`outside Kern+` stays for the Kern+ fallback without the hook).

## Open
- Locking the moody dwarf when the mood will fail (Possessed/Fey go berserk): no verb or act for it yet; seal/door_forbid
  could hold him in his workshop room. Needs Gordon's rule (FR).
- When the fort is cut off from every tree and log (bridges up, no tree on the walk group), more chopping does not help;
  the way must be opened (lever in PEACE) or the material bought (trade wants carry the mood's `buy` tokens, BUG-284).

## Tests (fail on b35af6d)
- tests/lua/test_economy_chains.lua `BUG-341: mood logs out of reach are no stock: the wood floor stands above them,
  autochop fells trees` (89 logs, far 89: `autochop target 200 110`; reachable: no change).
- tests/lua/test_care_moods.lua `BUG-341: free items out of reach of the moody dwarf are mood_wants.far; the decision says
  another walk group`.

## Live check
A mood whose logs (or leather, cloth) lie on another walk group: kern.log `need wood N (care: mood)` with N above the free
count, `autochop target ...` raised, FellTree jobs on the citizens' walk group; DECISION_NEEDED mood_material names
`out of his reach (another walk group)`.
