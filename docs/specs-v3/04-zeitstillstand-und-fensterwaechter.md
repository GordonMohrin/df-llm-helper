# Spec v3-04: Time-standstill and window guard

Priority: P0 | As of: 01.10.2026 (Run 5, Y109) | Status: implemented (v3), not yet live-tested | Framework: see `../specs-v2/README.md`

## Goal and benefit
Detect that game time stands still although `pause_state=false`, and remove the cause. In Run 5 the game stood still for 5 minutes because Info/Justice and Help were open; later a DFHack MessageBox ("trade finished") held the game. The player noticed it first.
**Expected gain:** no unnoticed standstill; saves manual work after every trade (MessageBox, `pause.hold`, `caravan.flag`).

## Detection
- **Primary:** `df.global.world.frame_counter` and `cur_year_tick` do not move over 3 watcher ticks (6 s), not paused (`R`).
- **Focus class:** from `getCurFocus(true)`: `Info/*`, `Help`, `dfhack/lua/MessageBox`, `Trade/*`, `ViewSheets/*`, `Designate/*` (mode), `Squads/*`, `Announcement` windows.

## Measures (maintenance, automatic, with loop protection)
1. `LEAVESCREEN` until `dwarfmode/Default` (max. 4 attempts, 1 s apart), only if the focus class does not belong to a **running trade** (close trade windows only if `trade.flow` is not in SELECT_LIVE/CONFIRM/FINISH).
2. `dfhack/lua/MessageBox`: first `SELECT` (OK), then `LEAVESCREEN`.
3. Afterwards `claude/advance run` only if neither `pause.hold` nor `alert.flag` is current and there is no enemy (otherwise keep the pause).
4. **Trade aftercare:** after `trade.flow == DONE`: delete `pause.hold` (reason `karawane`) and `caravan.flag`, close the MessageBox, `advance run`. This is the open fix from the live trade (CHANGELOG, "pause.hold stays behind").
5. **Player in the game:** an Info window the player is opening right now must not be closed immediately: grace period `grace_s` (default 20 s), unless game time stands still meanwhile.
6. **Log:** every action as an event `Time stood still (focus): window closed`.

## Configuration
`freeze_guard: {ticks_to_act: 3, max_leave: 4, grace_s: 20, classes: [Info, Help, MessageBox, ViewSheets]}`

## Fair play
Only simulated menu input (like a player operating the game).

## Acceptance criteria
1. Replay "Justice/OPEN_CASES + Help, time stands still": after 6 s + action `Default`, time runs.
2. Replay "MessageBox after the end of a trade": closed, `pause.hold`/`caravan.flag` gone, game runs.
3. Test "trade running (SELECT_LIVE)": the trade window is not closed.
4. Test "player opens Info, time runs": no action (time not moving is the precondition).
5. Loop protection: after 3 unsuccessful attempts a critical warning instead of further input.

## Fixtures/tests
Focus lists ("dwarfmode/Info/JUSTICE/OPEN_CASES|dwarfmode/Help", "dfhack/lua/MessageBox"), counter time series.

## Implementation notes (v3)
- Code: pure logic `df_llm_helper/freeze_guard.py` (`FreezeGuard.decide`, `apply`), called by the watcher `df_llm_helper/waechter.py` after its status query; config section `freeze_guard` in `df_llm_helper/features/freeze_guard_cfg.py`. Tests: `tests/test_freeze_guard.py` (AC1–AC5 named `test_acN_*`); fixtures: `fixtures/v3/freeze/` (synthetic, see its README).
- Watcher status line (`CLEAR_CMD`) now ends with ` fc=<frame_counter> yt=<cur_year_tick>`; the unpause pattern accepts both (and the old form without them).
- Further config keys: `enabled`, `leave_gap_s: 1.0`, `max_attempts: 3`, `max_per_hour: 10`, `aftercare: true`. Every action goes to `state.db` (`actions`, rule `freeze_guard`: close_screens, trade_aftercare, protected, unhandled, give_up, capped) and to `events.log`; give-up/cap also as a critical digest warning.
- Interpretations/deviations: (a) Info/Help/... windows are only handled when not paused (`R`); a MessageBox is handled paused or not. (b) The grace period applies to a window that appeared while time was running (= opened by the player); a window that was already open when the guard started or that appeared while time stood still (MessageBox, Run 5 incident) gets no grace, so AC1 acts after 6 s. (c) While a trade is in SELECT_LIVE/CONFIRM/FINISH the guard sends no input at all (not only to trade windows); trade windows are only closed if `Trade` is added to `classes`. (d) Aftercare runs once per finished trade (`trade.flow.since`, persisted) and removes only a `pause.hold`/`caravan.flag` written before the trade reached DONE, so a new caravan is never released by mistake. (e) Each key press is guarded in Lua: it is only sent while the focus still contains a handled class (never on `dwarfmode/Default`, where Escape opens the options menu).
