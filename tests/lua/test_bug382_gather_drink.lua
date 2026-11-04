-- BUG-382 (Run 16c i3: drink 150 -> 0 days with 16 brews waiting, 'no brewable plants' and two finished farms without seeds,
-- food 378 days): the runner drew its gather zone for low food only and removed it at food > 120, so nobody gathered plants
-- for the stills. economy's stock.bshort (drink below gather.drink_d with the brewable plants short of the deficit) draws the
-- zone and keeps it; it goes once the drink plants are back and food is not low. Fails on ec9bd8e (no zone, bshort unknown).
local T = require('testlib')
local H = require('runner_world')
local runner = require('dfllm.runner')

local CFG0 = {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end
local function fresh(opts)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  require('dfllm.aqshaft').CFG.on = true
  local W = H.world(opts)
  W.load(runner)
  return W
end
local function world(tag)
  local W = fresh{tag = tag, ytick = 0, persist = {manifest = {v = 2, depot = {100, 100, 60}}}}
  W.fd, W.short = 378, true
  W.load{name = 'economy', every = {ticks = 1200}, state = function()
    return {stock = {food_d = W.fd, drink_d = 40, bshort = W.short and 1 or nil}}
  end}
  for x = 80, 120 do for y = 80, 120 do W.map[x .. ',' .. y .. ',62'] = {c = '.', dig = ''} end end
  W.state()
  return W
end
local function zones(W)
  local r = {}
  for _, a in ipairs(W.find_acts('quickfort')) do
    local p = a.args[1]
    if p.mode == 'zone' then r[#r + 1] = p.data[0][0][0] end
  end
  return r
end
local function logged(W, pat)
  for _, l in ipairs(W.logs) do if l.msg:find(pat, 1, true) then return l end end
end

T.test('BUG-382: drink plants short with food 378 days: the gather zone is drawn and stays; it goes when the plants are back', function()
  local W = world('gd1')
  H.runs(W, 1)
  T.eq(zones(W), {'g{name=dfllm-gather}(28x28)'}, 'a zone for the stills\' plants beside plenty of food')
  T.ok(logged(W, 'drink plants short'), 'the log line says why')
  H.runs(W, 14)
  T.eq(#zones(W), 1, 'drawn once')
  T.eq(#W.find_acts('zone_remove'), 0, 'food above 120 does not remove it while the drink plants are short')
  W.short = false
  W.state()
  H.runs(W, 7)
  local rm = W.find_acts('zone_remove')
  T.eq(#rm, 1, 'the plants are back and food is high: removed')
  T.eq(rm[1].args[1], 'dfllm-gather')
  T.eq(W.K.persist.get('m.runner').gather, nil)
end)

T.test('BUG-382: no drink shortage, plenty of food: no zone', function()
  local W = world('gd2')
  W.short = false
  W.state()
  H.runs(W, 3)
  T.eq(zones(W), {}, 'nothing short')
end)

T.done()
