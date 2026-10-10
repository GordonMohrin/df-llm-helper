-- Frozen v2 contract data (WP0). docs/v2/CONTRACTS.md is normative; df_llm_helper/schema.py
-- mirrors these tables and tests/test_schema.py checks that both agree. Pure Lua, no DFHack.
local json = require('dfllm.util.json')
local C = {}

C.V = 2
C.TICKS = {DAY = 1200, MONTH = 33600, SEASON = 100800, YEAR = 403200}

-- absolute game tick: monotonic across years and timestream skips (CONTRACTS §1.2)
function C.abs_tick(year, ytick) return year * 403200 + ytick end

C.MODES = {'PEACE', 'ALERT', 'SIEGE', 'BREACH', 'RECOVERY', 'DRILL'}
C.TRANSITIONS = {
  PEACE    = {ALERT = true, SIEGE = true, DRILL = true},
  ALERT    = {PEACE = true, SIEGE = true, BREACH = true},
  SIEGE    = {BREACH = true, RECOVERY = true},
  BREACH   = {RECOVERY = true},
  RECOVERY = {PEACE = true, ALERT = true, SIEGE = true, BREACH = true},
  DRILL    = {PEACE = true, ALERT = true, SIEGE = true},
}
-- who may call K.set_mode: siege any allowed transition; drill only these two
C.MODE_SETTERS = {siege = '*', drill = {['PEACE>DRILL'] = true, ['DRILL>PEACE'] = true}}

C.POSTURES = {'TRAIN', 'STATION_B1', 'READY_STATION', 'B2_HOLD'}

-- Gameplay modules in dispatch order (§3.4). every = default cadence; critical = never demoted.
C.MODULES = {
  {name = 'sense',     wp = 'WP5', critical = true, every = {ticks = 10}},
  {name = 'threat',    wp = 'WP5', critical = true, every = {ticks = 25}},
  {name = 'siege',     wp = 'WP5', critical = true, every = {ticks = 25}},
  {name = 'gate',      wp = 'WP5', critical = true, every = {ticks = 25}},
  {name = 'military',  wp = 'WP6', every = {ticks = 3600}},
  {name = 'drill',     wp = 'WP6', every = {ticks = 600}},
  {name = 'readiness', wp = 'WP6', every = {ticks = 33600}},
  {name = 'arbiter',   wp = 'WP1', critical = true, every = {ms = 500}},
  {name = 'runner',    wp = 'WP7', every = {ticks = 600}},
  {name = 'snapshot',  wp = 'WP7', every = {ticks = 100}},
  {name = 'economy',   wp = 'WP8', every = {ticks = 1200}},
  {name = 'care',      wp = 'WP8', every = {ticks = 1200}},
  {name = 'trade',     wp = 'WP9', every = {ticks = 100}},
  {name = 'baseline',  wp = 'WP8', every = {ticks = 33600}},
  {name = 'perf',      wp = 'WP1', every = {ms = 1000}},
  {name = 'selftest',  wp = 'WP1', every = {ms = 60000}},
}

