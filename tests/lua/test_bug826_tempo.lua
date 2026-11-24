-- BUG-826 (Neuausrichtung 2, docs/v2/NEU2-tempo.md; Gordon 24.11.: by default every game runs at maximum game frames and few
-- graphics frames): clock.gfps (default 10) and clock.peace_fps (default 1000) in config/reflex.json; only quiet PEACE gets
-- faster, every other mode, the supply brake, the trade clamp, tempo.lower and the lockdown keep their behaviour; the vanilla
-- FPS cap is never raised; the status clock names both values.
local T = require('testlib')
local H = require('kern_world')
local kmock = require('dfllm.util.k_mock')
local arbiter = require('dfllm.arbiter')
arbiter.PROFILE.overlays = true

local function world(tag, clock, extra, pre)
  local dir = H.tmpdir(tag)
  local W = kmock.new{dfpath = dir, cfg = {reflex = {v = 2, clock = clock}}}
  if pre then pre() end
  luahost.mkdir_recursive(dir .. '/dfllm-runtime')
  package.loaded['plugins.timestream'] = {timestream_getFps = function() return W.timestream_fps end}
  package.loaded['plugins.overlay'] = nil
  for _, m in ipairs(extra or {}) do W.load(m) end
  W.load(arbiter)
  return W, dir
