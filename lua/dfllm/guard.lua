-- guard (FR-68): the emergency hook `dfllm stop` leaves behind in a dangerous mode (SIEGE, BREACH, ALERT, or a
-- reflex lockdown holding the clock). Live y419 (Run 10, Handlelock, a siege): the session stopped the kernel for
-- ~3 min to pull levers by hand; stop put the FPS cap and timestream back to 500, and nothing dismissed popups any
-- more, so every death notice ("... has been found dead, dehydrated.") halted the fort until `dfllm reload`.
-- While the kernel is stopped the guard (repeat `dfllm-guard`, every EVERY frames, also while paused) does only
-- what the arbiter does on the same screens, through the act library (UI-equivalent, fair play):
--   * dismisses the front announcement popup when the arbiter's whitelist classifies it (arbiter.classify:
--     migrants, caravan, death, mood, ..., and the threat popups the arbiter dismisses after its reflex);
--     unknown popups and the embark intro stay for the player; act.dismiss_popup;
--   * keeps the vanilla FPS cap at the clamp the kernel held (the mode's cap: 30 in SIEGE/BREACH, 100 in ALERT)
--     and timestream off when it was off (act.setting fps_cap, act.timestream -1).
-- It never pauses or unpauses (the player's pause stays) and touches nothing else. kern.boot (dfllm boot, adopt,
-- reload) and kern.restore (dfllm restore, `dfllm stop --restore-fps` on a stopped kernel) remove it; a map unload
-- removes it and heals restore.json (the held cap and timestream come back). <save>/guard.json says what it does
-- (`dfllm status` in Python and in game read it); its `wall` is refreshed every WALL_S seconds.
local actlib = require('dfllm.act')
local fio = require('dfllm.io')
local json = require('dfllm.util.json')
local C = require('dfllm.util.contract')

local G = {KEY = 'dfllm-guard', EVERY = 10, WALL_S = 5}
G.MODES = {SIEGE = true, BREACH = true, ALERT = true}   -- persisted modes in which `dfllm stop` keeps the clock

local cur        -- the running guard, nil when off

local function int(v) return type(v) == 'number' and math.tointeger(v) or nil end

local function tick()
  local ok, t = pcall(function() return C.abs_tick(df.global.cur_year, df.global.cur_year_tick) end)
  return ok and int(t) or 0
end

local function oneline(s) return (tostring(s or ''):gsub('[\t\r\n]', ' ')) end

-- the act library on its own (no kernel): commands.log lines with origin `guard`, no events
local function make_act(save)
  return actlib.new{
    who = function() return nil end,
    allowlist = function() return actlib.BUILTIN_ALLOWLIST end,
    log_cmd = function(origin, what, args_json, result)
      if save then
        fio.append(save .. '/commands.log', string.format('%d\t%d\tguard\t%s\t%s\t%s\n', os.time(), tick(),
                   oneline(what), oneline(args_json), oneline(result)), fio.LOG_MAX)
      end
    end,
    fail = function() end,
  }
end

local function summary(c)
  local kinds = {}
  for k, n in pairs(c.kinds) do kinds[#kinds + 1] = string.format('%s %d', k, n) end
  table.sort(kinds)
  return string.format('%s, FPS cap %d%s, %d popup%s dismissed%s', c.mode, c.cap, c.ts_off and ', timestream off' or '',
                       c.n, c.n == 1 and '' or 's', #kinds > 0 and (' (' .. table.concat(kinds, ', ') .. ')') or '')
end

local function write(c, why)
  c.wall = os.time()
  if not c.save then return end
  local kinds = {}
  for k, n in pairs(c.kinds) do kinds[k] = n end
  fio.write(c.save .. '/guard.json', json.encode({
    v = 2, on = c.on and 1 or 0, mode = c.mode, cap = c.cap, ts_off = c.ts_off and 1 or 0, why = why or '',
    since = c.since, wall = c.wall, n = c.n, kinds = json.object(kinds), last = c.last or ''}))
end

local function pass(c)
  local popups = df.global.world.status.popups
  if #popups > 0 then
    local text = dfhack.df2utf(popups[0].text)
    local kind = c.classify(text)
    if kind and c.act.dismiss_popup(kind) then
      c.n, c.kinds[kind], c.last = c.n + 1, (c.kinds[kind] or 0) + 1, oneline(text):sub(1, 120)
      write(c, 'popup')
    end
  end
  local fps = int(math.floor((df.global.enabler.fps or 0) + 0.5))
  if fps and fps > c.cap then c.act.setting('fps_cap', c.cap) end
  if c.ts_off then
    local okp, ts = pcall(require, 'plugins.timestream')
    local okv, v = pcall(function() return okp and type(ts) == 'table' and ts.timestream_getFps() end)
    if okv and int(v) and v > 0 then c.act.timestream(-1) end
  end
  if os.time() - (c.wall or 0) >= G.WALL_S then write(c, 'alive') end
end

-- one guard pass (the repeat callback; tests call it directly)
function G.tick()
  local c = cur
  if not c then return end
  local ok, err = pcall(pass, c)
  if not ok then c.err = oneline(err):sub(1, 200) end
end

-- spec = {mode, cap (FPS cap to hold), ts_off (timestream off), why, save (<save> runtime dir), classify = fn(text)
-- -> kind or nil}; replaces a running guard
function G.install(spec)
  if cur then G.remove('replaced') end
  local cap = int(spec.cap)
  if not cap or cap < 10 then return false, 'guard needs an FPS cap 10..1000' end
  local classify = spec.classify
  if type(classify) ~= 'function' then
    local ok, A = pcall(require, 'dfllm.arbiter')
    classify = ok and type(A) == 'table' and A.classify or function() return nil end
  end
  local c = {on = true, mode = tostring(spec.mode or '?'), cap = cap, ts_off = spec.ts_off == true,
             why = tostring(spec.why or ''), save = spec.save, since = os.time(), n = 0, kinds = {},
             classify = classify, act = make_act(spec.save)}
  cur = c
  write(c, 'stop')
  require('repeat-util').scheduleEvery(G.KEY, G.EVERY, 'frames', G.tick)
  dfhack.onStateChange[G.KEY] = function(code)
    if code == (rawget(_G, 'SC_MAP_UNLOADED') or 3) then G.unloaded() end
  end
  G.tick()                                                   -- the clamp holds from this frame on
  return true, summary(c)
end

-- remove the guard (boot, restore, map unload); returns its summary, nil when none ran
function G.remove(why)
  local c = cur
  if not c then return nil end
  cur = nil
  pcall(function() require('repeat-util').cancel(G.KEY) end)
  if dfhack.onStateChange then dfhack.onStateChange[G.KEY] = nil end
  c.on = false
  pcall(write, c, why or 'removed')
  return summary(c) .. string.format(' in %d s', math.max(0, os.time() - c.since))
end

-- map unload: no fort to guard any more; restore.json (still active) gives the held cap and timestream back
function G.unloaded()
  if not cur then return end
  G.remove('unload')
  pcall(function() require('dfllm.kern').restore{} end)
end

-- the running guard's numbers (dfllm status in game, tests), nil when off
function G.active()
  local c = cur
  if not c then return nil end
  return {mode = c.mode, cap = c.cap, ts_off = c.ts_off, n = c.n, since = c.since, err = c.err, text = summary(c)}
end

return G
