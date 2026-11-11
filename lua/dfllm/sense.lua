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
-- BUG-027: while gate has a bridge with work (gate.watch: boxes around its footprints) the hostile scan also lists
-- the visible friendly non-citizens in those boxes (visitors, merchants, diplomats, tame animals) as census.h.friends
-- {{id, k}} (<= FRIEND_MAX); gate follows them by id and holds the pull while one stands on or next to a footprint.
-- FR-62 (Run 9: 402 units, 16 ms/s): the hostile scan touches every unit 10x per second, so the per-unit path
-- is kept short: inactive units (dead, gone) cost one call, the LARGE_PREDATOR raw flag is cached per
-- race/caste, and the entrance list (seal) is only fetched when a predator candidate needs it.
-- Intake waves (Gordon 2026-10-16): every listed hostile carries its zone (zn: 1 = the intake area, manifest zones Z1/Z2
-- and the killboxes; 2 = past B1: a Kern+ tile or zones Z3/Z4; 0 = elsewhere) and dz = 1 when it is dangerous for an
-- intake (a great danger, or a caste raw flag BUILDINGDESTROYER, TRAPAVOID or FLIER; cached per race/caste like
-- LARGE_PREDATOR). census.h counts zin (zone 1), zpast (zone 2), dz and dz_o1 (the nearest dangerous one to O1); the
-- list puts zone 2, then zone 1 hostiles first, so a wave in the killing field is never cut off by the 40 nearest.
-- BUG-030: census.h.bd counts the visible building destroyers (raws, see raw_read), list entries carry bd = 1 for them.
-- Run 11: an invader the raws call an animal (raw_read an) is listed as k 'danger' with an = 1 and counted in census.h.an,
-- never in inv.
-- BUG-035 (Run 11 siege 9: 'recall: 9 of 5 still outside' while the alert moved the citizens from Kern+ to Tiefe+):
-- while reflex's recall runs it names the burrows the sounding civ alert confines to (recount); every citizen scan then
-- also counts the sane non-soldier citizens on none of their tiles: census.u.away, away_ids (<= AWAY_MAX), away_to.
local geom = require('dfllm.util.geom')

-- every 9 ticks = every frame at full timestream (<= 9-tick skips), so scan periods are not
-- rounded up to two frames; a step with nothing due returns at once
local M = {name = 'sense', every = {ticks = 9}, critical = true}

