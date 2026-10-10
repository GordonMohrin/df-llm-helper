-- perf (WP1, 1,000 ms): perf.csv every 30 s (CONTRACTS §9.11), frame-gap freezes and the DEGRADED
-- rule of DESIGN §10: rolling 10-min ticks/s < 60 % of the post-load baseline of the same mode and
-- target fps, or a frame gap (autosave freeze) > 20 s. Kernel timings come from kern.perf_take()
-- (window sums) plus DFHack's own repeat counter (dfhack.internal.getPerfCounters, script-manager.lua:293).
-- Row tps = ticks per *unpaused* second (pauses are not slowness; 0 when < MIN_UNPAUSED_MS ran).
-- Rows more than MAX_PAUSED_PCT paused, or whose target fps changed (inbox tempo.lower), are not
-- used for the DEGRADED rule.
local fio = require('dfllm.io')

local M = {name = 'perf', every = {ms = 1000}}

M.ROW_MS = 30000
M.BASE_ROWS, M.ROLL_ROWS = 10, 20      -- 5 min baseline, 10 min rolling window (30 s rows)
M.DEGRADED_PCT, M.RECOVER_PCT = 60, 80
M.MAX_PAUSED_PCT = 20
M.MIN_UNPAUSED_MS = 1000
M.FREEZE_MS = 20000
M.ROTATE_BYTES = 1024 * 1024
M.HEADER = 'wall,tick,mode,tps,pop,units,items,ms_s,gap_max_ms,gaps3,mods'

local st = {}

local function new_acc() return {ms = 0, frames = 0, gap_max = 0, gaps3 = 0, unpaused_ms = 0, mods = {}} end

-- arbiter's desired timestream fps (WP1-internal K.call); 'na' without an arbiter or with D-11 off
local function target(K)
  local ok, fps = K.call('arbiter', 'target')
  if ok and math.type(fps) == 'integer' then return tostring(fps) end
  return 'na'
end

local function path(K) return K.cfg.paths.save and (K.cfg.paths.save .. '/perf.csv') end

local function vec_len(f)
  local ok, n = pcall(f)
  return ok and math.tointeger(n) or 0
end

local function repeat_ms()
  local ok, ms = pcall(function()
    local per_repeat = select(6, dfhack.internal.getPerfCounters())
    return per_repeat and per_repeat.dfllm
  end)
  if not ok or type(ms) ~= 'number' then return nil end
  return math.tointeger(ms) or math.floor(ms)
end

-- kernel costs come from the cost clock (os.clock ms, fractional): integers only in files (§1.1)
local function ri(x) return math.floor((x or 0) + 0.5) end

