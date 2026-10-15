-- sense (WP5): the only unit reader besides snapshot (CONTRACTS §1.4, §6.1, §6.2).
-- K.census.u = citizens (every 100 ticks, 25 in SIEGE/BREACH/DRILL, and synchronously inside every
-- mode change, so siege's T0 actions see a fresh census). K.census.h = visible hostiles (every 45
-- ticks in PEACE, 25 otherwise, 10 while threat is armed), sliced over world.units.active.
-- A hostile counts only if
--   dfhack.units.isVisible(u) and not dfhack.units.isHidden(u) and not u.flags1.caged
-- (Lua API.txt:1460, :1512); hidden ambushers and caged prisoners never count. Own units never
-- count: a berserk or insane citizen is isDanger (API.txt:1668) but not isCitizen(u) (API.txt:1464),
-- so the own check uses include_insane; such units are only counted in census.h.crazed.
-- WP5 extensions (additive): census.u.insane_ids (insane citizens, for the gate footprint check),
-- census.h.crazed, census.h.list[i].dc (distance to the nearest citizen outside Kern+, -1 none).
-- live L6: K.census.a = the fort's visible tame animals (economy's famine slaughter), with the unit count.
local geom = require('dfllm.util.geom')

-- every 9 ticks = every frame at full timestream (<= 9-tick skips), so scan periods are not
-- rounded up to two frames; a step with nothing due returns at once
local M = {name = 'sense', every = {ticks = 9}, critical = true}

M.SLICE_WORK = 600     -- hostile-scan work per slice: ~600 ordinary units or ~60 hostiles ('more' for the rest)
M.LIST_MAX = 40        -- census.h.list: nearest hostiles
M.OUT_MAX = 20         -- census.u.outside_ids
M.COUNT_EVERY = 1000   -- ticks between visible-unit counts (perf.csv `units`) and the animal census (census.a)
M.ANIMAL_MAX = 120     -- census.a.list bound
local CIT_FAST = {SIEGE = true, BREACH = true, DRILL = true}

local st                -- module state, reset by init