-- Event registry (§12): class fixed per type; by = emitting module ('any' = every module).
C.EVENTS = {
  -- A: wakes the LLM
  SIEGE_END = {cls = 'A', by = 'siege'}, GATE_FAIL = {cls = 'A', by = 'gate'},
  BREACH = {cls = 'A', by = 'siege'}, DEATHS_3PLUS = {cls = 'A', by = 'care'},
  DRILL_FAIL = {cls = 'A', by = 'drill'}, KERN_FAULT = {cls = 'A', by = 'kern'},
  PERF_DEGRADED = {cls = 'A', by = 'perf'}, DECISION_NEEDED = {cls = 'A', by = 'any'},
  PLAN_EXHAUSTED = {cls = 'A', by = 'runner'}, PROJECT_BLOCKED = {cls = 'A', by = 'runner'},
  YEAR_REVIEW = {cls = 'A', by = 'kern'},
  -- B: digest
  SIEGE_START = {cls = 'B', by = 'siege'}, ALERT_START = {cls = 'B', by = 'siege'},
  ALERT_END = {cls = 'B', by = 'siege'}, INVASION = {cls = 'B', by = 'threat'},
  MOOD_START = {cls = 'B', by = 'care'}, MOOD_NEED = {cls = 'B', by = 'care'},
  MOOD_END = {cls = 'B', by = 'care'}, CARAVAN = {cls = 'B', by = 'trade'},
  MIGRANTS = {cls = 'B', by = 'economy'}, PETITION = {cls = 'B', by = 'care'},
  STOCK_LOW = {cls = 'B', by = 'economy'}, CANCEL_LOOP = {cls = 'B', by = 'economy'},
  CAPTURE = {cls = 'B', by = 'care'}, BREACH_STOP = {cls = 'B', by = 'runner'},
  KERNEL_SLOW = {cls = 'B', by = 'kern'}, WEALTH = {cls = 'B', by = 'siege'},
  DRILL_RESULT = {cls = 'B', by = 'drill'}, READY_CHANGE = {cls = 'B', by = 'readiness'},
  POPCAP = {cls = 'B', by = 'readiness'}, AUDIT = {cls = 'B', by = 'readiness'},
  PROJECT_DONE = {cls = 'B', by = 'runner'}, PROJECT_REQUEST = {cls = 'B', by = 'any'},
  PHASE = {cls = 'B', by = 'runner'}, PAUSE = {cls = 'B', by = 'arbiter'},
  DEATH = {cls = 'B', by = 'care'}, ACT_FAIL = {cls = 'B', by = 'kern'},
  -- C: log only
  SIEGE_STATUS = {cls = 'C', by = 'siege'}, SEASON = {cls = 'C', by = 'kern'},
  PROJECT_STAGE = {cls = 'C', by = 'runner'}, MODE = {cls = 'C', by = 'kern'},
  GATE = {cls = 'C', by = 'gate'}, LEVER = {cls = 'C', by = 'gate'},
  SNAPSHOT_READY = {cls = 'C', by = 'snapshot'}, CMD = {cls = 'C', by = 'kern'},
  BOOT = {cls = 'C', by = 'kern'}, UNLOAD = {cls = 'C', by = 'kern'},
}

-- Inbox verbs (§13). mod = handler ('kern' = kernel itself); modes = allowed modes (nil = any);
-- approve = args.approve must be true.
C.VERBS = {
  ['plan.reload']  = {mod = 'kern'},
  ['bp.place']     = {mod = 'runner'},
  ['bp.cancel']    = {mod = 'runner'},
  ['drill']        = {mod = 'drill', modes = {PEACE = true}},
  ['snapshot']     = {mod = 'snapshot'},
  ['audit']        = {mod = 'readiness'},
  ['popcap.lower'] = {mod = 'readiness'},
  ['tempo.lower']  = {mod = 'arbiter'},
  ['pause']        = {mod = 'arbiter'},
  ['unpause']      = {mod = 'arbiter'},
  ['trade.want']   = {mod = 'trade'},
  ['squad.sortie'] = {mod = 'military', approve = true,
                      modes = {ALERT = true, SIEGE = true, BREACH = true, RECOVERY = true}},
  ['lever']        = {mod = 'gate', modes = {PEACE = true}},
  ['inspect']      = {mod = 'kern'},
  ['selftest']     = {mod = 'selftest'},
  ['module.enable'] = {mod = 'kern'},
}
-- Verbs accepted only from these `by` origins (§9.5). `by` is a label, not authentication: the
-- hook (WP4) keeps the LLM from writing these origins; this check is the second line.
C.VERB_BY = {audit = {follow = true, test = true}}

