-- BUG-546 (Run 16d i4 Trumpetrealms y397-y404: the LinkBuildingToTrigger jobs of the refuge levers O1/B2 hung more than 1000 days, gate.links
-- skipped a lever with link_pending, the diagnosis `link_stale` offered no command): gate takes an unworked link job down after
-- gate.LINK_REISSUE ticks (act.cancel_link_job) and links the lever again with the mechanisms that stand now; after gate.LINK_MECH ticks of a
-- queued job it asks economy for a dwarf with the Mechanics labor (economy.mechanic_labor); a job with a worker is left alone and then the
-- question `link_stale` carries a command. NEVER does any of it pull a lever or raise a bridge: this file runs it beside walkers on and
-- around the footprints (the world of test_bug543_raise_traffic): re-issued links pull and raise nothing, the siege defense (BREACH) still
-- raises every bridge when the footprints are clear, and no link job is touched in a siege.
local T = require('testlib')
local S = require('siege_world')
local kmock = require('dfllm.util.k_mock')
local Z = S.Z
local kv = kmock.vec

local FPY = {O1 = 10, B1 = 40, B2 = 60}          -- the footprints are x 50..52 at these rows

local function built(b)
  b.getBuildStage = function() return 1 end
  b.getMaxBuildStage = function() return 1 end
end

