-- BUG-569 / BUG-570 siege traffic tests (Run 16b i2 Brotherarrow y406: a goblin siege of 36-37 lasted 115+ days; SIEGE_DEEP 'army 37 >
-- 3 x 12 soldiers; worn 40 % < 60 %' held 95 citizens in a Tiefe+ with food 1 and 23 beds while Kern+ held 4987 food; ~26 dead of hunger
-- and thirst, the Eat jobs stood at the stair head for 10+ days, the lockdown_long limit passed with a hopeless sortie on offer).
-- The world of test_bug478_481_siege_traffic.lua (real sense / threat / siege / gate, citizens and soldiers walking over the bridges, a
-- raised bridge cannot be walked, a unit ON a moving bridge is crushed) with a seal stand-in that answers the way seal does: the burrow
-- the deep defense asks for (BREACH ask) is the refuge, a `cur` refuge is kept (fight_rule KEEP) unless siege passes a release reason,
-- refuge_fit is what the test says. Defense is not weakened: whatever the burrow does, the bridges close and nobody is crushed or shut out.
--   (1) BUG-569: the deep defense by 'army' (no building destroyers) and a refuge that cannot feed them: the civilians STAY in Kern+, the
--       squads hold the core station, SIEGE_DEEP says so; once the refuge is stocked (fit) they go down;
--   (2) BUG-570: the announced engineers keep the civilians in Tiefe+ (the line breaks in minutes); 4 citizens over 50,000 of hunger with
--       the army 100 tiles off: relief at once (alert Kern+, release reason, DECISION_NEEDED starve_lockdown relief 1), a goblin 20 tiles
--       from O1: relief ends (alert back to Tiefe+, the decision says why not and offers nothing but the sortie), far again: relief again,
--       nobody hungry for a game day: over, back to the deep defense. Bridges up the whole time, nobody crushed or shut out;
--   (3) a hostile near from the start: no relief, ever, however hungry they are (the decision names the hostile).
local T = require('testlib')
local S = require('siege_world')
local kmock = require('dfllm.util.k_mock')
local Z = S.Z

local FPY = {O1 = 10, B1 = 40, B2 = 60}          -- the footprints are x 50..52 at these rows

