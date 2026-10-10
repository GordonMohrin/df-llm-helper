-- readiness (WP6): levels R0-R3 (DESIGN §5.4) and the ONLY max-pop writer (act.popcap ->
-- `pop-control set max-pop N`, pop-control.lua:52-63). Growth is earned:
--   R0  cap 55
--   R1  "sealed": worst-case audit passes (inbox `audit` from bp.topo.audit), Kern+ and Tiefe+ exist,
--       an outer and an inner bridge exist and every manifest bridge has 2 linked levers
--   R2  R1 + a drill passed <= 100,800 ticks ago (and after the last siege), soldiers >= D-12 share
--       of adults and >= 8, combat value per soldier >= plan.military.cv_min, >= 30 armed traps on
--       every attacker path (audit.min_traps), food >= 60 and drink >= 170 days (plan.supply)
--   R3  R2 + D-01 = B + >= 20 % of soldiers in iron or steel body armor
-- Cap = min(level cap, plan.policy.pop_ceiling, inbox popcap.lower). A demotion freezes max-pop at
-- the current population; outside PEACE max-pop never rises. Audits are requested monthly and
-- after defense stages through snapshot.export (WP7); the result comes back as the `audit` verb.
local geom = require('dfllm.util.geom')

local M = {name = 'readiness', every = {ticks = 1200}, verbs = {}, on = {}}

M.CAPS = {[0] = 55, [1] = 55, [2] = 75, [3] = 250}
M.SIEGE_TRIGGER = 80     -- difficulty "enemy population trigger" [S10: read it]; R2 ceiling = trigger - 5
M.DRILL_VALID = 100800   -- a passed drill counts for one season
M.AUDIT_VALID = 100800   -- an audit counts for one season
M.AUDIT_EVERY = 33600    -- re-audit monthly
M.AUDIT_GAP = 1200       -- at most one audit request per day
M.LEVERS_EVERY = 33600
M.MIN_LEVERS, M.TRAPS, M.METAL, M.R2_SOLDIERS = 2, 30, 20, 8
M.STOCK_HYST = 90        -- % of a stock minimum that keeps R2 once reached (no flapping)
M.PAD = {8, 8, 1}        -- audit bbox margin around the manifest geometry
local QUIET_MODES = {PEACE = true, ALERT = true, RECOVERY = true}   -- audit snapshots allowed

local st      -- persisted m.readiness
local rt      -- runtime: lever check, published values
local dirty

local function int(v) return type(v) == 'number' and math.tointeger(v) or nil end
local function save(K) if dirty then K.persist.set('m.readiness', st); dirty = false end end
local function try(f, ...) local ok, r = pcall(f, ...); if ok then return r end end
local function cut(s, n) s = tostring(s or ''); return #s > n and s:sub(1, n) or s end

