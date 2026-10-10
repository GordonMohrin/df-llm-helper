-- siege (WP5): the mode FSM (DESIGN §3 mode table, §4 siege reflex, CONTRACTS §14) and the sole
-- writer of the civ alert and its burrow list (via act -> gui/civ-alert, civ-alert.lua:27-50).
-- Inputs are visibility only (threat.assess over K.census.h); a raised bridge cuts the walk
-- groups, so path existence is never used to leave a siege.
--   T0 (detecting step): mode SIEGE, civ alert on (Kern+), posture READY_STATION, SIEGE_START.
--   T0..T0+600: O1/B1 up as soon as nobody (soldiers excluded) is outside, or at T+600, or when a
--     visible hostile is <= 10 tiles from that bridge (gate keeps the single-pending invariant).
--   T0+900: an outer/inner bridge not up -> BREACH in-game (alert Tiefe+, B2 up, B2_HOLD).
--   RECOVERY after 2,400 quiet ticks; on quiet time +1,200 B2 then B1 down and alert off,
--     +2,400 O1 down, +8,400 PEACE and SIEGE_END (A). Any visible invader -> SIEGE again.
-- Non-invader hostiles count only within reach of the fort (threat.lua), the same rule for entry,
-- re-entry and quiet. Kill orders are withdrawn when no target is left in a kill box. Losses are
-- checked against every citizen seen in the episode (the census drops the dead before UNIT_DEATH).
local geom = require('dfllm.util.geom')

-- every frame, but a full step only on a fresh hostile census or every PERIOD ticks, so the
-- decision lands in the frame that sense published the census (latency = sense scan period)
local M = {name = 'siege', every = {ticks = 1}, critical = true}
M.PERIOD, M.PERIOD_ARMED = 25, 10

M.RAISE_BY, M.BREACH_AT, M.NEAR_RAISE = 600, 900, 10
M.QUIET, M.ALERT_QUIET = 2400, 1200
M.REC_INNER, M.REC_OUTER, M.REC_PEACE = 1200, 2400, 8400
M.ALERT_CIV_ON, M.ALERT_CIV_OFF, M.ALERT_CIV_HOLD, M.ALERT_O1 = 30, 40, 600, 30
M.ANCHORS = 20             -- alert anchors kept (positions of citizens outside at alert-on)
M.STATUS, M.RETRY, M.POSTURE_REASSERT, M.KILL_EVERY = 600, 600, 3600, 100
M.DRILL_MAX = 3600         -- a drill normally ends at T+1,200 (drill module)

local POSTURE = {PEACE = 'TRAIN', ALERT = 'STATION_B1', SIEGE = 'READY_STATION', DRILL = 'READY_STATION',
                 BREACH = 'B2_HOLD', RECOVERY = 'STATION_B1'}
local EPISODE = {SIEGE = true, BREACH = true, RECOVERY = true}
local SHAFT = {['<'] = true, ['>'] = true, X = true, _ = true}

local st      -- persisted m.siege
local mem     -- runtime only (what was applied, ids seen)
local dirty

local function int(v) return type(v) == 'number' and math.tointeger(v) or nil end
local function save(K) if dirty then K.persist.set('m.siege', st); dirty = false end end

