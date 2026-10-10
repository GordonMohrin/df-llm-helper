-- Mock kernel K + fake df/dfhack for offline module tests (CONTRACTS §16). Pure Lua 5.3.
-- Implements the scheduling of §3.3 and the K interface of §4 exactly, and checks every
-- contract rule it can (event registry, act owners, mode setters, verbs, state owners and schema, 4 KB).
--   local W = require('dfllm.util.k_mock').new{units = {...}}
--   W.load(require('dfllm.gate')); W.run(600, {skip = 9}); W.find_acts('pull')
local json = require('dfllm.util.json')
local C = require('dfllm.util.contract')

local M = {}
local YEAR, SEASON = C.TICKS.YEAR, C.TICKS.SEASON

---------------------------------------------------------------- DF-like containers
local LEN = setmetatable({}, {__mode = 'k'})
local VEC = {}
VEC.__len = function(t) return LEN[t] end
VEC.__ipairs = function(t)
  return function(_, i) i = i + 1; if i < LEN[t] then return i, rawget(t, i) end end, t, -1
end
VEC.__pairs = VEC.__ipairs
VEC.__index = {
  insert = function(t, pos, v)
    local n = LEN[t]
    if pos == '#' or pos == nil then pos = n end
    for i = n, pos + 1, -1 do rawset(t, i, rawget(t, i - 1)) end
    rawset(t, pos, v); LEN[t] = n + 1
  end,
  erase = function(t, pos)
    local n = LEN[t]
    for i = pos, n - 2 do rawset(t, i, rawget(t, i + 1)) end
    rawset(t, n - 1, nil); LEN[t] = n - 1
  end,
}
-- 0-based vector like a DF std::vector (#v, v[0], ipairs from 0, :insert('#', x), :erase(i))
function M.vec(list)
  local t = setmetatable({}, VEC)
  LEN[t] = 0
  for _, x in ipairs(list or {}) do t:insert('#', x) end
  return t
end
function M.enum(names)
  local t = {}
  for i, n in ipairs(names) do t[n] = i - 1; t[i - 1] = n end
  return t
end
local vec = M.vec

local function packn(...) return {n = select('#', ...), ...} end
local function in_bbox(p, b)
  return p.x >= b[1] and p.x <= b[4] and p.y >= b[2] and p.y <= b[5] and p.z >= b[3] and p.z <= b[6]
end
local function copy(t)
  if type(t) ~= 'table' then return t end
  local r = {}
  for k, v in pairs(t) do r[k] = copy(v) end
  return setmetatable(r, getmetatable(t))
end

local MODULE_INDEX = {}
for i, m in ipairs(C.MODULES) do MODULE_INDEX[m.name] = i end

local PLAN_DEFAULTS = {
  military = {pct = 15, squads = {melee = 2, xbow = 1}, cv_min = 12},
  supply = {drink_d = 170, food_d = 60, mood_stock = 10},
  orders = {import = {}}, trade = {want = {}, sell = {}}, notes = '',
}

local function state_owner(top, sub)
  local O = C.STATE_OWNERS
  if sub then return O[top .. '.' .. sub] or O[top .. '.*'] or O[top] end
  return O[top] or O[top .. '.*']
end

---------------------------------------------------------------- world
function M.new(opts)
  opts = opts or {}
  local W = {acts = {}, events = {}, replies = {}, logs = {}, faults = {}, commands = {},
             persist_raw = {}, world_raw = {}, act_results = {}, cost = {}, jobs = {}, buildings = {},
             scripts = {}, cmd_outputs = {}, settings = {}, overlays = {}, timestream_fps = -1}
  local strict = opts.strict ~= false
  W.ms, W.frame_n = opts.ms or 0, 0
  W.ms_per_frame = opts.ms_per_frame or 16
  W.wall0 = opts.wall or 1791676800
  W.dfpath = opts.dfpath or '.'
  W.save = opts.save or 'mock'
  W.mode, W.mode_since = opts.mode or 'PEACE', 0
  W.seq, W.ev_n = 0, 0
  W.entries, W.mods = {}, {}
  local current = nil          -- module whose code runs now (nil = test code)
  local in_mode_cb = false
  local eventq, evq = {}, {}   -- eventful queue; emitted events for EV:<TYPE>
  local persist_cache = {}
  local flush_req, last_compose_ms = false, nil
  local job_seq, squad_seq, order_seq, report_seq, unit_seq = 100, 0, 0, 0, 1000

  ------------------------------------------------------------ fake df
  local units_by_id, burrows = {}, {}
  local df_ = {
    global = {
      cur_year = opts.year or 3, cur_year_tick = opts.ytick or 0, pause_state = false,
      plotinfo = {alerts = {civ_alert_idx = 0, list = vec{{burrows = vec{}}}}, burrows = {list = vec{}}},
      world = {units = {active = vec{}, all = vec{}}, status = {reports = vec{}},
               items = {all = vec{}, other = {}}, buildings = {all = vec{}, other = {}}},
      d_init = {dwarf = {population_cap = 75, strict_population_cap = 100, visitor_cap = 300},
                feature = {autosave = 'SEASONAL'}},
      enabler = {fps = 250, gfps = 250},
    },
  }
  for _, k in ipairs({'items', 'buildings'}) do
    setmetatable(df_.global.world[k].other, {__index = function(t, cat)
      local v = vec{}; rawset(t, cat, v); return v end})
  end
  local report_names = {}
  for name in pairs(C.REPORTS) do report_names[#report_names + 1] = name end
  table.sort(report_names)
  df_.announcement_type = M.enum(report_names)
  df_.unit = {find = function(id) return units_by_id[id] end}
  df_.building = {find = function(id) return W.buildings[id] end}
  df_.item = {find = function(id) return (W.items_by_id or {})[id] end}
  df_.report = {find = function(id)
    for _, r in ipairs(df_.global.world.status.reports) do if r.id == id then return r end end
  end}
  W.df = df_
  local G = df_.global

  ------------------------------------------------------------ fake dfhack
  local function um(u) return u._m end
  local units = {}
  function units.isDead(u) return um(u).dead == true end
  units.isKilled = units.isDead
  function units.isActive(u) return not um(u).dead and not um(u).offmap end
  function units.isVisible(u) return um(u).visible ~= false end
  function units.isHidden(u) return um(u).hidden == true end
  -- insane = a citizen gone berserk/raving: not a citizen unless include_insane, and a danger
  -- (Lua API.txt:1464-1470, :1668)
  function units.isCitizen(u, include_insane)
    local m = um(u)
    return m.citizen == true and not m.dead and (include_insane == true or not m.insane)
  end
  function units.isResident(u, include_insane)
    local m = um(u)
    return (m.citizen == true or m.resident == true) and not m.dead and (include_insane == true or not m.insane)
  end
  function units.isSane(u) local m = um(u); return not m.dead and not m.insane end
  function units.isCrazed(u) return um(u).insane == true end
  function units.isAdult(u) return um(u).adult ~= false end
  function units.isChild(u) return um(u).adult == false end
  function units.isBaby(u) return um(u).baby == true end
  function units.isInvader(u) return um(u).invader == true and not um(u).dead end
  function units.isMegabeast(u) return um(u).megabeast == true end
  function units.isForgottenBeast(u) return um(u).fb == true end
  function units.isTitan(u) return um(u).titan == true end
  function units.isUndead(u) return um(u).undead == true end
  function units.isDemon(u) return um(u).demon == true end
  function units.isGreatDanger(u)
    local m = um(u)
    return m.great == true or m.megabeast == true or m.fb == true or m.titan == true or m.demon == true
  end
  function units.isDanger(u)
    return um(u).danger == true or um(u).insane == true or units.isInvader(u) or units.isGreatDanger(u)
  end
  function units.isTame(u) return um(u).tame == true end
  function units.isMerchant(u) return um(u).merchant == true end
  function units.isVisitor(u) return um(u).visitor == true end
  function units.isAnimal(u) return um(u).animal == true end
  function units.isFortControlled(u) return units.isCitizen(u) or units.isTame(u) end
  function units.getStressCategory(u) return um(u).stress or 3 end
  function units.getPosition(u) return u.pos.x, u.pos.y, u.pos.z end
  function units.getReadableName(u) return um(u).name or ('Unit ' .. u.id) end
  function units.getRaceName(u) return um(u).race or 'DWARF' end
  function units.isUnitInBox(u, x1, y1, z1, x2, y2, z2)
    return in_bbox(u.pos, {x1, y1, z1, x2, y2, z2})
  end
  function units.getCitizens(exclude_residents, include_insane) -- Lua API.txt:1696
    local r = {}
    for _, u in ipairs(G.world.units.active) do
      local ok
      if exclude_residents then ok = units.isCitizen(u, include_insane) else ok = units.isResident(u, include_insane) end
      if ok then r[#r + 1] = u end
    end
    return r
  end

  local function store(raw)
    return {
      getString = function(k) return raw[k] end,
      saveString = function(k, s) assert(type(s) == 'string', 'persistent data must be a string'); raw[k] = s end,
      get = function(k, default) local s = raw[k]; if s == nil then return default end; return json.decode(s) end,
      save = function(k, t) raw[k] = json.encode(t) end,
      delete = function(k) local had = raw[k] ~= nil; raw[k] = nil; return had end,
    }
  end
  local site, wld = store(W.persist_raw), store(W.world_raw)
  local fs = rawget(_G, 'luahost')
  local dfhack_ = {
    units = units,
    getTickCount = function() return W.ms end,
    getDFPath = function() return W.dfpath end,
    getSavePath = function() return W.dfpath .. '/save/' .. W.save end,
    isMapLoaded = function() return true end, isWorldLoaded = function() return true end,
    isSiteLoaded = function() return true end,
    df2utf = function(s) return s end, utf2df = function(s) return s end,
    print = print,
    printerr = function(...) W.logs[#W.logs + 1] = {level = 'printerr', msg = table.concat(packn(...), ' ')} end,
    run_command_silent = function(...)
      local a = packn(...)
      W.commands[#W.commands + 1] = a
      return W.cmd_outputs[a[1]] or '', 0
    end,
    timeout = function(n, unit, cb) W.timeouts = W.timeouts or {}; W.timeouts[#W.timeouts + 1] = {n, unit, cb}; return #W.timeouts end,
    onStateChange = {},
    persistent = {
      getSiteDataString = site.getString, saveSiteDataString = site.saveString,
      getSiteData = site.get, saveSiteData = site.save, deleteSiteData = site.delete,
      getWorldDataString = wld.getString, saveWorldDataString = wld.saveString,
      getWorldData = wld.get, saveWorldData = wld.save, deleteWorldData = wld.delete,
    },
    burrows = {
      findByName = function(name) return burrows[name] end,
      getName = function(b) return b.name end,
      isAssignedTile = function(b, pos) return b ~= nil and in_bbox(pos, b._bbox) end,
      isAssignedUnit = function(b, u) return b ~= nil and in_bbox(u.pos, b._bbox) end,
    },
    military = {getSquadName = function(id) return 'Squad ' .. id end},
    internal = {getPerfCounters = function() return {} end},
    maps = {
      getSize = function() local s = W.map_size or {12, 12, 16}; return s[1], s[2], s[3] end,
      isValidTilePos = function(x, y, z)
        if type(x) == 'table' then x, y, z = x.x, x.y, x.z end
        local s = W.map_size or {12, 12, 16}
        return x >= 0 and y >= 0 and z >= 0 and x < s[1] * 16 and y < s[2] * 16 and z < s[3]
      end,
      getTileFlags = function(x, y, z)
        if type(x) == 'table' then x, y, z = x.x, x.y, x.z end
        local t = (W.tiles or {})[x .. ',' .. y .. ',' .. z]
        if not t then return nil, nil end
        return t.des, t.occ
      end,
      getTileType = function(x, y, z)
        if type(x) == 'table' then x, y, z = x.x, x.y, x.z end
        local t = (W.tiles or {})[x .. ',' .. y .. ',' .. z]
        return t and t.tt
      end,
    },
    filesystem = {
      listdir = function(p) return fs and fs.listdir(p) or {} end,
      isdir = function(p) return fs and fs.isdir(p) or false end,
      isfile = function(p)
        if fs then return fs.isfile(p) end
        local f = io.open(p, 'rb'); if f then f:close() end; return f ~= nil
      end,
      exists = function(p)
        if fs then return fs.isfile(p) or fs.isdir(p) end
        local f = io.open(p, 'rb'); if f then f:close() end; return f ~= nil
      end,
      mkdir_recursive = function(p) return fs and fs.mkdir_recursive(p) or false end,
      mtime = function(p) return fs and fs.mtime(p) or -1 end,
    },
  }
  W.dfhack = dfhack_

  -- default fake scripts (only act.lua tests need them)
  W.scripts['quickfort'] = {apply_blueprint = function(p)
    W.qf_calls = W.qf_calls or {}; W.qf_calls[#W.qf_calls + 1] = p; return {} end}
  W.scripts['lever'] = {
    leverPullJob = function(lever, priority) job_seq = job_seq + 1; return job_seq end,
    leverPullInstant = function() error('lever --instant is armok') end,
  }
  W.scripts['gui/civ-alert'] = {
    sound_alarm = function() G.plotinfo.alerts.civ_alert_idx = 1 end,
    clear_alarm = function() G.plotinfo.alerts.civ_alert_idx = 0 end,
  }

  if opts.globals ~= false then
    _G.df, _G.dfhack = df_, dfhack_
    _G.CR_OK, _G.CR_FAILURE, _G.CR_WRONG_USAGE = 0, -1, -2
    _G.reqscript = function(name)
      local s = W.scripts[name]
      if not s then error('k_mock: reqscript(' .. tostring(name) .. ') not provided (set W.scripts[name])', 2) end
      return s
    end
    _G.dfhack.reqscript = _G.reqscript
    _G.xyz2pos = function(x, y, z) return {x = x, y = y, z = z} end
    package.loaded['plugins.eventful'] = {
      eventType = M.enum({'TICK', 'JOB_INITIATED', 'JOB_STARTED', 'JOB_COMPLETED', 'UNIT_NEW_ACTIVE',
                          'UNIT_DEATH', 'ITEM_CREATED', 'BUILDING', 'CONSTRUCTION', 'SYNDROME', 'INVASION',
                          'INVENTORY_CHANGE', 'REPORT', 'UNIT_ATTACK', 'UNLOAD', 'INTERACTION'}),
      enableEvent = function() end, onReport = {}, onInvasion = {}, onUnitDeath = {},
    }
    package.loaded['repeat-util'] = {
      scheduleEvery = function(key, n, unit, cb) W.repeats = W.repeats or {}; W.repeats[key] = {n, unit, cb} end,
      cancel = function(key) if W.repeats then W.repeats[key] = nil end end,
    }
  end

  ------------------------------------------------------------ units, burrows, buildings, census
  -- A fake unit's DF-visible fields (pos, flags1, flags2) are read-only views over its spec u._m;
  -- tests change the world through the spec (W.move, W.kill, W.unit(id)._m.hidden = true).
  local function view(m, map)
    return setmetatable({}, {
      __index = function(_, k)
        local f = map[k]
        if f == nil then return nil end
        local v = m[f]
        if v == nil then return false end
        return v
      end,
      __newindex = function() error('k_mock: unit fields are read-only, edit the spec', 2) end})
  end
  function W.add_unit(spec)
    unit_seq = unit_seq + 1
    local m = copy(spec)
    local id = m.id or unit_seq
    local p = m.pos or {0, 0, 0}
    m.id, m.pos, m.x, m.y, m.z = id, nil, p[1] or p.x, p[2] or p.y, p[3] or p.z
    local u = {id = id, pos = view(m, {x = 'x', y = 'y', z = 'z'}),
               flags1 = view(m, {caged = 'caged', inactive = 'offmap'}), flags2 = view(m, {killed = 'dead'}),
               military = {squad_id = m.squad or -1, squad_position = -1},
               inventory = vec{}, status = {}, _m = m}
    units_by_id[id] = u
    G.world.units.active:insert('#', u)
    G.world.units.all:insert('#', u)
    return u
  end
  for _, s in ipairs(opts.units or {}) do W.add_unit(s) end
  function W.unit(id) return units_by_id[id] end
  function W.move(id, x, y, z) local m = units_by_id[id]._m; m.x, m.y, m.z = x, y, z end
  function W.kill(id) units_by_id[id]._m.dead = true end
  function W.burrow(name, bbox)
    local b = burrows[name]
    if not b then
      b = {id = #G.plotinfo.burrows.list, name = name}
      burrows[name] = b
      G.plotinfo.burrows.list:insert('#', b)
    end
    b._bbox = bbox
    return b
  end
  function W.add_building(spec)
    local b = copy(spec)
    b.id = b.id or (#G.world.buildings.all + 1)
    W.buildings[b.id] = b
    G.world.buildings.all:insert('#', b)
    return b
  end

  ------------------------------------------------------------ K
  local K = {census = {u = opts.census and opts.census.u, h = opts.census and opts.census.h,
                       i = opts.census and opts.census.i}}
  W.K = K
  local now = {}
  local function refresh_now(paused)
    now.year, now.ytick = G.cur_year, G.cur_year_tick
    now.tick = C.abs_tick(G.cur_year, G.cur_year_tick)
    now.season = G.cur_year_tick // SEASON
    now.ms, now.wall = W.ms, W.wall0 + W.ms // 1000
    now.paused = paused or G.pause_state == true
    now.frame = W.frame_n
  end
  refresh_now(false)
  W.mode_since = now.tick
  function K.now() return now end

  local function violation(msg)
    if strict then error('contract: ' .. msg, 3) end
    W.logs[#W.logs + 1] = {level = 'error', module = current, msg = 'contract: ' .. msg}
    return false, msg
  end

  local function trunc(s, n)
    s = tostring(s or '')
    if #s <= n then return s end
    local cut = n
    while cut > 0 and (s:byte(cut + 1) or 0) & 0xC0 == 0x80 do cut = cut - 1 end
    return s:sub(1, cut)
  end

  local function emit_as(by, etype, cls, msg, d)
    local reg = C.EVENTS[etype]
    if not reg then return violation('unknown event type ' .. tostring(etype)) end
    if by and reg.by ~= 'any' and reg.by ~= by then
      return violation(etype .. ' must be emitted by ' .. reg.by .. ', not ' .. by)
    end
    if cls ~= nil and cls ~= reg.cls then
      W.logs[#W.logs + 1] = {level = 'warn', module = by, msg = etype .. ' class ' .. tostring(cls) .. ' -> ' .. reg.cls}
    end
    if d ~= nil and type(d) ~= 'table' then return violation(etype .. ': d must be a table') end
    d = copy(d or {}) -- kern serializes at emit time; later mutation must not change the record
    local ok, enc = pcall(json.encode, d)
    if not ok then return violation(etype .. ': d not encodable: ' .. tostring(enc)) end
    if #enc > 1024 then d = {trunc = 1} end
    if next(d) == nil then d = json.object{} end
    W.ev_n = W.ev_n + 1
    local ev = {n = W.ev_n, tick = now.tick, type = etype, cls = reg.cls, msg = trunc(msg, 200), d = d}
    W.events[#W.events + 1] = ev
    evq[#evq + 1] = ev
    return ev.n
  end
  function K.emit(etype, cls, msg, d) return emit_as(current, etype, cls, msg, d) end

  function K.mode() return W.mode end
  function K.mode_since() return W.mode_since end

  local call_in -- forward
  local function persist_set(key, v) -- internal, no owner check
    local dk = C.persist_key(key)
    if v == nil then W.persist_raw[dk] = nil; persist_cache[key] = nil; return end
    W.persist_raw[dk] = json.encode(v)
    persist_cache[key] = v
  end

  function K.set_mode(m, why)
    if in_mode_cb then return false, 'reentrant' end
    local from = W.mode
    if m == from then return true, 'unchanged' end
    if not C.TRANSITIONS[from] or not C.TRANSITIONS[from][m] then
      return violation('mode transition ' .. from .. '>' .. tostring(m) .. ' not allowed')
    end
    if current then
      local rule = C.MODE_SETTERS[current]
      if rule == nil or (rule ~= '*' and not rule[from .. '>' .. m]) then
        return violation(current .. ' may not set mode ' .. from .. '>' .. m)
      end
    end
    W.mode, W.mode_since = m, now.tick
    persist_set('mode', {v = 2, mode = m, since = now.tick, why = trunc(why, 200), prev = from})
    in_mode_cb = true
    local ev = {from = from, to = m, why = why, tick = now.tick}
    for _, e in ipairs(W.entries) do
      if not e.disabled and e.M.on and e.M.on.MODE then call_in(e, 'on.MODE', e.M.on.MODE, ev) end
    end
    in_mode_cb = false
    emit_as('kern', 'MODE', 'C', from .. '>' .. m .. ' ' .. tostring(why or ''), {from = from, to = m, why = trunc(why, 60)})
    flush_req = true
    return true
  end

  -- act recorder
  local act_ids = {pull = function() job_seq = job_seq + 1; W.jobs[job_seq] = {id = job_seq, kind = 'PullLever'}; return job_seq end,
                   squad_create = function() squad_seq = squad_seq + 1; return squad_seq end,
                   workorder = function() order_seq = order_seq + 1; return order_seq end}
  local effects = {
    set_paused = function(on) G.pause_state = on and true or false; return true end,
    timestream = function(fps) W.timestream_fps = fps; return true end,
    setting = function(name, v) local old = W.settings[name]; W.settings[name] = v; return true, old end,
    overlay = function(name, on) local old = W.overlays[name]; W.overlays[name] = on; return true, old end,
    civ_alert = function(on) G.plotinfo.alerts.civ_alert_idx = on and 1 or 0; return true end,
    alert_burrows = function(names) W.alert_burrows = names; return true end,
    popcap = function(n) W.popcap = n; G.d_init.dwarf.population_cap = n; return true end,
    cancel_own_lever_job = function(id)
      if not W.jobs[id] then return false, 'not our job' end
      W.jobs[id] = nil; return true
    end,
    run = function(cmd, ...) return true, W.cmd_outputs[cmd] or '' end,
    quickfort = function(p) return true, {} end,
  }
  local act = {}
  for fn, owners in pairs(C.ACT) do
    local allowed = {}
    for _, o in ipairs(owners) do allowed[o] = true end
    act[fn] = function(...)
      if current and not allowed[current] and current ~= 'kern' then
        return violation('act.' .. fn .. ' is not owned by ' .. current)
      end
      local rec = {fn = fn, args = packn(...), by = current, tick = now.tick, mode = W.mode}
      W.acts[#W.acts + 1] = rec
      local f = W.act_results[fn]
      local ok, res
      if f then ok, res = f(...)
      elseif act_ids[fn] then ok, res = true, act_ids[fn](...)
      elseif effects[fn] then ok, res = effects[fn](...)
      else ok = true end
      rec.ok, rec.res = ok, res
      return ok, res
    end
  end
  K.act = setmetatable(act, {__index = function(_, k) error('contract: act.' .. tostring(k) .. ' does not exist', 2) end})
  function W.act_result(fn, f)
    if not C.ACT[fn] then error('k_mock: unknown act ' .. tostring(fn), 2) end
    W.act_results[fn] = f
  end

  -- persist
  local function persist_owner_ok(key)
    if current == nil or current == 'kern' then return true end
    local e = C.PERSIST[key]
    if e then return e.owner == current end
    if key:match('^bp%.') then return current == 'runner' end
    local mname = key:match('^m%.(.+)$')
    return mname == current
  end
  K.persist = {
    get = function(key)
      local dk = C.persist_key(key)
      if not dk then return violation('unknown persist key ' .. tostring(key)) end
      if persist_cache[key] == nil and W.persist_raw[dk] then persist_cache[key] = json.decode(W.persist_raw[dk]) end
      return persist_cache[key]
    end,
    set = function(key, v)
      if not C.persist_key(key) then return violation('unknown persist key ' .. tostring(key)) end
      if not persist_owner_ok(key) then return violation(current .. ' may not write persist ' .. key) end
      persist_set(key, v)
    end,
    touch = function(key)
      if not persist_owner_ok(key) then return violation(current .. ' may not write persist ' .. key) end
      if persist_cache[key] ~= nil then persist_set(key, persist_cache[key]) end
    end,
  }
  for key, v in pairs(opts.persist or {}) do persist_set(key, v) end
  if opts.marker ~= false and not K.persist.get('marker') then
    persist_set('marker', {v = 2, adopted = 0, save = W.save, fort = 'Mockfort', acceptance = 0, baseline = 0, boots = 1})
  end
  if opts.mode then persist_set('mode', {v = 2, mode = W.mode, since = W.mode_since, why = 'init', prev = W.mode}) end

  -- plan, cfg, log
  local function with_defaults(plan)
    local p = copy(plan or {v = 2, year = G.cur_year, phase_target = 'P0', seasons = {{build = {}}, {build = {}}, {build = {}}, {build = {}}},
                             policy = {option = 'A', pop_ceiling = 55, beauty = 'used_rooms'}})
    for k, v in pairs(PLAN_DEFAULTS) do if p[k] == nil then p[k] = copy(v) end end
    p.phases = p.phases or opts.phases
    return p
  end
  K.plan = with_defaults(opts.plan)
  function W.set_plan(plan) K.plan = with_defaults(plan) end
  local cfg = opts.cfg or {}
  local decisions = {}
  for k, v in pairs(C.DECISIONS) do decisions[k] = v end
  for k, v in pairs(cfg.decisions or {}) do decisions[k] = v end
  K.cfg = {decisions = decisions,
           allowlist = cfg.allowlist or {v = 2, commands = {}, blocked = {}, armok_exceptions = {}},
           baseline = cfg.baseline or {v = 2},
           paths = {df = W.dfpath, runtime = W.dfpath .. '/dfllm-runtime', save = W.dfpath .. '/dfllm-runtime/' .. W.save,
                    repo = cfg.repo or '.'},
           save = W.save, dev = cfg.dev == true, acceptance = cfg.acceptance == true}
  local LEVELS = {debug = true, info = true, warn = true, error = true}
  function K.log(level, fmt, ...)
    if not LEVELS[level] then return violation('bad log level ' .. tostring(level)) end
    local ok, msg = pcall(string.format, tostring(fmt), ...)
    W.logs[#W.logs + 1] = {level = level, module = current, msg = ok and msg or tostring(fmt)}
  end

  -- calls with fault isolation; 3 faults in 10 min back the module off (§3.3.5, contract.KERN)
  local KN = C.KERN
  local function fault(e, where, err)
    W.faults[#W.faults + 1] = {module = e.name, where = where, err = tostring(err)}
    if strict then error(e.name .. ' ' .. where .. ': ' .. tostring(err), 0) end
    if e.last_fault and W.ms - e.last_fault >= KN.backoff_reset_ms then e.backoff = nil end
    e.last_fault = W.ms
    e.fault_ms = e.fault_ms or {}
    local keep = {}
    for _, t in ipairs(e.fault_ms) do if W.ms - t < KN.fault_window_ms then keep[#keep + 1] = t end end
    keep[#keep + 1] = W.ms
    e.fault_ms = keep
    if #keep >= KN.fault_n and not e.disabled then
      local cls = e.critical and 'critical' or 'other'
      e.backoff = e.backoff and math.min(e.backoff * 2, KN.backoff_max_ms[cls]) or KN.backoff_ms[cls]
      e.disabled, e.cont, e.disabled_until, e.fault_ms = true, false, W.ms + e.backoff, {}
      emit_as('kern', 'KERN_FAULT', 'A', e.name .. ' backed off ' .. e.backoff // 1000 .. ' s after 3 faults',
              {module = e.name, err = trunc(err, 120), n = #keep, backoff_s = e.backoff // 1000})
    end
  end
  local function enable(e, why)
    e.disabled, e.disabled_until, e.fault_ms = false, nil, {}
    if why == 'verb' then e.backoff = nil end
    W.logs[#W.logs + 1] = {level = 'info', module = 'kern', msg = e.name .. ' re-enabled (' .. why .. ')'}
  end
  function call_in(e, where, f, ...)
    local prev = current
    current = e.name
    local r = packn(xpcall(f, debug.traceback, K, ...))
    current = prev
    if not r[1] then fault(e, where, r[2]); return false, r[2] end
    return table.unpack(r, 1, r.n)
  end
  function K.call(name, fn, ...)
    local e = W.mods[name]
    if not e then return false, 'no module' end
    if e.disabled then return false, 'disabled' end
    local f = e.M[fn]
    if type(f) ~= 'function' then return false, 'no function ' .. tostring(fn) end
    return call_in(e, 'call ' .. fn, f, ...)
  end
  function K.enabled(name) local e = W.mods[name]; return e ~= nil and not e.disabled end
  function K.manifest() return K.persist.get('manifest') or {v = 2} end
  function K.flush() flush_req = true end

  -- state composition
  local function compose()
    W.seq = W.seq + 1
    local faults, slow, disabled = 0, {}, {}
    for _, e in ipairs(W.entries) do
      faults = faults + #(e.fault_ms or {})
      if e.factor > 1 then slow[#slow + 1] = e.name end
      if e.disabled then disabled[#disabled + 1] = e.name end
    end
    local doc = {v = 2, seq = W.seq, mode = W.mode, ev = W.ev_n, save = W.save,
                 t = {y = now.year, tick = now.ytick, season = now.season, tps = W.tps or 0, paused = now.paused,
                      abs = now.tick, wall = now.wall, frame = now.frame},
                 k = {ms_s = 0, gap_max_ms = 0, slow = json.array(slow), faults = faults}}
    if #disabled > 0 then doc.k.disabled = disabled end
    for _, e in ipairs(W.entries) do
      if not e.disabled and e.M.state then
        local ok, part = call_in(e, 'state', e.M.state)
        if ok and part ~= nil then
          if type(part) ~= 'table' then violation(e.name .. '.state must return a table') else
            for top, v in pairs(part) do
              local is_obj = type(v) == 'table' and not json.is_array(v) and next(v) ~= nil and #v == 0
              if is_obj and state_owner(top) ~= e.name then
                doc[top] = doc[top] or {}
                for sub, sv in pairs(v) do
                  if state_owner(top, sub) ~= e.name then
                    violation(e.name .. ' does not own state ' .. top .. '.' .. tostring(sub))
                  else doc[top][sub] = sv end
                end
              elseif state_owner(top) ~= e.name then
                violation(e.name .. ' does not own state ' .. tostring(top))
              else doc[top] = v end
            end
          end
        end
      end
    end
    -- schema check (§9.3): strict raises; otherwise drop invalid optional keys like kern
    local dropped, errs = C.prune_state(doc)
    if #errs > 0 then
      violation('state.json invalid: ' .. table.concat(errs, '; ', 1, math.min(#errs, 6)) ..
                (#dropped > 0 and (' (dropped ' .. table.concat(dropped, ',') .. ')') or ''))
    end
    local enc = json.encode(doc)
    if #enc > 4096 then violation('state.json is ' .. #enc .. ' bytes > 4096') end
    W.view_doc = doc
    last_compose_ms = W.ms
    flush_req = false
    return doc
  end
  function K.view() return W.view_doc or {} end
  function W.state() return compose() end

  ------------------------------------------------------------ modules and frames
  function W.load(mod)
    assert(type(mod) == 'table' and type(mod.name) == 'string', 'k_mock: module needs a name')
    local idx = MODULE_INDEX[mod.name]
    if not idx and not mod.name:match('^test_') then
      return violation('module ' .. mod.name .. ' is not in contract.MODULES (prefix test_ for test modules)')
    end
    if W.mods[mod.name] then error('k_mock: module ' .. mod.name .. ' loaded twice', 2) end
    local ev = mod.every
    if type(ev) ~= 'table' or (ev.ticks == nil) == (ev.ms == nil) then
      return violation(mod.name .. '.every must be {ticks=N} or {ms=N}')
    end
    local critical = mod.critical
    if critical == nil and idx then critical = C.MODULES[idx].critical end
    local e = {name = mod.name, M = mod, order = idx or (100 + #W.entries), factor = 1, slow_ms = {},
               critical = critical == true}
    W.mods[mod.name] = e
    W.entries[#W.entries + 1] = e
    table.sort(W.entries, function(a, b) return a.order < b.order end)
    if mod.init then call_in(e, 'init', mod.init) end
    return mod
  end

  -- W.cost[name] = simulated os.clock() ms per step (§3.3.6): 3 slow calls within 10 min demote a
  -- module (critical: KERN_FAULT at most once per 10 min); 10 min without one halves the factor.
  local function charge(e, where)
    local c, t = W.cost[e.name], W.ms
    if e.factor > 1 and t - (e.last_slow or t) >= KN.promote_ms then
      e.factor, e.last_slow = e.factor // 2, t
      W.logs[#W.logs + 1] = {level = 'info', module = 'kern', msg = e.name .. ' promoted to x' .. e.factor}
    end
    if not c or c <= KN.slow_ms then return end
    e.last_slow = t
    local keep = {}
    for _, s in ipairs(e.slow_ms) do if t - s < KN.slow_window_ms then keep[#keep + 1] = s end end
    keep[#keep + 1] = t
    e.slow_ms = keep
    if #keep < KN.slow_n then return end
    e.slow_ms = {}
    if e.critical then
      if not e.slow_fault or t - e.slow_fault >= KN.slow_window_ms then
        e.slow_fault = t
        emit_as('kern', 'KERN_FAULT', 'A', e.name .. ' slow (' .. c .. ' ms)', {module = e.name, err = 'slow', n = KN.slow_n})
      end
    elseif e.factor < KN.max_factor then
      e.factor = e.factor * 2
      emit_as('kern', 'KERNEL_SLOW', 'B', e.name .. ' demoted x' .. e.factor, {module = e.name, ms = c, factor = e.factor})
    end
  end

  local function run_step(e, cont)
    local ctx = {dt = e.last_tick and (now.tick - e.last_tick) or 0, dt_ms = e.last_ms and (now.ms - e.last_ms) or 0,
                 cont = cont, slice = cont and (e.slice + 1) or 1}
    if not cont then e.last_tick, e.last_ms = now.tick, now.ms else ctx.dt, ctx.dt_ms = 0, 0 end
    e.slice = ctx.slice
    local ok, r = call_in(e, 'step', e.M.step, e.critical and 1 or 2, ctx)
    charge(e, 'step')
    e.cont = ok and r == 'more'
  end

  local function deliver(e, name, ev)
    local h = e.M.on and e.M.on[name]
    if not h then return end
    if name == 'REPORT' and e.M.reports and not e.M.reports[ev.type] then return end
    call_in(e, 'on.' .. name, h, ev)
  end

  function W.event(name, ev)
    assert(name == 'INVASION' or name == 'REPORT' or name == 'UNIT_DEATH', 'k_mock: eventful event ' .. tostring(name))
    eventq[#eventq + 1] = {name, copy(ev or {})}
  end

  local function check_calendar(prev_year, prev_season)
    if G.cur_year ~= prev_year then
      emit_as('kern', 'YEAR_REVIEW', 'A', 'year ' .. prev_year .. ' done', {year = prev_year})
    end
    local season = G.cur_year_tick // SEASON
    if season ~= prev_season or G.cur_year ~= prev_year then
      emit_as('kern', 'SEASON', 'C', 'season ' .. season, {year = G.cur_year, season = season})
    end
  end

  function W.frame(dt, paused)
    dt = dt or 1
    local ticking = not paused and not G.pause_state and dt > 0
    local py, ps = G.cur_year, G.cur_year_tick // SEASON
    if ticking then
      G.cur_year_tick = G.cur_year_tick + dt
      while G.cur_year_tick >= YEAR do G.cur_year_tick = G.cur_year_tick - YEAR; G.cur_year = G.cur_year + 1 end
    end
    W.ms = W.ms + W.ms_per_frame
    W.frame_n = W.frame_n + 1
    refresh_now(not ticking)
    current = 'kern'
    if ticking then check_calendar(py, ps) end
    current = nil
    for _, e in ipairs(W.entries) do
      if e.disabled and e.disabled_until and W.ms >= e.disabled_until then enable(e, 'backoff over') end
    end
    -- queued eventful events, then events emitted in the previous frame (swap first, so events
    -- emitted during this frame are delivered next frame)
    local eq = evq; evq = {}
    local q = eventq; eventq = {}
    for _, item in ipairs(q) do
      local name, ev = item[1], item[2]
      ev.tick = now.tick
      if name == 'REPORT' then
        report_seq = report_seq + 1
        ev.id = ev.id or report_seq
        G.world.status.reports:insert('#', {id = ev.id, type = df_.announcement_type[ev.type], text = ev.text, pos = ev.pos})
      end
      for _, e in ipairs(W.entries) do if not e.disabled then deliver(e, name, ev) end end
    end
    for _, ev in ipairs(eq) do
      for _, e in ipairs(W.entries) do if not e.disabled then deliver(e, 'EV:' .. ev.type, ev) end end
    end
    -- due modules in contract order
    for _, e in ipairs(W.entries) do
      if not e.disabled and e.M.step then
        if e.cont then run_step(e, true)
        else
          local ev = e.M.every or {}
          local due
          if ev.ticks then due = ticking and (e.last_tick == nil or now.tick - e.last_tick >= ev.ticks * e.factor)
          else due = e.last_ms == nil or now.ms - e.last_ms >= ev.ms * e.factor end
          if due then run_step(e, false) end
        end
      end
    end
    if flush_req or last_compose_ms == nil or W.ms - last_compose_ms >= 2000 then compose() end
  end

  -- advance `ticks` game ticks in frames of opts.skip (number or array cycled); {paused=true}: `ticks` frames, no ticks
  function W.run(ticks, ropts)
    ropts = ropts or {}
    if ropts.paused then
      for _ = 1, ticks do W.frame(0, true) end
      return
    end
    local skip, i, done = ropts.skip or 1, 0, 0
    while done < ticks do
      i = i + 1
      local step = type(skip) == 'table' and skip[(i - 1) % #skip + 1] or skip
      step = math.min(step, ticks - done)
      W.frame(step)
      done = done + step
    end
  end

  function W.unload()
    for _, e in ipairs(W.entries) do if not e.disabled then deliver(e, 'UNLOAD', {}) end end
    current = 'kern'
    emit_as('kern', 'UNLOAD', 'C', 'unload', nil)
    current = nil
  end

  ------------------------------------------------------------ inbox
  local cmd_seq = 0
  local kern_verbs = {
    ['plan.reload'] = function(args)
      local plan = W.plan_file
      if not plan then return false, 'no plan.json' end
      K.plan = with_defaults(plan)
      persist_set('plan', {v = 2, plan = plan, phases = K.plan.phases or json.null, loaded = now.tick})
      local n = 0
      for _, s in ipairs(plan.seasons or {}) do n = n + #(s.build or {}) end
      return true, 'plan y' .. tostring(plan.year) .. ' loaded', {year = plan.year, builds = n}
    end,
    inspect = function(args)
      local what = args.what
      if what == 'state' then return true, 'state', compose()
      elseif what == 'mode' then return true, W.mode, {mode = W.mode, since = W.mode_since}
      elseif what == 'census' then return true, 'census', K.census
      elseif what == 'manifest' then return true, 'manifest', K.manifest()
      elseif what == 'plan' then return true, 'plan', K.plan
      elseif what == 'projects' then return true, 'projects', K.persist.get('projects') or {}
      elseif what == 'modules' then
        local r = {}
        for _, e in ipairs(W.entries) do r[#r + 1] = {name = e.name, disabled = e.disabled or false, factor = e.factor} end
        return true, 'modules', r
      elseif what == 'persist' then
        local r = {}
        for k in pairs(W.persist_raw) do r[#r + 1] = k end
        table.sort(r)
        return true, 'persist', r
      elseif what == 'perf' then return true, 'perf', json.object{} end
      return false, 'bad what'
    end,
    ['module.enable'] = function(args)
      local e = type(args.module) == 'string' and W.mods[args.module]
      if not e then return false, 'no module ' .. tostring(args.module) end
      local was = e.disabled == true
      enable(e, 'verb')
      return true, args.module .. (was and ' re-enabled' or ' was enabled'), {module = args.module}
    end,
  }
  function W.inbox(verb, args, o)
    o = o or {}
    cmd_seq = cmd_seq + 1
    local cmd = {id = o.id or ('t' .. cmd_seq), verb = verb, by = o.by or 'test', ts = W.wall0 * 1000 + W.ms}
    args = args or {}
    local function reply(ok, msg, data)
      local r = {id = cmd.id, ok = ok and true or false, msg = trunc(msg or '', 300), verb = verb, tick = now.tick}
      if data ~= nil then r.data = data end
      W.replies[#W.replies + 1] = r
      local prev = current
      current = 'kern'
      emit_as('kern', 'CMD', 'C', verb .. ' ' .. (r.ok and 'ok' or 'failed'), {id = cmd.id, verb = verb, ok = r.ok and 1 or 0})
      current = prev
      return r
    end
    local spec = C.VERBS[verb]
    if not spec then return reply(false, 'unknown verb') end
    if type(args) ~= 'table' then return reply(false, 'args must be an object') end
    if C.VERB_BY[verb] and not C.VERB_BY[verb][cmd.by] then return reply(false, verb .. ' not accepted from ' .. tostring(cmd.by)) end
    if spec.modes and not spec.modes[W.mode] then return reply(false, verb .. ' not allowed in ' .. W.mode) end
    if spec.approve and args.approve ~= true then return reply(false, 'approval required') end
    if spec.mod == 'kern' then
      local ok, msg, data = kern_verbs[verb](args)
      return reply(ok, msg, data)
    end
    local e = W.mods[spec.mod]
    if not e then return reply(false, 'no module ' .. spec.mod) end
    if e.disabled then return reply(false, 'module disabled') end
    local h = e.M.verbs and e.M.verbs[verb]
    if not h then return reply(false, 'no handler for ' .. verb) end
    local nf = #W.faults
    local r = packn(call_in(e, 'verb ' .. verb, h, args, cmd))
    if #W.faults > nf then return reply(false, 'handler error') end
    return reply(r[2], r[3], r[4]) -- r[1] is the pcall status
  end

  ------------------------------------------------------------ recorders
  function W.find_acts(fn)
    local r = {}
    for _, a in ipairs(W.acts) do if fn == nil or a.fn == fn then r[#r + 1] = a end end
    return r
  end
  function W.find_events(etype)
    local r = {}
    for _, ev in ipairs(W.events) do if etype == nil or ev.type == etype then r[#r + 1] = ev end end
    return r
  end
  function W.set_census(part, tbl)
    assert(part == 'u' or part == 'h' or part == 'i', 'k_mock: census part must be u, h or i')
    K.census[part] = tbl
  end
  function W.set_mode(m) W.mode, W.mode_since = m, now.tick end
  function W.clear() W.acts, W.events, W.replies, W.logs, W.faults = {}, {}, {}, {}, {} end

  return W
end

return M
