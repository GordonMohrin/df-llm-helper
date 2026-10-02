-- claude/arbeit start|stop|once - permanent routine: keeps workshops busy (the player's rule:
-- as soon as workers have nothing to do, new orders immediately). Uses only workshop tasks + manager orders.
local util = reqscript('claude/util')
if not util.require_fort() then return end
local cfg = reqscript('claude/config')
local bh = reqscript('claude/bauhelp')
local repeatUtil = require('repeat-util')
local workshops = require('dfhack.workshops')
local json = require('json')
local KEY = 'claude-arbeit'
local INTERVAL = 1500
local cmd = ({ ... })[1] or 'once'
local rot = rot or {}

local function stock()
  local s = {}
  local function add(k, n) s[k] = (s[k] or 0) + n end
  for _, it in ipairs(df.global.world.items.all) do
    local f = it.flags
    if not (f.forbid or f.trader or f.owned or f.garbage_collect or f.removed or f.rotten or f.in_inventory or f.construction or f.dump) then
      local t = df.item_type[it:getType()]
      local n = it.stack_size
      if t == 'THREAD' then
        local mi = dfhack.matinfo.decode(it)
        if mi and mi:toString():find('silk') and not f.spider_web then add('silk', n) end
      elseif t == 'WOOD' then if not f.in_building and bh.item_reachable(it) then add('wood', n) end -- Y88: only reachable wood (cavern behind the barrier does not count)
      elseif t == 'BED' then if not f.in_building then add('beds', 1) end
      elseif t == 'BUCKET' then if not f.in_building then add('buckets', 1) end
      elseif t == 'BARREL' then
        if #dfhack.items.getContainedItems(it) == 0 then add('barrels_empty', 1) end
      elseif t == 'CAGE' then
        -- empty = without items AND without a captive unit (general_ref_contains_unitst), not in a building (trap/depot)
        local hasunit = false
        for _, r in ipairs(it.general_refs) do
          if df.general_ref_contains_unitst:is_instance(r) then hasunit = true break end
        end
        if not hasunit and #dfhack.items.getContainedItems(it) == 0 and not it.flags.in_building then add('cages', 1) end
      elseif t == 'BOULDER' then
        add('boulder', n)
        -- "plain" = stone without ore (ore chunks stay for smelting/erkundung)
        local mi = dfhack.matinfo.decode(it)
        local ore = mi and mi.inorganic and #mi.inorganic.metal_ore.mat_index > 0
        if not ore then add('boulder_plain', n) end
      elseif t == 'FIGURINE' or t == 'AMULET' or t == 'SCEPTER' or t == 'CROWN' or t == 'RING' or t == 'EARRING' or t == 'BRACELET' or t == 'TOTEM' or t == 'CRAFTS' then
        add('crafts', n) -- Crafts = trade goods (caravan)
      elseif t == 'BLOCKS' then add('blocks', n)
      elseif t == 'SEEDS' then add('seeds', n)
      elseif t == 'TRAPPARTS' then add('mech', n)
      elseif t == 'BIN' then add('bins', n)
      elseif t == 'BOX' then add('boxes', n); if not f.in_building then add('boxes_free', n) end
      elseif t == 'TABLE' then if not f.in_building then add('tables', n) end
      elseif t == 'CHAIR' then if not f.in_building then add('chairs', n) end
      elseif t == 'CABINET' then if not f.in_building then add('cabinets', n) end
      elseif t == 'STATUE' then add('statues', n)
      elseif t == 'COFFIN' then add('coffins', n)
      elseif t == 'DOOR' then add('doors', n)
      elseif t == 'WEAPONRACK' then add('racks', n)
      elseif t == 'ARMORSTAND' then add('astands', n)
      elseif t == 'ROUGH' then add('rough', n)
      elseif t == 'CLOTH' then
        add('cloth', n)
        local mi = dfhack.matinfo.decode(it)
        if mi and mi:toString():find('silk') then add('silkcloth', n) end
      elseif t == 'BAR' then
        add('bars', n)
        local mi = dfhack.matinfo.decode(it)
        if mi and mi:toString():find('coal') then add('charcoal', n) end
      elseif t == 'CORPSEPIECE' or t == 'BONE' then
        local mi = dfhack.matinfo.decode(it)
        if mi and mi:toString():find('bone') then add('bone', n) end
      end
    end
  end
  return s
end

