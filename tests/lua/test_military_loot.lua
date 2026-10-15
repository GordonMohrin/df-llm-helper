-- military FR-46: forbidden metal gear of the dead is unforbidden for the armory (PEACE, or RECOVERY with no
-- hostile in sight; revealed, reachable tiles only) and mil.free counts the free metal gear per category.
local T = require('testlib')
local X = require('wp6_world')
local vec = require('dfllm.util.k_mock').vec

-- metal unless the material token says wood or leather
local function metal_decode()
  dfhack.matinfo.decode = function(it)
    if not it then return nil end
    local tok = it._mat or ''
    return {getToken = function() return tok end,
            material = {flags = {IS_METAL = tok:find('^INORGANIC') ~= nil}}}
  end
end

local function gear(W, typ, mat, flags, pos, stack)
  local it = X.item(W, typ, mat)
  it.flags, it._pos, it.stack_size = flags or {}, pos, stack or 1
  df.global.world.items.other[typ]:insert('#', it)
  return it
end

local function world(mode, setup)
  local W = X.world{n = 4, mode = mode}
  metal_decode()
  for _, t in ipairs({'ARMOR', 'HELM', 'PANTS', 'GLOVES', 'SHOES', 'SHIELD', 'AMMO'}) do
    df.global.world.items.other[t] = df.global.world.items.other[t] or vec{}
  end
  dfhack.items.getPosition = function(it) local p = it._pos; if p then return p[1], p[2], p[3] end end
  dfhack.items.getHolderUnit = function() return nil end
  W.act_result('item_flag', function(id, flag, on) W.items_by_id[id].flags[flag] = on; return true end)
  local snap = {name = 'snapshot', every = {ticks = 100}}
  function snap.tile(K, x, y, z) if x == 66 then return nil end return {c = '.'} end   -- x 66: hidden
  function snap.far(K, x, y, z) return x == 99 end                                     -- x 99: cut off
  local loot = {}
  if setup then setup(W, loot) end
  X.load(W, {'military'}, {X.runner('P5'), snap}, {'sense'})
  W.state()
  return W, loot
end

T.test('FR-46: forbidden metal loot on known reachable tiles is unforbidden in PEACE; mil.free counts it', function()
  local W, l = world('PEACE', function(W, l)
    l.sword = gear(W, 'WEAPON', 'INORGANIC:STEEL', {forbid = true}, {10, 10, 100})
    l.mail = gear(W, 'ARMOR', 'INORGANIC:IRON', {forbid = true}, {11, 10, 100})
    l.bolts = gear(W, 'AMMO', 'INORGANIC:BRONZE', {forbid = true}, {12, 10, 100}, 25)
    l.hidden = gear(W, 'HELM', 'INORGANIC:IRON', {forbid = true}, {66, 10, 100})
    l.cave = gear(W, 'SHIELD', 'INORGANIC:IRON', {forbid = true}, {99, 10, 100})
    l.wood = gear(W, 'SHIELD', 'WOOD', {forbid = true}, {13, 10, 100})
    l.held = gear(W, 'PANTS', 'INORGANIC:IRON', {forbid = true, in_inventory = true}, {14, 10, 100})
    l.trader = gear(W, 'GLOVES', 'INORGANIC:IRON', {forbid = true, trader = true}, {15, 10, 100})
    l.free = gear(W, 'ARMOR', 'INORGANIC:COPPER', {}, {16, 10, 100})
  end)
  W.run(9, {skip = 9})
  T.eq({l.sword.flags.forbid, l.mail.flags.forbid, l.bolts.flags.forbid}, {false, false, false})
  T.eq({l.hidden.flags.forbid, l.cave.flags.forbid, l.wood.flags.forbid, l.held.flags.forbid, l.trader.flags.forbid},
       {true, true, true, true, true})
  local free = W.state().mil.free
  T.eq(free, {weapon = 1, body = 2, ammo = 25}, 'categories without free metal are left out')
end)

T.test('FR-46: no loot in SIEGE (soldiers and haulers stay inside); free metal still counted', function()
  local W, l = world('SIEGE', function(W, l)
    l.sword = gear(W, 'WEAPON', 'INORGANIC:STEEL', {forbid = true}, {10, 10, 100})
    gear(W, 'WEAPON', 'INORGANIC:IRON', {}, {10, 11, 100})
  end)
  W.run(9, {skip = 9})
  T.eq(l.sword.flags.forbid, true)
  T.eq(#W.find_acts('item_flag'), 0)
  T.eq(W.state().mil.free.weapon, 1)
end)

T.done()
