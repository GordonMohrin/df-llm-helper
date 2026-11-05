-- BUG-462 (Run 16a i1 Syrupobeyed y387, Pop 96 -> 1): trolls (Miner, Siege Engineer) broke the outer bridge O1 (d29) and B2
-- (d39) although both stood UP: a raised bridge is no barrier to building destroyers. The defense reacts to the destroyers in
-- sight at once (SIEGE_DEEP: civilians to the refuge, squads at the core) and a destroyed outer or inner bridge tells seal
-- (seal.lost: the refuge is the retreat of the episode) in the same pass. The traffic test: citizens returning over B1, an
-- army with two trolls (BUILDINGDESTROYER) walking down the gate lane, O1 destroyed as the first troll passes it. It touches
-- no bridge or gate logic, so it asserts what the BUG-380 tests assert as well: nobody on a footprint while it moves, nobody
-- shut out, B1 up before the invaders reach it, and no GATE_FAIL, plus the destroyers' consequences.
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

T.test('BUG-462 traffic: SIEGE, two trolls and four goblins walk down the gate lane while citizens return over B1, O1 is ' ..
       'destroyed as the first troll passes it -> SIEGE_DEEP before, seal.lost once right after, BREACH destroyed, B1 up before ' ..
       'the army reaches it, nobody crushed or shut out', function()
  FPY.O1, FPY.B1, FPY.B2 = 10, 40, 60
  local W = build{walkers = route_walkers()}
  troll_raws()
  local calls = {}
  W.load(fake_seal(calls))
  local army = {}
  for i = 1, 6 do
    local troll = i <= 2
    local u = W.add_unit(S.inv(500 + i, 50 + i % 3, -90 - (i // 3), Z, troll and {race = 'TROLL'} or nil))
    if troll then u.race, u.caste = TROLL, i % 2 end
    army[#army + 1] = {id = u.id or (500 + i), x = 50 + i % 3, y0 = -90 - (i // 3), y1 = 38, start = 0}
  end
  W.foes = army
  local tdestroy
  local at = {{930, function(W2, now) destroy(W2, 'O1'); tdestroy = now - W2.t_start end}}
  for t = 0, 1500, 9 do at[#at + 1] = {t, step} end
  S.run(W, 1500, {at = at})
  T.eq(#W.crushed, 0, 'crushed: ' .. names(W.crushed))
  for _, w in ipairs(W.walkers) do T.eq(w.i, #w.route, 'walker ' .. w.id .. ' got through (not shut out)') end
  -- the defense saw the destroyers before O1 fell
  local deep = W.find_events('SIEGE_DEEP')
  T.ok(#deep >= 1 and (deep[1].tick - W.t_start) < 930, 'SIEGE_DEEP before the loss: ' .. (deep[1] and (deep[1].tick - W.t_start) or 'none'))
  T.ok((deep[1].d.bd or 0) >= 2, 'two building destroyers named')
  -- the loss
  T.eq(#W.find_events('BRIDGE_DESTROYED'), 1)
  local br = W.find_events('BREACH')
  T.eq(#br, 1)
  T.eq(br[1].d.why, 'destroyed')
  T.eq(#calls, 1, 'seal.lost asked once: ' .. T.show(calls))
  T.eq(calls[1].name, 'O1')
  T.ok(calls[1].tick - W.t_start - tdestroy <= 400, 'seal.lost within 400 ticks of the loss: ' .. (calls[1].tick - W.t_start - tdestroy))
  -- B1 up before the army (at y 38 after 1152 ticks) is there, and it stays up
  local up = flips_to(W, 'B1', 'up')
  T.eq(#up, 1, 'B1 rose once')
  T.ok(up[1] + W.move_ticks <= 1150, 'B1 up before the army reaches it: ' .. (up[1] + W.move_ticks))
  T.eq(S.bstate(W, 'B1'), 'up')
  T.eq(#W.find_events('GATE_FAIL'), 0)
end)

T.done()
