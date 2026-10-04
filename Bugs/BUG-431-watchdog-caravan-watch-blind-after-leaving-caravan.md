# BUG-431: `watchdog.caravan_watch` never fires again after a caravan stays in `plotinfo.caravans` as `Leaving`

- **Status:** open (worked around in `claude/aufsicht`, dwarf-fortress commit `3c27174`)
- **Severity:** S1
- **Area:** `lua/claude/watchdog.lua` (`caravan_watch`)
- **Reported:** 2026-10-04, commit `eb0f007`
- **Environment:** Windows 11, Python 3.14, game: running (DF 53.16 + DFHack), fort Windrings year 182 (Run 5)

## Command / steps
1. Caravan entity 35 finished trading: `trade_state = 3` (Leaving), `time_remaining = 0`, `goods = 0`.
2. The entry stays in `df.global.plotinfo.caravans` for hours (never removed).
3. A new caravan (entity 29) arrives at 22:02.

## Expected
`caravan.flag`, `pause.hold` and event `CARAVAN_ARRIVAL` for the new caravan within a minute.

## Actual
No flag, no pause, no event. The player noticed the merchant first ("is a trader at the depot?"). Cause (`lua/claude/watchdog.lua`, `caravan_watch`):
```lua
local car = #df.global.plotinfo.caravans > 0
if not car then state.caravan_paused = false return end
...
if state.caravan_paused then return end
```
`caravan_paused` is only reset when the list is empty, which never happens while the leaving caravan sits in it.

## Evidence
`tools/caravan.flag` was last written at 00:58 the previous day. plotinfo dump at 22:05: `entity 35 trade_state 3 time_remaining 0 goods 0`, `entity 29 trade_state 2 time_remaining 2319`.

## Analysis (reporter's hypothesis)
State must be kept per entity and per `trade_state`, not "list non-empty".

## Suggested fix
Track `{entity -> trade_state}` and fire when an entity becomes 1 or 2 (new, or coming back from 3). This is implemented in `claude/aufsicht` (`check_karawane`, event `KARAWANE_DA`); `watchdog.lua` itself should get the same logic so aufsicht can drop its copy.

## Info needed
none.
