-- dfllm kernel (CONTRACTS §3-§4, §8-§10, §12-§13; reference semantics: util/k_mock.lua).
-- One repeat-util frame callback dispatches every module; eventful callbacks only enqueue;
-- all files are written from here (state a/b, events, heartbeat, outbox, logs). Boot is a no-op
-- without the site marker, except healing a crashed restore.json (runtime settings, any save).
local json = require('dfllm.util.json')
local C = require('dfllm.util.contract')
local fio = require('dfllm.io')
local persistlib = require('dfllm.persist')
local actlib = require('dfllm.act')

local M = {}
M.KEY = 'dfllm'
M.BY = {llm = true, gordon = true, cli = true, follow = true, supervise = true, test = true}
M.CAD = {state_ms = 2000, events_ms = 1000, inbox_ms = 500, heartbeat_ms = 5000, persist_ms = 10000,
         inbox_per_frame = 4, slow_ms = 5, fault_window_ms = 600000, eventq_max = 2000, gap_ms = 3000,
         evbuf_max = 5000, logbuf_max = 2000}   -- lines kept while a file cannot be written
local CAD = M.CAD
local KN = C.KERN               -- fault backoff and slowness numbers (CONTRACTS §3.3.5-3.3.6)
local SEASON = C.TICKS.SEASON
local LEVELS = {debug = true, info = true, warn = true, error = true}
local NO_CHARGE = {init = true, heal = true, ['on.UNLOAD'] = true}

-- cost clock (CONTRACTS §1.2): os.clock() in ms (1 ms steps on lua53.dll, profiler.lua:190);
-- getTickCount moves in 15.6 ms steps and is used only for cadences. Tests may set M.cost_clock.
M.cost_clock = nil
local function cost_ms()
  local f = M.cost_clock
  if f then return f() end
  return os.clock() * 1000
end
local function round(x) return math.floor((x or 0) + 0.5) end
local PLAN_DEFAULTS = {
  military = {pct = 15, squads = {melee = 2, xbow = 1}, cv_min = 12},
  supply = {drink_d = 170, food_d = 60, mood_stock = 10},
  orders = {import = {}}, trade = {want = {}, sell = {}}, notes = '',
}
local MODULE_INDEX = {}
for i, m in ipairs(C.MODULES) do MODULE_INDEX[m.name] = m end

local S          -- the running kernel state, nil when stopped

---------------------------------------------------------------- small helpers
local function copy(t)
  if type(t) ~= 'table' or t == json.null then return t end
  local r = {}
  for k, v in pairs(t) do r[k] = copy(v) end
  return setmetatable(r, getmetatable(t))
end

local function trunc(s, n)
  s = tostring(s or '')
  if #s <= n then return s end
  local cut = n
  while cut > 0 and (s:byte(cut + 1) or 0) & 0xC0 == 0x80 do cut = cut - 1 end
  return s:sub(1, cut)
end

local function clean(s, n) return trunc(json.utf8_clean(tostring(s or '')), n) end
local function oneline(s) return (tostring(s or ''):gsub('[\r\n\t]+', ' ')) end
local function first_line(s) return (tostring(s or ''):match('^[^\n]*')) end

local function state_owner(top, sub)
  local O = C.STATE_OWNERS
  if sub then return O[top .. '.' .. sub] or O[top .. '.*'] or O[top] end
  return O[top] or O[top .. '.*']
end

local function valid_every(ev)
  if type(ev) ~= 'table' or (ev.ticks == nil) == (ev.ms == nil) then return false end
  local n = ev.ticks or ev.ms
  return math.type(n) == 'integer' and n > 0
end

local function save_name()
  local p = dfhack.getSavePath and dfhack.getSavePath()
  if p and p ~= '' then return fio.basename(p) end
  if dfhack.world and dfhack.world.ReadWorldFolder then return dfhack.world.ReadWorldFolder() end
  return nil
end

local function abs_now()
  return C.abs_tick(df.global.cur_year, df.global.cur_year_tick)
end

function M.with_defaults(plan, phases_doc)
  local p = copy(plan)
  if type(p) ~= 'table' or p == json.null then
    p = {v = 2, year = df.global.cur_year, phase_target = 'P0',
         seasons = {{build = {}}, {build = {}}, {build = {}}, {build = {}}},
         policy = {option = 'A', pop_ceiling = 55, beauty = 'used_rooms'}}
  end
  for k, v in pairs(PLAN_DEFAULTS) do if p[k] == nil then p[k] = copy(v) end end
  if type(phases_doc) == 'table' and phases_doc ~= json.null then p.phases = phases_doc.phases end
  return p
end

-- decisions.yaml (CONTRACTS §9.16): the one Lua reader is contract.parse_decisions
M.parse_decisions = C.parse_decisions

-- re-enable a backed-off module (CONTRACTS §3.3.5): empty fault window, no second init;
-- why 'verb' (inbox module.enable) also resets the backoff doubling
local function enable(st, e, why)
  e.disabled, e.disabled_until, e.fault_ms = false, nil, {}
  if why == 'verb' then e.backoff = nil end
  st.log_as('kern', 'info', e.name .. ' re-enabled (' .. why .. ')')
  st.persist_rec()
  st.flush_req = true
end

