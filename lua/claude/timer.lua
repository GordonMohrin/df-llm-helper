--@ module = true
-- Holds the running "advance" timer. As a module, the state persists between calls.

timeout_id = timeout_id or nil
target = target or nil -- { year, tick }

function cancel()
  if timeout_id then
    dfhack.timeout_active(timeout_id, nil)
    timeout_id = nil
  end
  target = nil
end

local YEAR = 403200
local function now_abs() return df.global.cur_year * YEAR + df.global.cur_year_tick end

-- dfhack.timeout(n, 'ticks') counts simulation frames, not calendar ticks: with timestream 2..9 calendar ticks pass per
-- frame (tempo.lua). So the timer re-arms itself with a fraction of the remaining CALENDAR ticks and pauses as soon as
-- the calendar target is reached (overshoot at most one frame, BUG-405).
local function arm(goal)
  local rest = goal - now_abs()
  if rest <= 0 then
    df.global.pause_state = true
    timeout_id = nil
    return
  end
  timeout_id = dfhack.timeout(math.max(1, rest // 10), 'ticks', function() arm(goal) end)
end

function start(ticks)
  cancel()
  local goal = now_abs() + ticks
  target = { year = goal // YEAR, tick = goal % YEAR }
  arm(goal)
  df.global.pause_state = false
end

function active()
  return timeout_id ~= nil and dfhack.timeout_active(timeout_id) ~= nil
end

if dfhack_flags and dfhack_flags.module then
  return
end
