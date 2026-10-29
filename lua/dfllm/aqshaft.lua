-- aqshaft: FR-95, the aquifer pass. A library, not a kernel module (like zonelib/orderlib): the runner hosts it
-- (runner.work hands every `aqshaft` project to A.work; breach/lost/REPORT hand a damp report to A.observe; end_run calls
-- A.tick). It reads tiles through the runner's snapshot.tile only (revealed tiles; `aq` is the aquifer flag of a REVEALED
-- tile, what the vanilla drip icon shows the player, DECISIONS 2026-10-28; hidden tiles answer nil) and changes the game
-- through quickfort only (the player's dig, smooth and build designations).
-- Mechanics (aquifer research 2026-10-28, DFHack 53.16 docs): water comes from a natural ROUGH wall with the aquifer flag
-- into the orthogonally adjacent open tiles and the open tile below it; a smoothed wall is no longer rough, a constructed
-- wall is never an aquifer, soil cannot be smoothed. Light aquifers fill slowly and can be walled off; heavy ones fill at
-- once. DF cancels a dig designation on the discovery of damp stone; the DFHack dig tool's damp marker (the mining
-- toolbar's "damp dig" mode, quickfort `marker = {damp = true}`) keeps it: the acknowledgement a player gives.
-- 1. aqshaft {x, y, top, dry_levels, depth, mode}: per level DIG (damp marker) -> SEAL (stone: smooth the 4 orthogonal
--    walls, priority 1; soil: dig a plus shape, constructed walls on its 4 arms, economy's building material) -> WATCH
--    (the centre tile's flow for watch ticks); the next level only once the seal stands and the flow is <= flow_ok (or
--    stays <= stable_max without rising for watch_max: standing water, no source). Only one level is open at a time. A level
--    with no damp report, no revealed aquifer wall and no water is dry: no seal. Passed (AQ_PASS_DONE) after dry_levels
--    dry levels below the last aquifer level, or at the shaft's depth.
-- 2. Observe mode (any other dig): a damp report starts it instead of a park (AQ_OBSERVE); the cancelled designation
--    comes back with the damp marker, the natural rough walls beside each damp tile are smoothed once it is dug, seepage
--    <= runner seep_max goes on (AQ_SEEP).
-- 3. Heavy aquifer (both): visible water in our own dug tiles at >= heavy (4/7) or rising (rise samples in a row, each
--    higher, all wet) stops the project for good (breach:heavy_aquifer), plugs a shaft (CAVERN_PLUG) and says AQ_HEAVY (A).
-- Persist m.runner.aq[proj] (shaft): {k = 'shaft', mode, x, y, top, cur_z, aqn, dry, heavy, dz = {[z] = 1} damp levels,
-- levels = {[z] = {state = dig|seal|watch|passed|dry|heavy, opened, samples, seal_tiles = {{x, y, z, kind, st}},
-- material, ws, rd, seep}}}; (observe): {k = 'obs', mode = 'observe', t, n, pts = {{x, y, z, st}}, wet = {['x,y,z'] =
-- {flows}}, heavy}. Events: AQ_OBSERVE, AQ_LEVEL_SEALED, AQ_SEEP, AQ_PASS_DONE (B), AQ_HEAVY (A).
local json = require('dfllm.util.json')

local A = {}
local DAY = 1200
A.CFG = {
  on = true,             -- observe mode for damp reports (false: the old stop at breach:damp)
  watch = DAY,           -- WATCH: the centre tile's flow is sampled this long after the seal stands
  watch_max = 3 * DAY,   -- ... then a stable flow <= stable_max (standing water, nothing rising) passes too
  sample = 300,          -- at most one flow sample per level this often
  flow_ok = 1, stable_max = 3, heavy = 4, rise = 3,
  redig = 12,            -- a lost designation is designated again at most this often (per level / per chunk)
  obs_pts = 16, samples = 8, wet_keep = 6, prio = 1,
  qf_tick = 2,           -- quickfort calls of A.tick per run (observe mode's smoothing)
}
A.MODES = {auto = true, stone = true, soil = true, all = true}
local ORTH = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}}
local OPENED = {S = 'smooth', C = 'wall'}

local function int(v) return math.tointeger(type(v) == 'string' and tonumber(v) or v) end
local function obj(t)
  if type(t) ~= 'table' or t == json.null or (json.is_array(t) and #t > 0) then return json.object{} end
  return json.object(t)
end
local function key(x, y, z) return x .. ',' .. y .. ',' .. z end
local function flow_of(v)
  if type(v) ~= 'table' then return 0 end
  if v.c == '~' or v.c == 'w' then return int(v.flow) or (v.c == '~' and 7 or 2) end
  return 0
end
local function cell1(k) return {[0] = {[0] = {[0] = k}}} end

-- the aqshaft record of P (made on first use from the document's params)
function A.shaft(X, P, d)
  local r = X.rt.aq[P.id]
  if type(r) == 'table' and r.k == 'shaft' then return r end
  local p = type(d.params) == 'table' and d.params or {}
  local an = type(d.anchor) == 'table' and d.anchor or {}
  local mode = A.MODES[p.mode] and p.mode or 'auto'
  r = {k = 'shaft', mode = mode, x = int(p.x) or int(an[1]), y = int(p.y) or int(an[2]),
       top = int(p.top) or int(an[3]), dry_levels = math.max(1, int(p.dry_levels) or 2), cur_z = int(p.top) or int(an[3]),
       aqn = 0, dry = 0, heavy = false, dz = json.object{}, levels = json.object{}, lv = {}}
  if (int(r.x) or -1) < 0 then r.x, r.y, r.top, r.cur_z = int(an[1]), int(an[2]), int(an[3]), int(an[3]) end
  X.rt.aq[P.id] = r
  X.dirty()
  return r
end

local function level(r, z)
  r.levels = obj(r.levels)
  local L = r.levels[tostring(z)]
  if type(L) ~= 'table' then
    L = {state = 'dig', samples = {}, seal_tiles = {}, material = ''}
    r.levels[tostring(z)] = L
  end
  if type(L.samples) ~= 'table' then L.samples = {} end
  if type(L.seal_tiles) ~= 'table' then L.seal_tiles = {} end
  return L
end

-- rising: the last `rise` samples each higher than the one before, all wet
local function rising(s)
  local n = #s
  if n < A.CFG.rise then return false end
  for i = n - A.CFG.rise + 1, n do
    if (s[i] or 0) <= 0 or (i > n - A.CFG.rise + 1 and s[i] <= s[i - 1]) then return false end
  end
  return true
end
A.rising = rising

local function push(list, v, cap)
  list[#list + 1] = v
  while #list > cap do table.remove(list, 1) end
end

---------------------------------------------------------------- the lined shaft
local function heavy(X, P, d, r, z, L, f, why, pos)
  r.heavy, L.state = true, 'heavy'
  X.block(P, 'breach:heavy_aquifer')
  local plug = X.plug(P, d, pos)
  local msg = string.format('%s: heavy aquifer at z%d (flow %d/7%s): stopped for good, shaft plugged (%s)', P.id, z, f,
                            why == 'rising' and ', rising' or '', plug or 'see CAVERN_PLUG')
  X.emit('AQ_HEAVY', 'A', msg, {proj = P.id, z = z, flow = f, why = why, pos = pos, plug = plug})
  X.log('warn', '%s', msg)
  X.dirty()
  return true
end

-- the flow in our own dug tiles of this level (the centre, the dug arms of a soil seal), sampled at most every sample
-- ticks; true when it is a heavy aquifer (handled)
local function check_level(X, P, d, r, z, L)
  if not L.opened or L.state == 'passed' or L.state == 'dry' then return false end
  local t = X.now()
  if L.st and t - L.st < A.CFG.sample then return false end
  local f, at = flow_of(X.tile(r.x, r.y, z)), {r.x, r.y, z}
  for _, p in ipairs(L.seal_tiles) do
    if p[4] == 'soil' and p[5] ~= 'new' and p[5] ~= 'des' then
      local fa = flow_of(X.tile(p[1], p[2], p[3]))
      if fa > f then f, at = fa, {p[1], p[2], p[3]} end
    end
  end
  L.st = t
  push(L.samples, f, A.CFG.samples)
  X.moved(P)                                       -- a sample is progress: a watched level is never 'stalled'
  X.dirty()
  if f >= A.CFG.heavy then return heavy(X, P, d, r, z, L, f, 'flow', at) end
  if rising(L.samples) then return heavy(X, P, d, r, z, L, f, 'rising', at) end
  if f > 0 and not L.seep then
    L.seep = 1
    X.emit('AQ_SEEP', 'B', string.format('%s: seepage %d/7 at %d,%d,%d (z%d %s)', P.id, f, at[1], at[2], at[3], z,
                                         L.state), {proj = P.id, z = z, flow = f, pos = at})
  end
  return false
end

local function designate(X, P, x, y, z, k, marker)
  if not X.room() then return nil end
  local ok, st = X.qf{mode = 'dig', data = cell1(k), pos = {x, y, z}, priority = A.CFG.prio,
                      marker = marker and {damp = true} or nil}
  return ok and (type(st) ~= 'table' or (int(st.dig_designated) or 1) > 0)
end

local function aquifer_here(X, r, z, L, v)
  if r.mode == 'all' then return true end
  if L.damp or (type(r.dz) == 'table' and r.dz[tostring(z)]) or flow_of(v) > 0 then return true end
  for _, o in ipairs(ORTH) do
    local n = X.tile(r.x + o[1], r.y + o[2], z)
    if n and n.aq == true then return true end
  end
  return false
end

-- the seal pieces of a level: the 4 orthogonal tiles (kind stone | soil | ok | open | wait)
local function seal_pieces(X, r, z)
  local out, soil, stone = {}, 0, 0
  for _, o in ipairs(ORTH) do
    local x, y = r.x + o[1], r.y + o[2]
    local n = X.tile(x, y, z)
    local kind
    if not n then kind = 'wait'
    elseif n.c == '#' then
      kind = (r.mode == 'soil' or (r.mode ~= 'stone' and n.soilmat == true)) and 'soil' or 'stone'
    elseif OPENED[n.c] then kind = 'ok'
    else kind = 'open' end
    if kind == 'soil' then soil = soil + 1 elseif kind == 'stone' then stone = stone + 1 end
    out[#out + 1] = {x, y, z, kind, (kind == 'ok' or kind == 'open') and 'done' or 'new'}
  end
  local mat = (soil > 0 and stone > 0) and 'mixed' or soil > 0 and 'soil' or 'stone'
  return out, mat, soil
end

function A.next_level(X, P, d, r, z)
  if r.aqn > 0 and r.dry >= r.dry_levels then return A.pass_done(X, P, d, r, z) end
  X.next(P, d)
  return 'done'
end

function A.pass_done(X, P, d, r, z)
  r.done, r.bot = 1, z
  local lv = {}
  for _, v in ipairs(type(r.lv) == 'table' and r.lv or {}) do lv[#lv + 1] = v end
  local dd = {proj = P.id, top = r.top, bot = z, n = #lv}
  if #lv > 0 then dd.lv = lv end
  X.emit('AQ_PASS_DONE', 'B', string.format('%s: the shaft %d,%d z%d-%d passed %s', P.id, r.x, r.y, r.top, z,
                                            #lv > 0 and ('the aquifer (levels ' .. table.concat(lv, ',') .. ')')
                                            or 'no aquifer'), dd)
  X.dirty()
  X.finish(P, d)
  return 'done'
end

local function dig_step(X, P, d, r, z, L)
  local st = d.stages[P.stage + 1]
  local ch = st.chunks[1]
  local k = ch.cells[1][4]
  if not L.des then
    if not designate(X, P, ch.pos[1] + ch.cells[1][1], ch.pos[2] + ch.cells[1][2], ch.pos[3] + ch.cells[1][3], k, true) then
      return X.room() and 'done' or 'yield'
    end
    L.des, P.chunk = 1, 1
    X.moved(P)
    X.dirty()
    return 'done'
  end
  local v = X.tile(r.x, r.y, z)
  if not v then return 'done' end                   -- hidden: the stair above is not dug yet
  if v.c == '#' or v.c == 'S' then
    if v.dig == '' then                              -- DF took the designation (damp stone): the marker says go on
      if (int(L.rd) or 0) >= A.CFG.redig then
        X.block(P, 'breach:damp')
        X.log('warn', '%s: z%d designation lost %d times: stopped (breach:damp)', P.id, z, L.rd)
        return 'done'
      end
      if designate(X, P, r.x, r.y, z, k, true) then
        L.rd, L.damp = (int(L.rd) or 0) + 1, 1
        X.log('warn', '%s: z%d damp stone designated again with the damp marker (%d/%d)', P.id, z, L.rd, A.CFG.redig)
        X.dirty()
      end
    end
    return 'done'
  end
  L.opened = X.now()
  X.moved(P)
  if not aquifer_here(X, r, z, L, v) then
    L.state = 'dry'
    if r.aqn > 0 then r.dry = r.dry + 1 end
    X.dirty()
    return A.next_level(X, P, d, r, z)
  end
  local pieces, mat, soil = seal_pieces(X, r, z)
  L.state, L.seal_tiles, L.material, L.aq = 'seal', pieces, mat, 1
  if soil > 0 then
    local via, why = X.mat(soil)
    L.mat = via and tostring(via) or ('none: ' .. tostring(why or '?'))
  end
  X.level(z)
  X.log('info', '%s: aquifer at z%d (%s walls): sealing level %d before the next', P.id, z, mat, z)
  X.dirty()
  check_level(X, P, d, r, z, L)
  if r.heavy then return 'done' end
  return A.seal_step(X, P, d, r, z, L)
end

-- one quickfort call for the pieces in `list` (cells relative to the shaft centre on z): true when it went through
local function batch(X, r, z, mode, k, list, marker)
  local data = {[0] = {}}
  for _, p in ipairs(list) do
    local dy, dx = p[2] - r.y, p[1] - r.x
    data[0][dy] = data[0][dy] or {}
    data[0][dy][dx] = k
  end
  local ok, st = X.qf{mode = mode, data = data, pos = {r.x, r.y, z}, priority = mode == 'dig' and A.CFG.prio or nil,
                      marker = marker and {damp = true} or nil}
  if not ok then return false end
  local n = type(st) == 'table' and int(mode == 'dig' and st.dig_designated or st.build_designated) or nil
  return n == nil or n > 0
end

-- the state of one seal piece from its tile (new -> des -> [soil: dug -> wall] -> done); kind 'wait' is classified once
-- the tile is revealed
local function piece_state(X, r, p)
  local v = X.tile(p[1], p[2], p[3])
  if not v then return end
  if p[4] == 'wait' then
    p[4] = v.c == '#' and ((r.mode == 'soil' or (r.mode ~= 'stone' and v.soilmat == true)) and 'soil' or 'stone')
           or (OPENED[v.c] and 'ok' or 'open')
    if p[4] == 'ok' or p[4] == 'open' then p[5] = 'done'; return true end
  end
  local st, was = p[5], p[5]
  if p[4] == 'stone' then
    if st == 'des' then
      if v.c ~= '#' then st = 'done'                      -- smoothed (or dug out by someone: no rough wall left)
      elseif v.dig == '' then st = 'new' end              -- the designation was lost: smoothed again
    end
  elseif p[4] == 'soil' then
    if v.c == 'C' then st = 'done'
    elseif st == 'des' and v.c ~= '#' then st = 'dug'
    elseif st == 'des' and v.dig == '' then st = 'new' end      -- a planned wall waits for buildingplan's material
  end
  p[5] = st
  return st ~= was and st ~= 'new'
end

function A.seal_step(X, P, d, r, z, L)
  local left, smooth, arms, walls = 0, {}, {}, {}
  for _, p in ipairs(L.seal_tiles) do
    if p[5] ~= 'done' then
      if piece_state(X, r, p) then X.moved(P) end
      if p[5] == 'new' and p[4] == 'stone' then smooth[#smooth + 1] = p
      elseif p[5] == 'new' and p[4] == 'soil' then arms[#arms + 1] = p
      elseif p[5] == 'dug' then walls[#walls + 1] = p end
      if p[5] ~= 'done' then left = left + 1 end
    end
  end
  for _, job in ipairs({{smooth, 'dig', 's', false, 'des'}, {arms, 'dig', 'd', true, 'des'},
                        {walls, 'build', 'Cw', false, 'wall'}}) do
    if #job[1] > 0 then
      if not X.room() then X.dirty(); return 'yield' end
      if batch(X, r, z, job[2], job[3], job[1], job[4]) then
        for _, p in ipairs(job[1]) do p[5] = job[5] end
        X.moved(P)
      end
    end
  end
  X.dirty()
  if left > 0 then return 'done' end
  L.state, L.ws = 'watch', X.now()
  local n = 0
  for _, p in ipairs(L.seal_tiles) do if p[4] == 'stone' or p[4] == 'soil' then n = n + 1 end end
  local f = L.samples[#L.samples] or 0
  local how = L.material == 'stone' and 'stone' or L.material
  X.emit('AQ_LEVEL_SEALED', 'B', string.format('%s: z%d sealed (%s, %d walls), flow %d/7: watching %d day%s', P.id, z, how,
                                               n, f, A.CFG.watch // DAY, A.CFG.watch // DAY == 1 and '' or 's'),
         {proj = P.id, z = z, how = how, n = n, flow = f, mat = L.mat})
  return 'done'
end

local function watch_step(X, P, d, r, z, L)
  local t, f = X.now(), L.samples[#L.samples] or 0
  local ws = int(L.ws) or t
  local ok = t - ws >= A.CFG.watch and #L.samples >= 2 and f <= A.CFG.flow_ok
  local stable = t - ws >= A.CFG.watch_max and f <= A.CFG.stable_max and not rising(L.samples)
  if not (ok or stable) then return 'done' end
  L.state = 'passed'
  r.aqn, r.dry = r.aqn + 1, 0
  r.lv = type(r.lv) == 'table' and r.lv or {}
  r.lv[#r.lv + 1] = z
  X.log('info', '%s: z%d sealed and %s (flow %d/7): next level', P.id, z, ok and 'dry' or 'stable', f)
  X.dirty()
  return A.next_level(X, P, d, r, z)
end

-- runner.work for an aqshaft project: 'done' or 'yield'. meas/hold (a measure-only pass, a paused project): only the
-- heavy watch, nothing designated
function A.work(X, P, d, meas, hold)
  local r = A.shaft(X, P, d)
  if r.heavy or r.done == 1 then return 'done' end
  if P.stage >= #d.stages then return A.pass_done(X, P, d, r, r.top - #d.stages + 1) end
  local z = r.top - P.stage
  if r.cur_z ~= z then r.cur_z = z; X.dirty() end
  local L = level(r, z)
  if check_level(X, P, d, r, z, L) then return 'done' end
  if meas or hold then return 'done' end
  if L.state == 'dig' then return dig_step(X, P, d, r, z, L)
  elseif L.state == 'seal' then return A.seal_step(X, P, d, r, z, L)
  elseif L.state == 'watch' then return watch_step(X, P, d, r, z, L) end
  return 'done'
end

-- a damp report at pos for an aqshaft: that level is an aquifer level (sealed even without a revealed aquifer wall)
function A.damp_level(X, P, pos)
  local r = X.rt.aq[P.id]
  local z = type(pos) == 'table' and int(pos[3])
  if type(r) ~= 'table' or r.k ~= 'shaft' or not z then return end
  r.dz = obj(r.dz)
  r.dz[tostring(z)] = 1
  X.dirty()
end

---------------------------------------------------------------- observe mode
-- a damp report at pos (src report | cancel | resume | pass) for P: true when P goes on in observe mode (no park)
function A.observe(X, P, pos, src)
  if not A.CFG.on or P.tpl == 'plug' then return false end
  if P.tpl == 'aqshaft' then A.damp_level(X, P, pos); return true end
  local r = X.rt.aq[P.id]
  if type(r) == 'table' and r.heavy then return false end
  local new = type(r) ~= 'table'
  if new then
    r = {k = 'obs', mode = 'observe', t = X.now(), n = 0, pts = {}, wet = json.object{}, heavy = false}
    X.rt.aq[P.id] = r
  end
  r.n = (int(r.n) or 0) + 1
  local x, y, z = int(type(pos) == 'table' and pos[1]), int(type(pos) == 'table' and pos[2]),
                  int(type(pos) == 'table' and pos[3])
  if x and y and z then
    local seen = false
    for _, p in ipairs(r.pts) do if p[1] == x and p[2] == y and p[3] == z then seen = true end end
    if not seen and #r.pts < A.CFG.obs_pts then r.pts[#r.pts + 1] = {x, y, z, 'new'} end
    X.level(z)
  end
  if new then
    local where = x and string.format(' at %d,%d,%d', x, y, z) or ''
    X.emit('AQ_OBSERVE', 'B', string.format('%s (%s): damp stone%s: observe mode (dig on with the damp marker, walls '
                                            .. 'beside it smoothed; stops on water >= %d/7 or rising)', P.id, P.tpl, where,
                                            A.CFG.heavy),
           {proj = P.id, tpl = P.tpl, pos = x and {x, y, z} or nil, z = z, n = r.n, src = src})
  end
  X.dirty()
  return true
end

function A.observing(rt, id)
  local r = type(rt) == 'table' and type(rt.aq) == 'table' and rt.aq[id] or nil
  return type(r) == 'table' and not r.heavy and (r.k == 'obs' or r.k == 'shaft') and r or nil
end

-- a wet own tile t (flow f <= seep_max) of an observing project: AQ_SEEP once, true when the flow rises (heavy)
function A.wet(X, P, t, f)
  local r = A.observing(X.rt, P.id)
  if not r or r.k ~= 'obs' then return false end
  r.wet = obj(r.wet)
  local k = key(t[1], t[2], t[3])
  local s = r.wet[k]
  local first = s == nil
  if type(s) ~= 'table' then
    local n = 0
    for _ in pairs(r.wet) do n = n + 1 end
    if n >= A.CFG.wet_keep then return false end
    s = {}
    r.wet[k] = s
  end
  if s[#s] ~= f then push(s, f, A.CFG.samples) end
  X.dirty()
  if first then
    X.emit('AQ_SEEP', 'B', string.format('%s: seepage %d/7 at %s (observe)', P.id, f, k),
           {proj = P.id, z = t[3], flow = f, pos = {t[1], t[2], t[3]}})
  end
  return rising(s)
end

-- the stop of an observing project (runner.breach, why water: flow >= heavy, or rising): AQ_HEAVY; the runner then
-- stops it as breach:heavy_aquifer and plugs it
function A.heavy_obs(X, P, pos, f, why)
  local r = A.observing(X.rt, P.id)
  if not r then return false end
  r.heavy = true
  local z = type(pos) == 'table' and int(pos[3]) or -1
  X.emit('AQ_HEAVY', 'A', string.format('%s (%s): water %d/7%s in its own dug tiles at %s: heavy aquifer, stopped for '
                                        .. 'good', P.id, P.tpl, f, why == 'rising' and ' and rising' or '',
                                        type(pos) == 'table' and key(pos[1], pos[2], pos[3]) or '?'),
         {proj = P.id, z = z, flow = f, why = why, pos = type(pos) == 'table' and {pos[1], pos[2], pos[3]} or nil})
  X.dirty()
  return true
end

-- end of every run: observe mode's seal: once a reported damp tile is dug, its natural rough stone walls that are not
-- the project's own tiles are smoothed (priority 1, one quickfort call per level; soil walls stay: noted); records of
-- projects that left the list are dropped once nothing is left to do
function A.tick(X)
  local calls, ids = 0, {}
  for id in pairs(X.rt.aq) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local r = X.rt.aq[id]
    if type(r) ~= 'table' then X.rt.aq[id] = nil; X.dirty()
    elseif r.k == 'obs' and not r.heavy then
      local own, open = X.own(id), 0
      for _, p in ipairs(type(r.pts) == 'table' and r.pts or {}) do
        if p[4] == 'new' then
          local v = X.tile(p[1], p[2], p[3])
          if v and v.c ~= '#' and v.c ~= 'S' then
            local data, n, soil = {[0] = {}}, 0, 0
            for _, o in ipairs(ORTH) do
              local x, y = p[1] + o[1], p[2] + o[2]
              local w = (not own or not own[key(x, y, p[3])]) and X.tile(x, y, p[3]) or nil
              if w and w.c == '#' and w.dig == '' then
                if w.soilmat == true then soil = soil + 1
                else
                  data[0][o[2]] = data[0][o[2]] or {}
                  data[0][o[2]][o[1]] = 's'
                  n = n + 1
                end
              end
            end
            if n == 0 or calls < A.CFG.qf_tick then
              if n > 0 then
                calls = calls + 1
                X.qf{mode = 'dig', data = data, pos = {p[1], p[2], p[3]}, priority = A.CFG.prio}
              end
              p[4] = soil > 0 and 'soil' or 'done'
              X.log('info', '%s: observe: %d walls beside the damp tile %d,%d,%d smoothed%s', id, n, p[1], p[2], p[3],
                    soil > 0 and string.format(', %d soil walls watched', soil) or '')
              X.dirty()
            end
          end
          if p[4] == 'new' then open = open + 1 end
        end
      end
      if open == 0 and not X.live(id) then X.rt.aq[id] = nil; X.dirty() end
    end
  end
end

---------------------------------------------------------------- fortcore aquifer=pass
-- the first passed shaft (not heavy): {id, x, y, top, bot} or nil
function A.passed(rt)
  local ids = {}
  for id, r in pairs(type(rt) == 'table' and type(rt.aq) == 'table' and rt.aq or {}) do
    if type(r) == 'table' and r.k == 'shaft' and r.done == 1 and not r.heavy then ids[#ids + 1] = id end
  end
  table.sort(ids)
  local r = ids[1] and rt.aq[ids[1]]
  return r and {id = ids[1], x = r.x, y = r.y, top = r.top, bot = r.bot} or nil
end

return A
