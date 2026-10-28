-- dfllm kernel (CONTRACTS §3-§4, §8-§10, §12-§13; reference semantics: util/k_mock.lua).
-- One repeat-util frame callback dispatches every module; eventful callbacks only enqueue;
-- all files are written from here (state a/b, events, heartbeat, outbox, logs). Boot is a no-op
-- without the site marker, except healing a crashed restore.json (runtime settings, any save).
-- Cost owners (FR-62): every module call is booked to its module (BUG-033: a K.call from one module into
-- another to the CALLER, with the edge 'caller>callee' kept); the kernel's own housekeeping to
-- k.state (state a/b), k.io (event/log files, heartbeat), k.persist (site data; a module's own keys are
-- booked to it), k.inbox (inbox without the verb handlers), k.events (eventful queue without the
-- handlers); the remainder is `kern` (the dispatcher). Pacing, demotion hysteresis, the fort-size
-- load and the boost (BUG-026: K.boost/K.unboost/K.busy) live in util/sched.lua (shared with k_mock).
local json = require('dfllm.util.json')
local C = require('dfllm.util.contract')
local sched = require('dfllm.util.sched')
local fio = require('dfllm.io')
local persistlib = require('dfllm.persist')
local actlib = require('dfllm.act')
local guard = require('dfllm.guard')         -- FR-68: what `dfllm stop` leaves running in a dangerous mode

