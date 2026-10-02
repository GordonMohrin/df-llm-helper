-- claude/advance <ticks>  - let the game run and pause automatically after <ticks>.
-- claude/advance 0        - pause immediately and discard the timer.
-- claude/advance clock    - only report time/pause status (changes nothing).
-- claude/advance run      - run continuously (no timer).
-- <ticks> are calendar ticks (also with timestream on, see timer.lua); popups are dismissed only by run / <ticks>.
local util = reqscript('claude/util')
local timer = reqscript('claude/timer')
if not util.require_fort() then return end

local arg = ({ ... })[1] or 'clock'

-- Message windows (e.g. "Migrants have arrived") halt the simulation until one clicks
-- "OK". We take care of that here; the content stays in the game log.
local function dismiss_popups()
  local p = df.global.world.status.popups
  local n = #p
  while #p > 0 do
    local x = p[#p - 1]
    p:erase(#p - 1)
    x:delete()
  end
  return n
end
-- Only dismissed where the game is set running (run / <ticks>); 'clock', '0' and invalid arguments are pure reads
-- and leave the announcement windows for the player (BUG-404).
local dismissed = 0

local function clock(extra)
  local out = {
    paused = df.global.pause_state,
    date = util.game_date(),
    timer_active = timer.active(),
    target = timer.target,
    popups_dismissed = dismissed > 0 and dismissed or nil,
  }
  for k, v in pairs(extra or {}) do out[k] = v end
  util.emit(out)
end

if arg == 'run' then
  -- run without a target (continuous operation); watchdog and popups are handled by claude/watchdog
  timer.cancel()
  dismissed = dismiss_popups()
  df.global.pause_state = false
  clock({ action = 'running-continuous' })
  return
end

if arg == 'clock' then
  clock()
  return
end

local ticks = tonumber(arg)
if not ticks or ticks < 0 then
  util.emit({ error = 'ticks muss eine Zahl >= 0 sein' })
  return
end

if ticks == 0 then
  timer.cancel()
  df.global.pause_state = true
  clock({ action = 'paused' })
  return
end

-- Upper bound: one game month per call, so Claude checks in regularly.
if ticks > util.TICKS_PER_MONTH then ticks = util.TICKS_PER_MONTH end
dismissed = dismiss_popups()
timer.start(ticks)
clock({ action = 'running', ticks = ticks })
