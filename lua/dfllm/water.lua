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
--     floodgate with the room's lever;
--   * dry cisterns (BUG-040, Run 11 y453: the cisterns y450s0b0 and y452s1b0 were done, their wells never wet): a
--     manifest cistern room (merged when its project is done) whose built well stays dry for cistern_dry_days is
--     reported once per dry spell (CISTERN_DRY, B) with what should fill it: its pond zone (bucket-fed), a pond zone this
--     module removed as a loop, its pipe's floodgate lever, or nothing; the nearest accepted water to carry from;
--   * the sources' burrows (BUG-040): each source is labelled with Kern+ or the refuge when it stands on it (state
--     water.src_l, M.label for readiness's texts); M.wet_wells(name) tells seal how many wells of a burrow are wet
--     (seal.refuge_drink reports them: a dry cistern's well is no drink for the refuge; readiness's refuge_dry already
--     counts only wet ones through refuge_ok);
--   * dry hospital removal (BUG-034, Run 11): while a patient's thirst is over patient_thirst (25,000), every zone of
--     a hospital location none of whose zones is served is removed (act.hospital_remove, the zones screen), at most
--     remove_per_run a run; a location with one served zone keeps all of them. HOSPITAL_REMOVED (A) names the zones,
--     the locations and the patients; a day later kern.log says how many GiveWater jobs run (see remove_dry).
-- Fair play: reads citizens by census id (thirst, health flags, current job, position, labors), buildings.other
-- vectors (WELL, ZONE_WATER_SOURCE or ANY_ZONE), items.other.BUCKET (flags, position, whether a bucket still
-- holds water: such a bucket is no free bucket), manager orders, site locations, burrow
-- membership; tiles only through snapshot.tile (revealed only). Never edits units or jobs; zones only through act
-- (a Pond zone beside a wet well, the zones of a dry hospital: the zones screen's remove).
-- Writes only through K.act, and only acts whose contract owners list `water` (item_flag, workorder, pond_remove,
-- hospital_remove; the module also runs before such a contract change, reporting what it would do instead).
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
  -- BUG-034: a dry hospital's zones go once a patient is over patient_thirst (DF's "thirsty" mark is ~25,000-50,000;
  -- dehydration kills at ~75,000); hosp_remove false keeps them (report only, as before)
  patient_thirst = 25000, hosp_remove = true, remove_per_run = 8,
  -- BUG-040: a done cistern whose built well stays dry this many days is reported once (CISTERN_DRY, B)
  cistern_dry_days = 30,
  -- BUG-054 (Run 11 y497: 5 patients dead of thirst at once with 4 caregivers, 24-27 free buckets and "hospital ok"):
  -- caregivers (the FEED_WATER_CIVILIANS labor, the Orderlies work detail) scale with the patients: carers_per_patient
  -- each (at least carers_min while there is a patient, at most carers_max), carers_urgent more while a patient is over
  -- thirst_alarm; at most carers_per_run are added a run; the ones the kernel added leave after carers_hold_days without
  -- any patient (hysteresis). A patient over dying_thirst (60,000: death follows at ~75,000) is PATIENT_DYING (A), again
  -- only for news and not before dying_every ticks. carers_max 0 switches the scaling off.
  carers_per_patient = 1, carers_min = 2, carers_max = 8, carers_urgent = 2, carers_per_run = 2, carers_hold_days = 14,
  dying_thirst = 60000, dying_every = 2 * DAY,
}
M.SRC_MAX = 8                                -- accepted sources in the state (water.src), nearest first
M.SRC_LBL = 4                                -- BUG-040: labels of the first ones (water.src_l: 'well 19098 in Kern+')
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

-- config/baseline.json "water" tunes the defaults; a value of another type than its default is ignored (BUG-034: a
-- string thirst would fault every run; `python -m dfpilot.lint --config` names it)
function M.conf(K)
  local c = type(K.cfg.baseline) == 'table' and K.cfg.baseline.water
  local r = {}
  for k, v in pairs(M.DEFAULTS) do r[k] = v end
  if type(c) == 'table' then
    for k, v in pairs(c) do
      if M.DEFAULTS[k] == nil or type(v) == type(M.DEFAULTS[k]) then r[k] = v end
    end
  end
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
  return ok and b or nil, name
end

local function burrow_named(name)
  local ok, b = pcall(function() return dfhack.burrows.findByName(name) end)
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

