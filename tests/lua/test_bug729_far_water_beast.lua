-- BUG-729 (Run 16c i3 Doorwings y372: alligators at the river 24-60 tiles from the citizens held ALERT and the clock at 100 t/s):
-- a wild beast in or beside water, farther than sense.WILD_WATER_NEAR from every citizen, is water wildlife (census.h.wfar, no
-- hostile, no ALERT); within it, or off the water, it counts as before.
local T = require('testlib')
local S = require('siege_world')

local BROOK = {x = 70, y = 20, z = S.Z}

local function world(spec)
  spec = spec or {}
  local units = {S.cit(1, 60, 70), S.cit(2, 60, spec.cy or 90),
                 {id = 300, pos = {BROOK.x, BROOK.y, S.Z}, animal = true, race = 'ALLIGATOR'}}
  local W = S.world{units = units}
  df.creature_raw = {find = function() return {caste = {[0] = {flags = {LARGE_PREDATOR = true}}}} end}
  W.unit(300).race, W.unit(300).caste = 1, 0
  W.unit(300).body = {size_info = {size_cur = 150000}}
  W.unit(300).flags1, W.unit(300).flags2 = {}, {}
  W.tiles = W.tiles or {}
  local function tile(x, y, des) W.tiles[x .. ',' .. y .. ',' .. S.Z] = {des = des} end
  for x = 58, 72 do
    for y = 19, 21 do tile(x, y, {outside = true, hidden = false, flow_size = 0}) end
  end
  if spec.dry ~= true then tile(BROOK.x, BROOK.y, {outside = true, hidden = false, flow_size = 3, liquid_type = 0}) end
  dfhack.maps.getWalkableGroup = function() return 7 end         -- on the citizens' group: the walk-group rule does not drop it
  local mil = S.military()
  mil.sortie_squad = function() return 'A', 5 end
  S.load(W, {mil})
  S.run(W, 300)
  return W
end

T.test('BUG-729 sense: a predator at the water far from every citizen is no hostile (wfar), no ALERT; census.w still lists it', function()
  local W = world()
  local h = W.K.census.h
  T.eq({W.K.mode(), h.vis, h.wfar, h.wfar_d}, {'PEACE', 0, 1, 50}, 'citizen 2 stands 50 tiles away')
  T.eq(W.K.census.w.n, 1, 'water watch keeps it')
end)

T.test('BUG-729 sense: within WILD_WATER_NEAR of a citizen, or off the water, it is a hostile as before', function()
  local W = world{cy = 30}                                   -- 10 tiles
  T.eq({W.K.mode() ~= 'PEACE', W.K.census.h.vis, W.K.census.h.wfar}, {true, 1, 0}, 'near a citizen: counts')
  W = world{dry = true}
  T.eq({W.K.mode() ~= 'PEACE', W.K.census.h.vis, W.K.census.h.wfar}, {true, 1, 0}, 'dry ground: the predator rule')
end)

T.done()
