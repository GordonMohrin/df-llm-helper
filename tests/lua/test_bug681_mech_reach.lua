-- BUG-681 (Run 16a i1 Basementflew y470-y486: 19 mechanisms counted free, all in the flooded level; the traps project waited for trapparts 300 days and
-- `plan propose` drew traps@S1 every year): economy.mech_reach counts the free parts a citizen can walk to and the ones out of reach apart;
-- state stock.mfree is the first, stock.mfar the second; mech_free (the lever flows' count) is unchanged.
local T = require('testlib')
local F = require('wp8_world')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end

local function part(id, x, y, z, flags)
  return {id = id, _pos = {x, y, z}, flags = flags or {}}
end

T.test('BUG-681: parts on a tile with no walkable group are out of reach, mech_free still counts them', function()
  local W = F.world{cfg = {baseline = F.cfg()}, units = {}}
  local far = {}
  W.load({name = 'snapshot', every = {ticks = 100}, far = function(K, x, y, z, strict) return far[x .. ',' .. y .. ',' .. z] == true end})
  W.economy = fresh('economy')
  W.load(W.economy)
  df.global.world.items.other.TRAPPARTS = {part(1, 10, 10, 10), part(2, 29, 112, 117), part(3, 29, 113, 117), part(4, 11, 10, 10, {forbid = true})}
  dfhack.items.getPosition = function(it) return it._pos[1], it._pos[2], it._pos[3] end
  far['29,112,117'], far['29,113,117'] = true, true
  local E = W.economy
  T.eq(E.mech_free(), 3, 'the raw count (the forbidden one is no free part)')
  local n, f = E.mech_reach(W.K)
  T.eq({n, f}, {1, 2}, 'one a citizen reaches, two in the flooded level')
end)

T.done()