-- BUG-034: a citizen carrying water to a patient now (current job GiveWater, the unit sheet's job line "Give water";
-- GiveWater2 where the enum has it): the run's count tells whether the game posts and keeps such jobs (the DF rule
-- HOSPITAL_REMOVED rests on)
local function giving(u)
  local ok, yes = pcall(function()
    local j = u.job and u.job.current_job
    if j == nil then return false end
    for _, name in ipairs({'GiveWater', 'GiveWater2'}) do
      local t = df.job_type[name]
      if t ~= nil and j.job_type == t then return true end
    end
    return false
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
      local is_carer = carer(u)
      if is_carer then
        r.carers[#r.carers + 1] = id
        if M.idle(u) then r.carers_idle = r.carers_idle + 1 end
      end
      if giving(u) then r.give = r.give + 1 end
      if #r.home < 60 then
        local x, y, z = dfhack.units.getPosition(u)
        if x then r.home[#r.home + 1] = {x = x, y = y, z = z} end
      end
      -- BUG-054: who the kernel could ask to carry water (not a caregiver yet; at most POOL_MAX; M.carers asks
      -- M.carer_ok only for the ones it would pick, and only when it needs more caregivers)
      if not is_carer and #r.pool < M.POOL_MAX then
        local x, y, z = dfhack.units.getPosition(u)
        if x then r.pool[#r.pool + 1] = {id = id, x = x, y = y, z = z, idle = M.idle(u)} end
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
  r.locs_total = 0
  for _ in pairs(locs) do r.locs_total = r.locs_total + 1 end
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
                             want = desired_buckets(locs[zn.location_id]), loc = zn.location_id}
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

-- pond zones beside a wet well (see the header): the carriers would pour the well's own water back into it. BUG-040:
-- each removal is kept (p.prm, the last 8: id, rect centre, tick): a cistern's pond removed this way is named in
-- CISTERN_DRY (once its own well was wet the carriers took from it: a bucket-fed cistern cannot fill past that)
local function pond_loops(K, c, r, p)
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
          p.prm = type(p.prm) == 'table' and p.prm or json.array{}
          p.prm[#p.prm + 1] = json.array{pd.id, (pd.x1 + pd.x2) // 2, (pd.y1 + pd.y2) // 2, pd.z, K.now().tick}
          while #p.prm > 8 do table.remove(p.prm, 1) end
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

-- whether the kernel removes a dry hospital's zones itself (BUG-034): config and the contract owner
local function removes(c) return c.hosp_remove ~= false and M.can('hospital_remove') end

-- the one-line recipe of the hospital gate from the last scan: zone a reachable bank, else the shortest dig,
-- else a cistern; deleting the hospital zone lets the patients fetch their own drink meanwhile. BUG-031: with a
-- cistern room standing (`cis`, cistern_state), not "a cistern" but what that one lacks. BUG-034: the kernel deletes
-- the zones itself once a patient is over patient_thirst, so the tail says when instead of asking for it
function M.recipe(c, cis)
  local ws = st.ws
  local tail = removes(c) and string.format('; until then the kernel removes it at thirst %d', c.patient_thirst)
               or '; until then delete the hospital zone'
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

---------------------------------------------------------------- dry hospital removal (BUG-034)
-- Run 11 (Kilrudrabed site98, y439 spring): 5 bedridden patients died of thirst (75,000) and 8 more were over 40,000 in a
-- hospital of 4 locations and 5 zones without accepted water, while HOSPITAL_DRY had said so for a long time and nothing
-- acted. The game session removed the 5 zones by hand (zones screen) and GiveWater jobs brought water to the patients
-- again (4 at once); Run 9 (FR-34): deleting the hospital zone made the survivor stand up, drink and eat. The DF rule
-- both rest on, as far as the live notes show it (bugs/BUG-034): a patient in a hospital without accepted water gets no
-- water (GiveWater cancelled "No water source" in Run 9, posted and never done in L5); without the hospital zone he does.
-- So while a patient is over patient_thirst, every zone of a hospital location none of whose zones is served goes; a
-- location with a served zone keeps all of its zones. The location itself stays (an empty entry on the locations screen).
-- Returns {zones, over} when zones were removed in this run, else nil.
local function remove_dry(K, c, r, p, T)
  if not removes(c) then return nil end
  local over = {}
  for _, pt in ipairs(r.patients) do if pt.thirst > c.patient_thirst then over[#over + 1] = pt end end
  if #over == 0 then return nil end
  local wet_loc = {}
  for _, h in ipairs(r.hosp) do if served(K, c, r, h) then wet_loc[h.loc] = true end end
  local zones, locs, seen, failed, first = {}, {}, {}, 0, nil
  for _, h in ipairs(r.hosp) do
    if not wet_loc[h.loc] and #zones + failed < c.remove_per_run then
      if K.act.hospital_remove(h.id) then             -- a refusal is an ACT_FAIL (B); the next run tries again
        zones[#zones + 1], first = h.id, first or h
        if not seen[h.loc] then seen[h.loc], locs[#locs + 1] = true, h.loc end
      else
        failed = failed + 1
      end
    end
  end
  if #zones == 0 then return nil end
  table.sort(over, function(a, b) return a.thirst > b.thirst end)
  local ids = {}
  for i = 1, math.min(8, #over) do ids[i] = over[i].id end
  local best
  for _, s in ipairs(r.sources) do
    if s.wet then
      local d = dist_box(s.x, s.y, s.z, first)
      if not best or d < best.d then best = {d = d, s = s} end
    end
  end
  local src = best and string.format('nearest accepted water %d,%d,%d (%d tiles)', best.s.x, best.s.y, best.s.z, best.d)
              or 'no accepted water on the map'
  local function list(t)
    local o = {}
    for i = 1, math.min(6, #t) do o[i] = fmt(t[i]) end
    return table.concat(o, ',') .. (#t > 6 and '+' or '')
  end
  local top = over[1]
  K.emit('HOSPITAL_REMOVED', 'A',
         trunc(string.format('removed %d dry hospital zone(s) %s (location %s): %d patient(s) over thirst %d, unit %d at '
                             .. '%d; %s; water before a new hospital', #zones, list(zones), list(locs), #over,
                             c.patient_thirst, top.id, top.thirst, src), 200),
         {zones = zones, locs = locs, units = ids, n = #over, thirst = top.thirst, patients = #r.patients,
          give = r.give, failed = failed, near = c.near, d = best and best.d or nil,
          src = best and {best.s.x, best.s.y, best.s.z} or nil})
  K.log('warn', 'water: removed hospital zone(s) %s of location(s) %s (no accepted water within %d tiles): %d patient(s) '
        .. 'over thirst %d (unit %d at %d), %d GiveWater job(s) now; %s', list(zones), list(locs), c.near, #over,
        c.patient_thirst, top.id, top.thirst, r.give, src)
  p.rm = {t = T.tick, zones = zones, locs = locs, n = #over, tmax = top.thirst, give = r.give}
  return {zones = zones, over = over}
end

-- the accepted sources (a well over water, a deep Water Source zone), nearest to the first hospital zone (else the
-- citizens' median) first, at most SRC_MAX as [x, y, z] (state water.src: plan propose/check, BUG-034)
local function src_list(r)
  local ref = r.hosp[1]
  if not ref and #r.home > 0 then
    local mx, my, mz = median(r.home, 'x'), median(r.home, 'y'), median(r.home, 'z')
    ref = {x1 = mx, y1 = my, x2 = mx, y2 = my, z = mz}
  end
  local l = {}
  for _, s in ipairs(r.sources) do
    if s.wet then l[#l + 1] = {s = s, d = ref and dist_box(s.x, s.y, s.z, ref) or 0} end
  end
  table.sort(l, function(a, b)
    if a.d ~= b.d then return a.d < b.d end
    return a.s.id < b.s.id
  end)
  local out, lbl = json.array{}, json.array{}
  for i = 1, math.min(M.SRC_MAX, #l) do
    local s = l[i].s
    out[i] = json.array{s.x, s.y, s.z}
    if i <= M.SRC_LBL then                                     -- BUG-040: the nearest ones (state size)
      lbl[i] = trunc(string.format('%s %d', s.kind, s.id) .. (s.inn and (' in ' .. s.inn) or ''), 32)
    end
  end
  return out, lbl
end

---------------------------------------------------------------- BUG-040: cisterns that stay dry
-- Run 11 (Kilrudrabed site98, y453): the cisterns y450s0b0 and y452s1b0 were PROJECT_DONE and their wells never held
-- water: the fort had no revealed open water (water NO since the run began), so nothing could fill them, and nobody said
-- so. A cistern room of the manifest (merged when its project is done) whose built well stays dry for cistern_dry_days
-- is reported once per dry spell (CISTERN_DRY, B; kern.log): what should fill it (fill: pond = bucket-fed by its pond
-- zone, pond_removed = pond_loops removed that zone as a loop, pipe = its floodgate waits for the well room's lever,
-- none), the nearest accepted water to carry from. Its project id from the runner's kept boxes, the pipe from its bp
-- file (runner.kept_in, runner.bp_params; read-only, only when reporting).
local function cistern_dry(K, c, r, p, now)
  p.cdry = json.object(type(p.cdry) == 'table' and p.cdry or {})
  local seen = {}
  for _, rm in ipairs(K.manifest().rooms or {}) do
    local b = rm.tpl == 'cistern' and type(rm.bbox) == 'table' and type(rm.id) == 'string' and rm.bbox
    if b and math.tointeger(b[1]) and math.tointeger(b[6]) then
      local well
      for _, s in ipairs(r.sources) do
        if s.kind == 'well' and s.built and s.z == b[3] and s.x >= b[1] and s.x <= b[4] and s.y >= b[2]
           and s.y <= b[5] then well = s end
      end
      local rec = p.cdry[rm.id]
      if well then seen[rm.id] = true end
      if well and well.wet then
        if type(rec) == 'table' and rec.said then
          K.log('info', 'water: cistern %s: its well %d holds water again', rm.id, well.id)
        end
        p.cdry[rm.id] = nil
      elseif well and type(rec) ~= 'table' then
        p.cdry[rm.id] = {t = now}
      elseif well and not rec.said and now - (math.tointeger(rec.t) or now) >= c.cistern_dry_days * DAY then
        rec.said = now
        local box = {x1 = b[1], y1 = b[2], x2 = b[4], y2 = b[5], z = b[3]}
        local fill, pond = 'none', nil
        for _, pd in ipairs(r.ponds) do
          if pd.z == b[3] and pd.x1 >= b[1] and pd.x2 <= b[4] and pd.y1 >= b[2] and pd.y2 <= b[5] then
            fill, pond = 'pond', pd.id
          end
        end
        for _, e in ipairs(fill == 'none' and type(p.prm) == 'table' and p.prm or {}) do
          if e[4] == b[3] and e[2] >= b[1] and e[2] <= b[4] and e[3] >= b[2] and e[3] <= b[5] then
            fill, pond = 'pond_removed', e[1]
          end
        end
        local okk, proj = K.call('runner', 'kept_in', b)
        proj = okk and type(proj) == 'string' and proj or nil
        if fill == 'none' and proj then
          local okp, prm = K.call('runner', 'bp_params', proj)
          if okp and type(prm) == 'table' and type(prm.path) == 'string' and prm.path ~= '' then fill = 'pipe' end
        end
        local best
        for _, s in ipairs(r.sources) do
          if s.wet and s ~= well then
            local d = dist_box(s.x, s.y, s.z, box)
            if not best or d < best.d then best = {d = d, s = s} end
          end
        end
        local how = ({pond = string.format('bucket-fed (pond zone %s)', tostring(pond)),
                      pond_removed = string.format('bucket-fed, its pond zone %s removed as a pond loop (its own well '
                                                   .. 'fed it)', tostring(pond)),
                      pipe = 'piped: its floodgate waits for the lever (link it, pull it once)',
                      none = 'no pond zone, no pipe: nothing fills it'})[fill]
        local carry = best and string.format('carry from: %s %d at %d,%d,%d (%d tiles)', best.s.kind, best.s.id,
                                             best.s.x, best.s.y, best.s.z, best.d)
                      or 'no accepted water to carry from (no revealed water source)'
        local days = (now - (math.tointeger(rec.t) or now)) // DAY
        local msg = string.format('cistern %s done, its well %d at %d,%d,%d dry for %d days: %s; %s', proj or rm.id,
                                  well.id, well.x, well.y, well.z, days, how, carry)
        local tail = '; no drink for a hospital or the refuge'
        if #msg + #tail <= 200 then msg = msg .. tail end
        K.emit('CISTERN_DRY', 'B', trunc(msg, 200),
               {room = trunc(rm.id, 60), proj = proj, well = well.id, pos = {well.x, well.y, well.z}, days = days,
                fill = fill, pond = pond, src = best and {best.s.x, best.s.y, best.s.z} or nil, d = best and best.d or nil})
        K.log('warn', 'water: %s', msg)
      end
    end
  end
  for id in pairs(p.cdry) do if not seen[id] then p.cdry[id] = nil end end
end

---------------------------------------------------------------- BUG-036: the hospital outside the core
-- Run 11 siege 9 (y445): two cave dragons struck down 8 citizens in the BREACH, 7 of them patients in hospital beds; a
-- lying patient cannot walk to the refuge (only a rescue or hauling moves him), so the hospital (its zone and beds) has to
-- lie in Tiefe+, or at least in Kern+ behind the seal, AND next to accepted water (BUG-034). Per hospital zone: the tiles
-- of its rect (<= HOSP_TILES, evenly sampled) on neither burrow (state water.hosp_out, readiness R0 hospital_out); in a fight
-- (SIEGE/BREACH) once the patients outside the burrow the civ alert confines to (PATIENTS_OUT, B; Kern+ and the refuge
-- while it is silent). Reads burrow tiles and the census patients only; moves nobody.
M.HOSP_TILES = 100         -- tiles looked at per hospital zone (an even sample of a bigger one)
local FIGHT = {SIEGE = true, BREACH = true}

local function hospital_out(r, kern, refuge, kname, rname)
  local zones = {}
  if kern or refuge then
    for _, h in ipairs(r.hosp) do
      local area, step = (h.x2 - h.x1 + 1) * (h.y2 - h.y1 + 1), 1
      while area > M.HOSP_TILES * step * step do step = step + 1 end     -- a big zone: an even sample of its tiles
      local n, out = 0, 0
      for y = h.y1, h.y2, step do
        for x = h.x1, h.x2, step do
          n = n + 1
          if not (on_burrow(kern, x, y, h.z) or on_burrow(refuge, x, y, h.z)) then out = out + 1 end
        end
      end
      if out > 0 then
        zones[#zones + 1] = {id = h.id, loc = h.loc, x = (h.x1 + h.x2) // 2, y = (h.y1 + h.y2) // 2, z = h.z,
                             tiles = out, of = n}
      end
    end
  end
  return {n = #zones, total = #r.hosp, zones = zones, kern = kname, refuge = rname}
end

local function patients_out(K, r, kern, refuge, kname, rname, ho)
  local mode = K.mode()
  if not FIGHT[mode] then st.pout = nil; return end
  if st.pout or #r.patients == 0 then return end
  local okn, names = K.call('siege', 'alert_names')
  names = okn and type(names) == 'table' and names or {}
  local b1 = type(names[1]) == 'string' and burrow_named(names[1]) or nil
  local bs, label = {kern, refuge}, kname .. '/' .. rname
  if b1 then bs, label = {b1}, names[1] end
  local out, ids, at = {}, {}, {}
  for _, pt in ipairs(r.patients) do
    local inb = false
    for _, b in ipairs(bs) do if on_burrow(b, pt.x, pt.y, pt.z) then inb = true; break end end
    if not inb then
      out[#out + 1] = pt
      if #ids < 20 then ids[#ids + 1] = pt.id end
      if #at < 3 and pt.x then at[#at + 1] = string.format('%d at %d,%d,%d', pt.id, pt.x, pt.y, pt.z) end
    end
  end
  if #out == 0 then return end
  st.pout = K.now().tick
  local tail = ho.n > 0 and string.format('; the hospital lies outside %s/%s: move it into %s next to accepted water',
                                          kname, rname, rname)
               or '; plan the hospital inside the refuge'
  local msg = string.format('%s: %d of %d patients lie outside the alert burrow %s (%s): they cannot walk there, only a '
                            .. 'rescue moves them%s', mode, #out, #r.patients, label, table.concat(at, ', '), tail)
  K.emit('PATIENTS_OUT', 'B', trunc(msg, 200), {n = #out, patients = #r.patients, burrow = trunc(label, 60), units = ids,
                                                mode = mode, hosp_out = ho.n})
  K.log('warn', 'water: %s', msg)
end

---------------------------------------------------------------- BUG-054: caregivers scale with the patients
-- Run 11 y497 (the game session's notes 18, 24): patient_thirst said "water, buckets and caregivers present" while 3-5
-- patients stood at thirst 30,000-40,293 with 24-27 of 62 buckets free and 4 caregivers; five of them died of thirst
-- together (75,000, hunger 80-119k) in a fort that reported "hospital ok", and the fort went from 49 citizens to 1.
-- What the code proves: nothing in the kernel ever gave the FEED_WATER_CIVILIANS labor to anybody (it only counts the
-- citizens who have it, `carer`), so the number of caregivers was whatever the game's own Orderlies work detail held;
-- the cause text only said "no caregiver" for ZERO of them, 4 for 5 patients counted as "present"; and a wet hospital
-- got no action at all: the only act was the removal of a DRY hospital's zones (remove_dry) and one weekly line.
-- Now: want = carers_per_patient per patient (carers_min .. carers_max, + carers_urgent while a patient is over
-- thirst_alarm); missing caregivers are added to the Orderlies work detail (the work details screen: act.work_detail,
-- the best candidate first: idle, then nearest the hospital; never a soldier, a dwarf in a mood, a noble, a child or
-- a miner/woodcutter/hunter); the ones added leave again carers_hold_days after the last patient. Not decided offline:
-- why the game's own jobs did not keep up (busy carers, no job posted, unreachable water): `give_jobs` and the
-- caregivers' state (idle, GiveWater jobs running/open) go into PATIENT_DYING and inspect water_sources.
M.CARER_DETAIL = 'Orderlies'
M.POOL_MAX = 200
local NO_WAIT = 7 * DAY                 -- a missing Orderlies detail is not asked for again for a week

function M.idle(u)
  local ok, yes = pcall(function() return u.job == nil or u.job.current_job == nil end)
  return ok and yes == true
end

-- a citizen the kernel may ask to carry water: adult, no squad, no mood, no noble post, no tool labor (Miners,
-- Woodcutters and Hunters are specialists), not a patient (the caller)
function M.carer_ok(u)
  local ok, yes = pcall(function()
    if dfhack.units.isDead(u) or not dfhack.units.isAdult(u) then return false end
    if (u.military.squad_id or -1) >= 0 then return false end
    if (u.mood or -1) >= 0 then return false end
    for _, name in ipairs({'MINE', 'CUTWOOD', 'HUNT'}) do
      local l = df.unit_labor and df.unit_labor[name]
      if l ~= nil and u.status.labors[l] == true then return false end
    end
    return true
  end)
  if not (ok and yes == true) then return false end
  local okn, np = pcall(dfhack.units.getNoblePositions, u)
  if okn and type(np) == 'table' and #np > 0 then return false end
  return true
end

-- GiveWater/GiveFood jobs on the job list: open (no worker) and running; nil when this DF has neither job type.
-- One bounded pass, only called while a patient is thirsty (water's own cadence, a game day)
function M.give_jobs()
  local types = {}
  for _, n in ipairs({'GiveWater', 'GiveWater2', 'GiveFood'}) do
    local t = df.job_type and df.job_type[n]
    if type(t) == 'number' then types[t] = true end
  end
  if next(types) == nil then return nil end
  local open, run, i = 0, 0, 0
  pcall(function()
    local link = df.global.world.jobs.list.next
    while link and i < 20000 do
      local j = link.item
      if j and types[j.job_type] then
        local okw, w = pcall(dfhack.job.getWorker, j)
        if okw and w == nil then open = open + 1 else run = run + 1 end
      end
      link, i = link.next, i + 1
    end
  end)
  return open, run
end

-- the plan of one run: {have, want, idle, added = {ids}, dropped = {ids}, err}. `over` = a patient is over thirst_alarm.
-- Adds through act.work_detail (water must be an owner of it: feature detection) and only the kernel's own additions
-- (p.cw: id -> tick) ever leave again
function M.carers(K, c, r, p, now, over)
  p.cw = json.object(type(p.cw) == 'table' and p.cw or {})
  local np, have = #r.patients, #r.carers
  local want = 0
  if np > 0 and c.carers_max > 0 then
    want = math.max(c.carers_min, np * c.carers_per_patient)
    if over then want = want + c.carers_urgent end
    want = math.min(want, c.carers_max)
  end
  local out = {have = have, want = want, idle = r.carers_idle, added = {}, dropped = {}}
  if np > 0 then p.cw_t = now end
  local mine = 0
  for sid in pairs(p.cw) do                                       -- a unit that died or left is forgotten
    local u = df.unit.find(math.tointeger(tonumber(sid)) or -1)
    if not u or dfhack.units.isDead(u) then p.cw[sid] = nil else mine = mine + 1 end
  end
  out.mine = mine
  if not M.can('work_detail') then out.err = 'water may not change work details'; return out end
  if have < want and mine >= c.carers_max then
    -- the kernel already put carers_max citizens into the detail and they are not caregivers: its labors do not grant
    -- FEED_WATER_CIVILIANS (or the game took them off); more members would change nothing
    out.err = string.format('%d citizens added to %s hold no FEED_WATER_CIVILIANS labor', mine, M.CARER_DETAIL)
  elseif have < want and now >= (math.tointeger(p.cw_off) or 0) then
    local ref = r.hosp[1] or (r.patients[1] and {x1 = r.patients[1].x or 0, y1 = r.patients[1].y or 0,
                                                 x2 = r.patients[1].x or 0, y2 = r.patients[1].y or 0,
                                                 z = r.patients[1].z or 0})
    local pool = {}
    for _, cd in ipairs(r.pool) do pool[#pool + 1] = {cd = cd, d = ref and dist_box(cd.x, cd.y, cd.z, ref) or 0} end
    table.sort(pool, function(a, b)
      if a.cd.idle ~= b.cd.idle then return a.cd.idle end
      if a.d ~= b.d then return a.d < b.d end
      return a.cd.id < b.cd.id
    end)
    for _, e in ipairs(pool) do
      if #out.added >= c.carers_per_run or have + #out.added >= want or mine + #out.added >= c.carers_max then break end
      local cu = df.unit.find(e.cd.id)
      if cu and not p.cw[fmt(e.cd.id)] and M.carer_ok(cu) then      -- (one of ours without the labor: the next one)
        local ok, res = K.act.work_detail(M.CARER_DETAIL, e.cd.id, true, {select = true})
        if ok then
          out.added[#out.added + 1] = e.cd.id
          p.cw[fmt(e.cd.id)] = now
        else
          out.err = tostring(res)
          if out.err:find('no work detail', 1, true) then p.cw_off = now + NO_WAIT end
          break                                                  -- an ACT_FAIL (B) names it; the next run tries again
        end
      end
    end
  elseif np == 0 and next(p.cw) and now - (math.tointeger(p.cw_t) or now) >= c.carers_hold_days * DAY then
    local sids = {}
    for sid in pairs(p.cw) do sids[#sids + 1] = sid end
    table.sort(sids)
    local id = math.tointeger(tonumber(sids[1]))
    if id and K.act.work_detail(M.CARER_DETAIL, id, false) then out.dropped[1] = id end
    p.cw[sids[1]] = nil                                          -- gone either way (a refusal: the player's member now)
  end
  out.have_after = have + #out.added
  return out
end

local function finish(K, c, r, p)
  local now = K.now().tick
  local T = K.now()
  pond_loops(K, c, r, p)
  local hosp_ok, best_h, dry_h = #r.hosp > 0, nil, nil
  for _, h in ipairs(r.hosp) do
    local ok, b = served(K, c, r, h)
    if not ok then hosp_ok, dry_h = false, dry_h or h end
    if b and (not best_h or b.d < best_h.d) then best_h = b end
  end
  local refuge, rname = burrow(K, 'refuge', 'Tiefe+')
  local kern, kname = burrow(K, 'kern', 'Kern+')
  local ho = hospital_out(r, kern, refuge, kname, rname)    -- BUG-036
  st.hout = ho
  patients_out(K, r, kern, refuge, kname, rname, ho)
  local refuge_ok, rwells, rwet = false, 0, 0          -- BUG-035: the wells in the refuge and the wet ones of them
  for _, s in ipairs(r.sources) do
    -- BUG-040: the burrow each source stands on (Kern+ first, else the refuge): state water.src_l, M.label
    s.inn = on_burrow(kern, s.x, s.y, s.z) and kname or (on_burrow(refuge, s.x, s.y, s.z) and rname or nil)
    if s.kind == 'well' and on_burrow(refuge, s.x, s.y, s.z) then
      rwells = rwells + 1
      if s.wet then rwet, refuge_ok = rwet + 1, true end
    end
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
  -- BUG-054: caregivers scale with the patients (before the cause text: it names what was added)
  local over_alarm = false
  for _, pt in ipairs(r.patients) do if pt.thirst > c.thirst_alarm then over_alarm = true end end
  local cs = M.carers(K, c, r, p, now, over_alarm)
  local after = cs.have_after or cs.have
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
  local gerr = cs.err and #cs.added == 0 and (' (could not add: ' .. trunc(cs.err, 60) .. ')') or ''
  if after == 0 and #r.patients > 0 then
    cause[#cause + 1] = 'no caregiver with FEED_WATER_CIVILIANS' .. gerr
  elseif cs.want > after then              -- BUG-054: 4 caregivers for 5 patients are not "present"
    cause[#cause + 1] = string.format('caregivers short: %d of %d wanted for %d patient(s)%s', after, cs.want,
                                      #r.patients, #cs.added > 0 and string.format(', %d added to %s now', #cs.added,
                                                                                    M.CARER_DETAIL) or gerr)
  elseif #cs.added > 0 then
    cause[#cause + 1] = string.format('caregivers raised to %d (%d added to %s now)', after, #cs.added, M.CARER_DETAIL)
  end
  local why = #cause > 0 and table.concat(cause, ', ') or 'water, buckets and caregivers present'
  -- FR-34: the one-line recipe (Run 9: deleting the hospital zone made the survivor stand up, drink and eat; Run 11:
  -- GiveWater jobs ran again, BUG-034). With the removal on, a dry hospital is left only when the removal failed
  local recipe = dry and 'delete the hospital zone (GiveWater resumes or patients fetch their own drink) or carry water'
                 or 'check the GiveWater jobs: caregivers, buckets, the way to the water'
  local carers = {}
  for i = 1, math.min(8, #r.carers) do carers[i] = r.carers[i] end
  -- BUG-034: a dry hospital's zones go before the patients die (HOSPITAL_REMOVED carries the patients: no patient_thirst
  -- and no HOSPITAL_DRY in the same run)
  local removed = dry and remove_dry(K, c, r, p, T) or nil
  -- a day after a removal: how many GiveWater jobs run now (the DF rule the removal rests on, BUG-034)
  local rm = p.rm
  if type(rm) == 'table' and rm.after == nil and math.tointeger(rm.t) and now - rm.t >= DAY then
    local tm = 0
    for _, pt in ipairs(r.patients) do if pt.thirst > tm then tm = pt.thirst end end
    rm.after, rm.tmax_after = r.give, tm
    K.log('info', 'water: a day after the hospital removal (tick %d): %d GiveWater job(s), %d patient(s), max thirst %d '
          .. '(was %d)', rm.t, r.give, #r.patients, tm, math.tointeger(rm.tmax) or -1)
  end
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
  if removed then
    p.alarm_t, p.alarm_w, woke = now, T.wall, true            -- HOSPITAL_REMOVED named them (BUG-034)
  elseif #over > 0 and (fresh or CAD.elapsed({t = p.alarm_t or -c.alarm_every, w = p.alarm_w}, T, c.alarm_every,
                                             c.wake_wall_s)) then
    p.alarm_t, p.alarm_w, woke = now, T.wall, true
    table.sort(over, function(a, b) return a.thirst > b.thirst end)
    local ids = {}
    for i = 1, math.min(8, #over) do ids[i] = over[i].id end
    local top = over[1]
    K.emit('DECISION_NEEDED', 'A', trunc(string.format('%d patient(s) over thirst %d, unit %d at %d: %s; %s', #over,
                                                       c.thirst_alarm, top.id, top.thirst, why, recipe), 200),
           {id = 'patient_thirst', unit = top.id, thirst = top.thirst, units = ids, n = #over, carers = carers,
            n_carers = after, want = cs.want, added = #cs.added, buckets = r.free + fixed, buckets_all = r.buckets,
            q = trunc(string.format('units %s thirsty: %s; carers %d of %d wanted (FEED_WATER_CIVILIANS: %s), buckets %d '
                                    .. 'free of %d; %s', table.concat(ids, ','), recipe, after, cs.want,
                                    #carers > 0 and table.concat(carers, ',') or 'none', r.free + fixed, r.buckets, why),
                      200)})
  end
  -- BUG-054: a patient at the death-risk line (dying_thirst; death follows at ~75,000) is a class-A line of its own, with
  -- the caregivers' state; the cadence rule (util/cadence.lua): at once for a new patient or a changed cause, else not
  -- before dying_every ticks and the wall-clock wait
  local dying, dids = {}, {}
  for _, pt in ipairs(r.patients) do
    if pt.thirst >= c.dying_thirst then dying[#dying + 1] = pt end
  end
  if #dying > 0 then
    table.sort(dying, function(a, b) return a.thirst > b.thirst end)
    for i, pt in ipairs(dying) do dids[i] = pt.id end
    local hs = #r.hosp == 0 and 'none' or (hosp_ok and 'ok' or 'dry')
    local toks = {'hospital ' .. hs, after >= cs.want and 'caregivers enough' or 'caregivers short',
                  r.free + fixed > 0 and 'buckets' or 'no buckets', r.give > 0 and 'giving' or 'nobody giving'}
    if CAD.due(p.dying, T, dids, toks, {ticks = c.dying_every, wall_s = c.wake_wall_s}) then
      p.dying = CAD.mark(T, dids, toks)
      local gopen, grun = M.give_jobs()
      local top = dying[1]
      local shown = {}
      for i = 1, math.min(8, #dids) do shown[i] = dids[i] end
      local msg = string.format('%d patient(s) near death of thirst (>= %d), unit %d at %d: hospital %s, caregivers %d of %d '
                                .. 'wanted (%d idle), %d giving water; %s', #dying, c.dying_thirst, top.id, top.thirst, hs,
                                after, cs.want, cs.idle, r.give, why)
      K.emit('PATIENT_DYING', 'A', trunc(msg, 200),
             {units = shown, n = #dying, thirst = top.thirst, carers = after, want = cs.want, hosp = hs,
              idle = cs.idle, added = #cs.added, give = r.give, open = gopen or -1, run = grun or -1,
              buckets = r.free + fixed, why = trunc(why, 120)})
      K.log('warn', 'water: %s (GiveWater/GiveFood jobs: %s open, %s running)', msg, tostring(gopen), tostring(grun))
    end
  else
    p.dying = CAD.quiet(p.dying)
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
    for i, cs in ipairs(cause) do
      local t = cs:gsub('%d+', 'N')                                        -- a distance is no new cause
      if t:find('^caregivers short') then t = 'caregivers short'           -- BUG-054: nor is how many were added now
      elseif t:find('^caregivers raised') then t = 'caregivers raised' end
      toks[i] = t
    end
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
  cistern_dry(K, c, r, p, now)                        -- BUG-040: a done cistern whose well stays dry
  -- the hospital zones left after this run's removal, and whether every one of them is served (BUG-034)
  local nh = #r.hosp
  if removed then
    local gone = {}
    for _, id in ipairs(removed.zones) do gone[id] = true end
    nh, hosp_ok = 0, true
    for _, h in ipairs(r.hosp) do
      if not gone[h.id] then
        nh = nh + 1
        if not served(K, c, r, h) then hosp_ok = false end
      end
    end
    hosp_ok = hosp_ok and nh > 0
  end
  local srcs, slbl = src_list(r)
  local out = {patients = #r.patients, thirsty = thirsty, thirst_max = tmax, wells = wells, wet = wet,
               hosp_ok = hosp_ok and 1 or 0, refuge_ok = refuge_ok and 1 or 0, buckets = r.buckets,
               buckets_free = r.free + fixed, buckets_full = r.full, buckets_want = want, unforbid = fixed,
               ordered = ordered, missing = math.max(0, missing), carers = after, gate = gate and 1 or 0,
               hosp = nh, give = r.give, removed = removed and #removed.zones or 0, src = srcs, src_l = slbl,
               rwells = rwells, rwet = rwet, hosp_out = ho.n}
  -- BUG-056 (Run 11: 8 HOSPITAL locations stayed after their zones were deleted): a hospital is a location with a zone;
  -- every count here (r.hosp, hosp, hosp_out, the dry gate, the removal) goes by zones, a zoneless location is only counted
  local live_locs, nlive = {}, 0
  for _, h in ipairs(r.hosp) do
    if not live_locs[h.loc] then live_locs[h.loc], nlive = true, nlive + 1 end
  end
  out.locs = {total = r.locs_total or nlive, live = nlive, stale = math.max(0, (r.locs_total or nlive) - nlive)}
  if out.locs.stale ~= (st.stale_locs or 0) then
    st.stale_locs = out.locs.stale
    if out.locs.stale > 0 then
      K.log('info', 'water: %d hospital location(s) without a zone are left alone (%d with zones; BUG-056)',
            out.locs.stale, nlive)
    end
  end
  out.cw = {have = after, want = cs.want, idle = cs.idle, give = r.give, mine = cs.mine, err = cs.err}   -- BUG-054, inspect
  local prev = st.out or {}
  if prev.hosp_ok ~= out.hosp_ok or prev.refuge_ok ~= out.refuge_ok or prev.patients ~= out.patients
     or prev.hosp ~= out.hosp or prev.rwells ~= out.rwells or prev.hosp_out ~= out.hosp_out or fixed > 0
     or ordered > 0 then
    -- BUG-035 (Run 11: 'refuge dry, 1 wet sources (13 wells)'): where the wells are relative to the refuge
    local rw = string.format('%d %s, %d in %s', wells, wells == 1 and 'well' or 'wells', rwells, rname)
    if rwells > 0 then rw = rw .. string.format(', %d of them wet', rwet) end
    K.log('info', 'water: %d patients (max thirst %d), hospital %s, refuge %s (%s), %d wet sources, buckets %d free of %d '
          .. '(want %d, unforbid %d, ordered %d), %d GiveWater', out.patients, tmax,
          nh == 0 and 'none' or (hosp_ok and 'ok' or 'dry') .. (ho.n > 0 and string.format(' (%d of %d zones outside %s/%s)',
          ho.n, ho.total, kname, rname) or ''), refuge_ok and 'ok' or 'dry', rw, wet, out.buckets_free,
          r.buckets, want, fixed, ordered, r.give)
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
          forbidden = {}, ponds = {}, carers = {}, home = {}, give = 0, pool = {}, carers_idle = 0}
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
  for _, s in ipairs(st.src or {}) do        -- BUG-040: + the depth of the water under a well (-1 unknown) and its burrow
    if #srcs < 30 then
      srcs[#srcs + 1] = {s.kind, s.id, s.x, s.y, s.z, s.wet and 1 or 0,
                         s.below and math.tointeger(s.below.flow) or -1, s.inn or ''}
    end
  end
  -- BUG-040: where the refuge lies and how far its nearest tile is from the nearest accepted water (seal's audit)
  local okr, rd = K.call('seal', 'refuge_drink')
  local ref
  if okr and type(rd) == 'table' and type(rd.box) == 'table' then
    local n = type(rd.near) == 'table' and rd.near or nil
    ref = {name = rd.name, box = rd.box, d = n and n.d or -1, at = n and n.at or nil,
           src = n and n.src and M.label(K, n.src[1], n.src[2], n.src[3]) or nil, wells = rd.wells, wet = rd.wwet}
  end
  local queued = (st.ws_want or st.scan) and 1 or 0
  local rm = pstate(K).rm                     -- BUG-034: the last dry hospital removal (zones, patients, GiveWater jobs)
  rm = type(rm) == 'table' and rm or nil
  if not st.ws then
    return true, 'water_sources: scan queued for the next water run',
           {tick = now, queued = queued, deep = c.deep, sources = srcs, removed = rm, refuge = ref,
            carers = st.out and st.out.cw or nil, locs = st.out and st.out.locs or nil}
  end
  local w = st.ws
  local reach = 0
  for _, b in ipairs(w.bodies) do if b.bank or b.dig then reach = reach + 1 end end
  return true, string.format('water_sources: %d bodies >= %d/7, %d with a bank or a dig, %d sources', #w.bodies, w.deep,
                             reach, #srcs),
         {tick = w.tick, age = now - w.tick, queued = queued, deep = w.deep, boxes = w.boxes, tiles = w.tiles,
          levels = w.levels, bodies = w.bodies, sources = srcs, err = w.err, removed = rm, refuge = ref,
          carers = st.out and st.out.cw or nil, locs = st.out and st.out.locs or nil,
          note = 'sources [kind, id, x, y, z, accepted, depth under a well (-1 unknown), burrow]; refuge: its bbox, d = '
                 .. 'its nearest tile to the nearest accepted source (-1 none); bank: stand there and fill or zone the '
                 .. 'water; dig: opening '
                 .. 'the last wall floods the dug tiles (dig from above or behind a floodgate); cavern 1: cavern water, '
                 .. 'never offered (caverns stay sealed); removed: the last dry hospital removal (t, zones, locs, '
                 .. 'n patients, tmax, give = GiveWater jobs then, after = a day later); locs (BUG-056): hospital locations, total / '
                 .. 'with a zone (live) / without (stale: ignored by every count); carers (BUG-054): have, want, idle ones, '
                 .. 'give = citizens giving water, mine = added by the kernel (Orderlies), err = why none was added'}
end

-- last summary (brief, tests): patients, thirst, wells, hospital/refuge water, buckets
function M.kpi(K) return st.out end

-- published only once the contract has a `water` state key (STATE_SPEC + STATE_OWNERS 'water.*'; BUG-034): hosp = the
-- hospital zones, src = the accepted sources nearest first (plan propose/check: a hospital only within `near` of one)
function M.state(K)
  local o = st.out
  if not o or not (C.STATE_SPEC.opt and C.STATE_SPEC.opt.water) or C.STATE_OWNERS['water.*'] ~= 'water' then
    return {}
  end
  return {water = {patients = o.patients, thirst_max = o.thirst_max, hosp_ok = o.hosp_ok, refuge_ok = o.refuge_ok,
                   buckets_free = o.buckets_free, hosp = o.hosp, src = o.src or json.array{}, hosp_out = o.hosp_out,
                   src_l = o.src_l}}
end

-- public (BUG-040, readiness): 'well 19098 at 137,77,143 in Kern+' for an accepted source of the last run at that tile,
-- else 'accepted water at x,y,z'
function M.label(K, x, y, z)
  for _, s in ipairs(st.src or {}) do
    if s.wet and s.x == x and s.y == y and s.z == z then
      return string.format('%s %d at %d,%d,%d', s.kind, s.id, x, y, z) .. (s.inn and (' in ' .. s.inn) or '')
    end
  end
  return string.format('accepted water at %d,%d,%d', math.tointeger(x) or -1, math.tointeger(y) or -1,
                       math.tointeger(z) or -1)
end

-- public (BUG-040, seal's burrow audit reports it: a dry cistern's well is no drink for the refuge): the wet wells and all built
-- wells on burrow `name` by the last run (burrow tiles read now); nil before the first run or without that burrow
function M.wet_wells(K, name)
  local b = type(name) == 'string' and st.src and burrow_named(name) or nil
  if not b then return nil end
  local wet, n = 0, 0
  for _, s in ipairs(st.src) do
    if s.kind == 'well' and s.built and on_burrow(b, s.x, s.y, s.z) then
      n = n + 1
      if s.wet then wet = wet + 1 end
    end
  end
  return wet, n
end

-- public (BUG-036, readiness): the hospital zones outside Kern+ and the refuge by the last run: {n, total, zones = {{id,
-- loc, x, y, z (the zone's centre), tiles (outside), of (tiles looked at, <= HOSP_TILES)}}, kern, refuge}; n 0 before the
-- first run
function M.hospital_out(K)
  return st.hout or {n = 0, total = 0, zones = {}}
end

return M