local function mods_field(acc, extra)
  local names, parts, sum = {}, {}, 0
  for n, ms in pairs(acc.mods) do
    if ri(ms) > 0 then names[#names + 1] = n end
    sum = sum + ms
  end
  table.sort(names)
  for _, n in ipairs(names) do parts[#parts + 1] = string.format('%s=%d', n, ri(acc.mods[n])) end
  if ri(acc.ms - sum) > 0 then parts[#parts + 1] = string.format('kern=%d', ri(acc.ms - sum)) end
  if extra then parts[#parts + 1] = string.format('repeat=%d', extra) end
  return table.concat(parts, ';')
end

local function write_row(K, r)
  local p = path(K)
  if not p then return end
  if st.rows_written % 120 == 0 then   -- rotate about once an hour at most
    local f = io.open(p, 'rb')
    local size = f and f:seek('end') or 0
    if f then f:close() end
    if size > M.ROTATE_BYTES then
      local old = fio.rotated(p)
      os.remove(old)
      os.rename(p, old)
    end
  end
  local line = string.format('%d,%d,%s,%d,%d,%d,%d,%d,%d,%d,%s\n', r.wall, r.tick, r.mode, r.tps, r.pop, r.units,
                             r.items, r.ms_s, r.gap_max_ms, r.gaps3, r.mods)
  if not fio.exists(p) then line = M.HEADER .. '\n' .. line end
  fio.append(p, line)
  st.rows_written = st.rows_written + 1
end

-- r.key = mode .. ':' .. target fps; baseline and rolling window per key
local function degraded_check(K, r)
  local m = r.key
  st.base_buf[m] = st.base_buf[m] or {}
  if not st.base[m] then
    local b = st.base_buf[m]
    b[#b + 1] = r.tps
    if #b >= M.BASE_ROWS then
      local s = 0
      for _, v in ipairs(b) do s = s + v end
      st.base[m] = s // #b
    end
    return
  end
  local roll = st.roll[m] or {}
  st.roll[m] = roll
  roll[#roll + 1] = r.tps
  if #roll > M.ROLL_ROWS then table.remove(roll, 1) end
  if #roll < M.ROLL_ROWS or st.base[m] <= 0 then return end
  local s = 0
  for _, v in ipairs(roll) do s = s + v end
  local avg = s // #roll
  local pct = avg * 100 // st.base[m]
  if not st.degraded[m] and pct < M.DEGRADED_PCT then
    st.degraded[m] = true
    K.emit('PERF_DEGRADED', 'A', string.format('%s ticks/s %d = %d%% of baseline %d (target %s)', r.mode, avg, pct,
                                               st.base[m], r.target), {tps = avg, base = st.base[m], pct = pct, why = 'tps'})
  elseif st.degraded[m] and pct >= M.RECOVER_PCT then
    st.degraded[m] = false
  end
end

local function new_row_window(K, now)
  st.t0, st.acc = {ms = now.ms, tick = now.tick}, new_acc()
  st.target, st.target_mixed, st.mode0 = target(K), false, K.mode()
end

function M.init(K)
  st = {rows_written = 0, base = {}, base_buf = {}, roll = {}, degraded = {}, last = nil, freeze_tick = nil,
        repeat0 = repeat_ms()}
  new_row_window(K, K.now())
  local kern = package.loaded['dfllm.kern']
  if kern and kern.perf_take then kern.perf_take() end   -- drop boot costs from the first window
end

function M.step(K)
  local now = K.now()
  local kern = package.loaded['dfllm.kern']
  local take = kern and kern.perf_take and kern.perf_take()
  local acc = st.acc
  if target(K) ~= st.target or K.mode() ~= st.mode0 then st.target_mixed = true end
  if take then
    acc.ms, acc.frames, acc.gaps3 = acc.ms + take.ms, acc.frames + take.frames, acc.gaps3 + take.gaps3
    acc.unpaused_ms = acc.unpaused_ms + (take.unpaused_ms or 0)
    if take.gap_max > acc.gap_max then acc.gap_max = take.gap_max end
    for n, ms in pairs(take.mods) do acc.mods[n] = (acc.mods[n] or 0) + ms end
    if take.gap_max >= M.FREEZE_MS and (not st.freeze_tick or now.tick - st.freeze_tick >= 1200) then
      st.freeze_tick = now.tick
      K.emit('PERF_DEGRADED', 'A', string.format('frame freeze %d ms', take.gap_max), {why = 'freeze'})
    end
  end
  local dt_ms = now.ms - st.t0.ms
  if dt_ms < M.ROW_MS then return end
  local census_u = K.census and K.census.u
  local rep = repeat_ms()
  local run_ms = math.min(acc.unpaused_ms, dt_ms)
  local tps = run_ms >= M.MIN_UNPAUSED_MS and math.max(0, (now.tick - st.t0.tick) * 1000 // run_ms) or 0
  local row = {wall = now.wall, tick = now.tick, mode = K.mode(), tps = tps,
               pop = census_u and math.tointeger(census_u.cit) or 0,
               -- only sense may touch world.units (CONTRACTS §1.4): -1 until sense publishes census.u.units
               units = census_u and math.tointeger(census_u.units) or -1,
               items = vec_len(function() return #df.global.world.items.all end),
               ms_s = ri(acc.ms * 1000 / dt_ms), gap_max_ms = ri(acc.gap_max), gaps3 = acc.gaps3,
               mods = mods_field(acc, (rep and st.repeat0) and (rep - st.repeat0) or nil)}
  st.repeat0 = rep
  write_row(K, row)
  local paused_pct = 100 - run_ms * 100 // dt_ms
  if row.tps > 0 and paused_pct <= M.MAX_PAUSED_PCT and not st.target_mixed then
    row.target, row.key = st.target, row.mode .. ':' .. st.target
    degraded_check(K, row)
  end
  st.last = row
  new_row_window(K, now)
end

-- last row plus baselines (inspect perf)
function M.stats(K)
  return {last = st.last, base = st.base}
end

return M
