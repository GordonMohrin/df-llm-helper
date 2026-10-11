-- care (WP8): strange moods, the mood-material reserve, burial and corpses, captives, hospital water, the
-- forbidden-barrel guard, the stress sampler and the naked check (DESIGN §4 RECOVERY clean-up, §5.6, §5.9-§5.11).
--   * moods: never touches the mood job (act has no job removal). Live L3: 10 of 13 moods failed (all fatal)
--     while care guessed the needs from the claimed workshop's classes. Gordon's decision (orchestrator
--     2026-10-11, v1 precedent): care reads the item requirements of the strange-mood job (job.job_items of
--     a StrangeMood* job only, what a player learns from the claimed workshop, the job and the dwarf's
--     searching; dfllm.reserve parses them). For each filter still short of items it resolves concrete
--     items the dwarf can use (revealed tile, reachable: the optional snapshot walk-group hook M.REACH_FN,
--     asked fresh per item because DF renumbers walk groups; without it only Kern+ counts), unforbids /
--     un-dumps / releases them from the
--     reserve, and starts what it can itself (autobutcher policy run for bone, shell, leather; a bedrooms
--     PROJECT_REQUEST for a stone dig). MOOD_NEED (B) carries the concrete list; still unresolved after
--     2 game days (or with no acquisition path) it wakes the LLM (DECISION_NEEDED mood_material). Production
--     orders, hunters and trade wants belong to economy and trade: they read care.mood_wants (hook).
--     Without readable filters the claimed workshop's classes (M.WS_MATS) are the fallback; children's
--     moods take the same path;
--   * mood reserve (config "reserve", dfllm.reserve): from P1 care keeps stored mood stock forbidden (boulders
--     20, logs 20, bone 10, shell 2, leather 10, cloth 10, thread 10, gems 5, bars 5 with a smelter), taken
--     from stockpiles inside Kern+ and their bins (a `dfllm-reserve` pile first), so no order or building
--     consumes it; sized from economy's census of free stock, topped up only after a census newer than care's
--     last write (the census skips forbidden items); critical
--     supply comes first (logs for missing barrels and coffins, boulders for coffins, no wood held in the supply
--     alarm), and a class an active mood needs is released, never topped up. Hooks (live L4, proposed for
--     CONTRACTS §7): care.reserved and care.mood_wants are pulled by economy (and trade); care pushes the
--     floor economy's own consumers keep through economy.reserve (optional, feature-detected), so rock orders
--     leave the last 20 boulders alone;
--   * every item flag write needs a revealed tile (snapshot.tile) and, outside PEACE / late RECOVERY,
--     a Kern+ tile (no Kern+ yet: no writes outside clean-up time);
--   * burial: free tombs >= open corpses + margin, else PROJECT_REQUEST tombs (follow places them);
--     `burial -c` zones unzoned coffins;
--   * captives: melt-safe (a cage holding a captive is never left marked for melting), then after a
--     deadline in PEACE/late RECOVERY assigned to the manifest pit (zone_assign) or, without a pit,
--     the cage is marked for dumping so it leaves the trap tile.
-- Reads: citizens and captives by census id, dead fort members by event / corpse unit id (CONTRACTS §1.4),
-- items.other / buildings.other vectors (sliced), burrow membership, site locations.
-- Writes only through K.act (item_flag, zone_assign, run). Since live L1b care also unmarks tools (picks,
-- battle axes, crossbows) marked for melting.
local json = require('dfllm.util.json')
local C = require('dfllm.util.contract')
local R = require('dfllm.reserve')     -- library (not a kernel module): mood filters, matcher, reserve sizes

local M = {name = 'care', every = {ticks = 1200}, on = {}}
local DAY = C.TICKS.DAY
-- Optional walk-group hook, proposed for CONTRACTS §7 (live L4): snapshot.reach(a, b) -> bool, i.e.
-- dfhack.maps.canWalkBetween asked at call time (care may not read tiles itself, CONTRACTS §1.4). Feature-
-- detected: while snapshot has no such function, only an item inside Kern+ counts as reachable (v1 counted
-- revealed cavern logs and bones behind a closed shaft as mood stock, and those moods failed). A hook that
-- faults is not asked again this boot (each fault counts against snapshot, three back it off).
M.REACH_FN = 'reach'
-- economy publishes K.census.i at the end of its sliced census, which skips forbidden items: until a census
-- newer than care's last reserve write of a class has come, census + held counts the newly held items twice
-- (the reserve would take the critical part too, then release it: flapping). A class is topped up again only
-- once the census tick is at least this far past that write (one economy period).
local CENSUS_LAG = 1200

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
  -- mood reserve: item ids care holds forbidden, per class; acquisition timestamps (autobutcher, dig request)
  if type(p.reserve) ~= 'table' then p.reserve = {} end
  local held = type(p.reserve.held) == 'table' and p.reserve.held or {}
  for k, v in pairs(held) do if type(v) ~= 'table' then held[k] = nil end end
  p.reserve.held = json.object(held)
  p.acq = json.object(type(p.acq) == 'table' and p.acq or {})
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
-- live L3: a berserk citizen leaves the own group (isOwnGroup false, histfig link FORMER_MEMBER of the site
-- government). Its death went unrecorded, its corpse was dumped as a stranger's, and its ghost held the fort
-- in BREACH; a (former) member link to plotinfo.group_id keeps it ours (the unit sheet shows that link)
local function group_member(u)
  local hf = df.historical_figure.find(u.hist_figure_id)
  local gid = df.global.plotinfo.group_id
  if not hf or gid == nil or gid < 0 then return false end
  for _, l in ipairs(hf.entity_links) do if l.entity_id == gid then return true end end
  return false
