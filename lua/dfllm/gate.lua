-- gate (WP5): drawbridges with the single-pending-pull invariant (DESIGN §4, CONTRACTS §7).
-- A pull is queued only if (1) the wanted state differs from gate_flags.raised (lever.lua:39-41),
-- (2) the bridge is not raising/lowering, (3) NO PullLever job is pending on any
-- lever of that bridge, and (4) no citizen stands on the footprint. Raising waits <= 300 ticks
-- (only in SIEGE/BREACH do we pull after that); lowering crushes whatever is on the footprint, so
-- it waits as long as it takes and our pending lowering pull is cancelled when a citizen steps on.
-- Our own job without a worker for 200 ticks is cancelled (act.cancel_own_lever_job, the UI
-- cancel) and the next pull goes to the backup lever.
-- Pulls go through act.pull -> reqscript('lever').leverPullJob (lever.lua:4, never deduplicates).
-- Lever rooms (live L3, the S3 fallback): manifest burrows named 'dfllm-levers*' hold levers; in SIEGE/DRILL/
-- BREACH gate assigns lever pullers to them (act.burrow_units, the burrow screen) and pulls a lever with a
-- puller present first; siege lists the allowed rooms in the civ alert (gate.rooms).
local geom = require('dfllm.util.geom')

local M = {name = 'gate', every = {ticks = 600}, critical = true, verbs = {}}

M.FAST, M.SLOW = 25, 600   -- cadence: FAST in SIEGE/BREACH/DRILL or while a bridge has work
M.NO_WORKER = 200          -- ticks our queued pull may wait without a worker
M.BLOCK_WAIT = 300         -- ticks to wait for citizens to leave the footprint before a forced raise
-- live L4: a drill raised B1 15 ticks after the footprint had cleared; the militia commander, carrying her
-- baby, stepped back on while the bridge moved (108 ticks) and both died (death cause DRAWBRIDGE). A bridge
-- moves ~100 ticks after its pull, so a non-forced pull (any lowering; a raise outside SIEGE/BREACH) also
-- waits for this many tiles around the footprint to be clear, and a pending one is cancelled when a citizen
-- comes that close. One tile: the commander had just stepped off; fortcore's melee station stands 2 tiles from B1
-- and its soldiers would hold B1 down for a whole drill with a wider margin.
M.MARGIN = 1
M.SETTLE = 50              -- ticks after a pull job left the queue before another may be queued
M.DEADLINE = 900           -- default: an 'up' not reached by then -> GATE_FAIL (A)
M.DOWN_GUARD = 30          -- 'down' refused while a visible hostile is this close to the bridge
M.RESOLVE = 6000           -- ticks between re-resolving a complete bridge (findAtTile is a linear scan)
M.RESOLVE_RETRY = 100      -- incomplete (no bridge or no linked lever): retry this often ...
M.RESOLVE_URGENT = 20      -- ... and this often while the bridge is not in its wanted state
M.FAIL_REPEAT = 1200       -- the same bridge's GATE_FAIL at most once per day

local FAST_MODES = {SIEGE = true, BREACH = true, DRILL = true}
local FORCE_MODES = {SIEGE = true, BREACH = true}       -- may RAISE with a citizen on it after 300 ticks
local FAIL_WHY = {blocked = 'blocked', no_lever = 'no_lever', no_worker = 'no_worker'}

local st      -- persisted m.gate: {v, br = {<b> = {want, why, since, deadline, failed}}, kpi = {...}}
local rt      -- runtime per bridge: building ids, own job, settle, block, rotation
local pub     -- precomputed state part {bridges = {...}}
local dirty
local PULL    -- df.job_type.PullLever

