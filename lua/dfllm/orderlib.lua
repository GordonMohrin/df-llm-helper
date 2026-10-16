-- orderlib: manager-order checks (FR-01, FR-10, FR-39). A library, not a kernel module (like reserve.lua):
-- economy and act.lua require it; it only reads (order fields, reaction raws, enum names) and never writes.
--   * FR-39: DF 53.16 crashes inside unit processing when an idle dwarf takes the job of a make-item order
--     without an item subtype (`workorder '{"job":"MakeArmor","material_category":["cloth"]}'` -> item_subtype
--     -1; four crashes on 14.10.2026, each within a minute of queuing). Every working order names the item
--     (ITEM_ARMOR_SHIRT, ITEM_PANTS_PANTS, ...): O.unsafe(job, sub) is the guard act.workorder, the order.add
--     verb and economy's daily scan use.
--   * FR-01: what an order needs before it can run: a built workshop of the right type (O.workshops), the
--     input material (O.input: a census key), a worker with the labor (O.labors). Only positively known needs
--     are returned; an unknown job or material is never reported as stuck.
--   * FR-10: the reason of a CANCEL_JOB report ("<unit> cancels <job>: Needs <material>.").
local O = {}

-- item-definition jobs: the order names one item def (raws ITEM_*); without it DF 53.16 crashes (FR-39)
O.SUBTYPE_JOBS = {MakeArmor = true, MakePants = true, MakeShoes = true, MakeGloves = true, MakeHelm = true,
                  MakeWeapon = true, MakeAmmo = true, MakeShield = true, MakeTrapComponent = true, MakeTool = true,
                  MakeToy = true}

function O.has_subtype(sub)
  if math.type(sub) == 'integer' then return sub >= 0 end
  return type(sub) == 'string' and sub:match('^ITEM_[A-Z0-9_]+$') ~= nil
end

-- true when an order of `job` (df.job_type name) with item subtype `sub` (raws token or index) would crash DF
function O.unsafe(job, sub)
  return O.SUBTYPE_JOBS[tostring(job)] == true and not O.has_subtype(sub)
end

---------------------------------------------------------------- material class of an order
local GLASS_MATS = {[3] = true, [4] = true, [5] = true}       -- df.builtin_mats GLASS_GREEN, CLEAR, CRYSTAL
local CAT_CLASS = {{'wood', 'wood'}, {'wood2', 'wood'}, {'cloth', 'cloth'}, {'silk', 'silk'}, {'yarn', 'yarn'},
                   {'leather', 'leather'}, {'bone', 'bone'}, {'shell', 'bone'}, {'horn', 'bone'}, {'tooth', 'bone'},
                   {'pearl', 'bone'}, {'plant', 'cloth'}}
local function field(o, k) return o[k] end
local function get(o, k)
  if o == nil then return nil end
  local ok, v = pcall(field, o, k)
  if ok then return v end
end

