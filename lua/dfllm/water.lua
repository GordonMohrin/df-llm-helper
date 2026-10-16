-- water (live L3): water for the bedridden. In L2 and L3 bedridden dwarves died of thirst: the hospital and
-- refuge wells stood over dry sumps, the only water was a brook 90 tiles away, and nothing told anybody.
-- Runs 7-9 (FR-31/33a/34/47): patients died of thirst in wards next to full drink stores, because a Water
-- Source zone on 1/7 seepage does not count for the game: GiveWater was cancelled "No water source".
--   * patients: citizens (census ids) who need health care (unit sheet "needs health care", the
--     injured notification) or lie resting in bed; their thirst timer is watched. A patient over
--     thirst_alarm (30,000, FR-34) wakes the LLM (DECISION_NEEDED patient_thirst, A) with the cause and a
--     one-line recipe (dry hospital: delete the hospital zone or carry water), the caregivers (citizens with
--     FEED_WATER_CIVILIANS) and the buckets: one line for all such patients, at once when one crosses the
--     alarm, else weekly;
--   * water sources, the game's own condition (FR-33a/34): a built well with revealed water down its shaft,
--     or an active Water Source zone with a revealed water tile of depth >= deep (4/7) on the zone's own
--     level (zone_below: also the level below; off, a brook top is unconfirmed live). Shallow water and the
--     mere presence of water tiles do not count. A hospital is served when such a source lies within `near`
--     tiles of its zone; the refuge when a wet well stands on a Tiefe+ tile;
--   * hospital gate (FR-31/34): a hospital location (or a pending `hospital` project) without an accepted
--     source wakes the LLM (HOSPITAL_DRY, A) with a one-line recipe from the water-source scan, when the
--     dry episode starts, then only when a patient joined or a new cause appeared, not before max(a week with
--     patients, else a month, 10 min wall clock) (BUG-008); the run that already sent patient_thirst sends
--     none. A `cistern` is asked monthly (PROJECT_REQUEST, B; bp sites cistern);
--   * water sources scan (FR-47, `inspect what=water_sources`): revealed water of depth >= deep around the
--     hospitals (else the citizens), `near` tiles wide and ws_dz levels up and down, through snapshot.liquids
--     (sliced, after the run's decisions); per water body its level, size, depth, an accepted zone or well
--     over it, a standable bank reachable from the citizens (snapshot.reach), else the shortest dig through
--     revealed natural wall on that level to such a bank. Run on request, and weekly while the hospital
--     gate is dry. Hidden tiles are never read. BUG-031: cavern water (a revealed cavern tile in the body) is
--     listed (`cavern` 1) but never offered: caverns stay sealed; a cistern room of the manifest is named with
--     what it lacks (no well, its well over 0/7, out of reach) instead of "a cistern";
--   * buckets (bucket-delivery fallback: caregivers carry water from any well or Water Source zone in a free
--     bucket): want = max(the hospital's desired buckets, buckets_min) + 1 per patient (<= buckets_max).
--     Forbidden buckets on revealed Kern+ tiles are unforbidden (item_flag; not in BREACH, and without a Kern+
--     burrow only in PEACE), and a missing rest is ordered (workorder dfllm:bucket, MakeBucket in wood, one
--     live order at a time). Items are kept as ids between frames and looked up again before a write;
--   * pond loop (live L6, Paddletribes): a Pond zone beside a WET well makes the carriers take the water from that
--     very well (the nearest source) and pour it into the pond hole over the same sump, again and again. A Pond
--     zone within `pond_near` tiles of a wet well is removed (act.pond_remove) unless a wet Water Source zone
--     is the real supply; at most `pond_per_run` a run;
--   * cisterns (manifest rooms tpl `cistern`): revealed water on the well room floor (2 tiles, or 1 tile in
--     two runs in a row) means the pipe is flooding the room: DECISION_NEEDED cistern_flood (A), close the
--     floodgate with the room's lever.
-- Fair play: reads citizens by census id (thirst, health flags, current job, position, labors), buildings.other
-- vectors (WELL, ZONE_WATER_SOURCE or ANY_ZONE), items.other.BUCKET (flags, position, whether a bucket still
-- holds water: such a bucket is no free bucket), manager orders, site locations, burrow
-- membership; tiles only through snapshot.tile (revealed only). Never edits units, jobs or zones.
-- Writes only through K.act, and only acts whose contract owners list `water` (item_flag, workorder; the
-- module also runs before that contract change, reporting what it would do in the events instead).
local json = require('dfllm.util.json')
local C = require('dfllm.util.contract')
local CAD = require('dfllm.util.cadence')   -- BUG-008: when a standing class-A condition is announced again

local M = {name = 'water', every = {ticks = 1200}, on = {}}
local DAY = C.TICKS.DAY

-- Wake cadence (review): one patient_thirst line per patient every 3 game days came about every 8 s at 450
-- ticks/s and buried every other DECISION_NEEDED of a wake under water lines. Now one line covers all patients
-- over the alarm, at once when a patient crosses it, else weekly (care's mood re-wake); HOSPITAL_DRY starts
-- with the dry episode and repeats weekly with patients (monthly without), never in a run that sent
-- patient_thirst.
M.DEFAULTS = {
  thirst_alarm = 30000, thirst_watch = 25000, near = 30, shaft = 12, pond_near = 3, pond_per_run = 2,
  buckets_min = 2, bucket_per_patient = 1, buckets_max = 8, unforbid_per_run = 4,
  alarm_every = 7 * DAY, hosp_every = 7 * DAY, request_every = 28 * DAY, flood_every = 2 * DAY, flood_tiles = 2,
  units_per_slice = 40, items_per_slice = 200, zone_tiles = 25, order_backoff = 3 * DAY,
  deep = 4, zone_below = false, gate_every = 28 * DAY, wake_wall_s = 600,
  ws_dz = 3, ws_tiles = 1500, ws_every = 7 * DAY, ws_bodies = 12, ws_dig = 8, ws_reach = 6, ws_reads = 400,
}
M.BUCKET_ORDER = {job = 'MakeBucket', material_category = {'wood'}, frequency = 'OneTime'}
local BUSY = {'in_job', 'trader', 'removed', 'garbage_collect', 'construction', 'in_building', 'hostile'}

local st = {}
local has_liquids, emit_gate             -- the hospital gate and the water sources scan (below)

local function fmt(n) return string.format('%d', math.tointeger(n) or -1) end
local function trunc(s, n) return #s > n and s:sub(1, n) or s end
local function vec(f)
  local ok, v = pcall(f)
  return ok and v or {}
end

function M.conf(K)
  local c = type(K.cfg.baseline) == 'table' and K.cfg.baseline.water
  local r = {}
  for k, v in pairs(M.DEFAULTS) do r[k] = v end
  if type(c) == 'table' then for k, v in pairs(c) do r[k] = v end end
  return r
end

-- the contract may not list water as an owner of an act yet (feature detection, no 'not owner' faults)
function M.can(fn)
  for _, o in ipairs(C.ACT[fn] or {}) do if o == 'water' then return true end end
  return false
end

local function pstate(K)
  local p = K.persist.get('m.water')
  if type(p) ~= 'table' then
    p = {v = 2}
    K.persist.set('m.water', p)
  end
  p.alarm = json.object(type(p.alarm) == 'table' and p.alarm or {})
  return p
end

local function tile(K, x, y, z)
  local ok, t = K.call('snapshot', 'tile', x, y, z)
  if ok and type(t) == 'table' then return t end
  return nil
end
local function wet_char(c) return c == 'w' or c == '~' end
local ROCK = {['#'] = true, S = true, C = true, F = true, T = true}     -- snapshot legend: walls, fortifications, trees

-- water under a well: the bucket goes down the open shaft (`_`) to the first water tile (a ramp or floor under
-- the hole holds the water itself and reads `w`/`~`); a dry ramp, rock, a floor or a hidden tile ends the
-- shaft. Without a tile reader nothing counts as wet. BUG-031 (Run 11: HOSPITAL_DRY monthly beside a cistern, the
-- recipe "a cistern"): the second value says what the shaft ends on, {at = {x, y, z}, flow = depth 0..7 (nil
-- unknown), why = 'water' | 'dry' (a floor or ramp without water) | 'rock' | 'hidden' | 'deep' (open space below the
-- shaft limit)}, for the HOSPITAL_DRY text
function M.well_wet(K, x, y, z, depth)
  for zz = z - 1, z - (depth or 12), -1 do
    local t = tile(K, x, y, zz)
    local at = {x, y, zz}
    if not t then return false, {at = at, why = 'hidden'} end
    local f = math.tointeger(t.flow)
    if wet_char(t.c) then return true, {at = at, flow = f, why = 'water'} end
    if t.c ~= '_' then
      return false, {at = at, flow = f or 0, why = ROCK[t.c] and 'rock' or 'dry'}
    end
  end
  return false, {at = {x, y, z - (depth or 12)}, why = 'deep'}
end

-- water the game accepts in a Water Source zone (FR-33a/34): a revealed tile of depth >= deep, never magma.
-- snapshot.tile gives the depth (flow); a reader without it marks depth 4..7 as '~' and 1..3 as 'w'
function M.deep_tile(t, c)
  if type(t) ~= 'table' or t.magma == true then return false end
  local f = math.tointeger(t.flow)
  if f ~= nil then return f >= c.deep end
  return t.c == '~'
end

-- a zone tile of deep water on the zone's own level (zone_below: or on the level below, e.g. a brook bed)
local function zone_wet(K, c, zn)
  local n = 0
  for y = zn.y1, zn.y2 do
    for x = zn.x1, zn.x2 do
      n = n + 1
      if n > c.zone_tiles then return false end
      for dz = 0, c.zone_below == true and 1 or 0 do
        if M.deep_tile(tile(K, x, y, zn.z - dz), c) then return true end
      end
    end
  end
  return false
end

local function hospital_locations()
  local out = {}
  local ok = pcall(function()
    local site = dfhack.world.getCurrentSite()               -- Lua API.txt:2205
    local htype = df.abstract_building_type.HOSPITAL
    for _, l in ipairs(site and site.buildings or {}) do
      if l:getType() == htype then out[l.id] = l end
    end
  end)
  return ok and out or {}
end

local function desired_buckets(loc)
  local ok, n = pcall(function() return loc.contents.desired_buckets end)
  return ok and math.tointeger(n) or nil
end

local function burrow(K, role, default)
  local name = default
  for n, b in pairs(K.manifest().burrows or {}) do if b.role == role then name = n end end
  local ok, b = pcall(function() return dfhack.burrows.findByName(name) end)   -- Lua API.txt:2412
  return ok and b or nil
end

local function on_burrow(b, x, y, z)
  if not b or not x then return false end
  local ok, yes = pcall(function() return dfhack.burrows.isAssignedTile(b, {x = x, y = y, z = z}) end)
  return ok and yes == true
end

local function dist_box(x, y, z, b)            -- Chebyshev distance from a tile to a zone rect (b.z only)
  local dx = x < b.x1 and b.x1 - x or (x > b.x2 and x - b.x2 or 0)
  local dy = y < b.y1 and b.y1 - y or (y > b.y2 and y - b.y2 or 0)
  return math.max(dx, dy, math.abs(z - b.z))
end

---------------------------------------------------------------- phases
-- patients (citizens by census id)
local function patient(u)
  local ok, yes = pcall(function()
    if u.health and u.health.flags.needs_healthcare then return true end   -- notifications.lua:172
    local j = u.job and u.job.current_job
    return j ~= nil and j.job_type == df.job_type.Rest                    -- full-heal.lua:209
  end)
  return ok and yes == true
end

-- a caregiver who carries water to the bedridden: an adult with the FEED_WATER_CIVILIANS labor (labors screen)
local function carer(u)
  local ok, yes = pcall(function()
    return not dfhack.units.isDead(u) and dfhack.units.isAdult(u)
           and u.status.labors[df.unit_labor.FEED_WATER_CIVILIANS] == true
  end)
  return ok and yes == true
end

local function phase_units(K, c, r)
  local n = 0
  while r.idx < #r.ids and n < c.units_per_slice do
    r.idx, n = r.idx + 1, n + 1
    local id = r.ids[r.idx]
    local u = df.unit.find(id)
    if u and patient(u) then
      local th = 0
      pcall(function() th = math.tointeger(u.counters2.thirst_timer) or 0 end)
      local x, y, z = dfhack.units.getPosition(u)
      r.patients[#r.patients + 1] = {id = id, thirst = th, x = x, y = y, z = z}
    elseif u then
      if carer(u) then r.carers[#r.carers + 1] = id end
      if #r.home < 60 then
        local x, y, z = dfhack.units.getPosition(u)
        if x then r.home[#r.home + 1] = {x = x, y = y, z = z} end
      end
    end
  end
  return r.idx >= #r.ids
end

-- wells, Water Source zones, hospital zones
local function phase_sites(K, c, r)
  local other = df.global.world.buildings.other
  for _, w in ipairs(vec(function() return other.WELL end)) do
    local done = true
    pcall(function() done = w:getBuildStage() >= w:getMaxBuildStage() end)
    local wet, info = false, nil
    if done then wet, info = M.well_wet(K, w.x1, w.y1, w.z, c.shaft) end
    r.sources[#r.sources + 1] = {kind = 'well', id = w.id, x = w.x1, y = w.y1, z = w.z, wet = wet,
                                 built = done, below = info}                  -- BUG-031: what the shaft ends on
  end
  local locs = hospital_locations()
  local wsrc = df.civzone_type and df.civzone_type.WaterSource
  local zones, seen = {}, {}                                 -- a Lua list: never write into a DF vector
  for _, zn in ipairs(vec(function() return other.ZONE_WATER_SOURCE end)) do
    zones[#zones + 1] = zn
    seen[zn.id] = true
  end
  local any = vec(function() return other.ANY_ZONE end)
  local pondt = df.civzone_type and df.civzone_type.Pond
  for _, zn in ipairs(any) do
    if pondt and zn.type == pondt then
      r.ponds[#r.ponds + 1] = {id = zn.id, x1 = zn.x1, y1 = zn.y1, x2 = zn.x2, y2 = zn.y2, z = zn.z}
    end
    if locs[zn.location_id] then
      r.hosp[#r.hosp + 1] = {id = zn.id, x1 = zn.x1, y1 = zn.y1, x2 = zn.x2, y2 = zn.y2, z = zn.z,
                             want = desired_buckets(locs[zn.location_id])}
    end
    if wsrc and zn.type == wsrc and not seen[zn.id] then zones[#zones + 1] = zn; seen[zn.id] = true end
  end
  for _, zn in ipairs(zones) do
    local active = true
    pcall(function() active = zn.spec_sub_flag.active end)
    if active then
      r.sources[#r.sources + 1] = {kind = 'zone', id = zn.id, x = (zn.x1 + zn.x2) // 2, y = (zn.y1 + zn.y2) // 2,
                                   z = zn.z, wet = zone_wet(K, c, zn), box = {x1 = zn.x1, y1 = zn.y1, x2 = zn.x2,
                                                                                y2 = zn.y2, z = zn.z}}
    end
  end
  return true
end

-- buckets: usable, free, forbidden inside Kern+
local function item_pos(it)
  local a, b, c = dfhack.items.getPosition(it)               -- Lua API.txt:2055
  if type(a) == 'table' then return a.x, a.y, a.z end
  return a, b, c
end

-- a bucket that still holds something (water dropped with an interrupted job) serves no other job until
-- fix/dry-buckets empties it (tools/fix/dry-buckets.txt; control-panel default: weekly). The item sheet shows it
local function holds(it)
  local ok, l = pcall(dfhack.items.getContainedItems, it)          -- Lua API.txt:2043
  return ok and type(l) == 'table' and #l > 0
end

local function phase_buckets(K, c, r)
  local v = vec(function() return df.global.world.items.other.BUCKET end)
  local n = 0
  while r.idx < #v and n < c.items_per_slice do
    local it = v[r.idx]
    r.idx, n = r.idx + 1, n + 1
    local f = it and it.flags
    if f and not f.removed and not f.garbage_collect and not f.trader then
      r.buckets = r.buckets + 1
      local busy = false
      for _, k in ipairs(BUSY) do if f[k] then busy = true end end
      if not busy and holds(it) then
        r.full = r.full + 1
      elseif not busy and not f.forbid and not f.dump then
        r.free = r.free + 1
      elseif not busy and f.forbid then
        r.forbidden[#r.forbidden + 1] = it.id       -- an id: the item may be gone before the run finishes
      end
    end
  end
  return r.idx >= #v
end

---------------------------------------------------------------- decisions
local function served(K, c, r, h)
  local best
  for _, s in ipairs(r.sources) do
    if s.wet then
      local d = dist_box(s.x, s.y, s.z, h)
      if not best or d < best.d then best = {d = d, s = s} end
    end
  end
  return best and best.d <= c.near, best
end

local function order_live(id)
  if math.type(id) ~= 'integer' then return false end
  local ok, live = pcall(function()
    for _, o in ipairs(df.global.world.manager_orders.all) do
      if o.id == id then return (o.amount_left or 0) > 0 end
    end
    return false
  end)
  return ok and live == true
end

-- a forbidden bucket that may be unforbidden now: still there and forbidden (the scan ran over several frames:
-- the item is looked up again by id, never kept as a pointer), on a revealed tile inside Kern+. Not in BREACH
-- (an enemy is inside Kern+); without a Kern+ burrow only in PEACE (care's inside() rule)
local function unforbid_ok(K, kern, id)
  local it = df.item.find(id)
  local f = it and it.flags
  if not f or not f.forbid or f.removed or f.garbage_collect or f.trader then return false end
  for _, k in ipairs(BUSY) do if f[k] then return false end end
  local x, y, z = item_pos(it)
  if not x then return false end
  local mode = K.mode()
  if mode == 'BREACH' or (not kern and mode ~= 'PEACE') then return false end
  if kern and not on_burrow(kern, x, y, z) then return false end
  return tile(K, x, y, z) ~= nil
end

local function supply_buckets(K, c, r, p, want)
  local fixed, ordered = 0, 0
  local kern = burrow(K, 'kern', 'Kern+')
  if r.free < want and M.can('item_flag') then
    for _, id in ipairs(r.forbidden) do
      if r.free + fixed >= want or fixed >= c.unforbid_per_run then break end
      if unforbid_ok(K, kern, id) and K.act.item_flag(id, 'forbid', false) then fixed = fixed + 1 end
    end
  end
  local missing = want - r.free - fixed
  local now = K.now().tick
  if missing > 0 and M.can('workorder') and not order_live(p.order) and now >= (p.order_retry or 0) then
    local spec = {}
    for k, val in pairs(M.BUCKET_ORDER) do spec[k] = val end
    spec.material_category = {'wood'}
    spec.tag, spec.amount_total = 'dfllm:bucket', missing
    local ok, id = K.act.workorder(spec)
    if ok then p.order, ordered = id, missing else p.order_retry = now + c.order_backoff end
  end
  return fixed, ordered, missing
end

-- pond zones beside a wet well (see the header): the carriers would pour the well's own water back into it
local function pond_loops(K, c, r)
  if #r.ponds == 0 or not M.can('pond_remove') then return 0 end
  for _, s in ipairs(r.sources) do
    if s.kind == 'zone' and s.wet then return 0 end            -- a real supply exists: the pond is no loop
  end
  local n = 0
  for _, pd in ipairs(r.ponds) do
    if n >= c.pond_per_run then break end
    for _, s in ipairs(r.sources) do
      if s.kind == 'well' and s.wet and dist_box(s.x, s.y, s.z, {x1 = pd.x1, y1 = pd.y1, x2 = pd.x2, y2 = pd.y2,
                                                                 z = pd.z}) <= c.pond_near then
        if K.act.pond_remove(pd.id) then
          n = n + 1
          K.log('warn', 'water: pond zone %d removed: the wet well %d beside it was its water source (a loop)',
                pd.id, s.id)
        end
        break
      end
    end
  end
  return n
end

---------------------------------------------------------------- water sources (FR-47)
-- Run 9: the aquifer probe pool (6-7/7) was walled in, the shaft below got a 1/7 trickle, and nobody knew where
-- deep water could be reached. The scan reads revealed water of depth >= deep through snapshot.liquids (hidden
-- tiles never), groups it into bodies per level and looks for a standable bank the citizens reach, else the
-- shortest dig through revealed natural wall on that level. Plain values only; sliced over frames.
local STAND = {['.'] = true, r = true, ['<'] = true, ['>'] = true, X = true, w = true, ['^'] = true}
local DIGGABLE = {['#'] = true, S = true}                 -- natural wall (smoothed too); constructions stay
local N8 = {{-1, -1}, {0, -1}, {1, -1}, {-1, 0}, {1, 0}, {-1, 1}, {0, 1}, {1, 1}}

local function k3(x, y, z) return string.format('%d,%d,%d', x, y, z) end

local function median(list, f)
  local v = {}
  for _, e in ipairs(list) do v[#v + 1] = e[f] end
  table.sort(v)
  return v[(#v + 1) // 2]
end

has_liquids = function(K)
  local ok = K.call('snapshot', 'liquids', 0, 0, -1, -1, 0, 1)
  return ok == true
end

emit_gate = function(K, c, a)
  local fix = M.recipe(c, a.cis)
  K.emit('HOSPITAL_DRY', 'A', trunc(string.format('%s without accepted water, %d patient(s): %s',
                                                  a.planned and 'planned hospital' or 'hospital', a.patients, fix), 200),
         {why = trunc(a.why, 200), patients = a.patients, zone = a.zone, near = c.near, recipe = trunc(fix, 200),
          cistern = a.cis and trunc(a.cis.txt, 120) or nil})
end

-- the one-line recipe of the hospital gate from the last scan: zone a reachable bank, else the shortest dig,
-- else a cistern; deleting the hospital zone lets the patients fetch their own drink meanwhile. BUG-031: with a
-- cistern room standing (`cis`, cistern_state), not "a cistern" but what that one lacks
function M.recipe(c, cis)
  local ws = st.ws
  local tail = '; until then delete the hospital zone'
  if not ws then
    if cis then return cis.fix .. tail end
    return string.format('a well over water or a Water Source zone on water >= %d/7 within %d tiles (inspect '
                         .. 'water_sources)%s', c.deep, c.near, tail)
  end
  local best, cav
  for _, b in ipairs(ws.bodies or {}) do
    if b.cavern == 1 and b.d <= c.near and not cav then cav = b end
    if b.cavern ~= 1 and b.d <= c.near and (b.bank or b.dig) then
      if not best or (b.bank and not best.bank) or ((b.bank ~= nil) == (best.bank ~= nil) and b.d < best.d) then
        best = b
      end
    end
  end
  if best and best.bank then
    return string.format('zone the water at %d,%d,%d (%d/7) as Water Source, bank %d,%d,%d is reachable, or a well '
                         .. 'over it%s', best.at[1], best.at[2], best.at[3], best.max, best.bank[1], best.bank[2],
                         best.bank[3], tail)
  elseif best then
    local d = best.dig
    return string.format('dig %d wall tile(s) from %d,%d,%d to %d,%d,%d to bare the water at %d,%d,%d, then zone '
                         .. 'it%s', d.n, d.from[1], d.from[2], d.from[3], d.to[1], d.to[2], d.to[3], best.at[1],
                         best.at[2], best.at[3], tail)
  end
  if cis then return cis.fix .. tail end
  local ctxt = cav and string.format(' (the cavern water at %d,%d,%d is none: caverns stay sealed)', cav.at[1], cav.at[2],
                                     cav.at[3]) or ''
  return string.format('no reachable water >= %d/7 within %d tiles%s: a cistern (bp sites cistern)%s', c.deep, c.near,
                       ctxt, tail)
end

-- BUG-031 (Run 11: a cistern stood since y426 and HOSPITAL_DRY said "no reachable water >= 4/7 within 30 tiles: a
-- cistern" every month): why the nearest cistern room of the manifest (tpl cistern; its bbox is the well room, the
-- 3x3 cistern lies one level below) does not serve hospital zone `h`. Its well is the WELL source inside the room; the
-- cistern's water is read on its revealed tiles (snapshot.tile; hidden ones never). Returns nil without a cistern room,
-- else {id, txt (the state: ' cistern <id>: its well <w> at x,y,z stands over 0/7 (dry)', ' ... is 38 tiles from the
-- hospital (> 30)', ' ... has no built well'), fix (what to do), near (within `near` tiles), d}
local function cistern_state(K, c, r, h)
  local best
  for _, rm in ipairs(K.manifest().rooms or {}) do
    local b = rm.tpl == 'cistern' and type(rm.bbox) == 'table' and rm.bbox
    if b and math.tointeger(b[1]) and math.tointeger(b[6]) then
      local well
      for _, s in ipairs(r.sources) do
        if s.kind == 'well' and s.z == b[3] and s.x >= b[1] and s.x <= b[4] and s.y >= b[2] and s.y <= b[5] then
          well = s
        end
      end
      local cx, cy = (b[1] + b[4]) // 2, (b[2] + b[5]) // 2
      local d = dist_box(well and well.x or cx, well and well.y or cy, b[3], h)
      if not best or d < best.d then best = {rm = rm, well = well, d = d, at = {cx, cy, b[3]}, b = b} end
    end
  end
  if not best then return nil end
  local id, w, at = tostring(best.rm.id or '?'), best.well, best.at
  local maxf, seen = 0, 0                     -- the deepest revealed water of the cistern below the room
  for y = best.b[2], best.b[5] do
    for x = best.b[1], best.b[4] do
      local t = tile(K, x, y, best.b[3] - 1)
      if t then
        seen = seen + 1
        local f = math.tointeger(t.flow) or (t.c == '~' and 4 or (t.c == 'w' and 1 or 0))
        if f > maxf then maxf = f end
      end
    end
  end
  local out = {id = id, d = best.d, near = best.d <= c.near}
  local far = not out.near and string.format(', %d tiles from the hospital (> %d)', best.d, c.near) or ''
  if not w then
    out.txt = string.format('cistern %s at %d,%d,%d has no well%s', id, at[1], at[2], at[3], far)
    out.fix = out.txt .. ': build it'
  elseif not w.built then
    out.txt = string.format('cistern %s: its well %d at %d,%d,%d is not built%s', id, w.id, w.x, w.y, w.z, far)
    out.fix = out.txt .. ': finish it'
  elseif not w.wet then
    local bl = w.below or {}
    local p = bl.at or {w.x, w.y, w.z - 1}
    local what = bl.why == 'hidden' and 'a hidden tile' or (bl.why == 'rock' and 'rock'
                 or (bl.why == 'deep' and 'a dry shaft' or string.format('%d/7 (dry)', bl.flow or 0)))
    out.txt = string.format('cistern %s: its well %d stands over %s at %d,%d,%d (cistern max %d/7)%s', id, w.id, what,
                            p[1], p[2], p[3], maxf, far)
    out.fix = out.txt .. ': fill it (pond zone and bucket carriers, or its pipe)'
  else
    out.txt = string.format('cistern %s: its well %d at %d,%d,%d (water %d/7) is %d tiles from the hospital (> %d)', id,
                            w.id, w.x, w.y, w.z, (w.below and w.below.flow) or maxf, best.d, c.near)
    out.fix = out.txt .. ': a hospital zone near it'
  end
  out.max, out.seen = maxf, seen
  return out
end

local function new_scan(K, c, r)
  local boxes, ref = {}, nil
  for i = 1, math.min(2, #r.hosp) do
    local h = r.hosp[i]
    boxes[#boxes + 1] = {math.max(0, h.x1 - c.near), math.max(0, h.y1 - c.near), math.max(0, h.z - c.ws_dz),
                         h.x2 + c.near, h.y2 + c.near, h.z + c.ws_dz}
  end
  if r.hosp[1] then
    local h = r.hosp[1]
    ref = {x1 = h.x1, y1 = h.y1, x2 = h.x2, y2 = h.y2, z = h.z}
  elseif #r.home > 0 then
    local mx, my, mz = median(r.home, 'x'), median(r.home, 'y'), median(r.home, 'z')
    boxes[1] = {math.max(0, mx - c.near), math.max(0, my - c.near), math.max(0, mz - c.ws_dz), mx + c.near,
                my + c.near, mz + c.ws_dz}
    ref = {x1 = mx, y1 = my, x2 = mx, y2 = my, z = mz}
  else
    return nil
  end
  local from, fd                                     -- walk origin: the citizen nearest the reference
  for _, h in ipairs(r.home) do
    local d = dist_box(h.x, h.y, h.z, ref)
    if not fd or d < fd then from, fd = h, d end
  end
  return {boxes = boxes, bi = 1, tiles = {}, n = 0, ref = ref, from = from, stage = 'read', sources = r.sources,
          bk = 0, out = {}}
end

-- one slice of reading: rows of the current level of the current box through snapshot.liquids
local function scan_read(K, c, sc)
  local budget = c.ws_tiles
  while budget > 0 do
    local b = sc.boxes[sc.bi]
    if not b then return true end
    sc.z, sc.y = sc.z or b[3], sc.y or b[2]
    if sc.z > b[6] then
      sc.bi, sc.z, sc.y = sc.bi + 1, nil, nil
    else
      local w = b[4] - b[1] + 1
      local rows = math.max(1, math.min(b[5] - sc.y + 1, budget // w, 4096 // w))
      local ok, list, err = K.call('snapshot', 'liquids', b[1], sc.y, b[4], sc.y + rows - 1, sc.z, c.deep)
      if not ok or type(list) ~= 'table' then
        sc.err = 'snapshot.liquids: ' .. tostring(ok and err or list)
        return true
      end
      for _, t in ipairs(list) do
        local key = k3(t[1], t[2], sc.z)
        if not sc.tiles[key] and sc.n < 4000 then sc.tiles[key], sc.n = {t[1], t[2], sc.z, t[3], t[4]}, sc.n + 1 end
      end
      budget = budget - w * rows
      sc.y = sc.y + rows
      if sc.y > b[5] then sc.y, sc.z = b[2], sc.z + 1 end
    end
  end
  return false
end

-- deep tiles -> bodies (8-connected on one level), nearest to the reference first, at most ws_bodies
local function scan_group(c, sc)
  local keys, seen, bodies = {}, {}, {}
  for k in pairs(sc.tiles) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do
    if not seen[k] then
      seen[k] = true
      local t0 = sc.tiles[k]
      local body, stack = {z = t0[3], tiles = {}, max = 0, d = math.huge, cav = 0}, {t0}
      while #stack > 0 do
        local t = table.remove(stack)
        body.tiles[#body.tiles + 1] = t
        if t[4] > body.max then body.max = t[4] end
        if t[5] == 1 then body.cav = 1 end            -- BUG-031: a cavern tile makes it cavern water
        local d = dist_box(t[1], t[2], t[3], sc.ref)
        if d < body.d then body.d = d end
        for _, o in ipairs(N8) do
          local nk = k3(t[1] + o[1], t[2] + o[2], t[3])
          if sc.tiles[nk] and not seen[nk] then seen[nk] = true; stack[#stack + 1] = sc.tiles[nk] end
        end
      end
      table.sort(body.tiles, function(a, b) return a[2] < b[2] or (a[2] == b[2] and a[1] < b[1]) end)
      body.at = {body.tiles[1][1], body.tiles[1][2], body.z}
      bodies[#bodies + 1] = body
    end
  end
  table.sort(bodies, function(a, b)
    if a.d ~= b.d then return a.d < b.d end
    if #a.tiles ~= #b.tiles then return #a.tiles > #b.tiles end
    return a.z > b.z
  end)
  while #bodies > c.ws_bodies do table.remove(bodies) end
  sc.list = bodies
end

-- one body: the accepted zone or well over it, a reachable bank, else the shortest dig to one
local function scan_body(K, c, sc, body)
  local z, deepset = body.z, sc.tiles
  local res = {z = z, n = #body.tiles, max = body.max, at = body.at, d = body.d, zone = -1, well = -1, reach = 0}
  -- BUG-031 (Run 11: a 7/7 cavern lake 1146 tiles on z127 below an aborted shaft): caverns stay sealed (DOCTRINE: every
  -- breach of caverns through a 2-wall airlock), so cavern water is listed but never looked at for a bank or a dig
  if body.cav == 1 then res.cavern = 1; return res end
  for _, s in ipairs(sc.sources or {}) do
    for _, t in ipairs(body.tiles) do
      if s.kind == 'zone' and s.wet and s.box and (s.box.z == z or (c.zone_below == true and s.box.z == z + 1))
         and t[1] >= s.box.x1 and t[1] <= s.box.x2 and t[2] >= s.box.y1 and t[2] <= s.box.y2 then res.zone = s.id end
      if s.kind == 'well' and s.wet and s.z > z and s.x == t[1] and s.y == t[2] then res.well = s.id end
    end
  end
  local checks = 0
  local function reachable(x, y)
    if not sc.from then return true end
    if checks >= c.ws_reach then return nil end
    checks = checks + 1
    local ok, yes = K.call('snapshot', 'reach', sc.from, {x = x, y = y, z = z})
    return not ok or yes ~= false
  end
  -- at most ws_reads tile reads per body (one body a frame): a big lake must not make the module slow
  local reads = 0
  local function read(x, y)
    if reads >= c.ws_reads then res.partial = 1; return nil end
    reads = reads + 1
    return tile(K, x, y, z)
  end
  local seen, walls = {}, {}
  for _, t in ipairs(body.tiles) do
    if reads >= c.ws_reads then res.partial = 1; break end
    for _, o in ipairs(N8) do
      local x, y = t[1] + o[1], t[2] + o[2]
      local key = k3(x, y, z)
      if not deepset[key] and not seen[key] then
        seen[key] = true
        local tt = read(x, y)
        if tt and STAND[tt.c] and not M.deep_tile(tt, c) then
          local yes = reachable(x, y)
          if yes then res.bank, res.reach = {x, y, z}, 1; return res end
          if yes == nil then return res end
        elseif tt and DIGGABLE[tt.c] then
          walls[#walls + 1] = {x, y, key, x, y}
        end
      end
    end
  end
  -- no reachable bank: breadth first through revealed natural wall (each wall dug counts one), up to ws_dig
  local qi, depth = 1, {}
  for _, w in ipairs(walls) do depth[w[3]] = 1 end
  while qi <= #walls do
    local w = walls[qi]
    qi = qi + 1
    local dw = depth[w[3]]
    for _, o in ipairs(N8) do
      local x, y = w[1] + o[1], w[2] + o[2]
      local key = k3(x, y, z)
      if not deepset[key] and not seen[key] then
        seen[key] = true
        local tt = read(x, y)
        if tt and STAND[tt.c] and not M.deep_tile(tt, c) then
          local yes = reachable(x, y)
          if yes then
            res.dig = {n = dw, from = {x, y, z}, to = {w[4], w[5], z}}
            return res
          end
          if yes == nil then return res end
        elseif tt and DIGGABLE[tt.c] and dw < c.ws_dig then
          depth[key] = dw + 1
          walls[#walls + 1] = {x, y, key, w[4], w[5]}
        end
      end
    end
  end
  return res
end

local function scan_done(K, c, sc)
  local levels, byz = {}, {}
  for _, t in pairs(sc.tiles) do byz[t[3]] = (byz[t[3]] or 0) + 1 end
  for z, n in pairs(byz) do levels[#levels + 1] = {z, n} end
  table.sort(levels, function(a, b) return a[1] > b[1] end)
  st.ws = {tick = K.now().tick, deep = c.deep, boxes = sc.boxes, tiles = sc.n, levels = levels, bodies = sc.out,
           err = sc.err}
  local reach = 0
  for _, b in ipairs(sc.out) do if b.bank or b.dig then reach = reach + 1 end end
  K.log('info', 'water sources: %d tiles >= %d/7 in %d bodies, %d with a bank or a dig%s', sc.n, c.deep, #sc.out, reach,
        sc.err and (' (' .. sc.err .. ')') or '')
end

-- one frame of the scan: true while more remains
local function scan_step(K, c)
  local sc = st.scan
  if sc.stage == 'read' then
    if not scan_read(K, c, sc) then return true end
    if sc.err then scan_done(K, c, sc); return false end
    scan_group(c, sc)
    sc.stage = 'bodies'
    if #sc.list > 0 then return true end
  end
  sc.bk = sc.bk + 1
  local body = sc.list[sc.bk]
  if body then sc.out[#sc.out + 1] = scan_body(K, c, sc, body) end
  if sc.bk < #sc.list then return true end
  scan_done(K, c, sc)
  return false
end

local function finish(K, c, r, p)
  local now = K.now().tick
  pond_loops(K, c, r)
  local hosp_ok, best_h, dry_h = #r.hosp > 0, nil, nil
  for _, h in ipairs(r.hosp) do
    local ok, b = served(K, c, r, h)
    if not ok then hosp_ok, dry_h = false, dry_h or h end
    if b and (not best_h or b.d < best_h.d) then best_h = b end
  end
  local refuge = burrow(K, 'refuge', 'Tiefe+')
  local refuge_ok = false
  for _, s in ipairs(r.sources) do
    if s.kind == 'well' and s.wet and on_burrow(refuge, s.x, s.y, s.z) then refuge_ok = true end
  end
  local wells, wet = 0, 0
  for _, s in ipairs(r.sources) do
    if s.kind == 'well' then wells = wells + 1 end
    if s.wet then wet = wet + 1 end
  end
  -- buckets: the hospital's own wish, at least buckets_min, one more per patient
  local want = c.buckets_min
  for _, h in ipairs(r.hosp) do if h.want and h.want > want then want = h.want end end
  want = math.min(c.buckets_max, want + c.bucket_per_patient * #r.patients)
  local fixed, ordered, missing = supply_buckets(K, c, r, p, want)
  -- patients over the alarm: one class-A line for all of them, with the cause (cadence: M.DEFAULTS)
  local thirsty, tmax = 0, 0
  local dry = not hosp_ok and #r.hosp > 0
  local cause = {}
  if #r.hosp == 0 then cause[#cause + 1] = 'no hospital zone' end
  local cis = dry and cistern_state(K, c, r, dry_h) or nil              -- BUG-031: why the cistern does not count
  if dry then
    cause[#cause + 1] = best_h and string.format('nearest accepted water %d tiles from the hospital', best_h.d)
                        or 'no wet well or deep (>= ' .. c.deep .. '/7) Water Source zone'
    if cis then cause[#cause + 1] = cis.txt end
  end
  if wet == 0 then cause[#cause + 1] = 'no accepted water at all' end
  if r.free + fixed == 0 then cause[#cause + 1] = 'no free bucket' end
  if #r.carers == 0 then cause[#cause + 1] = 'no caregiver with FEED_WATER_CIVILIANS' end
  local why = #cause > 0 and table.concat(cause, ', ') or 'water, buckets and caregivers present'
  -- FR-34: the one-line recipe (Run 9: deleting the hospital zone made the survivor stand up, drink and eat)
  local recipe = dry and 'delete the hospital zone (patients fetch their own drink) or carry water'
                 or 'check the GiveWater jobs: caregivers, buckets, the way to the water'
  local carers = {}
  for i = 1, math.min(8, #r.carers) do carers[i] = r.carers[i] end
  -- p.alarm: patients over the alarm in this episode (id -> tick they crossed it)
  local over, fresh = {}, false
  for _, pt in ipairs(r.patients) do
    if pt.thirst >= c.thirst_watch then thirsty = thirsty + 1 end
    if pt.thirst > tmax then tmax = pt.thirst end
    if pt.thirst > c.thirst_alarm then
      over[#over + 1] = pt
      local sid = fmt(pt.id)
      if not p.alarm[sid] then p.alarm[sid], fresh = now, true end
    end
  end
  for sid in pairs(p.alarm) do
    local keep = false
    for _, pt in ipairs(over) do if fmt(pt.id) == sid then keep = true end end
    if not keep then p.alarm[sid] = nil end
  end
  local woke = false
  -- BUG-008: the weekly reminder also waits wake_wall_s wall seconds (a game week is 21 s at timestream speed); a
  -- patient crossing the alarm still wakes at once
  local T = K.now()
  if #over > 0 and (fresh or CAD.elapsed({t = p.alarm_t or -c.alarm_every, w = p.alarm_w}, T, c.alarm_every,
                                         c.wake_wall_s)) then
    p.alarm_t, p.alarm_w, woke = now, T.wall, true
    table.sort(over, function(a, b) return a.thirst > b.thirst end)
    local ids = {}
    for i = 1, math.min(8, #over) do ids[i] = over[i].id end
    local top = over[1]
    K.emit('DECISION_NEEDED', 'A', trunc(string.format('%d patient(s) over thirst %d, unit %d at %d: %s; %s', #over,
                                                       c.thirst_alarm, top.id, top.thirst, why, recipe), 200),
           {id = 'patient_thirst', unit = top.id, thirst = top.thirst, units = ids, n = #over, carers = carers,
            n_carers = #r.carers, buckets = r.free + fixed, buckets_all = r.buckets,
            q = trunc(string.format('units %s thirsty (%s): %s; carers %d (FEED_WATER_CIVILIANS: %s), buckets %d free '
                                    .. 'of %d', table.concat(ids, ','), why, recipe, #r.carers,
                                    #carers > 0 and table.concat(carers, ',') or 'none', r.free + fixed, r.buckets), 200)})
  end
  -- hospital gate (FR-31/34): a hospital location, or a hospital project while no accepted water exists at all,
  -- without an accepted source wakes the LLM when the dry episode starts (not in a run that sent patient_thirst);
  -- a cistern is asked monthly either way. BUG-008: within an episode again only when a patient joined or a new
  -- cause appeared, and not before max(hosp_every with patients, else gate_every, wake_wall_s wall seconds)
  local okh, hpend = K.call('runner', 'pending', 'hospital')
  local planned = #r.hosp == 0 and okh and type(hpend) == 'number' and hpend > 0
  local gate = dry or (planned and wet == 0)
  if gate then
    if (not st.ws or now - st.ws.tick >= c.ws_every) and not st.scan then st.ws_want = true end
    local every = #r.patients > 0 and c.hosp_every or c.gate_every
    local start = p.hosp == nil
    p.hosp = p.hosp or now
    local pids, toks = {}, {}
    for i, pt in ipairs(r.patients) do pids[i] = pt.id end
    for i, cs in ipairs(cause) do toks[i] = (cs:gsub('%d+', 'N')) end      -- a distance is no new cause
    if planned then toks[#toks + 1] = 'planned' end
    local last = p.hosp_t and {t = p.hosp_t, w = p.hosp_w, ids = p.hosp_ids or {}, toks = p.hosp_toks or {}} or nil
    if woke then
      p.hosp_t, p.hosp_w, p.hosp_ids, p.hosp_toks = now, T.wall, pids, toks   -- patient_thirst carried cause and recipe
    elseif start or CAD.due(last, T, pids, toks, {ticks = every, wall_s = c.wake_wall_s}) then
      p.hosp_t, p.hosp_w, p.hosp_ids, p.hosp_toks = now, T.wall, pids, toks
      local h = r.hosp[1]
      local a = {planned = planned, patients = #r.patients, zone = h and h.id or -1,
                 why = planned and 'no accepted water on the map' or why, cis = cis}
      if not st.ws and has_liquids(K) then
        st.gate_pending, st.ws_want = a, true             -- the first one waits for the scan's recipe (a few frames)
      else
        emit_gate(K, c, a)
      end
    end
    local okp, pend = K.call('runner', 'pending', 'cistern')
    -- BUG-031: a cistern within reach of the hospital needs water, not a second cistern (the recipe says how)
    if not (okp and type(pend) == 'number' and pend > 0) and not (cis and cis.near)
       and now - (p.req or -c.request_every) >= c.request_every then
      p.req = now
      K.emit('PROJECT_REQUEST', 'B', 'cistern: the hospital has no accepted water within ' .. c.near .. ' tiles',
             {tpl = 'cistern', n = 1, why = 'hospital_water'})
    end
  else
    p.hosp, p.hosp_t, p.hosp_w, p.hosp_ids, p.hosp_toks = nil, nil, nil, nil, nil   -- a new dry episode wakes at once
  end
  -- a cistern that floods its well room (the breaker failed or something was dug into the pipe). One wet tile
  -- in one run is no flood: a bucket poured into a dry cistern's pond hole shows water there for a moment
  local wet_rooms = {}
  for _, rm in ipairs(K.manifest().rooms or {}) do
    if rm.tpl == 'cistern' and type(rm.bbox) == 'table' and type(rm.id) == 'string' then
      local b, first, n = rm.bbox, nil, 0
      for y = b[2], b[5] do
        for x = b[1], b[4] do
          local t = tile(K, x, y, b[3])
          if t and wet_char(t.c) then n = n + 1; first = first or {x, y, b[3]} end
        end
      end
      if n > 0 then wet_rooms[rm.id] = true end
      local flooded = n >= c.flood_tiles or (n > 0 and (st.wet_rooms or {})[rm.id])
      if flooded and now - (p.flood or -c.flood_every) >= c.flood_every then
        p.flood = now
        K.emit('DECISION_NEEDED', 'A', trunc(string.format('cistern %s floods its well room: %d wet tiles from '
                                                           .. '%d,%d,%d', rm.id, n, first[1], first[2], first[3]), 200),
               {id = 'cistern_flood', q = trunc('close the floodgate (the lever in the well room ' .. rm.id
                                                .. '), stop filling its pond zone, keep dwarves out', 200)})
      end
    end
  end
  st.wet_rooms = wet_rooms
  local out = {patients = #r.patients, thirsty = thirsty, thirst_max = tmax, wells = wells, wet = wet,
               hosp_ok = hosp_ok and 1 or 0, refuge_ok = refuge_ok and 1 or 0, buckets = r.buckets,
               buckets_free = r.free + fixed, buckets_full = r.full, buckets_want = want, unforbid = fixed,
               ordered = ordered, missing = math.max(0, missing), carers = #r.carers, gate = gate and 1 or 0}
  local prev = st.out or {}
  if prev.hosp_ok ~= out.hosp_ok or prev.refuge_ok ~= out.refuge_ok or prev.patients ~= out.patients
     or fixed > 0 or ordered > 0 then
    K.log('info', 'water: %d patients (max thirst %d), hospital %s, refuge %s, %d wet sources (%d wells), buckets %d free of %d '
          .. '(want %d, unforbid %d, ordered %d)', out.patients, tmax, hosp_ok and 'ok' or 'dry',
          refuge_ok and 'ok' or 'dry', wet, wells, out.buckets_free, r.buckets, want, fixed, ordered)
  end
  st.out = out
  st.src = r.sources
  K.persist.touch('m.water')
end

---------------------------------------------------------------- module
local PHASES = {phase_units, phase_sites, phase_buckets}

local function new_run(K)
  local cu = K.census.u
  local ids = {}
  for _, id in ipairs(type(cu) == 'table' and cu.ids or {}) do ids[#ids + 1] = id end
  return {ph = 1, idx = 0, ids = ids, patients = {}, sources = {}, hosp = {}, buckets = 0, free = 0, full = 0,
          forbidden = {}, ponds = {}, carers = {}, home = {}}
end

function M.init(K)
  st = {run = nil}
  pstate(K)
end

-- the run (patients, sources, buckets, decisions), then a requested water sources scan in the following frames;
-- a scan that outlasts the cadence lets the next run go first
function M.step(K, budget, ctx)
  local c = M.conf(K)
  local p = pstate(K)
  local now = K.now().tick
  if not (ctx and ctx.cont) or (not st.run and not st.scan) then
    st.run, st.run_t = new_run(K), now
  elseif not st.run and now - (st.run_t or now) >= M.every.ticks then
    st.run, st.run_t = new_run(K), now
  end
  local r = st.run
  if r then
    while r.ph <= #PHASES do
      if not PHASES[r.ph](K, c, r) then return 'more' end
      r.ph, r.idx = r.ph + 1, 0
    end
    st.run = nil
    finish(K, c, r, p)
    if st.ws_want and not st.scan then
      st.ws_want = nil
      st.scan = new_scan(K, c, r)
    end
  elseif st.scan then
    local ok, more = pcall(scan_step, K, c)
    if not ok then
      K.log('warn', 'water sources scan: %s', tostring(more))
      st.ws = st.ws or {tick = now, deep = c.deep, boxes = {}, tiles = 0, levels = {}, bodies = {}, err = 'scan failed'}
    end
    if not (ok and more) then st.scan = nil end
  end
  if st.gate_pending and not st.scan then                 -- the gate alarm that waited for the scan
    emit_gate(K, c, st.gate_pending)
    st.gate_pending = nil
  end
  if st.scan then return 'more' end
end

-- inspect what=water_sources (kern routes it here; FR-47): the last scan (bodies of water >= deep per level with
-- an accepted zone or well, a reachable bank or the shortest dig), the sources of the last run; a scan older than
-- ws_every (or none) is queued for the next water run
function M.inspect(K, what, key)
  if what ~= 'water_sources' then return false, 'water answers what=water_sources only' end
  local c = M.conf(K)
  local now = K.now().tick
  if (not st.ws or now - st.ws.tick >= c.ws_every) and not st.scan then st.ws_want = true end
  local srcs = {}
  for _, s in ipairs(st.src or {}) do
    if #srcs < 30 then srcs[#srcs + 1] = {s.kind, s.id, s.x, s.y, s.z, s.wet and 1 or 0} end
  end
  local queued = (st.ws_want or st.scan) and 1 or 0
  if not st.ws then
    return true, 'water_sources: scan queued for the next water run',
           {tick = now, queued = queued, deep = c.deep, sources = srcs}
  end
  local w = st.ws
  local reach = 0
  for _, b in ipairs(w.bodies) do if b.bank or b.dig then reach = reach + 1 end end
  return true, string.format('water_sources: %d bodies >= %d/7, %d with a bank or a dig, %d sources', #w.bodies, w.deep,
                             reach, #srcs),
         {tick = w.tick, age = now - w.tick, queued = queued, deep = w.deep, boxes = w.boxes, tiles = w.tiles,
          levels = w.levels, bodies = w.bodies, sources = srcs, err = w.err,
          note = 'sources [kind, id, x, y, z, accepted]; bank: stand there and fill or zone the water; dig: opening '
                 .. 'the last wall floods the dug tiles (dig from above or behind a floodgate); cavern 1: cavern water, '
                 .. 'never offered (caverns stay sealed)'}
end

-- last summary (brief, tests): patients, thirst, wells, hospital/refuge water, buckets
function M.kpi(K) return st.out end

-- published only once the contract has a `water` state key (STATE_SPEC + STATE_OWNERS 'water.*')
function M.state(K)
  local o = st.out
  if not o or not (C.STATE_SPEC.opt and C.STATE_SPEC.opt.water) or C.STATE_OWNERS['water.*'] ~= 'water' then
    return {}
  end
  return {water = {patients = o.patients, thirst_max = o.thirst_max, hosp_ok = o.hosp_ok, refuge_ok = o.refuge_ok,
                   buckets_free = o.buckets_free}}
end

return M
