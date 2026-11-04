-- BUG-328 review (merge14): a set-aside build project that loses a piece came never back by itself (the measure-only
-- pass reset P.chunk and stopped before measure_build from then on), and the life-critical exemptions (mood, care lead,
-- aqshaft) were checked only when a project was set aside, never for one set aside already. Every test fails on 5dca864.
local T = require('testlib')
local H = require('runner_world')
local runner = require('dfllm.runner')

local CFG0 = {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end
local STOCK = {}
local function fresh(opts)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  STOCK = {food_d = 200, drink_d = 300, rock = 50, rock_need = 10}
  local W = H.world(opts)
  W.load({name = 'economy', every = {ticks = 1200}, mat_for = function() return 'rock' end,
          state = function() return {stock = STOCK} end})
  dfhack.buildings = dfhack.buildings or {}
  dfhack.buildings.findAtTile = function(x, y, z)
    local id = W.bld_at[x .. ',' .. y .. ',' .. z]
    return id and W.buildings[id] or nil
  end
  W.load(runner)
  return W
end
local function logged(W, level, pat)
  for _, l in ipairs(W.logs) do if l.level == level and l.msg:find(pat) then return l end end
end
local function row(W, id) for _, r in ipairs(W.state().proj) do if r[1] == id then return r end end end
local function aside(W, id) return ((row(W, id) or {})[4] or ''):find('^set aside') ~= nil end

-- a build project whose two beds nobody builds, run until it is set aside (idle_days 5)
local function set_aside(W, id, o)
  H.floor(W, 10, 10, 100, 14, 11)
  H.place(W, id, H.doc(o or {x = 10}))
  H.runs(W, 6)
  H.dig(W)
  for _ = 1, 2 * 14 do H.runs(W, 1) end
end
local CFG5 = {baseline = {v = 2, runner = {queue = {idle_days = 5}}}}

T.test('BUG-328 review: a set-aside build project that loses a placed piece comes back by itself and places it ' ..
       'again (old: P.chunk reset by the measure, never measured again, set aside until bp.resume)', function()
  local W = fresh{tag = 'r328lost', cfg = CFG5}
  set_aside(W, 'st')
  T.ok(aside(W, 'st'), T.show(row(W, 'st')))
  local id = W.bld_at['10,10,100']
  T.ok(id, 'the bed was placed')
  W.buildings[id], W.bld_at['10,10,100'] = nil, nil       -- the bed is gone (cancelled, deconstructed, destroyed)
  for _ = 1, 2 * 4 do H.runs(W, 1) end
  T.ok(logged(W, 'info', '^st %(bedrooms%) moves again after %d+ days set aside'), 'back by itself')
  T.ok(not aside(W, 'st'), T.show(row(W, 'st')))
  T.ok(W.bld_at['10,10,100'], 'the lost bed is placed again')
end)

T.test('BUG-328 review: a project set aside before a strange mood claims its shop comes back at once and takes a ' ..
       'slot (old: barred from every slot while the mood dwarf waited)', function()
  local W = fresh{tag = 'r328mood', cfg = CFG5}
  set_aside(W, 'ws', {x = 10, tpl = 'workshops', class = 'infra', params = {},
                      manifest = {v = 2, workshops = {{type = 'Craftsdwarfs', pos = {0, 0, 0}}}}})
  T.ok(aside(W, 'ws'), T.show(row(W, 'ws')))
  local _, left = W.K.call('runner', 'mood_types', '26535', {'Craftsdwarfs'})
  T.eq(left, {}, 'the set-aside project covers the mood')
  H.runs(W, 1)
  T.ok(logged(W, 'info', '^ws %(workshops%) back after %d+ days set aside %(a strange mood waits for it%)'),
       'released for the mood')
  T.ok(not aside(W, 'ws'), T.show(row(W, 'ws')))
  for _ = 1, 2 * 14 do H.runs(W, 1) end
  T.ok(not aside(W, 'ws'), 'not set aside again while the mood waits')
end)

T.test('BUG-328 review: the refuge drink store is never set aside', function()
  local W = fresh{tag = 'r328drink', cfg = CFG5}
  set_aside(W, 'rd', {x = 10, tpl = 'refuge_drink', class = 'infra', params = {}, manifest = {v = 2}})
  T.ok(not aside(W, 'rd'), T.show(row(W, 'rd')))
  T.eq(W.state().sched and W.state().sched.ip, nil)
end)

T.test('BUG-328 review: a seal set aside in PEACE comes back when a SIEGE starts; a food/drink project in a drink ' ..
       'emergency too', function()
  local W = fresh{tag = 'r328seal', cfg = CFG5}
  set_aside(W, 'st')
  T.ok(aside(W, 'st'), T.show(row(W, 'st')))
  -- a seal and a cistern set aside earlier (the record idle_scan writes)
  local t = W.K.now().tick
  for _, s in ipairs({{'sl', 'seal', 'defense', 40}, {'cs', 'cistern', 'infra', 70}}) do
    H.put(W, s[1], H.dig_doc(1, {tpl = s[2], class = s[3], params = {}, x = s[4]}))
    W.inbox('bp.place', {tpl = s[2], site = 'S1'}, {id = s[1]})
  end
  local rt = W.K.persist.get('m.runner')
  for _, id in ipairs({'sl', 'cs'}) do rt.ip[id] = {t = t, ps = t, si = 0, why = 'no progress'} end
  H.runs(W, 1)
  T.ok(aside(W, 'sl') and aside(W, 'cs'), 'both set aside in PEACE without an emergency')
  W.mode = 'SIEGE'
  H.runs(W, 1)
  T.ok(logged(W, 'info', '^sl %(seal%) back after %d+ days set aside %(a seal in SIEGE%)'), 'the seal is back')
  T.ok(aside(W, 'cs') and aside(W, 'st'), 'the others stay set aside')
  W.mode = 'PEACE'
  STOCK.drink_d = 0                                      -- a drink emergency (seal_first drink_d)
  H.runs(W, 6)
  T.ok(logged(W, 'info', '^cs %(cistern%) back after %d+ days set aside %(drink 0 d%)'), 'the cistern is back')
  T.ok(aside(W, 'st'), 'the bedrooms stay set aside')
end)

T.done()
