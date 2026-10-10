-- gate (WP5): drawbridges with the single-pending-pull invariant (DESIGN §4, CONTRACTS §7).
-- A pull is queued only if (1) the wanted state differs from gate_flags.raised (lever.lua:39-41),
-- (2) the bridge is not raising/lowering, (3) NO PullLever job is pending on any
-- lever of that bridge, and (4) no citizen stands on the footprint. Raising waits <= 300 ticks
-- (only in SIEGE/BREACH do we pull after that); lowering crushes whatever is on the footprint, so
-- it waits as long as it takes and our pending lowering pull is cancelled when a citizen steps on.
-- Our own job without a worker for 200 ticks is cancelled (act.cancel_own_lever_job, the UI
-- cancel) and the next pull goes to the backup lever.
-- Pulls go through act.pull -> reqscript('lever').leverPullJob (lever.lua:4, never deduplicates).
local geom = require('dfllm.util.geom')

local M = {name = 'gate', every = {ticks = 600}, critical = true, verbs = {}}

M.FAST, M.SLOW = 25, 600   -- cadence: FAST in SIEGE/BREACH/DRILL or while a bridge has work
M.NO_WORKER = 200          -- ticks our queued pull may wait without a worker
M.BLOCK_WAIT = 300         -- ticks to wait for citizens to leave the footprint before a forced raise
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

local function new_kpi(t0) return {dbl = 0, t0 = t0, raise = {}, pulls = 0, cancels = 0, fails = {}} end

local function flush(K)
  if dirty then K.persist.set('m.gate', st); dirty = false end
end

local function runtime(name)
  local r = rt[name]
  if not r then
    r = {levers = {}, linked = {}, bad = {}, nw = 0}
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
  r.levers, r.linked = {}, {}
  local function add(lv, t)
    if #r.levers >= 4 or r.linked[lv.id] ~= nil then return end
    r.levers[#r.levers + 1] = lv.id
    r.linked[lv.id] = (t == nil) or (r.bid ~= nil and t[r.bid] == true)  -- unreadable link: usable
  end
  for _, p in ipairs(spec.levers or {}) do
    local lv = find_at(p)
    if lv and is_lever(lv) then add(lv, targets(lv)) end
  end
  -- stale manifest positions: levers linked to this bridge (one vector scan per RESOLVE_RETRY at most)
  if r.bid and not any_linked(r) and now - (r.scan_tick or -M.RESOLVE_RETRY) >= M.RESOLVE_RETRY then
    r.scan_tick = now
    for _, lv in ipairs(df.global.world.buildings.other.TRAP) do      -- lever.lua:103
      if is_lever(lv) then
        local t = targets(lv)
        if t and t[r.bid] then add(lv, t) end
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

-- linked lever to pull next: first one that has not failed in this epoch, rotating after failures;
-- the link is re-checked right before the pull (a lever may have been unlinked or removed)
local function pick(r)
  local cand = {}
  for _, lid in ipairs(r.levers) do if r.linked[lid] then cand[#cand + 1] = lid end end
  local n = #cand
  if n == 0 then return nil end
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
      if s == r.job.before then r.bad[r.job.lever] = true end
      r.job, r.settle = nil, now + M.SETTLE
    else
      local dir = r.job.before == 'up' and 'down' or 'up'
      -- stale: the want changed, lowering became unsafe, or the bridge moved without us (our
      -- pull would now toggle it back)
      local stale = (w ~= nil and w ~= dir) or (dir == 'down' and down_guard(K, name) ~= nil)
                    or s ~= r.job.before
      -- a citizen stepped onto the footprint before our lowering pull was done: cancel it
      if not stale and dir == 'down' and citizens_on(K, name, spec.fp) ~= 0 then stale = 'blocked' end
      local has_worker = worker(j) ~= nil
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
  if on > 0 or (w == 'down' and on < 0) then
    r.block_since = r.block_since or now
    if not r.block_ev then
      r.block_ev = true
      K.emit('GATE', 'C', name .. ' ' .. w .. ' waits: citizen on the footprint', {bridge = name, state = 'blocked'})
    end
    if not (w == 'up' and FORCE_MODES[K.mode()] and now - r.block_since >= M.BLOCK_WAIT) then
      r.stuck = 'blocked'
      return s
    end
    K.log('warn', 'gate: raising %s with a citizen on it after %d ticks', name, now - r.block_since)
  end
  r.block_since, r.block_ev = nil, nil
  local lid = pick(r)
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
      for _, f in ipairs({'dbl', 'pulls', 'cancels'}) do k[f] = int(p.kpi[f]) or 0 end
      for n, v in pairs(type(p.kpi.raise) == 'table' and p.kpi.raise or {}) do k.raise[n] = int(v) end
      for _, f in ipairs(type(p.kpi.fails) == 'table' and p.kpi.fails or {}) do k.fails[#k.fails + 1] = f end
      st.kpi = k
    end
  end
  rt, pub, dirty, PULL = {}, nil, false, nil
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
  for _, name in ipairs(bridge_names(man)) do
    ensure_default(K, name, now)
    states[name] = control(K, name, man.bridges[name], now)
    check_fail(K, name, now)
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
  local raise, fails = {}, {}
  for n, v in pairs(st.kpi.raise) do raise[n] = v end
  for i, f in ipairs(st.kpi.fails) do fails[i] = f end
  return {double_toggles = st.kpi.dbl, last_raise_ticks = raise, pulls = st.kpi.pulls,
          cancels = st.kpi.cancels, fails = fails, since = st.kpi.t0}
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