local function route(x, y0, y1)
  local r, step = {}, y1 >= y0 and 1 or -1
  for y = y0, y1, step do r[#r + 1] = {x, y} end
  return r
end

local function build(o)
  local units = S.fort_units()
  local walkers = {}
  for _, w in ipairs(o.walkers or {}) do
    local x, y = w.route[1][1], w.route[1][2]
    local u = S.cit(w.id, x, y, Z, w.kind == 'soldier' and {squad = 1} or nil)
    units[#units + 1] = u
    walkers[#walkers + 1] = {id = w.id, route = w.route, start = w.start or 0, i = 1, kind = w.kind}
  end
  for _, u in ipairs(o.army or {}) do units[#units + 1] = u end
  local W = S.world{units = units, mode = o.mode, move = o.move or 100, lever_default = {worker = 30, pull = 40}}
  W.mil = S.military()
  S.load(W, {W.mil})
  W.walkers, W.crushed, W.t0 = walkers, {}, nil
  W.foes = o.foes or {}
  return W
end

local function on_fp(name, x, y) return y == FPY[name] and x >= 50 and x <= 52 end

local function path_of(w)
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
  for _, w in ipairs(W.walkers) do
    if not w.dead and rel >= w.start and w.i < #w.route then
      local nx = w.route[w.i + 1]
      local blocked = false
      for name in pairs(FPY) do
        if on_fp(name, nx[1], nx[2]) and S.bstate(W, name) == 'up' then blocked = true end   -- a raised bridge: no way
      end
      if not blocked then
        w.i = w.i + 1
        W.move(w.id, w.route[w.i][1], w.route[w.i][2], Z)
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
          W.crushed[#W.crushed + 1] = {id = w.id, bridge = name, tick = rel}
        end
      end
    end
  end
end

local function names(list)
  local r = {}
  for _, c in ipairs(list) do r[#r + 1] = string.format('%d on %s at +%d', c.id, c.bridge, c.tick) end
  return table.concat(r, '; ')
end

local function flips_to(W, b, to)
  local r = {}
  for _, f in ipairs(S.flips(W, b)) do if f.to == to then r[#r + 1] = f.tick - W.t_start end end
  return r
end

-- seal's stand-in. refuge_fit: W.fit = {ok, why}; alert_burrow: the BREACH ask (the deep defense) = the refuge, a `cur` refuge is kept
-- unless siege passes a release reason, anything else Kern+ (the real choice and fight_rule are tested in test_bug569_572_seal.lua)
local function fake_seal(W)
  local M = {name = 'seal', every = {ticks = 3600}}
  W.sealq = {}
  W.fit = {ok = true, why = ''}
  function M.refuge_fit(K) return W.fit.ok, W.fit.why end
  function M.alert_burrow(K, mode, default, hold, cur, release)
    W.sealq[#W.sealq + 1] = {mode = mode, default = default, cur = cur, release = release, tick = K.now().tick}
    if mode == 'BREACH' then return 'Tiefe+', nil, nil, false end
    if cur == 'Tiefe+' and not release then return 'Tiefe+', nil, nil, false end
    return 'Kern+', nil, nil, false
  end
  function M.plug(K, args) return 'wait:test' end
  return M
end

local function hunger(W, ids, v)
  for _, id in ipairs(ids) do W.unit(id).counters2 = {hunger_timer = v, thirst_timer = 1000} end
end

local function alerts(W)
  local r = {}
  for _, a in ipairs(S.acts(W, 'alert_burrows')) do r[#r + 1] = a.args[1][1] end
  return r
end
local function last_alert(W) local r = alerts(W); return r[#r] end

local function decisions(W)
  local r = {}
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == 'starve_lockdown' then r[#r + 1] = e end end
  return r
end

local function releases(W)
  local r = {}
  for _, q in ipairs(W.sealq) do if q.release then r[#r + 1] = q.release end end
  return r
end

-- citizens and soldiers returning over the bridges early in the siege (before the raise)
local function stream()
  local ws = {}
  for i = 1, 4 do ws[#ws + 1] = {id = 300 + i, kind = 'soldier', route = route(51, 30, 44), start = (i - 1) * 18} end
  for k = 0, 2 do
    local north = k % 2 == 0
    ws[#ws + 1] = {id = 320 + k, kind = 'citizen', route = north and route(50, 61, 28) or route(52, 19, 62), start = 60 + 120 * k}
  end
  return ws
end

local function run(W, ticks, extra)
  local at = {}
  for t = 0, ticks, 9 do at[#at + 1] = {t, step} end
  for _, a in ipairs(extra or {}) do at[#at + 1] = a end
  S.run(W, ticks, {at = at})
end

local CIT = {1, 2, 3, 4}

local function army(n, x, y)
  local list = {}
  for i = 1, n do list[#list + 1] = S.inv(500 + i, x + i % 3, y - i // 3, Z) end
  return list
end

---------------------------------------------------------------- (1) BUG-569
T.test('BUG-569 (Brotherarrow y406): the deep defense by army (30 > 3 x 8), the refuge cannot feed the civilians (food 1<86): they STAY in ' ..
       'Kern+, SIEGE_DEEP says so, the squads hold the core station, the bridges rise; once the refuge is stocked they go down', function()
  local W = build{walkers = stream(), mode = 'SIEGE', army = army(30, 50, -90)}
  W.load(fake_seal(W))
  W.fit = {ok = false, why = 'food 1<86, beds 18<22'}
  run(W, 1800)
  local deep = W.find_events('SIEGE_DEEP')
  T.ok(#deep >= 1, 'SIEGE_DEEP')
  local has = {}
  for _, w in ipairs(deep[1].d.why) do has[w] = true end
  T.ok(has.army and not has.destroyers, 'by army: ' .. T.show(deep[1].d.why))
  T.ok(deep[1].msg:find('the civilians STAY in Kern+', 1, true), deep[1].msg)
  T.ok(deep[1].msg:find('food 1<86', 1, true), deep[1].msg)
  T.ok(deep[1].d.unfit and deep[1].d.unfit:find('food 1<86', 1, true), 'the event carries the shortfall')
  for _, b in ipairs(alerts(W)) do T.eq(b, 'Kern+', 'old code: the first alert goes to Tiefe+ (SIEGE_DEEP army)') end
  T.ok(#alerts(W) >= 1, 'the alert sounds on Kern+')
  local P = W.mil.postures[#W.mil.postures]
  T.eq(P and P.P, 'CORE', 'every squad still holds the core station')
  T.eq(W.state().wave.deep, 'army')
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W.crushed))
  for _, w in ipairs(W.walkers) do T.eq(w.i, #w.route, 'walker ' .. w.id .. ' got through (not shut out)') end
  for _, b in ipairs({'O1', 'B1'}) do T.eq(S.bstate(W, b), 'up', b .. ' up') end
  T.eq(S.bstate(W, 'B2'), 'down')
  T.eq(#W.find_events('GATE_FAIL'), 0)
  -- the refuge is stocked: the civilians go down (the move walks away from the entrances)
  W.fit = {ok = true, why = ''}
  run(W, 600)
  T.eq(last_alert(W), 'Tiefe+', 'fit refuge: the deep defense sends them down')
  T.eq(#W.crushed, 0)
end)

---------------------------------------------------------------- (2) BUG-570
T.test('BUG-570 (Brotherarrow y406): announced engineers keep the civilians in Tiefe+ (food 1); 4 citizens over 50,000 of hunger with the ' ..
       'army 100 tiles off: relief (Kern+, starve_lockdown), a goblin 20 tiles from O1 ends it (Tiefe+ again), far again: relief again, ' ..
       'fed for a game day: over; the bridges stay up and nobody is crushed or shut out', function()
  local W = build{walkers = stream(), mode = 'SIEGE', army = army(6, 50, -90)}
  W.load(fake_seal(W))
  W.fit = {ok = false, why = 'food 1<86'}
  local ok, new = W.K.call('siege', 'expect_destroyers', 'monstrous siege engineers!')
  T.ok(ok and new == true, 'expect_destroyers')
  local goblin = 501
  -- 1200: before the hunger the civilians are in the refuge
  run(W, 1150)
  T.eq(last_alert(W), 'Tiefe+', 'announced engineers: the refuge, however empty (the line breaks in minutes)')
  T.eq(W.state().wave.sv, nil, 'no emergency yet')
  hunger(W, CIT, 90000)                                                          -- the hunger of the lockdown
  run(W, 600)                                                                    -- the hunger is read
  T.eq(last_alert(W), 'Kern+', 'old code: nothing leaves the refuge (the Eat jobs stood at the stair head 10 days)')
  local d = decisions(W)
  T.eq(#d, 1, 'DECISION_NEEDED starve_lockdown once')
  T.eq({d[1].cls, d[1].d.relief, d[1].d.n, d[1].d.to}, {'A', 1, 4, 'Kern+'})
  T.ok(d[1].msg:find('the civilians go to Kern+', 1, true), d[1].msg)
  T.eq(W.state().wave.sv, 1, 'status: relief on')
  local rel = releases(W)
  T.ok(#rel >= 1 and rel[#rel]:find('starvation relief', 1, true), 'seal is told why: ' .. T.show(rel))
  local oks, sv = W.K.call('siege', 'starve_state')
  T.eq({oks, sv.relief, sv.n}, {true, true, 4})
  for _, b in ipairs({'O1', 'B1'}) do T.eq(S.bstate(W, b), 'up', b .. ' stays up in the relief') end
  -- a goblin comes within 25 tiles of O1: the relief ends at once, the fort closes again (the refuge of the deep defense)
  W.move(goblin, 51, -10, Z)                                                     -- 20 tiles from O1, 50 from B1
  run(W, 1200)
  T.eq(last_alert(W), 'Tiefe+', 'a hostile 20 tiles from O1: back in the refuge (the deep defense)')
  d = decisions(W)
  T.eq(#d, 2, 'the change is news')
  T.eq({d[2].d.relief, d[2].d.near}, {0, 20})
  T.ok(d[2].msg:find('NOT widened to Kern+', 1, true) and d[2].msg:find('a hostile 20 tiles from the fort', 1, true), d[2].msg)
  T.eq(W.state().wave.sv, 2, 'status: emergency, no relief')
  local logged = false
  for _, l in ipairs(W.logs) do if tostring(l.msg):find('starvation relief OFF', 1, true) then logged = true end end
  T.ok(logged, 'kern.log names it')
  -- far again: relief again
  W.move(goblin, 51, -90, Z)
  run(W, 900)
  T.eq(last_alert(W), 'Kern+', 'far again: Kern+ again')
  T.eq(#decisions(W), 3)
  -- they ate: a game day without anybody over the mark ends the emergency
  hunger(W, CIT, 1000)
  run(W, 2200)
  T.eq(W.state().wave.sv, nil, 'over')
  T.eq(last_alert(W), 'Tiefe+', 'back to the deep defense')
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W.crushed))
  for _, w in ipairs(W.walkers) do T.eq(w.i, #w.route, 'walker ' .. w.id .. ' got through (not shut out)') end
  for _, b in ipairs({'O1', 'B1'}) do
    T.eq(S.bstate(W, b), 'up', b .. ' up')
    T.eq(#flips_to(W, b, 'down'), 0, b .. ' never lowered in the whole emergency')
  end
  T.eq(W.pending_violations, 0, 'one pull at a time')
  T.eq(#W.find_events('GATE_FAIL'), 0)
end)

---------------------------------------------------------------- (3) no relief with a hostile near
T.test('BUG-570: a goblin 20 tiles from O1 from the start: hungry citizens get no relief (Tiefe+ stays, the decision names the hostile and ' ..
       'the missing squad); the same hunger with one inside Kern+ neither', function()
  local W = build{walkers = stream(), mode = 'SIEGE', army = army(6, 50, -90)}
  W.load(fake_seal(W))
  W.fit = {ok = false, why = 'food 1<86'}
  W.K.call('siege', 'expect_destroyers', 'siege engineers!')
  W.move(501, 51, -10, Z)
  run(W, 300)
  hunger(W, CIT, 90000)
  run(W, 900)
  T.eq(last_alert(W), 'Tiefe+', 'no relief: a hostile within 25 tiles of O1')
  local d = decisions(W)
  T.eq(#d, 1)
  T.eq({d[1].d.relief, d[1].d.near, d[1].d.inside}, {0, 20, 0})
  T.ok(d[1].msg:find('NOT widened', 1, true), d[1].msg)
  T.eq(W.state().wave.sv, 2)
  T.eq(#releases(W), 0, 'seal is never told to release the refuge')
  T.eq(#W.crushed, 0)
end)

T.test('BUG-570: siege_starve.on false is the old rule; two hungry citizens (min 3) are no emergency', function()
  local W = build{walkers = {}, mode = 'SIEGE', army = army(6, 50, -90)}
  W.load(fake_seal(W))
  W.K.call('siege', 'expect_destroyers', 'siege engineers!')
  hunger(W, {1, 2}, 90000)
  run(W, 900)
  T.eq(last_alert(W), 'Tiefe+')
  T.eq(#decisions(W), 0, 'two are below siege_starve.min')
  T.eq(W.state().wave.sv, nil)
  local W2 = build{walkers = {}, mode = 'SIEGE', army = army(6, 50, -90)}
  W2.K.cfg.reflex = {v = 2, siege_starve = {on = false}}
  W2.load(fake_seal(W2))
  W2.K.call('siege', 'expect_destroyers', 'siege engineers!')
  hunger(W2, CIT, 90000)
  run(W2, 900)
  T.eq(last_alert(W2), 'Tiefe+', 'off: the refuge holds')
  T.eq(#decisions(W2), 0)
end)

T.done()
