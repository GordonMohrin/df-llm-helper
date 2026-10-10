-- care (WP8): strange moods, burial and corpses, captives, hospital water, the forbidden-barrel guard,
-- the stress sampler and the naked check (DESIGN §4 RECOVERY clean-up, §5.6, §5.9-§5.11).
--   * moods: never touches the mood job (act has no job removal). It reads only what the vanilla UI
--     shows: the claimed workshop's type (its material classes, M.WS_MATS) and the moody dwarf's skill
--     sheet. It never reads job.job_items (that is what the armok tool showmood prints, DESIGN §11.4).
--     It unforbids / un-dumps items of those classes and emits MOOD_NEED when none exist (or no workshop);
--   * every item flag write needs a revealed tile (snapshot.tile) and, outside PEACE / late RECOVERY,
--     a Kern+ tile (no Kern+ yet: no writes outside clean-up time);
--   * burial: free tombs >= open corpses + margin, else PROJECT_REQUEST tombs (follow places them);
--     `burial -c` zones unzoned coffins;
--   * captives: melt-safe (a cage holding a captive is never left marked for melting), then after a
--     deadline in PEACE/late RECOVERY assigned to the manifest pit (zone_assign) or, without a pit,
--     the cage is marked for dumping so it leaves the trap tile.
-- Reads: citizens and captives by census id, dead fort members by event / corpse unit id (CONTRACTS §1.4),
-- items.other / buildings.other vectors (sliced), burrow membership, site locations.
-- Writes only through K.act (item_flag, zone_assign, run).
local json = require('dfllm.util.json')
local C = require('dfllm.util.contract')

local M = {name = 'care', every = {ticks = 1200}, on = {}}
local DAY = C.TICKS.DAY

-- mirror of config/baseline.json "care" (tests/lua/test_care.lua checks they agree)
M.DEFAULTS = {
  units_per_slice = 50, items_per_slice = 200, tomb_margin = 6, tomb_request_every = 3600,
  corpse_old = 3600, approach_r = 15, captive_deadline = 600, captive_dump = true,
  unforbid_per_need = 5, corpse_acts_per_run = 30, barrels_per_run = 20, mood_nojob_ticks = 1200,
  stress_week = 8400,
}
M.STRANGE = {Fey = true, Secretive = true, Possessed = true, Macabre = true, Fell = true}
M.FAILED = {Melancholy = true, Raving = true, Berserk = true}
-- material classes per claimed workshop (workshop_type / furnace_type name): a primary material of the
-- moods made there; the class names index M.MAT_VEC
M.WS_MATS = {
  Craftsdwarfs = {'bone', 'shell', 'rock', 'wood'}, Jewelers = {'rough', 'gems'},
  MetalsmithsForge = {'bars'}, MagmaForge = {'bars'}, Carpenters = {'wood'}, Bowyers = {'wood', 'bone'},
  Masons = {'rock'}, Mechanics = {'rock'}, Leatherworks = {'leather'}, Tanners = {'leather'},
  Clothiers = {'cloth', 'thread'}, Loom = {'thread', 'cloth'}, GlassFurnace = {'rough'},
}
M.MAT_VEC = {bone = 'CORPSEPIECE', shell = 'CORPSEPIECE', rock = 'BOULDER', wood = 'WOOD', rough = 'ROUGH',
             gems = 'SMALLGEM', bars = 'BAR', leather = 'SKIN_TANNED', cloth = 'CLOTH', thread = 'THREAD'}
-- moodable skills (df.job_skill names); the highest one on the unit sheet hints the workshop to build
M.MOOD_SKILLS = {'CARPENTRY', 'MASONRY', 'BONECARVE', 'STONECRAFT', 'WOODCRAFT', 'CUTGEM', 'ENCRUSTGEM',
                 'FORGE_WEAPON', 'FORGE_ARMOR', 'FORGE_FURNITURE', 'METALCRAFT', 'GLASSMAKER', 'LEATHERWORK',
                 'TANNER', 'CLOTHESMAKING', 'WEAVING', 'BOWYER', 'MECHANICS'}
local UNIT_COST = 4                  -- slice budget units per citizen looked at

