# BUG-391 a stranded group dies of thirst ('no raised bridge leads to drink') and the status says 'nobody thirsty: they drink water'
Status: fixed (offline, live-untested): STRANDED without a way to drink raises DECISION_NEEDED stranded_drink with commands; no all-clear then. Open: the kernel builds no well on its own
Severity: high
Found: 2026-11-04, Run 16a (i1 Bachwald R2, `runs/run-16a/FR-BUGS.md` #2238/#2613-#2653: 8 dead of thirst, pop 22 -> 14)
Module: `lua/dfllm/siege.lua` (rescue_step, dry_decision, dry_group), `lua/dfllm/economy.lua` (alarm_check, drink_why), `dfpilot/wake.py`, `dfpilot/bp/sites.py` (reachable)

## Actual
STRANDED #1505/#1514/#2238/#2624/#2648 named 4 citizens on walk group 2829 over thirst 34,937 and said "no rescue (no raised bridge leads to
drink)". Nothing else happened: `dfllm status` said "drink 0 d; nobody thirsty: they drink water" (read as an all-clear), the thirst alarm stayed
off, no DECISION. The water zone the kernel had accepted lay on another group. 7 citizens died "dehydrated (thirst 75000)".

## Root cause
- siege.lua `rescue_step` (refusal branch, :655): a refusal because no bridge leads to the needed stock only emitted STRANDED (class A, but it names
  no action). A cut-off group that no bridge can reach is not something the kernel can fix; nobody was asked.
- economy.lua `alarm_check` (BUG-259 rule, :3190): "low drink days alone are no alarm while the thirst timers show the citizens drink water" counted
  citizens above `alarm.thirst` only; the stranded sat at 25,000-35,000 and the rest drank at the brook, so `st.water` (the all-clear) was set and
  `drink_why` printed it.
- `bp sites cistern --near` could not place a well on their side: `sites.reachable` dropped every site outside the majority's group.

## Fix
- siege.lua:516 `dry_decision`: when the refused rescue needs drink and `way()` found no bridge: DECISION_NEEDED `stranded_drink` (class A): who (n),
  where (walk group, tile), thirst, and `cmds`: `inspect what=reach`, `inspect what=water_sources`, `bp sites cistern --near <x,y,z> --within 20 --fresh`.
  Cadence util/cadence (news only: more citizens; at least 2 game days / 120 s). `wake.URGENT_DECISIONS` has it (not held by the hourly limit).
- siege.lua:534 `M.dry_group(K)`: {n, thirst, grp, pos} of the last cut-off set over the thirst mark without drink on its group (2 game days).
- economy.lua: `alarm_check` counts them as thirsty (alarm + `DECISION_NEEDED thirst`), no `st.water`; `drink_why` leads with
  "4 stranded without drink (group 2829)".
- sites.py `reachable(.., focus)`: a ranking asked near/at a tile on another walk group is not filtered (the caller chose that group).

## Tests
tests/lua/test_stranded.lua (+1: citizens on the field, DECISION once with the commands, dry_group, gone with the thirst), tests/lua/test_economy_food_run15.lua
(+1: no all-clear, alarm, status), tests/test_bug390_392_reach.py (near a '0' tile, wake urgency).

## Open
No automatic well: placing a building for a group the kernel cannot reach needs a builder there (the decision names the commands). What separates the
walk groups is still not named in STRANDED.
