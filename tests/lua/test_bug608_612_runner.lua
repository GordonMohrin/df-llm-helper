-- BUG-608 (Run 16a i1 Basementflew y426-y429: the hospital stayed build_lost, 7 parts 'buildingplan: waiting for materials', 8 retries, the
-- materials lay in the flooded z117 complex): a build_lost room names the pieces economy cannot make now and the stock out of reach.
-- BUG-612 (Run 16c i3 Wallfree y375-y376: DEPOT_MISSING 'no known depot site (no fortcore depot)', no caravan ever traded): with no fortcore
-- and no manifest depot the keeper looks for a flat 5x5 block of open floor beside the citizens, on their walk group.
local T = require('testlib')
local H = require('runner_world')
local runner = require('dfllm.runner')

local CFG0 = {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end

local function fresh(tag, mat)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  local W = H.world{tag = tag}
  W.real_bench = true
  W.load({name = 'economy', every = {ticks = 1200},
          mat_for = function(K, kind) if mat and kind == 'bed' then return nil, 'no material for bed: no logs' end return 'rock' end,
          state = function() return {stock = {food_d = 200, drink_d = 300, rock = 50, rock_need = 10}} end})
  W.load(runner)
  return W
end
local function doc(tpl)
  local d = H.doc{tpl = tpl, class = 'living', params = {}, manifest = {v = 2}}
  d.stages[2].chunks[1].cells = {{0, 0, 0, 'b'}, {1, 0, 0, 'b'}, {2, 0, 0, 'b'}, {0, 1, 0, 'R'}}
  return d
end
local function build_none(W) end

T.test('BUG-608: a build_lost hospital whose beds cannot be made says so, with the stock that lies out of reach', function()
  local W = fresh('hm1', true)
  W.K.census.i = {rock_far = 64, blocks_far = 62}
  W.unsuitable['10,10,100'] = true
  W.unsuitable['11,10,100'] = true
  W.unsuitable['12,10,100'] = true
  W.unsuitable['10,11,100'] = true
  H.floor(W, 10, 10, 100, 14, 11)
  local d = doc('hospital')
  H.place(W, 'dr', d)
  H.runs(W, 6)
  H.dig(W)
  for _ = 1, 8 do build_none(W); H.runs(W, 1) end
  local P = H.proj(W, 'dr')
  T.eq(P.blocked, 'build_lost', T.show(P))
  local why = runner.mat_why(W.K, P, d)
  T.ok(why and why:find('bed x3: no logs', 1, true), why)
  T.ok(why:find('out of reach (another walk group): 64 rock, 62 blocks', 1, true), why)
  H.runs(W, 4)
  local pb = W.find_events('PROJECT_BLOCKED')
  T.ok(#pb >= 1)
  T.ok(pb[1].msg:find('(bed x3: no logs; out of reach', 1, true), pb[1].msg)
  T.ok(pb[1].d.mat:find('bed x3: no logs', 1, true), T.show(pb[1].d))
  -- every piece can be made: nothing is said
  local W2 = fresh('hm2', false)
  H.place(W2, 'dr', doc('hospital'))
  T.eq(runner.mat_why(W2.K, H.proj(W2, 'dr'), doc('hospital')), nil)
end)

local function citizens(W, pts)
  local ids = {}
  for i, p in ipairs(pts) do ids[i] = i; end
  local units = {}
  for i, p in ipairs(pts) do units[i] = {id = i, pos = {x = p[1], y = p[2], z = p[3]}} end
  df.unit.find = function(id) return units[id] end
  dfhack.units.getPosition = function(u) return u.pos.x, u.pos.y, u.pos.z end
  W.K.census.u = {ids = ids}
end

T.test('BUG-612: no fortcore, no manifest depot: a flat 5x5 block beside the citizens on their walk group becomes a depot project', function()
  local W = fresh('hd1')
  H.floor(W, 40, 40, 100, 70, 70)
  W.tile(52, 50, 100).c = '#'; W.tile(51, 49, 100).c = 'T'            -- a wall and a tree beside the citizens' spot
  for y = 40, 70 do for x = 40, 70 do local t = W.tile(x, y, 100); t.g = t.c == '.' and 1 or 0 end end
  citizens(W, {{50, 50, 100}, {51, 51, 100}, {52, 52, 100}})
  local ok, id = runner.depot_keep(W.K, 'caravan')
  T.ok(ok, tostring(id))
  T.eq(id, 'depot1')
  local P = H.proj(W, 'depot1')
  T.ok(P and P.tpl == 'depot', 'the depot project is registered')
  local at = W.K.persist.get('m.runner').depot
  T.ok(type(at) == 'table' and math.abs(at[1] - 51) <= 8 and math.abs(at[2] - 51) <= 8 and at[3] == 100, T.show(at))
  -- the block is clear: every tile of the 5x5 around the middle is open floor
  for y = at[2] - 2, at[2] + 2 do for x = at[1] - 2, at[1] + 2 do T.eq(W.tile(x, y, 100).c, '.') end end
  local said
  for _, l in ipairs(W.logs) do if l.msg:find('surface fallback beside the citizens', 1, true) then said = l.msg end end
  T.ok(said, 'logged')
end)

T.test('BUG-612: no flat block (a wall every third tile, another walk group): no site, said once, the search is not repeated for depot_retry', function()
  local W = fresh('hd2')
  H.floor(W, 40, 40, 100, 70, 70)
  for y = 40, 70 do for x = 40, 70 do
    local t = W.tile(x, y, 100)
    if x % 3 == 0 then t.c = '#' end
    t.g = t.c == '.' and 1 or 0
  end end
  citizens(W, {{50, 50, 100}})
  local ok, why = runner.depot_keep(W.K, 'caravan')
  T.eq({ok, why}, {false, 'no known depot site'})
  local calls = W.snap.gcalls
  ok, why = runner.depot_keep(W.K, 'caravan')
  T.eq({ok, why}, {false, 'no known depot site'})
  T.eq(W.snap.gcalls, calls, 'no second search')
  local said
  for _, l in ipairs(W.logs) do if l.msg:find('trade depot missing, no site: no flat 5x5 block', 1, true) then said = l.msg end end
  T.ok(said, 'the reason is logged')
end)

T.test('BUG-612: a manifest depot is still preferred (no search)', function()
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  local W = H.world{tag = 'hd3', persist = {manifest = {v = 2, depot = {60, 60, 100}}}}
  W.load(runner)
  citizens(W, {{50, 50, 100}})
  local ok, id = runner.depot_keep(W.K, 'caravan')
  T.ok(ok and id == 'depot1', tostring(id))
  T.eq(W.snap.gcalls, nil, 'no walk group read: the manifest named the site')
end)

T.test('BUG-608: a build_lost room whose pieces cannot be made is not retried every season; one whose pieces can be made is', function()
  local function lost(tag, mat)
    local W = fresh(tag, mat)
    runner.CFG.retry_every = 12 * 600
    for _, k in ipairs({'10,10,100', '11,10,100', '12,10,100', '10,11,100'}) do W.unsuitable[k] = true end
    H.floor(W, 10, 10, 100, 14, 11)
    H.place(W, 'dr', doc('hospital'))
    H.runs(W, 6)
    H.dig(W)
    for _ = 1, 8 do H.runs(W, 1) end
    T.eq(H.proj(W, 'dr').blocked, 'build_lost')
    for _ = 1, 3 do H.runs(W, 14); W.ms = W.ms + 600000 end
    local n = 0
    for _, l in ipairs(W.logs) do if tostring(l.msg):find('^dr: build_lost at', 1) then n = n + 1 end end
    return W, n
  end
  local W, n = lost('hr1', true)
  T.eq(n, 0, 'no retry while the beds cannot be made')
  local held
  for _, l in ipairs(W.logs) do if tostring(l.msg):find('build_lost retry held, the pieces cannot be made: bed x3', 1, true) then held = true end end
  T.ok(held, 'the hold is logged')
  local _, n2 = lost('hr2', false)
  T.ok(n2 >= 1, 'beds can be made: the season retry runs (' .. n2 .. ')')
end)

T.done()
