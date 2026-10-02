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

function start(ticks)
  cancel()
  local total = df.global.cur_year_tick + ticks
  target = { year = df.global.cur_year + total // 403200, tick = total % 403200 }
  timeout_id = dfhack.timeout(ticks, 'ticks', function()
    df.global.pause_state = true
    timeout_id = nil
  end)
  df.global.pause_state = false
end

function active()
  return timeout_id ~= nil and dfhack.timeout_active(timeout_id) ~= nil
end

if dfhack_flags and dfhack_flags.module then
  return
end
