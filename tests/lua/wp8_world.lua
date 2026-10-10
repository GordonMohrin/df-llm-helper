-- WP8 test world: k_mock plus the DF fakes baseline/economy/care read (item and building vectors,
-- manager orders, materials, kitchen, enums). Test-only (CONTRACTS §1.4 exempts tests/**).
--   local F = require('wp8_world'); local W = F.world{units = {...}}; F.item(W, 'DRINK', {stack_size = 5})
local kmock = require('dfllm.util.k_mock')
local json = require('dfllm.util.json')

local F = {}
F.REPO = (arg and arg[0] or ''):match('^(.*)/tests/lua/[^/]+$') or '.'

function F.read_json(rel)
  local f = assert(io.open(F.REPO .. '/' .. rel, 'rb'))
  local s = f:read('a')
  f:close()
  return json.decode(s)
end

F.ITEM_TYPES = {'BAR', 'SMALLGEM', 'BLOCKS', 'ROUGH', 'BOULDER', 'WOOD', 'DOOR', 'BED', 'CHAIR', 'CAGE', 'BARREL',
  'BUCKET', 'TABLE', 'COFFIN', 'STATUE', 'CORPSE', 'WEAPON', 'ARMOR', 'SHOES', 'SHIELD', 'HELM', 'GLOVES', 'BIN',
  'FIGURINE', 'AMULET', 'SCEPTER', 'AMMO', 'CROWN', 'RING', 'EARRING', 'BRACELET', 'ANVIL', 'CORPSEPIECE', 'MEAT',
  'FISH', 'SEEDS', 'PLANT', 'SKIN_TANNED', 'PLANT_GROWTH', 'THREAD', 'CLOTH', 'TOTEM', 'PANTS', 'DRINK', 'CHEESE',
  'FOOD', 'TOOL', 'EGG'}

local function enum_from(names, first)
  local t = {}
  for i, n in ipairs(names) do t[n] = first + i - 1; t[first + i - 1] = n end
  return t
end

-- real df.buildings_other_id names (strings in hack/dfhack.dll; 53.16 has no ZONE_HOSPITAL). The fake
-- vectors reject any other name, and record it in W.bad_vectors.
F.BUILDINGS_OTHER = {'IN_PLAY', 'STOCKPILE', 'ANY_ZONE', 'ACTIVITY_ZONE', 'ZONE_HOME', 'ZONE_TOMB', 'ZONE_POND',
  'ZONE_DUMP', 'ZONE_BEDROOM', 'ZONE_MEETING_HALL', 'ZONE_PEN', 'ANY_HOSPITAL', 'ANY_STORAGE', 'BOX', 'CABINET',
  'TRAP', 'DOOR', 'FLOODGATE', 'HATCH', 'WELL', 'TABLE', 'BRIDGE', 'CHAIR', 'TRADE_DEPOT', 'BED', 'FARM_PLOT',
  'STATUE', 'SLAB', 'COFFIN', 'WEAPON_RACK', 'ARMOR_STAND', 'FURNACE_ANY', 'WORKSHOP_ANY'}

local function strict(W, other, names)
  local ok = {}
  for _, n in ipairs(names) do ok[n] = true end
  setmetatable(other, {__index = function(t, cat)
    if not ok[cat] then
      W.bad_vectors[#W.bad_vectors + 1] = tostring(cat)
      error('fake DF: no vector other.' .. tostring(cat), 2)
    end
    local v = kmock.vec{}
    rawset(t, cat, v)
    return v
  end})
end

-- materials: F.mat(W, type, index, {token=, flags={EDIBLE_RAW=true}})
function F.mat(W, t, i, spec)
  W.mats[t .. ':' .. i] = {type = t, index = i, token = spec.token or (t .. ':' .. i), flags = spec.flags or {}}
end

-- install the WP8 fakes on an existing k_mock world (also used on top of tests/lua/kern_world.lua)
function F.install(W)
  local g = df.global
  W.mats, W.kitchen, W.civzones_at, W.subdefs, W.item_seq = {}, {}, {}, {}, 5000
  local et = enum_from(F.ITEM_TYPES, 0)
  et.NONE, et[-1] = -1, 'NONE'
  df.item_type = et
  df.job_type = enum_from({'CustomReaction', 'MakeCharcoal', 'SmeltOre', 'MakeQuiver', 'ConstructArmorStand',
                           'PrepareMeal', 'WeaveCloth', 'ConstructBlocks', 'MakeCrafts', 'StrangeMoodCrafter'}, 0)
  df.workshop_type = enum_from({'Carpenters', 'Farmers', 'Masons', 'Craftsdwarfs', 'Jewelers', 'MetalsmithsForge',
                                'MagmaForge', 'Bowyers', 'Mechanics', 'Siege', 'Butchers', 'Leatherworks', 'Tanners',
                                'Clothiers', 'Fishery', 'Still', 'Loom'}, 0)
  df.furnace_type = enum_from({'WoodFurnace', 'Smelter', 'GlassFurnace', 'Kiln'}, 0)
  local mt = enum_from({'Fey', 'Secretive', 'Possessed', 'Macabre', 'Fell', 'Melancholy', 'Raving', 'Berserk',
                        'Baby', 'Traumatized'}, 0)
  mt.None, mt[-1] = -1, 'None'
  df.mood_type = mt
  df.civzone_type = enum_from({'Home', 'Tomb', 'Pond', 'Dump'}, 0)
  df.building_type = enum_from({'Chair', 'Bed', 'Table', 'Coffin', 'FarmPlot', 'Furnace', 'TradeDepot', 'Shop',
                                'Door', 'Floodgate', 'Box', 'Weaponrack', 'Armorstand', 'Workshop'}, 0)
  df.abstract_building_type = enum_from({'MEAD_HALL', 'KEEP', 'TEMPLE', 'DARK_TOWER', 'MARKET', 'TOMB',
                                         'DUNGEON', 'UNDERWORLD_SPIRE', 'INN_TAVERN', 'LIBRARY',
                                         'COUNTING_HOUSE', 'GUILDHALL', 'TOWER', 'HOSPITAL'}, 0)
  df.unit_thought_type = enum_from({'SawDeadBody', 'NoShirt', 'Thirsty', 'AteNoTable', 'Rain'}, 0)
  df.death_type = enum_from({'OLD_AGE', 'HUNGER', 'THIRST', 'SHOT', 'BLEED'}, 0)
  df.job_skill = enum_from({'MINING', 'BONECARVE', 'WOODCRAFT', 'CARPENTRY', 'MASONRY', 'STONECRAFT', 'CUTGEM',
                            'ENCRUSTGEM', 'FORGE_WEAPON', 'FORGE_ARMOR', 'FORGE_FURNITURE', 'METALCRAFT',
                            'GLASSMAKER', 'LEATHERWORK', 'TANNER', 'CLOTHESMAKING', 'WEAVING', 'BOWYER',
                            'MECHANICS'}, 0)
  df.agreement_details_type = enum_from({'JoinParty', 'Residency', 'Citizenship', 'Location'}, 0)
  df.unit_inventory_item = {T_mode = {Hauled = 0, Weapon = 1, Worn = 2}}
  df.building_trapst = {is_instance = function(_, b) return type(b) == 'table' and b._trap == true end}
  W.items_by_id = {}
  g.world.manager_orders = {all = kmock.vec{}, manager_order_next_id = 1}
  g.world.raws = {plants = {all = kmock.vec{}}}
  g.plotinfo.petitions = kmock.vec{}
  -- dfhack fakes
  dfhack.matinfo = {
    decode = function(t, i)
      if type(t) == 'table' then t, i = t.mat_type, t.mat_index end
      local m = W.mats[tostring(t) .. ':' .. tostring(i)]
      if not m then return nil end
      return {type = m.type, index = m.index, material = {flags = m.flags}, getToken = function() return m.token end}
    end,
    find = function(a, b)
      local tok = b and (a .. ':' .. b) or a
      for _, m in pairs(W.mats) do
        if m.token == tok or m.token:sub(-#tok - 1) == ':' .. tok then
          return {type = m.type, index = m.index, getToken = function() return m.token end}
        end
      end
    end,
  }
  dfhack.kitchen = {
    findExclusion = function(flags, it, sub, t, i)
      for k, e in ipairs(W.kitchen) do
        if e.what == next(flags) and e.it == it and e.t == t and e.i == i then return k - 1 end
      end
      return -1
    end,
    addExclusion = function(flags, it, sub, t, i)
      W.kitchen[#W.kitchen + 1] = {what = next(flags), it = it, t = t, i = i}
      return true
    end,
  }
  W.act_result('kitchen_exclude', function(item, sub, t, i, what)
    W.kitchen[#W.kitchen + 1] = {what = what, it = df.item_type[item], t = t, i = i}
    return true, 'added'
  end)
  dfhack.items = {
    getContainer = function(it) return it._cont end,
    getHolderBuilding = function(it) return it._holder end,
    getPosition = function(it) local p = it._pos; if p then return p[1], p[2], p[3] end end,
    getContainedItems = function(it) return it._contents or {} end,
    getSubtypeDef = function(t, s) return W.subdefs[s] end,
    markForMelting = function(it) if it.flags.melt then return false end; it.flags.melt = true; return true end,
    cancelMelting = function(it) if not it.flags.melt then return false end; it.flags.melt = false; return true end,
  }
  dfhack.units.isGhost = function(u) return u._m.ghost == true end
  dfhack.units.getContainer = function(u) return u._cage end
  -- dead citizens keep their group link (unlike isCitizen); _m.own_group marks insane members
  dfhack.units.isOwnGroup = function(u) return u._m.citizen == true or u._m.own_group == true end
  dfhack.units.getNominalSkill = function(u, id) return (u._m.skills or {})[df.job_skill[id]] or 0 end
  dfhack.buildings = {findCivzonesAt = function(p) return W.civzones_at[p.x .. ',' .. p.y .. ',' .. p.z] end}
  dfhack.job = {getManagerOrderName = function(o) return o._name or '' end,
                getHolder = function(job) return job._holder end}
  W.site = {buildings = kmock.vec{}}
  dfhack.world = dfhack.world or {}
  dfhack.world.getCurrentSite = function() return W.site end
  W.bad_vectors = {}
  strict(W, g.world.buildings.other, F.BUILDINGS_OTHER)
  local inames = {'ANY_CORPSE', 'IN_PLAY'}
  for _, n in ipairs(F.ITEM_TYPES) do inames[#inames + 1] = n end
  strict(W, g.world.items.other, inames)
  -- workorder creates a visible manager order (like the real tool), so liveness checks work
  W.act_result('workorder', function(spec)
    local mo = g.world.manager_orders
    local id = mo.manager_order_next_id
    mo.manager_order_next_id = id + 1
    mo.all:insert('#', {id = id, job_type = df.job_type[spec.job], reaction_name = spec.reaction or '',
                        amount_left = spec.amount_total, amount_total = spec.amount_total, _spec = spec,
                        mat_type = -1, mat_index = -1})
    return true, id
  end)
  return W
end

function F.world(opts)
  return F.install(kmock.new(opts or {}))
end

-- item: F.item(W, 'DRINK', {stack_size=5, flags={forbid=true}, mat_type=, mat_index=, _pos={x,y,z}})
function F.item(W, cat, spec)
  spec = spec or {}
  W.item_seq = W.item_seq + 1
  local it = spec
  it.id = it.id or W.item_seq
  it.flags = it.flags or {}
  it.stack_size = it.stack_size or 1
  it.mat_type, it.mat_index = it.mat_type or 0, it.mat_index or -1
  local tcode = df.item_type[it._type or cat]
  it.getType = function() return tcode end
  df.global.world.items.other[cat]:insert('#', it)
  W.items_by_id[it.id] = it
  return it
end

function F.building(W, cat, spec)
  local b = W.add_building(spec or {})
  df.global.world.buildings.other[cat]:insert('#', b)
  return b
end

-- a built workshop (or furnace) as a job holder: F.workshop(W, 'Craftsdwarfs') / F.workshop(W, 'GlassFurnace', true)
function F.workshop(W, name, furnace)
  local bt = furnace and df.building_type.Furnace or df.building_type.Workshop
  local sub = furnace and df.furnace_type[name] or df.workshop_type[name]
  assert(sub, 'unknown workshop ' .. tostring(name))
  return F.building(W, furnace and 'FURNACE_ANY' or 'WORKSHOP_ANY',
                    {type = sub, getType = function() return bt end, getSubtype = function() return sub end})
end

-- a hospital: a site location plus an ANY_ZONE civzone linked to it (quickfort zone.lua:350)
function F.hospital(W, box)
  local loc = {id = 600 + #W.site.buildings, getType = function() return df.abstract_building_type.HOSPITAL end}
  W.site.buildings:insert('#', loc)
  return F.building(W, 'ANY_ZONE', {x1 = box[1], y1 = box[2], x2 = box[3], y2 = box[4], z = box[5],
                                    location_id = loc.id})
end

function F.order(W, spec)
  local mo = df.global.world.manager_orders
  spec.id = spec.id or mo.manager_order_next_id
  mo.manager_order_next_id = math.max(mo.manager_order_next_id, spec.id + 1)
  spec.amount_left = spec.amount_left or 1
  mo.all:insert('#', spec)
  return spec
end

-- every act.run call of W checked against an allowlist document (config/allowlist.json by default)
function F.bad_runs(W, al)
  al = al or F.read_json('config/allowlist.json')
  local A = require('dfllm.act')
  local bad = {}
  for _, a in ipairs(W.find_acts('run')) do
    local args = {}
    for i = 2, a.args.n do args[#args + 1] = a.args[i] end
    local ok, why = A.allowed(al, a.args[1], args)
    if not ok then bad[#bad + 1] = a.args[1] .. ' ' .. table.concat(args, ' ') .. ': ' .. tostring(why) end
  end
  return bad
end

-- the command lines of all act.run calls, joined by spaces
function F.runs(W)
  local r = {}
  for _, a in ipairs(W.find_acts('run')) do
    local parts = {}
    for i = 1, a.args.n do parts[#parts + 1] = tostring(a.args[i]) end
    r[#r + 1] = table.concat(parts, ' ')
  end
  return r
end

function F.has(list, s)
  for _, x in ipairs(list) do if x == s then return true end end
  return false
end

function F.cfg(W)
  return F.read_json('config/baseline.json')
end

-- a fake citizen census as sense would publish it
function F.census_u(ids, extra)
  local c = {tick = 0, cit = #ids, adults = #ids, children = 0, soldiers = 0, ids = ids, soldier_ids = {},
             outside = 0, outside_ids = {}, on_bridge = {}, stressed = 0, caged = {}}
  for k, v in pairs(extra or {}) do c[k] = v end
  return c
end

return F
