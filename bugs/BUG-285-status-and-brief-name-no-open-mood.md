# BUG-285 status and brief name no open strange mood, its needs or its time left
Status: fixed (offline, live-untested)
Severity: medium (the game session read `moods 1` in the care line and nothing else while the mood ran out)
Found: 2026-10-29, Run 15 (Drillchamber, Guildcleans STAND/FR-BUGS)
Module: `lua/dfllm/care.lua` (M.state, M.mood_view), `dfpilot/brief.py`, `dfpilot/guide.py`

## Actual
State held only `care.moods` (a count); status and brief had no line for a running mood; `dfllm next` said `thirst ?` for a
MOOD_CRITICAL without thirst.

## Fix
State `mood` (care, from the mood check, not the full run): `[{u, t, left, why, buy}]`, fewest days left first, at most 4, with
`t` = `MOOD <name> <kind> needs <items>: <have/missing>, <days left>` (`dfllm.mood` MD.line: every open slot, `have k/n`, the
missing ones with their blocker, `no <Shop>` / `no workshop claimed`, `N d left` | `~N d left (est. from the claim)` | `time
unknown (DF starts it at the claim)`). status: the first two as rank-1 lines right under the clock line; brief: all, under its
head line. guide: `N d left` when the event carries it.

## Tests
`tests/test_bug282_285_moods.py` (status/brief order and budget, guide), `tests/lua/test_mood_emergency.lua` (state line, buy,
gone after MOOD_END). Fail on 64df679.

## Live check
`dfllm status` during a mood: line 2 starts `MOOD <name>`; the days fall with the game; after MOOD_END the line is gone.
