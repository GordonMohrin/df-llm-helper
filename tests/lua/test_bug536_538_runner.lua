-- BUG-536 (Run 16d i4 Trumpetrealms: the depot y389s0b2 'build_lost at build, missing D', 16 retries, never a reason): the message names
-- the trade depot and why the 5x5 was not placed (footprint tiles that are no open floor, no material). BUG-538 (the seal hatch on the
-- stair 94,94,140 'walled in on its level': stalled and stale 300+ days under a seal_stalled decision): a seal whose every open piece
-- is boxed is cancelled by the kernel after seal_boxed_days, with the reason.
local T = require('testlib')
local H = require('runner_world')
local runner = require('dfllm.runner')

local CFG0 = {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end

local function depot_doc(x, y, z)
  return {v = 2, tpl = 'depot', site = 'S1', class = 'infra', params = {}, anchor = {x, y, z}, rot = 0,
          stages = {{label = 'build', mode = 'build', orders = 0, defense = 0,
                     chunks = {{pos = {x, y, z}, cells = {{0, 0, 0, 'D(5x5)'}}}}}},
          manifest = {v = 2, depot = {x + 2, y + 2, z}}, materials = {trade_depot = 1}}
end

local function world(tag, mat)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  local W = H.world{tag = tag, map_size = {16, 16, 160}}
  dfhack.buildings = dfhack.buildings or {}
  dfhack.buildings.findAtTile = function(x, y, z)
    local id = W.bld_at[x .. ',' .. y .. ',' .. z]
    return id and W.buildings[id] or nil
  end
  W.load({name = 'economy', every = {ticks = 1200}, mat_for = function() if mat then return nil, mat end return 'rock' end,
          state = function() return {stock = {food_d = 200, drink_d = 300, rock = 50, rock_need = 10}} end})
  W.load(runner)
  W.state()
  return W
end

T.test('BUG-536: the depot footprint is read: a wall and a tree in the 5x5 are named with their tiles; the material is named', function()
  local W = world('b536a', 'no rock, no logs')
  H.floor(W, 20, 20, 50, 24, 24)
  W.tile(22, 22, 50).c = '#'
  W.tile(23, 21, 50).c = 'T'
  local d = depot_doc(20, 20, 50)
  H.place(W, 'dp', d)
  local P = H.proj(W, 'dp')
  local why = runner.lost_why(W.K, P, d)
  T.ok(why:find('2 of 25 footprint tiles are no open floor (23,21,50 tree, 22,22,50 wall)', 1, true), why)
  T.ok(why:find('no building material: no rock, no logs', 1, true), why)
end)

T.test('BUG-536: a clear footprint and a material that exists say so; hidden tiles alone say nothing (the retry text does)', function()
  local W = world('b536b')
  H.floor(W, 20, 20, 50, 24, 24)
  local d = depot_doc(20, 20, 50)
  H.place(W, 'dp', d)
  local P = H.proj(W, 'dp')
  local why = runner.lost_why(W.K, P, d)
  T.ok(why:find('the 5x5 footprint at 20,20,50 looks clear and material exists', 1, true), why)
  for y = 20, 24 do for x = 20, 24 do W.tile(x, y, 50).hidden = true end end
  T.eq(runner.lost_why(W.K, P, d), nil)
end)

T.test('BUG-536: PROJECT_BLOCKED for a lost depot names the trade depot and the cause (old: "missing D")', function()
  local W = world('b536c')
  H.floor(W, 20, 20, 50, 24, 24)
  W.tile(22, 22, 50).c = '#'
  for y = 20, 24 do for x = 20, 24 do W.unsuitable[x .. ',' .. y .. ',50'] = true end end
  H.place(W, 'dp', depot_doc(20, 20, 50))
  H.runs(W, 12)
  local P = H.proj(W, 'dp')
  if P.blocked ~= 'build_lost' then
    T.ok(false, 'the fake quickfort did not lose the depot: ' .. tostring(P.blocked) .. ' ' .. P.stage)
  end
  H.runs(W, 4)
  local pb = W.find_events('PROJECT_BLOCKED')
  T.ok(#pb >= 1, 'a PROJECT_BLOCKED')
  T.eq(pb[1].d.missing, {'trade depot'})
  T.ok(pb[1].msg:find('missing trade depot', 1, true) and pb[1].msg:find('1 of 25 footprint tiles are no open floor', 1, true),
       pb[1].msg)
  T.ok(pb[1].d.parts:find('22,22,50 wall', 1, true), pb[1].d.parts)
end)

local SX, SY, Z = 94, 94, 140
local function seal_doc()
  return {v = 2, tpl = 'seal', site = 'S1', class = 'defense', params = {at = SX .. ',' .. SY .. ',' .. Z .. ' stair_updown'},
          anchor = {SX, SY, Z}, rot = 0,
          stages = {{label = 'seal.build', mode = 'build', orders = 1, defense = 1,
                     chunks = {{pos = {SX, SY, Z}, cells = {{0, 0, 0, 'H'}}}}}},
          manifest = {v = 2}, materials = {hatch = 1}}
end

local function boxed_world(tag, bs)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  local W = H.world{tag = tag, map_size = {16, 16, 160},
                    cfg = {baseline = {v = 2, runner = {seal_first = {esc_days = 5}, queue = {idle_days = 50}}}}}
  dfhack.buildings = dfhack.buildings or {}
  dfhack.buildings.findAtTile = function(x, y, z)
    local id = W.bld_at[x .. ',' .. y .. ',' .. z]
    return id and W.buildings[id] or nil
  end
  H.floor(W, SX, SY, Z, SX, SY)
  W.load({name = 'economy', every = {ticks = 1200}, mat_for = function() return 'rock' end, build_state = function() return bs end,
          state = function() return {stock = {food_d = 200, drink_d = 300, rock = 50, rock_need = 10}} end})
  W.load(runner)
  W.state()
  runner.CFG.seal_boxed_days = 3
  return W
end

local function row(W, id)
  for _, r in ipairs(W.state().proj) do if r[1] == id then return r end end
end

T.test('BUG-538: a seal whose only open piece is a boxed hatch is cancelled by the kernel after seal_boxed_days, with the reason',
       function()
  local W = boxed_world('b538a', {job = 77, boxed = true, line = 'walled in on its level (no tile beside it to build from)'})
  H.place(W, 'sl', seal_doc())
  local runs = 0
  while row(W, 'sl') and runs < 80 do H.runs(W, 1); runs = runs + 1 end
  local pb
  for _, e in ipairs(W.find_events('PROJECT_BLOCKED')) do if e.d.why == 'boxed_cancel' then pb = e end end
  T.ok(pb, 'PROJECT_BLOCKED boxed_cancel after ' .. runs .. ' runs')
  T.ok(pb.msg:find('cancelled by the kernel: hatch 94,94,140 walled in on its level', 1, true), pb.msg)
  T.eq(pb.d.proj, 'sl')
  T.eq(row(W, 'sl'), nil, 'the project is gone')
end)

T.test('BUG-538: a hatch that is not boxed (a builder could take it) is never cancelled', function()
  local W = boxed_world('b538b', {job = 77})
  H.place(W, 'sl', seal_doc())
  H.runs(W, 60)
  for _, e in ipairs(W.find_events('PROJECT_BLOCKED')) do T.ok(e.d.why ~= 'boxed_cancel', e.msg) end
  T.ok(row(W, 'sl') ~= nil)
end)

T.done()