-- act.lua functions (§5) and the modules allowed to call them ('*' = any module).
C.ACT = {
  set_paused = {'arbiter'}, timestream = {'arbiter'}, setting = {'arbiter'},
  overlay = {'arbiter'}, dismiss_popup = {'arbiter'},
  civ_alert = {'siege'}, alert_burrows = {'siege'},
  squad_create = {'military'}, squad_leader = {'military'}, squad_add = {'military'}, squad_remove = {'military'},
  squad_routine = {'military'}, squad_order = {'military'}, squad_uniform = {'military'},
  pull = {'gate'}, cancel_own_lever_job = {'gate'},
  popcap = {'readiness'},
  quickfort = {'runner'},
  orders_import = {'economy'}, orders = {'economy'}, workorder = {'economy'},
  order_suspend = {'economy'}, kitchen_exclude = {'economy'},
  item_flag = {'care'}, zone_assign = {'care'},
  trade = {'trade'},
  run = {'baseline', 'economy', 'care', 'military', 'trade', 'arbiter', 'selftest', 'runner'},
}

-- state.json leaf owners (§9.3); 'k.*' means every key under k.
C.STATE_OWNERS = {
  ['v'] = 'kern', ['seq'] = 'kern', ['ev'] = 'kern', ['t.*'] = 'kern', ['mode'] = 'kern',
  ['save'] = 'kern', ['k.*'] = 'kern',
  ['phase'] = 'runner', ['proj'] = 'runner',
  ['pop.cit'] = 'sense', ['pop.adults'] = 'sense', ['pop.soldiers'] = 'sense',
  ['pop.cap'] = 'readiness', ['pop.gate_cap'] = 'readiness', ['ready.*'] = 'readiness',
  ['stock.drink_d'] = 'economy', ['stock.food_d'] = 'economy', ['stock.meals'] = 'economy',
  ['stock.hosp_water'] = 'care', ['care.*'] = 'care', ['labor.*'] = 'economy',
  ['threat.*'] = 'threat', ['bridges'] = 'gate', ['owners.*'] = 'arbiter',
  ['mil.*'] = 'military', ['trade.*'] = 'trade',
}

-- Persistent site-data keys (§10). Stored as dfhack.persistent site strings encoded with util/json.
-- Dynamic keys: 'bp.<project id>' (runner), 'm.<module>' (that module).
C.PERSIST = {
  marker = {key = 'dfllm', owner = 'kern'},
  manifest = {key = 'dfllm.manifest', owner = 'runner'},
  projects = {key = 'dfllm.projects', owner = 'runner'},
  plan = {key = 'dfllm.plan', owner = 'kern'},
  phase = {key = 'dfllm.phase', owner = 'runner'},
  mode = {key = 'dfllm.mode', owner = 'kern'},     -- written by K.set_mode
  drill = {key = 'dfllm.drill', owner = 'drill'},
  restore = {key = 'dfllm.restore', owner = 'arbiter'},
  kern = {key = 'dfllm.kern', owner = 'kern'},
}
function C.persist_key(k)
  local e = C.PERSIST[k]
  if e then return e.key end
  if k:match('^bp%.[%w_.%-]+$') or k:match('^m%.[%l_]+$') then return 'dfllm.' .. k end
  return nil
end

C.DECISIONS = {
  ['D-01'] = 'A', ['D-02'] = 'unchanged', ['D-03'] = 'rule', ['D-04'] = 'off', ['D-05'] = 'off',
  ['D-06'] = 'off', ['D-07'] = 'unchanged', ['D-08'] = 'dropped', ['D-09'] = 'no', ['D-10'] = 'off',
  ['D-11'] = 'accepted', ['D-12'] = '15/20', ['D-13'] = 'no',
}

-- decisions.yaml reader (§9.16), the one Lua implementation (kern uses it; schema.parse_decisions is
-- the Python twin): strip a UTF-8 BOM, split on \n, strip spaces/tabs/\r at both ends, then
-- `D-NN [ \t]* : value [# comment]`; empty values are skipped, a later line wins.
function C.parse_decisions(text, into)
  local d = into or {}
  local s = tostring(text or '')
  if s:sub(1, 3) == '\239\187\191' then s = s:sub(4) end
  for line in s:gmatch('[^\n]+') do
    local l = line:match('^[ \t\r]*(.-)[ \t\r]*$')
    local id, rest = l:match('^(D%-[0-9][0-9])[ \t]*:(.*)$')
    if id then
      local hash = rest:find('#', 1, true)
      if hash then rest = rest:sub(1, hash - 1) end
      local val = rest:match('^[ \t]*(.-)[ \t]*$')
      if val ~= '' then d[id] = val end
    end
  end
  return d
