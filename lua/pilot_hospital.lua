-- claude/pilot_hospital status | staff <occupation_id> <unit_id> [--apply]
-- (df-llm-helper FEATURE-004 hospital watch, LIVE-UNTESTED)
-- status: READ ONLY. One call for `python -m df_llm_helper hospital`:
--   citizens:  care labors/skills, wounds, standing, job, idle, squad, pickaxe, mood, stress, hospital zone, and the
--              care jobs that name the unit as patient (UNIT_PATIENT ref)
--   hospitals: zones with a HOSPITAL location (beds, tables, traction benches, containers, water reachable?)
--   locations: every HOSPITAL location with its staff posts (world.occupations: DOCTOR/DIAGNOSTICIAN/SURGEON/
--              BONE_DOCTOR, holder alive/adult). Addendum 02.10.2026: with no post filled the game creates NO care
--              jobs at all, whatever labors the citizens have; a post keeps pointing at a dead holder.
--   water:     wells and unforbidden drinks; reachable from each hospital zone (walk groups, own buildings/items only)
--   refuge:    claude/gefahr refuge_supply (BUG-423: drink/well/water tiles in the refuge burrow), when available
--   supplies:  cloth, thread, splints, crutches, plaster powder, soap, logs (available / forbidden)
--   gypsum:    boulders of gypsum-class stone (gypsum, alabaster, selenite, satinspar; reaction class GYPSUM) on
--              visible tiles: the only raw material for plaster powder
-- staff:  fills ONE hospital post the way the location menu does (occupation.unit_id / histfig_id +
--         unit.occupations insert; a dead holder is unlinked first). Without --apply: dry run. Refuses posts held by
--         a living unit, non-citizens, children, units in a mood, soldiers, patients and prisoners. Old values are
--         logged to tools/out/hospital-log.json. df-llm-helper sends --apply only with a register entry HOSPITAL.
local util = reqscript('claude/util')
local json = require('json')
if not util.require_fort() then return end

local a = { ... }
local cmd = a[1] or 'status'
local APPLY = false
for _, v in ipairs(a) do if v == '--apply' then APPLY = true end end

local function safe(f, d) local ok, v = pcall(f) if ok and v ~= nil then return v end return d end

local LABORS = { 'DIAGNOSE', 'SURGERY', 'BONE_SETTING', 'SUTURING', 'DRESSING_WOUNDS', 'FEED_WATER_CIVILIANS',
                 'RECOVER_WOUNDED' }
local SKILLS = { 'DIAGNOSE', 'SURGERY', 'SET_BONE', 'SUTURE', 'DRESS_WOUNDS' }
local CARE_JOBS = { GiveWater = true, GiveFood = true, GiveWater2 = true, GiveFood2 = true, DiagnosePatient = true,
                    Surgery = true, SetBone = true, Suture = true, DressWound = true, RecoverWounded = true,
                    ApplyCast = true, CleanPatient = true, PlaceInTraction = true }
local POSTS = { DOCTOR = true, DIAGNOSTICIAN = true, SURGEON = true, BONE_DOCTOR = true }
local GYPSUM = { GYPSUM = true, ALABASTER = true, SELENITE = true, SATINSPAR = true }

local function btype(b) return safe(function() return df.building_type[b:getType()] end, '?') end
local function tname(it) return safe(function() return df.item_type[it:getType()] end, '?') end
local function is_dead(u)
  if safe(function() return dfhack.units.isDead(u) end, false) then return true end
  return not safe(function() return dfhack.units.isAlive(u) end, true)
end
local function in_squad(u) return safe(function() return u.military.squad_id ~= -1 end, false) end
local function has_pick(u)
  for _, inv in ipairs(safe(function() return u.inventory end, {})) do
    local it = inv.item
    if safe(function() return it:getType() == df.item_type.WEAPON and it.subtype.skill_melee == df.job_skill.MINING end,
            false) then
      return true
    end
  end
  return false
end
local function job_of(u)
  local j = safe(function() return u.job.current_job end, nil)
  return j and safe(function() return df.job_type[j.job_type] end, '?') or nil
end
local function cant_stand(u) return safe(function() return u.status2.limbs_stand_count == 0 end, false) end
local function patient(u) return cant_stand(u) or job_of(u) == 'Rest' end
local function walk(p) return safe(function() return dfhack.maps.getWalkableGroup(p) end, 0) ~= 0 end
local function reach(p, q) return safe(function() return dfhack.maps.canWalkBetween(p, q) end, false) end

