-- drill (WP6): the siege drill (DESIGN §3 DRILL, §4, §5.4). A drill is SIEGE without enemies: mode
-- DRILL makes siege sound the civ alert (Kern+), send the squads to READY_STATION and raise the
-- outer and inner bridges with real lever pulls (gate's single-pending invariant). At T+1,200 the
-- drill records its KPIs, then PEACE lowers the bridges again with the same invariant.
-- Pass: every outer/inner bridge up by T+900, worn >= 90 %, nobody outside Kern+ at T+1,200, 0 double toggles
-- (DESIGN §11 R2, §14). Results go to persist `drill` (≤5), DRILL_RESULT (B) and, on exactly the 2nd
-- consecutive failure, DRILL_FAIL (A, CONTRACTS §12); readiness reads them (R2).
-- Outside (live L2/L3: 4, 2 and 3 citizens, bucket carriers from the brook 90 tiles away and surface workers):
-- DRILL_RESULT also reports how many of them were `walking` home (closer to the entry than at T+1,100 or T0, or
-- waiting at a raised outer/inner bridge), a diagnostic only: every one of them still counts, because in a real
-- siege a citizen locked out by O1 at T+450, or a bucket carrier on its way back from the brook, stands outside
-- with the attackers (and R2 raises the pop cap on a passed drill). DRILL_RESULT also carries the outer
-- bridge's raise time (goal T+600), the lever-job take time and the lever pullers (gate.kpi).
-- Starts: inbox `drill`, drill.start(why), or automatically in PEACE: yearly,
-- every season while the plan wants R2 growth, after a siege, and after a failed drill: a month,
-- doubling per further failure up to a season, and never while the failure is structural (no Kern+,
-- or too few uniform specs to reach 90 %) until that input changes. Automatic drills also need an
-- outer/inner bridge in the manifest, soldiers, a barracks and 2 days since the load;
-- drill.hold() names the missing one (FR-65: state ready.dhold, `status`: `drill never (auto: no bridges)`).
-- BUG-051 (Run 13 Wheelsblows: the drill never ran, 'phase P0<P5' and 'merchants on the map'; note 2: traders stay
-- for weeks): a drill is refused only for danger (military.danger: a mode other than PEACE, a lockdown, a hostile in
-- sight) and, for the length of one trade session, while the broker is at the trade screen (trade.clock: the civ alert
-- would call him home); merchants standing on the map and the runner's phase hold nothing. The phase gate P5 stood for
-- 'stage 3 is built'; what a drill needs is what it uses: bridges to raise, squads to measure (soldiers) and the
-- barracks they stand in (military.barracks).
local geom = require('dfllm.util.geom')

local M = {name = 'drill', every = {ticks = 600}, verbs = {}, on = {}}

M.MEASURE = 1200         -- KPIs at T+1,200
M.HOME_WINDOW = 100      -- outside citizens sampled at T+1,100: who got closer to the entry since then ...
M.HOME_STEP = 2          -- ... by at least 2 tiles is walking home (a dwarf walks about 10 tiles in 100 ticks)
M.HOME_PROGRESS = 10     -- ... as is one 10 tiles closer than at T0 (headed home, stopped where the raised gate
                         -- cut the path)
M.GATE_NEAR = 3          -- within 3 tiles of a raised outer/inner bridge = waiting at the gate the doctrine closed
M.OUTER_GOAL = 600       -- outer bridge up by T+600 (live L3 goal with lever pullers; pass rule stays T+900)
M.RAISE_MAX = 900        -- bridges up by T+900
M.WORN_MIN = 90
M.FAST, M.SLOW = 25, 600
M.YEARLY = 403200
M.KEEP_R2 = 94800        -- re-drill before the 100,800-tick validity of a pass runs out (R2)
M.RETRY_FAIL = 33600     -- a month after the first failed drill, x2 per further failure
M.RETRY_CAP = 100800     -- at most a season between retries
M.RETRY_ABORT = 6000     -- 5 days after a drill a real threat interrupted
M.SETTLE = 2400          -- no automatic drill in the first 2 days after a load
M.KEEP = 5
local R1_CAP = 55

local st      -- persisted m.drill: {v, t0, why, try, siege}
local rec     -- persisted `drill`: {v, streak_fail, last = [...]}
local rt      -- runtime: boot tick, ending flag, home0/home (outside citizens' entry distance at T0 / T+1,100)

local function int(v) return type(v) == 'number' and math.tointeger(v) or nil end
local function cut(s, n) s = tostring(s or ''); return #s > n and s:sub(1, n) or s end
local function try(f) local ok, r = pcall(f); if ok then return r end end
local function save(K) K.persist.set('m.drill', st) end

local function sorted_keys(t)
  local r = {}
  for k in pairs(type(t) == 'table' and t or {}) do r[#r + 1] = k end
  table.sort(r)
  return r
end

local function gate_bridges(man)
  local r = {}
  for _, name in ipairs(sorted_keys(man.bridges)) do
    local b = man.bridges[name]
    if type(b) == 'table' and type(b.fp) == 'table' and (b.role == 'outer' or b.role == 'inner') then r[#r + 1] = name end
  end
  return r
end

-- merchants on the map: trade state, else a caravan approaching/at the depot/leaving (caravan.lua:99). BUG-051: no
-- longer a reason to refuse a drill (kept for status and tests)
function M.merchants(K)
  local tr = K.view().trade
  if type(tr) == 'table' and tr.caravan == 1 then return true end
  return try(function()
    local S = df.caravan_state.T_trade_state
    for _, c in ipairs(df.global.plotinfo.caravans) do
      local s = c.trade_state
      if s == S.Approaching or s == S.AtDepot or s == S.Leaving then return true end
    end
    return false
  end) == true
end

local function last_pass()
  local t
  for _, e in ipairs(rec.last) do if e.pass == 1 and (not t or e.tick > t) then t = e.tick end end
  return t
end

---------------------------------------------------------------- walking home (live L3)
-- the point citizens walk to: the inner bridge's footprint centre (the way into Kern+), else the outer one
local function entry(man)
  local b
  for _, name in ipairs(gate_bridges(man)) do
    local x = man.bridges[name]
    if x.role == 'inner' then b = x; break end
    b = b or x
  end
  if b then return {x = (b.fp[1] + b.fp[4]) // 2, y = (b.fp[2] + b.fp[5]) // 2, z = b.fp[3]} end
end

local function pos_of(id)
  local u = df.unit.find(id)
  if not u then return nil end
  local ok, x, y, z = pcall(dfhack.units.getPosition, u)
  if ok and x then return {x = x, y = y, z = z} end
end

local function bbox_dist(p, b)
  return math.max(b[1] - p.x, p.x - b[4], b[2] - p.y, p.y - b[5], b[3] - p.z, p.z - b[6], 0)
end

-- distance to the entry of every listed outside citizen (census.u.outside_ids, at most 20)
local function home_sample(K)
  local cu, e, r = K.census.u, entry(K.manifest()), {}
  if not e or type(cu) ~= 'table' then return r end
  for _, id in ipairs(type(cu.outside_ids) == 'table' and cu.outside_ids or {}) do
    local p = pos_of(id)
    if p then r[id] = geom.dist(p, e) end
  end
  return r
end

-- outside citizens who are walking home now: 2 tiles closer to the entry than at T+1,100, 10 tiles closer than at
-- T0, or waiting within 3 tiles of a raised outer/inner bridge. A citizen beyond the listed 20 counts as not walking.
local function walking_home(K, cu)
  local man = K.manifest()
  local e = entry(man)
  if not e then return 0 end
  local gates = {}
  for _, name in ipairs(gate_bridges(man)) do
    local ok, s = K.call('gate', 'state', name)
    if ok and s == 'up' then gates[#gates + 1] = man.bridges[name].fp end
  end
  local n = 0
  for _, id in ipairs(type(cu.outside_ids) == 'table' and cu.outside_ids or {}) do
    local p = pos_of(id)
    if p then
      local d, d0, d1 = geom.dist(p, e), rt.home0 and rt.home0[id], rt.home and rt.home[id]
      local walking = (d1 ~= nil and d <= d1 - M.HOME_STEP) or (d0 ~= nil and d <= d0 - M.HOME_PROGRESS)
      for _, fp in ipairs(gates) do
        if bbox_dist(p, fp) <= M.GATE_NEAR then walking = true end
      end
      if walking then n = n + 1 end
    end
  end
  return n
end

-- BUG-051: why no drill now because of danger (military.danger: 'mode ALERT', 'lockdown', 'hostile'), else nil; without a
-- military module only the mode counts
local function danger(K)
  local ok, why = K.call('military', 'danger')
  if ok then return why end
  return K.mode() ~= 'PEACE' and ('mode ' .. K.mode()) or nil
end

-- BUG-051: the broker is at the trade screen (trade.clock): the drill waits for the end of that session
function M.trading(K)
  local ok, why = K.call('trade', 'clock')
  return ok and why == 'trade'
end

---------------------------------------------------------------- start / measure / end
-- public (CONTRACTS §7): PEACE only, no danger, no trade session under way, one drill at a time
function M.start(K, why)
  if st.t0 then return false, 'a drill is running' end
  local d = danger(K)
  if d then
    if d:sub(1, 5) == 'mode ' then return false, 'drill only in PEACE (now ' .. K.mode() .. ')' end
    return false, 'drill refused: ' .. (d == 'lockdown' and 'a lockdown holds' or 'a hostile is in sight')
  end
  if M.trading(K) then return false, 'a trade session is under way (the broker would be called home)' end
  local now = K.now().tick
  K.call('gate', 'reset_kpi')                     -- raise ticks and double toggles count from T0
  st.t0, st.why, st.try, rt.home = now, cut(why or 'drill', 40), now, nil
  rt.home0 = home_sample(K)                       -- who is outside at T0, and how far from the entry
  save(K)
  local ok, err = K.set_mode('DRILL', 'drill: ' .. st.why)
  if not ok then
    st.t0 = nil
    save(K)
    return false, 'mode: ' .. tostring(err)
  end
  M.every = {ticks = M.FAST}
  return true, 'drill started (' .. st.why .. ')'
end
M.run = M.start                                   -- DESIGN §12 name

local function measure(K, now)
  local fails = {}
  local okg, kpi = K.call('gate', 'kpi')
  kpi = okg and type(kpi) == 'table' and kpi or {}
  local raise = type(kpi.last_raise_ticks) == 'table' and kpi.last_raise_ticks or {}
  local names = gate_bridges(K.manifest())
  local raised = 0
  if #names == 0 then fails[#fails + 1], raised = 'no_bridges', -1 end
  for _, name in ipairs(names) do
    local ok, s = K.call('gate', 'state', name)
    if ok and s == 'up' then
      local t = int(raise[name]) or 0             -- no raise recorded: it was up before T0
      if raised >= 0 then raised = math.max(raised, t) end
      if t > M.RAISE_MAX then fails[#fails + 1] = 'slow:' .. name end
    else
      raised = -1
      fails[#fails + 1] = 'up:' .. name
    end
  end
  local okm, mk = K.call('military', 'kpi')
  mk = okm and type(mk) == 'table' and mk or nil
  local worn = mk and int(mk.worn) or 0
  if not mk then fails[#fails + 1] = 'military?'
  elseif (mk.soldiers or 0) == 0 then fails[#fails + 1] = 'no_soldiers' end
  if worn < M.WORN_MIN then fails[#fails + 1] = 'worn<' .. M.WORN_MIN end
  local cu = K.census.u
  local outside = type(cu) == 'table' and int(cu.outside) or -1
  local walking = outside > 0 and walking_home(K, cu) or 0      -- reported only (see the header)
  if outside < 0 then fails[#fails + 1] = 'no_kern'
  elseif outside > 0 then fails[#fails + 1] = 'outside:' .. outside end
  local dbl = int(kpi.double_toggles) or 0
  if dbl > 0 then fails[#fails + 1] = 'dbl:' .. dbl end
  -- reported only: the outer bridge's raise time (-1 not up), the slowest lever-job take, pullers assigned
  local man, outer, take, pullers = K.manifest(), nil, -1, 0
  local takes = type(kpi.take_ticks) == 'table' and kpi.take_ticks or {}
  for _, name in ipairs(names) do
    if man.bridges[name].role == 'outer' then
      local ok, s = K.call('gate', 'state', name)
      local t = (ok and s == 'up') and (int(raise[name]) or 0) or -1    -- no raise recorded: up before T0
      if outer == nil then outer = t
      elseif outer >= 0 then outer = t < 0 and -1 or math.max(outer, t) end
    end
    local tk = int(takes[name])
    if tk and tk > take then take = tk end
  end
  for _, n in pairs(type(kpi.pullers) == 'table' and kpi.pullers or {}) do pullers = pullers + (int(n) or 0) end
  return {tick = now, pass = #fails == 0 and 1 or 0, raised = raised, worn = math.max(0, math.min(100, worn)),
          outside = math.max(0, outside), dbl = dbl, fails = fails,
          extra = {walking = walking, outer = outer or -1, take = take, pullers = pullers}}
end

local function finish(K, now)
  local r = measure(K, now)
  local x = r.extra
  r.extra = nil                                   -- persist `drill` keeps the CONTRACTS §10 fields only
  local last = rec.last
  last[#last + 1] = r
  while #last > M.KEEP do table.remove(last, 1) end
  rec.streak_fail = r.pass == 1 and 0 or rec.streak_fail + 1
  K.persist.set('drill', rec)
  local fl = table.concat(r.fails, ', ')
  K.emit('DRILL_RESULT', 'B', string.format('drill %s: raised %d, outer %d (goal %d), worn %d%%, outside %d (%d walking home), dbl %d%s',
         r.pass == 1 and 'passed' or 'failed', r.raised, x.outer, M.OUTER_GOAL, r.worn, r.outside, x.walking, r.dbl,
         fl ~= '' and (' (' .. fl .. ')') or ''),
         {pass = r.pass, raised = r.raised, worn = r.worn, outside = r.outside, dbl = r.dbl,
          walking = x.walking, outer = x.outer, take = x.take, pullers = x.pullers})
  if r.pass == 0 and rec.streak_fail == 2 then
    K.emit('DRILL_FAIL', 'A', string.format('drill failed %d times in a row: %s', rec.streak_fail, fl),
           {streak = rec.streak_fail, fails = r.fails})
  end
  st.t0, rt.home, rt.home0 = nil, nil, nil
  save(K)
  rt.ending = true
  K.set_mode('PEACE', 'drill done')               -- gate lowers the bridges, siege ends the alert
  rt.ending = false
  M.every = {ticks = M.SLOW}
  return r
end

local function abort(K, why)
  K.log('info', 'drill: aborted (%s)', why)
  st.t0, st.try, rt.home, rt.home0 = nil, K.now().tick, nil, nil
  save(K)
  M.every = {ticks = M.SLOW}
end

---------------------------------------------------------------- automatic drills
local function wants_r2(K)
  local pol = type(K.plan) == 'table' and K.plan.policy
  local ceil = type(pol) == 'table' and int(pol.pop_ceiling) or R1_CAP
  if ceil <= R1_CAP then return false end
  local ok, lvl = K.call('readiness', 'level')
  return ok and type(lvl) == 'number' and lvl >= 1
end

-- a failure the next drill would repeat for sure: no Kern+ burrow (census.u.outside -1), or so few
-- uniform specs that 90 % worn is out of reach (military.kpi specs/slots). No soldiers, no bridges or
-- no military module stop automatic drills altogether (see due).
local function structural(K, mk)
  local cu = K.census.u
  if type(cu) ~= 'table' or (int(cu.outside) or -1) < 0 then return 'no_kern' end
  local slots, specs = int(mk.slots) or 0, int(mk.specs) or 0
  if slots > 0 and specs * 100 < M.WORN_MIN * slots then return 'no_uniform' end
  return nil
end

-- ticks to wait after the newest failure: a month, doubled per further failure, at most a season
local function retry_wait()
  local w = M.RETRY_FAIL
  for _ = 2, rec.streak_fail do
    w = w * 2
    if w >= M.RETRY_CAP then return M.RETRY_CAP end
  end
  return w
end

-- why an automatic drill is due now (1st value), else why it is held (2nd value, <= 24 chars; FR-65 status)
local function check(K, now)
  if st.t0 then return nil, 'running' end
  local d = danger(K)
  if d then return nil, d end
  if now - rt.boot < M.SETTLE then return nil, 'settling' end
  if st.try and now - st.try < M.RETRY_ABORT then          -- 5 days after the last start (finished or aborted)
    local newest = rec.last[#rec.last]
    return nil, (newest and newest.tick >= st.try) and 'just drilled' or 'aborted'
  end
  if #gate_bridges(K.manifest()) == 0 then return nil, 'no bridges' end
  local okm, mk = K.call('military', 'kpi')
  if not okm or type(mk) ~= 'table' then return nil, 'military?' end
  if (mk.soldiers or 0) == 0 then return nil, 'no soldiers' end
  local okb, bk = K.call('military', 'barracks')
  if okb and bk == false then return nil, 'no barracks' end
  local newest = rec.last[#rec.last]
  if not newest then return 'first' end
  if newest.pass == 0 then
    rt.blocked = structural(K, mk)
    if rt.blocked then return nil, 'blocked:' .. rt.blocked end
    if now - newest.tick < retry_wait() then return nil, 'retry wait' end
    return 'retry'
  end
  rt.blocked = nil
  local pass = last_pass() or newest.tick
  if st.siege and st.siege > pass then return 'after siege' end
  if wants_r2(K) and now - pass >= M.KEEP_R2 then return 'keep R2' end
  if now - pass >= M.YEARLY then return 'yearly' end
  return nil, 'passed'
end

-- why an automatic drill is due now, or nil
function M.due(K, now) return (check(K, now)) end

-- public (FR-65, readiness -> state ready.dhold): why no automatic drill starts now ('no bridges', 'no barracks',
-- 'no soldiers', 'mode ALERT', 'lockdown', 'hostile', 'blocked:no_kern', 'retry wait', 'passed', 'trading', ...); nil = one is due
function M.hold(K)
  local why, held = check(K, K.now().tick)
  if why and M.trading(K) then return 'trading' end
  return held
end

---------------------------------------------------------------- module
function M.init(K)
  local p = K.persist.get('m.drill')
  p = type(p) == 'table' and p or {}
  st = {v = 2, t0 = int(p.t0), why = p.why, try = int(p.try), siege = int(p.siege)}
  local d = K.persist.get('drill')
  rec = {v = 2, streak_fail = 0, last = {}}
  if type(d) == 'table' then
    rec.streak_fail = int(d.streak_fail) or 0
    for _, e in ipairs(type(d.last) == 'table' and d.last or {}) do
      if type(e) == 'table' and int(e.tick) then
        local fails = {}
        for i, f in ipairs(type(e.fails) == 'table' and e.fails or {}) do fails[i] = cut(f, 40) end
        rec.last[#rec.last + 1] = {tick = e.tick, pass = e.pass == 1 and 1 or 0, raised = int(e.raised) or -1,
                                   worn = int(e.worn) or 0, outside = int(e.outside) or 0, dbl = int(e.dbl) or 0,
                                   fails = fails}
      end
    end
  end
  rt = {boot = K.now().tick, ending = false}
  M.every = {ticks = st.t0 and M.FAST or M.SLOW}
end

function M.step(K, budget, ctx)
  local now = K.now().tick
  local mode = K.mode()
  if st.t0 then
    if mode ~= 'DRILL' then abort(K, 'mode ' .. mode); return end
    if now - st.t0 >= M.MEASURE then finish(K, now)
    elseif not rt.home and now - st.t0 >= M.MEASURE - M.HOME_WINDOW then rt.home = home_sample(K) end
    return
  end
  if mode == 'DRILL' then                         -- a drill without its record (lost persist): end it
    K.set_mode('PEACE', 'drill record lost')
    return
  end
  local why = M.due(K, now)
  if why then M.start(K, 'auto: ' .. why) end
end

-- results for tests and inspect: streak, the last results (copies) and why a retry is held back
function M.results(K)
  local r = {}
  for i, e in ipairs(rec.last) do r[i] = e end
  return {streak_fail = rec.streak_fail, last = r, blocked = rt.blocked}
end

M.on.MODE = function(K, ev)
  if (ev.to == 'SIEGE' or ev.to == 'BREACH') then st.siege = ev.tick or K.now().tick; save(K) end
  if st.t0 and ev.from == 'DRILL' and not rt.ending then abort(K, ev.from .. '>' .. ev.to) end
end

-- inbox `drill` (PEACE only, checked by kern)
M.verbs.drill = function(K, args, cmd)
  local why = type(args.why) == 'string' and args.why ~= '' and args.why or ('inbox:' .. tostring(cmd and cmd.by or '?'))
  return M.start(K, why)
end

return M
