-- water (live L3): water for the bedridden. In L2 and L3 bedridden dwarves died of thirst: the hospital and
-- refuge wells stood over dry sumps, the only water was a brook 90 tiles away, and nothing told anybody.
--   * patients: citizens (census ids) who need health care (unit sheet "needs health care", the
--     injured notification) or lie resting in bed; their thirst timer is watched. A patient over
--     thirst_alarm (40,000, 10,000 before DF's "dehydrated") wakes the LLM (DECISION_NEEDED patient_thirst, A)
--     with the cause (no wet well or Water Source zone near the hospital, no free bucket): one line for all
--     such patients, at once when one crosses the alarm, else weekly;
--   * water sources, as the zone sheet and the well show them: wells with revealed water below the well
--     (snapshot.tile down the shaft), Water Source zones (civzone WaterSource, active) with revealed water on
--     or under a zone tile. A hospital is served when a wet source lies within `near` tiles of its zone;
--     the refuge when a wet well stands on a Tiefe+ tile. A hospital without water while somebody is a
--     patient wakes the LLM (hospital_water, A; when the dry episode starts, then weekly) and asks for a
--     `cistern` monthly (PROJECT_REQUEST, B; bp sites cistern, the brook plan: python -m
--     df_llm_helper.bp.sites cistern);
--   * buckets (bucket-delivery fallback: caregivers carry water from any well or Water Source zone in a free
--     bucket): want = max(the hospital's desired buckets, buckets_min) + 1 per patient (<= buckets_max).
--     Forbidden buckets on revealed Kern+ tiles are unforbidden (item_flag; not in BREACH, and without a Kern+
--     burrow only in PEACE), and a missing rest is ordered (workorder dfllm:bucket, MakeBucket in wood, one
--     live order at a time). Items are kept as ids between frames and looked up again before a write;
--   * cisterns (manifest rooms tpl `cistern`): revealed water on the well room floor (2 tiles, or 1 tile in
--     two runs in a row) means the pipe is flooding the room: DECISION_NEEDED cistern_flood (A), close the
--     floodgate with the room's lever.
-- Fair play: reads citizens by census id (thirst, health flags, current job, position), buildings.other
-- vectors (WELL, ZONE_WATER_SOURCE or ANY_ZONE), items.other.BUCKET (flags, position, whether a bucket still
-- holds water: such a bucket is no free bucket), manager orders, site locations, burrow
-- membership; tiles only through snapshot.tile (revealed only). Never edits units, jobs or zones.
-- Writes only through K.act, and only acts whose contract owners list `water` (item_flag, workorder; the
-- module also runs before that contract change, reporting what it would do in the events instead).
local json = require('dfllm.util.json')
local C = require('dfllm.util.contract')

local M = {name = 'water', every = {ticks = 1200}, on = {}}
local DAY = C.TICKS.DAY

-- Wake cadence (review): one patient_thirst line per patient every 3 game days came about every 8 s at 450
-- ticks/s and buried every other DECISION_NEEDED of a wake under water lines. Now one line covers all patients
-- over the alarm, at once when a patient crosses it, else weekly (care's mood re-wake); hospital_water starts
-- with the dry episode and repeats weekly, and not in a run that already sent patient_thirst.
M.DEFAULTS = {
  thirst_alarm = 40000, thirst_watch = 25000, near = 30, shaft = 12,
  buckets_min = 2, bucket_per_patient = 1, buckets_max = 8, unforbid_per_run = 4,
  alarm_every = 7 * DAY, hosp_every = 7 * DAY, request_every = 28 * DAY, flood_every = 2 * DAY, flood_tiles = 2,
  units_per_slice = 40, items_per_slice = 200, zone_tiles = 25, order_backoff = 3 * DAY,
}
M.BUCKET_ORDER = {job = 'MakeBucket', material_category = {'wood'}, frequency = 'OneTime'}
local BUSY = {'in_job', 'trader', 'removed', 'garbage_collect', 'construction', 'in_building', 'hostile'}

local st = {}

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

-- water under a well: the bucket goes down the open shaft (`_`) to the first water tile (a ramp or floor under
-- the hole holds the water itself and reads `w`/`~`); a dry ramp, rock, a floor or a hidden tile ends the
-- shaft. Without a tile reader nothing counts as wet.
function M.well_wet(K, x, y, z, depth)
  for zz = z - 1, z - (depth or 12), -1 do
    local t = tile(K, x, y, zz)
    if not t then return false end
    if wet_char(t.c) then return true end
    if t.c ~= '_' then return false end
  end
  return false
end

local function zone_wet(K, c, zn)
  local n = 0
  for y = zn.y1, zn.y2 do
    for x = zn.x1, zn.x2 do
      n = n + 1
      if n > c.zone_tiles then return false end
      for dz = 0, 1 do                                       -- a brook bed under the walkable brook top
        local t = tile(K, x, y, zn.z - dz)
        if t and wet_char(t.c) then return true end
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
    local wet = done and M.well_wet(K, w.x1, w.y1, w.z, c.shaft)
    r.sources[#r.sources + 1] = {kind = 'well', id = w.id, x = w.x1, y = w.y1, z = w.z, wet = wet}
  end
  local locs = hospital_locations()
  local wsrc = df.civzone_type and df.civzone_type.WaterSource
  local zones, seen = {}, {}                                 -- a Lua list: never write into a DF vector
  for _, zn in ipairs(vec(function() return other.ZONE_WATER_SOURCE end)) do
    zones[#zones + 1] = zn
    seen[zn.id] = true
  end
  local any = vec(function() return other.ANY_ZONE end)
  for _, zn in ipairs(any) do
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

local function finish(K, c, r, p)
  local now = K.now().tick
  local hosp_ok, best_h = #r.hosp > 0, nil
  for _, h in ipairs(r.hosp) do
    local ok, b = served(K, c, r, h)
    if not ok then hosp_ok = false end
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
  local cause = {}
  if #r.hosp == 0 then cause[#cause + 1] = 'no hospital zone' end
  if not hosp_ok and #r.hosp > 0 then
    cause[#cause + 1] = best_h and string.format('nearest wet source %d tiles from the hospital', best_h.d)
                        or 'no wet well or Water Source zone'
  end
  if wet == 0 then cause[#cause + 1] = 'no wet source at all' end
  if r.free + fixed == 0 then cause[#cause + 1] = 'no free bucket' end
  local why = #cause > 0 and table.concat(cause, ', ') or 'water and buckets present (caregivers? labor FEED_WATER_CIVILIANS)'
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
  if #over > 0 and (fresh or now - (p.alarm_t or -c.alarm_every) >= c.alarm_every) then
    p.alarm_t, woke = now, true
    table.sort(over, function(a, b) return a.thirst > b.thirst end)
    local ids = {}
    for i = 1, math.min(8, #over) do ids[i] = over[i].id end
    local top = over[1]
    K.emit('DECISION_NEEDED', 'A', trunc(string.format('%d patient(s) over thirst %d, unit %d at %d: %s', #over,
                                                       c.thirst_alarm, top.id, top.thirst, why), 200),
           {id = 'patient_thirst', unit = top.id, thirst = top.thirst, units = ids, n = #over,
            q = trunc(string.format('bedridden units %s thirsty (%s): water near the hospital (cistern, Water '
                                    .. 'Source zone), buckets %d free', table.concat(ids, ','), why,
                                    r.free + fixed), 200)})
  end
  -- a hospital without water: wake while somebody needs it (episode start, then weekly), ask for a cistern
  -- monthly either way
  if not hosp_ok and #r.hosp > 0 then
    if #r.patients == 0 then
      p.hosp = nil                                         -- the episode ends with the last patient
    elseif woke then
      p.hosp = p.hosp or now                               -- patient_thirst already carries the cause
    elseif now - (p.hosp or -c.hosp_every) >= c.hosp_every then
      p.hosp = now
      K.emit('DECISION_NEEDED', 'A', trunc(string.format('hospital without water: %s, %d patients', why,
                                                         #r.patients), 200),
             {id = 'hospital_water', q = 'place a cistern (python -m df_llm_helper.bp.sites cistern) or a Water '
                                         .. 'Source zone on revealed water near the hospital'})
    end
    local okp, pend = K.call('runner', 'pending', 'cistern')
    if not (okp and type(pend) == 'number' and pend > 0) and now - (p.req or -c.request_every) >= c.request_every then
      p.req = now
      K.emit('PROJECT_REQUEST', 'B', 'cistern: the hospital has no water within ' .. c.near .. ' tiles',
             {tpl = 'cistern', n = 1, why = 'hospital_water'})
    end
  else
    p.hosp = nil
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
               ordered = ordered, missing = math.max(0, missing)}
  local prev = st.out or {}
  if prev.hosp_ok ~= out.hosp_ok or prev.refuge_ok ~= out.refuge_ok or prev.patients ~= out.patients
     or fixed > 0 or ordered > 0 then
    K.log('info', 'water: %d patients (max thirst %d), hospital %s, refuge %s, %d/%d wells wet, buckets %d free of %d '
          .. '(want %d, unforbid %d, ordered %d)', out.patients, tmax, hosp_ok and 'ok' or 'dry',
          refuge_ok and 'ok' or 'dry', wet, wells, out.buckets_free, r.buckets, want, fixed, ordered)
  end
  st.out = out
  K.persist.touch('m.water')
end

---------------------------------------------------------------- module
local PHASES = {phase_units, phase_sites, phase_buckets}

local function new_run(K)
  local cu = K.census.u
  local ids = {}
  for _, id in ipairs(type(cu) == 'table' and cu.ids or {}) do ids[#ids + 1] = id end
  return {ph = 1, idx = 0, ids = ids, patients = {}, sources = {}, hosp = {}, buckets = 0, free = 0, full = 0,
          forbidden = {}}
end

function M.init(K)
  st = {run = nil}
  pstate(K)
end

function M.step(K, budget, ctx)
  local c = M.conf(K)
  local p = pstate(K)
  if not (ctx and ctx.cont) or not st.run then st.run = new_run(K) end
  local r = st.run
  while r.ph <= #PHASES do
    if not PHASES[r.ph](K, c, r) then return 'more' end
    r.ph, r.idx = r.ph + 1, 0
  end
  st.run = nil
  finish(K, c, r, p)
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