local st = {}

local function fmt(n) return string.format('%d', math.tointeger(n) or -1) end

function M.conf(K)
  local c = type(K.cfg.baseline) == 'table' and K.cfg.baseline.care
  if type(c) ~= 'table' then return M.DEFAULTS end
  local r = {}
  for k, v in pairs(M.DEFAULTS) do r[k] = v end
  for k, v in pairs(c) do r[k] = v end
  return r
end

-- persist m.care; maps re-tagged as objects (a decoded empty map is an array, json.lua:104)
local function pstate(K)
  local p = K.persist.get('m.care')
  if type(p) ~= 'table' then
    p = {v = 2, dead = {}, deaths = {}, petitions = {}}
    K.persist.set('m.care', p)
  end
  for _, k in ipairs({'moods', 'captives', 'corpses'}) do p[k] = json.object(type(p[k]) == 'table' and p[k] or {}) end
  for _, rec in pairs(p.moods) do rec.needs = json.object(type(rec.needs) == 'table' and rec.needs or {}) end
  p.dead, p.deaths, p.petitions = p.dead or {}, p.deaths or {}, p.petitions or {}
  if type(p.announced) ~= 'table' then          -- saves before the field: every tracked death was announced
    p.announced = {}
    for i, id in ipairs(p.dead) do p.announced[i] = id end
  end
  if type(p.stress) ~= 'table' then p.stress = {since = K.now().tick, top = {}} end
  p.stress.counts = json.object(type(p.stress.counts) == 'table' and p.stress.counts or {})
  return p
end

