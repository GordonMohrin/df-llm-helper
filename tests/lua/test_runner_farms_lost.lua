-- BUG-257 (Run 15 Inkintense c1a18745d4e25dac02, Drillchamber c1a187433a25b12d07: farms 'build_lost at build, missing p',
-- retry 1..8/8 from dig on the same stone site, 'soil 0/70', for 8 seasons): quickfort builds farm plots only on soil or
-- mud and a re-dig brings neither. A farms project's retries are spent at the first build_lost (runner.lost counts it at
-- once, economy has follow place the farms elsewhere); other templates keep their retries. Fails on 2b9c009.
local T = require('testlib')
local H = require('runner_world')
local runner = require('dfllm.runner')

local CFG0 = {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end

local function world()
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  local W = H.world{tag = 'farmlost', map_size = {16, 16, 160}}
  dfhack.buildings = dfhack.buildings or {}
  dfhack.buildings.findAtTile = function(x, y, z)
    local id = W.bld_at[x .. ',' .. y .. ',' .. z]
    return id and W.buildings[id] or nil
  end
  W.load({name = 'economy', every = {ticks = 1200}, mat_for = function() return 'rock' end,
          state = function() return {stock = {food_d = 200, drink_d = 300, rock = 50, rock_need = 10}} end})
  W.load(runner)
  W.state()
  return W
end

T.test('BUG-257: a farms project lost to build_lost is lost for good at once (no re-dig); a bedrooms project keeps ' ..
       'its retries', function()
  local W = world()
  H.place(W, 'fm', H.doc{tpl = 'farms', class = 'infra', x = 10, params = {plots = 1}}, {tpl = 'farms', site = 'S1',
                                                                                         prio = 1})
  H.place(W, 'bd', H.doc{tpl = 'bedrooms', x = 70})
  H.runs(W, 1)
  for _, id in ipairs({'fm', 'bd'}) do
    local P = H.proj(W, id)
    P.blocked, P.since = 'build_lost', W.K.now().tick
  end
  H.runs(W, 2)
  T.eq({W.K.call('runner', 'lost', 'farms')}, {true, 1, 'fm'}, 'live: retry 1..8/8 on the same site')
  T.eq({W.K.call('runner', 'lost', 'bedrooms')}, {true, 0, nil}, 'other templates retry as before')
  local n = 0
  for _, l in ipairs(W.logs) do
    if tostring(l.msg):find('fm: farms build_lost: plots need soil or mud, a re-dig brings none', 1, true) then n = n + 1 end
  end
  T.eq(n, 1, 'one kern.log line')
  T.eq(W.K.persist.get('m.runner').rty.fm.n, runner.CFG.retry_max)
end)

T.done()
