-- drill (WP6): the siege drill (DESIGN §3 DRILL, §4, §5.4). A drill is SIEGE without enemies: mode
-- DRILL makes siege sound the civ alert (Kern+), send the squads to READY_STATION and raise the
-- outer and inner bridges with real lever pulls (gate's single-pending invariant). At T+1,200 the
-- drill records its KPIs, then PEACE lowers the bridges again with the same invariant.
-- Pass: every outer/inner bridge up by T+900, worn >= 90 %, nobody outside Kern+ at T+1,200,
-- 0 double toggles. Results go to persist `drill` (≤5), DRILL_RESULT (B) and, on exactly the 2nd
-- consecutive failure, DRILL_FAIL (A, CONTRACTS §12); readiness reads them (R2).
-- Starts: inbox `drill`, drill.start(why), or automatically in PEACE without merchants: yearly,
-- every season while the plan wants R2 growth, after a siege, and after a failed drill: a month,
-- doubling per further failure up to a season, and never while the failure is structural (no Kern+,
-- or too few uniform specs to reach 90 %) until that input changes.
local M = {name = 'drill', every = {ticks = 600}, verbs = {}, on = {}}

M.MEASURE = 1200         -- KPIs at T+1,200
M.RAISE_MAX = 900        -- bridges up by T+900
M.WORN_MIN = 90
M.FAST, M.SLOW = 25, 600
M.YEARLY = 403200
M.KEEP_R2 = 94800        -- re-drill before the 100,800-tick validity of a pass runs out (R2)
M.RETRY_FAIL = 33600     -- a month after the first failed drill, x2 per further failure
M.RETRY_CAP = 100800     -- at most a season between retries
M.RETRY_ABORT = 6000     -- 5 days after a drill a real threat interrupted
M.SETTLE = 2400          -- no automatic drill in the first 2 days after a load
M.AUTO_PHASE = 5         -- automatic drills from phase P5 (drill 1); always if no phase is known
M.KEEP = 5
local R1_CAP = 55

local st      -- persisted m.drill: {v, t0, why, try, siege}
local rec     -- persisted `drill`: {v, streak_fail, last = [...]}
local rt      -- runtime: boot tick, ending flag

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

-- merchants on the map: trade state, else a caravan approaching/at the depot/leaving (caravan.lua:99)
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

---------------------------------------------------------------- start / measure / end
-- public (CONTRACTS §7): PEACE only, no merchants on the map, one drill at a time
function M.start(K, why)
  if st.t0 then return false, 'a drill is running' end
  if K.mode() ~= 'PEACE' then return false, 'drill only in PEACE (now ' .. K.mode() .. ')' end
  if M.merchants(K) then return false, 'merchants on the map' end
  local now = K.now().tick
  K.call('gate', 'reset_kpi')                     -- raise ticks and double toggles count from T0
  st.t0, st.why, st.try = now, cut(why or 'drill', 40), now
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
  if outside < 0 then fails[#fails + 1] = 'no_kern'
  elseif outside > 0 then fails[#fails + 1] = 'outside:' .. outside end
  local dbl = int(kpi.double_toggles) or 0
  if dbl > 0 then fails[#fails + 1] = 'dbl:' .. dbl end
  return {tick = now, pass = #fails == 0 and 1 or 0, raised = raised, worn = math.max(0, math.min(100, worn)),
          outside = math.max(0, outside), dbl = dbl, fails = fails}
end

local function finish(K, now)
  local r = measure(K, now)
  local last = rec.last
  last[#last + 1] = r
  while #last > M.KEEP do table.remove(last, 1) end
  rec.streak_fail = r.pass == 1 and 0 or rec.streak_fail + 1
  K.persist.set('drill', rec)
  local fl = table.concat(r.fails, ', ')
  K.emit('DRILL_RESULT', 'B', string.format('drill %s: raised %d, worn %d%%, outside %d, dbl %d%s',
         r.pass == 1 and 'passed' or 'failed', r.raised, r.worn, r.outside, r.dbl, fl ~= '' and (' (' .. fl .. ')') or ''),
         {pass = r.pass, raised = r.raised, worn = r.worn, outside = r.outside, dbl = r.dbl})
  if r.pass == 0 and rec.streak_fail == 2 then
    K.emit('DRILL_FAIL', 'A', string.format('drill failed %d times in a row: %s', rec.streak_fail, fl),
           {streak = rec.streak_fail, fails = r.fails})
  end
  st.t0 = nil
  save(K)
  rt.ending = true
  K.set_mode('PEACE', 'drill done')               -- gate lowers the bridges, siege ends the alert
  rt.ending = false
  M.every = {ticks = M.SLOW}
  return r
end

local function abort(K, why)
  K.log('info', 'drill: aborted (%s)', why)
  st.t0, st.try = nil, K.now().tick
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

-- why an automatic drill is due now, or nil
function M.due(K, now)
  if K.mode() ~= 'PEACE' or now - rt.boot < M.SETTLE then return nil end
  if st.try and now - st.try < M.RETRY_ABORT then return nil end
  if #gate_bridges(K.manifest()) == 0 then return nil end
  local ph = K.view().phase
  local pn = type(ph) == 'string' and tonumber(ph:match('^P(%d)$')) or nil
  if pn and pn < M.AUTO_PHASE then return nil end
  local okm, mk = K.call('military', 'kpi')
  if not okm or type(mk) ~= 'table' or (mk.soldiers or 0) == 0 then return nil end
  local newest = rec.last[#rec.last]
  if not newest then return 'first' end
  if newest.pass == 0 then
    rt.blocked = structural(K, mk)
    if rt.blocked or now - newest.tick < retry_wait() then return nil end
    return 'retry'
  end
  rt.blocked = nil
  local pass = last_pass() or newest.tick
  if st.siege and st.siege > pass then return 'after siege' end
  if wants_r2(K) and now - pass >= M.KEEP_R2 then return 'keep R2' end
  if now - pass >= M.YEARLY then return 'yearly' end
  return nil
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
    if now - st.t0 >= M.MEASURE then finish(K, now) end
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