local function count(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end

local function xyz(a, b, c)
  if type(a) == 'table' then return a.x, a.y, a.z end
  return a, b, c
end

local function item_pos(it) return xyz(dfhack.items.getPosition(it)) end     -- Lua API.txt:2055

local function kern_burrow(K)
  local name = 'Kern+'
  for n, b in pairs(K.manifest().burrows or {}) do if b.role == 'kern' then name = n end end
  local ok, b = pcall(function() return dfhack.burrows.findByName(name) end)   -- Lua API.txt:2412
  return ok and b or nil
end

-- inside the sealed interior; without a Kern+ burrow only at clean-up time (PEACE / late RECOVERY),
-- so a dead dwarf among invaders is never unforbidden (DF's forbid-dead-citizens protection)
local function inside(r, x, y, z)
  if not x then return false end
  if not r.kern then return r.clean_ok end
  local ok, yes = pcall(function() return dfhack.burrows.isAssignedTile(r.kern, {x = x, y = y, z = z}) end)  -- :2436
  return ok and yes == true
end

-- a write needs a revealed tile; snapshot.tile is the only tile read (CONTRACTS §7). No reader: no write.
local function revealed(K, x, y, z)
  if not x then return false end
  local ok, t = K.call('snapshot', 'tile', x, y, z)
  return ok == true and type(t) == 'table'
end

-- a (possibly dead) member of the fort: dead citizens keep their group membership link
-- (full-heal.lua:238-240), while getCitizens() and so K.census.u.ids drop them at once (Lua API.txt:1466).
-- Insane citizens are covered too. isOwnGroup :1480, isAnimal :1626.
-- dead_only: also isDead (:1492), so a living dwarf's severed limb is not taken for a death
function M.own_member(id, dead_only)
  local ok, yes = pcall(function()
    local u = df.unit.find(id)
    return u ~= nil and dfhack.units.isOwnGroup(u) and not dfhack.units.isAnimal(u)
           and (not dead_only or dfhack.units.isDead(u))
  end)
  return ok and yes == true
end

local function remember_dead(p, id)
  for _, x in ipairs(p.dead) do if x == id then return false end end
  p.dead[#p.dead + 1] = id
  while #p.dead > 200 do table.remove(p.dead, 1) end
  return true
end

local function approach_boxes(m)
  local boxes = {}
  for _, b in pairs(m.bridges or {}) do if b.role == 'outer' and b.fp then boxes[#boxes + 1] = b.fp end end
  for _, k in ipairs({'Z1', 'Z2'}) do
    for _, bb in ipairs((m.zones or {})[k] or {}) do boxes[#boxes + 1] = bb end
  end
  for _, kb in ipairs(m.killboxes or {}) do boxes[#boxes + 1] = kb.bbox end
  for _, e in ipairs(m.edge or {}) do boxes[#boxes + 1] = {e[1], e[2], e[3], e[1], e[2], e[3]} end
  return boxes
end

-- within r tiles horizontally of an approach box, at most one z away (line of sight for raising)
function M.near_approach(boxes, x, y, z, r)
  if not x then return false end
  for _, b in ipairs(boxes) do
    if z >= b[3] - 1 and z <= b[6] + 1 and x >= b[1] - r and x <= b[4] + r and y >= b[2] - r and y <= b[5] + r then
      return true
    end
  end
  return false
end

local function built(b)
  local ok, done = pcall(function() return b:getBuildStage() >= b:getMaxBuildStage() end)
  return not ok or done
end

local function vec(path)
  local ok, v = pcall(path)
  return ok and v or {}
end

---------------------------------------------------------------- units: stress, naked, moods
local function thoughts(u, counts)
  pcall(function()
    for _, e in ipairs(u.status.current_soul.personality.emotions) do   -- fixnaked.lua:12
      local name = df.unit_thought_type[e.thought]
      if name then counts[name] = (counts[name] or 0) + 1 end
    end
  end)
end

-- no worn ARMOR-type item (shirt, robe, dress, coat): DF's "no shirt" / uncovered stress
local function has_shirt(u)
  local worn = 2
  pcall(function() worn = df.unit_inventory_item.T_mode.Worn end)
  local armor = df.item_type.ARMOR
  for _, inv in ipairs(u.inventory) do
    if inv.mode == worn and inv.item and inv.item:getType() == armor then return true end
  end
  return false
end

-- the claimed workshop's type name, as the workshop sheet shows it (job holder, Lua API.txt:1356)
function M.mood_workshop(job)
  local ok, name = pcall(function()
    local b = dfhack.job.getHolder(job)
    if not b then return nil end
    local t = b:getType()
    if t == df.building_type.Workshop then return df.workshop_type[b:getSubtype()] end
    if t == df.building_type.Furnace then return df.furnace_type[b:getSubtype()] end
  end)
  return ok and name or nil
end

-- the material classes the claimed workshop works with, minus those already brought to the job
-- (items in the workshop are listed on its sheet)
function M.mood_mats(job, ws)
  local mats = M.WS_MATS[ws or '']
  if not mats then return nil end
  for _, ref in ipairs(job.items or {}) do
    local ok, tname = pcall(function() return df.item_type[ref.item:getType()] end)
    if ok and tname then
      for _, m in ipairs(mats) do if M.MAT_VEC[m] == tname then return nil end end   -- primary material in
    end
  end
  return mats
end

-- the highest moodable skill on the unit sheet (getNominalSkill, Lua API.txt:1816), not job.mood_skill
local function best_skill(u)
  local best, br = '', 0
  for _, name in ipairs(M.MOOD_SKILLS) do
    local ok, lv = pcall(function() return dfhack.units.getNominalSkill(u, df.job_skill[name]) end)
    if ok and type(lv) == 'number' and lv > br then best, br = name, lv end
  end
  return best
end

local function mood_seen(K, c, r, p, u, kind)
  local sid, now = fmt(u.id), K.now().tick
  local rec = p.moods[sid]
  if not rec then
    rec = {kind = kind, since = now, nojob = -1, ws = 0, needs = json.object{}}
    p.moods[sid] = rec
    K.emit('MOOD_START', 'B', string.format('strange mood (%s) unit %d', kind, u.id), {unit = u.id, kind = kind})
  end
  r.moody[sid] = true
  local job = u.job and u.job.current_job
  if not job then
    if rec.nojob < 0 then rec.nojob = now end
    if rec.ws == 0 and now - rec.nojob >= c.mood_nojob_ticks then
      rec.ws = 1
      local skill = best_skill(u)
      K.emit('MOOD_NEED', 'B', string.format('mood unit %d has no workshop (best skill %s)', u.id, skill),
             {unit = u.id, kind = kind, need = 'workshop', skill = skill})
    end
    return
  end
  rec.nojob = -1
  local ws = M.mood_workshop(job)
  local mats = M.mood_mats(job, ws)
  if not mats then return end
  r.mood_list[#r.mood_list + 1] = {sid = sid, ws = ws, mats = mats}
  for _, m in ipairs(mats) do
    if not r.need_set[m] then r.need_set[m] = true; r.need_cats[#r.need_cats + 1] = m end
  end
end

local function look_unit(K, c, r, p, u)
  local a = r.acc
  a.n = a.n + 1
  if dfhack.units.getStressCategory(u) <= 1 then           -- Lua API.txt:1904: 0 worst .. 6
    a.stressed = a.stressed + 1
    thoughts(u, a.thoughts)
  end
  if not dfhack.units.isBaby(u) and not has_shirt(u) then a.naked = a.naked + 1 end
  local kind = df.mood_type[u.mood]
  if kind and M.STRANGE[kind] then mood_seen(K, c, r, p, u, kind) end
end

local function phase_units(K, c, r, p)
  while r.left > 0 and r.idx < #r.ids do
    r.idx, r.left = r.idx + 1, r.left - UNIT_COST
    local u = df.unit.find(r.ids[r.idx])
    if u then
      local ok, err = pcall(look_unit, K, c, r, p, u)
      if not ok then K.log('warn', 'care unit %d: %s', r.ids[r.idx], tostring(err)) end
    end
  end
  if r.idx < #r.ids then return false end
  -- moods that ended (mood cleared, failed into insanity, or the unit died)
  for sid, rec in pairs(p.moods) do
    if not r.moody[sid] then
      local u = df.unit.find(math.tointeger(tonumber(sid)))
      local mood = u and df.mood_type[u.mood]
      local alive = u and not dfhack.units.isDead(u)
      if not (alive and M.STRANGE[mood]) then
        local ok = (alive and not M.FAILED[mood]) and 1 or 0
        p.moods[sid] = nil
        K.emit('MOOD_END', 'B', string.format('mood (%s) unit %s %s', rec.kind, sid, ok == 1 and 'done' or 'failed'),
               {unit = math.tointeger(tonumber(sid)), kind = rec.kind, ok = ok})
      end
    end
  end
  return true
end

---------------------------------------------------------------- corpses
local function corpse_item(K, c, r, p, it)
  local f = it.flags
  if f.in_building or f.removed or f.garbage_collect then return end    -- interred or gone
  local uid = it.unit_id
  if math.type(uid) ~= 'integer' or uid < 0 then return end
  local x, y, z = item_pos(it)
  if r.dead[uid] == nil then                  -- a death we did not see: the corpse's unit decides
    r.dead[uid] = M.own_member(uid, true)
    if r.dead[uid] then remember_dead(p, uid) end
  end
  if r.dead[uid] then                         -- a citizen: free it for burial, never dump it (ghosts)
    r.open[fmt(uid)] = true
    if (f.forbid or f.dump) and r.acts < c.corpse_acts_per_run and (r.clean_ok or inside(r, x, y, z))
       and revealed(K, x, y, z) then
      local ok = true
      if f.forbid then ok = K.act.item_flag(it.id, 'forbid', false) and ok end
      if f.dump then ok = K.act.item_flag(it.id, 'dump', false) and ok end
      if ok then r.acts = r.acts + 1 end
    end
  elseif r.clean_ok and not f.in_inventory and (f.forbid or not f.dump) and r.acts < c.corpse_acts_per_run
         and M.near_approach(r.boxes, x, y, z, c.approach_r) and revealed(K, x, y, z) then
    if f.forbid then K.act.item_flag(it.id, 'forbid', false) end
    if not f.dump and K.act.item_flag(it.id, 'dump', true) then r.acts = r.acts + 1 end
  end
end

-- stop(): optional early end of the vector
local function scan(r, getv, fn, stop)
  local v = vec(getv)
  local n = #v
  while r.left > 0 and r.idx < n do
    if stop and stop() then return true end
    local it = v[r.idx]
    r.idx, r.left = r.idx + 1, r.left - 1
    if it then
      local ok, err = pcall(fn, it)
      if not ok then r.errs, r.err = r.errs + 1, r.err or tostring(err) end
    end
  end
  return r.idx >= n
end

local function phase_corpses(K, c, r, p)
  return scan(r, function() return df.global.world.items.other.ANY_CORPSE end,
              function(it) corpse_item(K, c, r, p, it) end)
end

---------------------------------------------------------------- zones: tombs, coffins, hospital water, pit, petitions
local function well_water(K, w)
  local x, y, z = w.x1, w.y1, w.z
  local low = math.tointeger(w.bucket_z) or (z - 12)
  for zz = z - 1, math.max(low, z - 30), -1 do
    local ok, t = K.call('snapshot', 'tile', x, y, zz)
    if not ok then return true end              -- no tile reader loaded: trust the built well
    if type(t) ~= 'table' then return false end -- hidden or invalid below the well
    if t.c == 'w' or t.c == '~' then return true end
    if t.c ~= '_' then return false end         -- shaft blocked before reaching water
  end
  return false
end

-- hospital zones: civzones linked to a hospital location. There is no ZONE_HOSPITAL vector in 53.16;
-- quickfort links zone.location_id to a site abstract building (internal/quickfort/zone.lua:305-350).
local function hospital_zones()
  local ids, out = {}, {}
  local site = dfhack.world.getCurrentSite()                     -- Lua API.txt:2205
  local htype = df.abstract_building_type.HOSPITAL
  for _, l in ipairs(site and site.buildings or {}) do
    if l:getType() == htype then ids[l.id] = true end
  end
  if next(ids) == nil then return out end
  for _, zn in ipairs(df.global.world.buildings.other.ANY_ZONE) do
    if ids[zn.location_id] then out[#out + 1] = zn end
  end
  return out
end

local function phase_zones(K, c, r, p)
  local other = df.global.world.buildings.other
  local free = 0
  for _, zn in ipairs(vec(function() return other.ZONE_TOMB end)) do
    local active = true
    pcall(function() active = zn.spec_sub_flag.active end)   -- entomb.lua:56
    if zn.assigned_unit_id == -1 and active then free = free + 1 end
  end
  r.tombs_free = free
  local unzoned, tomb = 0, df.civzone_type and df.civzone_type.Tomb
  for _, cof in ipairs(vec(function() return other.COFFIN end)) do
    local zoned = not built(cof)               -- a planned coffin cannot be zoned yet
    for _, zn in ipairs(cof.relations or {}) do if zn.type == tomb then zoned = true end end   -- entomb.lua:66
    if not zoned then unzoned = unzoned + 1 end
  end
  if unzoned > 0 then K.act.run('burial', '-c') end            -- tools/burial.txt: citizens-only tombs
  local hw = 0
  for _, zn in ipairs(vec(hospital_zones)) do
    for _, w in ipairs(vec(function() return other.WELL end)) do
      if hw == 0 and w.z == zn.z and w.x1 >= zn.x1 - 1 and w.x1 <= zn.x2 + 1 and w.y1 >= zn.y1 - 1
         and w.y1 <= zn.y2 + 1 and well_water(K, w) then hw = 1 end
    end
  end
  r.hosp_water = hw
  local pit = K.manifest().pit
  if pit then
    local pond = df.civzone_type and df.civzone_type.Pond
    local ok, zs = pcall(function() return dfhack.buildings.findCivzonesAt({x = pit[1], y = pit[2], z = pit[3]}) end)  -- :2488
    for _, zn in ipairs(ok and zs or {}) do if zn.type == pond then r.pit = zn.id; break end end
  end
  local known = {}
  for _, id in ipairs(p.petitions) do known[id] = true end
  for _, id in ipairs(vec(function() return df.global.plotinfo.petitions end)) do
    if not known[id] then
      local kind = 'petition'
      pcall(function() kind = df.agreement_details_type[df.agreement.find(id).details[0].type] or kind end)
      p.petitions[#p.petitions + 1] = id
      K.emit('PETITION', 'B', 'petition: ' .. kind, {kind = kind, id = id})
    end
  end
  while #p.petitions > 50 do table.remove(p.petitions, 1) end
  return true
end

---------------------------------------------------------------- captives
local function in_trap(item)
  local h = dfhack.items.getHolderBuilding(item)            -- Lua API.txt:2047
  if not h then return false end
  local ok, yes = pcall(function() return df.building_trapst:is_instance(h) end)
  return ok and yes == true
end

local function phase_captives(K, c, r, p)
  local cu = K.census.u
  if type(cu) ~= 'table' or type(cu.caged) ~= 'table' then return true end
  local now, seen = K.now().tick, {}
  for _, id in ipairs(cu.caged) do
    local sid = fmt(id)
    seen[sid] = true
    local u = df.unit.find(id)
    local rec = p.captives[sid]
    if not rec then
      rec = {t = now, act = ''}
      p.captives[sid] = rec
      local race = ''
      pcall(function() race = dfhack.units.getRaceName(u) end)
      K.emit('CAPTURE', 'B', string.format('captive %d (%s)', id, race), {unit = id, race = race})
    end
    local cage = u and dfhack.units.getContainer(u)        -- Lua API.txt:1716
    if cage and (rec.err or 0) < 3 then                     -- give up after 3 refused writes
      local ok = true
      if cage.flags.melt then ok = K.act.item_flag(cage.id, 'melt', false) end   -- melting frees the captive
      if ok and rec.act == '' and r.clean_ok and now - rec.t >= c.captive_deadline then
        if r.pit then
          ok = K.act.zone_assign(r.pit, id)
          if ok then rec.act = 'pit' end
        elseif c.captive_dump and in_trap(cage) and not cage.flags.dump then
          ok = K.act.item_flag(cage.id, 'dump', true)
          if ok then rec.act = 'dump' end
        end
      end
      if not ok then rec.err = (rec.err or 0) + 1 end
    end
  end
  for sid in pairs(p.captives) do if not seen[sid] then p.captives[sid] = nil end end
  return true
end

---------------------------------------------------------------- forbidden-barrel guard (Run 5)
local function barrel(K, c, r, it)
  local f = it.flags
  if not f.forbid or f.trader or f.in_building or r.fixed >= c.barrels_per_run then return end
  local food = false
  local dt, ft = df.item_type.DRINK, df.item_type.FOOD
  for _, ci in ipairs(dfhack.items.getContainedItems(it) or {}) do      -- Lua API.txt:2043
    local t = ci:getType()
    if t == dt or t == ft then food = true; break end
  end
  if not food then return end
  local x, y, z = item_pos(it)
  if inside(r, x, y, z) and revealed(K, x, y, z) and K.act.item_flag(it.id, 'forbid', false) then
    r.fixed = r.fixed + 1
  end
end

local function phase_barrels(K, c, r, p)
  local inv = K.census.i
  if type(inv) ~= 'table' or ((inv.drink_forb or 0) + (inv.food_forb or 0)) == 0 then return true end
  return scan(r, function() return df.global.world.items.other.BARREL end, function(it) barrel(K, c, r, it) end)
end

---------------------------------------------------------------- mood materials
local BUSY = {'in_building', 'in_job', 'trader', 'removed', 'garbage_collect', 'construction', 'hostile'}
local function need_item(K, c, r, cat, it)
  if cat == 'bone' or cat == 'shell' then
    local cf = it.corpse_flags
    if not cf or cf.unbutchered or not cf[cat] then return end
  elseif cat == 'bars' and it.mat_type ~= 0 then return          -- metal bars only (coal is fuel)
  end
  local f = it.flags
  for _, k in ipairs(BUSY) do if f[k] then return end end
  if not f.forbid and not f.dump then r.avail = r.avail + 1; return end
  local x, y, z = item_pos(it)
  if r.fixes >= c.unforbid_per_need or not inside(r, x, y, z) or not revealed(K, x, y, z) then return end
  local ok = true
  if f.forbid then ok = K.act.item_flag(it.id, 'forbid', false) and ok end
  if f.dump then ok = K.act.item_flag(it.id, 'dump', false) and ok end
  if ok then r.fixes, r.avail = r.fixes + 1, r.avail + 1 end
end

-- one class at a time, stopping at the first usable item; then MOOD_NEED for every mood whose classes
-- all came up empty (once per mood and class set)
local function phase_needs(K, c, r, p)
  while r.nci <= #r.need_cats do
    local cat = r.need_cats[r.nci]
    if r.idx == 0 then r.avail, r.fixes = 0, 0 end
    local vname = M.MAT_VEC[cat]
    local done = scan(r, function() return df.global.world.items.other[vname] end,
                      function(it) need_item(K, c, r, cat, it) end, function() return r.avail > 0 end)
    if not done then return false end
    r.cat_avail[cat] = r.avail
    r.nci, r.idx = r.nci + 1, 0
  end
  for _, m in ipairs(r.mood_list) do
    local any = false
    for _, cat in ipairs(m.mats) do if (r.cat_avail[cat] or 0) > 0 then any = true end end
    local rec = p.moods[m.sid]
    local need = table.concat(m.mats, '/')
    if not any and rec and rec.needs[need] == nil then
      rec.needs[need] = 1
      K.emit('MOOD_NEED', 'B', string.format('mood unit %s (%s) needs %s: none available', m.sid, m.ws, need),
             {unit = math.tointeger(tonumber(m.sid)), kind = rec.kind, need = need, ws = m.ws})
    end
  end
  return true
end

---------------------------------------------------------------- run, finish
local PHASES = {phase_units, phase_corpses, phase_zones, phase_captives, phase_barrels, phase_needs}

local function new_run(K, c, p)
  local cu = K.census.u
  local ids = {}
  for _, id in ipairs(type(cu) == 'table' and cu.ids or {}) do ids[#ids + 1] = id end
  local dead = {}
  for _, id in ipairs(p.dead) do dead[id] = true end
  local mode, now = K.mode(), K.now().tick
  return {ph = 1, idx = 0, left = 0, ids = ids, have_units = type(cu) == 'table' and type(cu.ids) == 'table',
          acc = {n = 0, stressed = 0, naked = 0, thoughts = {}}, moody = {}, need_set = {}, need_cats = {}, nci = 1,
          mood_list = {}, cat_avail = {},
          dead = dead, open = {}, acts = 0, fixed = 0, avail = 0, fixes = 0, errs = 0,
          clean_ok = mode == 'PEACE' or (mode == 'RECOVERY' and now - K.mode_since() >= DAY),
          boxes = approach_boxes(K.manifest()), kern = kern_burrow(K)}
end

local function top5(counts)
  local list = {}
  for k, n in pairs(counts) do list[#list + 1] = {k, n} end
  table.sort(list, function(a, b) return a[2] > b[2] or (a[2] == b[2] and a[1] < b[1]) end)
  local r = {}
  for i = 1, math.min(5, #list) do r[i] = list[i] end
  return r
end

local function finish(K, c, r, p)
  local now = K.now().tick
  -- open citizen corpses: first seen -> age
  for sid in pairs(p.corpses) do if not r.open[sid] then p.corpses[sid] = nil end end
  local open, old = 0, 0
  for sid in pairs(r.open) do
    p.corpses[sid] = p.corpses[sid] or now
    open = open + 1
    if now - p.corpses[sid] >= c.corpse_old then old = old + 1 end
  end
  local ghosts = 0
  for _, id in ipairs(p.dead) do
    local u = df.unit.find(id)
    if u and dfhack.units.isGhost(u) then ghosts = ghosts + 1 end      -- Lua API.txt:1508
  end
  -- tombs: free >= open corpses + margin; ask only once the core exists or somebody is unburied
  local need = open + c.tomb_margin - r.tombs_free
  local core = (K.manifest().zones or {}).Z4 ~= nil
  if need > 0 and (core or open > 0) and (p.tomb_req == nil or now - p.tomb_req >= c.tomb_request_every) then
    p.tomb_req = now
    K.emit('PROJECT_REQUEST', 'B', string.format('tombs: %d free < %d corpses + %d', r.tombs_free, open, c.tomb_margin),
           {tpl = 'tombs', n = need, why = 'tombs_free'})
  end
  -- weekly top stressors (persisted for the brief; see contract notes)
  for k, n in pairs(r.acc.thoughts) do p.stress.counts[k] = (p.stress.counts[k] or 0) + n end
  if now - (p.stress.since or now) >= c.stress_week then
    p.stress.top, p.stress.since = top5(p.stress.counts), now
    p.stress.counts = json.object{}
    local parts = {}
    for _, e in ipairs(p.stress.top) do parts[#parts + 1] = e[1] .. '=' .. fmt(e[2]) end
    K.log('info', 'top stressors this week: %s', table.concat(parts, ' '))
  end
  if r.errs > 0 then K.log('warn', 'care: %d unreadable items (%s)', r.errs, tostring(r.err)) end
  local prev = st.out or {}
  local a = r.acc
  st.out = {stressed_pct = r.have_units and (a.n > 0 and a.stressed * 100 // a.n or 0) or (prev.stressed_pct or 0),
            naked = r.have_units and a.naked or (prev.naked or 0), ghosts = ghosts, corpses_old = old,
            tombs_free = r.tombs_free or 0, moods = count(p.moods), hosp_water = r.hosp_water or 0}
  K.persist.touch('m.care')
end

---------------------------------------------------------------- module
function M.init(K)
  st = {run = nil}
  pstate(K)
end

function M.step(K, budget, ctx)
  local c = M.conf(K)
  local p = pstate(K)
  if not (ctx and ctx.cont) or not st.run then st.run = new_run(K, c, p) end
  local r = st.run
  r.left = c.items_per_slice
  while r.ph <= #PHASES do
    if not PHASES[r.ph](K, c, r, p) then return 'more' end
    r.ph, r.idx = r.ph + 1, 0
    if r.left <= 0 then return 'more' end
  end
  st.run = nil
  finish(K, c, r, p)
end

-- citizen deaths: DEATH (B) each, DEATHS_3PLUS (A) at 3 within a day
-- classified from the dead unit itself: the census (getCitizens) may already have dropped it, and
-- insane citizens were never in it
M.on.UNIT_DEATH = function(K, ev)
  local id, cu = ev.unit, K.census.u
  if math.type(id) ~= 'integer' then return end
  local citizen = M.own_member(id)
  if not citizen then
    for _, x in ipairs(type(cu) == 'table' and cu.ids or {}) do if x == id then citizen = true; break end end
  end
  if not citizen then return end
  local p = pstate(K)
  local now = ev.tick or K.now().tick
  for _, x in ipairs(p.announced) do if x == id then return end end   -- DEATH once per unit
  p.announced[#p.announced + 1] = id
  while #p.announced > 200 do table.remove(p.announced, 1) end
  remember_dead(p, id)              -- a corpse scan may have tracked it already
  local cause = 'unknown'
  pcall(function() cause = df.death_type[df.unit.find(id).counters.death_cause] or cause end)  -- deathcause.lua:38
  K.emit('DEATH', 'B', string.format('citizen %d died (%s)', id, cause), {unit = id, citizen = 1, cause = cause})
  local recent = {}
  for _, d in ipairs(p.deaths) do if now - d[1] < DAY then recent[#recent + 1] = d end end
  recent[#recent + 1] = {now, id}
  p.deaths = recent
  if #recent >= 3 and (p.last_3plus == nil or now - p.last_3plus >= DAY) then
    p.last_3plus = now
    local ids = {}
    for _, d in ipairs(recent) do ids[#ids + 1] = d[2] end
    K.emit('DEATHS_3PLUS', 'A', string.format('%d citizens died within a day', #recent), {n = #recent, ids = ids})
  end
  K.persist.touch('m.care')
end

function M.state(K)
  local o = st.out
  if not o then return {} end
  return {care = {stressed_pct = math.max(0, math.min(100, o.stressed_pct)), naked = o.naked, ghosts = o.ghosts,
                  corpses_old = o.corpses_old, tombs_free = o.tombs_free, moods = o.moods},
          stock = {hosp_water = o.hosp_water}}
end

return M
