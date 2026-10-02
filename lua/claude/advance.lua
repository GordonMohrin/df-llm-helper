-- claude/advance <ticks>  - let the game run and pause automatically after <ticks>.
-- claude/advance 0        - pause immediately and discard the timer.
-- claude/advance clock    - only report time/pause status.
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
local dismissed = dismiss_popups()

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
timer.start(ticks)
clock({ action = 'running', ticks = ticks })