local function sorted_keys(t)
  local r = {}
  for k in pairs(type(t) == 'table' and t or {}) do r[#r + 1] = k end
  table.sort(r)
  return r
end

---------------------------------------------------------------- inputs
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

local function plan_loaded(K)
  local p = K.persist.get('plan')
  return type(p) == 'table' and int(p.loaded) or -1
end

-- the newest passed drill and the newest drill of any result (persist `drill`, written by drill)
local function drills(K)
  local d = K.persist.get('drill')
  local pass, last
  for _, e in ipairs(type(d) == 'table' and type(d.last) == 'table' and d.last or {}) do
    if type(e) == 'table' and int(e.tick) then
      if not last or e.tick >= last.tick then last = e end
      if e.pass == 1 and (not pass or e.tick >= pass.tick) then pass = e end
    end
  end
  return pass, last
end

-- army share (%) from D-12 '<low>/<high>' (low below pop 60) and plan.military.pct
local function share(K, cit)
  local lo, hi = tostring((K.cfg.decisions or {})['D-12'] or '15/20'):match('^(%d+)/(%d+)$')
  local p = (cit or 0) >= 60 and (tonumber(hi) or 20) or (tonumber(lo) or 15)
  local mil = type(K.plan) == 'table' and K.plan.military
  local pp = type(mil) == 'table' and int(mil.pct)
  if pp and pp > p then p = pp end
  return math.tointeger(p) or 15
end

local function plan_num(K, sect, key, default)
  local s = type(K.plan) == 'table' and K.plan[sect]
  return type(s) == 'table' and int(s[key]) or default
end

-- a manifest lever is a lever building linked to the bridge on fp (gate.lua:77-87, lever.lua:24-27)
local function lever_ok(p, fp)
  return try(function()
    local b = dfhack.buildings.findAtTile(p[1], p[2], p[3])          -- Lua API.txt:2484
    if not b or b.trap_type ~= df.trap_type.Lever or #b.linked_mechanisms == 0 then return false end
    local c = geom.bbox_center(fp)
    for _, m in ipairs(b.linked_mechanisms) do
      local ref = dfhack.items.getGeneralRef(m, df.general_ref_type.BUILDING_HOLDER)
      local t = ref and ref:getBuilding()
      if not t then return true end                                   -- unreadable target: trust the link
      if t.z == c.z and c.x >= t.x1 and c.x <= t.x2 and c.y >= t.y1 and c.y <= t.y2 then return true end
    end
    return false
  end) == true
end

-- bridges and levers: outer + inner exist, every bridge known to gate, >= 2 linked levers each
local function check_levers(K, man)
  local fails, roles = {}, {}
  for _, name in ipairs(sorted_keys(man.bridges)) do
    local b = man.bridges[name]
    if type(b) == 'table' and type(b.fp) == 'table' and #b.fp == 6 then
      roles[b.role or '?'] = true
      local ok, s = K.call('gate', 'state', name)
      if not ok or s == 'unknown' then fails[#fails + 1] = 'bridge:' .. name end
      local n = 0
      for _, p in ipairs(type(b.levers) == 'table' and b.levers or {}) do
        if type(p) == 'table' and lever_ok(p, b.fp) then n = n + 1 end
      end
      if n < M.MIN_LEVERS then fails[#fails + 1] = 'levers:' .. name end
    end
  end
  if not roles.outer then table.insert(fails, 1, 'no_outer') end
  if not roles.inner then table.insert(fails, 1, 'no_inner') end
  return {tick = K.now().tick, fails = fails}
end

---------------------------------------------------------------- audit requests
local function grow(bb, p)
  if type(p) ~= 'table' or #p < 3 then return bb end
  local x0, y0, z0 = p[1], p[2], p[3]
  local x1, y1, z1 = p[4] or x0, p[5] or y0, p[6] or z0
  if not bb then return {x0, y0, z0, x1, y1, z1} end
  return {math.min(bb[1], x0), math.min(bb[2], y0), math.min(bb[3], z0),
          math.max(bb[4], x1), math.max(bb[5], y1), math.max(bb[6], z1)}
end

-- union of the manifest geometry plus a margin (nil: let snapshot choose)
function M.audit_bbox(man)
  local bb
  for _, b in pairs(type(man.bridges) == 'table' and man.bridges or {}) do
    bb = grow(bb, b.fp)
    for _, l in ipairs(type(b.levers) == 'table' and b.levers or {}) do bb = grow(bb, l) end
  end
  for _, list in pairs(type(man.zones) == 'table' and man.zones or {}) do
    for _, z in ipairs(list) do bb = grow(bb, z) end
  end
  for _, kb in ipairs(type(man.killboxes) == 'table' and man.killboxes or {}) do bb = grow(bb, kb.bbox) end
  for _, p in pairs(type(man.stations) == 'table' and man.stations or {}) do bb = grow(bb, p) end
  for _, p in ipairs(type(man.edge) == 'table' and man.edge or {}) do bb = grow(bb, p) end
  for _, kind in ipairs({'civ', 'mil'}) do
    for _, c in ipairs(type(man.stairs) == 'table' and type(man.stairs[kind]) == 'table' and man.stairs[kind] or {}) do
      bb = grow(bb, {c[1], c[2], c[3], c[1], c[2], c[4]})
    end
  end
  if type(man.refuge) == 'table' then bb = grow(bb, man.refuge.anchor) end
  bb = grow(grow(bb, man.pit), man.depot)
  if not bb then return nil end
  local P = M.PAD
  return {math.max(0, bb[1] - P[1]), math.max(0, bb[2] - P[2]), math.max(0, bb[3] - P[3]),
          bb[4] + P[1], bb[5] + P[2], bb[6] + P[3]}
end

local function request_audit(K, force)
  local now = K.now().tick
  if not QUIET_MODES[K.mode()] then st.audit_due, dirty = 1, true; return end
  if st.audit_req and now - st.audit_req < (force and M.AUDIT_GAP or M.AUDIT_EVERY) then
    if force then st.audit_due, dirty = 1, true end
    return
  end
  local man = K.manifest()
  local bbox = M.audit_bbox(man)
  if not bbox then return end                                 -- nothing built yet
  st.audit_req, st.audit_due, dirty = now, 0, true
  local ok, ok2, id = K.call('snapshot', 'export', {purpose = 'audit', bbox = bbox})
  if ok and ok2 then st.audit_snap = tostring(id)
  else K.log('warn', 'readiness: audit snapshot not exported: %s', tostring(ok and id or ok2)) end
end

---------------------------------------------------------------- levels
local function audit_fails(K, now)
  local a = st.audit
  if type(a) ~= 'table' then return {'audit'} end
  local f = {}
  if now - a.tick > M.AUDIT_VALID then f[#f + 1] = 'audit_old' end
  if a.ok ~= 1 then f[#f + 1] = 'audit_fail' end
  if a.bypass ~= 0 then f[#f + 1] = 'bypass' end
  if a.refuge_sep ~= 1 then f[#f + 1] = 'refuge_sep' end
  if a.civ_sep ~= 1 then f[#f + 1] = 'civ_sep' end
  if a.caverns ~= 1 then f[#f + 1] = 'caverns' end
  return f
end

local function evaluate(K, why)
  local now = K.now().tick
  local man = K.manifest()
  local cu = K.census.u
  local okm, kpi = K.call('military', 'kpi')
  kpi = okm and type(kpi) == 'table' and kpi or nil
  -- R1
  local f1 = audit_fails(K, now)
  rt.audit_ok = #f1 == 0 and 1 or 0
  local kern, refuge = burrow_names(man)
  if not dfhack.burrows.findByName(kern) then f1[#f1 + 1] = 'no_kern' end
  if not dfhack.burrows.findByName(refuge) then f1[#f1 + 1] = 'no_refuge' end
  if not rt.lev or now - rt.lev.tick >= M.LEVERS_EVERY then rt.lev = check_levers(K, man) end
  for _, f in ipairs(rt.lev.fails) do f1[#f1 + 1] = f end
  -- R2
  local f2 = {}
  local pass, last = drills(K)
  rt.pass_tick = pass and pass.tick or nil
  if not pass then f2[#f2 + 1] = 'drill'
  elseif now - pass.tick > M.DRILL_VALID then f2[#f2 + 1] = 'drill_old'
  elseif st.siege and pass.tick < st.siege then f2[#f2 + 1] = 'redrill' end
  local adults, cit = type(cu) == 'table' and cu.adults or 0, type(cu) == 'table' and cu.cit or 0
  local soldiers, cv = kpi and kpi.soldiers or 0, kpi and kpi.cv or 0
  local sh = share(K, cit)
  if not kpi then f2[#f2 + 1] = 'military?' end
  if soldiers * 100 < adults * sh then f2[#f2 + 1] = 'army<' .. sh .. '%' end
  if soldiers < M.R2_SOLDIERS then f2[#f2 + 1] = 'soldiers<' .. M.R2_SOLDIERS end
  local cv_min = plan_num(K, 'military', 'cv_min', 12)
  if cv < cv_min then f2[#f2 + 1] = 'cv<' .. cv_min end
  local traps = type(st.audit) == 'table' and st.audit.min_traps or 0
  if traps < M.TRAPS then f2[#f2 + 1] = 'traps<' .. M.TRAPS end
  local stock = K.view().stock
  local hyst = (st.lvl or 0) >= 2 and M.STOCK_HYST or 100
  for _, s in ipairs({{'food_d', 'food', 60}, {'drink_d', 'drink', 170}}) do
    local need = plan_num(K, 'supply', s[1], s[3])
    local have = type(stock) == 'table' and int(stock[s[1]])
    if not have then f2[#f2 + 1] = s[2] .. '?'
    elseif have * 100 < need * hyst then f2[#f2 + 1] = s[2] .. '<' .. need end
  end
  -- R3
  local f3 = {}
  if tostring((K.cfg.decisions or {})['D-01'] or 'A') ~= 'B' then f3[#f3 + 1] = 'option_a' end
  if (kpi and kpi.metal_pct or 0) < M.METAL then f3[#f3 + 1] = 'metal<' .. M.METAL .. '%' end
  local lvl, fail = 0, f1
  if #f1 == 0 then lvl, fail = 1, f2 end
  if lvl == 1 and #f2 == 0 then lvl, fail = 2, f3 end
  if lvl == 2 and #f3 == 0 then lvl, fail = 3, {} end
  local out = {}
  for i = 1, math.min(#fail, 8) do out[i] = cut(fail[i], 24) end
  rt.fail = out
  rt.cv = cv
  rt.worn = last and int(last.worn) or (kpi and kpi.worn) or 0   -- worn measured by the last drill
  if lvl ~= st.lvl then
    local from = st.lvl or 0
    st.lvl, dirty = lvl, true
    K.emit('READY_CHANGE', 'B', string.format('readiness R%d -> R%d (%s)', from, lvl, why or 'check'),
           {from = from, to = lvl, fail = out})
  end
  return lvl
end

---------------------------------------------------------------- pop cap
local function inbox_cap(K)
  local ib = st.inbox
  if type(ib) == 'table' and int(ib.cap) and ib.plan == plan_loaded(K) then return ib.cap end
  if ib then st.inbox, dirty = nil, true end                 -- a new plan supersedes an inbox lowering
  return nil
end

-- readiness ceiling for a level and the binding limit
function M.ceiling(K, lvl)
  local c, why = M.CAPS[lvl] or M.CAPS[0], 'R' .. lvl
  if lvl == 2 then c = math.min(c, M.SIEGE_TRIGGER - 5) end
  local pc = plan_num(K, 'policy', 'pop_ceiling', nil)
  if pc and pc < c then c, why = pc, 'plan' end
  local ib = inbox_cap(K)
  if ib and ib < c then c, why = ib, 'inbox' end
  return c, why
end

local function apply_cap(K)
  local gate, why = M.ceiling(K, st.lvl or 0)
  rt.gate_cap = gate
  local cu = K.census.u
  local cit = type(cu) == 'table' and cu.cit or nil
  local c, last = gate, st.cap
  if last and c < last then
    if not cit then return end                                -- freeze needs the population
    local f = math.max(c, math.min(last, cit))                -- demotion: frozen at the current pop
    if f > c then c, why = f, 'freeze' end
  end
  if last and c > last and K.mode() ~= 'PEACE' then c, why = last, 'frozen' end
  c = math.max(1, c)                                          -- pop-control needs a positive number
  if c == last and rt.applied then return end
  if not K.act.popcap(c) then return end
  rt.applied = true
  if c ~= last then
    st.cap, dirty = c, true
    K.emit('POPCAP', 'B', string.format('max-pop %d (%s)', c, why), {cap = c, why = why})
  end
end

local function refresh(K, why)
  evaluate(K, why)
  apply_cap(K)
  rt.pub = true
  save(K)
end

---------------------------------------------------------------- public API (CONTRACTS §7)
function M.level(K) return st.lvl or 0 end
function M.cap(K) return st.cap or rt.gate_cap or M.CAPS[0] end

---------------------------------------------------------------- verbs
local function bool(v) return type(v) == 'boolean' end

-- CONTRACTS §13 (R6): an audit is accepted only for a snapshot this boot exported with purpose
-- 'audit' (seen as EV:SNAPSHOT_READY) and only once; `by` is checked by kern (VERB_BY)
M.SNAPS_KEPT = 8
M.on['EV:SNAPSHOT_READY'] = function(K, ev)
  local d = type(ev) == 'table' and ev.d
  if type(d) ~= 'table' or d.purpose ~= 'audit' or type(d.id) ~= 'string' then return end
  rt.snaps = rt.snaps or {}
  local list = rt.snaps
  list[#list + 1] = d.id
  while #list > M.SNAPS_KEPT do table.remove(list, 1) end
end

local function take_snap(id)
  for i, s in ipairs(rt.snaps or {}) do
    if s == id then table.remove(rt.snaps, i); return true end
  end
  return false
end

M.verbs.audit = function(K, args, cmd)
  if type(args.snap) ~= 'string' or not bool(args.ok) or type(args.fails) ~= 'table' or not int(args.min_traps)
     or not (bool(args.bypass) and bool(args.refuge_sep) and bool(args.civ_sep) and bool(args.caverns)) then
    return false, 'bad audit args'
  end
  if not take_snap(args.snap) then return false, 'unknown snap' end
  local fails = {}
  for i = 1, math.min(#args.fails, 8) do fails[i] = cut(args.fails[i], 60) end
  local f = function(b) return b and 1 or 0 end
  st.audit = {tick = K.now().tick, snap = cut(args.snap, 40), ok = f(args.ok), fails = fails,
              min_traps = math.max(0, int(args.min_traps)), bypass = f(args.bypass),
              refuge_sep = f(args.refuge_sep), civ_sep = f(args.civ_sep), caverns = f(args.caverns)}
  dirty = true
  K.emit('AUDIT', 'B', string.format('audit %s: %d traps min%s', args.ok and 'ok' or 'failed', st.audit.min_traps,
         #fails > 0 and (', ' .. fails[1]) or ''), {ok = st.audit.ok, fails = fails, min_traps = st.audit.min_traps})
  refresh(K, 'audit')
  return true, string.format('audit stored, readiness R%d', st.lvl), {lvl = st.lvl}
end

M.verbs['popcap.lower'] = function(K, args, cmd)
  local cap = int(args.cap)
  if not cap or cap < 0 or cap > 250 then return false, 'cap must be an integer 0..250' end
  local cur = M.ceiling(K, st.lvl or 0)
  if cap < cur then
    st.inbox, dirty = {cap = cap, plan = plan_loaded(K)}, true
    refresh(K, 'inbox')
    return true, string.format('ceiling lowered to %d, max-pop %d', cap, M.cap(K)), {cap = M.cap(K)}
  end
  return true, string.format('ceiling already %d (lower only)', cur), {cap = M.cap(K)}
end

---------------------------------------------------------------- module
function M.init(K)
  local p = K.persist.get('m.readiness')
  p = type(p) == 'table' and p or {}
  st = {v = 2, lvl = int(p.lvl) or 0, cap = int(p.cap), siege = int(p.siege), audit_req = int(p.audit_req),
        audit_due = int(p.audit_due) or 0, audit_snap = p.audit_snap}
  if type(p.audit) == 'table' and int(p.audit.tick) then st.audit = p.audit end
  if type(p.inbox) == 'table' and int(p.inbox.cap) then st.inbox = {cap = int(p.inbox.cap), plan = int(p.inbox.plan)} end
  rt = {lev = nil, applied = false, pub = false, fail = {}, cv = 0, worn = 0}
  dirty = false
end

function M.step(K, budget, ctx)
  local now = K.now().tick
  if st.audit_due == 1 or not st.audit_req or now - st.audit_req >= M.AUDIT_EVERY then
    request_audit(K, st.audit_due == 1)
  end
  refresh(K, 'check')
end

function M.state(K)
  if not rt or not rt.pub then return {} end
  local now = K.now().tick
  local a = st.audit
  return {ready = {lvl = st.lvl or 0, worn = math.max(0, math.min(100, rt.worn or 0)), cv = math.max(0, rt.cv or 0),
                   drill_age = rt.pass_tick and math.max(0, now - rt.pass_tick) or -1,
                   audit = {ok = rt.audit_ok or 0, age = a and math.max(0, now - a.tick) or -1,
                            min_traps = a and a.min_traps or 0},
                   fail = rt.fail},
          pop = {cap = M.cap(K), gate_cap = rt.gate_cap or M.CAPS[0]}}
end

M.on.MODE = function(K, ev)
  if ev.to == 'SIEGE' or ev.to == 'BREACH' then st.siege, dirty = ev.tick or K.now().tick, true end
  refresh(K, 'mode ' .. tostring(ev.to))
end
M.on['EV:DRILL_RESULT'] = function(K, ev) refresh(K, 'drill') end
M.on['EV:PROJECT_STAGE'] = function(K, ev)
  if type(ev.d) == 'table' and ev.d.defense == 1 then rt.lev = nil; request_audit(K, true); save(K) end
end
M.on['EV:PROJECT_DONE'] = function(K, ev)
  rt.lev = nil                                    -- the manifest may have new bridges or levers
  request_audit(K, true)
  refresh(K, 'project')
end

return M