---------------------------------------------------------------- kernel instance
local function build(o)
  local st = {opts = o.opts, paths = o.paths, save_name = o.save, marked = o.marked, strict = o.opts.strict == true,
              entries = {}, mods = {}, current = nil, in_mode_cb = false, frame_n = 0,
              eventq = {}, evq = {}, evbuf = {}, logbuf = {}, cmdbuf = {}, flush_events_now = false,
              ev_n = 0, seq = 0, mode = 'PEACE', mode_since = 0, view = nil, flush_req = false,
              last_state_ms = nil, last_hb_ms = nil, last_inbox_ms = nil, last_ev_flush_ms = 0,
              last_persist_ms = 0, inbox_pending = {}, inbox_retry = {}, inbox_stuck = {}, once = {},
              buckets = {}, p = {ms = 0, frames = 0, gap_max = 0, gaps3 = 0, unpaused_ms = 0, mods = {}},
              dropped = 0, report_any = false, report_types = {}, ev_listen = {}, kern_faults = 0,
              rot_warned = {}, io_warned = {}}
  st.now = {tick = abs_now(), ytick = df.global.cur_year_tick, year = df.global.cur_year,
            season = df.global.cur_year_tick // SEASON, ms = dfhack.getTickCount(), wall = os.time(),
            paused = df.global.pause_state == true, frame = 0}
  st.cal_year, st.cal_season = st.now.year, st.now.season
  local K = {census = {}}
  st.K = K

  ------------------------------------------------------------ logs (buffered, flushed with events)
  local function log_as(module, level, msg)
    if level == 'debug' and not (st.cfg and st.cfg.dev) then return end
    st.logbuf[#st.logbuf + 1] = string.format('%d\t%d\t%s\t%s\t%s\n', os.time(), st.now.tick, level,
                                              module or 'kern', oneline(msg))
    if level == 'error' then dfhack.printerr('dfllm ' .. tostring(module or 'kern') .. ': ' .. first_line(msg)) end
  end
  st.log_as = log_as
  local function log_cmd(origin, what, args_json, result)
    st.cmdbuf[#st.cmdbuf + 1] = string.format('%d\t%d\t%s\t%s\t%s\t%s\n', os.time(), st.now.tick, oneline(origin),
                                              oneline(what), oneline(args_json), oneline(result))
  end
  st.log_cmd = log_cmd
  local function violation(msg)
    log_as(st.current, 'error', 'contract: ' .. msg)
    if st.strict then error('contract: ' .. msg, 3) end
    return false, msg
  end

  ------------------------------------------------------------ events (§12)
  local function emit_as(by, etype, cls, msg, d)
    local reg = C.EVENTS[etype]
    if not reg then violation('unknown event type ' .. tostring(etype)); return nil end
    by = by or 'kern'
    if reg.by ~= 'any' and reg.by ~= by then
      violation(etype .. ' must be emitted by ' .. reg.by .. ', not ' .. by); return nil
    end
    if cls ~= nil and cls ~= reg.cls then log_as(by, 'warn', etype .. ' class ' .. tostring(cls) .. ' -> ' .. reg.cls) end
    if d ~= nil and type(d) ~= 'table' then violation(etype .. ': d must be a table'); return nil end
    local ok, denc = pcall(json.encode, d or json.object{})
    if not ok then violation(etype .. ': d not encodable: ' .. tostring(denc)); return nil end
    if denc == '[]' then denc = '{}' end
    if denc:sub(1, 1) ~= '{' then violation(etype .. ': d must be an object'); return nil end
    if #denc > 1024 then denc = '{"trunc":1}' end
    st.ev_n = st.ev_n + 1
    local rec = {n = st.ev_n, tick = st.now.tick, type = etype, cls = reg.cls, msg = clean(msg, 200),
                 d = json.decode(denc)}
    st.evbuf[#st.evbuf + 1] = json.encode(rec) .. '\n'
    st.evq[#st.evq + 1] = rec
    if reg.cls == 'A' then st.flush_events_now = true end
    return rec.n
  end
  st.emit_as = emit_as
  -- kernel-emitted A events: identical type+d at most once per 1,200 ticks (CONTRACTS §12)
  local function emit_once(etype, msg, d)
    local key = etype .. json.encode(d or {})
    local last = st.once[key]
    if last and st.now.tick - last < C.TICKS.DAY then return nil end
    st.once[key] = st.now.tick
    return emit_as('kern', etype, nil, msg, d)
  end
  st.emit_once = emit_once

  ------------------------------------------------------------ calls with fault isolation (§3.3)
  local persist_rec   -- forward: refresh persist 'kern'
  -- 3 faults within 10 min back the module off; never disabled for good (CONTRACTS §3.3.5)
  local function fault(e, where, err)
    local msg = tostring(err)
    log_as(e.name, 'error', where .. ': ' .. msg)
    if st.strict then error(e.name .. ' ' .. where .. ': ' .. msg, 0) end
    local now_ms, keep = dfhack.getTickCount(), {}
    if e.last_fault and now_ms - e.last_fault >= KN.backoff_reset_ms then e.backoff = nil end
    e.last_fault = now_ms
    for _, t in ipairs(e.fault_ms) do if now_ms - t < KN.fault_window_ms then keep[#keep + 1] = t end end
    keep[#keep + 1] = now_ms
    e.fault_ms = keep
    if #keep >= KN.fault_n and not e.disabled then
      local cls = e.critical and 'critical' or 'other'
      e.backoff = e.backoff and math.min(e.backoff * 2, KN.backoff_max_ms[cls]) or KN.backoff_ms[cls]
      e.disabled, e.cont, e.disabled_until, e.fault_ms = true, false, now_ms + e.backoff, {}
      emit_as('kern', 'KERN_FAULT', 'A', e.name .. ' backed off ' .. e.backoff // 1000 .. ' s after ' .. #keep .. ' faults',
              {module = e.name, err = clean(first_line(msg), 120), n = #keep, backoff_s = e.backoff // 1000})
      persist_rec()
      st.flush_req, st.persist_now = true, true
    end
  end

  -- slow calls (> 5 ms on the cost clock) decay after 10 min; 3 of them demote a non-critical module
  -- (factor x2, KERNEL_SLOW) or raise KERN_FAULT 'slow' for a critical one (at most once per 10 min);
  -- 10 min without a slow call halves the factor again (CONTRACTS §3.3.6)
  local function charge(e, where, ms)
    if NO_CHARGE[where] then return end
    local t = dfhack.getTickCount()
    if e.factor > 1 and t - (e.last_slow or t) >= KN.promote_ms then
      e.factor, e.last_slow = e.factor // 2, t
      log_as('kern', 'info', e.name .. ' promoted to x' .. e.factor)
      st.flush_req = true
    end
    if ms <= KN.slow_ms then return end
    e.last_slow = t
    local keep = {}
    for _, s in ipairs(e.slow_ms) do if t - s < KN.slow_window_ms then keep[#keep + 1] = s end end
    keep[#keep + 1] = t
    e.slow_ms = keep
    if #keep < KN.slow_n then return end
    e.slow_ms = {}
    local msr = round(ms)
    if e.critical then
      if not e.slow_fault or t - e.slow_fault >= KN.slow_window_ms then
        e.slow_fault = t
        emit_as('kern', 'KERN_FAULT', 'A', e.name .. ' slow (' .. msr .. ' ms)', {module = e.name, err = 'slow', n = KN.slow_n})
      end
    elseif e.factor < KN.max_factor then
      e.factor = e.factor * 2
      emit_as('kern', 'KERNEL_SLOW', 'B', e.name .. ' demoted x' .. e.factor, {module = e.name, ms = msr, factor = e.factor})
      st.flush_req = true
    end
  end

  local child_ms = 0
  local function call_in(e, where, f, ...)
    local prev, saved = st.current, child_ms
    st.current, child_ms = e.name, 0
    local t0 = cost_ms()
    local r = table.pack(xpcall(f, debug.traceback, K, ...))
    local dt = cost_ms() - t0
    local self_ms = dt - child_ms
    st.current, child_ms = prev, saved + dt
    e.ms_total = e.ms_total + self_ms
    st.p.mods[e.name] = (st.p.mods[e.name] or 0) + self_ms
    if self_ms > st.frame_top_ms then st.frame_top_ms, st.frame_top = self_ms, e.name end
    if not r[1] then fault(e, where, r[2]); return false, r[2] end
    charge(e, where, self_ms)
    return table.unpack(r, 1, r.n)
  end
  st.call_in = call_in
  st.frame_top_ms, st.frame_top = 0, nil

  ------------------------------------------------------------ persist, act
  local papi, pstore = persistlib.new{who = function() return st.current end, violation = violation,
                                      log = function(level, msg) log_as('kern', level, msg) end}
  st.pstore = pstore
  local function as_kern(f, ...)
    local prev = st.current
    st.current = 'kern'
    local r = table.pack(pcall(f, ...))
    st.current = prev
    if not r[1] then log_as('kern', 'error', tostring(r[2])) end
    return table.unpack(r, 2, r.n)
  end
  st.as_kern = as_kern
  persist_rec = function()
    if not st.marked then return end
    local dis = {}
    for _, e in ipairs(st.entries) do if e.disabled then dis[#dis + 1] = e.name end end
    as_kern(papi.set, 'kern', {v = 2, ev = st.ev_n, seq = st.seq, boots = st.boots or 0, disabled = json.array(dis)})
  end
  st.persist_rec = persist_rec

  K.act = actlib.new{
    who = function() return st.current end,
    allowlist = function() return st.cfg and st.cfg.allowlist or actlib.BUILTIN_ALLOWLIST end,
    log_cmd = log_cmd,
    fail = function(fn, err, module)
      local key = 'ACT_FAIL' .. fn .. module .. err
      local last = st.once[key]
      if last and st.now.tick - last < C.TICKS.DAY then return end
      st.once[key] = st.now.tick
      emit_as('kern', 'ACT_FAIL', 'B', 'act.' .. fn .. ' failed for ' .. module .. ': ' .. err,
              {fn = fn, err = err, module = module})
    end,
  }

  ------------------------------------------------------------ K (§4)
  function K.now() return st.now end
  function K.emit(etype, cls, msg, d) return emit_as(st.current, etype, cls, msg, d) end
  function K.mode() return st.mode end
  function K.mode_since() return st.mode_since end
  K.persist = papi
  function K.log(level, fmt, ...)
    if not LEVELS[level] then return violation('bad log level ' .. tostring(level)) end
    local ok, msg = pcall(string.format, tostring(fmt), ...)
    log_as(st.current, level, ok and msg or tostring(fmt))
  end
  function K.call(name, fn, ...)
    local e = st.mods[name]
    if not e then return false, 'no module' end
    if e.disabled then return false, 'disabled' end
    local f = e.M[fn]
    if type(f) ~= 'function' then return false, 'no function ' .. tostring(fn) end
    return call_in(e, 'call ' .. tostring(fn), f, ...)
  end
  function K.view() return st.view or {} end
  function K.manifest() return papi.get('manifest') or {v = 2} end
  function K.flush() st.flush_req = true end
  function K.enabled(name) local e = st.mods[name]; return e ~= nil and not e.disabled end

  function K.set_mode(m, why)
    if st.in_mode_cb then return false, 'reentrant' end
    local from = st.mode
    if m == from then return true, 'unchanged' end
    if not C.TRANSITIONS[from] or not C.TRANSITIONS[from][m] then
      return violation('mode transition ' .. from .. '>' .. tostring(m) .. ' not allowed')
    end
    local who = st.current
    if who ~= nil and who ~= 'kern' then
      local rule = C.MODE_SETTERS[who]
      if rule == nil or (rule ~= '*' and not rule[from .. '>' .. m]) then
        return violation(who .. ' may not set mode ' .. from .. '>' .. m)
      end
    end
    st.mode, st.mode_since = m, st.now.tick
    as_kern(papi.set, 'mode', {v = 2, mode = m, since = st.now.tick, why = clean(why, 200), prev = from})
    st.in_mode_cb = true
    local ev = {from = from, to = m, why = why, tick = st.now.tick}
    for _, e in ipairs(st.entries) do
      if not e.disabled and e.M.on and e.M.on.MODE then call_in(e, 'on.MODE', e.M.on.MODE, ev) end
    end
    st.in_mode_cb = false
    emit_as('kern', 'MODE', 'C', from .. '>' .. m .. ' ' .. tostring(why or ''), {from = from, to = m, why = clean(why, 60)})
    st.flush_req, st.persist_now, st.flush_events_now = true, true, true
    return true
  end

  return st
end

---------------------------------------------------------------- module registry
local function load_module(o, name)
  if type(o.modules) == 'table' then
    if o.modules[name] then return o.modules[name] end
    for _, m in ipairs(o.modules) do if type(m) == 'table' and m.name == name then return m end end
    return nil
  end
  local ok, mod = pcall(require, 'dfllm.' .. name)
  if not ok then
    if not tostring(mod):find("module 'dfllm." .. name .. "' not found", 1, true) then return nil, mod end
    return nil
  end
  return mod
end

local function register(st, mod, idx)
  local name = type(mod) == 'table' and mod.name
  if type(name) ~= 'string' or not (MODULE_INDEX[name] or name:match('^test_')) then
    st.log_as('kern', 'error', 'module table without a contract name: ' .. tostring(name)); return nil
  end
  if not valid_every(mod.every) then
    st.log_as('kern', 'error', name .. '.every must be {ticks=N} or {ms=N}'); return nil
  end
  if st.mods[name] then return st.mods[name] end
  local c = mod.critical
  if c == nil and MODULE_INDEX[name] then c = MODULE_INDEX[name].critical end
  local e = {name = name, M = mod, order = idx, factor = 1, slow_ms = {}, critical = c == true,
             fault_ms = {}, ms_total = 0, cont = false, slice = 0}
  st.mods[name] = e
  st.entries[#st.entries + 1] = e
  return e
end

-- load contract modules (or opts.modules for tests: {name = table} map or list of tables)
local function load_all(st)
  local o = st.opts
  if type(o.modules) == 'table' and #o.modules > 0 then
    for i, mod in ipairs(o.modules) do
      local name = type(mod) == 'table' and mod.name
      local idx = 100 + i
      for j, m in ipairs(C.MODULES) do if m.name == name then idx = j end end
      register(st, mod, idx)
    end
  else
    for i, m in ipairs(C.MODULES) do
      local mod, err = load_module(o, m.name)
      if mod then
        if type(mod) ~= 'table' or mod.name ~= m.name then
          st.log_as('kern', 'error', 'dfllm.' .. m.name .. ' does not return its module table')
        else register(st, mod, i) end
      elseif err then
        st.log_as('kern', 'error', 'loading dfllm.' .. m.name .. ': ' .. first_line(err))
      else
        st.log_as('kern', 'info', 'module ' .. m.name .. ' not present')
      end
    end
  end
  table.sort(st.entries, function(a, b) return a.order < b.order end)
  for _, e in ipairs(st.entries) do
    local on = e.M.on or {}
    if on.REPORT then
      if type(e.M.reports) == 'table' then
        for t in pairs(e.M.reports) do st.report_types[t] = true end
      else st.report_any = true end
    end
    for k in pairs(on) do
      local t = type(k) == 'string' and k:match('^EV:(.+)$')
      if t then st.ev_listen[t] = true end
    end
  end
end

---------------------------------------------------------------- files
-- append one line buffer; on failure keep it (oldest lines dropped beyond max_lines, counted in
-- st.dropped) and retry at the next flush. Returns the buffer to keep.
local function flush_buf(st, buf, path, max_bytes, max_lines)
  local ok, err, rot_err = fio.append(path, table.concat(buf), max_bytes)
  local keep = buf
  if ok then
    keep, st.io_warned[path] = {}, nil
  else
    if not st.io_warned[path] then
      st.io_warned[path] = true
      dfhack.printerr('dfllm: ' .. fio.basename(path) .. ': ' .. tostring(err) .. ' (kept, retrying)')
    end
    local over = #buf - max_lines
    if over > 0 then
      table.move(buf, over + 1, #buf, 1)
      for i = #buf, #buf - over + 1, -1 do buf[i] = nil end
      st.dropped = st.dropped + over
    end
  end
  if rot_err and not st.rot_warned[path] then         -- once per file until a rotation succeeds again
    st.rot_warned[path] = true
    local line = string.format('%d\t%d\twarn\tkern\trotation of %s failed (appending anyway): %s\n',
                               os.time(), st.now.tick, fio.basename(path), oneline(rot_err))
    local lb = (buf == st.logbuf) and keep or st.logbuf
    lb[#lb + 1] = line
  elseif ok and not rot_err then st.rot_warned[path] = nil end
  return keep
end

local function flush_files(st, force)
  local p = st.paths
  local dir = st.marked and p.save or p.runtime
  if #st.evbuf > 0 then
    if st.marked then st.evbuf = flush_buf(st, st.evbuf, p.save .. '/events.jsonl', fio.EVENTS_MAX, CAD.evbuf_max)
    else st.evbuf = {} end                       -- an unmarked instance has no events file
  end
  -- logs: the rotation warning above may add a kern.log line, so the log buffer goes after events
  if #st.cmdbuf > 0 then st.cmdbuf = flush_buf(st, st.cmdbuf, dir .. '/commands.log', fio.LOG_MAX, CAD.logbuf_max) end
  if #st.logbuf > 0 then st.logbuf = flush_buf(st, st.logbuf, dir .. '/kern.log', fio.LOG_MAX, CAD.logbuf_max) end
  st.flush_events_now = false
  st.last_ev_flush_ms = st.now.ms
end

-- per-second buckets over the last 10 s (frame ms, frame-to-frame gaps, ticks)
local function bucket(st)
  local now = st.now
  local sec = now.ms // 1000
  local b = st.buckets[#st.buckets]
  if not b or b.sec ~= sec then
    b = {sec = sec, ms = 0, gap = 0, fmax = 0, tick = now.tick, at = now.ms}
    st.buckets[#st.buckets + 1] = b
    if #st.buckets > 10 then table.remove(st.buckets, 1) end
  end
  return b
end

local function window(st)
  local now, bs = st.now, st.buckets
  local first = bs[1]
  if not first then return {ms_s = 0, tps = 0, gap = 0, fmax = 0} end
  local ms, gap, fmax = 0, 0, 0
  for _, b in ipairs(bs) do
    ms, gap, fmax = ms + b.ms, math.max(gap, b.gap), math.max(fmax, b.fmax)
  end
  local secs = math.max(1, bs[#bs].sec - first.sec + 1)
  local span = now.ms - first.at
  local tps = span > 0 and ((now.tick - first.tick) * 1000) // span or 0
  return {ms_s = (ms + secs // 2) // secs, tps = math.max(0, tps), gap = gap, fmax = fmax}
end

local SHRINK = {'proj', 'mil', 'trade', 'care', 'labor', 'stock', 'ready', 'bridges', 'threat', 'pop', 'phase'}

local function compose(st)
  st.seq = st.seq + 1
  local now, w = st.now, window(st)
  local faults, slow, disabled = 0, json.array{}, {}
  for _, e in ipairs(st.entries) do
    for _, t in ipairs(e.fault_ms) do
      if now.ms - t < CAD.fault_window_ms then faults = faults + 1 end
    end
    if e.factor > 1 then slow[#slow + 1] = e.name end
    if e.disabled then disabled[#disabled + 1] = e.name end
  end
  local doc = {v = 2, seq = st.seq, mode = st.mode, ev = st.ev_n, save = st.save_name,
               t = {y = now.year, tick = now.ytick, season = now.season, tps = w.tps, paused = now.paused,
                    abs = now.tick, wall = now.wall, frame = now.frame},
               k = {ms_s = w.ms_s, gap_max_ms = w.gap, slow = slow, faults = faults, ms_max = w.fmax}}
  if #disabled > 0 then doc.k.disabled = disabled end
  for _, e in ipairs(st.entries) do
    if not e.disabled and e.M.state then
      local ok, part = st.call_in(e, 'state', e.M.state)
      if ok and part ~= nil then
        if type(part) ~= 'table' then st.log_as(e.name, 'error', 'contract: state() must return a table')
        else
          for top, v in pairs(part) do
            local is_obj = type(v) == 'table' and not json.is_array(v) and next(v) ~= nil and #v == 0
            if is_obj and state_owner(top) ~= e.name then
              doc[top] = doc[top] or {}
              for sub, sv in pairs(v) do
                if state_owner(top, sub) ~= e.name then
                  st.log_as(e.name, 'error', 'contract: does not own state ' .. top .. '.' .. tostring(sub))
                else doc[top][sub] = sv end
              end
            elseif state_owner(top) ~= e.name then
              st.log_as(e.name, 'error', 'contract: does not own state ' .. tostring(top))
            else doc[top] = v end
          end
        end
      end
    end
  end
  -- schema check (CONTRACTS §9.3, R1): drop invalid optional keys so one module's slip cannot blind
  -- the readers; errors in kern's required keys are logged and the document is written anyway
  local dropped, errs = C.prune_state(doc)
  if #errs > 0 then
    local dk = {}
    for _, k in ipairs(dropped) do dk[k] = true end
    st.prune_warned = st.prune_warned or {}
    for _, err in ipairs(errs) do
      local top = err:match('^%$%.([^.%[:]+)') or '$'
      local sub = err:match('^%$%.[^.%[:]+%.([^.%[:]+)')
      local last = st.prune_warned[top]
      if not last or now.ms - last >= KN.slow_window_ms then      -- once per key per 10 min
        st.prune_warned[top] = now.ms
        local owner = state_owner(top, sub) or 'kern'
        st.log_as(owner, 'error', 'contract: state.' .. top .. (dk[top] and ' dropped: ' or ' invalid: ') .. err)
      end
    end
  end
  local ok, enc = pcall(json.encode, doc)
  if not ok then
    st.log_as('kern', 'error', 'state not encodable: ' .. tostring(enc))
    for _, k in ipairs(SHRINK) do doc[k] = nil end
    enc = json.encode(doc)
  end
  local i = 1
  while #enc > 4096 and SHRINK[i] do
    if doc[SHRINK[i]] ~= nil then
      st.log_as('kern', 'warn', 'state > 4 KB: dropped ' .. SHRINK[i])
      doc[SHRINK[i]] = nil
      enc = json.encode(doc)
    end
    i = i + 1
  end
  st.view = doc
  st.flush_req = false
  st.last_state_ms = now.ms
  if st.marked then
    local slot = (st.seq % 2 == 1) and 'a' or 'b'
    local wok, err = fio.write(st.paths.save .. '/state.' .. slot .. '.json', enc)
    if not wok then st.log_as('kern', 'error', 'state write: ' .. tostring(err)) end
  end
  return doc
end
M._compose = compose

local function heartbeat(st)
  local now = st.now
  st.last_hb_ms = now.ms
  fio.write(st.paths.save .. '/heartbeat', json.encode({v = 2, wall = now.wall, frame = now.frame, tick = now.tick,
                                                        paused = now.paused, mode = st.mode, seq = st.seq}) .. '\n')
end

local function flush_persist(st)
  st.persist_rec()
  st.pstore.flush()
  st.last_persist_ms, st.persist_now = st.now.ms, false
end

---------------------------------------------------------------- inbox (§9.5, §13)
local function reply(st, cmd, ok, msg, data, args)
  local r = {id = cmd.id, ok = ok and true or false, msg = clean(msg, 300), verb = clean(cmd.verb, 40),
             tick = st.now.tick}
  if data ~= nil then
    if type(data) ~= 'table' or data == json.null then data = {value = data}
    elseif next(data) == nil then data = json.object{}                    -- never '[]'
    elseif json.is_array(data) or (#data > 0) then data = {items = data} end
    local okd, enc = pcall(json.encode, data)
    if not okd then r.data = {err = 'unencodable'}
    elseif #enc > 8192 then r.data = {trunc = 1, bytes = #enc}
    else r.data = data end
  end
  local path, err = fio.write_new(st.paths.outbox, cmd.id .. '.json', json.encode(r))
  if not path then st.log_as('kern', 'error', 'outbox ' .. cmd.id .. ': ' .. tostring(err)) end
  local aok, aj = pcall(json.encode, args or json.object{})
  st.log_cmd('inbox:' .. cmd.id .. ':' .. tostring(cmd.by or '?'), 'verb:' .. r.verb,
             aok and trunc(aj, 300) or '"?"', r.ok and 'ok' or ('ERR ' .. r.msg))
  st.emit_as('kern', 'CMD', 'C', r.verb .. ' ' .. (r.ok and 'ok' or 'failed'), {id = cmd.id, verb = r.verb, ok = r.ok and 1 or 0})
  return r
end

local INSPECT = {state = true, modules = true, census = true, manifest = true, projects = true, persist = true,
                 perf = true, mode = true, plan = true}

local function kern_verb(st, verb, args, cmd)
  local K = st.K
  if verb == 'plan.reload' then
    local doc, err = fio.read_json(st.paths.save .. '/plan.json')
    if type(doc) ~= 'table' then return false, 'plan.json: ' .. tostring(err) end
    if doc.v ~= 2 or type(doc.seasons) ~= 'table' or #doc.seasons ~= 4 then return false, 'plan.json is not a v2 plan' end
    local prev = K.persist.get('plan')
    local phases = prev and prev.phases
    K.plan = M.with_defaults(doc, phases)
    st.as_kern(K.persist.set, 'plan', {v = 2, plan = doc, phases = phases or json.null, loaded = st.now.tick})
    local n = 0
    for _, s in ipairs(doc.seasons) do n = n + #(s.build or {}) end
    return true, 'plan y' .. tostring(doc.year) .. ' loaded', {year = doc.year, builds = n}
  end
  if verb == 'module.enable' then        -- CONTRACTS §3.3.5: re-enable now, reset the doubling
    local name = args.module
    if type(name) ~= 'string' or not C.FMT.module(name) then return false, 'bad module name' end
    local e = st.mods[name]
    if not e then return false, 'no module ' .. name end
    local was = e.disabled == true
    enable(st, e, 'verb')
    return true, name .. (was and ' re-enabled' or ' was enabled'), {module = name}
  end
  -- inspect
  local what = args.what
  if not INSPECT[what] then return false, 'bad what' end
  if what == 'state' then return true, 'state', compose(st)
  elseif what == 'mode' then return true, st.mode, {mode = st.mode, since = st.mode_since}
  elseif what == 'census' then return true, 'census', K.census
  elseif what == 'manifest' then return true, 'manifest', K.manifest()
  elseif what == 'plan' then return true, 'plan', K.plan
  elseif what == 'projects' then return true, 'projects', K.persist.get('projects') or json.object{}
  elseif what == 'modules' then
    local r = {}
    for _, e in ipairs(st.entries) do
      r[#r + 1] = {name = e.name, disabled = e.disabled or false, factor = e.factor, ms = round(e.ms_total),
                   faults = #e.fault_ms, every = e.M.every,
                   backoff_s = e.disabled_until and math.max(0, (e.disabled_until - st.now.ms) // 1000) or nil}
    end
    return true, 'modules', {modules = r}
  elseif what == 'persist' then
    if type(args.key) == 'string' then
      if not C.persist_key(args.key) then return false, 'unknown persist key' end
      return true, args.key, K.persist.get(args.key) or json.object{}
    end
    return true, 'persist', {keys = st.pstore.keys()}
  elseif what == 'perf' then
    local w = window(st)
    local d = {ms_s = w.ms_s, tps = w.tps, gap_max_ms = w.gap, ms_max = w.fmax, dropped = st.dropped}
    if st.mods.perf and not st.mods.perf.disabled then
      local ok, ok2, stats = K.call('perf', 'stats')
      if ok and type(stats) == 'table' then d.perf = stats end
    end
    return true, 'perf', d
  end
end

local function handle_inbox(st, name)
  local path = st.paths.inbox .. '/' .. name
  local fid = name:match('^[0-9]+%-([A-Za-z0-9_%-]+)%.json$')
  if fid and #fid > 40 then fid = nil end
  local raw = fio.read(path)
  if raw == nil then st.inbox_retry[name] = nil; return end
  local doc = json.try_decode(raw)
  local function consume()           -- delete after reading; a locked file is answered once only
    st.inbox_retry[name] = nil
    if not fio.remove(path) then
      st.inbox_stuck[name] = true
      st.log_as('kern', 'warn', 'could not delete inbox file ' .. name)
    end
  end
  if type(doc) ~= 'table' or json.is_array(doc) then
    if not st.inbox_retry[name] then st.inbox_retry[name] = true; return 'retry' end
    consume()
    if fid then return reply(st, {id = fid, verb = '?', by = '?'}, false, 'bad json') end
    st.log_as('kern', 'warn', 'dropped unreadable inbox file ' .. name)
    return
  end
  consume()
  local cid = doc.id
  if type(cid) ~= 'string' or #cid > 40 or not cid:match('^[A-Za-z0-9_%-]+$') then
    if fid then return reply(st, {id = fid, verb = tostring(doc.verb), by = '?'}, false, 'bad id') end
    st.log_as('kern', 'warn', 'dropped inbox file without id ' .. name)
    return
  end
  local cmd = {id = cid, verb = tostring(doc.verb), by = doc.by, ts = doc.ts}
  if fid and fid ~= cid then
    cmd.id = fid    -- the writer waits for the file-name id
    return reply(st, cmd, false, 'id does not match file name')
  end
  local spec = C.VERBS[doc.verb]
  if not spec then return reply(st, cmd, false, 'unknown verb') end
  local args = doc.args
  if type(args) ~= 'table' or args == json.null or json.is_array(args) then
    return reply(st, cmd, false, 'args must be an object')
  end
  if not M.BY[doc.by] then return reply(st, cmd, false, 'bad by', nil, args) end
  local vb = C.VERB_BY[doc.verb]               -- `by` is a label; a few verbs only from these origins (§9.5)
  if vb and not vb[doc.by] then return reply(st, cmd, false, cmd.verb .. ' not accepted from ' .. tostring(doc.by), nil, args) end
  if spec.modes and not spec.modes[st.mode] then return reply(st, cmd, false, cmd.verb .. ' not allowed in ' .. st.mode, nil, args) end
  if spec.approve and args.approve ~= true then return reply(st, cmd, false, 'approval required', nil, args) end
  if spec.mod == 'kern' then
    local prev = st.current
    st.current = 'kern'
    local okc, ok, msg, data = pcall(kern_verb, st, cmd.verb, args, cmd)
    st.current = prev
    if not okc then st.log_as('kern', 'error', 'verb ' .. cmd.verb .. ': ' .. tostring(ok)); return reply(st, cmd, false, 'handler error', nil, args) end
    return reply(st, cmd, ok, msg, data, args)
  end
  local e = st.mods[spec.mod]
  if not e then return reply(st, cmd, false, 'no module ' .. spec.mod, nil, args) end
  if e.disabled then return reply(st, cmd, false, 'module disabled', nil, args) end
  local h = e.M.verbs and e.M.verbs[cmd.verb]
  if type(h) ~= 'function' then return reply(st, cmd, false, 'no handler for ' .. cmd.verb, nil, args) end
  local r = table.pack(st.call_in(e, 'verb ' .. cmd.verb, h, args, cmd))
  if not r[1] then return reply(st, cmd, false, 'handler error', nil, args) end
  return reply(st, cmd, r[2], r[3], r[4], args)
end

local function poll_inbox(st)
  local now = st.now
  if #st.inbox_pending == 0 and (st.last_inbox_ms == nil or now.ms - st.last_inbox_ms >= CAD.inbox_ms) then
    st.last_inbox_ms = now.ms
    local names, stuck = {}, {}
    for _, n in ipairs(fio.listdir(st.paths.inbox)) do
      if st.inbox_stuck[n] then stuck[n] = true
      elseif n:sub(1, 1) ~= '.' and n:sub(-5) == '.json' then names[#names + 1] = n end
    end
    st.inbox_stuck = stuck            -- forget files that are finally gone
    table.sort(names)
    st.inbox_pending = names
  end
  local done = 0
  while done < CAD.inbox_per_frame and #st.inbox_pending > 0 do
    local name = table.remove(st.inbox_pending, 1)
    handle_inbox(st, name)
    done = done + 1
  end
end

---------------------------------------------------------------- the frame
local function deliver(st, e, name, ev)
  local h = e.M.on and e.M.on[name]
  if not h then return end
  if name == 'REPORT' and type(e.M.reports) == 'table' and not e.M.reports[ev.type] then return end
  st.call_in(e, 'on.' .. name, h, ev)
end

local function report_event(st, id)
  local rep = df.report.find(id)
  if not rep then return nil end
  local tname = df.announcement_type[rep.type]
  if not tname or not (st.report_any or st.report_types[tname]) then return nil end
  local p = rep.pos
  local has_pos = p and p.x and p.x >= 0
  return {id = id, type = tname, text = clean(dfhack.df2utf(rep.text or ''), 200),
          pos = has_pos and {x = p.x, y = p.y, z = p.z} or nil}
end

local function run_step(st, e, cont)
  local now = st.now
  local ctx = {dt = e.last_tick and (now.tick - e.last_tick) or 0, dt_ms = e.last_ms and (now.ms - e.last_ms) or 0,
               cont = cont, slice = cont and (e.slice + 1) or 1}
  if cont then ctx.dt, ctx.dt_ms = 0, 0 else e.last_tick, e.last_ms = now.tick, now.ms end
  e.slice = ctx.slice
  local ok, r = st.call_in(e, 'step', e.M.step, e.critical and 1 or 2, ctx)
  e.cont = ok and r == 'more' and not e.disabled
end

local function frame(st)
  local t0, c0 = dfhack.getTickCount(), cost_ms()
  st.frame_n = st.frame_n + 1
  local now = st.now
  local prev_tick, prev_start, prev_cost = now.tick, st.frame_start, st.frame_cost or 0
  local g = df.global
  now.year, now.ytick = g.cur_year, g.cur_year_tick
  now.tick = C.abs_tick(now.year, now.ytick)
  now.season = now.ytick // SEASON
  now.ms, now.wall, now.paused, now.frame = t0, os.time(), g.pause_state == true, st.frame_n
  st.frame_start = t0
  local b = bucket(st)
  if prev_start then   -- frame-to-frame gap; blame our own previous frame if it took most of it
    local gap = t0 - prev_start
    if gap > b.gap then b.gap = gap end
    if gap > st.p.gap_max then st.p.gap_max = gap end
    if gap >= CAD.gap_ms then
      st.p.gaps3 = st.p.gaps3 + 1
      local blame = (prev_cost * 2 >= gap) and (st.prev_top or 'kern') or 'external'
      st.log_as('kern', 'warn', string.format('frame gap %d ms (blame %s)', gap, blame))
    end
  end
  st.frame_top_ms, st.frame_top = 0, nil
  local ticking = now.tick > prev_tick
  if ticking and prev_start then st.p.unpaused_ms = st.p.unpaused_ms + (t0 - prev_start) end   -- perf tps
  if now.tick < prev_tick then   -- older save state or clock reset: restart cadences
    for _, e in ipairs(st.entries) do e.last_tick = nil end
  end
  local K = st.K
  for _, e in ipairs(st.entries) do       -- backoff over: re-enable (CONTRACTS §3.3.5)
    if e.disabled and e.disabled_until and t0 >= e.disabled_until then enable(st, e, 'backoff over') end
  end
  st.current = 'kern'
  if ticking and (now.year ~= st.cal_year or now.season ~= st.cal_season) then
    if now.year ~= st.cal_year then
      st.emit_as('kern', 'YEAR_REVIEW', 'A', 'year ' .. st.cal_year .. ' done', {year = st.cal_year})
    end
    st.emit_as('kern', 'SEASON', 'C', 'season ' .. now.season, {year = now.year, season = now.season})
    st.cal_year, st.cal_season = now.year, now.season
  end
  st.current = nil
  -- eventful queue, then events emitted in the previous frame (EV:<TYPE>); both queues are swapped
  -- before delivery, so anything emitted now arrives next frame (no allocation when empty)
  local eq, q = st.evq, st.eventq
  local neq = #eq
  if neq > 0 then st.evq = {} end
  if #q > 0 then
    st.eventq = {}
    for _, item in ipairs(q) do
      local name, ev = item[1], item[2]
      if name == 'REPORT' then
        local okr, rev = pcall(report_event, st, ev.id)
        if not okr then st.log_as('kern', 'warn', 'report ' .. tostring(ev.id) .. ': ' .. first_line(rev)) end
        ev = okr and rev or nil
      end
      if ev then
        ev.tick = now.tick
        for _, e in ipairs(st.entries) do if not e.disabled then deliver(st, e, name, ev) end end
      end
    end
  end
  if neq > 0 then
    for _, rec in ipairs(eq) do
      if st.ev_listen[rec.type] then
        local name = 'EV:' .. rec.type
        for _, e in ipairs(st.entries) do if not e.disabled then deliver(st, e, name, rec) end end
      end
    end
  end
  -- due modules in contract order (§3.3)
  for _, e in ipairs(st.entries) do
    if not e.disabled and e.M.step then
      if e.cont then run_step(st, e, true)
      else
        local ev = e.M.every
        local due
        if type(ev) ~= 'table' then due = false
        elseif ev.ticks then due = ticking and (e.last_tick == nil or now.tick - e.last_tick >= ev.ticks * e.factor)
        else due = e.last_ms == nil or now.ms - e.last_ms >= (ev.ms or 1000) * e.factor end
        if due then run_step(st, e, false) end
      end
    end
  end
  if st.marked then poll_inbox(st) end
  -- housekeeping (real-time cadences)
  if st.flush_req or st.last_state_ms == nil or now.ms - st.last_state_ms >= CAD.state_ms then compose(st) end
  if st.marked and (st.last_hb_ms == nil or now.ms - st.last_hb_ms >= CAD.heartbeat_ms) then heartbeat(st) end
  if st.persist_now or (st.marked and now.ms - st.last_persist_ms >= CAD.persist_ms and st.pstore.dirty()) then
    flush_persist(st)
  end
  if st.flush_events_now or now.ms - st.last_ev_flush_ms >= CAD.events_ms then flush_files(st) end
  local cost = cost_ms() - c0
  st.frame_cost, st.prev_top = cost, st.frame_top
  b.ms = b.ms + cost
  if cost > b.fmax then b.fmax = cost end
  st.p.ms, st.p.frames = st.p.ms + cost, st.p.frames + 1
end

function M._tick()
  local st = S
  if not st then return end
  if not dfhack.isMapLoaded() then M.stop('map gone'); return end   -- missed SC_MAP_UNLOADED
  local ok, err = xpcall(frame, debug.traceback, st)
  if not ok then
    st.current, st.in_mode_cb = nil, false
    st.kern_faults = st.kern_faults + 1
    st.log_as('kern', 'error', 'frame: ' .. tostring(err))
    if st.strict then error(err, 0) end
    st.emit_once('KERN_FAULT', 'kernel frame error', {module = 'kern', err = clean(first_line(err), 120)})
    pcall(flush_files, st)
  end
end

---------------------------------------------------------------- boot, adopt, stop
local function read_marker()
  local raw = dfhack.persistent.getSiteDataString('dfllm')
  if not raw then return nil end
  local m = json.try_decode(raw)
  if type(m) == 'table' and m.v == 2 then return m end
  return nil
end

local function load_cfg(st, repo, marker)
  local decisions = {}
  for k, v in pairs(C.DECISIONS) do decisions[k] = v end
  M.parse_decisions(fio.read(repo .. '/config/decisions.yaml'), decisions)
  local al = fio.read_json(repo .. '/config/allowlist.json')
  if type(al) ~= 'table' or al.v ~= 2 or type(al.commands) ~= 'table' then
    st.log_as('kern', 'warn', 'config/allowlist.json missing or invalid: using the built-in read-only allowlist')
    al = copy(actlib.BUILTIN_ALLOWLIST)
  end
  local okh, armok = pcall(function() return require('helpdb').get_tag_data('armok') end)
  if okh and type(armok) == 'table' then
    local removed = actlib.armok_filter(al, armok)
    if #removed > 0 then
      st.log_as('kern', 'error', 'allowlist: armok commands removed (not in armok_exceptions): ' .. table.concat(removed, ' '))
    end
  else
    st.log_as('kern', 'warn', 'armok cross-check unavailable: ' .. trunc(first_line(armok), 120))
  end
  local base = fio.read_json(repo .. '/config/baseline.json')
  if type(base) ~= 'table' or base.v ~= 2 then base = {v = 2} end
  local p = st.paths
  return {decisions = decisions, allowlist = al, baseline = base,
          paths = {df = p.df, runtime = p.runtime, save = p.save, repo = repo},
          save = st.save_name, dev = os.getenv('DFLLM_DEV') == '1', acceptance = (marker or {}).acceptance == 1}
end

-- highest seq in the state slots / last n in the event files (continue after loading an older save)
local function disk_seq(p)
  local best = 0
  for _, s in ipairs({'a', 'b'}) do
    local d = fio.read_json(p.save .. '/state.' .. s .. '.json')
    if type(d) == 'table' and math.type(d.seq) == 'integer' and d.seq > best then best = d.seq end
  end
  return best
end
local function disk_ev(p)
  local best = 0
  for _, f in ipairs({p.save .. '/events.jsonl', fio.rotated(p.save .. '/events.jsonl')}) do
    local line = fio.last_line(f)
    local d = line and json.try_decode(line)
    if type(d) == 'table' and math.type(d.n) == 'integer' and d.n > best then best = d.n end
  end
  return best
end

local function heal(st, marked)
  local A = load_module(st.opts, 'arbiter')
  if type(A) ~= 'table' or type(A.heal) ~= 'function' then return end
  local e = {name = 'arbiter', M = A, fault_ms = {}, ms_total = 0, factor = 1, slow_ms = {}, critical = true}
  local ok, healed = st.call_in(e, 'heal', A.heal, {marked = marked == true})
  return ok and healed == true
end

-- an unmarked kernel instance: built-in config, logs to the runtime root, persist never flushed.
-- marked: the loaded save carries the marker (dfllm restore on a stopped kernel), so the arbiter may
-- also heal per-save values when restore.json names this save.
local function heal_only(st, repo, marked)
  local p = st.paths
  st.cfg = {decisions = copy(C.DECISIONS), allowlist = copy(actlib.BUILTIN_ALLOWLIST), baseline = {v = 2},
            paths = {df = p.df, runtime = p.runtime, repo = repo}, save = st.save_name, dev = false, acceptance = false}
  st.K.cfg = st.cfg
  if not fio.exists(p.runtime .. '/restore.json') then return false end
  local healed = heal(st, marked)
  if #st.logbuf > 0 or #st.cmdbuf > 0 then flush_files(st) end
  return healed
end

local function fort_name()
  local ok, name = pcall(function()
    local site = dfhack.world.getCurrentSite()
    return dfhack.df2utf(dfhack.translation.translateName(site.name, true))
  end)
  return ok and type(name) == 'string' and name ~= '' and name or 'fort'
end

local function preconditions()
  if not dfhack.isMapLoaded() then return false, 'no map loaded' end
  if dfhack.world and dfhack.world.isFortressMode and not dfhack.world.isFortressMode() then
    return false, 'not in fortress mode'
  end
  local save = save_name()
  if not save or save == '' then return false, 'no save folder' end
  return true, save
end

-- opts: {repo=path, modules=list (tests), strict=bool (tests)}
function M.boot(opts)
  opts = opts or {}
  if S then M.stop('reboot') end
  local ok, save = preconditions()
  if not ok then return false, save end
  local paths = fio.paths(dfhack.getDFPath(), save)
  local marker = read_marker()
  local st = build{opts = opts, paths = paths, save = save, marked = marker ~= nil}
  local repo = opts.repo or '.'
  if not marker then
    -- unmarked save: only heal settings a crashed session left behind; nothing in the save is touched
    heal_only(st, repo, false)
    if fio.exists(paths.runtime .. '/ACTIVE') then fio.remove(paths.runtime .. '/ACTIVE') end
    return false, 'no dfllm marker: save not adopted, kernel idle'
  end
  fio.ensure(paths)
  fio.write(paths.runtime .. '/ACTIVE', save)
  st.cfg = load_cfg(st, repo, marker)
  st.K.cfg = st.cfg
  local K = st.K
  -- persisted kernel state (arbiter.init heals a crashed restore.json before it captures settings)
  local kp = K.persist.get('kern') or {}
  st.boots = (math.tointeger(kp.boots) or 0) + 1
  st.seq = math.max(math.tointeger(kp.seq) or 0, disk_seq(paths))
  st.ev_n = math.max(math.tointeger(kp.ev) or 0, disk_ev(paths))
  local pm = K.persist.get('mode')
  if type(pm) == 'table' and C.TRANSITIONS[pm.mode] then
    st.mode, st.mode_since = pm.mode, math.tointeger(pm.since) or st.now.tick
  else
    st.mode, st.mode_since = 'PEACE', st.now.tick
  end
  local pp = K.persist.get('plan')
  K.plan = M.with_defaults(pp and pp.plan, pp and pp.phases)
  marker.boots = (math.tointeger(marker.boots) or 0) + 1
  st.as_kern(K.persist.set, 'marker', marker)
  if type(kp.disabled) == 'table' and #kp.disabled > 0 then
    st.log_as('kern', 'warn', 'modules disabled last session (re-enabled): ' .. table.concat(kp.disabled, ' '))
  end
  -- modules
  load_all(st)
  for _, e in ipairs(st.entries) do
    if e.M.init then st.call_in(e, 'init', e.M.init) end
  end
  S = st
  -- eventful (enqueue only; registered on SC_MAP_LOADED = this boot)
  local eok, ev = pcall(require, 'plugins.eventful')
  if eok and type(ev) == 'table' then
    local function enqueue(name, item)
      if #st.eventq < CAD.eventq_max then st.eventq[#st.eventq + 1] = {name, item}
      else st.dropped = st.dropped + 1 end
    end
    local want = {INVASION = false, REPORT = st.report_any or next(st.report_types) ~= nil, UNIT_DEATH = false}
    for _, e in ipairs(st.entries) do
      local on = e.M.on or {}
      if on.INVASION then want.INVASION = true end
      if on.UNIT_DEATH then want.UNIT_DEATH = true end
    end
    if want.INVASION then
      ev.enableEvent(ev.eventType.INVASION, 10)
      ev.onInvasion[M.KEY] = function(id) enqueue('INVASION', {id = id}) end
    end
    if want.REPORT then
      ev.enableEvent(ev.eventType.REPORT, 10)
      ev.onReport[M.KEY] = function(id) enqueue('REPORT', {id = id}) end
    end
    if want.UNIT_DEATH then
      ev.enableEvent(ev.eventType.UNIT_DEATH, 100)
      ev.onUnitDeath[M.KEY] = function(id) enqueue('UNIT_DEATH', {unit = id}) end
    end
    st.eventful = ev
  else
    st.log_as('kern', 'error', 'eventful unavailable: ' .. tostring(ev))
  end
  dfhack.onStateChange[M.KEY] = function(code)
    if code == (rawget(_G, 'SC_MAP_UNLOADED') or 3) and S == st then M.stop('unload') end
  end
  st.current = 'kern'
  st.emit_as('kern', 'BOOT', 'C', 'boot ' .. save .. ' #' .. st.boots, {save = clean(save, 120), v = 2, boots = st.boots})
  st.current = nil
  compose(st)
  heartbeat(st)
  flush_persist(st)
  flush_files(st)
  require('repeat-util').scheduleEvery(M.KEY, 1, 'frames', M._tick)
  return true, string.format('booted %s (%d modules, mode %s)', save, #st.entries, st.mode)
end

function M.adopt(opts)
  opts = opts or {}
  local ok, save = preconditions()
  if not ok then return false, save end
  if read_marker() then return M.boot(opts) end
  local tick = abs_now()
  local marker = {v = 2, adopted = tick, save = clean(save, 120), fort = clean(fort_name(), 120),
                  acceptance = opts.acceptance and 1 or 0, baseline = 0, boots = 0}
  dfhack.persistent.saveSiteDataString('dfllm', json.encode(marker))
  local phases = fio.read_json((opts.repo or '.') .. '/plans/year1.json')
  if type(phases) == 'table' and phases.kind == 'phases' then
    dfhack.persistent.saveSiteDataString('dfllm.plan',
      json.encode({v = 2, plan = json.null, phases = phases, loaded = tick}))
  end
  return M.boot(opts)
end

function M.stop(why)
  local st = S
  if not st then return false, 'not running' end
  why = why or 'stop'
  for _, e in ipairs(st.entries) do   -- arbiter restores runtime settings even when disabled
    if not e.disabled or e.name == 'arbiter' then deliver(st, e, 'UNLOAD', {}) end
  end
  st.current = 'kern'
  st.emit_as('kern', 'UNLOAD', 'C', why, nil)
  st.current = nil
  pcall(flush_persist, st)
  pcall(compose, st)
  pcall(heartbeat, st)
  pcall(flush_files, st)
  pcall(function() require('repeat-util').cancel(M.KEY) end)
  if st.eventful then
    st.eventful.onInvasion[M.KEY], st.eventful.onReport[M.KEY], st.eventful.onUnitDeath[M.KEY] = nil, nil, nil
  end
  dfhack.onStateChange[M.KEY] = nil
  fio.remove(st.paths.runtime .. '/ACTIVE')
  S = nil
  return true, why
end

-- dfllm restore: stop a running kernel (its arbiter restores) or heal restore.json without booting
function M.restore(opts)
  opts = opts or {}
  if S then return M.stop('restore') end
  local paths = fio.paths(dfhack.getDFPath(), nil)
  local st = build{opts = opts, paths = paths, save = save_name(), marked = false}
  local okm, mk = pcall(function() return dfhack.isMapLoaded() and read_marker() end)
  if not heal_only(st, opts.repo or '.', okm and type(mk) == 'table') then return false, 'nothing to restore' end
  return true, 'runtime settings restored from restore.json'
end

---------------------------------------------------------------- introspection (dfllm.lua, perf, selftest)
function M.running() return S ~= nil end
function M.K() return S and S.K end

-- deltas since the previous take: frame ms, frames, max gap, gaps >= 3 s, ms per module, and
-- unpaused_ms = sum of the frame-to-frame intervals in which game ticks advanced
function M.perf_take()
  if not S then return nil end
  local p = S.p
  S.p = {ms = 0, frames = 0, gap_max = 0, gaps3 = 0, unpaused_ms = 0, mods = {}}
  p.dropped = S.dropped
  return p
end

function M.status()
  local st = S
  if not st then return nil end
  local w = window(st)
  local mods = {}
  for _, e in ipairs(st.entries) do
    mods[#mods + 1] = {name = e.name, disabled = e.disabled or false, factor = e.factor, ms = round(e.ms_total),
                       faults = #e.fault_ms}
  end
  return {save = st.save_name, mode = st.mode, seq = st.seq, ev = st.ev_n, frame = st.frame_n, boots = st.boots,
          ms_s = round(w.ms_s), tps = round(w.tps), gap_max_ms = round(w.gap), modules = mods, runtime = st.paths.save,
          kern_faults = st.kern_faults, dropped = st.dropped}
end

return M
