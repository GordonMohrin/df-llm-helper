-- BUG-439 (Run 16a i1 Syrupobeyed y373: a wild woolly mammoth, no LARGE_PREDATOR flag, inside the fort struck down two citizens
-- in one step; no PREDATOR, threat 0): a big wild unit on a tile that is not open to the sky is a wild danger BEFORE it kills.
local T = require('testlib')
local S = require('siege_world')
local SW = require('seal_world')

local function world(spec)
  local W = S.world{units = {S.cit(1, 60, spec.cy or 70, spec.cz), {id = 300, pos = {60, spec.y or 60, S.Z}, animal = true},
                             {id = 301, pos = {61, 25, S.Z}, animal = true, tame = true},
                             {id = 302, pos = {62, 25, S.Z}, animal = true, merchant = true}}}
  df.creature_raw = {find = function() return {caste = {[0] = {flags = {CARNIVORE = spec.cv}}}} end}      -- no LARGE_PREDATOR
  for _, id in ipairs({300, 301, 302}) do W.unit(id).race, W.unit(id).caste = 1, 0 end
  W.unit(300).body = {size_info = {size_cur = spec.size}}
  W.unit(301).body = {size_info = {size_cur = 4000000}}
  W.unit(302).body = {size_info = {size_cur = 4000000}}
  W.unit(300).flags1 = spec.f1 or {}
  W.tiles = W.tiles or {}
  for _, id in ipairs({300, 301, 302}) do
    local p = W.unit(id).pos
    W.tiles[p.x .. ',' .. p.y .. ',' .. p.z] = {des = {outside = spec.outside == true, hidden = false}}
  end
  dfhack.maps.getWalkableGroup = function() return 7 end
  S.load(W, {S.military(), SW.fake('seal', {entrances = function() return {{51, 10, S.Z}}, 25 end})})
  S.run(W, 300)
  return W
end

T.test('BUG-439 sense: a mammoth-sized wild unit inside the fort is a PREDATOR candidate (ALERT, k danger, pr 1) before it killed',
       function()
  local W = world{size = 4000000}
  T.eq({W.K.mode() ~= 'PEACE', W.K.census.h.vis}, {true, 1}, 'only the wild big one counts: the tame and the merchant one do not')
  local e = W.K.census.h.list[1]
  T.eq({e.id, e.k, e.pr, e.kl}, {300, 'danger', 1, nil})
end)

T.test('BUG-439 sense: a small wild unit, a big one under the open sky, a caged one stay wildlife (no hostile)', function()
  local W = world{size = 80000}
  T.eq({W.K.mode(), W.K.census.h.vis}, {'PEACE', 0}, 'an elk-sized or smaller visitor in the rock is no danger')
  W = world{size = 4000000, outside = true}
  T.eq({W.K.mode(), W.K.census.h.vis}, {'PEACE', 0}, 'under the open sky a grazer is wildlife until it kills (BUG-421)')
  W = world{size = 4000000, f1 = {caged = true}}
  T.eq(W.K.census.h.vis, 0, 'a caged one is no danger')
end)

-- BUG-532 (Run 16a i1 y408-y409: wild Stegosaurus / Diplodocus 47-76 tiles away, a lockdown at 30 t/s each): a plant eater is
-- wildlife beyond HERB_NEAR tiles from every citizen, and counts within it (BUG-439); a carnivore counts wherever it stands
T.test('BUG-532 sense: a far wild herbivore of a big body is no hostile; census.h.herb counts it', function()
  local W = world{size = 4000000, y = 25}           -- citizen at y 70: 45 tiles
  T.eq({W.K.mode(), W.K.census.h.vis, W.K.census.h.herb}, {'PEACE', 0, 1}, 'far plant eater: wildlife, no ALERT')
  T.eq(W.K.census.h.herb_d, 45)
  W = world{size = 4000000, y = 55}                 -- 15 tiles
  T.eq({W.K.mode() ~= 'PEACE', W.K.census.h.vis, W.K.census.h.herb}, {true, 1, 0}, 'within HERB_NEAR it is the BUG-439 danger')
end)

T.test('BUG-532 sense: a far wild carnivore of a big body still counts', function()
  local W = world{size = 4000000, y = 25, cv = true}
  T.eq({W.K.mode(), W.K.census.h.vis, W.K.census.h.herb}, {'ALERT', 1, 0}, 'CARNIVORE: a real predator whatever the distance')
end)

-- BUG-554 (Run 16a i1 y416-y422): the plant eater is marked hb for reflex, and only a citizen on its own levels (DA_DZ) is a neighbour
T.test('BUG-554 sense: a near plant eater carries hb; a citizen 14 levels below is no neighbour of a plant eater on the surface', function()
  local W = world{size = 4000000, y = 25, cy = 35}                       -- 10 tiles from a citizen outside Kern+, same level
  local e = W.K.census.h.list[1]
  T.eq({e and e.id, e and e.hb, e and e.pr}, {300, 1, 1}, 'near: a hostile, marked hb')
  W = world{size = 4000000, y = 25, cy = 35, cz = S.Z - 14}                  -- the citizen stands 14 levels down
  T.eq({W.K.mode(), W.K.census.h.vis, W.K.census.h.herb}, {'PEACE', 0, 1}, 'on another level it is wildlife')
  W = world{size = 4000000, y = 25, cy = 35, cv = true}
  e = W.K.census.h.list[1]
  T.eq({e and e.hb, e and e.pr}, {nil, 1}, 'a carnivore is no hb')
end)

T.done()