local M = {}
M.KEY = 'dfllm'
M.BY = {llm = true, gordon = true, cli = true, follow = true, supervise = true, test = true}
M.CAD = {state_ms = 2000, events_ms = 1000, inbox_ms = 500, heartbeat_ms = 5000, persist_ms = 10000,
         inbox_per_frame = 4, slow_ms = 5, fault_window_ms = 600000, eventq_max = 2000, gap_ms = 3000,
         evbuf_max = 5000, logbuf_max = 2000,   -- lines kept while a file cannot be written
         load_ms = 5000,                        -- fort-size load refresh (units from sense, #items.all)
         persist_big_bytes = 8192, persist_big_ms = 60000}   -- big site-data keys: written at most every 60 s
local CAD = M.CAD
-- BUG-070/071 knobs (config/baseline.json "perf", checked by lint --config): {default, min, max}. quiet_s: after a new
-- year or a frame gap that a DF save explains, heavy background work (snapshot exports, seal's background jobs, the timed
-- persist flush) waits this long; 0 = never. carry_days: how long a state key whose module gave nothing is published
-- from its last known value (with its age in `stale`); 0 = never.
M.PERF = {quiet_s = {60, 0, 600}, carry_days = {28, 0, 400}}
function M.perf_cfg(st, key)
  local lim = M.PERF[key]
  local b = st.cfg and st.cfg.baseline
  local p = type(b) == 'table' and b.perf or nil
  local v = type(p) == 'table' and math.tointeger(p[key]) or nil
  if v and v >= lim[2] and v <= lim[3] then return v end
  return lim[1]
end
local KN = C.KERN               -- fault backoff and slowness numbers (CONTRACTS §3.3.5-3.3.6)
local SEASON = C.TICKS.SEASON
local LEVELS = {debug = true, info = true, warn = true, error = true}
local NO_CHARGE = {init = true, heal = true, ['on.UNLOAD'] = true}
local NO_EVERY = {}   -- stands in for an `every` that is not a table: such a module never runs (§3.2)

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

-- BUG-132: the ceiling of a fort without an applied plan follows D-01 (Gordon 2026-10-24: B, R0 cap 100; A keeps 55)
M.NO_PLAN_CEIL = {A = 55, B = 100}
function M.with_defaults(plan, phases_doc, decisions)
  local p = copy(plan)
  if type(p) ~= 'table' or p == json.null then
    local opt = (type(decisions) == 'table' and decisions['D-01'] or C.DECISIONS['D-01']) == 'B' and 'B' or 'A'
    p = {v = 2, year = df.global.cur_year, phase_target = 'P0',
         seasons = {{build = {}}, {build = {}}, {build = {}}, {build = {}}},
         policy = {option = opt, pop_ceiling = M.NO_PLAN_CEIL[opt], beauty = 'used_rooms'}}
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
              buckets = {}, p = {ms = 0, frames = 0, gap_max = 0, gaps3 = 0, unpaused_ms = 0, mods = {}, via = {}},
              dropped = 0, report_any = false, report_types = {}, report_text = {}, ev_listen = {}, kern_faults = 0,
              rot_warned = {}, io_warned = {}, cum = {}, cum_via = {}, cum_ms = 0, load = sched.load(-1, 0),
              pool = sched.pool(), frame_paced = 0, boosts = {}, top_ring = {}, carry = {}, gaps = {}, quiet_until = 0}
  st.now = {tick = abs_now(), ytick = df.global.cur_year_tick, year = df.global.cur_year,
            season = df.global.cur_year_tick // SEASON, ms = dfhack.getTickCount(), wall = os.time(),
            paused = df.global.pause_state == true, frame = 0}
  st.cal_year, st.cal_season = st.now.year, st.now.season
  st.save_seen = o.save                       -- BUG-070: the save folder name DF had at the last look (a rename = a DF save)
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
      st.unboost(e, 'backed off')
      emit_as('kern', 'KERN_FAULT', 'A', e.name .. ' backed off ' .. e.backoff // 1000 .. ' s after ' .. #keep .. ' faults',
              {module = e.name, err = clean(first_line(msg), 120), n = #keep, backoff_s = e.backoff // 1000})
      persist_rec()
      st.flush_req, st.persist_now = true, true
    end
  end

  -- slow calls (> 5 ms on the cost clock) decay after 10 min; 3 of them demote a non-critical module
  -- (factor x2) or raise KERN_FAULT 'slow' for a critical one (at most once per 10 min). KERNEL_SLOW is
  -- emitted once per module per 6 h, later demotions are only logged; promotion needs quiet running
  -- time (frame loop, sched.quiet) that doubles after each flip (CONTRACTS §3.3.6, FR-62)
  -- BUG-033: svc = ms of the call spent in K.calls of other modules: a slow call is judged on the module's own code
  -- (its calls into others are paced as its cost, but neither demote it nor the callee); the messages name the callee
  -- with the most time when there was any (top)
  -- BUG-039: task = what the module said it was doing (M.doing), named in the messages and KERNEL_SLOW d.task
  local function charge(e, where, ms, svc, top, task)
    if NO_CHARGE[where] then return end
    if svc then ms = ms - svc end
    local act, report = sched.slow(e, ms, dfhack.getTickCount(), where)
    if not act then return end
    local msr = round(ms)
    local via = (svc and top and svc >= 1) and string.format('; +%d ms in %s calls', round(svc), top) or ''
    local inw = task and (' in ' .. task) or ''
    if act == 'fault' then
      emit_as('kern', 'KERN_FAULT', 'A', e.name .. ' slow (' .. msr .. ' ms' .. inw .. via .. ')',
              {module = e.name, err = 'slow', n = KN.slow_n})
      return
    end
    if report then
      local why = task and (msr .. ' ms' .. inw .. via) or (via ~= '' and via:sub(3)) or nil
      emit_as('kern', 'KERNEL_SLOW', 'B', e.name .. ' demoted x' .. e.factor .. (why and (' (' .. why .. ')') or ''),
              {module = e.name, ms = msr, factor = e.factor, task = task and trunc(task, 40) or nil})
    else
      log_as('kern', 'info', string.format('%s demoted x%d (%d ms%s%s; already reported; promotion after %d quiet min)',
                                           e.name, e.factor, msr, inw, via, sched.quiet_need(e) // 60000))
    end
    st.flush_req = true
  end

  -- BUG-039: what a module says it is doing (optional M.doing() -> string), asked only after a slow call
  local function doing(e)
    local f = e.M.doing
    if type(f) ~= 'function' then return nil end
    local ok, v = pcall(f)
    return ok and type(v) == 'string' and v ~= '' and clean(v, 80) or nil
  end
  st.doing = doing

  -- cost per owner: the perf window (perf.csv) and the cumulative totals (selftest's 1-min budget check)
  local function book(name, ms)
    st.p.mods[name] = (st.p.mods[name] or 0) + ms
    st.cum[name] = (st.cum[name] or 0) + ms
  end
  st.book = book

  local child_ms = 0
  local svc = nil      -- BUG-033: {ms, by = {callee = ms}} of the K.calls inside the running call_in
  local slow_act = nil -- BUG-039: {fn = 'quickfort place', ms} the slowest act call inside the running call_in
  st.on_act_cost = function(fn, ms, args)
    if slow_act and ms <= slow_act.ms then return end
    local p = fn == 'quickfort' and args and type(args[1]) == 'table' and args[1] or nil
    slow_act = {fn = p and string.format('quickfort %s%s', tostring(p.mode),
                                         (p.command and p.command ~= 'run') and (' ' .. tostring(p.command)) or '') or fn,
                ms = ms}
  end
  -- BUG-039 (Run 11 y451: one runner step took 68.6 s): a call of KN.big_ms or more is named in kern.log: who, where,
  -- what it did (M.doing), its slowest act call and the capped debt; inspect modules `big` keeps the largest
  local function big_call(e, where, ms, task, act)
    if not e.big or ms >= e.big.ms then e.big = {ms = ms, what = trunc(where .. (task and (' ' .. task) or ''), 80), at = st.now.ms} end
    local parts = {}
    if task then parts[#parts + 1] = task end
    if act and act.ms >= 1 then parts[#parts + 1] = string.format('slowest act: %s %d ms', act.fn, round(act.ms)) end
    log_as('kern', 'warn', string.format('%s %s took %d ms%s%s', e.name, where, round(ms),
                                         #parts > 0 and (' (' .. table.concat(parts, '; ') .. ')') or '',
                                         e.critical and '' or string.format('; debt capped at %d ms (%d s of its share)',
                                                                            round(sched.cap(e)), sched.PACE.debt_cap_s)))
  end
  local function call_in(e, where, f, ...)
    local prev, saved, svc0, act0 = st.current, child_ms, svc, slow_act
    st.current, child_ms, svc, slow_act = e.name, 0, nil, nil
    local t0 = cost_ms()
    local r = table.pack(xpcall(f, debug.traceback, K, ...))
    local dt = cost_ms() - t0
    local self_ms = dt - child_ms
    local mine, act = svc, slow_act
    st.current, child_ms, svc, slow_act = prev, saved + dt, svc0, act0
    e.ms_total = e.ms_total + self_ms
    book(e.name, self_ms)
    sched.spend(e, self_ms)
    if not e.critical and not e.boost then st.frame_paced = st.frame_paced + self_ms end
    if self_ms > st.frame_top_ms then st.frame_top_ms, st.frame_top = self_ms, e.name end
    local task = where == 'step' and self_ms > KN.slow_ms and doing(e) or nil
    if self_ms >= KN.big_ms and not NO_CHARGE[where] then big_call(e, where, self_ms, task, act) end
    if not r[1] then fault(e, where, r[2]); return false, r[2] end
    local top, tms = nil, 0
    for k, v in pairs(mine and mine.by or {}) do if v > tms then top, tms = k, v end end
    charge(e, where, self_ms, mine and mine.ms, top, task)
    return table.unpack(r, 1, r.n)
  end
  st.call_in = call_in
  st.frame_top_ms, st.frame_top = 0, nil

  -- BUG-033: a K.call from one module into another (snapshot.tile/liquids/far, runner.dig_backlog, ...) is part of the
  -- CALLER's work: its time stays in the caller's self time (booked and paced there; slow calls are judged on the own
  -- code), so a service module's own pacing debt never grows from queries it did not choose (Run 11: snapshot's debt
  -- from the other modules' tile and water reads kept its exports waiting for months). The callee's share is recorded
  -- as the edge 'caller>callee' (perf.csv, inspect modules `svc`); faults still count against the callee.
  local function call_via(caller, e, where, f, ...)
    local prev, saved, svc0 = st.current, child_ms, svc
    st.current, child_ms, svc = e.name, 0, nil
    local t0 = cost_ms()
    local r = table.pack(xpcall(f, debug.traceback, K, ...))
    local dt = cost_ms() - t0
    local nested = child_ms                    -- handlers inside it, booked to other owners already
    st.current, child_ms, svc = prev, saved + nested, svc0
    local own = dt - nested                    -- (a K.call the callee makes in turn is inside it, edge kept too)
    if svc then svc.ms, svc.by[e.name] = svc.ms + own, (svc.by[e.name] or 0) + own
    else svc = {ms = own, by = {[e.name] = own}} end
    local edge = caller.name .. '>' .. e.name
    st.p.via[edge] = (st.p.via[edge] or 0) + own
    st.cum_via[edge] = (st.cum_via[edge] or 0) + own
    e.svc_ms = (e.svc_ms or 0) + own
    if not r[1] then fault(e, where, r[2]); return false, r[2] end
    return table.unpack(r, 1, r.n)
  end

  -- kernel housekeeping booked as its own owner (k.state, k.io, ...); module calls inside it stay with
  -- the modules (child time). Errors propagate to the frame's xpcall as before.
  local function kern_in(part, f, ...)
    local saved = child_ms
    child_ms = 0
    local t0 = cost_ms()
    local ok, err = pcall(f, ...)
    local dt = cost_ms() - t0
    book(part, dt - child_ms)
    child_ms = saved + dt
    if not ok then error(err, 0) end
  end
  st.kern_in = kern_in

  -- a site-data write is booked to the key's owner module (m.<module>, manifest/projects/bp.* runner, ...):
  -- a module that dirties a big record pays for its encoding; kern's own keys stay in k.persist
  local function charge_key(key, ms)
    local spec = C.PERSIST[key]
    local owner = spec and spec.owner or key:match('^m%.(.+)$') or (key:match('^bp%.') and 'runner')
    local e = owner and st.mods[owner]
    if not e then return end
    book(e.name, ms)
    e.ms_total = e.ms_total + ms
    sched.spend(e, ms)
    if not e.critical and not e.boost then st.frame_paced = st.frame_paced + ms end
    child_ms = child_ms + ms
  end

  ------------------------------------------------------------ persist, act
  -- <save>/manifest.json mirrors the persisted fort manifest for Python (follow's audit, bp sites): no
  -- `inspect manifest` round trip and no 8 KB reply limit (STATUS §6.9, live L1)
  local function write_manifest(v)
    if not st.marked or not st.paths or not st.paths.save then return end
    local ok, enc = pcall(json.encode, v)
    if ok then fio.write(st.paths.save .. '/manifest.json', enc) end
  end
  st.write_manifest = write_manifest
  local papi, pstore = persistlib.new{who = function() return st.current end, violation = violation,
                                      log = function(level, msg) log_as('kern', level, msg) end,
                                      on_flush = function(key, v) if key == 'manifest' then write_manifest(v) end end,
                                      clock = cost_ms, charge = charge_key, now_ms = function() return st.now.ms end,
                                      big = {bytes = CAD.persist_big_bytes, ms = CAD.persist_big_ms}}
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
    local rec = {v = 2, ev = st.ev_n, seq = st.seq, boots = st.boots or 0, disabled = json.array(dis)}
    local carry = {}                                        -- BUG-071: the last known status values (oldest leaf's tick)
    for top, c in pairs(st.carry or {}) do
      local at, v = nil, {}
      for leaf, val in pairs(c.v) do v[leaf] = val; at = math.min(at or c.at[leaf], c.at[leaf]) end
      if at then carry[top] = {at = at, v = v} end
    end
    if next(carry) then rec.carry = carry end
    as_kern(papi.set, 'kern', rec)
  end
  st.persist_rec = persist_rec

  K.act = actlib.new{
    who = function() return st.current end,
    allowlist = function() return st.cfg and st.cfg.allowlist or actlib.BUILTIN_ALLOWLIST end,
    log_cmd = log_cmd,
    clock = cost_ms, on_cost = st.on_act_cost,      -- BUG-039: the slowest act call of a huge step
    fail = function(fn, err, module, what)
      local key = 'ACT_FAIL' .. fn .. module .. err .. tostring(what or '')       -- BUG-068: per command line too
      local last = st.once[key]
      if last and st.now.tick - last < C.TICKS.DAY then return end
      st.once[key] = st.now.tick
      emit_as('kern', 'ACT_FAIL', 'B', 'act.' .. fn .. ' failed for ' .. module .. ': ' .. err ..
              (what and what ~= '' and (' [' .. what .. ']') or ''),
              {fn = fn, err = err, module = module, cmd = what})
    end,
  }

  ------------------------------------------------------------ boost (BUG-026, util/sched.lua)
  -- end e's boost (why: 'unboost', 'expired', 'backed off'); logged with its length and what it cost
  function st.unboost(e, why)
    local r = sched.unboost(e, st.now.ms)
    if not r then return end
    st.boosts[e.name] = nil
    st.log_as('kern', 'info', string.format('%s boost ended (%s; %s) after %d s, %d ms charged', e.name, why, r.why,
                                            r.ms // 1000, round(r.spent)))
  end

  ------------------------------------------------------------ K (§4)
  function K.now() return st.now end
  -- BUG-026: the calling module asks for priority (sched.BOOST) while it must react in real time; renewed by
  -- calling again, it lapses after BOOST.ttl_ms without a renewal; busy: heavy background work waits (K.busy).
  -- -> true, or false, why
  function K.boost(why, busy)
    local e = st.mods[st.current or '']
    if not e then return false, 'no module' end
    local r, err = sched.boost(e, why, st.now.ms, busy)
    if not r then return false, err end
    if r == 'new' then
      st.boosts[e.name] = e
      log_as('kern', 'info', string.format('%s boosted: %s (paced at %d ms/s, not demoted%s)', e.name, e.boost.why,
                                           round(sched.rate(e)), busy and '; background work of the other modules waits'
                                           or ''))
    end
    return true
  end
  function K.unboost()
    local e = st.mods[st.current or '']
    if e and e.boost then st.unboost(e, 'unboost') end
  end
  -- name, why of a module holding a busy boost, or nil: heavy background work (snapshot exports, seal's background
  -- jobs) waits while one holds
  function K.busy()
    for name, e in pairs(st.boosts) do
      local b = e.boost
      if b and b.busy and st.now.ms < b.until_ms then return name, b.why end
    end
    if st.now.ms < st.quiet_until and st.mode == 'PEACE' then return 'save', st.quiet_why end   -- BUG-070: PEACE only
    return nil
  end
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
    local caller = st.mods[st.current or '']
    if caller and caller ~= e then return call_via(caller, e, 'call ' .. tostring(fn), f, ...) end   -- BUG-033
    return call_in(e, 'call ' .. tostring(fn), f, ...)
  end
  function K.view() return st.view or {} end
  function K.manifest() return papi.get('manifest') or {v = 2} end
  function K.flush() st.flush_req = true end
  function K.enabled(name) local e = st.mods[name]; return e ~= nil and not e.disabled end
  -- fort size (FR-62): {units = visible units (sense; -1 unknown), items = #world.items.all, f = load factor >= 1}
  function K.load() local l = st.load; return {units = l.units, items = l.items, f = l.f} end

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
  local e = sched.init{name = name, M = mod, order = idx, factor = 1, slow_ms = {}, critical = c == true,
                       fault_ms = {}, ms_total = 0, cont = false, slice = 0}
  e.stretch = sched.stretch(e, st.load)
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
    if on.REPORT and type(e.M.report_text) == 'table' then
      for _, m in ipairs(e.M.report_text) do st.report_text[#st.report_text + 1] = tostring(m):lower() end
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

-- per-second buckets over the last 10 s (frame ms, frame-to-frame gaps, ticks); b.paced = the part spent by
-- non-critical (paced) modules. A new second sets the PEACE pool from the unpaced cost (critical modules,
-- kernel housekeeping) of the seconds before (FR-62)
local function bucket(st)
  local now = st.now
  local sec = now.ms // 1000
  local b = st.buckets[#st.buckets]
  if not b or b.sec ~= sec then
    local n, unpaced = 0, 0
    for _, x in ipairs(st.buckets) do n, unpaced = n + 1, unpaced + x.ms - x.paced end
    if n > 0 then sched.pool_update(st.pool, unpaced / n, st.entries, now.ms) end
    b = {sec = sec, ms = 0, paced = 0, gap = 0, fmax = 0, tick = now.tick, at = now.ms}
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

-- BUG-071: pop and stock are what status shows first: they go last (a >4 KB document used to lose stock before ready,
-- bridges and threat). `stale` (the age of a carried value) goes after them: a carried value must never show as a live one.
local SHRINK = {'proj', 'alert', 'mil', 'trade', 'care', 'ready', 'bridges', 'threat', 'labor', 'stock', 'pop', 'stale',
                'phase', 'curse'}      -- BUG-115: a cursed fort's list goes last

-- BUG-071 (Run 13: status showed only the clock line after a year change or a hang): the keys status needs first. When
-- their module gives nothing (disabled, not yet run after a boot: economy publishes stock only after its first daily run)
-- the kernel publishes the last known integer leaf and says how old it is in `stale` (key -> game ticks); the last known
-- values also survive a reboot (persist kern.carry).
M.CARRY = {pop = {'cit', 'adults', 'soldiers'}, stock = {'drink_d', 'food_d', 'meals'}, labor = {'starving', 'idle'}}
function M.carry(st, doc)
  local tick = st.now.tick
  local max = M.perf_cfg(st, 'carry_days') * C.TICKS.DAY
  local stale
  for top, leaves in pairs(M.CARRY) do
    local part = type(doc[top]) == 'table' and doc[top] or nil
    local rec = st.carry[top]
    if not rec then rec = {at = {}, v = {}}; st.carry[top] = rec end
    local filled = false
    for _, leaf in ipairs(leaves) do
      local v = part and part[leaf]
      if math.type(v) == 'integer' then
        rec.v[leaf], rec.at[leaf] = v, tick
      elseif max > 0 and rec.v[leaf] ~= nil and rec.at[leaf] <= tick and tick - rec.at[leaf] <= max then
        if not filled then
          local cp = {}
          for k, x in pairs(part or {}) do cp[k] = x end
          part, filled = cp, true
          doc[top] = cp
        end
        part[leaf] = rec.v[leaf]
        stale = stale or {}
        stale[top] = math.max(stale[top] or 0, tick - rec.at[leaf])
      end
    end
  end
  doc.stale = stale
end

-- BUG-033: the top cost owner of the last minute for state k.top (doctor and status name it in one line), e.g.
-- 'runner 35 (snapshot 20)': the owner's ms per real second and, in brackets, the module its K.calls spent the most
-- in; nil before 10 s of samples. Samples of the cumulative costs are kept every 2 s for 60 s.
M.TOP_MS, M.TOP_EVERY_MS = 60000, 2000
local function top_owner(st)
  local now, ring = st.now.ms, st.top_ring
  local last = ring[#ring]
  if not last or now - last.at >= M.TOP_EVERY_MS then
    local cum, via = {}, {}
    for k, v in pairs(st.cum) do cum[k] = v end
    for k, v in pairs(st.cum_via) do via[k] = v end
    ring[#ring + 1] = {at = now, cum = cum, via = via}
    while #ring > 2 and now - ring[2].at >= M.TOP_MS do table.remove(ring, 1) end
  end
  local first = ring[1]
  local secs = (now - first.at) / 1000
  if secs < 10 then return nil end
  local best, bms = nil, 0
  for k, v in pairs(st.cum) do
    local d = (v - (first.cum[k] or 0)) / secs
    if d > bms or (d == bms and best and k < best) then best, bms = k, d end
  end
  if not best or bms < 0.5 then return nil end
  local callee, cms = nil, 0
  for k, v in pairs(st.cum_via) do
    local a, b = k:match('^([^>]+)>(.+)$')
    local d = (v - (first.via[k] or 0)) / secs
    if a == best and d > cms then callee, cms = b, d end
  end
  local s = string.format('%s %d', best, round(bms))
  if callee and cms >= 0.5 then s = s .. string.format(' (%s %d)', callee, round(cms)) end
  return trunc(s, 40)
end

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
  doc.k.top = top_owner(st)
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
  M.carry(st, doc)
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
  -- I1: K.view() (gate: the caravan window, drill, care, economy, readiness read it) is the complete document; only the
  -- file the readers see is shed to 4 KB. A shallow copy: the shed keys are removed from `doc`, not from the view.
  local full = {}
  for k, v in pairs(doc) do full[k] = v end
  local i = 1
  while #enc > 4096 and SHRINK[i] do
    if doc[SHRINK[i]] ~= nil then
      -- once per key per 10 min (a document that stays too big dropped the same key every 2 s)
      st.prune_warned = st.prune_warned or {}
      local wk = 'shrink.' .. SHRINK[i]
      if not st.prune_warned[wk] or now.ms - st.prune_warned[wk] >= KN.slow_window_ms then
        st.prune_warned[wk] = now.ms
        st.log_as('kern', 'warn', 'state > 4 KB: dropped ' .. SHRINK[i])
      end
      doc[SHRINK[i]] = nil
      enc = json.encode(doc)
    end
    i = i + 1
  end
  st.view = full
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

-- all: every dirty key now (mode change, fault back-off, boot, stop); otherwise big keys wait CAD.persist_big_ms
local function flush_persist(st, all)
  st.persist_rec()
  st.pstore.flush(all)
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
    elseif #enc > 8192 then
      r.data = {trunc = 1, bytes = #enc}
      -- BUG-039 (Run 11: `inspect persist m.runner` read as 'no p key'): the reply says so; a field reads a part
      r.msg = clean(r.msg .. string.format(' (data %d bytes > 8 KB: not sent; ask for one field)', #enc), 300)
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
-- inspect topics a module answers itself: M.inspect(K, what, key) -> ok, msg, data (FR-27 tombs, FR-47 water)
local INSPECT_BY = {tombs = 'care', water_sources = 'water', hospital = 'water', curse = 'care', unit = 'care'}     -- BUG-106: hospital; BUG-115, FR-83: curse, unit

local function kern_verb(st, verb, args, cmd)
  local K = st.K
  if verb == 'plan.reload' and args.phases == true then
    -- live L1b: an adopted fort keeps the phase list of its adopt time; this replaces it with the repo's
    -- plans/year1.json (the plan itself and the current phase id stay; runner re-checks the phase)
    local repo = K.cfg.paths and K.cfg.paths.repo or '.'
    local ph, err = fio.read_json(repo .. '/plans/year1.json')
    if type(ph) ~= 'table' or ph.kind ~= 'phases' or type(ph.phases) ~= 'table' or #ph.phases == 0 then
      return false, 'plans/year1.json: ' .. tostring(err or 'not a phase list')
    end
    local prev = K.persist.get('plan')
    local doc = prev and prev.plan
    if doc == json.null then doc = nil end
    K.plan = M.with_defaults(doc, ph, K.cfg and K.cfg.decisions)
    st.as_kern(K.persist.set, 'plan', {v = 2, plan = doc or json.null, phases = ph, loaded = st.now.tick})
    return true, string.format('phases reloaded (%d)', #ph.phases), {phases = #ph.phases}
  end
  if verb == 'plan.reload' then
    local doc, err = fio.read_json(st.paths.save .. '/plan.json')
    if type(doc) ~= 'table' then return false, 'plan.json: ' .. tostring(err) end
    if doc.v ~= 2 or type(doc.seasons) ~= 'table' or #doc.seasons ~= 4 then return false, 'plan.json is not a v2 plan' end
    local prev = K.persist.get('plan')
    local phases = prev and prev.phases
    K.plan = M.with_defaults(doc, phases, K.cfg and K.cfg.decisions)
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
  local by = type(what) == 'string' and INSPECT_BY[what]
  if by then
    local okc, ok, msg, data = K.call(by, 'inspect', what, args.key)
    if not okc then return false, by .. ': ' .. tostring(ok) end
    return ok == true, tostring(msg or what), data
  end
  if not INSPECT[what] then
    -- a module answers its own `what` (M.inspect[what](K, args) -> ok, msg, data; FR-01/18/40: orders,
    -- workload from economy, trade from trade)
    for _, e in ipairs(st.entries) do
      local f = type(e.M.inspect) == 'table' and e.M.inspect[what]
      if type(what) == 'string' and type(f) == 'function' then
        if e.disabled then return false, 'module disabled' end
        local r = table.pack(st.call_in(e, 'inspect ' .. what, f, args))
        if not r[1] then return false, 'handler error' end
        return r[2], r[3], r[4]
      end
    end
    return false, 'bad what'
  end
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
                   backoff_s = e.disabled_until and math.max(0, (e.disabled_until - st.now.ms) // 1000) or nil,
                   -- FR-62: pacing share (ms/s), current debt, frames it waited, cadence stretch (%), demotion flips
                   share = not e.critical and round(e.share) or nil, debt = not e.critical and round(e.debt) or nil,
                   paced = e.paced_n > 0 and e.paced_n or nil, stretch_pct = round((e.stretch or 1) * 100),
                   flips = e.flips > 0 and e.flips or nil, demotions = e.demotions,
                   boost = e.boost and e.boost.why or nil,
                   -- BUG-033: ms this module spent in K.calls of other modules (booked to the callers)
                   svc = (e.svc_ms or 0) >= 0.5 and round(e.svc_ms) or nil,
                   -- BUG-039: slices the pacing floor gave it; its largest call this boot (>= KN.big_ms)
                   floor = (e.floor_n or 0) > 0 and e.floor_n or nil,
                   big = e.big and {ms = round(e.big.ms), what = e.big.what,
                                    ago_s = math.max(0, (st.now.ms - e.big.at) // 1000)} or nil}
    end
    return true, 'modules', {modules = r, load = M.load_info(st), budget = sched.budget(st.load)}
  elseif what == 'persist' then
    if type(args.key) == 'string' then
      if not C.persist_key(args.key) then return false, 'unknown persist key' end
      local v = K.persist.get(args.key)
      -- BUG-039: one top-level field of a big record (m.runner is over the 8 KB reply limit: `field:'p'`)
      if type(args.field) == 'string' then
        local f = type(v) == 'table' and v[args.field] or nil
        if f == nil then return true, args.key .. '.' .. args.field .. ': none', json.object{} end
        return true, args.key .. '.' .. args.field, type(f) == 'table' and f or {value = f}
      end
      return true, args.key, v or json.object{}
    end
    return true, 'persist', {keys = st.pstore.keys(), bytes = json.object(st.pstore.sizes())}   -- BUG-033: sizes
  elseif what == 'perf' then
    local w = window(st)
    local d = {ms_s = w.ms_s, tps = w.tps, gap_max_ms = w.gap, ms_max = w.fmax, dropped = st.dropped,
               load = M.load_info(st), budget = sched.budget(st.load), pool_ms_s = round(st.pool.rate),
               pool_pct = round(st.pool.g * 100)}
    -- BUG-070: the last frame gaps >= 3 s with their cause (module, save, external), and the quiet window
    local gl = {}
    for i, g in ipairs(st.gaps) do gl[i] = {wall = g.wall, tick = g.tick, ms = round(g.ms), cause = g.cause, task = g.task} end
    d.gaps = json.array(gl)
    d.quiet_s = math.max(0, (st.quiet_until - st.now.ms) // 1000)
    d.quiet_why = d.quiet_s > 0 and st.quiet_why or nil
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
-- BUG-115: a module that names report texts (M.report_text) gets a report of ANY announcement type whose text holds one
-- of them: the type of "has been cursed by" is not known offline. (care, curse texts)
local function text_hit(markers, low)
  for _, m in ipairs(markers) do if low:find(m, 1, true) then return true end end
  return false
end

local function deliver(st, e, name, ev)
  local h = e.M.on and e.M.on[name]
  if not h then return end
  if name == 'REPORT' and type(e.M.reports) == 'table' and not e.M.reports[ev.type]
     and not (ev.low and type(e.M.report_text) == 'table' and text_hit(e.M.report_text, ev.low)) then return end
  st.call_in(e, 'on.' .. name, h, ev)
end

local function report_event(st, id)
  local rep = df.report.find(id)
  if not rep then return nil end
  local tname = df.announcement_type[rep.type]
  local wanted = tname and (st.report_any or st.report_types[tname])
  local low
  if #st.report_text > 0 then            -- also for a type some module lists: the text may name another module's markers
    low = tostring(rep.text or ''):lower()
    wanted = wanted or text_hit(st.report_text, low)
  end
  if not wanted then return nil end
  local p = rep.pos
  local has_pos = p and p.x and p.x >= 0
  return {id = id, type = tname or '?', text = clean(dfhack.df2utf(rep.text or ''), 200),
          pos = has_pos and {x = p.x, y = p.y, z = p.z} or nil, low = low}
end

local function run_step(st, e, cont)
  local now = st.now
  local ctx = {dt = e.last_tick and (now.tick - e.last_tick) or 0, dt_ms = e.last_ms and (now.ms - e.last_ms) or 0,
               cont = cont, slice = cont and (e.slice + 1) or 1, load = st.load.f}
  if cont then ctx.dt, ctx.dt_ms = 0, 0 else e.last_tick, e.last_ms = now.tick, now.ms end
  e.slice = ctx.slice
  local ok, r = st.call_in(e, 'step', e.M.step, e.critical and 1 or 2, ctx)
  e.cont = ok and r == 'more' and not e.disabled
end

-- eventful queue, then events emitted in the previous frame (EV:<TYPE>); both queues are swapped
-- before delivery, so anything emitted now arrives next frame (no allocation when empty)
local function deliver_queues(st, eq, q)
  local now = st.now
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
  for _, rec in ipairs(eq) do
    if st.ev_listen[rec.type] then
      local name = 'EV:' .. rec.type
      for _, e in ipairs(st.entries) do if not e.disabled then deliver(st, e, name, rec) end end
    end
  end
end

-- fort-size load (FR-62): visible units from sense's census, the item vector's length (no iteration);
-- the cadence stretch of the scaled modules follows it
local function refresh_load(st)
  local cu = st.K.census and st.K.census.u
  local okn, items = pcall(function() return #df.global.world.items.all end)
  local l = sched.load(cu and cu.units or -1, okn and items or 0)
  st.load, st.load_at = l, st.now.ms
  for _, e in ipairs(st.entries) do
    local s = sched.stretch(e, l)
    if s ~= e.stretch then
      if math.abs(s - e.stretch) >= 0.5 or s == 1 then
        st.log_as('kern', 'info', string.format('%s cadence x%.1f for the fort size (%d units, %d items)',
                                                e.name, s, l.units, l.items))
      end
      e.stretch = s
    end
  end
end

local function note_paced(st, e)
  e.paced_n = e.paced_n + 1
  if e.paced_n == 1 then
    st.log_as('kern', 'info', string.format('%s paced: over its share of %s ms/s (debt %d ms); runs and slices wait',
                                            e.name, tostring(e.share), round(e.debt)))
  end
end

-- BUG-039: the pacing floor gave a module that waited PACE.floor_ms one slice whatever its debt (kern.log once per
-- module per 10 min, with the count)
local function note_floor(st, e, cont)
  local t = st.now.ms
  if e.floor_log and t - e.floor_log < KN.slow_window_ms then return end
  e.floor_log = t
  st.log_as('kern', 'warn', string.format('%s waited %d s for a slice%s (debt %d ms over its share of %s ms/s): one slice '
                                          .. 'anyway (pacing floor, %d so far)', e.name, sched.PACE.floor_ms // 1000,
                                          cont and ' with its run in hand' or '', round(e.debt), tostring(e.share),
                                          e.floor_n or 0))
end

-- BUG-070 (Run 13 y456/y483: freezes of 24-27 s at the year change and at saves, 13 gaps > 3 s, max 172 s): a frame gap
-- of CAD.gap_ms or more gets ONE cause. `module` (or kern): our own previous frame took most of it (the top owner, with
-- what it said it was doing); `save`: not ours and a DF save explains it (the save folder was renamed 'autosave N', or the
-- year changed across the gap: the yearly autosave); `external`: not ours and nothing explains it (DF, the OS, a sleep).
-- The cause goes to kern.log ("(blame X)"), the ring `st.gaps` (inspect perf), perf.csv (`gap:<cause>` ms and
-- `gapn:<cause>` count per row) and PERF_DEGRADED d.cause; a `save` also opens the quiet window.
function M.note_gap(st, gap, prev_cost, prev_year)
  local now = st.now
  local cause, extra = 'external', ''
  local sname = save_name()
  if prev_cost * 2 >= gap then
    cause = st.prev_top or 'kern'
    if st.prev_task then extra = ' in ' .. st.prev_task end
  elseif sname and st.save_seen and sname ~= st.save_seen then
    cause, extra = 'save', string.format(' (save folder %s > %s)', st.save_seen, sname)
  elseif now.year ~= prev_year then
    cause, extra = 'save', ' (new year: the yearly autosave)'
  end
  if sname then st.save_seen = sname end
  local p = st.p
  p.gapby, p.gapn = p.gapby or {}, p.gapn or {}
  p.gapby[cause], p.gapn[cause] = (p.gapby[cause] or 0) + gap, (p.gapn[cause] or 0) + 1
  if gap > p.gap_max then p.gap_max, p.gap_cause = gap, cause end
  local ring = st.gaps
  ring[#ring + 1] = {wall = now.wall, tick = now.tick, ms = gap, cause = cause, task = st.prev_task and trunc(st.prev_task, 40) or nil}
  if #ring > 12 then table.remove(ring, 1) end
  st.log_as('kern', 'warn', string.format('frame gap %d ms (blame %s)%s', gap, cause, extra))
  if cause == 'save' then M.quiet(st, 'after a DF save') end
end

-- BUG-070: heavy background work waits for config perf.quiet_s after a new year or a DF-save gap (K.busy() answers 'save':
-- snapshot exports and seal's background jobs wait, the timed persist flush waits); urgent work never does
function M.quiet(st, why)
  local q = M.perf_cfg(st, 'quiet_s')
  if q <= 0 or st.mode ~= 'PEACE' then return end                  -- a fight never waits for a save
  st.quiet_until, st.quiet_why = st.now.ms + q * 1000, why
end

local function frame(st)
  local t0, c0 = dfhack.getTickCount(), cost_ms()
  st.frame_n = st.frame_n + 1
  local now = st.now
  local prev_tick, prev_start, prev_cost, prev_year = now.tick, st.frame_start, st.frame_cost or 0, now.year
  local g = df.global
  now.year, now.ytick = g.cur_year, g.cur_year_tick
  now.tick = C.abs_tick(now.year, now.ytick)
  now.season = now.ytick // SEASON
  now.ms, now.wall, now.paused, now.frame = t0, os.time(), g.pause_state == true, st.frame_n
  st.frame_start = t0
  local b = bucket(st)
  st.frame_paced = 0
  local dt_frame = 0
  if prev_start then   -- frame-to-frame gap; blame our own previous frame if it took most of it
    local gap = t0 - prev_start
    dt_frame = gap
    if gap > b.gap then b.gap = gap end
    if gap >= CAD.gap_ms then
      st.p.gaps3 = st.p.gaps3 + 1
      M.note_gap(st, gap, prev_cost, prev_year)
    elseif gap > st.p.gap_max then st.p.gap_max = gap end
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
  if not st.load_at or t0 - st.load_at >= CAD.load_ms then
    refresh_load(st)
    st.save_seen = save_name() or st.save_seen     -- BUG-070: a rename without a gap is no evidence for the next one
  end
  st.current = 'kern'
  if ticking and (now.year ~= st.cal_year or now.season ~= st.cal_season) then
    if now.year ~= st.cal_year then
      st.emit_as('kern', 'YEAR_REVIEW', 'A', 'year ' .. st.cal_year .. ' done', {year = st.cal_year})
      M.quiet(st, 'new year (the yearly autosave)')
    end
    st.emit_as('kern', 'SEASON', 'C', 'season ' .. now.season, {year = now.year, season = now.season})
    st.cal_year, st.cal_season = now.year, now.season
  end
  st.current = nil
  local eq, q = st.evq, st.eventq
  local neq, nq = #eq, #q
  -- BUG-139 (live i2: two LOCKDOWNs 1-9 ticks apart for every unacked TRANSFORM): both queues are swapped whenever either
  -- is delivered, so an event a handler emits now (care's TRANSFORM from a REPORT) lands in the fresh queue and arrives next
  -- frame once, instead of in the delivered table (same frame) and again next frame
  if neq > 0 or nq > 0 then st.evq, st.eventq = {}, {} end
  if neq > 0 or nq > 0 then st.kern_in('k.events', deliver_queues, st, eq, q) end
  -- due modules in contract order (§3.3); non-critical ones over their share wait (pacing, §3.3.8: in PEACE
  -- also on the pool, elsewhere with larger shares); a demoted module earns its promotion in frames in which
  -- it could run (§3.3.6)
  local peace = st.mode == 'PEACE'
  local pool, mult = peace and st.pool or nil, peace and 1 or sched.PACE.alert_mult
  for _, e in ipairs(st.entries) do
    if not e.disabled and e.M.step then
      local ev = e.M.every
      if type(ev) ~= 'table' then ev = NO_EVERY end
      local ms_mod = ev.ms ~= nil
      if e.boost and t0 >= e.boost.until_ms then st.unboost(e, 'expired') end
      if e.factor > 1 and (ticking or ms_mod) and sched.quiet(e, dt_frame, t0) then
        st.log_as('kern', 'info', e.name .. ' promoted to x' .. e.factor)
        st.flush_req = true
      end
      -- BUG-136: the optional watch pass (M.watch, M.watch_every = {ticks}): its own tick clock, never paced, never demoted,
      -- not stretched, also while a run is in hand (CONTRACTS §3.2)
      local we = e.M.watch_every
      if ticking and type(we) == 'table' and type(e.M.watch) == 'function' and math.type(we.ticks) == 'integer'
         and (e.watch_tick == nil or now.tick < e.watch_tick or now.tick - e.watch_tick >= we.ticks) then
        e.watch_tick = now.tick
        st.call_in(e, 'watch', e.M.watch)
      end
      local cont, due = e.cont, e.cont
      if not cont and ev ~= NO_EVERY then   -- sched.due, inlined: this loop runs every frame
        local per = e.boost and 1 or e.factor * e.stretch      -- sched.period
        if not ms_mod then due = ticking and (e.last_tick == nil or now.tick - e.last_tick >= ev.ticks * per)
        else due = e.last_ms == nil or now.ms - e.last_ms >= ev.ms * per end
      end
      if due then
        local wait, why = false, nil
        if not e.critical then wait, why = sched.paced(e, t0, pool, mult) end
        if wait then note_paced(st, e)
        else
          if why == 'floor' then note_floor(st, e, cont) end
          run_step(st, e, cont)
        end
      end
    end
  end
  if st.marked and (#st.inbox_pending > 0 or st.last_inbox_ms == nil or now.ms - st.last_inbox_ms >= CAD.inbox_ms) then
    st.kern_in('k.inbox', poll_inbox, st)
  end
  -- housekeeping (real-time cadences)
  if st.flush_req or st.last_state_ms == nil or now.ms - st.last_state_ms >= CAD.state_ms then
    st.kern_in('k.state', compose, st)
  end
  if st.marked and (st.last_hb_ms == nil or now.ms - st.last_hb_ms >= CAD.heartbeat_ms) then
    st.kern_in('k.io', heartbeat, st)
  end
  if st.persist_now or (st.marked and now.ms - st.last_persist_ms >= CAD.persist_ms and st.pstore.dirty()
                        and (now.ms >= st.quiet_until or st.mode ~= 'PEACE')) then
    st.kern_in('k.persist', flush_persist, st, st.persist_now)
  end
  if st.flush_events_now or now.ms - st.last_ev_flush_ms >= CAD.events_ms then st.kern_in('k.io', flush_files, st) end
  local cost = cost_ms() - c0
  st.frame_cost, st.prev_top = cost, st.frame_top
  -- BUG-070: a frame this long may be followed by a gap that is ours: remember what its top owner was doing
  st.prev_task = (cost >= 1000 and st.frame_top and st.mods[st.frame_top]) and st.doing(st.mods[st.frame_top]) or nil
  b.ms = b.ms + cost
  b.paced = b.paced + math.min(cost, st.frame_paced)
  if cost > b.fmax then b.fmax = cost end
  st.p.ms, st.p.frames = st.p.ms + cost, st.p.frames + 1
  st.cum_ms = st.cum_ms + cost
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
  -- reflex and clock knobs (FR-51/52/53); a missing or invalid file means the built-in defaults (fail-open)
  local rfx = fio.read_json(repo .. '/config/reflex.json')
  if type(rfx) ~= 'table' or rfx.v ~= 2 then rfx = {v = 2} end
  local p = st.paths
  return {decisions = decisions, allowlist = al, baseline = base, reflex = rfx,
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

-- BUG-121: the newest game tick the runtime folder remembers: the last event (events.jsonl, else its rotation) and the
-- newest state slot (the highest seq: the other slot may still hold an older line). The persisted site data belongs to
-- the loaded save and says nothing about a discarded timeline. nil when the folder holds neither.
local function disk_tick(p)
  local best
  for _, f in ipairs({p.save .. '/events.jsonl', fio.rotated(p.save .. '/events.jsonl')}) do
    local line = fio.last_line(f)
    local d = line and json.try_decode(line)
    if type(d) == 'table' and math.type(d.tick) == 'integer' then best = d.tick; break end
  end
  local seq, tick = -1, nil
  for _, s in ipairs({'a', 'b'}) do
    local d = fio.read_json(p.save .. '/state.' .. s .. '.json')
    if type(d) == 'table' and math.type(d.seq) == 'integer' and d.seq > seq and type(d.t) == 'table' then
      seq, tick = d.seq, math.tointeger(d.t.abs)
    end
  end
  if tick and (not best or tick > best) then best = tick end
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
  st.cfg = {decisions = copy(C.DECISIONS), allowlist = copy(actlib.BUILTIN_ALLOWLIST), baseline = {v = 2}, reflex = {v = 2},
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

-- The runtime folder of a fort is named after the save folder it was adopted in (marker.save), not the
-- folder loaded now: DF renames the save to 'autosave N' at every autosave (live L0/L1), and a folder
-- per name would split bp/, plan.json, snap/ and events across folders every game year. The loaded
-- folder stays in state.save and the BOOT event (supervise loads the newest save by marker).
function M.runtime_key(marker, save)
  local k = type(marker) == 'table' and marker.save
  if type(k) == 'string' and k ~= '' and k ~= '.' and k ~= '..' and not k:find('[/\\]') then return k end
  return save
end

-- opts: {repo=path, modules=list (tests), strict=bool (tests)}
function M.boot(opts)
  opts = opts or {}
  if S then M.stop('reboot') end
  local guarded = guard.remove('boot')       -- FR-68: the kernel takes the clock and the popups back
  local ok, save = preconditions()
  if not ok then return false, save end
  local marker = read_marker()
  local paths = fio.paths(dfhack.getDFPath(), M.runtime_key(marker, save))
  local st = build{opts = opts, paths = paths, save = save, marked = marker ~= nil}
  local repo = opts.repo or '.'
  if guarded then st.log_as('kern', 'info', 'stop guard removed at boot: ' .. guarded) end
  if not marker then
    -- unmarked save: only heal settings a crashed session left behind; nothing in the save is touched
    heal_only(st, repo, false)
    if fio.exists(paths.runtime .. '/ACTIVE') then fio.remove(paths.runtime .. '/ACTIVE') end
    return false, 'no dfllm marker: save not adopted, kernel idle'
  end
  fio.ensure(paths)
  fio.write(paths.runtime .. '/ACTIVE', M.runtime_key(marker, save))
  st.cfg = load_cfg(st, repo, marker)
  st.K.cfg = st.cfg
  local K = st.K
  -- persisted kernel state (arbiter.init heals a crashed restore.json before it captures settings)
  local kp = K.persist.get('kern') or {}
  st.boots = (math.tointeger(kp.boots) or 0) + 1
  if type(kp.carry) == 'table' then            -- BUG-071: the last known status values of the session before
    for top, leaves in pairs(M.CARRY) do
      local c = kp.carry[top]
      if type(c) == 'table' and math.type(c.at) == 'integer' and c.at <= st.now.tick and type(c.v) == 'table' then
        local rec = {at = {}, v = {}}
        for _, leaf in ipairs(leaves) do
          local x = c.v[leaf]
          if math.type(x) == 'integer' and x >= 0 then rec.v[leaf], rec.at[leaf] = x, c.at end
        end
        st.carry[top] = rec
      end
    end
  end
  st.seq = math.max(math.tointeger(kp.seq) or 0, disk_seq(paths))
  st.ev_n = math.max(math.tointeger(kp.ev) or 0, disk_ev(paths))
  -- BUG-121 (Run 14 note 101): the clock stands before what the runtime folder last saw = an older save was loaded.
  -- The marker comes before every other event of this boot; follow, events and brief drop what lies before it, and the
  -- alarm.txt of the discarded line goes (reflex writes the loaded save's own in its first step).
  local tick_alt = disk_tick(paths)
  if tick_alt and st.now.tick < tick_alt then
    local d = {n_alt = st.ev_n, tick_alt = tick_alt, tick_neu = st.now.tick}
    st.current = 'kern'
    st.emit_as('kern', 'TIMELINE_RESET', 'B', string.format(
      'game clock jumped back (older save loaded): tick %d -> %d; events up to #%d belong to the discarded timeline',
      tick_alt, st.now.tick, st.ev_n), d)
    st.current = nil
    fio.remove(paths.save .. '/alarm.txt')
    st.log_as('kern', 'warn', string.format('timeline reset: tick %d -> %d, event numbers continue after #%d',
                                            tick_alt, st.now.tick, st.ev_n))
  end
  local pm = K.persist.get('mode')
  if type(pm) == 'table' and C.TRANSITIONS[pm.mode] then
    st.mode, st.mode_since = pm.mode, math.tointeger(pm.since) or st.now.tick
  else
    st.mode, st.mode_since = 'PEACE', st.now.tick
  end
  local pp = K.persist.get('plan')
  K.plan = M.with_defaults(pp and pp.plan, pp and pp.phases, st.cfg and st.cfg.decisions)
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
  pcall(st.write_manifest, K.manifest())
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
  flush_persist(st, true)
  flush_files(st)
  require('repeat-util').scheduleEvery(M.KEY, 1, 'frames', M._tick)
  return true, string.format('booted %s (%d modules, mode %s)', M.runtime_key(marker, save), #st.entries, st.mode)
end

function M.adopt(opts)
  opts = opts or {}
  local ok, save = preconditions()
  if not ok then return false, save end
  if read_marker() then return M.boot(opts) end
  local tick = abs_now()
  -- runtime key = world save folder + site id: a second fort in the same world (region2) must not reuse
  -- the first fort's runtime folder (plan.json, bp/, events of the abandoned fort; live 2026-10-11)
  local okp, sid = pcall(function() return df.global.plotinfo.site_id end)
  local site_id = okp and math.tointeger(sid) or 0
  local key = clean(save, 100) .. '-site' .. site_id
  local marker = {v = 2, adopted = tick, save = key, fort = clean(fort_name(), 120),
                  acceptance = opts.acceptance and 1 or 0, baseline = 0, boots = 0}
  dfhack.persistent.saveSiteDataString('dfllm', json.encode(marker))
  local phases = fio.read_json((opts.repo or '.') .. '/plans/year1.json')
  if type(phases) == 'table' and phases.kind == 'phases' then
    dfhack.persistent.saveSiteDataString('dfllm.plan',
      json.encode({v = 2, plan = json.null, phases = phases, loaded = tick}))
  end
  return M.boot(opts)
end

-- why: 'stop' (dfllm stop), 'reload', 'reboot', 'restore', 'unload', 'map gone', ...; opts.restore_fps (dfllm stop
-- --restore-fps): restore everything as before FR-68. A plain `dfllm stop` while the fort is in SIEGE/BREACH/ALERT
-- or a reflex lockdown holds the clock keeps the FPS cap and timestream (arbiter on.UNLOAD) and installs the guard.
function M.stop(why, opts)
  local st = S
  if not st then return false, 'not running' end
  why = why or 'stop'
  opts = type(opts) == 'table' and opts or {}
  local ev = {why = why, hold_ok = why == 'stop' and opts.restore_fps ~= true}
  local arb
  for _, e in ipairs(st.entries) do   -- arbiter restores runtime settings even when disabled
    if not e.disabled or e.name == 'arbiter' then deliver(st, e, 'UNLOAD', ev) end
    if e.name == 'arbiter' then arb = e.M end
  end
  local held = type(ev.held) == 'table' and ev.held or nil
  local msg = why
  if held then
    local okg, gmsg = guard.install{mode = st.mode, cap = held.cap, ts_off = held.ts_off, why = held.why,
                                    save = st.marked and st.paths.save or nil,
                                    classify = arb and type(arb.classify) == 'function' and arb.classify or nil}
    msg = string.format('stopped in %s%s: FPS cap held at %d%s; guard %s %s (dismisses blocking popups, keeps '
                        .. 'the clock); dfllm boot resumes, dfllm restore releases the clock (or stop --restore-fps)',
                        st.mode, held.why ~= st.mode and (' (' .. tostring(held.why) .. ')') or '', held.cap,
                        held.ts_off and ', timestream off' or '', guard.KEY, okg and 'runs' or ('FAILED: ' .. tostring(gmsg)))
    st.log_as('kern', 'warn', msg)
  end
  st.current = 'kern'
  st.emit_as('kern', 'UNLOAD', 'C', held and string.format('%s (guard holds FPS cap %d in %s)', why, held.cap, st.mode)
                                    or why, nil)
  st.current = nil
  pcall(flush_persist, st, true)
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
  return true, msg
end

-- dfllm restore: stop a running kernel (its arbiter restores) or heal restore.json without booting; a stop guard
-- (FR-68) ends here too, so the held FPS cap and timestream come back
function M.restore(opts)
  opts = opts or {}
  if S then return M.stop('restore') end
  guard.remove('restore')
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
  S.p = {ms = 0, frames = 0, gap_max = 0, gaps3 = 0, unpaused_ms = 0, mods = {}, via = {}}
  p.dropped = S.dropped
  return p
end

-- cumulative cost since boot (selftest's 1-min budget check): ms = every frame, mods = per owner
-- (modules and the k.* parts), at = getTickCount of the current frame
function M.costs()
  if not S then return nil end
  local mods, via = {}, {}
  for k, v in pairs(S.cum) do mods[k] = v end
  for k, v in pairs(S.cum_via) do via[k] = v end       -- BUG-033: 'caller>callee' ms (inside the caller's mods)
  return {ms = S.cum_ms, at = S.now.ms, mods = mods, via = via}
end

-- fort-size load {units, items, f} and the kernel budget (ms per real second) that fits it (FR-62)
function M.load() return S and S.K.load() or nil end
function M.budget() return S and sched.budget(S.load) or sched.budget(nil) end
function M.load_info(st)
  st = st or S
  if not st then return nil end
  return {units = st.load.units, items = st.load.items, f_pct = round(st.load.f * 100)}
end

function M.status()
  local st = S
  if not st then return nil end
  local w = window(st)
  local mods = {}
  for _, e in ipairs(st.entries) do
    mods[#mods + 1] = {name = e.name, disabled = e.disabled or false, factor = e.factor, ms = round(e.ms_total),
                       faults = #e.fault_ms, paced = e.paced_n, share = not e.critical and e.share or nil,
                       floor = e.floor_n or 0, big = e.big and {ms = round(e.big.ms), what = e.big.what} or nil,
                       boost = e.boost and e.boost.why or nil}
  end
  return {save = st.save_name, mode = st.mode, seq = st.seq, ev = st.ev_n, frame = st.frame_n, boots = st.boots,
          ms_s = round(w.ms_s), tps = round(w.tps), gap_max_ms = round(w.gap), modules = mods, runtime = st.paths.save,
          kern_faults = st.kern_faults, dropped = st.dropped, load = M.load_info(st), budget = sched.budget(st.load)}
end

return M
