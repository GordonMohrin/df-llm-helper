-- BUG-480 / BUG-479 siege traffic tests (Run 16c i3 Castletongs y403: the siege popup said 'monstrous siege engineers', the alert
-- sounded on Kern+, the census saw the five trolls 9 ticks later and moved it to Tiefe+: 83 citizens crossed the gates' footprints a
-- second time, O1 was not up at T+900, the refuge hatch was broken). The scripted siege: citizens and soldiers returning over B1
-- (and across the lane O1..B2), an army walking down the gate lane with trolls (BUILDINGDESTROYER) that show up later.
--   * the announced engineers send the FIRST alert to Tiefe+ (SIEGE_DEEP why `announced`, before any troll is in sight);
--     without the announcement the first alert is Kern+ (the old behaviour);
--   * once a troll is in sight the deep defense asks seal for the refuge plug (BUG-479) every pass;
--   * nobody is crushed, nobody is shut out, B1 is up before the army reaches it, no GATE_FAIL.
local T = require('testlib')
local S = require('siege_world')
local kmock = require('dfllm.util.k_mock')
local Z = S.Z

local FPY = {O1 = 10, B1 = 40, B2 = 60}          -- the footprints are x 50..52 at these rows (O1 leaves it when destroyed)

local function route(x, y0, y1)
  local r, step = {}, y1 >= y0 and 1 or -1
  for y = y0, y1, step do r[#r + 1] = {x, y} end
  return r
end

-- units: {id, kind = 'soldier'|'citizen', route, start (ticks)}; the stepper moves them one tile per frame
local function build(o)
  local units = S.fort_units()
  local walkers = {}
  for _, w in ipairs(o.walkers or {}) do
    local x, y = w.route[1][1], w.route[1][2]
    local u = S.cit(w.id, x, y, Z, w.kind == 'soldier' and {squad = 1} or nil)
    units[#units + 1] = u
    walkers[#walkers + 1] = {id = w.id, route = w.route, start = w.start or 0, i = 1, kind = w.kind, ghost = w.ghost}
  end
  for _, u in ipairs(o.army or {}) do units[#units + 1] = u end
  local W = S.world{units = units, mode = o.mode, move = o.move or 100, lever_default = {worker = 30, pull = 40}}
  W.mil = S.military()
  S.load(W, {W.mil})
  W.walkers, W.crushed, W.t0 = walkers, {}, nil
  W.foes = o.foes or {}
  return W
end

local function on_fp(name, x, y)
  return y == FPY[name] and x >= 50 and x <= 52
end

local function path_of(w)
  local xs, ys, zs = {}, {}, {}
  for k = w.i + 1, math.min(#w.route, w.i + 25) do
    xs[#xs + 1], ys[#ys + 1], zs[#zs + 1] = w.route[k][1], w.route[k][2], Z
  end
  for _, g in ipairs(w.ghost or {}) do xs[#xs + 1], ys[#ys + 1], zs[#zs + 1] = g[1], g[2], Z end
  if #xs == 0 then return nil end
  return {path = {x = kmock.vec(xs), y = kmock.vec(ys), z = kmock.vec(zs)}}
end

-- one frame of the walkers and the invaders, then the crush rule
local function step(W, t)
  W.t0 = W.t0 or t
  local rel = t - W.t0
  for _, w in ipairs(W.walkers) do
    if not w.dead and rel >= w.start and w.i < #w.route then
      local nx = w.route[w.i + 1]
      local blocked = false
      for name, row in pairs(FPY) do
        if on_fp(name, nx[1], nx[2]) and S.bstate(W, name) == 'up' then blocked = true end   -- a raised bridge: no way
      end
      if not blocked then
        w.i = w.i + 1
        W.move(w.id, w.route[w.i][1], w.route[w.i][2], Z)
      end
    end
    if not w.dead then W.unit(w.id).path = (rel >= w.start) and path_of(w) or nil end
  end
  for _, f in ipairs(W.foes) do
    if rel >= f.start and f.y0 ~= f.y1 then
      local k = math.min(math.floor((rel - f.start) / 9), math.abs(f.y1 - f.y0))
      local y = f.y0 + (f.y1 > f.y0 and k or -k)
      W.move(f.id, f.x, y, Z)
    end
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

local function run(W, ticks)
  local at = {}
  for t = 0, ticks, 9 do at[#at + 1] = {t, step} end
  S.run(W, ticks, {at = at})
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


local TROLL = 77
local function troll_raws()
  local lvl, flag = {flags = {}, misc = {buildingdestroyer = 1}}, {flags = {BUILDINGDESTROYER = true}}
  df.creature_raw = {find = function(r) if r == TROLL then return {caste = {[0] = lvl, [1] = flag}} end end}
end

-- seal's stand-in: records seal.lost (the real one is tested in test_bug462_464_retreat.lua)
local function fake_seal(calls)
  local M = {name = 'seal', every = {ticks = 3600}}
  function M.lost(K, name)
    calls[#calls + 1] = {name = name, tick = K.now().tick}
    return #calls == 1
  end
  return M
end

local function destroy(W, name)
  local b = W.bridges[name]
  W.buildings[b.id] = nil
  local v = df.global.world.buildings.other.BRIDGE
  for i = #v - 1, 0, -1 do if v[i] == b then v:erase(i) end end
  W.bridges[name] = nil
  FPY[name] = nil
end

local function route_walkers()
  local ws = {}
  for i = 1, 6 do ws[#ws + 1] = {id = 300 + i, kind = 'soldier', route = route(51, 30, 44), start = (i - 1) * 18} end
  for k = 0, 3 do
    local north = k % 2 == 0
    ws[#ws + 1] = {id = 320 + k, kind = 'citizen', route = north and route(50, 61, 28) or route(52, 19, 62),
                   start = 100 + 170 * k - 21 * 9}
  end
  return ws
end


local function fake_seal(calls)
  local M = {name = 'seal', every = {ticks = 3600}}
  function M.lost(K, name) calls.lost[#calls.lost + 1] = name; return #calls.lost == 1 end
  function M.plug(K, args) calls.plug[#calls.plug + 1] = {tick = K.now().tick, bd = args and args.bd}; return 'wait:test' end
  return M
end

local function scenario(announce)
  FPY.O1, FPY.B1, FPY.B2 = 10, 40, 60
  local W = build{walkers = route_walkers(), mode = 'SIEGE'}
  troll_raws()
  local calls = {lost = {}, plug = {}}
  W.load(fake_seal(calls))
  if announce then
    local ok, new = W.K.call('siege', 'expect_destroyers', 'monstrous siege engineers!')
    T.ok(ok and new == true, 'expect_destroyers')
  end
  local army = {}
  for i = 1, 6 do
    local u = W.add_unit(S.inv(500 + i, 50 + i % 3, -90 - (i // 3), Z))
    army[#army + 1] = {id = u.id or (500 + i), x = 50 + i % 3, y0 = -90 - (i // 3), y1 = 38, start = 0}
  end
  W.foes = army
  local at = {{600, function(W2, now)                  -- two trolls come into sight, behind the goblins
    for i = 7, 8 do
      local u = W2.add_unit(S.inv(500 + i, 50 + i % 3, -60, Z, {race = 'TROLL'}))
      u.race, u.caste = TROLL, i % 2
      W2.foes[#W2.foes + 1] = {id = u.id or (500 + i), x = 50 + i % 3, y0 = -60, y1 = 38, start = now - W2.t0}
    end
  end}}
  for t = 0, 1500, 9 do at[#at + 1] = {t, step} end
  S.run(W, 1500, {at = at})
  return W, calls
end

local function first_alert(W)
  local a = S.acts(W, 'alert_burrows')
  return a[1] and a[1].args[1] or nil
end

T.test('BUG-480 traffic: the siege popup named siege engineers -> the first alert is Tiefe+ and SIEGE_DEEP says `announced` before ' ..
       'any troll is in sight; nobody crushed or shut out, B1 up before the army, no GATE_FAIL; the trolls then ask for the plug',
       function()
  local W, calls = scenario(true)
  local first = first_alert(W)
  T.ok(first and #first == 1 and first[1] == 'Tiefe+', 'the first alert burrow is the refuge: ' .. T.show(first))
  local deep = W.find_events('SIEGE_DEEP')
  T.ok(#deep >= 1, 'SIEGE_DEEP')
  local has = {}
  for _, w in ipairs(deep[1].d.why) do has[w] = true end
  T.ok(has.announced and not has.destroyers, 'first reason: announced only: ' .. T.show(deep[1].d.why))
  T.ok(deep[1].tick - W.t_start < 100, 'at once: ' .. (deep[1].tick - W.t_start))
  T.ok(deep[1].msg:find('popup announced siege engineers', 1, true), deep[1].msg)
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W.crushed))
  for _, w in ipairs(W.walkers) do T.eq(w.i, #w.route, 'walker ' .. w.id .. ' got through (not shut out)') end
  local up = flips_to(W, 'B1', 'up')
  T.eq(#up, 1, 'B1 rose once')
  T.ok(up[1] + W.move_ticks <= 1150, 'B1 up before the army reaches it: ' .. (up[1] + W.move_ticks))
  T.eq(S.bstate(W, 'B1'), 'up')
  T.eq(#W.find_events('GATE_FAIL'), 0)
  T.ok(#calls.plug >= 1 and calls.plug[1].bd == true, 'the deep defense asks seal for the plug: ' .. #calls.plug)
  -- the trolls came into sight at +600; the announced deep defense was latched before
  T.eq(S.acts(W, 'alert_burrows')[#S.acts(W, 'alert_burrows')].args[1][1], 'Tiefe+', 'the alert never went back to Kern+')
end)

T.test('BUG-480 control: the same siege WITHOUT the announcement sounds the first alert on Kern+ (the old order: Kern+, then the ' ..
       'deep defense once the trolls are seen)', function()
  local W, calls = scenario(false)
  local first = first_alert(W)
  T.ok(first and first[1] == 'Kern+', 'first alert burrow: ' .. T.show(first))
  local deep = W.find_events('SIEGE_DEEP')
  if #deep > 0 then
    local has = {}
    for _, w in ipairs(deep[1].d.why) do has[w] = true end
    T.ok(not has.announced, 'no announcement, no `announced`')
    T.ok(deep[1].tick - W.t_start >= 500, 'only when the trolls are in sight: ' .. (deep[1].tick - W.t_start))
  end
  T.eq(#W.crushed, 0)
end)

T.test('BUG-480: expect_destroyers is idempotent, expires after BDX_HOLD ticks without a siege', function()
  local W = build{walkers = {}, mode = 'PEACE'}
  local ok, a = W.K.call('siege', 'expect_destroyers', 'trolls')
  T.eq(a, true)
  ok, a = W.K.call('siege', 'expect_destroyers', 'trolls')
  T.eq(a, false, 'a second ask changes nothing')
  W.run(4000, {skip = 9})
  local p = W.K.persist.get('m.siege')
  T.eq(p.bdx, nil, 'expired: no siege followed')
end)

T.done()