local function sorted_keys(t)
  local r = {}
  for k in pairs(t or {}) do r[#r + 1] = k end
  table.sort(r)
  return r
end

-- burrow names from the manifest: role kern (default Kern+) and refuge (default Tiefe+)
local function burrow_names(man)
  local kern, refuge
  for _, name in ipairs(sorted_keys(man.burrows)) do
    local role = type(man.burrows[name]) == 'table' and man.burrows[name].role
    if role == 'kern' and (kern == nil or name == 'Kern+') then kern = name end
    if role == 'refuge' and (refuge == nil or name == 'Tiefe+') then refuge = name end
  end
  if type(man.refuge) == 'table' and type(man.refuge.burrow) == 'string' then refuge = man.refuge.burrow end
  return kern or 'Kern+', refuge or 'Tiefe+'
end
M.burrow_names = burrow_names

-- manifest geometry used by both scans (a few bridges; recomputed per citizen scan)
local function geometry(K)
  local man = K.manifest()
  local g = {bridges = {}, o1 = nil}
  for _, name in ipairs(sorted_keys(man.bridges)) do
    local b = man.bridges[name]
    if type(b) == 'table' and type(b.fp) == 'table' and #b.fp == 6 then
      local e = {name = name, role = b.role, fp = b.fp, c = geom.bbox_center(b.fp)}
      g.bridges[#g.bridges + 1] = e
      if b.role == 'outer' and (g.o1 == nil or name == 'O1') then g.o1 = e end
    end
  end
  g.kern, g.refuge = burrow_names(man)
  return g
end

local function threat_armed(K)
  local ok, flag = K.call('threat', 'armed')
  return ok and flag == 1
end

---------------------------------------------------------------- citizens (§6.1)
local P = {x = 0, y = 0, z = 0}   -- scratch coord for burrow lookups (a table coord, cf. item.lua:12)

local function scan_citizens(K, now)
  local U, B = dfhack.units, dfhack.burrows
  local g = geometry(K)
  st.geo = g
  local kb = B.findByName(g.kern)
  local rb = B.findByName(g.refuge)
  -- include_insane (API.txt:1696); the sane ones are exactly getCitizens() (isCitizen/isResident
  -- default to sane only, API.txt:1464-1470). Insane ones only count on bridge footprints.
  local all = U.getCitizens(false, true)
  local ids, sids, out, out_pos, insane = {}, {}, {}, {}, {}
  local cit, adults, soldiers, stressed, outside = 0, 0, 0, 0, 0
  local on_bridge = {}
  for _, b in ipairs(g.bridges) do on_bridge[b.name] = 0 end
  for _, u in ipairs(all) do
    local id = u.id
    local sane = U.isCitizen(u) or U.isResident(u)
    local soldier = false
    if sane then
      cit = cit + 1
      ids[#ids + 1] = id
      if U.isAdult(u) then adults = adults + 1 end
      soldier = u.military.squad_id >= 0
      if soldier then soldiers = soldiers + 1; sids[#sids + 1] = id end
      if U.getStressCategory(u) <= 1 then stressed = stressed + 1 end
    else
      insane[#insane + 1] = id
    end
    local x, y, z = U.getPosition(u)
    if x then
      P.x, P.y, P.z = x, y, z
      for _, b in ipairs(g.bridges) do
        if geom.in_bbox(P, b.fp) then on_bridge[b.name] = on_bridge[b.name] + 1 end
      end
      -- inside = Kern+ or the refuge (behind B2); soldiers do not count (DESIGN §4)
      if sane and not soldier and kb and not B.isAssignedTile(kb, P) and not (rb and B.isAssignedTile(rb, P)) then
        outside = outside + 1
        out[#out + 1] = id
        out_pos[#out_pos + 1] = {x = x, y = y, z = z}
      end
    end
  end
  table.sort(ids)
  table.sort(sids)
  table.sort(out)
  table.sort(insane)
  local out_ids = {}
  for i = 1, math.min(#out, M.OUT_MAX) do out_ids[i] = out[i] end
  st.out_pos = out_pos
  st.cit_tick, st.cit_due = now.tick, false
  K.census.u = {tick = now.tick, cit = cit, adults = adults, children = cit - adults, soldiers = soldiers,
                ids = ids, soldier_ids = sids, outside = kb and outside or -1, outside_ids = out_ids,
                on_bridge = on_bridge, stressed = stressed, caged = st.caged or {}, units = st.units or -1,
                insane_ids = insane}
  st.pub = {pop = {cit = cit, adults = adults, soldiers = soldiers}}
end

---------------------------------------------------------------- hostiles (§6.2), sliced
local function hscan_begin(K, now, armed)
  local g = st.geo or geometry(K)
  st.geo = g
  st.hs = {i = 0, seen = {}, list = {}, keys = {}, vis = 0, inv = 0, great = 0, undead = 0, inside = 0, crazed = 0,
           near_o1 = -1, near_cit = -1, near_bridge = {}, caged = {}, units = 0, tick = now.tick,
           armed = armed and 1 or 0, geo = g, out_pos = st.out_pos or {},
           count = now.tick - (st.count_tick or -M.COUNT_EVERY) >= M.COUNT_EVERY, animals = {}}
  for _, b in ipairs(g.bridges) do st.hs.near_bridge[b.name] = -1 end
  local oke, ent, r = K.call('seal', 'entrances')                  -- FR-33: where a wild predator matters
  if oke and type(ent) == 'table' and #ent > 0 then st.hs.ent, st.hs.ent_r = ent, math.tointeger(r) or 25 end
  st.h_tick = now.tick
end

local function minpos(cur, d) if cur < 0 or d < cur then return d end return cur end

-- live L6: the fort's tame animals (census.a, refreshed with the unit count every COUNT_EVERY ticks): economy
-- marks surplus ones for slaughter in a famine. Visible, tame, fort-controlled, alive, no citizen.
local function animal(hs, u, U)
  if #hs.animals >= M.ANIMAL_MAX or not U.isTame(u) or U.isCitizen(u, true) or U.isDead(u) then return end
  if not U.isFortControlled(u) then return end
  local f2 = u.flags2
  hs.animals[#hs.animals + 1] = {
    id = u.id, race = u.race or -1, female = u.sex == 0, adult = U.isAdult(u),
    pet = (U.isPet ~= nil and U.isPet(u)) == true, slaughter = (f2 and f2.slaughter) == true,
    war = ((U.isWar ~= nil and U.isWar(u)) or (U.isHunter ~= nil and U.isHunter(u))) == true}
end

-- live L6 (reclaimed Castlerisen): cavern giant bats killed 5 of 7 dwarves in a few days with threat at 0;
-- isDanger is false for them. A visible wild LARGE_PREDATOR (caste raw flag, shown in the creature
-- description) is a hostile candidate too; tame ones are dropped below like every own unit.
-- live L6 (Paddletribes): a giant olm in a sealed deep cavern (z94) flapped the fort between PEACE and ALERT
-- (idle 86%); a wild predator counts only on the citizens' walkable area (the map's own connectivity)
local fort_group, fort_group_t, fort_minz = nil, -1, nil
local function citizens_group()
  local t = df.global.cur_year_tick
  if fort_group_t ~= t then
    fort_group_t, fort_group, fort_minz = t, nil, nil
    for _, c in ipairs(dfhack.units.getCitizens(true)) do
      local g = dfhack.maps.isValidTilePos(c.pos) and dfhack.maps.getWalkableGroup(c.pos)
      if g and g ~= 0 then
        fort_group = fort_group or g
        fort_minz = math.min(fort_minz or c.pos.z, c.pos.z)
      end
    end
  end
  return fort_group, fort_minz
end

-- FR-33 (Run 9: four dingoes on the open surface held the fort in ALERT for 22 days): outside the fort a wild
-- predator counts only within hs.ent_r tiles of an entrance (seal.entrances); inside (a roofed tile) always
local function near_entrance(u, hs)
  local ent = hs and hs.ent
  if not ent then return true end                     -- no entrance known: every predator on the group counts
  local des = dfhack.maps.getTileFlags(u.pos)
  if des and not des.hidden and not des.outside then return true end
  local x, y, z = u.pos.x, u.pos.y, u.pos.z
  for _, p in ipairs(ent) do
    if math.max(math.abs(x - p[1]), math.abs(y - p[2]), math.abs(z - p[3])) <= hs.ent_r then return true end
  end
  return false
end

local function predator(u, hs)
  local ok, yes = pcall(function()
    local r = df.creature_raw.find(u.race)
    if not (r ~= nil and r.caste[u.caste].flags.LARGE_PREDATOR == true) then return false end
    -- off-map units (pos -30000) crashed DF 53 in getWalkableGroup (live L6): validate first
    if not dfhack.maps.isValidTilePos(u.pos) then return false end
    local g = citizens_group()
    if not (g == nil or dfhack.maps.getWalkableGroup(u.pos) == g) then return false end
    return near_entrance(u, hs)
  end)
  return ok and yes == true
end

-- per unit: 2 predicate calls for ordinary units; the full check only for hostile candidates
local function consider(hs, u)
  local U = dfhack.units
  local undead = U.isUndead(u)
  if not (undead or U.isDanger(u) or (not U.isTame(u) and predator(u, hs))) then
    if hs.count and U.isVisible(u) and not U.isHidden(u) then
      hs.units = hs.units + 1
      animal(hs, u, U)
    end
    return 1
  end
  local id = u.id
  if hs.seen[id] then return 1 end                     -- the vector may shift between slices
  hs.seen[id] = true
  if not U.isActive(u) or not U.isVisible(u) or U.isHidden(u) then return 4 end
  hs.units = hs.units + 1
  if u.flags1.caged then hs.caged[#hs.caged + 1] = id; return 5 end
  local inv = U.isInvader(u)
  if not inv then
    -- own units are never hostiles: berserk/insane citizens and residents, undead citizens, pets
    if U.isCitizen(u, true) or U.isResident(u, true) then
      if not (U.isCitizen(u) or U.isResident(u)) then hs.crazed = hs.crazed + 1 end   -- insane only
      return 7
    end
    if U.isTame(u) or U.isFortControlled(u) then return 7 end
    -- live L1b: the ghost of a dead citizen (isUndead, isOwnGroup) walked into Kern+ and held the fort in
    -- BREACH for days; an own ghost is care's job (slab, burial), not the siege reflex's
    -- live L3: a berserk child's ghost is no longer isOwnGroup (berserk dwarves leave the group); as a ghost of
    -- the fort's civilization it is still an own ghost. Counted as a hostile inside Kern+ it held the fort in
    -- BREACH: every civilian sat in Tiefe+, nobody pulled a lever, buried the body or fetched a drink
    if U.isGhost and U.isGhost(u) and ((U.isOwnGroup and U.isOwnGroup(u))
                                       or (u.civ_id ~= -1 and u.civ_id == df.global.plotinfo.civ_id)) then
      return 7
    end
  end
  local x, y, z = U.getPosition(u)
  if not x then return 7 end
  -- live L7 (Paddletribes): demons in the underworld (z1-5, a walkable group of their own) were visible from the
  -- map's edge and kept the fort in ALERT (idle 78 %, O1 up). A non-invader on another walkable group that cannot
  -- fly cannot reach anyone: not a hostile (the cavern olm rule above, for every kind)
  if not inv then
    local okg, other = pcall(function()
      local cg, minz = citizens_group()
      if not cg or not dfhack.maps.isValidTilePos(u.pos) then return false end
      local g = dfhack.maps.getWalkableGroup(u.pos)
      -- live L7: underworld demons stand 80+ levels below every citizen
      if minz and u.pos.z < minz - 40 then return true end
      if g == 0 or g == cg then return false end
      local r = df.creature_raw.find(u.race)
      return not (r ~= nil and r.caste[u.caste].flags.FLIER == true)
    end)
    if okg and other then return 7 end
  end
  local great = U.isGreatDanger(u)      -- megabeasts, titans, forgotten beasts, demons (Lua API.txt:1672)
  hs.vis = hs.vis + 1
  if great then hs.great = hs.great + 1 end
  if undead then hs.undead = hs.undead + 1 end
  if inv then hs.inv = hs.inv + 1 end
  local g, d_o1, dcit = hs.geo, -1, -1
  local o = g.o1
  if o then
    local c = o.c
    d_o1 = math.max(math.abs(x - c.x), math.abs(y - c.y), math.abs(z - c.z))
    hs.near_o1 = minpos(hs.near_o1, d_o1)
  end
  local nb = hs.near_bridge
  for _, b in ipairs(g.bridges) do               -- Chebyshev distance to the footprint box
    local f = b.fp
    local dx = x < f[1] and f[1] - x or (x > f[4] and x - f[4] or 0)
    local dy = y < f[2] and f[2] - y or (y > f[5] and y - f[5] or 0)
    local dz = z < f[3] and f[3] - z or (z > f[6] and z - f[6] or 0)
    local d = math.max(dx, dy, dz)
    local cur = nb[b.name]
    if cur < 0 or d < cur then nb[b.name] = d end
  end
  for _, p in ipairs(hs.out_pos) do
    local d = math.max(math.abs(x - p.x), math.abs(y - p.y), math.abs(z - p.z))
    if dcit < 0 or d < dcit then dcit = d end
  end
  if dcit >= 0 then hs.near_cit = minpos(hs.near_cit, dcit) end
  if hs.kb then
    P.x, P.y, P.z = x, y, z
    if dfhack.burrows.isAssignedTile(hs.kb, P) then hs.inside = hs.inside + 1 end
  end
  local list = hs.list
  list[#list + 1] = {id = id, x = x, y = y, z = z, d_o1 = d_o1, dc = dcit,
                     k = great and 'great' or (undead and 'undead') or (inv and 'inv') or 'danger'}
  -- integer sort key: distance (O1, else nearest outside citizen) then scan order
  hs.keys[#hs.keys + 1] = (d_o1 >= 0 and d_o1 or (dcit >= 0 and dcit or 999999)) * 16777216 + #list
  return 10
end

-- one slice of at most M.SLICE_WORK work units (1 per ordinary unit, ~10 per hostile); true when done
local function hscan_slice()
  local hs = st.hs
  hs.kb = dfhack.burrows.findByName(hs.geo.kern)    -- never keep a DF pointer across frames
  local vec = df.global.world.units.active
  local n = #vec
  local i, work = hs.i, 0
  while i < n and work < M.SLICE_WORK do
    local u = vec[i]
    if u then work = work + consider(hs, u) end
    i = i + 1
  end
  hs.i = i
  return i >= n
end

local function hscan_finish(K)
  local hs = st.hs
  st.hs = nil
  table.sort(hs.keys)                            -- plain integer sort: no Lua comparator
  local list = {}
  for i = 1, math.min(#hs.keys, M.LIST_MAX) do list[i] = hs.list[hs.keys[i] % 16777216] end
  table.sort(hs.caged)
  st.caged = hs.caged
  if hs.count then
    st.units, st.count_tick = hs.units, hs.tick
    K.census.a = {tick = hs.tick, n = #hs.animals, list = hs.animals}
  end
  K.census.h = {tick = hs.tick, vis = hs.vis, inv = hs.inv, great = hs.great, undead = hs.undead, inside = hs.inside,
                near_o1 = hs.near_o1, near_cit = hs.near_cit, near_bridge = hs.near_bridge, list = list,
                armed = hs.armed, crazed = hs.crazed}
end

---------------------------------------------------------------- module
function M.init(K)
  st = {cit_due = true, pub = nil}
end

-- 45 (not 50) in PEACE: with 9-tick timestream frames a scan lands every 45 ticks, inside the
-- DESIGN §4 latency of <= 50 ticks (<= 25 when armed: 10 -> 18 with 9-tick frames)
function M.hostile_period(K, armed)
  if armed then return 10 end
  return K.mode() == 'PEACE' and 45 or 25
end

function M.step(K, budget, ctx)
  if st.hs then                                  -- continue a sliced pass
    if not hscan_slice() then return 'more' end
    hscan_finish(K)
    return
  end
  local now = K.now()
  local mode = K.mode()
  local cit_period = CIT_FAST[mode] and 25 or 100
  if st.cit_due or st.cit_tick == nil or now.tick - st.cit_tick >= cit_period then scan_citizens(K, now) end
  if st.h_tick and now.tick - st.h_tick < 10 then return end    -- no hostile period is shorter
  local armed = threat_armed(K)
  if st.h_tick == nil or now.tick - st.h_tick >= M.hostile_period(K, armed) then
    hscan_begin(K, now, armed)
    if not hscan_slice() then return 'more' end
    hscan_finish(K)
  end
end

-- sense is first in contract.MODULES, so its MODE handler runs before siege's: the T0 raise rule
-- (citizens outside Kern+ = 0) reads a census taken in the detecting step, not one 100 ticks old
M.on = {
  MODE = function(K, ev) scan_citizens(K, K.now()) end,
}

function M.state(K) return st.pub or {} end

return M