local function sorted_keys(t)
  local r = {}
  for k in pairs(t or {}) do r[#r + 1] = k end
  table.sort(r)
  return r
end

-- bridge names by role and burrow names from the manifest
local function geometry(K)
  local man = K.manifest()
  local g = {outer = {}, inner = {}, core = {}, all = {}, man = man}
  for _, name in ipairs(sorted_keys(man.bridges)) do
    local b = man.bridges[name]
    if type(b) == 'table' and type(b.fp) == 'table' and g[b.role] then
      local list = g[b.role]
      list[#list + 1] = name
      g.all[#g.all + 1] = name
    end
  end
  local kern, refuge
  for _, name in ipairs(sorted_keys(man.burrows)) do
    local role = type(man.burrows[name]) == 'table' and man.burrows[name].role
    if role == 'kern' and (kern == nil or name == 'Kern+') then kern = name end
    if role == 'refuge' and (refuge == nil or name == 'Tiefe+') then refuge = name end
  end
  if type(man.refuge) == 'table' and type(man.refuge.burrow) == 'string' then refuge = man.refuge.burrow end
  g.kern, g.refuge = kern or 'Kern+', refuge or 'Tiefe+'
  return g
end

---------------------------------------------------------------- inputs
-- threat.assess; minimal fallback on the census if threat is missing or disabled
local function assess(K)
  local ok, a = K.call('threat', 'assess')
  if ok then return a end
  local h = K.census.h
  if type(h) ~= 'table' then return nil end
  local fresh = K.now().tick - (h.tick or 0) <= 200
  local inv, great, vis, inside = h.inv or 0, h.great or 0, h.vis or 0, h.inside or 0
  return {vis = vis, inv = inv, great = great, undead = h.undead or 0, inside = inside,
          near_o1 = h.near_o1 or -1, near_cit = h.near_cit or -1, near_bridge = h.near_bridge or {},
          siege = (great > 0 and 'great') or (inv >= 6 and 'invaders') or nil, hostile = vis > 0,
          quiet = fresh and vis == 0, calm = fresh and vis == 0, fresh = fresh}
end

local function gate_state(K, b)
  local ok, s = K.call('gate', 'state', b)
  return ok and s or 'unknown'
end

local function want(K, b, w, why, deadline)
  local ok, ok2 = K.call('gate', 'want', b, w, why, deadline)
  return ok and ok2 == true
end

local function alert_idx()
  local ok, v = pcall(function() return df.global.plotinfo.alerts.civ_alert_idx end)
  return ok and v or nil
end

local function wealth(K, why)
  local ok, d = pcall(function()
    local w = df.global.plotinfo.tasks.wealth
    return {created = int(w.total), exported = int(w.exported), imported = int(w.imported)}
  end)
  if ok and d and d.created then
    K.emit('WEALTH', 'B', string.format('wealth at %s: created %d', why, d.created), d)
  end
end

---------------------------------------------------------------- transitions
local function go(K, to, why, a, bridge)
  local from, ep = K.mode(), st.ep
  if not K.set_mode(to, why) then return false end
  local vis = a and a.vis or 0
  if to == 'SIEGE' then
    K.emit('SIEGE_START', 'B', string.format('siege (%s): %d visible, %d invaders', why, vis, a and a.inv or 0),
           {vis = vis, inv = a and a.inv or 0, great = a and a.great or 0, why = why})
    wealth(K, 'siege')
  elseif to == 'ALERT' then
    K.emit('ALERT_START', 'B', string.format('alert: %d visible hostiles', vis), {vis = vis})
    wealth(K, 'alert')
  elseif to == 'BREACH' then
    K.emit('BREACH', 'A', 'breach: ' .. (bridge and (bridge .. ' not up at T+900') or 'hostile inside Kern+'),
           {why = why == 'gate_fail' and 'gate_fail' or 'inside', bridge = bridge})
    wealth(K, 'breach')
  elseif to == 'PEACE' and from == 'ALERT' then
    K.emit('ALERT_END', 'B', 'alert over', {vis = vis})
  elseif to == 'PEACE' and from == 'RECOVERY' and ep then
    local hostiles = math.max(ep.hmax or 0, ep.seen or 0)
    K.emit('SIEGE_END', 'A', string.format('%d hostiles, %d killed, %d lost, sealed %d ticks',
           hostiles, ep.killed, ep.lost, ep.sealed),
           {hostiles = hostiles, killed = ep.killed, lost = ep.lost, captures = ep.caps, sealed_ticks = ep.sealed})
  end
  return true
end

-- contiguous quiet (visibility only)
local function quiet_for(a, now, n)
  if a and a.quiet then
    st.qs = st.qs or now
    return now - st.qs >= n
  end
  if st.qs then st.qs, dirty = nil, true end
  return false
end

local function failed_bridge(K, g)
  for _, list in ipairs({g.outer, g.inner}) do
    for _, b in ipairs(list) do
      if gate_state(K, b) ~= 'up' then return b end
    end
  end
  return nil
end

local function decide(K, a, g, now)
  local mode = K.mode()
  if mode == 'PEACE' then
    if not a then return end
    if a.siege then
      if go(K, 'SIEGE', a.siege, a) and a.inside > 0 then go(K, 'BREACH', 'inside', a) end
    elseif a.inside > 0 then
      if go(K, 'ALERT', 'inside', a) then go(K, 'BREACH', 'inside', a) end
    elseif a.hostile then go(K, 'ALERT', 'hostile', a) end
  elseif mode == 'ALERT' then
    if not a then return end
    if a.inside > 0 then go(K, 'BREACH', 'inside', a)
    elseif a.siege then go(K, 'SIEGE', a.siege, a)
    elseif a.calm then
      st.aq = st.aq or now
      if now - st.aq >= M.ALERT_QUIET then go(K, 'PEACE', 'quiet', a) end
    elseif st.aq then st.aq, dirty = nil, true end
  elseif mode == 'SIEGE' then
    if a and a.inside > 0 then go(K, 'BREACH', 'inside', a); return end
    local fb = now - st.t0 >= M.BREACH_AT and failed_bridge(K, g)
    if fb then go(K, 'BREACH', 'gate_fail', a, fb)
    elseif quiet_for(a, now, M.QUIET) then go(K, 'RECOVERY', 'quiet', a) end
  elseif mode == 'BREACH' then
    if quiet_for(a, now, M.QUIET) then go(K, 'RECOVERY', 'quiet', a) end
  elseif mode == 'RECOVERY' then
    if a and a.inside > 0 then go(K, 'BREACH', 'inside', a)
    elseif a and (a.inv > 0 or a.siege) then go(K, 'SIEGE', 'reentry', a)   -- same reach rule as entry
    else
      if a and a.quiet then st.rq = st.rq + math.max(0, now - st.rl) end   -- the clock stops otherwise
      st.rl, dirty = now, true
      if st.rq >= M.REC_PEACE then go(K, 'PEACE', 'recovered', a) end
    end
  elseif mode == 'DRILL' then
    if a and (a.siege or a.inside > 0) then
      if go(K, 'SIEGE', a.siege or 'inside', a) and a.inside > 0 then go(K, 'BREACH', 'inside', a) end
    elseif a and a.hostile then go(K, 'ALERT', 'hostile in drill', a)
    elseif not K.enabled('drill') or now - st.t0 >= M.DRILL_MAX then
      go(K, 'PEACE', 'drill timeout')          -- nobody else will end it (drill missing or stuck)
    end
  end
end

---------------------------------------------------------------- actuators (level-triggered)
-- ALERT anchors: where the citizens outside Kern+ stood when the civ alert went on (read by census
-- id, CONTRACTS §1.4). Obeying the alert takes them inside, so "near a citizen outside" stops being
-- measurable; the alert is held against these anchors (and O1) instead, which prevents flapping.
local function add_anchors(K)
  local cu = K.census.u
  local at = st.civ_at or {}
  for _, id in ipairs(type(cu) == 'table' and type(cu.outside_ids) == 'table' and cu.outside_ids or {}) do
    if #at >= M.ANCHORS then break end
    local u = df.unit.find(id)
    local x, y, z
    if u then x, y, z = dfhack.units.getPosition(u) end
    if x then
      local dup = false
      for _, p in ipairs(at) do if p[1] == x and p[2] == y and p[3] == z then dup = true; break end end
      if not dup then at[#at + 1] = {x, y, z} end
    end
  end
  st.civ_at = at
end

-- min distance from a listed hostile to the anchors or the O1 footprint centre; -1 when none
local function anchor_dist(K, g)
  local h = K.census.h
  local pts = {}
  for _, p in ipairs(st.civ_at or {}) do pts[#pts + 1] = {x = p[1], y = p[2], z = p[3]} end
  local o1 = g.man.bridges and g.man.bridges[g.outer[1]]
  if o1 then pts[#pts + 1] = geom.bbox_center(o1.fp) end
  local best = -1
  for _, e in ipairs(type(h) == 'table' and h.list or {}) do
    for _, p in ipairs(pts) do
      local d = geom.dist(e, p)
      if best < 0 or d < best then best = d end
    end
  end
  return best
end

local function alert_wanted(K, a, g, now)
  local mode = K.mode()
  if mode == 'SIEGE' or mode == 'DRILL' or mode == 'BREACH' then return true end
  if mode == 'RECOVERY' then return not st.b1low end
  if mode ~= 'ALERT' then return false end
  -- ALERT: on while a hostile is <= 30 tiles from a citizen outside; held while a hostile is <= 40
  -- from a citizen still outside, an anchor or O1; off after 600 ticks beyond that
  if a then
    local d = a.near_cit
    if d >= 0 and d <= M.ALERT_CIV_ON then
      add_anchors(K)
      st.civ, st.far, dirty = true, nil, true
    elseif st.civ then
      local da = anchor_dist(K, g)
      local held = (d >= 0 and d <= M.ALERT_CIV_OFF) or (da >= 0 and da <= M.ALERT_CIV_OFF)
      if held then
        if st.far then st.far, dirty = nil, true end
      else
        st.far = st.far or now
        if now - st.far >= M.ALERT_CIV_HOLD then st.civ, st.far, st.civ_at = false, nil, nil end
        dirty = true
      end
    end
  end
  return st.civ == true
end

local function set_alert(K, on, burrow, g, now)
  local cur = alert_idx()
  if not on then
    if cur ~= nil and cur ~= 0 then K.act.civ_alert(false) end
    return
  end
  if mem.burrow ~= burrow and now >= (mem.alert_retry or now) then
    if K.act.alert_burrows({burrow}) then mem.burrow = burrow
    else                                   -- e.g. no Tiefe+ yet: Kern+ beats no alert
      mem.alert_retry = now + M.RETRY
      if burrow ~= g.kern and mem.burrow ~= g.kern and K.act.alert_burrows({g.kern}) then mem.burrow = g.kern end
    end
  end
  if mem.burrow and cur == 0 and now >= (mem.civ_retry or now) then
    if not K.act.civ_alert(true) then mem.civ_retry = now + M.RETRY end
  end
end

local function set_posture(K, P, now)
  if mem.posture == P and now - mem.posture_tick < M.POSTURE_REASSERT then return end
  if mem.posture_want == P and now < (mem.posture_retry or now) then return end
  mem.posture_want = P
  local ok, r = K.call('military', 'posture', P)
  if ok and r ~= false then mem.posture, mem.posture_tick = P, now
  else mem.posture_retry = now + M.RETRY end
end

-- T0..T0+600 raise rule for the outer and inner bridges. "Nobody outside" is trusted only from a
-- census taken at or after T0 (sense rescans inside the mode change); an older one may miss a
-- citizen who just walked out, and the reason is latched in st.req.
local function raise(K, g, now)
  local t = now - st.t0
  local cu, h = K.census.u, K.census.h
  local outside = type(cu) == 'table' and (cu.tick or -1) >= st.t0 and cu.outside or -1
  local nb = type(h) == 'table' and type(h.near_bridge) == 'table' and h.near_bridge or {}
  for _, list in ipairs({g.outer, g.inner}) do
    for _, b in ipairs(list) do
      local why = st.req[b]
      if not why then
        local d = nb[b]
        if outside == 0 then why = 'inside'
        elseif t >= M.RAISE_BY then why = 'timer'
        elseif d and d >= 0 and d <= M.NEAR_RAISE then why = 'hostile_near' end
      end
      if why and want(K, b, 'up', why, st.t0 + M.BREACH_AT) and not st.req[b] then
        st.req[b], dirty = why, true
      end
    end
  end
end

-- RECOVERY: +1,200 quiet: B2 (core) down, then B1 (inner); +2,400: O1 (outer)
local function lower(K, g)
  local q = st.rq
  local low = false
  if q >= M.REC_INNER then
    local cores = true
    for _, b in ipairs(g.core) do
      want(K, b, 'down', 'recovery')
      if gate_state(K, b) ~= 'down' then cores = false end
    end
    low = cores
    if cores then
      for _, b in ipairs(g.inner) do
        want(K, b, 'down', 'recovery')
        if gate_state(K, b) ~= 'down' then low = false end
      end
    end
  end
  if q >= M.REC_OUTER then
    for _, b in ipairs(g.outer) do want(K, b, 'down', 'recovery') end
  end
  if low ~= st.b1low then st.b1low, dirty = low, true end
end

local function on_stair(man, e)
  local stairs = type(man.stairs) == 'table' and man.stairs or {}
  for _, kind in ipairs({'civ', 'mil'}) do
    for _, c in ipairs(type(stairs[kind]) == 'table' and stairs[kind] or {}) do
      if e.x == c[1] and e.y == c[2] and e.z >= c[3] and e.z <= c[4] then return true end
    end
  end
  return false
end

-- withdraw siege's kill orders (squads back to their posture stations). military.kill({}) = clear
-- held kill orders and re-apply the posture, else posture(P, force): both are WP6 extensions of
-- CONTRACTS §7 (military keeps a running kill order as held, military.lua apply_squad).
local function withdraw(K, P, now)
  local ok, r = K.call('military', 'kill', {})
  if not (ok and r == true) then K.call('military', 'posture', P, true) end
  mem.posture, mem.posture_tick = P, now
  K.log('info', 'siege: kill orders withdrawn (no target left in a kill box)')
end

-- kill orders only on visible targets inside manifest.killboxes, never on stair/shaft tiles. An
-- ordered target that is no longer valid (dead, out of the box, out of view) replaces the order at
-- once with the remaining targets, or withdraws it when none is left; new targets every 100 ticks.
local function kills(K, g, P, now)
  local h, man = K.census.h, g.man
  local boxes = type(man.killboxes) == 'table' and man.killboxes or {}
  if type(h) ~= 'table' then return end
  local ids, set = {}, {}
  for _, e in ipairs(#boxes > 0 and h.list or {}) do
    local p = {x = e.x, y = e.y, z = e.z}
    local inbox = false
    for _, kb in ipairs(boxes) do
      if type(kb.bbox) == 'table' and geom.in_bbox(p, kb.bbox) then inbox = true; break end
    end
    if inbox and not on_stair(man, e) then
      local ok, t = K.call('snapshot', 'tile', e.x, e.y, e.z)
      if not (ok and type(t) == 'table' and SHAFT[t.c]) then ids[#ids + 1] = e.id; set[e.id] = true end
    end
  end
  table.sort(ids)
  local sig = table.concat(ids, ',')
  if sig == (mem.kill_sig or '') then return end
  local lost = false
  for id in pairs(mem.kill_set or {}) do if not set[id] then lost = true; break end end
  if #ids == 0 then
    withdraw(K, P, now)
    mem.kill_sig, mem.kill_set = nil, nil
    return
  end
  if not lost and now - (mem.kill_tick or -M.KILL_EVERY) < M.KILL_EVERY then return end
  mem.kill_tick = now
  local ok, r = K.call('military', 'kill', ids)
  if ok and r ~= false then mem.kill_sig, mem.kill_set = sig, set
  elseif mem.kill_sig then                       -- refused: never leave the old order running
    withdraw(K, P, now)
    mem.kill_sig, mem.kill_set = nil, nil
  end
end

local function apply(K, a, g, now)
  local mode = K.mode()
  if mode == 'SIEGE' or mode == 'DRILL' then raise(K, g, now)
  elseif mode == 'BREACH' then
    for _, b in ipairs(g.all) do want(K, b, 'up', 'breach', st.tb + M.BREACH_AT) end
  elseif mode == 'ALERT' then
    if a and a.near_o1 >= 0 and a.near_o1 <= M.ALERT_O1 then
      for _, b in ipairs(g.outer) do want(K, b, 'up', 'alert') end
    end
  elseif mode == 'RECOVERY' then lower(K, g) end
  set_alert(K, alert_wanted(K, a, g, now), mode == 'BREACH' and g.refuge or g.kern, g, now)
  set_posture(K, POSTURE[mode], now)
  if mode == 'SIEGE' or mode == 'BREACH' then kills(K, g, POSTURE[mode], now) end
end

---------------------------------------------------------------- episode bookkeeping
-- every citizen id seen in this episode: the census (every 25 ticks in SIEGE) drops the dead before
-- the UNIT_DEATH poll (eventful freq 100) delivers them, so the current census cannot decide
local function note_citizens(K)
  local cu = K.census.u
  if type(cu) ~= 'table' or mem.cit_src == cu then return end
  mem.cit_src = cu
  for _, list in ipairs({cu.ids, cu.insane_ids}) do
    for _, id in ipairs(type(list) == 'table' and list or {}) do mem.cit_ever[id] = true end
  end
end

local function track(K, g, now, dt)
  local ep = st.ep
  if not ep or not EPISODE[K.mode()] then return end
  note_citizens(K)
  local h, cu = K.census.h, K.census.u
  if type(h) == 'table' then
    if (h.vis or 0) > ep.hmax then ep.hmax = h.vis end
    for _, e in ipairs(h.list or {}) do
      if not mem.hseen[e.id] then mem.hseen[e.id], mem.nseen = true, mem.nseen + 1 end
    end
    if mem.nseen > (ep.seen or 0) then ep.seen = mem.nseen end
  end
  if type(cu) == 'table' and type(cu.caged) == 'table' then
    if mem.caged0 == nil then                    -- after a reload: current cages are not new
      mem.caged0 = {}
      for _, id in ipairs(cu.caged) do mem.caged0[id] = true end
    end
    for _, id in ipairs(cu.caged) do
      if not mem.caged0[id] and not mem.caps[id] then mem.caps[id], ep.caps = true, ep.caps + 1 end
    end
  end
  local b = g.inner[1] or g.outer[1]
  if b and dt > 0 and gate_state(K, b) == 'up' then ep.sealed = ep.sealed + dt end
  dirty = true
end

local function status(K, a, now)
  local ep = st.ep
  if not ep or not EPISODE[K.mode()] or now - (st.ls or -M.STATUS) < M.STATUS then return end
  st.ls, dirty = now, true
  local d = {vis = a and a.vis or 0, deaths = ep.lost, captures = ep.caps}
  local ok, k = K.call('military', 'kpi')
  if ok and type(k) == 'table' then d.worn, d.on_station = int(k.worn), int(k.on_station) end
  K.emit('SIEGE_STATUS', 'C', string.format('%s: %d visible, %d lost', K.mode(), d.vis, ep.lost), d)
end

---------------------------------------------------------------- module
function M.init(K)
  local now = K.now().tick
  local p = K.persist.get('m.siege')
  p = type(p) == 'table' and p or {}
  st = {v = 2, t0 = int(p.t0) or K.mode_since(), tb = int(p.tb) or K.mode_since(), req = {},
        rq = int(p.rq) or 0, rl = now, civ = p.civ == true, b1low = p.b1low == true, ls = int(p.ls)}
  for b, why in pairs(type(p.req) == 'table' and p.req or {}) do
    if type(b) == 'string' then st.req[b] = tostring(why) end
  end
  if type(p.ep) == 'table' then
    st.ep = {}
    for _, f in ipairs({'start', 'hmax', 'seen', 'killed', 'lost', 'caps', 'sealed'}) do st.ep[f] = int(p.ep[f]) or 0 end
  end
  if type(p.civ_at) == 'table' then
    st.civ_at = {}
    for _, q in ipairs(p.civ_at) do
      if type(q) == 'table' and int(q[1]) and int(q[2]) and int(q[3]) then st.civ_at[#st.civ_at + 1] = {int(q[1]), int(q[2]), int(q[3])} end
    end
  end
  -- quiet windows restart after a load (persist may lag the save by a few seconds)
  mem = {hseen = {}, nseen = 0, caps = {}, caged0 = nil, posture_tick = 0, cit_ever = {}}
  dirty = true
end

function M.step(K, budget, ctx)
  local now = K.now().tick
  local h = K.census.h
  local htick = type(h) == 'table' and h.tick or -1
  local period = (type(h) == 'table' and h.armed == 1) and M.PERIOD_ARMED or M.PERIOD
  if htick == mem.htick and mem.last and now - mem.last < period then return end   -- nothing new
  local dt = mem.last and now - mem.last or 0
  mem.htick, mem.last = htick, now
  local a = assess(K)
  local g = geometry(K)
  decide(K, a, g, now)
  track(K, g, now, dt)
  apply(K, a, g, now)
  status(K, a, now)
  save(K)
end

M.on = {
  MODE = function(K, ev)
    local to, now = ev.to, ev.tick or K.now().tick
    st.qs, st.aq = nil, nil
    if to == 'SIEGE' or to == 'DRILL' then st.t0, st.req = now, {} end
    if to == 'BREACH' then st.tb = now end
    if to == 'RECOVERY' then st.rq, st.rl, st.b1low = 0, now, false end
    if to == 'ALERT' then st.civ, st.far, st.civ_at = false, nil, nil end
    if (to == 'SIEGE' or to == 'BREACH') and not st.ep then
      st.ep = {start = now, hmax = 0, seen = 0, killed = 0, lost = 0, caps = 0, sealed = 0}
      mem.hseen, mem.nseen, mem.caps, mem.caged0 = {}, 0, {}, nil
      mem.cit_ever, mem.cit_src = {}, nil
      note_citizens(K)
    end
    mem.kill_sig, mem.kill_set = nil, nil      -- a posture change re-issues every squad's orders
    if to == 'PEACE' or to == 'DRILL' then st.ep = nil end
    dirty = true
    apply(K, assess(K), geometry(K), now)    -- T0 actions in the detecting step
    save(K)
  end,
  UNIT_DEATH = function(K, ev)
    if not st.ep then return end
    local id = ev.unit
    note_citizens(K)
    if mem.cit_ever[id] then st.ep.lost, dirty = st.ep.lost + 1, true
    elseif mem.hseen[id] then st.ep.killed, dirty = st.ep.killed + 1, true end
    save(K)
  end,
}

return M