end

-- Kernel fault and slowness rules (§3.3.5-3.3.6); k_mock and kern use these numbers.
C.KERN = {
  fault_n = 3, fault_window_ms = 600000,            -- 3 faults within 10 min -> back off
  backoff_ms = {critical = 30000, other = 600000},  -- first backoff; doubles per back-off in one boot
  backoff_max_ms = {critical = 480000, other = 3600000},
  backoff_reset_ms = 3600000,                       -- 1 h without a fault resets the doubling
  slow_ms = 5, slow_n = 3, slow_window_ms = 600000, -- 3 calls > 5 ms (os.clock) within 10 min = slow
  promote_ms = 600000, max_factor = 8,              -- factor halves after 10 min without a slow call
}

-- Report routing hints (§4.1, names = df.announcement_type; confirm in spike S7).
C.REPORTS = {
  CARAVAN_ARRIVAL = 'trade', FIRST_CARAVAN_ARRIVAL = 'trade', MERCHANTS_LEAVING_SOON = 'trade',
  MERCHANTS_NEED_DEPOT = 'trade',
  MIGRANT_ARRIVAL = 'economy', MIGRANT_ARRIVAL_NAMED = 'economy', D_MIGRANTS_ARRIVAL = 'economy',
  CANCEL_JOB = 'economy', FOOD_WARNING = 'economy',
  STRANGE_MOOD = 'care', MOOD_BUILDING_CLAIMED = 'care', ARTIFACT_BEGUN = 'care', MADE_ARTIFACT = 'care',
  CITIZEN_DEATH = 'care', ANIMAL_TRAP_CATCH = 'care', STRESSED_CITIZEN = 'care', CITIZEN_TANTRUM = 'care',
  GHOST_ATTACK = 'care',
  DIG_CANCEL_DAMP = 'runner', DIG_CANCEL_WARM = 'runner', CAVE_COLLAPSE = 'runner', FEATURE_DISCOVERY = 'runner',
  UNDEAD_ATTACK = 'threat', NIGHT_ATTACK_STARTS = 'threat', MEGABEAST_ARRIVAL = 'threat',
  WEREBEAST_ARRIVAL = 'threat', BEAST_AMBUSH = 'threat', AMBUSH_AMBUSHER = 'threat',
  AMBUSH_THIEF = 'threat', AMBUSH_SNATCHER = 'threat',
}

-- snapshot tile legend (§9.10): one ASCII char per tile
C.SNAP_LEGEND = '?_.#SCF<>Xrv+=H^Bw~%T'

---------------------------------------------------------------- state.json spec (§9.3)
-- Same tree as schema.STATE (tests/test_schema.py compares both and runs shared vectors).
-- Nodes: int{lo,hi} str{max,enum,fmt} bool null const{v} arr{items,lo,hi} tup{items}
--        obj{req,opt,extra,keys} any{of}. fmt/keys name a check in C.FMT.
local function int(lo, hi) return {t = 'int', lo = lo, hi = hi} end
local function str(max, enum, fmt) return {t = 'str', max = max, enum = enum, fmt = fmt} end
local function arr(items, lo, hi) return {t = 'arr', items = items, lo = lo or 0, hi = hi} end
local function obj(req, opt, extra, keys) return {t = 'obj', req = req or {}, opt = opt or {}, extra = extra, keys = keys} end
local NAT, FLAG, PCT, BOOL = int(0), int(0, 1), int(0, 100), {t = 'bool'}
local MODULE = str(nil, nil, 'module')

