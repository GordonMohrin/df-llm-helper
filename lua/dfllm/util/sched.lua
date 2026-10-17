-- Scheduling rules shared by kern and k_mock (CONTRACTS §3.3.6-§3.3.8, FR-62). Pure Lua 5.3, no DFHack:
--   * demotion with hysteresis: 3 slow calls (> 5 ms on the cost clock) within 10 min double a non-critical
--     module's period; it is promoted one step only after promote_ms of quiet *running* time (frames in which it
--     could run) and 3 quiet steps; a demotion within 1 h of a promotion doubles the quiet time the next promotion
--     needs (at most 16x). KERNEL_SLOW is news once per module per REPORT_MS; later demotions are logged only.
--   * pacing: a non-critical module spends at most `share` ms per real second on average (a leaky bucket over
--     every call charged to it, its persist flushes included). While its debt exceeds one second of share, its
--     due runs and its 'more' slices wait: on a big fort a sliced pass takes more frames, not more ms per second.
--     In PEACE the non-critical modules also share a pool: what the 25 ms/s budget leaves after the critical
--     modules and the kernel's housekeeping (at least PACE.pool_min). When the shares of the saturated modules
--     (paced within the last PACE.busy_ms) add up to more than the pool, every share is scaled down by the same
--     factor g (at least PACE.g_min: half a share keeps every module working), so they fit together and none
--     starves. Outside PEACE the shares are PACE.alert_mult times larger and there is no pool (latency over speed).
--     BUG-039 (Run 11 y451: ONE runner step took 68.6 s; its debt of 67,760 ms drained at 2-4 ms per real second, so
--     its run in hand got no slice for hours, 49 game days and counting): the debt is capped at PACE.debt_cap_s
--     seconds of the module's share (boosted: of its boost share), and a due module that waited PACE.floor_ms gets
--     one slice whatever its debt (the pacing floor; S.paced -> false, 'floor'; e.floor_n counts them).
--   * fort-size load: f = max(1, units / LOAD.units, items / LOAD.items) against the reference fort the cadences
--     were tuned on; the cadence of a SCALED module (per-run work grows with items/units) is stretched by f
--     (at most LOAD.stretch_max), and the kernel budget grows with the unit count (critical modules scan every
--     unit and are never paced).
--   * boost (BUG-026, Run 10: a caravan visit was lost because trade, paced and demoted for its cost, ran only every
--     few seconds while its UI phases count real time): a module in BOOST.modules may hold a boost while it must react
--     in real time (trade: a caravan stands at the depot, the trade screen is open). While boosted its cadence ignores
--     the demotion factor and the load stretch, slow calls neither demote it nor count as quiet steps, and it is paced
--     at BOOST.share ms/s (at least its own share x the mode multiplier) outside the PEACE pool; its cost counts as
--     unpaced, so the pool of the other non-critical modules shrinks (they yield). The debt is cut to one second of
--     the share it runs on when a boost begins and when it ends, so the module neither starts the boost waiting for
--     an old debt nor pays for the boosted window afterwards. A boost ends after BOOST.ttl_ms unless renewed. A boost
--     marked busy (trade: the trade screen is open) also asks the heavy background work of the other modules to wait
--     (K.busy(): snapshot exports, seal's background jobs). BUG-033: snapshot may hold a (never busy) boost at
--     BOOST.shares.snapshot while an export someone waits for runs (an inbox request).
local C = require('dfllm.util.contract')
local KN = C.KERN

local S = {}

S.LOAD = {units = 150, items = 6000, stretch_max = 3}
-- ms per real second: 25 on the reference fort, +6 per 150 units above it (Run 9 before FR-62: sense alone took
-- 16 ms/s for 402 units; critical modules keep their latency and are never paced), at most 40
S.BUDGET = {ms_s = 25, per_unit = 6, max = 40}
S.PACE = {share = 2, burst_s = 1, pool_min = 4, g_min = 0.5, alert_mult = 4, busy_ms = 10000,
          shares = {seal = 4, economy = 3, runner = 4, snapshot = 6, trade = 3},
          debt_cap_s = 30, floor_ms = 30000}           -- BUG-039: the debt cap (s of share), the pacing floor
S.SCALED = {economy = true, care = true}
-- BUG-026: who may hold a boost, its pacing share (ms per real second) and how long it lasts without a renewal.
-- BUG-033: snapshot holds one (never busy) while it exports for an inbox request (dfllm audit, bp sites --fresh,
-- follow: a CLI waits for the file), at its own boost share
S.BOOST = {share = 20, ttl_ms = 30000, modules = {trade = true, snapshot = true}, shares = {snapshot = 12}}
S.REPORT_MS = 6 * 3600 * 1000                         -- KERNEL_SLOW per module at most this often
S.PROMOTE_RUNS = 3
S.FLIPS_MAX = 4                                       -- quiet time for a promotion: promote_ms * 2^flips

-- {units, items, f}: units = visible units (sense's census, -1 unknown), items = #world.items.all
function S.load(units, items)
  units, items = math.tointeger(units) or -1, math.tointeger(items) or 0
  local f = math.max(1, units / S.LOAD.units, items / S.LOAD.items)
  return {units = units, items = items, f = math.floor(f * 100 + 0.5) / 100}
end

-- kernel budget (ms per real second) for a fort of this size
function S.budget(load)
  local fu = math.max(1, ((load and load.units) or 0) / S.LOAD.units)
  return math.min(S.BUDGET.max, math.floor(S.BUDGET.ms_s + S.BUDGET.per_unit * (fu - 1) + 0.5))
end

-- scheduling fields of a registry entry e = {name, M, critical, factor, slow_ms}
function S.init(e)
  local m = e.M or {}
  e.share = (type(m.share) == 'number' and m.share > 0) and m.share or S.PACE.shares[e.name] or S.PACE.share
  e.debt, e.debt_at, e.paced_n, e.floor_n = 0, nil, 0, 0
  e.quiet_ms, e.quiet_runs, e.flips = 0, 0, 0
  e.stretch = 1
  return e
end

-- cadence multiplier from the fort size (module field `scale` = true/false overrides S.SCALED)
function S.stretch(e, load)
  local m = e.M or {}
  local on = m.scale
  if on == nil then on = S.SCALED[e.name] == true end
  if not on or e.critical then return 1 end
  return math.min(S.LOAD.stretch_max, (load and load.f) or 1)
end

-- due test of §3.3.2 with the factor and the stretch; ticking = game ticks advanced this frame
function S.due(e, now, ticking)
  local ev = e.M.every
  if type(ev) ~= 'table' then return false end
  local mult = S.period(e)
  if ev.ticks then return ticking and (e.last_tick == nil or now.tick - e.last_tick >= ev.ticks * mult) end
  return e.last_ms == nil or now.ms - e.last_ms >= (ev.ms or 1000) * mult
end

-- cadence multiplier: demotion factor x load stretch; 1 while boosted
function S.period(e) return e.boost and 1 or e.factor * (e.stretch or 1) end

-- the PEACE pool of the non-critical modules: rate (ms per real second) and the share factor g (0-1]
function S.pool() return {rate = S.BUDGET.ms_s, g = 1} end

-- once per second: the pool's rate from the last seconds' cost of everything that is never paced (critical
-- modules, kernel housekeeping), and g = rate / (shares of the saturated modules), at most 1
function S.pool_update(pool, unpaced_ms_s, entries, now_ms)
  pool.rate = math.max(S.PACE.pool_min, S.BUDGET.ms_s - (unpaced_ms_s or 0))
  local sum = 0
  for _, e in ipairs(entries) do
    if not e.critical and not e.disabled and not e.boost and e.waited_at and now_ms - e.waited_at < S.PACE.busy_ms then
      sum = sum + e.share
    end
  end
  pool.g = sum > pool.rate and math.max(S.PACE.g_min, pool.rate / sum) or 1
  return pool.rate
end

-- BUG-039: the most debt e may carry: debt_cap_s seconds of its share (boosted: of its boost share), so one huge
-- call (a 68 s step) costs it at most debt_cap_s seconds of waiting, not hours
function S.cap(e)
  local s = e.share or S.PACE.share
  if e.boost then s = math.max(s, S.BOOST.shares[e.name] or S.BOOST.share) end
  return s * S.PACE.debt_cap_s
end

-- cost of a call charged to e (every call; critical modules are never paced); the debt is capped (BUG-039)
function S.spend(e, ms)
  if not e.critical and ms > 0 then e.debt = math.min(e.debt + ms, S.cap(e)) end
end

local function drain(o, rate, now_ms)          -- leaky bucket: the debt drains at `rate` ms per real second
  local last = o.debt_at
  o.debt_at = now_ms
  if last and o.debt > 0 and now_ms > last then o.debt = math.max(0, o.debt - rate * (now_ms - last) / 1000) end
end

-- the share e is paced at now: boosted, BOOST.share (at least its own share x mult) outside the pool
function S.rate(e, pool, mult)
  if e.boost then return math.max(S.BOOST.shares[e.name] or S.BOOST.share, e.share * (mult or 1)) end
  return e.share * (mult or 1) * (pool and pool.g or 1)
end

-- true when the non-critical module must wait this frame: its debt is over one second of its share, scaled by
-- mult (outside PEACE) or the pool's g (PEACE). BUG-039 pacing floor: a module that has waited floor_ms (real time,
-- since the first frame it was due and had to wait) runs anyway -> false, 'floor' (e.floor_n counts them; the wait
-- starts again with the next frame it must wait). Called only for due modules (a run in hand is due every frame).
function S.paced(e, now_ms, pool, mult)
  if e.critical then return false end
  local share = S.rate(e, pool, mult)
  drain(e, share, now_ms)
  if e.debt > share * S.PACE.burst_s then
    e.waited_at = now_ms
    e.wait0 = e.wait0 or now_ms
    if now_ms - e.wait0 < S.PACE.floor_ms then return true end
    e.floor_n, e.wait0 = (e.floor_n or 0) + 1, nil
    return false, 'floor'
  end
  e.wait0 = nil
  return false
end

-- one charged call of `ms` (cost clock) at real time now_ms (getTickCount). Returns
--   'fault'            a critical module's 3rd slow call (KERN_FAULT 'slow', at most once per slow window)
--   'demote', report   factor doubled; report = true when it is news (first in REPORT_MS for this module)
--   nil                nothing to do
function S.slow(e, ms, now_ms, where)
  if e.boost then return nil end                          -- BUG-026: a boosted module is not demoted
  if ms <= KN.slow_ms then
    if where == 'step' and e.factor > 1 then e.quiet_runs = e.quiet_runs + 1 end
    return nil
  end
  e.quiet_ms, e.quiet_runs, e.last_slow = 0, 0, now_ms
  local keep = {}
  for _, s in ipairs(e.slow_ms) do if now_ms - s < KN.slow_window_ms then keep[#keep + 1] = s end end
  keep[#keep + 1] = now_ms
  e.slow_ms = keep
  if #keep < KN.slow_n then return nil end
  e.slow_ms = {}
  if e.critical then
    if not e.slow_fault or now_ms - e.slow_fault >= KN.slow_window_ms then
      e.slow_fault = now_ms
      return 'fault'
    end
    return nil
  end
  if e.factor >= KN.max_factor then return nil end
  e.factor = e.factor * 2
  if e.promoted_at and now_ms - e.promoted_at < KN.backoff_reset_ms then
    e.flips = math.min(e.flips + 1, S.FLIPS_MAX)          -- demoted again soon after a promotion: a flip
  elseif e.factor == 2 then
    e.flips = 0
  end
  e.demotions = (e.demotions or 0) + 1
  local report = e.reported_at == nil or now_ms - e.reported_at >= S.REPORT_MS
  if report then e.reported_at = now_ms end
  return 'demote', report
end

-- a frame of dt_ms in which the demoted module could run (ticking, or an ms module). Returns true when the
-- module is promoted one step (factor // 2)
function S.quiet(e, dt_ms, now_ms)
  if e.factor <= 1 or dt_ms <= 0 or e.boost then return false end
  e.quiet_ms = e.quiet_ms + dt_ms
  if e.quiet_ms >= KN.promote_ms * (1 << e.flips) and e.quiet_runs >= S.PROMOTE_RUNS then
    e.factor = e.factor // 2
    e.quiet_ms, e.quiet_runs, e.promoted_at = 0, 0, now_ms
    return true
  end
  return false
end

-- quiet time the next promotion of e needs (ms)
function S.quiet_need(e) return KN.promote_ms * (1 << (e.flips or 0)) end

-- BUG-026: e asks for (or renews) a boost. Returns 'new' | 'renew', or nil, why ('critical': never paced anyway;
-- 'not allowed': not in BOOST.modules). why is a short reason (<= 40 bytes, kept for logs and inspect); busy = the
-- other modules' heavy background work should wait meanwhile (set or cleared on every renewal)
function S.boost(e, why, now_ms, busy)
  if e.critical then return nil, 'critical' end
  if not S.BOOST.modules[e.name] then return nil, 'not allowed' end
  local b, new = e.boost, false
  if not b then
    b, new = {since = now_ms, spent = e.ms_total or 0}, true
    e.boost = b
    e.debt = math.min(e.debt, S.rate(e) * S.PACE.burst_s)
  end
  b.why, b.until_ms, b.busy = tostring(why or ''):sub(1, 40), now_ms + S.BOOST.ttl_ms, busy == true
  return new and 'new' or 'renew'
end

-- ends e's boost -> {why, ms (boost length), spent (ms charged while boosted)} or nil when it held none
function S.unboost(e, now_ms)
  local b = e.boost
  if not b then return nil end
  e.boost = nil
  e.debt = math.min(e.debt, e.share * S.PACE.burst_s)
  return {why = b.why, ms = math.max(0, (now_ms or b.since) - b.since), spent = (e.ms_total or 0) - b.spent}
end

-- the boost of e ran out (no renewal within BOOST.ttl_ms): ends it like S.unboost; nil when it still holds
function S.boost_expired(e, now_ms)
  if e.boost and now_ms >= e.boost.until_ms then return S.unboost(e, now_ms) end
  return nil
end

return S