-- HOSPITAL locations of the site (abstract buildings) -> { id, zones, posts }
local function hospital_locations()
  local locs = {}
  local site = safe(function() return df.global.world.world_data.active_site[0] end, nil)
  for _, ab in ipairs(site and safe(function() return site.buildings end, {}) or {}) do
    if safe(function() return ab:getType() == df.abstract_building_type.HOSPITAL end, false) then
      locs[ab.id] = { id = ab.id, zones = 0, posts = {} }
    end
  end
  return locs
end

-- a walkable tile inside a rectangle (the zone center may be a wall or a bed)
local function tile_in(x1, y1, x2, y2, z)
  local c = xyz2pos(math.floor((x1 + x2) / 2), math.floor((y1 + y2) / 2), z)
  if walk(c) then return c end
  for x = x1, x2 do
    for y = y1, y2 do
      local p = xyz2pos(x, y, z)
      if walk(p) then return p end
    end
  end
  return c
end

-- water sources: wells (tested from the tiles around them: a well tile has no walk group) + unforbidden drinks
local function water_points()
  local pts, wells, drinks = {}, 0, 0
  for _, w in ipairs(safe(function() return df.global.world.buildings.other.WELL end, {})) do
    wells = wells + 1
    for dx = -1, 1 do
      for dy = -1, 1 do
        local p = xyz2pos(w.centerx + dx, w.centery + dy, w.z)
        if (dx ~= 0 or dy ~= 0) and walk(p) then pts[#pts + 1] = p end
      end
    end
  end
  for _, it in ipairs(safe(function() return df.global.world.items.other.DRINK end, {})) do
    local f = it.flags
    if not (f.forbid or f.trader or f.removed or f.garbage_collect or f.foreign) then
      drinks = drinks + safe(function() return it:getStackSize() end, 1)
      if #pts < 80 then
        local x, y, z = dfhack.items.getPosition(it)
        if x then pts[#pts + 1] = xyz2pos(x, y, z) end
      end
    end
  end
  return pts, wells, drinks
end

local function hospitals(locs, wpts)
  local out = {}
  for _, z in ipairs(safe(function() return df.global.world.buildings.other.ACTIVITY_ZONE end, {})) do
    local loc = safe(function() return z.location_id end, -1)
    if locs[loc] then
      locs[loc].zones = locs[loc].zones + 1
      local h = { id = z.id, x1 = z.x1, y1 = z.y1, x2 = z.x2, y2 = z.y2, z = z.z, location = loc, beds = 0, tables = 0,
                  traction = 0, containers = 0 }
      for _, b in ipairs(df.global.world.buildings.all) do
        if b.z == z.z and b.centerx >= z.x1 and b.centerx <= z.x2 and b.centery >= z.y1 and b.centery <= z.y2 then
          local t = btype(b)
          if t == 'Bed' then h.beds = h.beds + 1
          elseif t == 'Table' then h.tables = h.tables + 1
          elseif t == 'TractionBench' then h.traction = h.traction + 1
          elseif t == 'Box' or t == 'Cabinet' then h.containers = h.containers + 1 end
        end
      end
      local p = tile_in(z.x1, z.y1, z.x2, z.y2, z.z)
      h.water_reach = false
      for _, q in ipairs(wpts) do
        if reach(p, q) then h.water_reach = true break end
      end
      out[#out + 1] = h
    end
  end
  return out
end

local function inside(p, hs)
  for _, h in ipairs(hs) do
    if p.z == h.z and p.x >= h.x1 and p.x <= h.x2 and p.y >= h.y1 and p.y <= h.y2 then return h.id end
  end
  return nil
end

-- patient id -> care jobs that name him (UNIT_PATIENT ref), and job counts
local function care_jobs()
  local per, counts = {}, {}
  local l = safe(function() return df.global.world.jobs.list.next end, nil)
  while l do
    local j = l.item
    local n = j and safe(function() return df.job_type[j.job_type] end, nil)
    if n and CARE_JOBS[n] then
      counts[n] = (counts[n] or 0) + 1
      local ref = safe(function() return dfhack.job.getGeneralRef(j, df.general_ref_type.UNIT_PATIENT) end, nil)
      local pid = ref and safe(function() return ref.unit_id end, nil)
      if pid then
        per[pid] = per[pid] or {}
        per[pid][#per[pid] + 1] = n
      end
    end
    l = l.next
  end
  return per, counts
end

local function holder(uid)
  if not uid or uid < 0 then return nil end
  local u = df.unit.find(uid)
  if not u then return { id = uid, alive = false, gone = true } end
  return { id = u.id, name = dfhack.units.getReadableName(u), alive = not is_dead(u),
           adult = safe(function() return dfhack.units.isAdult(u) end, true) }
end

local function occupations(locs)
  for _, o in ipairs(safe(function() return df.global.world.occupations.all end, {})) do
    local t = safe(function() return df.occupation_type[o.type] end, '?')
    local loc = safe(function() return o.location_id end, -1)
    if POSTS[t] and locs[loc] then
      local ps = locs[loc].posts
      ps[#ps + 1] = { id = o.id, type = t, unit_id = o.unit_id, hf = o.histfig_id, holder = holder(o.unit_id) }
    end
  end
end

local function material_id(it)
  return safe(function()
    local mi = dfhack.matinfo.decode(it)
    return mi and ((mi.inorganic and mi.inorganic.id) or (mi.material and mi.material.id)) or nil
  end, nil)
end

local function gypsum_class(it)
  local id = material_id(it)
  if id and GYPSUM[id] then return id end
  local cls = safe(function()
    local mi = dfhack.matinfo.decode(it)
    for _, rc in ipairs(mi.material.reaction_class) do
      if rc.value == 'GYPSUM' then return true end
    end
    return false
  end, false)
  return cls and (id or 'GYPSUM') or nil
end

local function supplies()
  local s = { cloth = 0, thread = 0, splint = 0, crutch = 0, plaster = 0, soap = 0, wood = 0 }
  local forb = { cloth = 0, thread = 0, splint = 0, crutch = 0, plaster = 0, soap = 0, wood = 0 }
  local gyp = { total = 0, forbidden = 0, by_mat = {} }
  for _, it in ipairs(safe(function() return df.global.world.items.other.IN_PLAY end, {})) do
    local f = it.flags
    if not (f.removed or f.trader or f.foreign or f.garbage_collect or f.construction or f.in_building
            or f.in_inventory or f.hostile) then
      local t = tname(it)
      local k = nil
      if t == 'CLOTH' then k = 'cloth' elseif t == 'THREAD' then k = 'thread'
      elseif t == 'SPLINT' then k = 'splint' elseif t == 'CRUTCH' then k = 'crutch' elseif t == 'WOOD' then k = 'wood'
      elseif t == 'POWDER_MISC' and material_id(it) == 'PLASTER' then k = 'plaster'
      elseif t == 'BAR' and tostring(material_id(it) or ''):find('SOAP') then k = 'soap' end
      local n = safe(function() return it:getStackSize() end, 1)
      if k then
        if f.forbid then forb[k] = forb[k] + n else s[k] = s[k] + n end
      end
      if t == 'BOULDER' then
        local x, y, z = dfhack.items.getPosition(it)
        local fl = x and dfhack.maps.getTileFlags(x, y, z) or nil
        local g = fl and not fl.hidden and gypsum_class(it) or nil      -- fair play: visible tiles only
        if g then
          if f.forbid then gyp.forbidden = gyp.forbidden + 1
          else
            gyp.total = gyp.total + 1
            gyp.by_mat[g] = (gyp.by_mat[g] or 0) + 1
          end
        end
      end
    end
  end
  s.forbidden = forb
  return s, gyp
end

local function log(t)
  pcall(function()
    t.time = os.date('%Y-%m-%d %H:%M:%S'); t.tick = df.global.cur_year_tick; t.year = df.global.cur_year
    local f = io.open(util.home() .. '/tools/out/hospital-log.json', 'a')
    if f then f:write(json.encode(t), '\n'); f:close() end
  end)
end

if cmd == 'status' then
  local locs = hospital_locations()
  local wpts, wells, drinks = water_points()
  local hs = hospitals(locs, wpts)
  occupations(locs)
  local per, counts = care_jobs()
  local cit = {}
  for _, u in ipairs(dfhack.units.getCitizens(true)) do
    if not is_dead(u) then
      local labors, skill = {}, 0
      for _, L in ipairs(LABORS) do
        if safe(function() return u.status.labors[df.unit_labor[L]] end, false) then labors[#labors + 1] = L end
      end
      for _, s in ipairs(SKILLS) do
        skill = skill + safe(function() return dfhack.units.getEffectiveSkill(u, df.job_skill[s]) end, 0)
      end
      local j = job_of(u)
      cit[#cit + 1] = {
        id = u.id, name = dfhack.units.getReadableName(u), wounds = safe(function() return #u.body.wounds end, 0),
        cant_stand = cant_stand(u), hospital = inside(u.pos, hs), squad = in_squad(u), pick = has_pick(u),
        labors = labors, care_skill = skill, idle = j == nil, job = j,
        child = not safe(function() return dfhack.units.isAdult(u) end, true),
        mood = safe(function() return u.mood >= 0 end, false),
        stress = safe(function() return u.status.current_soul.personality.stress end, 0),
        prisoner = safe(function() return u.flags1.caged or u.flags1.chained end, false),
        care_jobs = per[u.id] or {} }
    end
  end
  local loclist = {}
  for _, l in pairs(locs) do loclist[#loclist + 1] = l end
  table.sort(loclist, function(x, y) return x.id < y.id end)
  local sup, gyp = supplies()
  local refuge = nil
  local okg, G = pcall(reqscript, 'claude/gefahr')
  if okg and G and G.refuge_supply then
    local oks, r = pcall(G.refuge_supply, nil, true)
    if oks and type(r) == 'table' then
      refuge = { ok = r.ok, water_ok = r.water_ok, drink = r.drink, wells = r.wells, water_tiles = r.water_tiles,
                 food = r.food, burrow = r.burrow, problems = r.problems }
    end
  end
  local reach_any = nil
  for _, h in ipairs(hs) do reach_any = (reach_any == true) or h.water_reach end
  util.emit({ ok = true, citizens = cit, hospitals = hs, locations = loclist, care_jobs = counts,
              water = { wells = wells, drinks = drinks, reach_hospital = reach_any }, refuge = refuge,
              supplies = sup, gypsum = gyp,
              tick = safe(function() return df.global.cur_year * 403200 + df.global.cur_year_tick end, 0) })
elseif cmd == 'staff' then
  local oid, uid = tonumber(a[2] or ''), tonumber(a[3] or '')
  local occ = nil
  for _, o in ipairs(safe(function() return df.global.world.occupations.all end, {})) do
    if o.id == oid then occ = o break end
  end
  local locs = hospital_locations()
  local t = occ and safe(function() return df.occupation_type[occ.type] end, '?') or nil
  local loc = occ and locs[safe(function() return occ.location_id end, -1)] or nil
  if not occ or not POSTS[t] or not loc then
    util.emit({ ok = false, error = 'not a hospital post: ' .. tostring(a[2]) }) return
  end
  hospitals(locs, {})
  if loc.zones == 0 then
    util.emit({ ok = false, error = 'hospital location ' .. loc.id .. ' has no zone (orphaned): not staffed' }) return
  end
  local u = df.unit.find(uid or -1)
  local why = nil
  if not u or not safe(function() return dfhack.units.isCitizen(u) end, false) then why = 'not a citizen'
  elseif is_dead(u) then why = 'dead'
  elseif not safe(function() return dfhack.units.isAdult(u) end, true) then why = 'child'
  elseif safe(function() return u.mood >= 0 end, false) then why = 'in a mood'
  elseif in_squad(u) then why = 'soldier'
  elseif patient(u) then why = 'patient'
  elseif safe(function() return u.flags1.caged or u.flags1.chained end, false) then why = 'prisoner' end
  if why then util.emit({ ok = false, error = 'refused: ' .. why, unit = uid }) return end
  local old = occ.unit_id
  local oldu = (old and old >= 0) and df.unit.find(old) or nil
  if oldu and not is_dead(oldu) and oldu.id ~= u.id then
    util.emit({ ok = false, error = 'post held by a living unit ' .. oldu.id }) return
  end
  local res = { ok = true, occupation = occ.id, type = t, location = occ.location_id, unit = u.id, old_unit = old,
                old_hf = occ.histfig_id }
  if oldu and oldu.id == u.id then res.note = 'already holds this post' util.emit(res) return end
  if not APPLY then res.dry = true res.would = 'fill' util.emit(res) return end
  log({ action = 'staff', occupation = occ.id, type = t, old_unit = old, old_hf = occ.histfig_id, new_unit = u.id })
  if oldu then                                     -- a dead holder keeps the post: unlink it first
    local v = oldu.occupations
    for i = #v - 1, 0, -1 do
      if safe(function() return v[i].id == occ.id end, false) then v:erase(i) end
    end
  end
  occ.unit_id = u.id
  occ.histfig_id = u.hist_figure_id
  u.occupations:insert('#', occ)
  res.done = 'fill'
  util.emit(res)
else
  util.emit({ ok = false, error = 'Usage: claude/pilot_hospital status | staff <occupation_id> <unit_id> [--apply]' })
end