C.STATE_SPEC = obj({
  v = {t = 'const', v = C.V}, seq = NAT,
  t = obj({y = NAT, tick = int(0, 403199), season = int(0, 3), tps = NAT, paused = BOOL},
          {abs = NAT, wall = NAT, frame = NAT}),
  mode = str(nil, C.MODES),
  k = obj({ms_s = NAT, gap_max_ms = NAT, slow = arr(MODULE), faults = NAT}, {disabled = arr(MODULE), ms_max = NAT}),
  ev = NAT,
}, {
  save = str(120), phase = str(nil, nil, 'phase'),
  pop = obj(nil, {cit = NAT, adults = NAT, soldiers = NAT, cap = NAT, gate_cap = NAT}),
  ready = obj({lvl = int(0, 3), worn = PCT, cv = NAT, drill_age = int(-1),
               audit = obj({ok = FLAG, age = int(-1), min_traps = NAT}), fail = arr(str(24), 0, 8)}),
  stock = obj(nil, {drink_d = NAT, food_d = NAT, meals = NAT, hosp_water = FLAG}),
  care = obj({stressed_pct = PCT, naked = NAT, ghosts = NAT, corpses_old = NAT, tombs_free = NAT, moods = NAT}),
  labor = obj({starving = NAT, idle = PCT}),
  threat = obj({vis = NAT, armed = FLAG}),
  proj = arr({t = 'tup', items = {str(nil, nil, 'id'), str(24), PCT, str(40)}}, 0, 8),
  bridges = obj(nil, nil, str(nil, {'up', 'down', 'moving', 'unknown'}), 'bridge'),
  owners = obj({pause = {t = 'any', of = {{t = 'null'}, str(nil, {'inbox', 'gordon', 'popup', 'df'})}},
                tempo = str(nil, {'mode', 'inbox'})}),
  mil = obj({squads = NAT, soldiers = NAT, worn = PCT, cv = NAT, metal_pct = PCT, on_station = NAT}),
  trade = obj({caravan = FLAG, ratio = NAT, done = NAT}),
})

-- string formats (§1.1); explicit byte ranges, so LC_CTYPE cannot change them
C.FMT = {
  id = function(s) return #s >= 1 and #s <= 40 and not s:find('[^A-Za-z0-9_%-]') end,
  bridge = function(s) return #s >= 1 and #s <= 8 and s:find('^[A-Z]') ~= nil and not s:find('[^A-Za-z0-9]') end,
  module = function(s) return #s >= 2 and #s <= 16 and s:find('^[a-z]') ~= nil and not s:find('[^a-z_]') end,
  phase = function(s) return s:find('^P[0-7]$') ~= nil end,
}

local OBJECT_MT = getmetatable(json.object{})
-- JSON kind of v as util/json encodes it (floats are written rounded, NaN/inf as null)
local function kind(v)
  local tv = type(v)
  if v == nil or v == json.null then return 'null' end
  if tv == 'number' then
    if math.type(v) == 'float' and (v ~= v or v == math.huge or v == -math.huge) then return 'null' end
    return 'int'
  end
  if tv == 'boolean' then return 'bool' end
  if tv == 'string' then return 'str' end
  if tv ~= 'table' then return tv end
  if json.is_array(v) then return 'arr' end
  if getmetatable(v) == OBJECT_MT then return 'obj' end
  local n, c = #v, 0
  for _ in pairs(v) do c = c + 1 end
  return c == n and 'arr' or 'obj'
end
local function as_int(v)
  if math.type(v) == 'float' then return v >= 0 and math.floor(v + 0.5) or -math.floor(-v + 0.5) end
  return v
end
local function keystr(k) return math.type(k) == 'integer' and string.format('%d', k) or tostring(k) end