end

function M.own_member(id, dead_only)
  local ok, yes = pcall(function()
    local u = df.unit.find(id)
    if u == nil or dfhack.units.isAnimal(u) or (dead_only and not dfhack.units.isDead(u)) then return false end
    return dfhack.units.isOwnGroup(u) or group_member(u)
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

local function is_child(u)
  local ok, yes = pcall(function() return dfhack.units.isChild(u) or dfhack.units.isBaby(u) end)
  return ok and yes == true
end

local function unit_pos(u)
  local ok, x, y, z = pcall(function() return u.pos.x, u.pos.y, u.pos.z end)
  if ok and math.type(x) == 'integer' then return {x = x, y = y, z = z} end
end

-- the needs of one mood: from the mood job's filters (reserve.job_needs), else the claimed workshop's
-- classes as one any-of need (M.WS_MATS, the pre-L4 fallback); nil when nothing is missing
local function mood_needs(job, ws)
  local list = R.job_needs(job)
  if list then
    local out = {}
    for _, nd in ipairs(list) do out[#out + 1] = {alts = {nd}, n = nd.n, nd = nd} end
    return out, 'job'
  end
  local mats = M.mood_mats(job, ws)
  if not mats then return nil end
  local alts = {}
  for _, m in ipairs(mats) do
    local nd = R.legacy_need(m)
    if nd then alts[#alts + 1] = nd end
  end
  if #alts == 0 then return nil end
  return {{alts = alts, n = 1, legacy = table.concat(mats, '/')}}, 'workshop'
end

local function mood_seen(K, c, r, p, u, kind)
  local sid, now = fmt(u.id), K.now().tick
  local child = is_child(u)
  local rec = p.moods[sid]
  if not rec then
    rec = {kind = kind, since = now, nojob = -1, ws = 0, needs = json.object{}}
    p.moods[sid] = rec
    K.emit('MOOD_START', 'B', string.format('strange mood (%s) unit %d%s', kind, u.id, child and ' (child)' or ''),
           {unit = u.id, kind = kind, child = child and 1 or 0})
  end
  r.moody[sid] = true
  local job = u.job and u.job.current_job
  local ws = job and M.mood_workshop(job)
  if not ws and (not job or R.is_mood_job(job)) then   -- no workshop claimed yet (a mood job without a holder too)
    if rec.nojob < 0 then rec.nojob = now end
    if rec.ws == 0 and now - rec.nojob >= c.mood_nojob_ticks then
      rec.ws = 1
      -- live L3: three of four moods struck children (1-7 years) who have no skills to hint the workshop
      local skill = best_skill(u)
      if skill == '' then skill = child and 'none (child): any moodable shop' or 'none' end
      K.emit('MOOD_NEED', 'B', string.format('mood unit %d has no workshop (best skill %s)', u.id, skill),
             {unit = u.id, kind = kind, need = 'workshop', skill = skill})
      -- live L1: two fey moods failed for want of a workshop; the moody dwarves went insane and one died
      -- of thirst. A failed mood is lost within days: wake the LLM and ask for the moodable workshops.
      K.emit('DECISION_NEEDED', 'A', string.format('strange mood: unit %d has no workshop (best skill %s)', u.id, skill),
             {id = 'mood_workshop', q = string.format('unit %d needs a workshop for %s now (workshops template or one shop)',
                                                     u.id, skill):sub(1, 200)})
      local okp, pend = K.call('runner', 'pending', 'workshops')
      if not (okp and type(pend) == 'number' and pend > 0) then
        K.emit('PROJECT_REQUEST', 'B', string.format('workshops for a strange mood (unit %d, %s)', u.id, skill),
               {tpl = 'workshops', n = 1, why = 'mood'})
      end
    end
    if not job then return end                           -- a mood job already lists its materials: prepare them
  else
    rec.nojob = -1
  end
  local needs, via = mood_needs(job, ws)
  if not needs then return end
  local jid = -1
  pcall(function() jid = job.id end)
  -- only plain values outlive this frame: the job and its job_items are looked up again per frame (refresh_moods)
  local m = {sid = sid, uid = u.id, job_id = jid, ws = ws or '', kind = kind, needs = needs, via = via, child = child,
             upos = unit_pos(u)}
  r.mood_list[#r.mood_list + 1] = m
  for _, nd in ipairs(needs) do
    for _, alt in ipairs(nd.alts) do if alt.cls then r.mood_cls[alt.cls] = true end end
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
  if r.res_ids[it.id] then return end           -- a reserve bone or shell: no corpse to dump
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
  local unzoned, tomb, unlinked = 0, df.civzone_type and df.civzone_type.Tomb, 0
  for _, cof in ipairs(vec(function() return other.COFFIN end)) do
    local zoned = not built(cof)               -- a planned coffin cannot be zoned yet
    for _, zn in ipairs(cof.relations or {}) do if zn.type == tomb then zoned = true end end   -- entomb.lua:66
    if not zoned then
      -- live L3: burial.lua zones every coffin with empty `relations`, and a coffin built after its tomb zone
      -- has none: four coffins got a second tomb zone, DF gave the dead those "free" zones on occupied coffins
      -- and five citizens lay unburied. A coffin inside a tomb zone counts as zoned, and burial runs only
      -- when no such coffin would get a second zone.
      local ok, zs = pcall(dfhack.buildings.findCivzonesAt, {x = cof.x1, y = cof.y1, z = cof.z})   -- :2488
      local inside = false
      for _, zn in ipairs(ok and zs or {}) do if zn.type == tomb then inside = true end end
      if inside then unlinked = unlinked + 1 else unzoned = unzoned + 1 end
    end
  end
  r.coffins_unlinked = unlinked
  if unzoned > 0 and unlinked == 0 then K.act.run('burial', '-c') end   -- tools/burial.txt: citizens-only tombs
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

---------------------------------------------------------------- mood materials (live L4: the mood job's filters)
local function trunc(s, n)                      -- cut at a UTF-8 boundary
  s = tostring(s or '')
  if #s <= n then return s end
  local cut = n
  while cut > 0 and (s:byte(cut + 1) or 0) & 0xC0 == 0x80 do cut = cut - 1 end
  return s:sub(1, cut)
end

local function int(v) return math.tointeger(tonumber(v)) end

-- a fort member's remains (a dead citizen's bones, a severed limb) belong in a tomb, never in a mood or the
-- reserve (cached per run)
local function own_remains(r, it)
  local uid = it.unit_id
  if math.type(uid) ~= 'integer' or uid < 0 then return false end
  if r.member[uid] == nil then r.member[uid] = r.dead[uid] == true or M.own_member(uid) end
  return r.member[uid]
end

-- a tile the fort knows of: hidden -> false; no tile reader loaded -> true (nothing to ask, as before)
local function known_tile(K, x, y, z)
  if not x then return false end
  local ok, t = K.call('snapshot', 'tile', x, y, z)
  if not ok then return true end
  return type(t) == 'table'
end

-- can the moody dwarf (at from) reach the item? The walk-group hook (M.REACH_FN) when snapshot has it, asked
-- per item when it is used (DF renumbers walk groups as the map changes, so nothing is cached across frames);
-- without it, or without the unit's position, only an item inside Kern+ (no Kern+ yet: at clean-up time)
-- counts. A hook that faults is dropped for this boot.
local function reachable(K, r, from, x, y, z)
  if from and not r.no_reach and not st.reach_bad then
    local ok, yes = K.call('snapshot', M.REACH_FN, from, {x = x, y = y, z = z})
    if ok then return yes ~= false end
    local why = tostring(yes)
    if why ~= 'no module' and why ~= 'disabled' and not why:find('^no function') then
      st.reach_bad = true
      K.log('warn', 'snapshot.%s failed (%s): Kern+ stands in for it this boot', M.REACH_FN, why)
    end
    r.no_reach = true
  end
  return inside(r, x, y, z)
end

local function release_held(r, p, id)
  if not r.res_ids[id] then return end
  r.res_ids[id] = nil
  for cls, ids in pairs(p.reserve.held) do
    for i = #ids, 1, -1 do
      if ids[i] == id then
        table.remove(ids, i)
        st.wrote = st.wrote or {}
        st.wrote[cls] = r.now                   -- the census still counts it as forbidden
      end
    end
  end
end

-- one item against one need: usable as it lies (counted for this need only), or forbidden / dumped / held by
-- the reserve and freed (inside Kern+ or at clean-up time, revealed, reachable). A free item the dwarf may
-- not reach (outside Kern+ without the walk-group hook) is not counted: nd.far tells MOOD_NEED about it.
local function need_item(K, c, r, p, t, it)
  local nd, alt = t.nd, t.alt
  if nd.avail >= nd.n or r.claimed[it.id] or R.busy(it) or R.carried(it) or not R.match(alt, it) then return end
  if alt.part and own_remains(r, it) then return end
  local f = it.flags
  local x, y, z = item_pos(it)
  if not x then return end
  if not f.forbid and not f.dump then
    if known_tile(K, x, y, z) then
      if reachable(K, r, t.m.upos, x, y, z) then
        r.claimed[it.id], nd.avail = true, nd.avail + 1
      else
        nd.far = nd.far + 1
      end
    end
    return
  end
  if nd.fixes >= math.max(c.unforbid_per_need, nd.n) or not inside(r, x, y, z) or not revealed(K, x, y, z)
     or not reachable(K, r, t.m.upos, x, y, z) then return end
  -- live L4: a Possessed mood (bone x2, then a block and a boulder) found no bone; care freed one held boulder
  -- per run for its third filter and coffins, the depot and the cistern took each one before the dwarf (who
  -- gathers in filter order) came to it: 9 boulders gone, and the mood then lacked a boulder too. A held or
  -- dumped item is freed only once every earlier filter of the same mood is covered; until then it counts
  -- as there (held for the mood), so MOOD_NEED lists only what is really missing.
  for _, prev in ipairs(t.m.needs) do
    if prev == nd then break end
    if (prev.avail or 0) < prev.n then
      r.claimed[it.id], nd.avail = true, nd.avail + 1
      return
    end
  end
  local ok = true
  if f.forbid then ok = K.act.item_flag(it.id, 'forbid', false) and ok end
  if f.dump then ok = K.act.item_flag(it.id, 'dump', false) and ok end
  if ok then
    nd.fixes, nd.avail = nd.fixes + 1, nd.avail + 1
    r.claimed[it.id] = true
    release_held(r, p, it.id)
  end
end

-- DF frees a mood job (and its job_items) when the artifact is done or the mood fails. A sliced run spans
-- frames, so the job_item pointers reserve.match hands DFHack's veto are looked up again at every frame from
-- the unit; a mood whose job is gone or changed drops out of this run (the next run sees the new state)
local function refresh_moods(r)
  for _, m in ipairs(r.mood_list) do
    if m.via == 'job' and not m.gone then
      local ok, elems = pcall(function()
        local u = df.unit.find(m.uid)
        local j = u and u.job.current_job
        if j and j.id == m.job_id and R.is_mood_job(j) then return j.job_items.elements end
      end)
      for _, nd in ipairs(m.needs) do
        local okj, ji = false, nil
        if ok and elems then okj, ji = pcall(function() return elems[nd.nd.idx] end) end
        nd.nd.ji = okj and ji or nil
      end
      if not (ok and elems) then m.gone = true end
    end
  end
end

local CORPSE_CLS = {bone = true, shell = true, leather = true}

-- what care starts itself: the autobutcher policy run (bone, shell, leather from animals over the targets;
-- pets are never butchered) and a stone dig through the runner (PROJECT_REQUEST bedrooms, as tombs). Hunters,
-- production orders and purchases are economy's and trade's (care.mood_wants).
local function acquire(K, r, p, classes)
  local now, rc = K.now().tick, r.rc
  for _, cls in ipairs(classes) do
    if CORPSE_CLS[cls] and not r.butchered and now - (p.acq.butcher or -1e12) >= rc.butcher_every then
      r.butchered, p.acq.butcher = true, now
      if K.act.run('autobutcher', 'now') then K.log('info', 'mood needs %s: autobutcher now', cls) end
    elseif cls == 'boulders' and not r.dug and now - (p.acq.dig or -1e12) >= 3 * DAY then
      r.dug = true
      local okp, pend = K.call('runner', 'pending', 'bedrooms')
      if not (okp and type(pend) == 'number' and pend > 0) then
        p.acq.dig = now
        K.emit('PROJECT_REQUEST', 'B', 'bedrooms: a stone dig for a strange mood (boulders)',
               {tpl = 'bedrooms', n = 4, why = 'mood_rock'})
      end
    end
  end
end

-- after the scan: per mood the needs still short; MOOD_NEED (B) with the concrete list whenever it changes,
-- the acquisitions, and DECISION_NEEDED (A) once unresolved for wake_ticks (at once without any path),
-- again every rewake_ticks
local function mood_report(K, c, r, p)
  local rc, now = r.rc, K.now().tick
  local wants = {}
  for _, m in ipairs(r.mood_list) do
    local rec = not m.gone and p.moods[m.sid]
    if rec then
      local labels, classes, primary, seen, nopath, far = {}, {}, {}, {}, false, 0
      for _, nd in ipairs(m.needs) do               -- wants: the hook entries (care.mood_wants)
        if nd.avail < nd.n then
          local short = nd.n - nd.avail
          far = far + (nd.far or 0)
          labels[#labels + 1] = nd.legacy or R.label(nd.nd, short)
          local path = false
          for _, alt in ipairs(nd.alts) do
            local cls = alt.cls or 'other'
            if R.ACQ[cls] then path = true end
            if not seen[cls] then seen[cls] = true; classes[#classes + 1] = cls end
          end
          nopath = nopath or not path
          local a = nd.alts[1]                      -- an any-of need (workshop classes): its primary material
          primary[#primary + 1] = a.cls or 'other'
          if #wants < 20 then
            wants[#wants + 1] = {unit = int(m.sid), cls = a.cls or 'other', n = short, label = labels[#labels],
                                 acq = table.concat(R.ACQ[a.cls or ''] or {}, ','), buy = R.token(a) or ''}
          end
        end
      end
      if #labels == 0 then
        if rec.unres then K.log('info', 'mood unit %s: every material is available now', m.sid) end
        rec.unres = nil
      else
        local sig = trunc(table.concat(labels, ', '), 200)
        local u = rec.unres
        if type(u) ~= 'table' then u = {since = now, sig = ''}; rec.unres = u end
        local acq = {}
        for _, cls in ipairs(classes) do acq[#acq + 1] = cls .. ':' .. table.concat(R.ACQ[cls] or {'none'}, '+') end
        if sig ~= u.sig then
          u.sig = sig
          -- d stays under kern's 1,024 bytes (a larger d is replaced by {"trunc":1}, the unit id lost):
          -- need 200 + acq 200 + list 300 + the small keys
          local list, bytes = {}, 0
          for i = 1, math.min(8, #labels) do
            bytes = bytes + #labels[i] + 3
            if bytes > 300 then break end
            list[i] = labels[i]
          end
          K.emit('MOOD_NEED', 'B', string.format('mood unit %s (%s, %s%s) needs %s', m.sid, rec.kind,
                                                 m.ws ~= '' and m.ws or '?', m.child and ', child' or '', sig),
                 {unit = int(m.sid), kind = rec.kind, need = sig, ws = m.ws, via = m.via, child = m.child and 1 or 0,
                  list = list, acq = trunc(table.concat(acq, ' '), 200), far = far})
        end
        acquire(K, r, p, primary)
        local age = now - (u.since or now)
        if (nopath or age >= rc.wake_ticks) and (u.woke == nil or now - u.woke >= rc.rewake_ticks) then
          u.woke = now
          local hints = {}
          if far > 0 then hints[1] = string.format('%d outside Kern+: haul in or open the way', far) end
          for _, cls in ipairs(classes) do hints[#hints + 1] = R.HINT[cls] or R.HINT.other end
          -- live L1b-L3: a missing mood material ended in a failed mood and a death 9 times; care has freed
          -- what exists and started what it can, the rest needs the LLM (dig, trade, plan)
          K.emit('DECISION_NEEDED', 'A', trunc(string.format('strange mood: unit %s (%s%s) still needs %s', m.sid,
                                                             rec.kind, m.child and ', child' or '', sig), 200),
                 {id = 'mood_material', q = trunc(string.format('unit %s needs %s for %d d: %s', m.sid, sig,
                                                               age // DAY, table.concat(hints, '; ')), 200)})
        end
      end
    end
  end
  r.wants = wants
end

-- one task per (mood need, alternative, items vector); a task stops at the need's count
local function phase_needs(K, c, r, p)
  if not r.nq then
    r.nq, r.nqi = {}, 1
    for _, m in ipairs(r.mood_list) do
      for _, nd in ipairs(m.needs) do
        nd.avail, nd.fixes, nd.far = 0, 0, 0
        for _, alt in ipairs(nd.alts) do
          for _, v in ipairs(alt.vecs or {}) do r.nq[#r.nq + 1] = {m = m, nd = nd, alt = alt, vec = v} end
        end
      end
    end
  end
  refresh_moods(r)                               -- every frame: no job_item pointer from an earlier frame
  while r.nqi <= #r.nq do
    local t = r.nq[r.nqi]
    if t.nd.avail < t.nd.n and not t.m.gone then
      local done = scan(r, function() return df.global.world.items.other[t.vec] end,
                        function(it) need_item(K, c, r, p, t, it) end, function() return t.nd.avail >= t.nd.n end)
      if not done then return false end
    end
    r.nqi, r.idx = r.nqi + 1, 0
  end
  mood_report(K, c, r, p)
  return true
end

---------------------------------------------------------------- the mood reserve (live L4)
-- Live L3: 0 bone, shell, leather, bars, 4 cloth, 8 boulders, 9 logs; rock orders and mechanisms had eaten
-- every boulder before two mason moods. From reserve.from_phase care keeps stored mood stock forbidden (the
-- item sheet's forbid toggle, as a player keeps a mood stash) so no order or building takes it: items in
-- stockpiles inside Kern+ (the `dfllm-reserve` pile first; never the trade or melt piles), ids in persist.
-- reserve.hold sizes it (critical supply first). A class an active mood needs is never topped up, and
-- need_item frees held items the mood can use.
local function has_smelter()
  local ok, yes = pcall(function()
    for _, b in ipairs(df.global.world.buildings.other.FURNACE_ANY) do
      local n = df.furnace_type[b.type]
      if (n == 'Smelter' or n == 'MagmaSmelter') and built(b) then return true end
    end
    return false
  end)
  return ok and yes == true
end

-- the stockpile ids to search (a pile can be removed between frames: ids, looked up again per frame)
local function reserve_piles(K, rc)
  local skip = {}
  local bc = type(K.cfg.baseline) == 'table' and type(K.cfg.baseline.baseline) == 'table' and K.cfg.baseline.baseline or {}
  for _, k in ipairs({'trade_piles', 'melt_piles'}) do
    for _, n in ipairs(type(bc[k]) == 'table' and bc[k] or {}) do skip[tostring(n):lower()] = true end
  end
  local want = tostring(rc.pile or ''):lower()
  local first, rest = {}, {}
  for _, sp in ipairs(vec(function() return df.global.world.buildings.other.STOCKPILE end)) do
    local name = ''
    pcall(function() name = dfhack.df2utf(sp.name):lower() end)
    if want ~= '' and name == want then first[#first + 1] = sp.id
    elseif not skip[name] then rest[#rest + 1] = sp.id end
  end
  for _, id in ipairs(rest) do first[#first + 1] = id end
  return first
end

-- the item ids of one stockpile: what lies on its tiles (Lua API.txt:2512) and what its bins, bags and chests
-- hold (Lua API.txt:2043; getStockpileContents lists a non-empty bin, not its contents). Ids, not pointers: the
-- pile is worked through over several frames.
local function pile_ids(id)
  local out = {}
  local sp = df.building.find(id)
  if not sp then return out end
  local ok, items = pcall(dfhack.buildings.getStockpileContents, sp)
  if not ok or type(items) ~= 'table' then return out end
  for _, it in ipairs(items) do
    out[#out + 1] = it.id
    if R.is_container(it) then
      local okc, inner = pcall(dfhack.items.getContainedItems, it)
      for _, ci in ipairs(okc and type(inner) == 'table' and inner or {}) do out[#out + 1] = ci.id end
    end
  end
  return out
end

-- the fort's free stock of a class plus what the reserve holds (economy's census skips forbidden items);
-- nil = unknown (then nothing new is held). Boulders: economy's free boulders (`rock`) minus ores and flux,
-- which the reserve never holds; census.boulders is the whole BOULDER vector (built-in, economic and cavern
-- stone too) and would let the reserve take the coffins' stone. Thread: economy's collected thread (`thread`,
-- no webs); the THREAD vector counts cavern webs and would let it take the loom's thread.
local CENSUS_KEY = {logs = 'wood', bone = 'bone', shell = 'shell', leather = 'leather', cloth = 'cloth', gems = 'gems',
                    bars = 'bars', thread = 'thread'}
local function class_total(inv, cls, nheld)
  if cls == 'boulders' then
    local rock = math.tointeger(inv.rock)
    if not rock then return nil end
    return math.max(0, rock - (math.tointeger(inv.ore) or 0) - (math.tointeger(inv.flux) or 0)) + nheld
  end
  local n = math.tointeger(inv[CENSUS_KEY[cls] or ''])
  return n and n + nheld or nil
end

-- held items that are still ours (forbidden, the class, not consumed); sizes; releases beyond the hold
local function reserve_begin(K, c, r, p)
  local rc, inv, held = r.rc, K.census.i, p.reserve.held
  local rs = {pi = 1, ii = 0, def = {}, acts = 0, want = 0, tot = {}, found = {}}
  for _, cls in ipairs(R.CLASSES) do
    local keep = {}
    for _, id in ipairs(type(held[cls]) == 'table' and held[cls] or {}) do
      local it = math.type(id) == 'integer' and df.item.find(id)
      local f = it and it.flags
      if f and f.forbid and not (f.removed or f.garbage_collect or f.in_building or f.construction)
         and R.item_class(it) == cls then
        keep[#keep + 1] = id
      else
        r.res_ids[id] = nil
      end
    end
    held[cls] = keep
  end
  if type(inv) ~= 'table' then return rs end            -- no item census yet: hold what is held
  local okp, alarm = K.call('economy', 'alarm')
  local f = {phase = (K.view() or {}).phase, smelter = has_smelter(), alarm = okp == true and alarm ~= nil,
             barrels_empty = math.tointeger(inv.barrels_empty) or 0,
             coffins_missing = math.max(0, count(r.open) - (r.tombs_free or 0))}
  if type(f.phase) ~= 'string' then return rs end      -- no phase yet (first frames after a boot): unchanged
  local cloth = class_total(inv, 'cloth', #held.cloth)
  f.cloth_short = cloth and math.max(0, (math.tointeger((rc.targets or {}).cloth) or 0) - cloth) or 0
  local itick = math.tointeger(inv.tick) or -1
  st.wrote = st.wrote or {}
  for _, cls in ipairs(R.CLASSES) do
    local ids = held[cls]
    f.total = class_total(inv, cls, #ids)
    local hold = f.total and R.hold(rc, cls, f) or #ids
    -- census older than the last write of this class: census + held may count new holds twice, so no top-up
    -- and no higher floor until a fresh census (a release or a lower floor on the old numbers only frees more)
    local stale = st.wrote[cls] ~= nil and itick < st.wrote[cls] + CENSUS_LAG
    -- the floor economy keeps: the hold (critical supply stays spendable); what the reserve could not take
    -- into the stash yet (unstockpiled boulders) is floor - held for economy
    local pushed = (st.pushed or {})[cls]
    r.res_floor[cls] = (stale and pushed) and math.min(hold, pushed) or hold
    if stale or r.mood_cls[cls] then hold = math.min(hold, #ids) end   -- or a mood takes from this class now
    r.res_hold[cls] = hold
    rs.tot[cls] = f.total
    while #ids > hold and rs.acts < rc.per_run do                 -- release beyond the hold, newest first
      local id = ids[#ids]
      local it = df.item.find(id)
      if it then                                 -- the item flag rule above: revealed, Kern+ or clean-up time
        local x, y, z = item_pos(it)
        if not ((r.clean_ok or inside(r, x, y, z)) and revealed(K, x, y, z))
           or not K.act.item_flag(id, 'forbid', false) then break end
        st.wrote[cls] = r.now
      end
      table.remove(ids)
      r.res_ids[id] = nil
      rs.acts = rs.acts + 1
    end
    -- a class a full pass found nothing for is skipped until its stock changes or a week passed (no daily scan
    -- of every pile for thread that lies in cavern webs; hauling into a pile does not change the stock)
    local dry = (st.dry or {})[cls]
    local skip = dry and dry[1] == rs.tot[cls] and K.now().tick - dry[2] < 7 * DAY
    if r.clean_ok and hold > #ids and not skip then
      rs.def[cls] = hold - #ids
      rs.want = rs.want + rs.def[cls]
    end
  end
  if rs.want > 0 then rs.piles = reserve_piles(K, rc) end
  return rs
end

local function reserve_item(K, r, p, rs, it)
  local cls = R.item_class(it)
  if not cls or (rs.def[cls] or 0) <= 0 then return end
  local f = it.flags
  if f.forbid or f.dump or f.melt or r.claimed[it.id] or R.busy(it) or R.carried(it) then return end
  if cls == 'boulders' and R.economic(it) then return end           -- ores and flux stay the smelter's
  if (cls == 'bone' or cls == 'shell') and own_remains(r, it) then return end
  local x, y, z = item_pos(it)
  if not inside(r, x, y, z) or not revealed(K, x, y, z) then return end
  if K.act.item_flag(it.id, 'forbid', true) then
    local ids = p.reserve.held[cls]
    ids[#ids + 1] = it.id
    r.res_ids[it.id] = true
    rs.def[cls], rs.want, rs.acts = rs.def[cls] - 1, rs.want - 1, rs.acts + 1
    rs.found[cls] = true
    st.wrote[cls] = r.now
  end
end

-- the piles one after the other (their item ids listed once per pile), sliced by items
local function phase_reserve(K, c, r, p)
  if not r.rs then r.rs = reserve_begin(K, c, r, p) end
  local rs = r.rs
  while rs.piles and rs.pi <= #rs.piles and rs.want > 0 and rs.acts < r.rc.per_run do
    if not rs.list then rs.list, rs.ii = pile_ids(rs.piles[rs.pi]), 0 end
    local list = rs.list
    while r.left > 0 and rs.ii < #list and rs.want > 0 and rs.acts < r.rc.per_run do
      rs.ii, r.left = rs.ii + 1, r.left - 1
      local it = df.item.find(list[rs.ii])
      if it then
        local okr, err = pcall(reserve_item, K, r, p, rs, it)
        if not okr then r.errs, r.err = r.errs + 1, r.err or tostring(err) end
      end
    end
    if rs.ii < #list then
      if r.left <= 0 then return false end              -- slice budget used up: on with this pile next frame
      break                                             -- enough (or per_run writes) for this run
    end
    rs.pi, rs.list = rs.pi + 1, nil
  end
  if rs.piles and rs.pi > #rs.piles then                -- a full pass: remember the classes it found nothing for
    st.dry = st.dry or {}
    for cls, d in pairs(rs.def) do
      if d > 0 and not rs.found[cls] then st.dry[cls] = {rs.tot[cls], K.now().tick} else st.dry[cls] = nil end
    end
  end
  return true
end

---------------------------------------------------------------- tools are never melted (live L1b)
-- The dfllm-melt pile (automelt) took the spare picks and battle axes and marked them for melting: two of
-- three miners and every woodcutter had no tool for a year. fortcore's melt pile now excludes them; a tool
-- marked for melting anyway (an older pile, a player's pile) is unmarked like the item sheet's toggle.
M.TOOL_WEAPONS = {ITEM_WEAPON_PICK = true, ITEM_WEAPON_AXE_BATTLE = true, ITEM_WEAPON_CROSSBOW = true}
local tool_def = {}
local function tool_item(K, c, r, it)
  if not it.flags.melt then return end
  local s = it:getSubtype()
  if tool_def[s] == nil then
    local def = dfhack.items.getSubtypeDef(df.item_type.WEAPON, s)
    tool_def[s] = def ~= nil and M.TOOL_WEAPONS[def.id] == true
  end
  if tool_def[s] and K.act.item_flag(it.id, 'melt', false) then r.tools = (r.tools or 0) + 1 end
end

local function phase_tools(K, c, r, p)
  return scan(r, function() return df.global.world.items.other.WEAPON end, function(it) tool_item(K, c, r, it) end)
end

---------------------------------------------------------------- run, finish
-- needs after corpses and zones (citizen remains, coffins), the reserve after the needs (moods first)
local PHASES = {phase_units, phase_corpses, phase_zones, phase_captives, phase_barrels, phase_needs, phase_reserve,
                phase_tools}

local function new_run(K, c, p)
  local cu = K.census.u
  local ids = {}
  for _, id in ipairs(type(cu) == 'table' and cu.ids or {}) do ids[#ids + 1] = id end
  local dead = {}
  for _, id in ipairs(p.dead) do dead[id] = true end
  local res_ids = {}
  for _, list in pairs(p.reserve.held) do
    for _, id in ipairs(list) do res_ids[id] = true end
  end
  local mode, now = K.mode(), K.now().tick
  return {ph = 1, idx = 0, left = 0, ids = ids, have_units = type(cu) == 'table' and type(cu.ids) == 'table',
          acc = {n = 0, stressed = 0, naked = 0, thoughts = {}}, moody = {}, mood_list = {}, mood_cls = {},
          claimed = {}, member = {}, res_ids = res_ids, res_hold = {}, res_floor = {}, rc = R.conf(K.cfg.baseline),
          dead = dead, open = {}, acts = 0, fixed = 0, errs = 0, now = now,
          clean_ok = mode == 'PEACE' or (mode == 'RECOVERY' and now - K.mode_since() >= DAY),
          boxes = approach_boxes(K.manifest()), kern = kern_burrow(K)}
end

-- Optional push hook into economy (live L4, economy's hook API; not in CONTRACTS §7 yet, feature-detected):
-- economy.reserve(key, n, 'care') sets the standing floor economy's own consumers keep. economy keeps
-- max(0, floor - care.reserved) free items on top of the forbidden ones, so rock and wood orders leave alone
-- what the reserve cannot hold yet (unstockpiled boulders: "stop rock orders consuming the last 20").
-- floor = reserve.hold (target, at most the stock minus critical supply; 0 before P1 and for wood in the
-- alarm), so the critical part stays spendable. Sent on change and once after every boot; after a failure
-- other than a missing module or function it is not called again this boot (K.call counts the fault against
-- economy).
M.ECON_RESERVE = 'reserve'
local function push_floors(K, r)
  if st.econ_bad or next(r.res_floor) == nil then return end
  st.pushed = st.pushed or {}
  for _, cls in ipairs(R.CLASSES) do
    local n = r.res_floor[cls]
    if n and n ~= st.pushed[cls] then
      local ok, why = K.call('economy', M.ECON_RESERVE, cls, n, 'care')
      if not ok then
        why = tostring(why)
        if why ~= 'no module' and why ~= 'disabled' and not why:find('^no function') then
          st.econ_bad = true
          K.log('warn', 'economy.%s failed (%s): not called again this boot', M.ECON_RESERVE, why)
        end
        return
      end
      st.pushed[cls] = n
    end
  end
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
  local okp, pend = K.call('runner', 'pending', 'tombs')
  local queued = okp and type(pend) == 'number' and pend > 0      -- live L1: a tombs project every 3 days
  if need > 0 and not queued and (core or open > 0) and (p.tomb_req == nil or now - p.tomb_req >= c.tomb_request_every) then
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
  -- the reserve and the mood wants for the hooks (care.reserved, care.mood_wants); kern.log on change
  local held, parts = {}, {}
  for _, cls in ipairs(R.CLASSES) do
    held[cls] = #(p.reserve.held[cls] or {})
    if r.res_hold[cls] then parts[#parts + 1] = string.format('%s %d/%d', cls, held[cls], r.res_hold[cls]) end
  end
  st.held = held
  st.wants = r.wants or {}
  push_floors(K, r)
  local line = table.concat(parts, ' ')
  if line ~= '' and line ~= st.res_line then
    st.res_line = line
    K.log('info', 'mood reserve held/hold: %s', line)
  end
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
  if not (ctx and ctx.cont) or not st.run then st.run = new_run(K, c, p)
  else st.run.kern = kern_burrow(K) end        -- no burrow pointer from an earlier frame (it may be gone)
  local r = st.run
  r.left, r.now = c.items_per_slice, K.now().tick
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

local function deep(t)
  if type(t) ~= 'table' then return t end
  local r = {}
  for k, v in pairs(t) do r[k] = deep(v) end
  return setmetatable(r, getmetatable(t))
end

-- Pull hook for economy (live L4; proposed for CONTRACTS §7): items the mood reserve holds forbidden now,
-- {boulders, logs, bone, shell, leather, cloth, thread, gems, bars} (ints, a fresh table; economy maps the
-- class names to its keys). The item census skips forbidden items (`rock`, `thread` and the other keys; only
-- census.boulders is the whole BOULDER vector), so economy counts census + held as the mood stock; care sizes
-- the boulder and thread reserve from `rock` and `thread` and holds no new ones while they are missing.
function M.reserved(K)
  local out = {}
  for _, cls in ipairs(R.CLASSES) do out[cls] = (st.held or {})[cls] or 0 end
  return out
end

-- Pull hook for economy and trade (live L4; proposed for CONTRACTS §7): what open moods still miss after care
-- freed what exists, as a list (<= 20) of {cls, n, unit, label, acq, buy}. economy turns each into a short-term
-- need of its key (hunters, TAN_A_HIDE, WeaveCloth, SmeltOre, charcoal, autochop); acq = the paths of
-- reserve.ACQ ('butcher', 'hunt', 'chop', 'dig', 'order:<job>', 'buy'); buy = a trade.lua token ('bar:iron',
-- 'cloth', 'leather', 'gem') or '' for trade to put before plan.trade.want while a caravan is here.
function M.mood_wants(K)
  return deep(st.wants or {})
end

return M
