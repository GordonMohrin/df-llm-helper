# BUG-533 No migrant wave for years: max-pop sat on the citizens ('max-pop 33 (plan)', open_perimeter, defense_short) and nothing said why
Status: fixed (offline, live-untested) for the holds dfpilot owns; the i2 case (cap 100, 44 citizens) is not a cap problem and the status now says so
Severity: medium (the fort never grows)
Found: 2026-11-06, Run 16b i2 Brotherarrow, 16c i3 Sealcertain, 16d i4 Trumpetrealms, 16a i1 (events.jsonl POPCAP / MIGRANTS, read only)
Module: `lua/dfllm/readiness.lua` (`M.GROW`, `growth_room`, `hold_text`, the dhold / phold blocks), `dfpilot/plan.py` (`defense_cap`, `growth_room`, `gap_soft`), `dfpilot/brief.py` (`migrant_cap_note`)

## Actual
i3 / i4: MIGRANTS once (y372, 4 migrants), then none; the POPCAP log reads `32 (open_perimeter)`, `33 (plan)`, `35 (plan)`, `37 (plan)` ... `40 (plan)` on 32-40 citizens. i2: `100 (R1)` from y375 and 44 citizens, still no wave in three years. i1: `31 (open_perimeter)`, `29 (plan)` at times far under the citizens.

## Root cause
pop-control's game cap is `min(max-pop, citizens + wave-size)` (`hack/scripts/pop-control.lua` `adjust_caps`, monthly). A max-pop at or under the citizens is a cap of exactly the citizens: no wave can enter. dfpilot set it there in three places:
- `plan.defense_cap` (plan.py): `plan propose` drafts `pop_ceiling` = the citizens (at least DEFENSE_POP) while ANY defence gap stands (BUG-377). The readiness cap is `min(level cap, plan pop_ceiling, ...)` (readiness.lua `M.ceiling`, why `plan`); each year's propose re-anchors it at the then population (33, 35, 37, 39, 40: births, never a wave).
- readiness' `defense_short` (st.dhold = the citizens when a trap shortfall is older than DEF.grace_days) and the FR-70 `open_perimeter` freeze (st.phold) hold max-pop at the citizens (`rt.dhold_pop`, `rt.phold` in `M.ceiling`).
- The status showed `cap 33 gate 33` with no reason (`pop.hold` knew only the player ceiling and the famine hold) and the pop trend said no migrants, so nobody could tell a held cap from the game's own wealth rules (i2).

## Fix
- Soft gaps leave room for a wave: `readiness.M.GROW` (room_min 4, room_pct 10, trap_pct 50) and `plan.growth_room` / `gap_soft` (same numbers). A `traps short H<T` with H >= 50 % of T, or soldiers' armor worn >= 40 %, is soft; `plan.defense_cap` is then the citizens + `growth_room` (a hole - refuge_dry, traps 0, armor 0, thinner traps, bare armor - keeps the cap ON the citizens, BUG-377 as before). readiness' `defense_short` hold likewise (`rt.dsoft`), and the `open_perimeter` freeze when the entrance check counts no way in without door or bridge (`rt.open == 0`: only a lost lever or bridge keeps it open; `rt.psoft`). The room closes itself: the trap target grows with the citizens (0.35 x citizens), a wave that uses the room up raises it. Famine, player ceilings and the freezes outside PEACE are untouched.
- The reason in status: `pop.hold` also names the other holds: `plan 33`, `open_perimeter 32+`, `defense_short 110+` (`+` = leaves room) next to `cap` / `gate`; `brief.migrant_cap_note` (pop trend line): `migrants blocked by max-pop 33 on 33 citizens (plan 33)`, `max-pop 37 leaves room for 4 (...)`, or `max-pop 100 is not what keeps migrants out (44 citizens)` (the i2 answer: the cap was not the cause; the game's wealth / death rules in MIGRANT_RULES are).
- `plan propose` notes say `the citizens now + N room for a migrant wave: every gap is soft` instead of `no growth` when it leaves room.

## Not done
i2's three years without a wave under max-pop 100 follow the game's own migration rules (wealth of the last departing caravan, deaths, waves 1-2 fixed); dfpilot cannot steer them (DECISIONS 16) and now says so. The open_perimeter freeze with real ways in stays a hard hold (a push to seal).

## Tests
`tests/lua/test_bug478_481_defense_ready.lua` (+1: 16 of 29 traps -> max-pop 110, `defense_short 110+`; 8 of 29 -> 100, `defense_short 100`), `tests/test_bug532_534_f33.py` (growth_room, gap_soft, defense_cap soft / hole / mixed, migrant_cap_note).

## Live check
A fort with a soft trap shortfall: POPCAP `max-pop N+room (defense_short)`, status `ceiling defense_short N+`, a wave arrives (MIGRANTS), the room closes. The POPCAP log of an open_perimeter fort with `open 0`.