-- take = ticks from our queued pull to the first worker seen, per bridge (last pull); pp = pulls a lever puller
-- took; pa = puller assignments (live L3: O1's job was taken 156-243 ticks late)
local function new_kpi(t0)
  return {dbl = 0, t0 = t0, raise = {}, pulls = 0, cancels = 0, links = 0, fails = {}, take = {}, pp = 0, pa = 0}
end

local function flush(K)
  if dirty then K.persist.set('m.gate', st); dirty = false end
end

local function runtime(name)
  local r = rt[name]
  if not r then
    r = {levers = {}, linked = {}, bad = {}, nw = 0, pos = {}}
    rt[name] = r
  end
  return r
end

local function valid_spec(spec)
  return type(spec) == 'table' and type(spec.fp) == 'table' and #spec.fp == 6
end

local function bridge_names(man)
  local r = {}
  for name, spec in pairs(man.bridges or {}) do if valid_spec(spec) then r[#r + 1] = name end end
  table.sort(r)
  return r
end

---------------------------------------------------------------- DF reads (buildings, jobs)
local function find_at(p)
  local ok, b = pcall(dfhack.buildings.findAtTile, p[1], p[2], p[3])   -- Lua API.txt:2484
  return ok and b or nil
end

local function is_bridge(b)
  local ok, r = pcall(function()
    if df.building_type and b.getType then return b:getType() == df.building_type.Bridge end
    return b.gate_flags ~= nil
  end)
  return ok and r == true
end

local function is_lever(b)
  local ok, r = pcall(function() return b.trap_type == df.trap_type.Lever end)
  return ok and r == true
end

-- ids of the buildings a lever is linked to (lever.lua:24-27), nil if unreadable
local function targets(lv)
  local r = {}
  local ok = pcall(function()
    for _, m in ipairs(lv.linked_mechanisms) do
      local ref = dfhack.items.getGeneralRef(m, df.general_ref_type.BUILDING_HOLDER)
      local tb = ref and ref:getBuilding()
      if tb then r[tb.id] = true end
    end
  end)
  return ok and r or nil
end

local function pull_type()
  PULL = PULL or (df.job_type and df.job_type.PullLever)
  return PULL
end

local function pull_job(lv)
  local t = pull_type()
  for _, j in ipairs(lv.jobs) do if j.job_type == t then return j end end
end

local function job_on(lv, id)
  for _, j in ipairs(lv.jobs) do if j.id == id then return j end end
end

local function worker(j)
  local ok, w = pcall(dfhack.job.getWorker, j)                         -- Lua API.txt:1360
  return ok and w or nil
end

-- a bridge's gate_flags are named raised/raising/lowering (lever.lua:39-41 flag_names[Bridge]; the
-- v1 BUG-427 fix read them live); doors/floodgates use closed/closing/opening. Reading a field the
-- bitfield lacks raises, so each name is probed in pcall.
local function flag(gf, k)
  local ok, v = pcall(function() return gf[k] end)
  if ok then return v end
end
local function read(r)
  local b = r.bid and df.building.find(r.bid)
  if not b then return 'unknown' end
  local gf = b.gate_flags
  if flag(gf, 'raising') or flag(gf, 'lowering') or flag(gf, 'closing') or flag(gf, 'opening') then
    return 'moving'
  end
  local up = flag(gf, 'raised')
  if up == nil then up = flag(gf, 'closed') end
  if up == nil then return 'unknown' end
  return up and 'up' or 'down'
end

local function any_linked(r)
  for _, lid in ipairs(r.levers) do if r.linked[lid] then return true end end
  return false
end

-- the bridge building on a footprint: findAtTile first, else by extents in buildings.other.BRIDGE
-- (a raised bridge need not show at its tiles)
local function find_bridge(fp)
  local c = geom.bbox_center(fp)
  for _, p in ipairs({{c.x, c.y, c.z}, {fp[1], fp[2], fp[3]}, {fp[4], fp[5], fp[3]}}) do
    local x = find_at(p)
    if x and is_bridge(x) then return x end
  end
  local ok, r = pcall(function()
    for _, b in ipairs(df.global.world.buildings.other.BRIDGE) do
      if b.z == c.z and c.x >= b.x1 and c.x <= b.x2 and c.y >= b.y1 and c.y <= b.y2 then return b end
    end
  end)
  return ok and r or nil
end

-- bridge and lever building ids from the manifest positions, cached. A valid cached bridge is kept
-- (never re-found mid-siege). A complete resolution (bridge + a linked lever) is refreshed every
-- M.RESOLVE ticks; an incomplete one is never trusted for long, because linking a lever is a
-- separate job that often finishes after the bridge exists. r.resolved = nil forces a refresh.
local function resolve(r, spec, now, urgent)
  local parts = {table.concat(spec.fp, ',')}
  for _, p in ipairs(spec.levers or {}) do parts[#parts + 1] = table.concat(p, ',') end
  local sig = table.concat(parts, ';')
  local cached = r.bid and df.building.find(r.bid)
  if cached and not is_bridge(cached) then cached = nil end
  local same = r.sig == sig
  if same and r.resolved then
    local age = now - r.resolved
    if cached and any_linked(r) then
      if age < M.RESOLVE then return end
    elseif age < (urgent and M.RESOLVE_URGENT or M.RESOLVE_RETRY) then return end
  end
  r.sig, r.resolved = sig, now
  local b = (same and cached) or find_bridge(spec.fp) or cached
  r.bid = b and b.id or nil
  r.levers, r.linked, r.pos = {}, {}, {}
  local function add(lv, t, p)
    if #r.levers >= 4 or r.linked[lv.id] ~= nil then return end
    r.levers[#r.levers + 1] = lv.id
    r.linked[lv.id] = (t == nil) or (r.bid ~= nil and t[r.bid] == true)  -- unreadable link: usable
    r.pos[lv.id] = p
  end
  for _, p in ipairs(spec.levers or {}) do
    local lv = find_at(p)
    if lv and is_lever(lv) then add(lv, targets(lv), p) end
  end
  -- stale manifest positions: levers linked to this bridge (one vector scan per RESOLVE_RETRY at most)
  if r.bid and not any_linked(r) and now - (r.scan_tick or -M.RESOLVE_RETRY) >= M.RESOLVE_RETRY then
    r.scan_tick = now
    for _, lv in ipairs(df.global.world.buildings.other.TRAP) do      -- lever.lua:103
      if is_lever(lv) then
        local t = targets(lv)
        if t and t[r.bid] then add(lv, t, {lv.x1, lv.y1, lv.z}) end
      end
    end
  end
end

-- any pending PullLever job on any lever of the bridge (ours or not)
local function pending(r)
  for _, lid in ipairs(r.levers) do
    local lv = df.building.find(lid)
    if lv then
      local j = pull_job(lv)
      if j then return j, lid end
    end
  end
end

-- the lever is still there and still linked to this bridge (an unreadable link counts as linked)
local function linked_now(r, lid)
  local lv = df.building.find(lid)
  if not (lv and is_lever(lv)) then return false end
  local t = targets(lv)
  return t == nil or (r.bid ~= nil and t[r.bid] == true)
end

---------------------------------------------------------------- lever rooms and pullers (live L3, S3 fallback)
-- A lever room is a small manifest burrow named 'dfllm-levers*' (fortcore: the Z3 strip with the O1/B1 levers,
-- the Z4 landing strip with the B2 levers). Live L3 drills: O1's pull was taken 156-243 ticks after queueing
-- (the nearest idle dwarf walked up from the core), O1 rose at T+917/945/1,076. In SIEGE/DRILL/BREACH gate
-- assigns M.PULLERS adult civilians (no soldiers, children, insane or moody dwarves; inside Kern+/Tiefe+ and
-- nearest first) to every room whose bridges the mode raises (outer/inner in SIEGE/DRILL, core in BREACH):
-- act.burrow_units, the burrow screen's unit list. They stay next to the levers, and pick() takes a lever in a
-- room with a puller present first. A puller who is not in his room after PULLER_ARRIVE ticks, or who died,
-- went insane, was drafted or fell into a mood is replaced (and not chosen again in this episode). A puller who
-- gets thirsty or hungry is let go (the rooms hold no drink or food, and a burrow-held dwarf does not walk out to
-- drink: live L3, 21 thirsty citizens in the alert burrow) and may serve again after a drink and a meal. Other
-- modes release them. BREACH allows only rooms behind the core seal (a core lever, no outer/inner lever), and only
-- while one of their bridges has no linked lever inside the refuge: siege puts the allowed rooms into the civ alert
-- (gate.rooms); an attacker-side room, or the B2 landing while B2 may still be down, would draw fleeing civilians
-- out of Tiefe+ toward the attackers. fortcore gives every bridge a lever inside Tiefe+; once it is linked the
-- BREACH pulls go there. Without act.burrow_units nobody is assigned; the rooms still order the levers and stay
-- in the alert list.
M.ROOM_PREFIX = 'dfllm-levers'
M.PULLERS = 2
M.PULLER_ARRIVE = 600
M.PULLER_RETRY = 600       -- a refused assignment is tried again after this
M.PULLER_FILL = 100        -- a room that found too few candidates looks again after this (a census scan each time)
M.PULLER_THIRST = 20000    -- counters2 thirst_timer / hunger_timer at which a puller is let go (economy's supply
M.PULLER_HUNGER = 40000    -- alarm reads the same counters; DF shows 'thirsty' at 25,000 and 'hungry' at 50,000)
M.ROOM_EVERY = 100         -- ticks between re-reading which manifest levers lie in which room
local PULL_ROLES = {SIEGE = {outer = true, inner = true}, DRILL = {outer = true, inner = true}, BREACH = {core = true}}
local PT = {x = 0, y = 0, z = 0}      -- scratch coord for burrow tile reads
local pl                              -- runtime: {rooms = {<room> = {ids, at, skip, retry}}, warned}
local rooms_c                         -- cached room list {tick, list}

local function burrow(name)
  if type(name) ~= 'string' then return nil end
  local ok, b = pcall(dfhack.burrows.findByName, name)      -- Lua API.txt:2412
  return ok and b or nil
end

local function on_tile(b, x, y, z)
  if not b or x == nil then return false end
  PT.x, PT.y, PT.z = x, y, z
  local ok, r = pcall(dfhack.burrows.isAssignedTile, b, PT)   -- :2436
  return ok and r == true
end

local function unit_pos(u)
  if not u then return nil end
  local ok, x, y, z = pcall(dfhack.units.getPosition, u)
  if ok then return x, y, z end
end

-- the manifest's Kern+ and refuge burrow names (as siege/sense: role kern/refuge, refuge.burrow wins)
local function core_burrows(man)
  local kern, refuge
  local names = {}
  for name in pairs(type(man.burrows) == 'table' and man.burrows or {}) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    local role = type(man.burrows[name]) == 'table' and man.burrows[name].role
    if role == 'kern' and (kern == nil or name == 'Kern+') then kern = name end
    if role == 'refuge' and (refuge == nil or name == 'Tiefe+') then refuge = name end
  end
  if type(man.refuge) == 'table' and type(man.refuge.burrow) == 'string' then refuge = man.refuge.burrow end
  return kern or 'Kern+', refuge or 'Tiefe+'
end

-- existing rooms that hold manifest levers: {name, roles = {outer|inner|core}, bridges = {<b>}, c = lever centre}
local function room_list(K, now)
  if rooms_c and now >= rooms_c.tick and now - rooms_c.tick < M.ROOM_EVERY then return rooms_c.list end
  local man = K.manifest()
  local names, list = {}, {}
  for name in pairs(type(man.burrows) == 'table' and man.burrows or {}) do
    if type(name) == 'string' and name:sub(1, #M.ROOM_PREFIX) == M.ROOM_PREFIX then names[#names + 1] = name end
  end
  table.sort(names)
  for _, name in ipairs(names) do
    local b = burrow(name)
    if b then
      local rm, n, sx, sy, sz = {name = name, roles = {}, bridges = {}}, 0, 0, 0, 0
      for _, bn in ipairs(bridge_names(man)) do
        local spec = man.bridges[bn]
        for _, p in ipairs(spec.levers or {}) do
          if type(p) == 'table' and on_tile(b, p[1], p[2], p[3]) then
            rm.bridges[bn], rm.roles[tostring(spec.role)] = true, true
            n, sx, sy, sz = n + 1, sx + p[1], sy + p[2], sz + p[3]
          end
        end
      end
      if n > 0 then
        rm.c = {x = sx // n, y = sy // n, z = sz // n}
        list[#list + 1] = rm
      end
    end
  end
  rooms_c = {tick = now, list = list}
  return list
end

-- every bridge of the room has a linked lever on a tile of the refuge burrow (gate's resolved levers)
local function refuge_covers(K, rm)
  local _, rn = core_burrows(K.manifest())
  local rb = burrow(rn)
  if not rb then return false end
  for bn in pairs(rm.bridges) do
    local r, ok = rt[bn], false
    for _, lid in ipairs(r and r.levers or {}) do
      local p = r.pos[lid]
      if r.linked[lid] and type(p) == 'table' and on_tile(rb, p[1], p[2], p[3]) then ok = true; break end
    end
    if not ok then return false end
  end
  return true
end

-- BREACH: rooms behind the core seal only, and only while the refuge lacks a linked lever of their bridges (the
-- B2 landing lies next to B2, which may still be down while attackers are inside Kern+)
local function allowed(K, rm, mode)
  if mode ~= 'BREACH' then return true end
  return rm.roles.core == true and not rm.roles.outer and not rm.roles.inner and not refuge_covers(K, rm)
end

local function duty(K, rm, mode)
  local want = PULL_ROLES[mode]
  if not want or not allowed(K, rm, mode) then return false end
  for role in pairs(rm.roles) do if want[role] then return true end end
  return false
end

local function room_state(name)
  local p = pl.rooms[name]
  if not p then
    p = {ids = {}, at = {}, skip = {}}
    pl.rooms[name] = p
  end
  return p
end

-- assigned pullers of a room standing on its tiles now
local function present(rm)
  local p = pl.rooms[rm.name]
  if not p or #p.ids == 0 then return 0 end
  local b, n = burrow(rm.name), 0
  for _, id in ipairs(p.ids) do
    if on_tile(b, unit_pos(df.unit.find(id))) then n = n + 1 end
  end
  return n
end

local function puller_room(id)
  for name, p in pairs(pl.rooms) do
    for _, x in ipairs(p.ids) do if x == id then return name end end
  end
end

local function counter(u, k)
  local ok, v = pcall(function() return u.counters2[k] end)
  return ok and type(v) == 'number' and v or 0
end

-- why a citizen cannot be (or stay) a lever puller: 'gone' = dead, insane (isCitizen is sane only), no citizen,
-- child, soldier or in a strange mood (df.mood_type None = -1); 'needs' = thirsty or hungry; nil = fit
local function unfit(u)
  if not u then return 'gone' end
  local U = dfhack.units
  local ok, r = pcall(function()
    if U.isDead(u) or not U.isCitizen(u) or not U.isAdult(u) then return 'gone' end
    if u.military.squad_id >= 0 then return 'gone' end
    local m = u.mood
    if type(m) == 'number' and m >= 0 then return 'gone' end
    return false
  end)
  if not ok then return 'gone' end
  if r then return r end
  if counter(u, 'thirst_timer') >= M.PULLER_THIRST or counter(u, 'hunger_timer') >= M.PULLER_HUNGER then
    return 'needs'
  end
  return nil
end

-- the burrow's unit list as DF holds it (after a load our runtime is empty); nil if unreadable
local function live_units(name)
  local b = burrow(name)
  if not b then return nil end
  local ok, ids = pcall(function()
    local r = {}
    for _, id in ipairs(b.units) do r[#r + 1] = id end
    return r
  end)
  return ok and ids or nil
end

local function same_set(a, b)
  if #a ~= #b then return false end
  local s = {}
  for _, x in ipairs(a) do s[x] = true end
  for _, x in ipairs(b) do if not s[x] then return false end end
  return true
end

-- nearest eligible citizens inside Kern+/Tiefe+ (z counts double: stairs), outside ones only as a last resort
local function fill(K, rm, want, p, taken, now, home)
  local cu = K.census.u
  if type(cu) ~= 'table' or type(cu.ids) ~= 'table' then return end
  local c, cand = rm.c, {}
  for _, id in ipairs(cu.ids) do
    if not taken[id] and not p.skip[id] then
      local u = df.unit.find(id)
      if unfit(u) == nil then
        local x, y, z = unit_pos(u)
        if x then
          local d = math.max(math.abs(x - c.x), math.abs(y - c.y)) + 2 * math.abs(z - c.z)
          if not (on_tile(home.kern, x, y, z) or on_tile(home.refuge, x, y, z)) then d = d + 1000 end
          cand[#cand + 1] = {id = id, d = d}
        end
      end
    end
  end
  table.sort(cand, function(a, b) if a.d ~= b.d then return a.d < b.d end return a.id < b.id end)
  for _, e in ipairs(cand) do
    if #want >= M.PULLERS then break end
    want[#want + 1] = e.id
    taken[e.id], p.at[e.id] = rm.name, now
  end
end

-- level-triggered: every room's unit list = the pullers the mode wants (none outside SIEGE/DRILL/BREACH)
local function pullers_step(K, now)
  local set = rawget(K.act, 'burrow_units')   -- [S3]: act + contract.ACT entry pending (live engineer)
  local mode = K.mode()
  if not set then
    if PULL_ROLES[mode] and not pl.warned and #room_list(K, now) > 0 then
      pl.warned = true
      K.log('warn', 'gate: act.burrow_units missing, the lever rooms get no pullers')
    end
    return
  end
  local rooms = room_list(K, now)
  if #rooms == 0 then return end
  local kn, rn = core_burrows(K.manifest())
  local home = {kern = burrow(kn), refuge = burrow(rn)}
  local taken = {}
  for _, rm in ipairs(rooms) do
    local p = pl.rooms[rm.name]
    if not p then                                 -- first look after a load: adopt what DF holds
      p = room_state(rm.name)
      p.ids = live_units(rm.name) or {}
      for _, id in ipairs(p.ids) do p.at[id] = now end
    end
    for _, id in ipairs(p.ids) do taken[id] = rm.name end
  end
  for _, rm in ipairs(rooms) do
    local p = pl.rooms[rm.name]
    local want, why_of = {}, {}
    if duty(K, rm, mode) then
      local b = burrow(rm.name)
      for _, id in ipairs(p.ids) do
        local u = df.unit.find(id)
        local why = unfit(u)
        if not why and not on_tile(b, unit_pos(u)) and now - (p.at[id] or now) >= M.PULLER_ARRIVE then why = 'away' end
        if why then
          if why ~= 'needs' then p.skip[id] = true end   -- thirsty/hungry: may serve again after a drink and a meal
          taken[id], why_of[id] = nil, why
        else
          want[#want + 1] = id
        end
      end
      if #want < M.PULLERS and now >= (p.fill_at or now) then
        fill(K, rm, want, p, taken, now, home)
        p.fill_at = #want < M.PULLERS and now + M.PULLER_FILL or nil   -- too few candidates: no scan per step
      end
    elseif next(p.skip) or next(p.at) or p.fill_at then
      p.skip, p.at, p.fill_at = {}, {}, nil       -- the next episode starts afresh
    end
    if not same_set(want, p.ids) and now >= (p.retry or now) then
      local ok = set(rm.name, want)
      if ok then
        local had, keep, new, gone = {}, {}, 0, {}
        for _, id in ipairs(p.ids) do had[id] = true end
        for _, id in ipairs(want) do keep[id] = true; if not had[id] then new = new + 1 end end
        for _, id in ipairs(p.ids) do
          if not keep[id] then
            if taken[id] == rm.name then taken[id] = nil end
            if why_of[id] then gone[#gone + 1] = id .. ':' .. why_of[id] end
          end
        end
        if new > 0 then st.kpi.pa, dirty = (st.kpi.pa or 0) + new, true end
        K.log('info', 'gate: lever pullers %s = {%s} (%s)%s', rm.name, table.concat(want, ','), mode,
              #gone > 0 and (', let go ' .. table.concat(gone, ',')) or '')
        p.ids, p.retry = want, nil
      else
        p.retry = now + M.PULLER_RETRY
      end
    end
  end
end

-- lever order for a pull: 0 = in an allowed room with a puller present, 1 = on a tile of the burrow the civ alert
-- holds the civilians in (BREACH: the refuge if it exists, else Kern+, as siege), 2 = in another allowed room,
-- 3 = the rest; manifest order inside a class (live L3: in BREACH the levers in Kern+ had no worker, GATE_FAIL
-- no_worker x3). In BREACH a linked refuge lever thus comes before the B2 landing.
local function order(K, r, cand, now)
  local mode = K.mode()
  local kn, rn = core_burrows(K.manifest())
  local home = mode == 'BREACH' and burrow(rn) or nil
  home = home or burrow(kn)
  local rooms, pres = {}, {}
  for _, rm in ipairs(room_list(K, now)) do
    if allowed(K, rm, mode) then rooms[#rooms + 1] = {rm = rm, b = burrow(rm.name)} end
  end
  local function class(lid)
    local p = r.pos[lid]
    if type(p) ~= 'table' then return 3 end
    local room
    for _, e in ipairs(rooms) do
      if on_tile(e.b, p[1], p[2], p[3]) then room = e.rm; break end
    end
    if room then
      if pres[room.name] == nil then pres[room.name] = present(room) end
      if pres[room.name] > 0 then return 0 end
    end
    if on_tile(home, p[1], p[2], p[3]) then return 1 end
    return room and 2 or 3
  end
  local cls, idx = {}, {}
  for i, lid in ipairs(cand) do cls[lid], idx[lid] = class(lid), i end
  table.sort(cand, function(a, b) if cls[a] ~= cls[b] then return cls[a] < cls[b] end return idx[a] < idx[b] end)
end

-- linked lever to pull next: first one that has not failed in this epoch, rotating after failures;
-- the link is re-checked right before the pull (a lever may have been unlinked or removed)
local function pick(K, r, now)
  local cand = {}
  for _, lid in ipairs(r.levers) do if r.linked[lid] then cand[#cand + 1] = lid end end
  local n = #cand
  if n == 0 then return nil end
  if n > 1 then order(K, r, cand, now) end
  local start
  for i, lid in ipairs(cand) do if not r.bad[lid] then start = i; break end end
  if not start then
    r.bad, start = {}, 1
    for i, lid in ipairs(cand) do if lid == r.last_lever then start = i % n + 1 end end
  end
  for k = 0, n - 1 do
    local lid = cand[(start - 1 + k) % n + 1]
    if linked_now(r, lid) then return lid end
    r.linked[lid], r.resolved = false, nil     -- stale cache: resolve again on the next pass
  end
  return nil
end

local function grown(fp, m) return {fp[1] - m, fp[2] - m, fp[3], fp[4] + m, fp[5] + m, fp[6]} end

-- citizens (sane or not, CONTRACTS §1.4: by census id) on the footprint now; -1 = unknown (no census)
local function citizens_on(K, name, fp)
  local cu = K.census.u
  if type(cu) ~= 'table' then return -1 end
  if type(cu.ids) ~= 'table' then return (cu.on_bridge or {})[name] or -1 end
  local n = 0
  for _, list in ipairs({cu.ids, type(cu.insane_ids) == 'table' and cu.insane_ids or {}}) do
    for _, id in ipairs(list) do
      local u = df.unit.find(id)
      if u and not dfhack.units.isDead(u) and geom.in_bbox(u.pos, fp) then n = n + 1 end
    end
  end
  return n
end

local function down_guard(K, name)
  local m = K.mode()
  if FAST_MODES[m] then return 'down refused in ' .. m end
  local h = K.census.h
  local d = type(h) == 'table' and type(h.near_bridge) == 'table' and h.near_bridge[name]
  if d and d >= 0 and d <= M.DOWN_GUARD then return 'down refused: hostile within ' .. M.DOWN_GUARD .. ' tiles' end
  return nil
end

-- our pull left the queue and the bridge moved: how long the job waited for its worker (live L3 KPI)
local function note_take(K, name, job, now)
  local t = (job.taken or now) - job.queued
  local by = job.wid and puller_room(job.wid)
  st.kpi.take[name] = t
  if by then st.kpi.pp = (st.kpi.pp or 0) + 1 end
  dirty = true
  K.log('info', 'gate: %s pull taken %d ticks after queueing%s', name, t, by and (' by a puller of ' .. by) or '')
end

local function unit_id(w)
  local ok, id = pcall(function() return w.id end)
  return ok and math.type(id) == 'integer' and id or nil
end

---------------------------------------------------------------- desired state
-- a new want starts a new epoch (deadline, failure flag, lever rotation); same want keeps it
local function set_want(name, w, why, deadline, now)
  local br = st.br[name]
  if br and br.want == w then
    if deadline and br.deadline == nil then br.deadline, dirty = deadline, true end
    return false
  end
  st.br[name] = {want = w, why = tostring(why or ''):sub(1, 40), since = now,
                 deadline = w == 'up' and (deadline or now + M.DEADLINE) or nil, failed = false}
  local r = runtime(name)
  r.bad, r.nw, r.block_since = {}, 0, nil
  dirty = true
  return true
end

local function observe(K, name, r, s, now)
  if s == r.last then return end
  if r.last ~= nil then K.emit('GATE', 'C', name .. ' ' .. s, {bridge = name, state = s}) end
  r.last = s
  if s == 'moving' or s == 'unknown' then return end
  local br = st.br[name]
  -- double toggle: the bridge reached the wanted state in this epoch and left it again
  if br and br.want and r.settled == br.want and s ~= br.want and (r.settled_at or -1) >= br.since then
    st.kpi.dbl = st.kpi.dbl + 1
    dirty = true
    K.log('warn', 'gate: double toggle on %s (wanted %s)', name, br.want)
  end
  if s == 'up' and r.settled ~= nil and r.settled ~= 'up' then
    st.kpi.raise[name] = now - st.kpi.t0
    dirty = true
  end
  if br and s == br.want then r.bad = {} end
  r.settled, r.settled_at = s, now
end

-- one controller pass for one bridge; returns the observed state
local function control(K, name, spec, now)
  local r = runtime(name)
  local br = st.br[name]
  local w = br and br.want
  resolve(r, spec, now, w ~= nil and w ~= r.last)
  local s = read(r)
  observe(K, name, r, s, now)
  r.stuck = nil
  -- 1. our own queued pull
  if r.job then
    local lv = df.building.find(r.job.lever)
    local j = lv and job_on(lv, r.job.id)
    if not j then                                     -- done, or dropped by DF
      if s == r.job.before then r.bad[r.job.lever] = true
      else note_take(K, name, r.job, now) end
      r.job, r.settle = nil, now + M.SETTLE
    else
      local w0 = worker(j)
      if w0 and not r.job.taken then r.job.taken, r.job.wid = now, unit_id(w0) end
      local dir = r.job.before == 'up' and 'down' or 'up'
      -- stale: the want changed, lowering became unsafe, or the bridge moved without us (our
      -- pull would now toggle it back)
      local stale = (w ~= nil and w ~= dir) or (dir == 'down' and down_guard(K, name) ~= nil)
                    or s ~= r.job.before
      -- a citizen stepped onto the footprint before our lowering pull was done: cancel it
      if not stale and dir == 'down' and citizens_on(K, name, spec.fp) ~= 0 then stale = 'blocked' end
      -- live L4: a citizen near the footprint cancels a pending non-forced pull too (M.MARGIN)
      if not stale and not (dir == 'up' and FORCE_MODES[K.mode()])
         and citizens_on(K, name, grown(spec.fp, M.MARGIN)) > 0 then stale = 'blocked' end
      local has_worker = w0 ~= nil
      if not stale then
        if has_worker then r.job.nw = nil
        else
          r.job.nw = r.job.nw or now
          if now - r.job.nw >= M.NO_WORKER then stale = 'no_worker' end
        end
      end
      if not stale then
        r.stuck = (not has_worker) and 'no_worker' or nil
        return s
      end
      local ok = K.act.cancel_own_lever_job(r.job.id)       -- UI: cancel the queued pull
      st.kpi.cancels, dirty = st.kpi.cancels + 1, true
      if stale == 'no_worker' then r.bad[r.job.lever] = true; r.nw = r.nw + 1 end
      r.job = nil
      if not ok then r.settle = now + M.SETTLE; return s end -- it may be completing right now
    end
  end
  -- 2. the invariant: never a second pending pull on any lever of this bridge
  local fj = pending(r)
  if fj then
    r.stuck = worker(fj) and 'pending' or 'no_worker'
    return s
  end
  if w == nil or w == s then r.block_since, r.block_ev = nil, nil; return s end
  if s == 'unknown' then r.stuck = 'no_lever'; return s end
  if s == 'moving' or now < (r.settle or 0) then return s end
  if w == 'down' and down_guard(K, name) then r.stuck = 'guard'; return s end
  -- (4) footprint: raising flings, lowering crushes. 'down' waits without limit (also when the
  -- census is unknown); 'up' is forced after BLOCK_WAIT only in SIEGE/BREACH.
  local on = citizens_on(K, name, spec.fp)
  local forced = w == 'up' and FORCE_MODES[K.mode()]
  local near = forced and 0 or citizens_on(K, name, grown(spec.fp, M.MARGIN))
  if on > 0 or near > 0 or (w == 'down' and on < 0) then
    r.block_since = r.block_since or now
    if not r.block_ev then
      r.block_ev = true
      K.emit('GATE', 'C', name .. ' ' .. w .. ' waits: citizen on the footprint', {bridge = name, state = 'blocked'})
    end
    if not (forced and now - r.block_since >= M.BLOCK_WAIT) then
      r.stuck = 'blocked'
      return s
    end
    K.log('warn', 'gate: raising %s with a citizen on it after %d ticks', name, now - r.block_since)
  end
  r.block_since, r.block_ev = nil, nil
  local lid = pick(K, r, now)
  if not lid then r.stuck, r.resolved = 'no_lever', nil; return s end
  r.last_lever = lid
  local ok, job = K.act.pull(lid)
  if not ok then                                   -- 'no building', 'not a lever', ...: resolve again
    r.bad[lid], r.stuck, r.resolved = true, 'no_lever', nil
    return s
  end
  r.job = {id = job, lever = lid, queued = now, before = s}
  st.kpi.pulls, dirty = st.kpi.pulls + 1, true
  K.emit('LEVER', 'C', 'pull ' .. name .. ' ' .. w, {bridge = name, lever = lid, job = job})
  return s
end

---------------------------------------------------------------- linking (S3, live L2)
-- A manifest lever that is built but not linked to its built bridge gets one link job (act.link_lever = the
-- lever sheet's "link up" with two mechanisms). One pending link job per lever; a refused attempt (usually
-- no free mechanism) is retried after LINK_RETRY, doubling per refusal up to LINK_RETRY_MAX (live L2: a fort
-- without stone refused every day, 50 ACT_FAIL), and the bridge's other levers wait for that retry too
-- (they would need the same mechanisms). Not in SIEGE/BREACH/DRILL: a mechanic must not walk out then.
M.LINK_RETRY, M.LINK_RETRY_MAX = 1200, 9600
local LINK_MODES = {PEACE = true, ALERT = true, RECOVERY = true}
local LINK

local function built(b)
  local ok, r = pcall(function() return b:getBuildStage() >= b:getMaxBuildStage() end)
  return ok and r == true
end

local function link_pending(lv)
  LINK = LINK or (df.job_type and df.job_type.LinkBuildingToTrigger)
  for _, j in ipairs(lv.jobs) do if j.job_type == LINK then return j end end
end

local function links(K, name, spec, r, now)
  if not LINK_MODES[K.mode()] or now < (r.link_at or 0) then return end
  local b = r.bid and df.building.find(r.bid)
  if not b or not built(b) then return end
  for _, p in ipairs(spec.levers or {}) do
    local lv = find_at(p)
    if lv and is_lever(lv) and built(lv) and not link_pending(lv) then
      local t = targets(lv)
      if t and not t[b.id] then
        local ok, res = K.act.link_lever(lv.id, b.id)
        if not ok then
          r.link_wait = math.min(M.LINK_RETRY_MAX, r.link_wait and r.link_wait * 2 or M.LINK_RETRY)
          r.link_at = now + r.link_wait
          return
        end
        r.link_wait = nil
        if math.type(res) == 'integer' then
          st.kpi.links, dirty = (st.kpi.links or 0) + 1, true
          K.emit('LEVER', 'C', 'link ' .. name, {bridge = name, lever = lv.id, job = res})
        end
        r.resolved = nil                          -- re-read the links on the next pass
      end
    end
  end
end

local function check_fail(K, name, now, mode)
  local br = st.br[name]
  if not (br and br.want == 'up' and not br.failed and br.deadline and now >= br.deadline) then return end
  local r = runtime(name)
  if r.last == 'up' then return end
  br.failed, dirty = true, true
  local why = FAIL_WHY[r.stuck] or (r.nw > 0 and 'no_worker') or 'timeout'
  local f = st.kpi.fails
  if #f < 8 then f[#f + 1] = name .. ':' .. why end
  if (mode or K.mode()) == 'DRILL' then return end    -- a drill reports through drill.kpi, not A events
  if r.fail_tick and now - r.fail_tick < M.FAIL_REPEAT then return end
  r.fail_tick = now
  K.emit('GATE_FAIL', 'A', string.format('%s not up after %d ticks (%s)', name, now - br.since, why),
         {bridge = name, want = 'up', why = why})
end

local function update_every(K)
  local fast = FAST_MODES[K.mode()] or false
  if not fast then
    for name, r in pairs(rt) do
      local br = st.br[name]
      if r.job or (br and br.want and br.want ~= r.last) then fast = true; break end
    end
  end
  local want = fast and M.FAST or M.SLOW
  if M.every.ticks ~= want then M.every = {ticks = want} end
end

-- mode default for a bridge without a want: PEACE down, BREACH up
local function ensure_default(K, name, now)
  if st.br[name] ~= nil then return end
  local m = K.mode()
  if m == 'PEACE' then set_want(name, 'down', 'peace', nil, now)
  elseif m == 'BREACH' then set_want(name, 'up', 'breach', nil, now) end
end

---------------------------------------------------------------- module
function M.init(K)
  local now = K.now().tick
  st = {v = 2, br = {}, kpi = new_kpi(now)}
  local p = K.persist.get('m.gate')
  if type(p) == 'table' then
    for name, br in pairs(type(p.br) == 'table' and p.br or {}) do
      if type(br) == 'table' and (br.want == 'up' or br.want == 'down') then
        st.br[name] = {want = br.want, why = br.why or '', since = br.since and math.tointeger(br.since) or now,
                       deadline = br.deadline and math.tointeger(br.deadline), failed = br.failed == true}
      end
    end
    if type(p.kpi) == 'table' then
      local function int(v) return type(v) == 'number' and math.tointeger(v) or nil end
      local k = new_kpi(int(p.kpi.t0) or now)
      for _, f in ipairs({'dbl', 'pulls', 'cancels', 'links', 'pp', 'pa'}) do k[f] = int(p.kpi[f]) or 0 end
      for n, v in pairs(type(p.kpi.raise) == 'table' and p.kpi.raise or {}) do k.raise[n] = int(v) end
      for n, v in pairs(type(p.kpi.take) == 'table' and p.kpi.take or {}) do k.take[n] = int(v) end
      for _, f in ipairs(type(p.kpi.fails) == 'table' and p.kpi.fails or {}) do k.fails[#k.fails + 1] = f end
      st.kpi = k
    end
  end
  rt, pub, dirty, PULL = {}, nil, false, nil
  pl, rooms_c = {rooms = {}}, nil
  M.every = {ticks = FAST_MODES[K.mode()] and M.FAST or M.SLOW}
end

function M.step(K, budget, ctx)
  local now = K.now().tick
  local man = K.manifest()
  local states = {}
  local gone = {}                                -- forget bridges the manifest no longer lists
  for name in pairs(rt) do gone[name] = true end
  for name in pairs(st.br) do gone[name] = true end
  for name in pairs(gone) do
    if not valid_spec((man.bridges or {})[name]) then rt[name], st.br[name], dirty = nil, nil, true end
  end
  pullers_step(K, now)
  for _, name in ipairs(bridge_names(man)) do
    ensure_default(K, name, now)
    states[name] = control(K, name, man.bridges[name], now)
    check_fail(K, name, now)
    links(K, name, man.bridges[name], runtime(name), now)
  end
  pub = next(states) and {bridges = states} or {}
  update_every(K)
  flush(K)
end

-- public (CONTRACTS §7): request a bridge state. 'up' is always honoured; 'down' is refused in
-- SIEGE/BREACH/DRILL and while a visible hostile is within 30 tiles. deadline (abs tick, optional,
-- WP5 extension) = when a missing 'up' becomes GATE_FAIL; default now + 900.
function M.want(K, bridge, want, why, deadline)
  if want ~= 'up' and want ~= 'down' then return false, 'want must be up or down' end
  local man = K.manifest()
  local spec = type(man.bridges) == 'table' and man.bridges[bridge]
  if not valid_spec(spec) then return false, 'no bridge ' .. tostring(bridge) end
  if want == 'down' then
    local g = down_guard(K, bridge)
    if g then return false, g end
  end
  local now = K.now().tick
  local changed = set_want(bridge, want, why, deadline and math.tointeger(deadline), now)
  control(K, bridge, spec, now)
  update_every(K)
  flush(K)
  return true, (changed and 'wanted ' or 'still ') .. bridge .. ' ' .. want
end

-- module state part (no bridge) or public gate.state(bridge) -> state, pending job id
function M.state(K, bridge)
  if bridge == nil then return pub or {} end
  local man = K.manifest()
  local spec = type(man.bridges) == 'table' and man.bridges[bridge]
  if not valid_spec(spec) then return 'unknown', nil end
  local r = runtime(bridge)
  resolve(r, spec, K.now().tick)
  local s = read(r)
  local j = r.job and r.job.id
  if not j then
    local fj = pending(r)
    j = fj and fj.id or nil
  end
  return s, j
end

function M.kpi(K)
  local raise, fails, take, pullers = {}, {}, {}, {}
  for n, v in pairs(st.kpi.raise) do raise[n] = v end
  for i, f in ipairs(st.kpi.fails) do fails[i] = f end
  for n, v in pairs(st.kpi.take) do take[n] = v end
  for n, p in pairs(pl.rooms) do pullers[n] = #p.ids end
  return {double_toggles = st.kpi.dbl, last_raise_ticks = raise, pulls = st.kpi.pulls,
          cancels = st.kpi.cancels, links = st.kpi.links or 0, fails = fails, since = st.kpi.t0,
          take_ticks = take, puller_pulls = st.kpi.pp or 0, puller_assigns = st.kpi.pa or 0, pullers = pullers}
end

-- public (WP5 extension, live L3): the lever rooms allowed in `mode` (default: now) that exist, sorted; siege
-- adds them to the civ-alert burrow list (BREACH: only the rooms behind the core seal whose bridges have no
-- linked lever inside the refuge yet)
function M.rooms(K, mode)
  mode = mode or K.mode()
  local r = {}
  for _, rm in ipairs(room_list(K, K.now().tick)) do
    if allowed(K, rm, mode) then r[#r + 1] = rm.name end
  end
  return r
end

-- public (WP5 extension, live L3): assigned pullers standing in an allowed room that holds a lever of `bridge`
function M.pullers(K, bridge)
  local mode, n = K.mode(), 0
  for _, rm in ipairs(room_list(K, K.now().tick)) do
    if rm.bridges[bridge] and allowed(K, rm, mode) then n = n + present(rm) end
  end
  return n
end

function M.reset_kpi(K)
  st.kpi = new_kpi(K.now().tick)
  dirty = true
  flush(K)
end

M.on = {
  MODE = function(K, ev)
    local now = ev.tick or K.now().tick
    local man = K.manifest()
    pullers_step(K, now)                         -- T0: pullers walk to the levers; PEACE etc. release them
    for _, name in ipairs(bridge_names(man)) do
      local r = runtime(name)
      resolve(r, man.bridges[name], now)
      observe(K, name, r, read(r), now)
      check_fail(K, name, now, ev.from) -- settle the old epoch first (SIEGE->BREACH at T+900 = its deadline)
      local br = st.br[name]
      if ev.to == 'PEACE' then
        set_want(name, 'down', 'peace', nil, now)
      elseif ev.to == 'BREACH' then
        if br and br.want == 'up' and br.since < now then
          br.since, br.deadline, br.failed, dirty = now, now + M.DEADLINE, false, true
        else
          set_want(name, 'up', 'breach', now + M.DEADLINE, now)
        end
      elseif ev.to == 'SIEGE' or ev.to == 'DRILL' then
        if br and br.want == 'down' then st.br[name], dirty = nil, true      -- never lower now
        elseif br and br.want == 'up' and br.since < now then                -- new epoch, siege sets the deadline
          br.since, br.deadline, br.failed, dirty = now, nil, false, true
        end
      end
      control(K, name, man.bridges[name], now)   -- cancels a stale own pull at once
    end
    update_every(K)
    flush(K)
  end,
}

-- inbox `lever` (PEACE only, checked by kern): {bridge, want}
M.verbs.lever = function(K, args, cmd)
  local b, w = args.bridge, args.want
  if type(b) ~= 'string' or (w ~= 'up' and w ~= 'down') then return false, 'need bridge and want up|down' end
  local ok, msg = M.want(K, b, w, 'lever:' .. tostring(cmd and cmd.by or '?'))
  if not ok then return false, msg end
  local r = runtime(b)
  if r.job then return true, 'queued ' .. b .. ' ' .. w, {job = r.job.id} end
  if r.last == w then return true, b .. ' already ' .. w end
  return true, 'wanted ' .. b .. ' ' .. w .. ' (' .. (r.stuck or 'waiting') .. ')'
end

return M