local function route(x, y0, y1)
  local r, step = {}, y1 >= y0 and 1 or -1
  for y = y0, y1, step do r[#r + 1] = {x, y} end
  return r
end

-- the world of test_bug543_raise_traffic with: every building built, lever 22 (B1) unlinked with a link job from the start, the acts
-- link_lever / cancel_link_job of the real act.lua (a link job without a worker is removed, one with a worker stays), an economy fake
-- that counts mechanic_labor, gate.LINK_REISSUE / LINK_MECH shortened (o.reissue, o.mech)
local function build(o)
  local units = S.fort_units()
  local walkers = {}
  for _, w in ipairs(o.walkers or {}) do
    local x, y = w.route[1][1], w.route[1][2]
    units[#units + 1] = S.cit(w.id, x, y, Z, w.kind == 'soldier' and {squad = 1} or nil)
    walkers[#walkers + 1] = {id = w.id, route = w.route, start = w.start or 0, i = 1, kind = w.kind, nopath = w.nopath, react = w.react}
  end
  for _, u in ipairs(o.army or {}) do units[#units + 1] = u end
  local W = S.world{units = units, mode = o.mode, move = o.move or 100, lever_default = {worker = 30, pull = 40}}
  df.job_type.LinkBuildingToTrigger = 146
  W.mil = S.military()
  W.eco = {name = 'economy', every = {ticks = 1200}, calls = 0}
  function W.eco.mechanic_labor(K) W.eco.calls = W.eco.calls + 1; return 'have', 3 end
  S.load(W, {W.mil, W.eco})
  local gate = package.loaded['dfllm.gate']
  gate.LINK_REISSUE, gate.LINK_MECH = o.reissue or 1500, o.mech or 300
  W.walkers, W.crushed, W.t0, W.links, W.cancels = walkers, {}, nil, {}, {}
  for _, b in pairs(W.bridges) do built(b) end
  for _, lv in ipairs(W.levers) do built(lv) end
  local lv22 = W.buildings[22]
  lv22.linked_mechanisms = kv{}
  lv22.jobs:insert('#', {id = 7001, job_type = df.job_type.LinkBuildingToTrigger, _worker = o.worker and {id = 3} or nil})
  W.act_result('link_lever', function(lid, bid)
    local lv = W.buildings[lid]
    W.links[#W.links + 1] = {lid = lid, bid = bid, tick = W.K.now().tick}
    lv.jobs:insert('#', {id = 7100 + #W.links, job_type = df.job_type.LinkBuildingToTrigger})
    return true, 7100 + #W.links
  end)
  W.act_result('cancel_link_job', function(lid)
    local lv, n = W.buildings[lid], 0
    for i = #lv.jobs - 1, 0, -1 do
      local j = lv.jobs[i]
      if j.job_type == df.job_type.LinkBuildingToTrigger and j._worker == nil then lv.jobs:erase(i); n = n + 1 end
    end
    W.cancels[#W.cancels + 1] = {lid = lid, n = n, tick = W.K.now().tick}
    return true, n
  end)
  return W
end

local function on_fp(name, x, y) return y == FPY[name] and x >= 50 and x <= 52 end

local function path_of(w)
  if w.nopath then return nil end
  local xs, ys, zs = {}, {}, {}
  for k = w.i + 1, math.min(#w.route, w.i + 25) do
    xs[#xs + 1], ys[#ys + 1], zs[#zs + 1] = w.route[k][1], w.route[k][2], Z
  end
  if #xs == 0 then return nil end
  return {path = {x = kmock.vec(xs), y = kmock.vec(ys), z = kmock.vec(zs)}}
end

local function step(W, t)
  W.t0 = W.t0 or t
  local rel = t - W.t0
  W.K.census.a = {tick = W.K.now().tick, n = 0, list = {}}
  for _, w in ipairs(W.walkers) do
    if not w.dead and rel >= w.start then
      local r = w.react
      if r and w.i < #w.route and S.bstate(W, r.bridge) == 'moving' then
        W.move(w.id, r.to[1], r.to[2], Z)                 -- the adversary: onto the footprint while the bridge moves
        w.i = #w.route
      elseif w.i < #w.route then
        local nx = w.route[w.i + 1]
        local blocked = false
        for name in pairs(FPY) do
          if on_fp(name, nx[1], nx[2]) and S.bstate(W, name) == 'up' then blocked = true end
        end
        if not blocked then
          w.i = w.i + 1
          W.move(w.id, w.route[w.i][1], w.route[w.i][2], Z)
        end
      end
    end
    if not w.dead then W.unit(w.id).path = (rel >= w.start) and path_of(w) or nil end
  end
  for _, w in ipairs(W.walkers) do
    if not w.dead then
      local u = W.unit(w.id)
      for name in pairs(FPY) do
        if S.bstate(W, name) == 'moving' and on_fp(name, u._m.x, u._m.y) then
          w.dead = true
          W.crushed[#W.crushed + 1] = {id = w.id, bridge = name, tick = rel, kind = w.kind}
        end
      end
    end
  end
end

local function run(W, ticks)
  local at = {}
  for t = 0, ticks, 9 do at[#at + 1] = {t, step} end
  S.run(W, ticks, {at = at})
end

-- a soldier pacing along y = 42 (2 tiles from B1's footprint row 40), n steps; he steps onto (51, 40) when B1 moves
local function pacer(id, n)
  local r = {}
  local xs = {48, 50, 49, 50, 48}
  for i = 1, n do r[#r + 1] = {xs[i % 5 + 1], 42} end
  return {id = id, kind = 'soldier', route = r, start = 0, nopath = true, react = {bridge = 'B1', to = {51, 40}}}
end

local function link_jobs(W, lid)
  local n = 0
  for _, j in ipairs(W.buildings[lid].jobs) do if j.job_type == df.job_type.LinkBuildingToTrigger then n = n + 1 end end
  return n
end
local function no_flips(W)
  for name in pairs(FPY) do T.eq(#S.flips(W, name), 0, name .. ' never moved') end
end

T.test('BUG-546: PEACE, an unworked link job of lever 22 is taken down after LINK_REISSUE and the lever is linked again; a soldier ' ..
       'paces beside B1 all the time: nothing is pulled, no bridge moves, nobody is crushed', function()
  local W = build{mode = 'PEACE', walkers = {pacer(800, 400)}}
  run(W, 1200)
  T.eq(#W.cancels, 0, 'not yet')
  T.eq(link_jobs(W, 22), 1)
  run(W, 1800)
  T.ok(#W.cancels >= 1, 'taken down')
  T.eq(W.cancels[1].lid, 22)
  T.eq(W.cancels[1].n, 1)
  T.ok(#W.links >= 1, 'linked again')
  T.eq({W.links[1].lid, W.links[1].bid}, {22, S.BRIDGE_ID.B1})
  T.ok(W.links[1].tick > W.cancels[1].tick, 'after the cancel')
  T.eq(link_jobs(W, 22), 1, 'one fresh job stands')
  local relink = {}
  for _, e in ipairs(W.find_events('LEVER')) do if e.msg:find('relink B1', 1, true) then relink[#relink + 1] = e end end
  T.ok(#relink >= 1, 'LEVER relink B1')
  T.eq(#S.pulls(W), 0, 'no PullLever job')
  no_flips(W)
  T.eq(#W.crushed, 0)
  T.ok(W.eco.calls >= 1, 'a Mechanic was asked for while the job waited')
end)

T.test('BUG-546: a link job with a worker is not taken down (a long job is a job)', function()
  local W = build{mode = 'PEACE', worker = true, reissue = 1500}
  run(W, 4000)
  T.eq(link_jobs(W, 22), 1)
  T.eq(#W.links, 0, 'no second job')
  for _, c in ipairs(W.cancels) do T.eq(c.n, 0, 'the act removed nothing') end
end)

T.test('BUG-546: SIEGE defense (BREACH): a stale link job is left alone, citizens and soldiers walk over O1, B1 and B2, nobody is on a ' ..
       'footprint when it moves, all three rise when clear', function()
  local ws = {}
  for k = 0, 3 do
    local down = k % 2 == 0
    ws[#ws + 1] = {id = 900 + k, kind = k % 2 == 0 and 'citizen' or 'soldier', route = down and route(51, 0, 70) or route(51, 70, 0),
                   start = 400 * k}
  end
  local W = build{mode = 'BREACH', walkers = ws, army = S.army(6, 50, 150), reissue = 600}
  run(W, 3600)
  T.eq(#W.crushed, 0, 'crushed: ' .. T.show(W.crushed))
  for _, b in ipairs({'O1', 'B1', 'B2'}) do T.eq(S.bstate(W, b), 'up', b .. ' up') end
  T.eq(#W.cancels, 0, 'no link job is touched in a siege')
  T.eq(#W.links, 0)
  T.eq(link_jobs(W, 22), 1, 'the stale job stands')
end)

T.test('BUG-546: after a re-issue (PEACE) a lever-up of B1 with a soldier pacing beside it: not pulled while he paces, raised once he ' ..
       'stands, nobody crushed; the fresh link job is not in the way', function()
  local W = build{mode = 'PEACE', walkers = {pacer(810, 300)}, reissue = 600}
  run(W, 1500)
  T.ok(#W.cancels >= 1 and #W.links >= 1, 'the link was re-issued first')
  T.eq(select(2, W.K.call('gate', 'want', 'B1', 'up', 'lever:test')), true)
  run(W, 2400)
  T.eq(#W.crushed, 0, 'crushed: ' .. T.show(W.crushed))
  local up = {}
  for _, f in ipairs(S.flips(W, 'B1')) do if f.to == 'up' then up[#up + 1] = f.tick - W.t_start end end
  T.eq(#up, 1, 'B1 rose once')
  T.ok(up[1] >= 300 * 9, 'not while he paced: +' .. tostring(up[1]))
  T.eq(S.bstate(W, 'B1'), 'up')
  T.eq(#S.pulls(W, 'O1') + #S.pulls(W, 'B2'), 0, 'no other bridge was pulled')
end)

T.done()