local check
local function expect(spec_t, k, path, out)
  out[#out + 1] = path .. ': expected ' .. spec_t .. ', got ' .. k
end
function check(s, v, path, out)
  local k, t = kind(v), s.t
  if t == 'any' then
    for _, alt in ipairs(s.of) do
      local e = {}
      check(alt, v, path, e)
      if #e == 0 then return end
    end
    out[#out + 1] = path .. ': no alternative matched'
  elseif t == 'null' or t == 'bool' or t == 'int' or t == 'str' then
    if k ~= t then return expect(t, k, path, out) end
    if t == 'int' then
      local n = as_int(v)
      if s.lo and n < s.lo then out[#out + 1] = string.format('%s: %d < %d', path, n, s.lo)
      elseif s.hi and n > s.hi then out[#out + 1] = string.format('%s: %d > %d', path, n, s.hi) end
    elseif t == 'str' then
      local ok = true
      if s.enum then
        ok = false
        for _, e in ipairs(s.enum) do if e == v then ok = true end end
      end
      if not ok then out[#out + 1] = path .. ': ' .. v .. ' not in enum'
      elseif s.fmt and not C.FMT[s.fmt](v) then out[#out + 1] = path .. ': ' .. v .. ' is not a ' .. s.fmt
      elseif s.max and #json.utf8_clean(v) > s.max then out[#out + 1] = path .. ': longer than ' .. s.max .. ' bytes' end
    end
  elseif t == 'const' then
    if (type(s.v) == 'number' and (k ~= 'int' or as_int(v) ~= s.v)) or (type(s.v) ~= 'number' and v ~= s.v) then
      out[#out + 1] = path .. ': expected ' .. tostring(s.v)
    end
  elseif t == 'arr' or t == 'tup' then
    if k ~= 'arr' then return expect('array', k, path, out) end
    local n = #v
    if t == 'tup' then
      if n ~= #s.items then out[#out + 1] = path .. ': expected ' .. #s.items .. ' items, got ' .. n; return end
      for i = 1, n do check(s.items[i], v[i], path .. '[' .. (i - 1) .. ']', out) end
      return
    end
    if n < s.lo then out[#out + 1] = path .. ': ' .. n .. ' items < ' .. s.lo end
    if s.hi and n > s.hi then out[#out + 1] = path .. ': ' .. n .. ' items > ' .. s.hi end
    for i = 1, n do check(s.items, v[i], path .. '[' .. (i - 1) .. ']', out) end
  elseif t == 'obj' then
    if k ~= 'obj' then return expect('object', k, path, out) end
    local req = {}
    for key in pairs(s.req) do req[#req + 1] = key end
    table.sort(req)
    for _, key in ipairs(req) do
      if v[key] == nil then out[#out + 1] = path .. '.' .. key .. ': missing'
      else check(s.req[key], v[key], path .. '.' .. key, out) end
    end
    local keys = {}
    for key in pairs(v) do keys[#keys + 1] = keystr(key) end
    table.sort(keys)
    for _, ks in ipairs(keys) do
      local x = v[ks]
      if x == nil then x = v[math.tointeger(tonumber(ks))] end
      if s.req[ks] == nil then
        if s.opt[ks] then check(s.opt[ks], x, path .. '.' .. ks, out)
        elseif not s.extra then out[#out + 1] = path .. '.' .. ks .. ': unknown key'
        else
          if s.keys and not C.FMT[s.keys](ks) then out[#out + 1] = path .. ': key ' .. ks .. ' is not a ' .. s.keys end
          check(s.extra, x, path .. '.' .. ks, out)
        end
      end
    end
  else
    error('contract: bad spec node ' .. tostring(t))
  end
end

-- Errors of a state document (strings 'path: msg', [] = valid), judged as util/json would write it.
function C.check_state(doc)
  local out = {}
  check(C.STATE_SPEC, doc, '$', out)
  return out
end

-- Drop every optional top-level key that has an error (kern does this before writing, §9.3).
-- Returns dropped keys (sorted) and all errors found; errors in required keys stay (kern logs them).
function C.prune_state(doc)
  local errs = C.check_state(doc)
  local dropped, seen = {}, {}
  if type(doc) ~= 'table' then return dropped, errs end
  for _, e in ipairs(errs) do
    local top = e:match('^%$%.([^.%[:]+)')
    if top and not C.STATE_SPEC.req[top] and not seen[top] and doc[top] ~= nil then
      seen[top] = true
      dropped[#dropped + 1] = top
      doc[top] = nil
    end
  end
  table.sort(dropped)
  return dropped, errs
end

return C