-- 'wood' | 'rock' | 'metal' | 'glass' | 'cloth' | 'silk' | 'yarn' | 'leather' | 'bone' | 'any';
-- is_metal(mat_index) -> bool (an inorganic material's IS_METAL flag; nil = unknown -> rock)
function O.mat_class(o, is_metal)
  local mc = get(o, 'material_category')
  if mc then
    for _, e in ipairs(CAT_CLASS) do if get(mc, e[1]) == true then return e[2] end end
  end
  local mt, mi = get(o, 'mat_type'), get(o, 'mat_index')
  if mt == 0 then
    if math.type(mi) == 'integer' and mi >= 0 and is_metal and is_metal(mi) then return 'metal' end
    return 'rock'
  end
  if GLASS_MATS[mt] then return 'glass' end
  return 'any'
end

---------------------------------------------------------------- workshops (FR-01)
local W = function(n) return 'workshop:' .. n end
local F = function(n) return 'furnace:' .. n end
local FORGE = {W'MetalsmithsForge', W'MagmaForge'}
local GLASS = {F'GlassFurnace', F'MagmaGlassFurnace'}
local CRAFTS, MASONS, CARP, LEATHER, CLOTH = {W'Craftsdwarfs'}, {W'Masons'}, {W'Carpenters'}, {W'Leatherworks'}, {W'Clothiers'}
local FURNITURE = {rock = MASONS, wood = CARP, metal = FORGE, glass = GLASS}
local CONTAINER = {wood = CARP, metal = FORGE, glass = GLASS}
local WEAR = {metal = FORGE, leather = LEATHER, cloth = CLOTH, silk = CLOTH, yarn = CLOTH, bone = CRAFTS}
local function any(list) return {any = list} end
-- job type name -> {material class or 'any' -> workshop keys (one of them must stand built)}
O.WS = {
  ConstructTable = FURNITURE, ConstructThrone = FURNITURE, ConstructDoor = FURNITURE, ConstructCabinet = FURNITURE,
  ConstructChest = FURNITURE, ConstructCoffin = FURNITURE, ConstructFloodgate = FURNITURE,
  ConstructHatchCover = FURNITURE, ConstructGrate = FURNITURE, ConstructArmorStand = FURNITURE,
  ConstructWeaponRack = FURNITURE, ConstructStatue = {rock = MASONS, metal = FORGE, glass = GLASS},
  ConstructSlab = {rock = MASONS}, ConstructQuern = {rock = MASONS}, ConstructMillstone = {rock = MASONS},
  ConstructBlocks = {rock = MASONS, wood = CARP, metal = FORGE, glass = GLASS}, ConstructBed = {wood = CARP},
  ConstructBin = CONTAINER, MakeBarrel = CONTAINER, MakeBucket = CONTAINER, MakeCage = CONTAINER,
  ConstructMechanisms = {rock = {W'Mechanics'}, metal = {W'Mechanics'}},
  MakeCrafts = {rock = CRAFTS, wood = CRAFTS, bone = CRAFTS, metal = FORGE, glass = GLASS, leather = LEATHER,
                cloth = CLOTH, silk = CLOTH, yarn = CLOTH},
  MakeArmor = WEAR, MakeHelm = WEAR, MakePants = WEAR, MakeGloves = WEAR, MakeShoes = WEAR,
  MakeShield = {metal = FORGE, wood = CARP, leather = LEATHER},
  MakeWeapon = {metal = FORGE, wood = {W'Bowyers', W'Carpenters'}},
  MakeAmmo = {metal = FORGE, wood = {W'Bowyers', W'Craftsdwarfs'}, bone = {W'Bowyers', W'Craftsdwarfs'}},
  MakeTrapComponent = {metal = FORGE},
  MakeQuiver = any(LEATHER), MakeBackpack = any(LEATHER),
  BrewDrink = any({W'Still'}), PrepareMeal = any({W'Kitchen'}),
  PrepareRawFish = any({W'Fishery'}), ExtractFromRawFish = any({W'Fishery'}),
  ProcessPlants = any({W'Farmers'}), ProcessPlantsBag = any({W'Farmers'}), ProcessPlantsVial = any({W'Farmers'}),
  ProcessPlantsBarrel = any({W'Farmers'}), MillPlants = any({W'Quern', W'Millstone'}),
  WeaveCloth = any({W'Loom'}), MakeCharcoal = any({F'WoodFurnace'}), MakeAsh = any({F'WoodFurnace'}),
  SmeltOre = any({F'Smelter', F'MagmaSmelter'}), CutGems = any({W'Jewelers'}),
  ConstructCatapultParts = any({W'Siege'}), ConstructBallistaParts = any({W'Siege'}),
  ButcherAnimal = any({W'Butchers'}), TanHide = any({W'Tanners'}),
  -- Run 11 (Kilrudrabed, no gem vein): economy's glass chain (sand -> raw green glass -> cut glass) and its bags
  CollectSand = any(GLASS), MakeRawGlass = any(GLASS), CutGlass = any({W'Jewelers'}),
  ConstructBag = {cloth = CLOTH, silk = CLOTH, yarn = CLOTH, leather = LEATHER},
}

-- labor (df.unit_labor name) per workshop key; the forge and the craftsdwarf's shop depend on the job/material
O.WS_LABOR = {['workshop:Masons'] = 'MASON', ['workshop:Carpenters'] = 'CARPENTER', ['workshop:Still'] = 'BREWER',
              ['workshop:Kitchen'] = 'COOK', ['workshop:Farmers'] = 'PROCESS_PLANT', ['workshop:Quern'] = 'MILLER',
              ['workshop:Millstone'] = 'MILLER', ['workshop:Loom'] = 'WEAVER', ['workshop:Clothiers'] = 'CLOTHESMAKER',
              ['workshop:Leatherworks'] = 'LEATHER', ['workshop:Tanners'] = 'TANNER', ['furnace:Smelter'] = 'SMELT',
              ['furnace:MagmaSmelter'] = 'SMELT', ['furnace:WoodFurnace'] = 'BURN_WOOD',
              ['furnace:GlassFurnace'] = 'GLASSMAKER', ['furnace:MagmaGlassFurnace'] = 'GLASSMAKER',
              ['workshop:Fishery'] = 'CLEAN_FISH', ['workshop:Butchers'] = 'BUTCHER', ['workshop:Bowyers'] = 'BOWYER',
              ['workshop:Mechanics'] = 'MECHANIC', ['workshop:Jewelers'] = 'CUT_GEM', ['workshop:Siege'] = 'SIEGECRAFT'}
local FORGE_LABOR = {MakeWeapon = 'FORGE_WEAPON', MakeAmmo = 'FORGE_WEAPON', MakeTrapComponent = 'FORGE_WEAPON',
                     MakeArmor = 'FORGE_ARMOR', MakeHelm = 'FORGE_ARMOR', MakePants = 'FORGE_ARMOR',
                     MakeGloves = 'FORGE_ARMOR', MakeShoes = 'FORGE_ARMOR', MakeShield = 'FORGE_ARMOR'}
local CRAFT_LABOR = {rock = 'STONE_CRAFT', wood = 'WOOD_CRAFT', bone = 'BONE_CARVE'}
-- jobs whose labor is not the workshop's (DFHack autolabor joblabormapper.cpp: CollectSand is item hauling)
O.JOB_LABOR = {CollectSand = 'HAUL_ITEM'}

-- workshop keys an order may run in (nil = unknown: not checked), material class
function O.workshops(job, mc)
  local m = O.WS[job]
  if not m then return nil end
  return m[mc] or m.any
end

-- labor names the order's workers need (any of them); nil = unknown
function O.labors(job, mc, ws)
  if type(ws) ~= 'table' then return nil end
  if O.JOB_LABOR[job] then return {O.JOB_LABOR[job]} end
  local r, seen = {}, {}
  for _, w in ipairs(ws) do
    local l = O.WS_LABOR[w]
    if w == 'workshop:MetalsmithsForge' or w == 'workshop:MagmaForge' then l = FORGE_LABOR[job] or 'FORGE_FURNITURE'
    elseif w == 'workshop:Craftsdwarfs' then l = CRAFT_LABOR[mc] end
    if l and not seen[l] then seen[l] = true; r[#r + 1] = l end
  end
  return #r > 0 and r or nil
end

-- the census key of an order's input (economy's stock keys), or nil when not checked
local WEAR_JOBS = {MakeArmor = true, MakeHelm = true, MakePants = true, MakeGloves = true, MakeShoes = true,
                   MakeShield = true, MakeWeapon = true, MakeAmmo = true, MakeTrapComponent = true, MakeCrafts = true}
function O.input(job, mc, mat_token)
  if job == 'MakeCharcoal' then return 'wood' end
  if job == 'WeaveCloth' then return 'thread' end
  if job == 'PrepareMeal' then return 'cook' end
  if job == 'PrepareRawFish' then return 'fish_raw' end
  if job == 'SmeltOre' then return mat_token and ('ore:' .. mat_token) or nil end
  -- Run 11: bags of sand (economy's census `sand`), empty bags (`bags`), raw glass (`glass`)
  if job == 'MakeRawGlass' then return 'sand' end
  if job == 'CollectSand' then return 'bags' end
  if job == 'CutGlass' then return 'glass' end
  if not (O.WS[job] or WEAR_JOBS[job]) then return nil end
  if mc == 'wood' then return 'wood'
  elseif mc == 'rock' then return 'rock'
  elseif mc == 'metal' then return mat_token and ('bars:' .. mat_token) or 'bars'
  elseif mc == 'cloth' or mc == 'silk' or mc == 'yarn' then return 'cloth'
  elseif mc == 'leather' then return 'leather'
  elseif mc == 'bone' then return 'bone' end
  return nil
end

---------------------------------------------------------------- CANCEL_JOB reports (FR-10)
-- "<unit> cancels <job>: <reason>." -> job, reason (no trailing dot)
function O.cancel_parts(text)
  local s = tostring(text or '')
  local j, why = s:match('cancels ([^:]+):%s*(.-)%s*$')
  if not j then return nil end
  j = j:gsub('^[ ]+', ''):gsub('[ ]+$', '')
  why = why:gsub('%.$', '')
  if j == '' then return nil end
  return j, why
end

-- a "Needs ..." reason: the job's input is missing (DF's own words, e.g. "Needs rock", "Needs empty barrel")
function O.needs(why) return type(why) == 'string' and why:sub(1, 6):lower() == 'needs ' end

return O
