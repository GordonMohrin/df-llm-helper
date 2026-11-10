-- BUG-638 (Run 16b i2 Valleyhame y376-y377: seal y376s0b1 / y377s0b1 for the hatch 107,88,126, 'nothing stands at 107,88,126', build_lost twice,
-- the stalled decision offering cancel / place for 64 days; Run 16c i3 Wallfree y374-y376: seals y374s0b0 / y376s0b0 for the hatch 67,44,139 of a
-- stair that was never dug): a seal piece on solid rock is a phantom. bp.place refuses a seal whose pieces are all phantoms, a placed one
-- (an older document) is cancelled by the kernel with PROJECT_BLOCKED d.phantom, once; a seal with one real piece stays.
local T = require('testlib')
local H = require('runner_world')
local runner = require('dfllm.runner')

local DAY = 1200
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

-- a seal document with one cell per x (key 'H' hatch)
local function seal_doc(xs)
  local cells = {}
  for _, x in ipairs(xs) do cells[#cells + 1] = {x - xs[1], 0, 0, 'H'} end
  return {v = 2, tpl = 'seal', site = 'S1', class = 'defense', params = {at = xs[1] .. ',' .. SY .. ',' .. Z .. ' stair_updown'},
          anchor = {xs[1], SY, Z}, rot = 0,
          stages = {{label = 'seal.build', mode = 'build', orders = 1, defense = 1,
                     chunks = {{pos = {xs[1], SY, Z}, cells = cells}}}},
          manifest = {v = 2}, materials = {hatch = 1}}
end
local function phantoms(W)
  local out = {}
  for _, e in ipairs(W.find_events('PROJECT_BLOCKED')) do if e.d.phantom then out[#out + 1] = e end end
  return out
end

T.test('BUG-638: bp.place refuses a seal whose every piece lies on solid rock; one open piece is enough', function()
  local W = world('phbp')
  H.put(W, 'sx', seal_doc({20}))                         -- the map default: solid rock
  local r = W.inbox('bp.place', {tpl = 'seal', site = 'S1'}, {id = 'sx'})
  T.ok(not r.ok, 'refused')
  T.ok(r.msg:find('nothing to build on: 20,73,143 # is solid rock', 1, true), r.msg)
  T.eq(H.proj(W, 'sx'), nil)
  W.tile(31, SY, Z).c = '>'                              -- a real stair beside the phantom
  H.put(W, 'sy', seal_doc({30, 31}))
  T.ok(W.inbox('bp.place', {tpl = 'seal', site = 'S1'}, {id = 'sy'}).ok, 'one real piece: placed')
  H.floor(W, 40, SY, Z, 40, SY)
  H.put(W, 'sz', seal_doc({40}))
  T.ok(W.inbox('bp.place', {tpl = 'seal', site = 'S1'}, {id = 'sz'}).ok, 'an open floor: placed')
  W.tile(50, SY, Z).hidden = true
  H.put(W, 'sh', seal_doc({50}))
  T.ok(W.inbox('bp.place', {tpl = 'seal', site = 'S1'}, {id = 'sh'}).ok, 'a hidden tile says nothing: placed')
end)

T.test('BUG-638: a placed seal that is build_lost on solid rock is cancelled once with the tiles; a seal with a real piece stays', function()
  local W = world('phscan')
  H.floor(W, 20, SY, Z, 20, SY)
  H.floor(W, 40, SY, Z, 40, SY)
  H.place(W, 'ph', seal_doc({20}))                       -- placed while the tile was open (an older kernel / a map that changed)
  W.tile(20, SY, Z).c = '#'
  H.place(W, 'ok', seal_doc({40}))
  H.runs(W, 1)
  local P = H.proj(W, 'ph')
  P.blocked, P.since = 'build_lost', W.K.now().tick
  H.runs(W, 3)
  T.eq(H.proj(W, 'ph'), nil, 'cancelled')
  T.ok(H.proj(W, 'ok'), 'the seal with an open tile stays')
  local ev = phantoms(W)
  T.eq(#ev, 1, 'once')
  T.eq({ev[1].cls, ev[1].d.proj, ev[1].d.tpl, ev[1].d.phantom}, {'A', 'ph', 'seal', {'20,73,143 #'}})
  T.ok(ev[1].msg:find('solid rock', 1, true), ev[1].msg)
  H.runs(W, 3)
  T.eq(#phantoms(W), 1, 'no repeat')
end)

T.done()