local function addjob(b, defs, name)
  local def
  for _, d in pairs(defs) do if d.name:lower() == name then def = d end end
  if not def then return false end
  local job = df.job:new()
  job.pos = { x = b.centerx, y = b.centery, z = b.z }
  if def.job_fields then job:assign(def.job_fields) end
  for _, filter in ipairs(def.items or {}) do
    local f = copyall(filter); f.new = true
    job.job_items.elements:insert('#', f)
  end
  local ref = df.general_ref_building_holderst:new()
  ref.building_id = b.id
  job.general_refs:insert('#', ref)
  b.jobs:insert('#', job)
  dfhack.job.linkIntoWorld(job, true)
  return true
end

-- Own workshop tasks (custom_defs): crafts from stone run since 30.09. (Y81) as a standing manager order (claude/orders), no longer as a direct job.
local custom_defs = {}

-- Workshop plan (run 3: NO fixed building IDs anymore): {building kind, minimum queue, list {task, condition(stock)}}.
-- Building kind = name from df.workshop_type (Masons, Carpenters, Mechanics, Jewelers ...) or df.furnace_type (WoodFurnace, Smelter ...);
-- applies to EVERY finished workshop of this kind. Task names as in `claude/task list`.
local function B(s, n) return (s.boulder or 0) >= n end
local plan = {
  -- Since 30.09. (Y81, scope wirtschaft) stonemason/mechanic/craftsdwarf/carpenter/jeweler cutting run as STANDING manager orders with
  -- conditions (lua/claude/orders.lua, `claude/orders status`). Direct jobs here would order twice -> removed.
  -- Remains: cutting gems (the manager demands a gem material for CutGems; the direct job is proven).
  -- Charcoal/smelting/smithing: scope material (claude/material).
  -- Run 5 D9: raw gem reserve 4 for strange moods (gem cutter mood failed at raw gem 0): cut only from >= 5
  { 'Jewelers', 6, { { 'cut gems', function(s) return (s.rough or 0) >= 5 end } } },
}

