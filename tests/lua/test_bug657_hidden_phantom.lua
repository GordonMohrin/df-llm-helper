-- BUG-657 (Run 16c i3 Wallfree y400-y404, Run 16b i2 Valleyhame y378: the hatch 67,44,139 / 107,88,126 of a stair that was never dug lies on a
-- HIDDEN tile; BUG-638 only knew a revealed '#', so the seal went build_lost / SEAL_STUCK every year and no phantom event ever came). The
-- scan of a seal already build_lost or stuck counts a hidden tile with no building on it as a phantom too ('x,y,z ?'); bp.place does not
-- (a hidden tile says nothing yet), a hidden tile with a building planned on it is no phantom.
local T = require('testlib')
local H = require('runner_world')
local runner = require('dfllm.runner')

local SY, Z = 73, 143
local CFG0 = {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end

local function world(tag)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  local W = H.world{tag = tag, map_size = {16, 16, 160}}
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

local function seal_doc(x)
  return {v = 2, tpl = 'seal', site = 'S1', class = 'defense', params = {at = x .. ',' .. SY .. ',' .. Z .. ' stair_updown'},
          anchor = {x, SY, Z}, rot = 0,
          stages = {{label = 'seal.build', mode = 'build', orders = 1, defense = 1,
                     chunks = {{pos = {x, SY, Z}, cells = {{0, 0, 0, 'H'}}}}}},
          manifest = {v = 2}, materials = {hatch = 1}}
end
local function phantoms(W)
  local out = {}
  for _, e in ipairs(W.find_events('PROJECT_BLOCKED')) do if e.d.phantom then out[#out + 1] = e end end
  return out
end

T.test('BUG-657: a build_lost seal on a hidden tile is cancelled once with the tile; a fresh one and bp.place are not touched', function()
  local W = world('hid')
  H.floor(W, 30, SY, Z, 30, SY)
  W.tile(20, SY, Z).hidden = true                        -- the hatch of a stair nobody dug: quickfort builds nothing there
  H.place(W, 'hd', seal_doc(20))
  H.place(W, 'ok', seal_doc(30))
  H.runs(W, 3)
  T.ok(H.proj(W, 'hd'), 'a seal not lost yet stays: the tile may be revealed soon')
  T.eq(#phantoms(W), 0)
  local P = H.proj(W, 'hd')
  P.blocked, P.since = 'build_lost', W.K.now().tick
  H.runs(W, 3)
  T.eq(H.proj(W, 'hd'), nil, 'cancelled')
  T.ok(H.proj(W, 'ok'), 'the seal with an open tile stays')
  local ev = phantoms(W)
  T.eq(#ev, 1, 'once')
  T.eq({ev[1].cls, ev[1].d.proj, ev[1].d.tpl, ev[1].d.phantom}, {'A', 'hd', 'seal', {'20,73,143 ?'}})
  T.ok(ev[1].msg:find('never revealed', 1, true), ev[1].msg)
  H.runs(W, 3)
  T.eq(#phantoms(W), 1, 'no repeat')
end)

T.test('BUG-657: bp.place of a seal on a hidden tile is still placed (a hidden tile says nothing)', function()
  local W = world('hidbp')
  W.tile(50, SY, Z).hidden = true
  H.put(W, 'sh', seal_doc(50))
  T.ok(W.inbox('bp.place', {tpl = 'seal', site = 'S1'}, {id = 'sh'}).ok, 'placed')
end)

T.test('BUG-657: a hidden tile with a building planned on it is no phantom', function()
  local W = world('hidbld')
  H.floor(W, 20, SY, Z, 20, SY)
  H.place(W, 'pl', seal_doc(20))                         -- the hatch is planned on the open tile
  W.tile(20, SY, Z).hidden = true
  H.runs(W, 1)
  local P = H.proj(W, 'pl')
  P.blocked, P.since = 'build_lost', W.K.now().tick
  H.runs(W, 3)
  T.ok(H.proj(W, 'pl'), 'stays')
  T.eq(#phantoms(W), 0)
end)

T.done()