M.SLICE_WORK = 600     -- hostile-scan work per slice: ~600 ordinary units or ~60 hostiles ('more' for the rest)
M.LIST_MAX = 40        -- census.h.list: nearest hostiles
M.OUT_MAX = 20         -- census.u.outside_ids
M.AWAY_MAX = 40        -- census.u.away_ids (BUG-035: the recall's start set and the citizens who left since)
M.AWAY_NAMES = 4       -- burrows a recall may name
M.COUNT_EVERY = 1000   -- ticks between visible-unit counts (perf.csv `units`) and the animal census (census.a)
M.ANIMAL_MAX = 120     -- census.a.list bound
M.FRIEND_MAX = 40      -- census.h.friends bound (BUG-027)
-- BUG-338 (Run 15c Inkintense y379: 32 civilians stood in the killing field between O1 and B1, a part of Kern+ there,
-- when the war cave dragon broke O1; PREDATOR_FAR said "nearest citizen 63 tiles" while it killed them 8-11 tiles away):
-- census.u.atk = the civilians on the attack side of the inner bridge (outside Kern+ and the refuge, or on an intake tile:
-- zones Z1/Z2 and the killboxes, even where Kern+ covers them), atk_ids <= OUT_MAX of them; every hostile entry carries
-- da = the distance to the nearest civilian anywhere (Kern+, killing field, refuge; only those within DA_DZ levels: a
-- cavern under the fort is no neighbour), db = the xy distance to the nearest bridge footprint within BD_DZ levels (-1
-- none) and, for a building destroyer or a great danger, pd = 1 when its own path ends inside the fort (a Kern+ tile, an
-- intake or past-B1 zone, or within BD_NEAR tiles of a bridge): DF's unit.path.dest, the last step of the path it walks
M.DA_DZ, M.BD_DZ, M.BD_NEAR = 3, 3, 30
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
  -- intake waves: the attack zones between O1 and B1 (zone 1) and the zones past B1 (zone 2)
  g.zin, g.zpast = {}, {}
  local zones = type(man.zones) == 'table' and man.zones or {}
  for _, e in ipairs({{'Z1', g.zin}, {'Z2', g.zin}, {'Z3', g.zpast}, {'Z4', g.zpast}}) do
    for _, bb in ipairs(type(zones[e[1]]) == 'table' and zones[e[1]] or {}) do
      if type(bb) == 'table' and #bb == 6 then e[2][#e[2] + 1] = bb end
    end
  end
  for _, kb in ipairs(type(man.killboxes) == 'table' and man.killboxes or {}) do
    if type(kb) == 'table' and type(kb.bbox) == 'table' and #kb.bbox == 6 then g.zin[#g.zin + 1] = kb.bbox end
  end
  return g
end

local function in_boxes(boxes, x, y, z)
  for _, b in ipairs(boxes) do
    if x >= b[1] and x <= b[4] and y >= b[2] and y <= b[5] and z >= b[3] and z <= b[6] then return true end
  end
  return false
end

local function threat_armed(K)
  local ok, flag = K.call('threat', 'armed')
  return ok and flag == 1
end

M.GHOST_MAX = 200      -- BUG-062: census.g.ids, the fort's own ghosts met in a hostile scan

---------------------------------------------------------------- water (BUG-494, BUG-496)
-- Run 16b i2 Brotherarrow y372-y375: a Hibbertopterus pack in the brook drowned five citizens (fisher, carpenter) with
-- `threat 0 vis`: a unit in the water is on no walk group of the citizens, so the wild-danger rule below (same group, near an
-- entrance) never listed it; the deaths read `missing`, then `drowned` five days later, without a place or a cause. Only
-- sense and snapshot read tiles and walk the unit list: care asks through water_at and scene. Every DF read is guarded.
local WW = {R = 8, SCENE_MAX = 4}     -- R: tiles round a drowned body searched for wild units; SCENE_MAX: units named

-- 'water n/7' for a tile with water (flow_size >= 1, liquid water), else nil. Magma is not water.
function WW.wet(x, y, z)
  local ok, kind = pcall(function()
    local pos = {x = x, y = y, z = z}
    if not dfhack.maps.isValidTilePos(pos) then return nil end
    local des = dfhack.maps.getTileFlags(pos)
    if des == nil or des.hidden then return nil end
    local fs = tonumber(des.flow_size) or 0
    if fs < 1 then return nil end
    local lt = des.liquid_type
    if not (lt == 0 or lt == false or lt == nil or lt == 'Water') then return nil end
    return string.format('water %d/7', fs)
  end)
  if ok then return kind end
end

-- the water at the tile or on one of the 8 tiles round it (same level): kind ('water 3/7', 'beside water 3/7'), its tile
function WW.near(x, y, z)
  local k = WW.wet(x, y, z)
  if k then return k, {x, y, z} end
  for dx = -1, 1 do
    for dy = -1, 1 do
      if dx ~= 0 or dy ~= 0 then
        k = WW.wet(x + dx, y + dy, z)
        if k then return 'beside ' .. k, {x + dx, y + dy, z} end
      end
    end
  end
end

-- the tile's material when it is a brook or a river bed ('brook' | 'river'), else nil
function WW.stream(x, y, z)
  local ok, m = pcall(function()
    local tt = dfhack.maps.getTileType(x, y, z)
    if tt == nil then return nil end
    local a = df.tiletype.attrs[tt]
    local name = a and df.tiletype_material[a.material]
    if name == 'BROOK' then return 'brook' elseif name == 'RIVER' then return 'river' end
  end)
  if ok then return m end
end

function WW.race_name(u)
  local ok, n = pcall(function() return dfhack.units.getRaceName(u) end)
  if ok and type(n) == 'string' and n ~= '' then return n:sub(1, 40) end
  return tostring(u.race)
end

local function size_cur(u) return u.body.size_info.size_cur end      -- no closure per unit: the scan touches every unit
function WW.size_of(u)
  local ok, sz = pcall(size_cur, u)
  if ok and math.type(sz) == 'integer' and sz >= 0 then return sz end
end

---------------------------------------------------------------- citizens (§6.1)
local P = {x = 0, y = 0, z = 0}   -- scratch coord for burrow lookups (a table coord, cf. item.lua:12)

local function scan_citizens(K, now)
  local U, B = dfhack.units, dfhack.burrows
  local g = geometry(K)
  st.geo = g
  local kb = B.findByName(g.kern)
  local rb = B.findByName(g.refuge)
  -- BUG-035: the recall's burrows (reflex.recall via recount), resolved per scan (never keep a DF pointer)
  local awb
  for _, n in ipairs(st.aw_to or {}) do
    local b = B.findByName(n)
    if b then awb = awb or {}; awb[#awb + 1] = b end
  end
  local away, aw, ain, awi = 0, {}, 0, {}      -- BUG-621: ain / awi = the away ones that stand inside Kern+ or the refuge walls
  -- include_insane (API.txt:1696); the sane ones are exactly getCitizens() (isCitizen/isResident
  -- default to sane only, API.txt:1464-1470). Insane ones only count on bridge footprints.
  local all = U.getCitizens(false, true)
  local ids, sids, out, out_pos, insane = {}, {}, {}, {}, {}
  local civ_pos, atk, atk_n = {}, {}, 0           -- BUG-338
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
      local is_out = false
      if sane and not soldier and kb and not B.isAssignedTile(kb, P) and not (rb and B.isAssignedTile(rb, P)) then
        is_out = true
        outside = outside + 1
        out[#out + 1] = id
        out_pos[#out_pos + 1] = {x = x, y = y, z = z}
      end
      -- BUG-338: every civilian's position (the predator distance da), and the ones on the attack side of B1
      if sane and not soldier then
        civ_pos[#civ_pos + 1] = {x = x, y = y, z = z}
        if is_out or in_boxes(g.zin, x, y, z) then
          atk_n = atk_n + 1
          if #atk < M.OUT_MAX then atk[#atk + 1] = id end
        end
      end
      if awb and sane and not soldier then
        local inb = false
        for _, b in ipairs(awb) do
          if B.isAssignedTile(b, P) then inb = true; break end
        end
        if not inb then
          away = away + 1; aw[#aw + 1] = id
          if kb and not is_out then ain = ain + 1; awi[#awi + 1] = id end
        end
      end
    end
  end
  table.sort(ids)
  table.sort(sids)
  table.sort(out)
  table.sort(insane)
  local out_ids = {}
  for i = 1, math.min(#out, M.OUT_MAX) do out_ids[i] = out[i] end
  st.out_pos, st.civ_pos = out_pos, civ_pos
  table.sort(atk)
  st.cit_tick, st.cit_due = now.tick, false
  K.census.u = {tick = now.tick, cit = cit, adults = adults, children = cit - adults, soldiers = soldiers,
                ids = ids, soldier_ids = sids, outside = kb and outside or -1, outside_ids = out_ids,
                on_bridge = on_bridge, stressed = stressed, caged = st.caged or {}, units = st.units or -1,
                insane_ids = insane, atk = kb and atk_n or -1, atk_ids = atk}
  if awb then
    table.sort(aw)
    local l, to = {}, {}
    for i = 1, math.min(#aw, M.AWAY_MAX) do l[i] = aw[i] end
    for i, n in ipairs(st.aw_to) do to[i] = n end
    K.census.u.away, K.census.u.away_ids, K.census.u.away_to = away, l, to
    -- BUG-621 (Run 16d i4 Trumpetrealms y431: 'recall: 5 of 7 still outside Tiefe+, +41 more out since' 9 ticks after the alert moved from
    -- Kern+ to Tiefe+: those 41 stood inside Kern+ and had not yet walked down, no one had gone out): the away ones inside the walls
    table.sort(awi)
    local li = {}
    for i = 1, math.min(#awi, M.AWAY_MAX) do li[i] = awi[i] end
    K.census.u.away_in, K.census.u.away_in_ids = ain, li
  end
  st.pub = {pop = {cit = cit, adults = adults, soldiers = soldiers}}
end

---------------------------------------------------------------- hostiles (§6.2), sliced
local function hscan_begin(K, now, armed)
  local g = st.geo or geometry(K)
  st.geo = g
  st.hs = {i = 0, seen = {}, list = {}, keys = {}, vis = 0, inv = 0, great = 0, undead = 0, inside = 0, crazed = 0,
           zin = 0, zpast = 0, dz = 0, dz_o1 = -1, bd = 0, an = 0, rin = 0,
           near_o1 = -1, near_cit = -1, near_bridge = {}, caged = {}, units = 0, tick = now.tick, nben = 0, benign = {}, herb = 0, herb_d = -1,
           armed = armed and 1 or 0, geo = g, out_pos = st.out_pos or {}, civ_pos = st.civ_pos or {},
           count = now.tick - (st.count_tick or -M.COUNT_EVERY) >= M.COUNT_EVERY, animals = {}}
  for _, b in ipairs(g.bridges) do st.hs.near_bridge[b.name] = -1 end
  st.hs.K = K                                   -- FR-33 entrances: fetched on the first predator candidate
  -- BUG-702: the plant eaters reflex cleared (BUG-672, 3 quiet days, or the operator): no bridge, burrow or water event counts them
  local okpp, pp = K.call('reflex', 'pv_plant')
  st.hs.pvp = okpp and type(pp) == 'table' and next(pp) ~= nil and pp or nil
  st.hs.vpp = 0
  local okw, wb = K.call('gate', 'watch')       -- BUG-027: friendly non-citizens near the footprints with work
  st.hs.watch = okw and type(wb) == 'table' and #wb > 0 and wb or nil
  st.hs.friends, st.hs.fseen = {}, {}
  st.hs.ghosts = {}                              -- BUG-062: the fort's own ghosts met in the scan
  st.hs.wl, st.hs.wseen = {}, {}                 -- BUG-494: wild beasts at water met in the scan
  st.h_tick = now.tick
end

-- FR-33: where a wild predator matters (seal.entrances), once per scan and only when a candidate needs it
local function entrances(hs)
  if hs.ent_done then return hs.ent end
  hs.ent_done = true
  local oke, ent, r = hs.K.call('seal', 'entrances')
  if oke and type(ent) == 'table' and #ent > 0 then hs.ent, hs.ent_r = ent, math.tointeger(r) or 25 end
  return hs.ent
end

local function minpos(cur, d) if cur < 0 or d < cur then return d end return cur end

-- BUG-027: a visible friendly non-citizen in one of gate's watch boxes -> census.h.friends (only while gate watches)
local function friend(hs, u, U)
  local fr = hs.friends
  if #fr >= M.FRIEND_MAX or hs.fseen[u.id] then return end
  local p = u.pos
  local x, y, z = p.x, p.y, p.z
  local hit = false
  for _, b in ipairs(hs.watch) do
    if x >= b[1] and x <= b[4] and y >= b[2] and y <= b[5] and z >= b[3] and z <= b[6] then hit = true; break end
  end
  if not hit then return end
  if U.isCitizen(u, true) or U.isResident(u, true) then return end      -- census.u has them
  if not U.isVisible(u) or U.isHidden(u) or u.flags1.caged then return end
  local k
  if U.isTame(u) then k = 'animal'
  elseif U.isMerchant and U.isMerchant(u) then k = 'merchant'
  elseif (U.isVisitor and U.isVisitor(u)) or (U.isDiplomat and U.isDiplomat(u)) then k = 'visitor'
  else return end                                                       -- wild animals and the rest
  hs.fseen[u.id] = true
  fr[#fr + 1] = {id = u.id, k = k}
end

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
  local ent = hs and entrances(hs)
  if not ent then return true end                     -- no entrance known: every predator on the group counts
  local des = dfhack.maps.getTileFlags(u.pos)
  if des and not des.hidden and not des.outside then return true end
  local x, y, z = u.pos.x, u.pos.y, u.pos.z
  for _, p in ipairs(ent) do
    if math.max(math.abs(x - p[1]), math.abs(y - p[2]), math.abs(z - p[3])) <= hs.ent_r then return true end
  end
  return false
end

-- the caste raw flags, cached per race and caste for the session (raws do not change while a map is loaded), one raws
-- read per pair: LARGE_PREDATOR (p) and, for intake waves (Gordon 2026-10-16), a flag that walls, traps or a raised
-- gate do not stop (dz: BUILDINGDESTROYER, TRAPAVOID, FLIER; an unknown flag name reads as false). BUG-030 (Run 10
-- y421: six trolls destroyed O1, B1 and B2): bd = a building destroyer, the caste flag or the token's level
-- [BUILDINGDESTROYER:1|2], which the caste raws keep as a number (caste_raw.misc.buildingdestroyer [? live]); both are
-- read, a missing field reads as none
-- Run 11 (site98 y439: one ELK_BIRD invader 28188, a mount left behind at the map edge, held the fort in ALERT and a
-- lockdown for 45 days): an = an animal, a caste the raws say can neither learn nor speak (CAN_LEARN and CAN_SPEAK both
-- read false; the creature description's "intelligent" [? live: DF 53 flag names, as DFHack's own scripts read them]),
-- or, when those two do not read false, a MOUNT/MOUNT_EXOTIC caste not known to learn or speak. A missing or unreadable
-- flag is no evidence: the invader stays an invader.
local pred_raw = {}
local DZ_FLAGS = {'BUILDINGDESTROYER', 'TRAPAVOID', 'FLIER'}
local function flag(c, f)
  local ok, v = pcall(function() return c.flags[f] end)
  if ok then return v end
end
local function raw_read(race, caste)
  local r = df.creature_raw.find(race)
  local c = r ~= nil and r.caste[caste]
  if not c then return {p = false, dz = false, bd = false, an = false, cv = false} end
  local e = {p = c.flags.LARGE_PREDATOR == true, dz = false, bd = false, an = false, cv = flag(c, 'CARNIVORE') == true}
  for _, f in ipairs(DZ_FLAGS) do
    if flag(c, f) == true then
      e.dz = true
      if f == 'BUILDINGDESTROYER' then e.bd = true end
    end
  end
  local ok, n = pcall(function() return c.misc.buildingdestroyer end)
  if ok and type(n) == 'number' and n > 0 then e.dz, e.bd = true, true end
  local learn, speak = flag(c, 'CAN_LEARN'), flag(c, 'CAN_SPEAK')
  e.an = (learn == false and speak == false)
         or (learn ~= true and speak ~= true and (flag(c, 'MOUNT') == true or flag(c, 'MOUNT_EXOTIC') == true))
  return e
end
local NO_RAW = {p = false, dz = false, bd = false, an = false, cv = false}
local function raw_flags(u)
  local race, caste = u.race, u.caste
  if race == nil then return NO_RAW end
  local row = pred_raw[race]
  if row == nil then row = {}; pred_raw[race] = row end
  local v = row[caste or -1]
  if v == nil then
    local ok, e = pcall(raw_read, race, caste)
    v = ok and type(e) == 'table' and e or NO_RAW
    row[caste or -1] = v
  end
  return v
end
local function large_predator(u) return raw_flags(u).p end



-- BUG-421 (Run 16d i4 Mazelanterns y386: a wild PLATYBELODON, a grazer without the LARGE_PREDATOR flag, struck down two
-- citizens inside the fort; no PREDATOR, no INTRUDER, threat 0): a wild unit that killed a citizen (care passes the
-- death incident's killer through M.mark_killer) is a large predator from then on, for KILLER_DAYS game days
M.KILLER_DAYS = 30
M.KILLER_MAX = 20
local function killer(u)
  local k = st and st.killers
  local t = k and k[u.id]
  if not t then return false end
  local tick = st.hs and st.hs.tick or t
  if tick - t > M.KILLER_DAYS * 1200 then k[u.id] = nil; return false end
  return true
end

-- BUG-439 (Run 16a i1 Syrupobeyed y373: a wild WOOLLY MAMMOTH, no LARGE_PREDATOR flag, walked into the fort and struck down two
-- citizens in one step; no PREDATOR, no INTRUDER, threat 0: BUG-421's killer mark only exists AFTER the first death): a wild
-- unit of a large body (size_cur >= BIG_WILD cm3, a dwarf is 60000: a mammoth, rhino, elk, bear, camel) on a tile that is not
-- open to the sky (inside the rock of the fort, a roofed room) is a wild danger before it killed anyone. Never a tame or
-- fort-controlled unit, a citizen, resident, merchant (the caravan's pack animals), diplomat, visitor, a caged or chained one,
-- or an invader (its own rules). Outside under the sky a grazer stays wildlife until it kills (mark_killer).
M.BIG_WILD = 300000
local function big_wild(u)
  local ok, yes = pcall(function()
    local sz = u.body.size_info.size_cur                    -- a field read first: only a big body costs API calls
    if math.type(sz) ~= 'integer' or sz < M.BIG_WILD then return false end
    local U = dfhack.units
    if U.isTame(u) or U.isFortControlled(u) or U.isCitizen(u, true) or U.isResident(u, true) or U.isInvader(u) then
      return false
    end
    if U.isMerchant and U.isMerchant(u) then return false end
    local f1, f2 = u.flags1, u.flags2
    if f1.merchant or f1.diplomat or f1.caged or f1.chained or f2.visitor then return false end
    local des = dfhack.maps.getTileFlags(u.pos)
    return des ~= nil and not des.hidden and not des.outside
  end)
  return ok and yes == true
end

-- BUG-532 (Run 16a i1 Basementflew y408-y409: wild JURASSIC_STEGOSAURUS / DIPLODOCUS, BENIGN plant eaters of 315,000 to
-- 1,180,000 cm3 that BUG-439 counts as big wild beasts on a roofed tile, 47-76 tiles from the nearest citizen: PREDATOR after
-- PREDATOR, each a Kern+ lockdown with the clock at 30 t/s instead of 250): a big wild HERBIVORE (no LARGE_PREDATOR, no
-- CARNIVORE, no killer mark) is wildlife while it is farther than HERB_NEAR tiles from every citizen; it counts (BUG-439) once
-- it is within HERB_NEAR of one or inside Kern+ / past B1. census.h.herb = how many stood by, herb_d the nearest one's distance
M.HERB_NEAR = 20
local function herbivore(u)
  local rf = raw_flags(u)
  return not (rf.p or rf.cv or killer(u)) and big_wild(u)
end

local function predator(u, hs)
  if not (large_predator(u) or killer(u) or big_wild(u)) then return false end
  local ok, yes = pcall(function()
    -- off-map units (pos -30000) crashed DF 53 in getWalkableGroup (live L6): validate first
    if not dfhack.maps.isValidTilePos(u.pos) then return false end
    local g = citizens_group()
    if not (g == nil or dfhack.maps.getWalkableGroup(u.pos) == g) then return false end
    return near_entrance(u, hs)
  end)
  return ok and yes == true
end

-- BUG-495 (Run 16c i3 Sealcertain: PREDATOR without race or size, inspect unit did not know the unit): how a unit is
-- reached from the citizens' walk group: 1 = it stands on it, 2 = a bank tile beside it does (a unit in the water: a soldier
-- can strike it from the bank), 0 = neither (a cavern, another level), nil = unknown (no citizen group, an unreadable tile)
local function reach_of(u)
  local ok, r = pcall(function()
    local cg = citizens_group()
    if not cg then return nil end
    local p = u.pos
    local function grp(x, y)
      local q = {x = x, y = y, z = p.z}
      if not dfhack.maps.isValidTilePos(q) then return nil end
      return dfhack.maps.getWalkableGroup(q)
    end
    if grp(p.x, p.y) == cg then return 1 end
    for dx = -1, 1 do
      for dy = -1, 1 do
        if (dx ~= 0 or dy ~= 0) and grp(p.x + dx, p.y + dy) == cg then return 2 end
      end
    end
    return 0
  end)
  if ok then return r end
end

-- BUG-494 (Run 16b i2 Brotherarrow y372-y375: a Hibbertopterus pack in the brook drowned five citizens, `threat 0 vis`, no
-- PREDATOR): a wild unit in or beside water is on no walk group of the citizens, so predator() dropped it. A wild, visible
-- unit that is a large predator (raws), a marked killer or of a large body (size_cur >= WATER.big cm3, a dwarf is 60000)
-- and stands in or beside water is a WATER BEAST: census.w, the event WATER_PREDATOR (once per unit and WATER.rearm
-- ticks), the fishers released (economy fish_want reads census.w.hold). Never a hostile (no lockdown, no siege mode): the
-- brook is no entrance; the player decides on the sortie.
M.WATER = {big = 100000, near = 60, hold = 2400, rearm = 7200, max = 10, herb = 3600, herb_gap = 2400}
local function civ_dist(hs, x, y, z)
  local best = -1
  for _, p in ipairs(hs.civ_pos) do
    local dzc = math.abs(z - p.z)
    if dzc <= M.DA_DZ then best = minpos(best, math.max(math.abs(x - p.x), math.abs(y - p.y), dzc)) end
  end
  return best
end

local function water_beast(hs, u, U)
  local W = M.WATER
  if #hs.wl >= W.max or hs.wseen[u.id] then return end
  local rf = raw_flags(u)
  local sz
  if not (rf.p or killer(u)) then
    sz = WW.size_of(u)
    if not (sz and sz >= W.big) then return end
  else
    sz = WW.size_of(u)
  end
  if U.isTame(u) or U.isFortControlled(u) or U.isCitizen(u, true) or U.isResident(u, true) or U.isInvader(u) then return end
  if (U.isMerchant and U.isMerchant(u)) or not U.isVisible(u) or U.isHidden(u) then return end
  local f1, f2 = u.flags1, u.flags2
  if f1.merchant or f1.diplomat or f1.caged or f1.chained or f2.visitor then return end
  if not dfhack.maps.isValidTilePos(u.pos) then return end
  local x, y, z = u.pos.x, u.pos.y, u.pos.z
  local kind = WW.near(x, y, z)
  if not kind then return end
  hs.wseen[u.id] = true
  -- BUG-702 (Run 16b i2 Whirledrampart y419-y423: WATER_PREDATOR 110 / 123 / 103 times for three woolly mammoths that never attacked, every
  -- 7,200 ticks, class A: the follow wake budget went on them): a plant eater (no carnivore, no killer mark) that stood at the water for
  -- WATER.herb ticks without a kill, or one reflex cleared, is wildlife: no WATER_PREDATOR, no fisher hold. It counts again the moment it
  -- kills (killer mark) or has been out of the water scan for WATER.herb_gap ticks
  if not (rf.p or rf.cv or killer(u)) then
    local wh = st.wh
    if not wh then wh = {}; st.wh = wh end
    local rec = wh[u.id]
    if not rec or hs.tick - rec.last > W.herb_gap then rec = {t0 = hs.tick, last = hs.tick}; wh[u.id] = rec end
    rec.last = hs.tick
    if (hs.pvp and hs.pvp[u.id]) or hs.tick - rec.t0 >= W.herb then return end
  end
  local e = {id = u.id, x = x, y = y, z = z, sz = sz, rn = WW.race_name(u), p = rf.p and 1 or nil, wt = kind,
             st = WW.stream(x, y, z), rc = reach_of(u), dc = civ_dist(hs, x, y, z)}
  if killer(u) then e.kl = 1 end
  hs.wl[#hs.wl + 1] = e
end

local function try_num(f) local ok, v = pcall(f); return ok and type(v) == 'number' and v or nil end

-- M3 / BUG-111 (Run 14 y707 notes 94 and 96: an "invader" of size 6486 held the fort in BREACH for 26 days and the
-- soldiers Gordon sent stood beside it doing nothing): the flags a player sees on the unit sheet. An invader that is a
-- merchant, diplomat, visitor, restrained (bound) or a child is no hostile to the player; the first reason that applies
-- is returned (nil: a hostile). An unconscious one stays counted (it wakes up) and is only marked (entry.uc).
local function benign_why(u, U)
  local function yes(f) local ok, v = pcall(f); return ok and v == true end
  if yes(function() return u.flags1.merchant end) or (U.isMerchant and yes(function() return U.isMerchant(u) end)) then
    return 'merchant'
  end
  if yes(function() return u.flags1.diplomat end) or (U.isDiplomat and yes(function() return U.isDiplomat(u) end)) then
    return 'diplomat'
  end
  -- an invited visitor: the raw flag, and none of the flags an ambusher, a thief or a marauder carries (never a guess from an
  -- API predicate: a real attacker must stay a hostile)
  if yes(function() return u.flags2.visitor end) and not yes(function() return u.flags2.visitor_uninvited end)
     and not yes(function() return u.flags1.active_invader end) and not yes(function() return u.flags1.marauder end) then
    return 'visitor'
  end
  -- BUG-144 (live i3: DF 53.16 has no unit_flags2.restrained; reading it raised and pcall hid it): bound to a chain is
  -- flags1.chained (DF sets it again every tick while the chain holds); a caged unit never reaches here (census.h.caged)
  if yes(function() return u.flags1.chained end) then return 'restrained' end
  if yes(function() return U.isChild(u) end) or yes(function() return U.isBaby(u) end) then return 'child' end
end
M.BENIGN_MAX = 10      -- census.h.benign: units left out of the hostiles, with the reason

-- per unit: 1 call for an inactive (dead, gone) unit, 3-4 for ordinary ones; the full check only for
-- hostile candidates. An inactive unit is never a hostile (the candidate path drops it too), it only counts
-- as visible in the unit count.
local function consider(hs, u)
  local U = dfhack.units
  if not U.isActive(u) then
    if hs.count and U.isVisible(u) and not U.isHidden(u) then hs.units = hs.units + 1 end
    return 1
  end
  water_beast(hs, u, U)                                -- BUG-494: a big or predatory wild unit in or beside water
  local undead = U.isUndead(u)
  if not (undead or U.isDanger(u) or (not U.isTame(u) and predator(u, hs))) then
    if hs.count and U.isVisible(u) and not U.isHidden(u) then
      hs.units = hs.units + 1
      animal(hs, u, U)
    end
    if hs.watch then friend(hs, u, U) end
    return 1
  end
  local id = u.id
  if hs.seen[id] then return 1 end                     -- the vector may shift between slices
  hs.seen[id] = true
  if not U.isVisible(u) or U.isHidden(u) then return 4 end      -- active: checked first in consider
  hs.units = hs.units + 1
  if u.flags1.caged then hs.caged[#hs.caged + 1] = id; return 5 end
  local inv = U.isInvader(u)
  if not inv then
    -- own units are never hostiles: berserk/insane citizens and residents, undead citizens, pets
    if U.isCitizen(u, true) or U.isResident(u, true) then
      if not (U.isCitizen(u) or U.isResident(u)) then hs.crazed = hs.crazed + 1 end   -- insane only
      return 7
    end
    if U.isTame(u) or U.isFortControlled(u) then
      if hs.watch then friend(hs, u, U) end
      return 7
    end
    -- live L1b: the ghost of a dead citizen (isUndead, isOwnGroup) walked into Kern+ and held the fort in
    -- BREACH for days; an own ghost is care's job (slab, burial), not the siege reflex's
    -- live L3: a berserk child's ghost is no longer isOwnGroup (berserk dwarves leave the group); as a ghost of
    -- the fort's civilization it is still an own ghost. Counted as a hostile inside Kern+ it held the fort in
    -- BREACH: every civilian sat in Tiefe+, nobody pulled a lever, buried the body or fetched a drink
    if U.isGhost and U.isGhost(u) and ((U.isOwnGroup and U.isOwnGroup(u))
                                       or (u.civ_id ~= -1 and u.civ_id == df.global.plotinfo.civ_id)) then
      -- BUG-062 (Run 14 note 52: the brief said 12 ghosts, a count over the units 30): care's ghost number reads
      -- census.g, the ghosts met here (sense is the one that walks the unit list)
      if #hs.ghosts < M.GHOST_MAX then hs.ghosts[#hs.ghosts + 1] = id end
      return 7
    end
  end
  -- M3 (BUG-111): an invader DF does not treat as hostile (merchant, diplomat, visitor, restrained, child) is neither
  -- counted nor listed; census.h.benign names it and the reason. A friend near a watched footprint is still reported.
  if inv and not U.isUndead(u) and not U.isGreatDanger(u) then
    local why = benign_why(u, U)
    if why then
      hs.nben = hs.nben + 1
      if #hs.benign < M.BENIGN_MAX then hs.benign[#hs.benign + 1] = {id = id, why = why} end
      if hs.watch then friend(hs, u, U) end
      return 6
    end
  end
  local x, y, z = U.getPosition(u)
  if not x then return 7 end
  local great = U.isGreatDanger(u)      -- megabeasts, titans, forgotten beasts, demons (Lua API.txt:1672)
  local rf = raw_flags(u)
  -- Run 11 (site98 y439): an invader whose raws make it an animal (rf.an: a mount or pet the invaders left behind,
  -- ELK_BIRD 28188 at the map edge for 45 days) counts like a wild animal: not in inv (no arrival lockdown of its own;
  -- threat and reflex apply the predator rules), k 'danger' with an = 1, and the walk-group rule below applies to it
  -- BUG-338 (Run 15c Inkintense y379: the army's war cave dragon was listed as a wild danger, PREDATOR_FAR "no
  -- lockdown" at the map edge, then toppled the raised O1 and killed 5 at B1): a building destroyer is never a mount left
  -- behind; it stays an invader (k 'inv', counted in inv) whatever its raws say about learning
  local an = inv and rf.an == true and not rf.bd and not great and not undead
  if an then inv = false end
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
  local herb_in = false                          -- BUG-532: inside Kern+ or past B1 a plant eater always counts
  if hs.kb then
    P.x, P.y, P.z = x, y, z
    herb_in = dfhack.burrows.isAssignedTile(hs.kb, P) == true
  end
  local hbeast = not (inv or great or undead) and herbivore(u)       -- BUG-554: entry.hb marks it for reflex
  if hbeast and not (herb_in or in_boxes(hs.geo.zpast, x, y, z)) then
    -- BUG-532: a far plant eater is wildlife; the distance is the nearest citizen (outside Kern+ or on its levels)
    -- BUG-554: on its levels (DA_DZ) for both lists: a miner 14 levels down in a shaft is no neighbour of a stegosaurus on the
    -- surface (Run 16a i1 y416: PREDATOR for a stegosaurus 50 and more tiles from the fort, every 2,000 ticks)
    local dh = -1
    for _, p in ipairs(hs.out_pos) do
      local dzc = math.abs(z - p.z)
      if dzc <= M.DA_DZ then
        local d = math.max(math.abs(x - p.x), math.abs(y - p.y), dzc)
        if dh < 0 or d < dh then dh = d end
      end
    end
    for _, p in ipairs(hs.civ_pos) do
      local dzc = math.abs(z - p.z)
      if dzc <= M.DA_DZ then
        local d = math.max(math.abs(x - p.x), math.abs(y - p.y), dzc)
        if dh < 0 or d < dh then dh = d end
      end
    end
    if dh < 0 or dh > M.HERB_NEAR then
      hs.herb = hs.herb + 1
      if dh >= 0 and (hs.herb_d < 0 or dh < hs.herb_d) then hs.herb_d = dh end
      return 7
    end
  end
  hs.vis = hs.vis + 1
  if great then hs.great = hs.great + 1 end
  if undead then hs.undead = hs.undead + 1 end
  if inv then hs.inv = hs.inv + 1 end
  if an then hs.an = hs.an + 1 end
  local g, d_o1, dcit = hs.geo, -1, -1
  local o = g.o1
  if o then
    local c = o.c
    d_o1 = math.max(math.abs(x - c.x), math.abs(y - c.y), math.abs(z - c.z))
    hs.near_o1 = minpos(hs.near_o1, d_o1)
  end
  local nb, db = hs.near_bridge, -1
  -- BUG-702 (Run 16b i2 Whirledrampart y419-y423: cleared woolly mammoths within 30 tiles of B1 refused every 'lever B1 down' and kept the
  -- raised bridge between 25-31 citizens and their food and drink): a plant eater reflex cleared (and no killer mark) is not a
  -- hostile of any bridge: it keeps its list entry (pp = 1) but sets no near_bridge distance, and counts in census.h.vpp
  local clr = hbeast and hs.pvp ~= nil and hs.pvp[id] == true and not killer(u)
  if clr then hs.vpp = hs.vpp + 1 end
  for _, b in ipairs(clr and {} or g.bridges) do               -- Chebyshev distance to the footprint box
    local f = b.fp
    local dx = x < f[1] and f[1] - x or (x > f[4] and x - f[4] or 0)
    local dy = y < f[2] and f[2] - y or (y > f[5] and y - f[5] or 0)
    local dz = z < f[3] and f[3] - z or (z > f[6] and z - f[6] or 0)
    local d = math.max(dx, dy, dz)
    local cur = nb[b.name]
    if cur < 0 or d < cur then nb[b.name] = d end
    if dz <= M.BD_DZ then db = minpos(db, math.max(dx, dy)) end       -- BUG-338: on the bridges' own levels
  end
  for _, p in ipairs(hs.out_pos) do
    local d = math.max(math.abs(x - p.x), math.abs(y - p.y), math.abs(z - p.z))
    if dcit < 0 or d < dcit then dcit = d end
  end
  local da = -1                                  -- BUG-338: the nearest civilian anywhere, within DA_DZ levels
  for _, p in ipairs(hs.civ_pos) do
    local dzc = math.abs(z - p.z)
    if dzc <= M.DA_DZ then da = minpos(da, math.max(math.abs(x - p.x), math.abs(y - p.y), dzc)) end
  end
  if dcit >= 0 then hs.near_cit = minpos(hs.near_cit, dcit) end
  local zn, ik = 0, false
  if hs.kb then
    P.x, P.y, P.z = x, y, z
    if dfhack.burrows.isAssignedTile(hs.kb, P) then hs.inside, zn, ik = hs.inside + 1, 2, true end
  end
  if zn == 0 and in_boxes(g.zpast, x, y, z) then zn = 2 end
  if zn == 0 and in_boxes(g.zin, x, y, z) then zn = 1 end
  if zn == 2 then hs.zpast = hs.zpast + 1 elseif zn == 1 then hs.zin = hs.zin + 1 end
  -- intake waves: a hostile an intake must not let in (Gordon 2026-10-16): a great danger or a dz raw flag; BUG-030: a
  -- building destroyer (bd, also in dz) sends the siege into its deep defense
  local dz = (great or rf.dz) and 1 or 0
  if dz == 1 then
    hs.dz = hs.dz + 1
    if d_o1 >= 0 then hs.dz_o1 = minpos(hs.dz_o1, d_o1) end
  end
  -- BUG-049 (Run 13 y525: the citizens found the refuge occupied): the hostiles inside the refuge burrow are counted
  -- and listed first, so a full list (the 40 nearest to O1) never hides one
  local rin = false
  if hs.rb and not clr then
    P.x, P.y, P.z = x, y, z
    if dfhack.burrows.isAssignedTile(hs.rb, P) then rin, hs.rin = true, hs.rin + 1 end
  end
  local list = hs.list
  local entry = {id = id, x = x, y = y, z = z, d_o1 = d_o1, dc = dcit, zn = zn, dz = dz, da = da, db = db,
                 k = great and 'great' or (undead and 'undead') or (inv and 'inv') or 'danger'}
  -- BUG-338: where a building destroyer or great danger is walking to (DF: path.path x/y/z[0] is its next step, the
  -- last entry path.dest; the path crosses levels): into the fort is never "far", whatever the distance now
  if (rf.bd or great) and zn < 2 then
    local okp, dx, dy, dzp = pcall(function() local q = u.path.dest; return q.x, q.y, q.z end)
    if okp and math.type(dx) == 'integer' and dx >= 0 and math.type(dy) == 'integer' and math.type(dzp) == 'integer' then
      local inf = in_boxes(g.zin, dx, dy, dzp) or in_boxes(g.zpast, dx, dy, dzp)
      if not inf and hs.kb then
        P.x, P.y, P.z = dx, dy, dzp
        inf = dfhack.burrows.isAssignedTile(hs.kb, P) == true
      end
      if not inf then
        for _, b in ipairs(g.bridges) do
          local f = b.fp
          local ex = dx < f[1] and f[1] - dx or (dx > f[4] and dx - f[4] or 0)
          local ey = dy < f[2] and f[2] - dy or (dy > f[5] and dy - f[5] or 0)
          local ez = dzp < f[3] and f[3] - dzp or (dzp > f[6] and dzp - f[6] or 0)
          if ez <= M.BD_DZ and math.max(ex, ey) <= M.BD_NEAR then inf = true; break end
        end
      end
      if inf then entry.pd = 1 end
    end
  end
  if rin then entry.rf = 1 end
  if clr then entry.pp = 1 end                     -- BUG-702: a plant eater reflex cleared (bridge, refuge and rescue checks skip it)
  if ik then entry.ik = 1 end                      -- M3: inside Kern+ itself (zn 2 also covers zones Z3/Z4)
  if rf.bd then entry.bd, hs.bd = 1, hs.bd + 1 end
  if an then entry.an = 1 end
  -- BUG-065 (Run 14, a gremlin in the caves): the unit's own body size (cm3; a dwarf is 60000) and the large-predator
  -- flag go to the census, so reflex can tell a small harmless intruder from a dangerous one [size field: ? live]
  if hbeast then entry.hb = 1 end                  -- BUG-554: a big wild plant eater (see reflex inside_scan: no lockdown outside Kern+)
  if rf.p or killer(u) or big_wild(u) then entry.pr = 1 end   -- BUG-421: a wild killer is dangerous whatever its raws say; BUG-439: a big wild beast inside
  if killer(u) then entry.kl = 1 end
  if (try_num(function() return u.counters.unconscious end) or 0) > 0 then entry.uc = 1 end    -- M3: it wakes up
  local okz, sz = pcall(function() return u.body.size_info.size_cur end)
  if okz and math.type(sz) == 'integer' and sz >= 0 then entry.sz = sz end
  entry.rn = WW.race_name(u)                       -- BUG-495: the event names race, size and reach
  entry.rc = reach_of(u)
  list[#list + 1] = entry
  -- integer sort key: the zone (past B1, then the intake area), then distance (O1, else nearest outside citizen),
  -- then scan order
  local d = rin and -1 or zn == 2 and 0 or (zn == 1 and 1 or 2 + (d_o1 >= 0 and d_o1 or (dcit >= 0 and dcit or 999999)))
  hs.keys[#hs.keys + 1] = d * 16777216 + #list
  return 10
end

-- one slice of at most M.SLICE_WORK work units (1 per ordinary unit, ~10 per hostile); true when done
local function hscan_slice()
  local hs = st.hs
  hs.kb = dfhack.burrows.findByName(hs.geo.kern)    -- never keep a DF pointer across frames
  hs.rb = dfhack.burrows.findByName(hs.geo.refuge)
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

-- BUG-494: census.w = {tick, n, list (nearest to a citizen first), near (the nearest one's distance, -1 none), hold (1:
-- a beast within WATER.near tiles of a citizen now, or WATER.hold ticks ago: the fishers stay home)}; WATER_PREDATOR (A)
-- for every beast within WATER.near not announced for WATER.rearm ticks. d.reach 1 = on the citizens' walk group, 2 = from a
-- bank, 0 = out of reach; d.cmd = the sortie the squad can be sent on (squad.sortie to its tile)
local function wild_publish(K, hs)
  local W = M.WATER
  local l = hs.wl
  table.sort(l, function(a, b)
    local da, db = a.dc < 0 and 1e9 or a.dc, b.dc < 0 and 1e9 or b.dc
    if da ~= db then return da < db end
    return a.id < b.id
  end)
  local near, fresh = -1, {}
  st.w_ann = st.w_ann or {}
  for _, e in ipairs(l) do
    if e.dc >= 0 and e.dc <= W.near then
      near = minpos(near, e.dc)
      local t = st.w_ann[e.id]
      if t == nil or hs.tick - t >= W.rearm then fresh[#fresh + 1] = e end
    end
  end
  if near >= 0 then st.w_last = hs.tick end
  local hold = (near >= 0 or (st.w_last and hs.tick - st.w_last < W.hold)) and 1 or 0
  K.census.w = {tick = hs.tick, n = #l, list = l, near = near, hold = hold}
  if #fresh == 0 then return end
  local e = fresh[1]
  for _, f in ipairs(fresh) do st.w_ann[f.id] = hs.tick end
  local cmd
  local ok, key = K.call('military', 'sortie_squad')
  if ok and type(key) == 'string' then
    cmd = string.format('dfllm cmd squad.sortie \'{"squad":"%s","target":[%d,%d,%d],"unit":%d,"approve":true}\'', key, e.x, e.y, e.z, e.id)
  end
  local d = {n = #fresh, id = e.id, race = e.rn, pos = {e.x, e.y, e.z}, dc = e.dc, wet = e.wt, fish = hold,
             reach = e.rc, cmd = cmd}
  if e.sz then d.sz = e.sz end
  if e.st then d.stream = e.st end
  if e.kl then d.killer = 1 end
  K.log('warn', 'sense: %d wild beast(s) at water: %s %d (%s) at %d,%d,%d, %d tiles from a citizen', #fresh,
        tostring(e.rn), e.id, tostring(e.wt), e.x, e.y, e.z, e.dc)
  K.emit('WATER_PREDATOR', 'A', string.format('%d wild beast(s) at water: %s %d%s at %d,%d,%d (%s%s), %d tiles from a citizen; %s; '
         .. 'fishers held home%s', #fresh, tostring(e.rn), e.id, e.sz and (' ' .. e.sz .. ' cm3') or '', e.x, e.y, e.z,
         tostring(e.wt), e.st and (', ' .. e.st) or '', e.dc,
         e.rc == 1 and 'on the citizens\' ground' or (e.rc == 2 and 'reachable from the bank' or (e.rc == 0 and 'out of reach'
         or 'reach unknown')), cmd and '; sortie offered' or ''), d)
end

local function hscan_finish(K)
  local hs = st.hs
  st.hs = nil
  table.sort(hs.keys)                            -- plain integer sort: no Lua comparator
  local list = {}
  for i = 1, math.min(#hs.keys, M.LIST_MAX) do list[i] = hs.list[hs.keys[i] % 16777216] end
  table.sort(hs.caged)
  st.caged = hs.caged
  table.sort(hs.ghosts)
  K.census.g = {tick = hs.tick, n = #hs.ghosts, ids = hs.ghosts}
  if hs.count then
    st.units, st.count_tick = hs.units, hs.tick
    K.census.a = {tick = hs.tick, n = #hs.animals, list = hs.animals}
  end
  -- M3 (BUG-111): once per unit, kern.log says which invaders are left out and why
  st.ben_seen = st.ben_seen or {}
  for _, b in ipairs(hs.benign) do
    if not st.ben_seen[b.id] and st.ben_n < 50 then
      st.ben_seen[b.id], st.ben_n = true, st.ben_n + 1
      K.log('info', 'sense: unit %d is an invader by DF\'s flag but no hostile to the player: %s (not counted)', b.id, b.why)
    end
  end
  -- BUG-596: a list cut at LIST_MAX says how far from O1 the cut hostiles are at least (`lo`, the last listed one's distance, only when it
  -- lies outside both zones and O1 is known) and where O1 is (`o1`): water.foe_dist bounds a tile's distance to the unlisted ones with it
  local lo, o1c
  local lastl = #hs.keys > M.LIST_MAX and list[M.LIST_MAX] or nil
  if lastl and lastl.zn == 0 and (lastl.d_o1 or -1) >= 0 and hs.geo and hs.geo.o1 then
    local c = hs.geo.o1.c
    lo, o1c = lastl.d_o1, {c.x, c.y, c.z}
  end
  K.census.h = {tick = hs.tick, vis = hs.vis, lo = lo, o1 = o1c, inv = hs.inv, great = hs.great, undead = hs.undead, inside = hs.inside,
                rin = hs.rin,
                near_o1 = hs.near_o1, near_cit = hs.near_cit, near_bridge = hs.near_bridge, list = list,
                armed = hs.armed, crazed = hs.crazed, friends = hs.friends, zin = hs.zin, zpast = hs.zpast,
                dz = hs.dz, dz_o1 = hs.dz_o1, bd = hs.bd, an = hs.an, nben = hs.nben, benign = hs.benign, herb = hs.herb, herb_d = hs.herb_d, vpp = hs.vpp}
  wild_publish(K, hs)                            -- BUG-494
end

---------------------------------------------------------------- module
function M.init(K)
  st = {cit_due = true, pub = nil, ben_n = 0}
  pred_raw = {}                                  -- another save may bring other raws
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

-- public (BUG-421, care): the unit that killed a citizen (a death incident's killer) is a wild danger from now on. Only
-- a wild unit counts (not a citizen, an invader's kin or a pet: sense's own rules drop those); the next scan is at once.
-- Returns true when it was added
function M.mark_killer(K, id)
  id = math.tointeger(id)
  if not (st and id) then return false end
  local u = df.unit.find(id)
  if not u or dfhack.units.isCitizen(u, true) or dfhack.units.isTame(u) then return false end
  st.killers = st.killers or {}
  local n = 0
  for _ in pairs(st.killers) do n = n + 1 end
  if n >= M.KILLER_MAX and not st.killers[id] then return false end
  st.killers[id] = K.now().tick
  st.h_tick = nil
  K.log('warn', 'sense: unit %d (%s) killed a citizen: a wild danger from now on (PREDATOR inside the fort)', id,
        tostring(dfhack.units.getRaceName and dfhack.units.getRaceName(u) or u.race))
  return true
end

-- public (BUG-035, reflex's recall): the burrows the recall measures arrival in (the sounding civ alert's confining
-- burrows, <= AWAY_NAMES), or nil to stop; the citizens are counted again at once (census.u away, away_ids, away_to)
-- and on every later citizen scan. Returns census.u
function M.recount(K, names)
  local l = {}
  for _, n in ipairs(type(names) == 'table' and names or {}) do
    if type(n) == 'string' and #l < M.AWAY_NAMES then l[#l + 1] = n end
  end
  st.aw_to = #l > 0 and l or nil
  scan_citizens(K, K.now())
  return K.census.u
end

-- public (BUG-496, care's DROWNED event): the living wild units within WW.R tiles (Chebyshev, one level up or down) of a tile,
-- the nearest first (at most WW.SCENE_MAX): {id, race, sz, d, tame}. A citizen, resident, merchant or caged unit is none of them;
-- a tame one is listed (it may have pulled a dwarf in) but flagged. Returns the list
function M.scene(K, x, y, z, skip)
  local out = {}
  local ok = pcall(function()
    local U = dfhack.units
    for _, u in ipairs(df.global.world.units.active) do
      if u.id ~= skip and U.isActive(u) and not U.isDead(u) then
        local p = u.pos
        local d = math.max(math.abs(p.x - x), math.abs(p.y - y))
        if d <= WW.R and math.abs(p.z - z) <= 1 and not U.isCitizen(u, true) and not U.isResident(u, true)
           and not (U.isMerchant and U.isMerchant(u)) and not u.flags1.caged then
          out[#out + 1] = {id = u.id, race = WW.race_name(u), sz = WW.size_of(u), d = d, tame = U.isTame(u) == true}
        end
      end
    end
  end)
  if not ok then return {} end
  -- wild before tame, then the nearest
  table.sort(out, function(a, b)
    if a.tame ~= b.tame then return not a.tame end
    if a.d ~= b.d then return a.d < b.d end
    return a.id < b.id
  end)
  while #out > WW.SCENE_MAX do table.remove(out) end
  return out
end

-- public (BUG-496, care's DROWNED event): the water at a tile: 'water 5/7' | 'beside water 2/7' | nil, and 'brook' | 'river' | nil
function M.water_at(K, x, y, z)
  if not (math.type(x) == 'integer' and math.type(y) == 'integer' and math.type(z) == 'integer') then return nil end
  return WW.near(x, y, z), WW.stream(x, y, z)
end

-- public (BUG-495, care's inspect what=unit): what the fort can see of a unit that is no citizen: race, size, flags that make it
-- a danger, whether it stands at water, whether the citizens reach it, how far the nearest citizen is. Returns ok, text, d
-- (false, why when the unit is gone or not on the map)
function M.describe(K, id)
  id = math.tointeger(id)
  local u = id and df.unit.find(id)
  if not u then return false, 'no such unit: ' .. tostring(id) end
  local U = dfhack.units
  local x, y, z = U.getPosition(u)
  if not x then return false, string.format('unit %d is not on the map', id) end
  local rf = raw_flags(u)
  local d = {id = id, wild = U.isTame(u) and 0 or 1, race = WW.race_name(u), dead = U.isDead(u) and 1 or 0, pos = {x, y, z}}
  d.sz = WW.size_of(u)
  if rf.p then d.pred = 1 end
  if killer(u) then d.killer = 1 end
  if rf.bd then d.bd = 1 end
  if U.isInvader(u) then d.inv = 1 end
  if U.isTame(u) then d.tame = 1 end
  if U.isFortControlled(u) then d.own = 1 end
  if u.flags1.caged then d.caged = 1 end
  if (U.isMerchant and U.isMerchant(u)) or u.flags1.merchant then d.merchant = 1 end
  if U.isDanger(u) then d.danger = 1 end
  d.wet = WW.near(x, y, z)
  d.stream = WW.stream(x, y, z)
  d.reach = reach_of(u)
  local best = -1
  for _, p in ipairs(st and st.civ_pos or {}) do
    local dzc = math.abs(z - p.z)
    if dzc <= M.DA_DZ then best = minpos(best, math.max(math.abs(x - p.x), math.abs(y - p.y), dzc)) end
  end
  if best >= 0 then d.dc = best end
  local okj, job = pcall(function() return df.job_type[u.job.current_job.job_type] end)
  d.job = okj and job or 'none'
  local msg = string.format('unit %d %s%s%s at %d,%d,%d%s%s%s%s', id, d.race, d.sz and (' ' .. d.sz .. ' cm3') or '',
        d.dead == 1 and ', DEAD' or '', x, y, z, d.wet and (', ' .. d.wet) or '',
        d.tame and ', tame' or (d.inv and ', invader' or ', wild'),
        d.reach == 1 and ', on the citizens\' ground' or (d.reach == 2 and ', reachable from the bank'
        or (d.reach == 0 and ', out of reach' or '')), d.dc and (', ' .. d.dc .. ' tiles from a citizen') or '')
  return true, msg:sub(1, 200), d
end

-- public (BUG-134, live i2: a name lookup failed while paused after a load, before the first census): the ids of the
-- fort's living citizens and residents now (getCitizens; no census written). Read-only
function M.own_ids(K)
  local out = {}
  for _, u in ipairs(dfhack.units.getCitizens(false)) do
    if not dfhack.units.isDead(u) then out[#out + 1] = u.id end
  end
  return out
end

-- public (BUG-642, trade; Run 16c i3 Wallfree: a merchant ownerless on the map kept its caravan listed Leaving for years): the merchants of
-- one civ (units flagged merchant with civ_id = the caravan's entity). {n = on the map, off = flagged but not active (fix/stuck-merchants
-- dismisses these), ids and pos ('x,y,z') of the first three on the map}. Read-only, no census written
function M.merchants(K, civ)
  local r = {n = 0, off = 0, ids = {}, pos = {}}
  for _, u in ipairs(df.global.world.units.active) do
    if u.flags1.merchant and u.civ_id == civ then
      if dfhack.units.isActive(u) then
        r.n = r.n + 1
        if #r.ids < 3 then
          r.ids[#r.ids + 1] = u.id
          r.pos[#r.pos + 1] = string.format('%d,%d,%d', u.pos.x, u.pos.y, u.pos.z)
        end
      else
        r.off = r.off + 1
      end
    end
  end
  return r
end

return M