-- finished workshops/furnaces of a kind (lookup instead of fixed ID)
local function buildings_of(kind)
  local res = {}
  for _, b in ipairs(df.global.world.buildings.all) do
    local t = b:getType()
    local name
    if t == df.building_type.Workshop then name = df.workshop_type[b:getSubtype()]
    elseif t == df.building_type.Furnace then name = df.furnace_type[b:getSubtype()] end
    if name == kind and b:getBuildStage() >= b:getMaxBuildStage() then res[#res + 1] = b end
  end
  return res
end

-- (Manager orders: no longer here, but in claude/orders - catalog with conditions.)
local cycle = 0

local defmap = { MakeArmor = 'armor', MakePants = 'pants', MakeShoes = 'shoes', MakeGloves = 'gloves', MakeWeapon = 'weapons', MakeAmmo = 'ammo' }
local function subidx(o)
  if not o.sub then return nil end
  for i, d in ipairs(df.global.world.raws.itemdefs[defmap[o.job]]) do
    if d.id == o.sub then return d.subtype end
  end
end

local function order_open(o)
  local si = subidx(o)
  for _, mo in ipairs(df.global.world.manager_orders.all) do
    if df.job_type[mo.job_type] == o.job and mo.amount_left > 0 and (not o.sub or mo.item_subtype == si) then
      if o.mc and mo.material_category[o.mc] then return true end
      if o.mat and mo.mat_type == 0 and mo.mat_index == -1 then return true end
    end
  end
  return false
end

-- Manager/broker/bookkeeper NEVER work (run 2: a manager with 87 labors did not validate manager orders). Every pass: labors off.
local function clear_office_labors()
  local n = 0
  for _, u in ipairs(dfhack.units.getCitizens()) do
    local np = dfhack.units.getNoblePositions(u)
    for _, p in ipairs(np or {}) do
      local code = p.position.code
      if code == 'MANAGER' or code == 'BOOKKEEPER' then   -- Run 5 D3: do not clear BROKER every time (handel prep: nolabors once on appointment)
        for i = 0, #u.status.labors - 1 do
          if u.status.labors[i] then u.status.labors[i] = false; n = n + 1 end
        end
        break
      end
    end
  end
  return n
end

-- Economy (run 3, Y76): smoothing/engraving as work occupation + room value. {smoothing CSV, engraving CSV, cursor}
-- Engraving only makes sense once smoothed; quickfort skips unsmoothed tiles, repeated runs are harmless.
local SMOOTH_ENGRAVE = cfg.SMOOTH_ENGRAVE or {}   -- Run 4: from config (run 3: r3w_* blueprints for Razordrums coordinates, no longer valid here)

-- Carpenter orders need logs; without wood ALL dwarves with the CARPENTER labor abort them ("Needs logs", cancel loop).
-- Without wood: suspend orders; as soon as wood is available, release again.
local function gate_carpenters(s)
  local haswood = (s.wood or 0) >= 1
  local n = 0
  for _, b in ipairs(buildings_of('Carpenters')) do
    local del = {}
    for _, j in ipairs(b.jobs) do
      if not j.flags.working then
        if not haswood then del[#del + 1] = j   -- Run 5 D3: REMOVE jobs without wood (MakeBucket x4 hung suspended)
        elseif j.flags.suspend then j.flags.suspend = false; n = n + 1 end
      end
    end
    for _, j in ipairs(del) do
      if pcall(dfhack.job.removeJob, j) then n = n + 1 else j.flags.suspend = true end
    end
  end
  return n
end

-- Utilization (Y77, 30.09.): cage trap load jobs ("Load cage trap: Needs empty cage") are accepted by EVERY dwarf with the MECHANIC labor and
-- aborted (game log: ~160 aborts/3000 lines, dwarves walk across the fort and then stand "idle"). Without a free cage: suspend.
local function gate_cagetraps(s)
  local free = (s.cages or 0) >= 1
  local n = 0
  for _, b in ipairs(df.global.world.buildings.all) do
    if b:getType() == df.building_type.Trap and b.trap_type == df.trap_type.CageTrap then
      for _, j in ipairs(b.jobs) do
        if j.job_type == df.job_type.LoadCageTrap and not j.flags.working then
          local want = not free
          if j.flags.suspend ~= want then j.flags.suspend = want; n = n + 1 end
        end
      end
    end
  end
  return n
end

-- Y88: fuel gate. Without reachable wood 'Make charcoal: Needs logs' aborts (1120 aborts/4000 game log lines), without charcoal
-- 'Smelt ... / Forge ...: Needs refined coal' (215 + 192): every dwarf with a metal/furnace labor tries them in turn. Suspend jobs as long as the input is missing.
local FORGE_JOBS = { MakeWeapon = true, MakeArmor = true, MakeShield = true, MakePants = true, MakeHelm = true, MakeShoes = true, MakeGloves = true,
  MakeCage = true, MakeAmmo = true, MakeChain = true, MakeBlocks = false }
local function gate_fuel(s)
  local n = 0
  local haswood = (s.wood or 0) >= 1
  local hascoal = ((s.charcoal or 0) >= 1)
  local function gate(b, want)
    for _, j in ipairs(b.jobs) do
      if not j.flags.working and j.flags.suspend ~= want then j.flags.suspend = want; n = n + 1 end
    end
  end
  for _, b in ipairs(buildings_of('WoodFurnace')) do
    for _, j in ipairs(b.jobs) do
      if j.job_type == df.job_type.MakeCharcoal and not j.flags.working and j.flags.suspend == haswood then j.flags.suspend = not haswood; n = n + 1 end
    end
  end
  for _, b in ipairs(buildings_of('Smelter')) do gate(b, not hascoal) end
  for _, b in ipairs(buildings_of('MetalsmithsForge')) do
    for _, j in ipairs(b.jobs) do
      if FORGE_JOBS[df.job_type[j.job_type]] and not j.flags.working and j.flags.suspend == hascoal then j.flags.suspend = not hascoal; n = n + 1 end
    end
  end
  return n
end

-- Dead dig jobs: 'Dig' on floor/empty/sapling (tile already mined) -> "Dig: Inappropriate dig square", the only pick carrier walks
-- 40 tiles, aborts, the job is recreated (52 aborts/3000 lines). Remove without workers (like 'delete order' in the task menu).
local BAD_DIG = { FLOOR = true, EMPTY = true, SAPLING = true, SHRUB = true, TWIG = true }
local function prune_dead_digs()
  local dead = {}
  local l = df.global.world.jobs.list.next
  while l do
    local j = l.item
    if j.job_type == df.job_type.Dig and not dfhack.job.getWorker(j) then
      local tt = dfhack.maps.getTileType(j.pos)
      local sh = tt and df.tiletype.attrs[tt].shape
      if sh and BAD_DIG[df.tiletype_shape[sh]] then dead[#dead + 1] = j end
    end
    l = l.next
  end
  for _, j in ipairs(dead) do pcall(dfhack.job.removeJob, j) end
  -- Y88: remove duplicate dig jobs on the same tile (re-designation) -> no more 'Inappropriate dig square' aborts
  local dup = 0
  local okd, r = pcall(bh.dedupe_dig_jobs)
  if okd and r then dup = r end
  return #dead + dup
end

-- Utilization (Y77): basic labors. Smoothing (SmoothFloor/SmoothWall/CarveFortification) needs STONECUTTER (skill CUT_STONE), engraving ENGRAVER.
-- The "Everybody" work details (Stonecutters/Engravers) only take effect when the group is edited in the menu, not on existing dwarves ->
-- miners without a pick (2481, 2524) and planter 2197 had no STONECUTTER and stood idle with 128 open smoothing jobs. Only add, never remove.
-- Exception: pick carriers as long as dig jobs are open (stay pure miners).
-- Y81 (wirtschaft): production labors for the manager orders (claude/orders): carpenter, stonemason/carver, craftsdwarf (stone/bone/wood), jeweler, mechanic.
local BASE_LABORS = { 'CLEAN', 'STONECUTTER', 'ENGRAVER', 'MASON', 'BUILD_ROAD', 'BUILD_CONSTRUCTION',
  'CARPENTER', 'STONE_CARVER', 'STONE_CRAFT', 'BONE_CARVE', 'WOOD_CRAFT', 'CUT_GEM', 'ENCRUST_GEM', 'MECHANIC' }
local function sync_labors()
  local opendig_n = 0
  local l = df.global.world.jobs.list.next
  while l do
    if l.item.job_type == df.job_type.Dig and not dfhack.job.getWorker(l.item) then opendig_n = opendig_n + 1 end
    l = l.next
  end
  local opendig = opendig_n > 0
  local n = 0
  -- Run 5 D3 (utilization/dig jam): pick carriers are pure miners as long as >= 5 dig jobs are open (otherwise they brew/plant/haul and 80 jobs lie around);
  -- with <= 1 open dig jobs they get the labors back. Non-pick carriers (also squad members without a pick) take over brewing/planting/hauling.
  do
    local STRIP = { 'BREWER', 'COOK', 'PLANT', 'HERBALIST', 'FISH', 'HAUL_STONE', 'HAUL_FOOD', 'HAUL_REFUSE', 'HAUL_ITEM', 'HAUL_FURNITURE', 'HAUL_BODY',
      'HAUL_WATER', 'HAUL_TRADE', 'STONE_CRAFT', 'STONE_CARVER', 'MASON', 'CARPENTER', 'MECHANIC', 'CLEAN', 'WOOD_CRAFT', 'BONE_CARVE', 'CUT_GEM',
      'ENCRUST_GEM', 'BUILD_CONSTRUCTION', 'BUILD_ROAD' }
    local strip, restore = opendig_n >= 5, opendig_n <= 1
    if strip or restore then
      for _, u in ipairs(dfhack.units.getCitizens()) do
        if dfhack.units.isAdult(u) and u.status.labors[df.unit_labor.MINE] then
          local picker = false
          for _, ii in ipairs(u.inventory) do
            local it = ii.item
            if it and it:getType() == df.item_type.WEAPON and it.subtype and it.subtype.id == 'ITEM_WEAPON_PICK' then picker = true end
          end
          local office = false
          for _, p in ipairs(dfhack.units.getNoblePositions(u) or {}) do
            local c = p.position.code
            if c == 'MANAGER' or c == 'BOOKKEEPER' or c == 'BROKER' then office = true end
          end
          if picker and not office then
            for _, name in ipairs(STRIP) do
              local L = df.unit_labor[name]
              if L and strip and u.status.labors[L] then u.status.labors[L] = false; n = n + 1
              elseif L and restore and not u.status.labors[L] then u.status.labors[L] = true; n = n + 1 end
            end
          end
        end
      end
    end
  end
  -- Do not undermine work details with 'OnlySelectedDoesThis' (e.g. Stonecutters/Engravers/Miners): labor only for members
  local lim = {}
  local wds = df.global.plotinfo.labor_info.work_details
  for i = 0, #wds - 1 do
    local d = wds[i]
    for L = 0, #d.allowed_labors - 1 do
      if d.allowed_labors[L] then
        lim[L] = lim[L] or { any = false, members = {} }
        if d.flags.mode == df.work_detail_mode.EverybodyDoesThis then lim[L].any = true
        elseif d.flags.mode == df.work_detail_mode.OnlySelectedDoesThis then
          for j = 0, #d.assigned_units - 1 do lim[L].members[d.assigned_units[j]] = true end
        end
      end
    end
  end
  -- Enforce: Stonecutter/Engraver (coordinator decision D3, only 3747/3749 smooth/engrave so miners dig) also switch off for non-members
  -- (incl. squad 32/33) if the work detail is 'OnlySelectedDoesThis' and no 'Everybody' group enables the labor.
  for _, name in ipairs({ 'STONECUTTER', 'ENGRAVER' }) do
    local L = df.unit_labor[name]
    local lm = lim[L]
    if lm and not lm.any then
      for _, u in ipairs(dfhack.units.getCitizens()) do
        if dfhack.units.isAdult(u) and not lm.members[u.id] and u.status.labors[L] then u.status.labors[L] = false; n = n + 1 end
      end
    end
  end
  for _, u in ipairs(dfhack.units.getCitizens()) do
    if dfhack.units.isAdult(u) and u.military.squad_id < 0 then
      local office = false
      for _, p in ipairs(dfhack.units.getNoblePositions(u) or {}) do
        local c = p.position.code
        if c == 'MANAGER' or c == 'BOOKKEEPER' or c == 'BROKER' then office = true end
      end
      local picker = false
      for _, ii in ipairs(u.inventory) do
        local it = ii.item
        if it and it:getType() == df.item_type.WEAPON and it.subtype and it.subtype.id == 'ITEM_WEAPON_PICK' then picker = true end
      end
      local ruhe = false
      local okg, gs = pcall(reqscript, 'claude/gesund')
      if okg and gs and gs.is_ruhe and gs.is_ruhe(u.id) then ruhe = true end -- Stress rest (claude/gesund): labors stay off
      if not office and not ruhe and not (picker and opendig) then
        for _, name in ipairs(BASE_LABORS) do
          local L = df.unit_labor[name]
          local lm = lim[L]
          local allowed = (not lm) or lm.any or lm.members[u.id]
          if allowed and not u.status.labors[L] then u.status.labors[L] = true; n = n + 1 end
        end
      end
    end
  end
  return n
end

-- Utilization (Y77): occupation resupply. With ~7 workers and 250 fps a smoothing queue of 128 jobs is gone in <10 min -> afterwards idle.
-- If fewer than 20 free smoothing/engraving jobs are open, in the fort interior (stone/mineral floor only, reachable, without workshop/bed/door)
-- the next 40 tiles are designated for smoothing, afterwards smoothed floors without engraving for engraving (room value, trade value, skill training).
-- Designating = like in the menu (mark tile), no dig-now.
local SUP = cfg.SMOOTH_SUPPLY   -- Run 4: area from config (run 3: east wing x125..190, z141..145, batch 150 with 34 idle dwarves)
local SMOOTH_JOBS = { SmoothFloor = true, SmoothWall = true, DetailFloor = true, DetailWall = true }
local function smooth_supply()
  if not SUP then return 0, 0 end
  local open = 0
  local l = df.global.world.jobs.list.next
  while l do
    if SMOOTH_JOBS[df.job_type[l.item.job_type]] and not dfhack.job.getWorker(l.item) then open = open + 1 end
    l = l.next
  end
  if open >= SUP.min_open then return 0, open end
  local eng = {}
  for _, e in ipairs(df.global.world.event.engravings) do eng[e.pos.x .. ',' .. e.pos.y .. ',' .. e.pos.z] = true end
  local anchor = { x = SUP.ax, y = SUP.ay, z = SUP.az }
  local sm, en, smw, enw = {}, {}, {}, {}
  local NB = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
  for z = SUP.z1, SUP.z2 do
    for x = SUP.x1, SUP.x2 do
      for y = SUP.y1, SUP.y2 do
        local tt = dfhack.maps.getTileType(x, y, z)
        if tt then
          local a = df.tiletype.attrs[tt]
          local shape = df.tiletype_shape[a.shape]
          local mat = df.tiletype_material[a.material]
          local sp = df.tiletype_special[a.special]
          if (mat == 'STONE' or mat == 'MINERAL') and (shape == 'FLOOR' or shape == 'WALL') then
            local d = dfhack.maps.getTileFlags(x, y, z)
            if not d.hidden and d.flow_size == 0 and d.dig == df.tile_dig_designation.No and d.smooth == 0 and sp ~= 'TRACK' then
              local dist = math.abs(x - SUP.ax) + math.abs(y - SUP.ay) + 6 * math.abs(z - SUP.az)
              if shape == 'FLOOR' then
                local b = dfhack.buildings.findAtTile(x, y, z)
                if not b or b:getType() == df.building_type.Stockpile then
                  if sp == 'SMOOTH' then
                    if not eng[x .. ',' .. y .. ',' .. z] then en[#en + 1] = { x, y, z, dist, x, y, z } end
                  else
                    sm[#sm + 1] = { x, y, z, dist, x, y, z }
                  end
                end
              elseif sp == 'SMOOTH' or sp == 'NORMAL' then
                -- Wall: only if a walkable floor tile (no building) lies directly next to it (room/corridor wall, workable from there)
                for _, o in ipairs(NB) do
                  local nx, ny = x + o[1], y + o[2]
                  local nt = dfhack.maps.getTileType(nx, ny, z)
                  if nt and df.tiletype_shape[df.tiletype.attrs[nt].shape] == 'FLOOR' and not dfhack.maps.getTileFlags(nx, ny, z).hidden then
                    if sp == 'SMOOTH' then
                      if not eng[x .. ',' .. y .. ',' .. z] then enw[#enw + 1] = { x, y, z, dist, nx, ny, z } end
                    else
                      smw[#smw + 1] = { x, y, z, dist, nx, ny, z }
                    end
                    break
                  end
                end
              end
            end
          end
        end
      end
    end
  end
  local function byd(a, b) return a[4] < b[4] end
  table.sort(sm, byd); table.sort(en, byd); table.sort(smw, byd); table.sort(enw, byd)
  local n = 0
  local function mark(c, val)
    if n >= SUP.batch then return end
    -- reachable: for floor the tile itself, for wall the neighbor tile (c[5..7])
    if not dfhack.maps.canWalkBetween(anchor, { x = c[5], y = c[6], z = c[7] }) then return end
    local blk = dfhack.maps.getTileBlock(c[1], c[2], c[3])
    if not blk then return end
    blk.designation[c[1] % 16][c[2] % 16].smooth = val
    blk.flags.designated = true
    n = n + 1
  end
  -- Order: smooth floor, engrave floor, smooth walls, engrave walls (room value + occupation; Y81 walls added, floors were done)
  for _, c in ipairs(sm) do mark(c, 1) end
  for _, c in ipairs(en) do mark(c, 2) end
  for _, c in ipairs(smw) do mark(c, 1) end
  for _, c in ipairs(enw) do mark(c, 2) end
  return n, open
end

-- Wood (run 3): cavern 2 (z88..93) has 0 trees on the surface. If needed marks the nearest visible MATURE trees (TreeTrunkPillar)
-- for felling. NEVER mark saplings (Sapling): DF discards the flag immediately (run 3 Y76: 86 "trees" were all saplings).
-- Amphibian people (AMPHIBIAN_MAN) are avoided at >= 9 tiles distance. Only if wood is scarce and < 8 felling orders are open.
local TB = cfg.TREE_BAND   -- Run 4: { zmin, zmax, ax, ay } from config (run 3: cavern 2 z88..93, anchor shaft D)
local function designate_trees(s)
  if not TB then return 0 end
  if (s.wood or 0) >= 60 then return 0 end -- Y81: goal 60 (wood feeds beds/barrels/crafts AND material charcoal)
  local open = 0
  local l = df.global.world.jobs.list.next
  while l do
    if l.item.job_type == df.job_type.FellTree then open = open + 1 end
    l = l.next
  end
  if open >= 8 then return 0 end
  local ams = {}
  for _, u in ipairs(df.global.world.units.active) do
    if dfhack.units.isAlive(u) and df.creature_raw.find(u.race).creature_id == 'AMPHIBIAN_MAN' then ams[#ams + 1] = u.pos end
  end
  local function nearam(p)
    local m = 999
    for _, q in ipairs(ams) do m = math.min(m, math.max(math.abs(p.x - q.x), math.abs(p.y - q.y))) end
    return m
  end
  local cand = {}
  for _, p in ipairs(df.global.world.plants.all) do
    local pos = p.pos
    if TB and pos.z >= TB.zmin and pos.z <= TB.zmax and df.plant_raw.find(p.material).flags.TREE then
      local tt = dfhack.maps.getTileType(pos)
      local b = dfhack.maps.getTileBlock(pos)
      if b and tt and df.tiletype[tt] == 'TreeTrunkPillar' then
        local d = b.designation[pos.x % 16][pos.y % 16]
        if not d.hidden and d.dig == df.tile_dig_designation.No and nearam(pos) >= 9 then
          cand[#cand + 1] = { pos = pos, b = b, dist = math.abs(pos.x - TB.ax) + math.abs(pos.y - TB.ay) }
        end
      end
    end
  end
  table.sort(cand, function(x, y) return x.dist < y.dist end)
  local n = 0
  for _, c in ipairs(cand) do
    if n >= 20 then break end
    c.b.designation[c.pos.x % 16][c.pos.y % 16].dig = df.tile_dig_designation.Default
    c.b.flags.designated = true
    n = n + 1
  end
  return n
end

-- Wild plants (cavern 2, around the shaft foot z91; >= 9 tiles from the amphibian people): gathering yields brewing/cooking plants + seeds when seeds are scarce.
local GATHER = cfg.GATHER   -- Run 4: nil = no cavern gathering (run 3: r3w_gather_z91 at the shaft foot)

local function run()
  cycle = cycle + 1
  pcall(clear_office_labors)
  if cycle % 8 == 1 then
    for _, e in ipairs(cfg.ENGRAVE_BLUEPRINTS or {}) do pcall(dfhack.run_command_silent, { 'quickfort', 'run', e[1], '-c', e[2] }) end
  end
  local s = stock()
  local added = 0
  pcall(gate_carpenters, s)
  pcall(gate_cagetraps, s)
  pcall(gate_fuel, s)
  pcall(prune_dead_digs)
  pcall(sync_labors)
  pcall(smooth_supply)
  if cycle % 2 == 0 then pcall(designate_trees, s) end
  if cycle % 8 == 1 then
    for _, e in ipairs(SMOOTH_ENGRAVE) do
      pcall(dfhack.run_command_silent, { 'quickfort', 'run', e[1], '-c', e[3] })
      pcall(dfhack.run_command_silent, { 'quickfort', 'run', e[2], '-c', e[3] })
    end
  end
  if GATHER and cycle % 8 == 3 and (s.seeds or 0) < 20 then pcall(dfhack.run_command_silent, { 'quickfort', 'run', GATHER[1], '-c', GATHER[2] }) end
  -- Barrels: NOT here (run 3: owner is claude/trinken; watchdog barrel guard as fallback) -> no triple ordering, wood goes to beds/doors first.
  for _, p in ipairs(plan) do
    for _, b in ipairs(buildings_of(p[1])) do
      local defs = {}
      for _, d in pairs(workshops.getJobs(b:getType(), b:getSubtype(), b:getCustomType()) or {}) do if type(d) == 'table' and d.name then defs[#defs + 1] = d end end
      for _, d in pairs(custom_defs) do defs[#defs + 1] = d end
      local n = #p[3]
      local tries = 0
      local key = p[1] .. b.id
      while #b.jobs < p[2] and tries < n do
        rot[key] = ((rot[key] or 0) % n) + 1
        local t = p[3][rot[key]]
        if t[2](s) and addjob(b, defs, t[1]) then added = added + 1; tries = 0 else tries = tries + 1 end
      end
    end
  end
  return added, s
end

if cmd == 'start' then
  repeatUtil.scheduleEvery(KEY, INTERVAL, 'ticks', function() pcall(run) end)
  local a = run()
  util.emit({ running = true, interval = INTERVAL, added = a })
elseif cmd == 'stop' then
  repeatUtil.cancel(KEY)
  util.emit({ running = false })
elseif cmd == 'once' then
  local a, s = run()
  util.emit({ added = a, stock = s })
else
  -- unknown sub-command (typo, --help, 'status' of a script without one): usage only, no work round (BUG-407)
  util.emit({ error = 'unbekannter Befehl: ' .. tostring(cmd), usage = 'claude/arbeit start|stop|once' })
end
