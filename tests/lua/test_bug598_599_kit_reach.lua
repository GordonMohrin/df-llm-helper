-- BUG-598 / BUG-599 (round 39, Run 16a i1 Basementflew y441-y447, 16b i2 Brotherarrow y413, 16d i4 Trumpetrealms y428: `inspect what=military`
-- 'A 5 (fit 0, weapon 0, wood 0, armor 2), B 2 (fit 0, weapon 0), C 2' beside 'free usable: body 18, weapons 12' for years after the round-38
-- reload; kern.log 'squad A: body of 2 positions to any material' every day for the same slots, 'squad A: 5 positions changed to the
-- training weapon of their class' every few days):
--   598: a piece that is free by its flags is still no stock when it lies in a forbidden bin, on another walk group, was made by another
--        race, or DF keeps it assigned to a squad position nobody wears it in (vacant position, no position, an unfetched occupied
--        one); M.release_kit gives those back, M.kit_bins unforbids a forbidden bin of pure gear, the text and inspect name the causes
--   599: the training policy put every melee position on a wooden weapon the fort did not hold: empty hands in PEACE with free real
--        weapons lying; a position takes a wooden spec only while the fort holds a wooden weapon for it
local T = require('testlib')
local X = require('wp6_world')
local vec = require('dfllm.util.k_mock').vec

local function mil() return X.mod('military') end
local function logged(W, pat)
  for _, l in ipairs(W.logs) do if tostring(l.msg):find(pat, 1, true) then return true end end
  return false
end
local function subs(s, pos)
  local r = {}
  for _, sp in ipairs(s.positions[pos].equipment.uniform.weapon) do r[#r + 1] = sp.item_subtype end
  return r
end

-- the stock fakes: itemdefs with armor levels, positions and containers per item, a walk group probe at x = 99
local saved = {}
local function fakes()
  saved.def, saved.pos, saved.cont, saved.holder = dfhack.items.getSubtypeDef, dfhack.items.getPosition, dfhack.items.getContainer,
                                                   dfhack.items.getHolderUnit
  local real = saved.def
  dfhack.items.getSubtypeDef = function(t, sub)
    if t == df.item_type.ARMOR then
      return {id = sub == 0 and 'ITEM_ARMOR_TUNIC' or 'ITEM_ARMOR_BREASTPLATE', armorlevel = sub == 0 and 0 or 1}
    end
    return real(t, sub)
  end
  dfhack.items.getPosition = function(it) return it._x or 10, 10, 10 end
  dfhack.items.getContainer = function(it) return it._cont end
  dfhack.items.getHolderUnit = function(it) return it._unit end
  df.global.plotinfo.race_id = 1
  df.global.plotinfo.equipment = {items_assigned = {WEAPON = vec{}, ARMOR = vec{}, HELM = vec{}, PANTS = vec{}, GLOVES = vec{},
                                                     SHOES = vec{}, SHIELD = vec{}}}
end
local function unfake()
  dfhack.items.getSubtypeDef, dfhack.items.getPosition = saved.def, saved.pos
  dfhack.items.getContainer, dfhack.items.getHolderUnit = saved.cont, saved.holder
end

local function boot(opts)
  opts = opts or {}
  opts.n = opts.n or 50
  if opts.training == nil then opts.training = true end
  local W = X.world(opts)
  local snap = X.snapshot()
  function snap.far(K, x, y, z) return x == 99 end                     -- the flooded complex
  X.load(W, {'military'}, {X.runner('P5'), snap}, {'sense'})
  W.state()
  W.run(9, {skip = 9})
  return W
end

local function body(W, sub, over)
  local other = df.global.world.items.other
  local it = X.item(W, 'ARMOR')
  it._sub, it.flags = sub or 1, {}
  it.getSubtype = function(self) return self._sub end
  for k, v in pairs(over or {}) do it[k] = v end
  other.ARMOR:insert('#', it)
  return it
end

---------------------------------------------------------------- 598: the stock
T.test('BUG-598: free by its flags is not usable: a forbidden bin, another walk group, another race, a squad reservation, a worn piece; ' ..
       'stock_mats counts the rest, stock_detail names each cause', function()
  local W = boot()
  fakes()
  df.global.world.items.other.ARMOR = vec{}
  local M = mil()
  body(W); body(W)                                                        -- two usable breastplates
  body(W, 1, {_cont = {flags = {forbid = true}}})                         -- in a forbidden bin
  body(W, 1, {_cont = {flags = {}, _outer = true}})                       -- a free bin: fine
  body(W, 1, {_x = 99})                                                   -- on the flooded walk group
  body(W, 1, {maker_race = 7})                                            -- goblin make, fortress race 1
  local resv = body(W)                                                    -- DF keeps it assigned: items_assigned, no position
  df.global.plotinfo.equipment.items_assigned.ARMOR:insert('#', resv.id)
  local worn = body(W, 1, {_unit = {military = {squad_id = 3}}})
  worn.flags.in_inventory = true
  body(W, 0)                                                              -- a tunic
  W.run(9, {skip = 9})                                                    -- (the reservation map is cached for one tick)
  local n = M.stock_mats('body')
  T.eq(n.any, 3, '2 usable + the one in a free bin (old code: every piece with its flags free, 8)')
  local d = M.stock_detail('body')
  T.eq({d.free, d.soft, d.bin, d.far, d.alien, d.reserved, d.worn}, {3, 1, 1, 1, 1, 1, 1})
  W.K.set_mode('SIEGE', 'test')
  local txt = M.kit_missing(W.K, 'A')
  T.ok(txt:find('1 in forbidden bins', 1, true) and txt:find('1 on another walk group', 1, true), txt)
  T.ok(txt:find('1 made by another race', 1, true) and txt:find('1 reserved for a squad position', 1, true), txt)
  unfake()
end)

T.test('BUG-598: gear DF keeps assigned to a vacant position or to none is given back after ORPHAN_MIN (squad_release); a piece released ' ..
       'twice and still lying is written off (stuck); the picks of the workers and ranged weapons are left alone', function()
  local W = boot()
  fakes()
  df.global.world.items.other.ARMOR = vec{}
  local M = mil()
  local A = X.squad_of(W, 'A')
  local vac = body(W)                                                     -- assigned to the vacant position 9 of squad A
  A.positions[9].equipment.assigned_items:insert('#', vac.id)
  local orph = body(W)                                                    -- listed in items_assigned, no position behind it
  df.global.plotinfo.equipment.items_assigned.ARMOR:insert('#', orph.id)
  local free = body(W)
  W.run(9, {skip = 9})
  T.eq(M.stock_mats('body').any, 1, 'only the free one is stock')
  local before = #X.acts(W, 'squad_release')
  W.run(3600 * 3, {skip = 9})
  local acts = X.acts(W, 'squad_release')
  T.ok(#acts > before, 'released')
  local ids = {}
  for _, a in ipairs(acts) do for _, id in ipairs(a.args[1]) do ids[id] = true end end
  T.ok(ids[vac.id] and ids[orph.id] and not ids[free.id], T.show(ids))
  T.ok(logged(W, 'gear pieces DF kept assigned to a squad position that does not wear them given back'), 'kern.log says so')
  -- still assigned a second time: written off
  W.run(3600 * 6, {skip = 9})
  T.ok(M.stock_detail('body').stuck >= 2, T.show(M.stock_detail('body')))
  T.eq(M.stock_mats('body').any, 1, 'the stuck ones are no stock either')
  unfake()
end)

T.test('BUG-598: kit_bins: a forbidden bin that holds nothing but gear is unforbidden in PEACE; a bin with food in it is not', function()
  local W = boot()
  fakes()
  df.global.world.items.other.ARMOR = vec{}
  local M = mil()
  local gear = {id = 9001, flags = {forbid = true}, getType = function() return df.item_type.ARMOR end}
  local mixed = {id = 9002, flags = {forbid = true}, getType = function() return df.item_type.BIN end}
  local a = body(W, 1, {_cont = gear})
  a.flags.in_inventory = true
  local b = body(W, 1, {_cont = mixed})
  b.flags.in_inventory = true
  local real = dfhack.items.getContainedItems
  dfhack.items.getContainedItems = function(c)
    if c == gear then return {a} end
    return {b, {getType = function() return df.item_type.FOOD end}}
  end
  W.K.set_mode('PEACE', 'test')
  W.run(3600 * 2, {skip = 9})                                             -- the upkeep calls kit_bins
  local fl = X.acts(W, 'item_flag')
  local ids = {}
  local seen = {}
  for _, a2 in ipairs(fl) do
    if not seen[a2.args[1]] then seen[a2.args[1]] = true; ids[#ids + 1] = a2.args[1] end
  end
  T.eq(ids, {9001}, 'the gear bin only')
  T.eq({fl[1].args[1], fl[1].args[2], fl[1].args[3]}, {9001, 'forbid', false})
  T.ok(logged(W, '1 forbidden bins or chests of gear unforbidden'), 'kern.log says so')
  dfhack.items.getContainedItems = real
  unfake()
end)

---------------------------------------------------------------- 599: the training weapons
local function arm(W, s, rows)
  for i, row in ipairs(rows) do
    local pos, uid = i - 1, 40 + i
    if s.positions[pos].occupant >= 0 then X.unseat(W, s, W.hfs[s.positions[pos].occupant].unit_id) end
    X.seat(W, s, pos, uid)
    W.unit(uid)._m.skills = row.skills or {}
    s.positions[pos].equipment.uniform.weapon = vec{}
    if row.spec then X.set_uniform(s, {positions = {pos}, items = {{cat = 'weapon', type = 'WEAPON', subtype = row.spec}}}) end
  end
end

T.test('BUG-599: no wooden weapon in the fort: the melee positions keep real weapons in PEACE (old code: 5 wooden specs, empty hands); ' ..
       'a wooden axe appears: one position takes it, the others stay', function()
  local W = boot()
  fakes()
  local A = X.squad_of(W, 'A')
  W.set_census('i', {tick = 0, w_axe = 20, w_pick = 20})
  X.weapon(W, 'ITEM_WEAPON_SWORD_SHORT'); X.weapon(W, 'ITEM_WEAPON_SWORD_SHORT'); X.weapon(W, 'ITEM_WEAPON_SWORD_SHORT')
  arm(W, A, {{skills = {AXE = 8}, spec = 'ITEM_WEAPON_AXE_BATTLE'}, {skills = {AXE = 5}, spec = 'ITEM_WEAPON_AXE_BATTLE'},
             {skills = {AXE = 3}, spec = 'ITEM_WEAPON_AXE_BATTLE'}})
  W.run(3600 * 3, {skip = 9})
  for pos = 0, 2 do
    T.eq(#subs(A, pos), 1, 'a weapon spec')
    local sub = subs(A, pos)[1]
    T.ok(sub < 0 or not X.WEAPONS[sub + 1][1]:find('TRAINING', 1, true), 'pos ' .. pos .. ' is not on a wooden weapon that does not exist')
  end
  T.ok(logged(W, 'keep a real weapon: the fort holds no free training weapon'), 'kern.log names it')
  X.weapon(W, 'ITEM_WEAPON_AXE_TRAINING')
  W.run(3600 * 3, {skip = 9})
  local wooden = 0
  for pos = 0, 2 do
    local sub = subs(A, pos)[1]
    if sub >= 0 and X.WEAPONS[sub + 1][1]:find('TRAINING', 1, true) then wooden = wooden + 1 end
  end
  T.eq(wooden, 1, 'one wooden axe: one wooden spec')
  unfake()
end)

T.test('BUG-599: the squads share the wooden weapons (the pool is minus the other squads\' wooden specs); a wooden spec with nothing behind it ' ..
       'goes back to a real weapon', function()
  local W = boot()
  fakes()
  local A = X.squad_of(W, 'A')
  W.set_census('i', {tick = 0, w_axe = 20, w_pick = 20})
  X.weapon(W, 'ITEM_WEAPON_SPEAR'); X.weapon(W, 'ITEM_WEAPON_SPEAR'); X.weapon(W, 'ITEM_WEAPON_SPEAR')
  local w1 = X.weapon(W, 'ITEM_WEAPON_AXE_TRAINING')
  arm(W, A, {{skills = {AXE = 8}, spec = 'ITEM_WEAPON_AXE_TRAINING'}, {skills = {AXE = 5}, spec = 'ITEM_WEAPON_AXE_TRAINING'}})
  W.run(3600 * 3, {skip = 9})
  local wooden = 0
  for pos = 0, 1 do
    local sub = subs(A, pos)[1]
    if sub >= 0 and X.WEAPONS[sub + 1][1]:find('TRAINING', 1, true) then wooden = wooden + 1 end
  end
  T.eq(wooden, 1, 'two wooden specs, one wooden axe: the second position got a real weapon back')
  T.eq(mil().train_pool(W.K, nil).ITEM_WEAPON_AXE_TRAINING, 0, 'the wooden axe is claimed by the one wooden spec')
  T.eq(mil().train_pool(W.K, 'A').ITEM_WEAPON_AXE_TRAINING, 1, 'without squad A: the fort holds one')
  unfake()
end)

T.test('BUG-598/599: the live state of Run 16a i1 (12 free melee weapons, no wooden one, 18 "free" body armors of which 6 lie in a forbidden ' ..
       'bin and 6 are reserved for vacant positions): the melee squads hold real weapons, only the 6 free armors are stock, the reserved ones ' ..
       'go back', function()
  local W = boot()
  fakes()
  df.global.world.items.other.ARMOR = vec{}
  local M = mil()
  local A, B = X.squad_of(W, 'A'), X.squad_of(W, 'B')
  W.set_census('i', {tick = 0, w_axe = 20, w_pick = 20})
  for _ = 1, 12 do X.weapon(W, 'ITEM_WEAPON_SWORD_SHORT') end
  local bin = {id = 9100, flags = {forbid = true}, getType = function() return df.item_type.BIN end}
  for _ = 1, 6 do body(W, 1, {_cont = bin}).flags.in_inventory = true end
  for i = 1, 6 do
    local it = body(W)
    A.positions[9 - (i % 3)].equipment.assigned_items:insert('#', it.id)           -- positions 7-9 of squad A: vacant
  end
  for _ = 1, 6 do body(W) end
  dfhack.items.getContainedItems = function() return {} end
  W.run(3600 * 6, {skip = 9})
  for _, s in ipairs({A, B}) do
    for pos = 0, 9 do
      if s.positions[pos].occupant >= 0 then
        local sub = subs(s, pos)[1]
        T.ok(sub == nil or sub < 0 or not X.WEAPONS[sub + 1][1]:find('TRAINING', 1, true), 'a real weapon spec, no wooden one')
      end
    end
  end
  local d = M.stock_detail('body')
  T.eq(d.bin, 6, 'six in the forbidden bin (the bin holds no gear list in this fake: not unforbidden)')
  T.eq(d.free + d.reserved + d.stuck, 12, 'the six of the vacant positions were given back or written off')
  T.ok(#X.acts(W, 'squad_release') >= 1, 'squad_release was sent for the reserved pieces')
  unfake()
end)

T.test('BUG-598: inspect what=military names the pieces out of reach and the reservation counters', function()
  local W = boot()
  fakes()
  df.global.world.items.other.ARMOR = vec{}
  body(W, 1, {_cont = {flags = {forbid = true}}})
  body(W)
  local r = W.inbox('inspect', {what = 'military'})
  T.eq(r.ok, true, tostring(r.msg))
  T.ok(tostring(r.msg):find('lying free but out of reach: 1 bin', 1, true), r.msg)
  T.eq(r.data.out_of_reach.bin, 1)
  T.eq(r.data.stock.body.free, 1)
  T.eq(r.data.reserved, {pending = 0, released = 0, stuck = 0})
  unfake()
end)

T.done()