end
-- k_mock records every setting write in W.settings and leaves df.global alone: no write = the live value
local function capv(W) return W.settings.fps_cap or math.floor(df.global.enabler.fps) end
local function find_acts(W, fn, a1)
  local r = {}
  for _, a in ipairs(W.find_acts(fn)) do if a1 == nil or a.args[1] == a1 then r[#r + 1] = a end end
  return r
end

T.test('BUG-826: defaults: quiet PEACE runs timestream 1000, gfps 10, the FPS cap is never written', function()
  T.eq({arbiter.CLOCK.gfps, arbiter.CLOCK.peace_fps, arbiter.MODE_FPS.PEACE}, {10, 1000, 1000})
  local W = world('t826def')
  W.run(40, {paused = true})
  T.eq({W.settings.gfps, W.timestream_fps}, {10, 1000})
  T.eq(#find_acts(W, 'setting', 'fps_cap'), 0, 'the cap is not raised (timestream runs above it)')
  T.eq(capv(W), 250)
  local c = W.state().clock
  T.eq({c.cap, c.orig, c.ts, c.gfps, c.pt, c.why}, {250, 250, 1000, 10, 1000, ''})
  W.unload()
  T.eq(W.settings.gfps, 250, 'the original graphics frame rate is back after unload')
end)

T.test('BUG-826: a player FPS cap below the target is left alone in PEACE (60 stays 60)', function()
  local W = world('t826cap60', nil, nil, function() df.global.enabler.fps = 60 end)
  W.run(40, {paused = true})
  T.eq({capv(W), W.timestream_fps}, {60, 1000})
  T.eq(#find_acts(W, 'setting', 'fps_cap'), 0)
  df.global.enabler.fps = 250
end)

T.test('BUG-826: config override of gfps and peace_fps', function()
  local W = world('t826cfg', {gfps = 20, peace_fps = 600})
  W.run(40, {paused = true})
  T.eq({W.settings.gfps, W.timestream_fps}, {20, 600})
  local c = W.state().clock
  T.eq({c.gfps, c.pt, c.ts}, {20, 600, 600})
end)

T.test('BUG-826: invalid gfps / peace_fps fall back to the built-in defaults (key by key)', function()
  for i, bad in ipairs({{gfps = 0, peace_fps = 99}, {gfps = 101, peace_fps = 1001}, {gfps = 'fast', peace_fps = 1e3 + 0.5},
                        {gfps = -3, peace_fps = true}, {gfps = {}, peace_fps = 'x'}}) do
    local W = world('t826bad' .. i, bad)
    W.run(40, {paused = true})
    T.eq({W.settings.gfps, W.timestream_fps}, {10, 1000}, 'case ' .. i)
  end
  local W = world('t826half', {gfps = 25, peace_fps = 5})        -- one valid, one invalid: the valid one is kept
  W.run(40, {paused = true})
  T.eq({W.settings.gfps, W.timestream_fps}, {25, 1000})
  T.eq(arbiter.clock_cfg(W.K).siege_cap, 30, 'the caps keep their defaults')
end)

T.test('BUG-826: every other mode keeps its tempo and cap, even with a faster peace_fps; gfps stays', function()
  local W = world('t826modes', {peace_fps = 800})
  W.run(40, {paused = true})
  T.eq(W.timestream_fps, 800)
  local want = {ALERT = {-1, 100}, SIEGE = {-1, 30}, BREACH = {-1, 30}, DRILL = {-1, 30}, RECOVERY = {250, 250}}
  for _, m in ipairs({'ALERT', 'PEACE', 'SIEGE', 'BREACH', 'RECOVERY', 'PEACE', 'DRILL'}) do
    W.K.set_mode(m, 'test')
    W.run(10, {paused = true})
    if want[m] then
      T.eq({W.timestream_fps, capv(W), W.settings.gfps}, {want[m][1], want[m][2], 10}, m)
    else
      T.eq({W.timestream_fps, capv(W), W.settings.gfps}, {800, 250, 10}, m)
    end
  end
  W.K.set_mode('PEACE', 'test')
  W.run(10, {paused = true})
  T.eq({W.timestream_fps, capv(W)}, {800, 250}, 'back in PEACE: the target, the original cap')
end)

T.test('BUG-826: the supply brake, tempo.lower and the lockdown still win over the quiet target', function()
  local alarm
  local eco = {name = 'economy', every = {ticks = 1200}}
  function eco.alarm(K) return alarm end
  local why
  local reflex = {name = 'reflex', every = {ticks = 10}}
  function reflex.holding(K, what) return why end
  local W = world('t826win', nil, {eco, reflex})
  W.run(40, {paused = true})
  T.eq(W.timestream_fps, 1000)
  alarm = 'thirst 3'
  W.run(40, {paused = true})
  T.eq({W.timestream_fps, capv(W), W.state().owners.tempo}, {arbiter.BRAKE_FPS, arbiter.BRAKE_FPS, 'brake'})
  alarm = nil
  W.run(40, {paused = true})
  T.eq({W.timestream_fps, capv(W)}, {1000, 250})
  why = 'arrival:siege'
  W.K.call('arbiter', 'hold')
  T.eq({W.timestream_fps, capv(W)}, {-1, 30}, 'lockdown: timestream off, siege cap')
  why = nil
  W.run(40, {paused = true})
  T.eq({W.timestream_fps, capv(W)}, {1000, 250})
end)

T.test('BUG-826: while trade holds the clock gfps rises to 30 and the trade cap holds; both fall back after', function()
  local why
  local trade = {name = 'trade', every = {ticks = 100}}
  function trade.clock(K) return why end
  local W = world('t826trade', nil, {trade})
  W.run(10, {paused = true})
  T.eq(W.settings.gfps, 10)
  why = 'trade'
  W.run(40, {paused = true})
  T.eq({W.settings.gfps, W.timestream_fps, capv(W)}, {30, -1, 100})
  why = nil
  W.run(40, {paused = true})
  T.eq({W.settings.gfps, W.timestream_fps, capv(W)}, {10, 1000, 250})
  T.eq(#find_acts(W, 'setting', 'gfps'), 3, 'boot 10, trade 30, back 10: no write per pass')
end)

T.test('BUG-826: a gfps of 40 is not lowered to 30 while trade holds the clock (never below the configured value)', function()
  local why = 'trade'
  local trade = {name = 'trade', every = {ticks = 100}}
  function trade.clock(K) return why end
  local W = world('t826g40', {gfps = 40}, {trade})
  W.run(40, {paused = true})
  T.eq(W.settings.gfps, 40)
end)

T.test('BUG-826: D-11 rejected: no timestream, status ts -1, gfps still set', function()
  local dir = H.tmpdir('t826d11')
  local W = kmock.new{dfpath = dir, cfg = {decisions = {['D-11'] = 'rejected'}}}
  luahost.mkdir_recursive(dir .. '/dfllm-runtime')
  package.loaded['plugins.timestream'] = {timestream_getFps = function() return W.timestream_fps end}
  package.loaded['plugins.overlay'] = nil
  W.load(arbiter)
  W.run(40, {paused = true})
  T.eq(#W.find_acts('timestream'), 0)
  T.eq({W.state().clock.ts, W.state().clock.gfps}, {-1, 10})
end)

T.done()
