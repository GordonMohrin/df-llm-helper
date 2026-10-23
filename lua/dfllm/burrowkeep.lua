-- dfllm.burrowkeep (BUG-096, BUG-097, FR-80): the rules of seal's burrow guard that need no DF (library, no module).
-- Run 14 (note 70): the burrow Kern+ shrank to about one tile and Tiefe+ vanished from plotinfo.burrows.list, nobody saw
-- when or why, and the hospital zone lay outside the alert burrow for the fourth time. seal reads Kern+, the refuge and
-- any other burrow of the manifest once a game day (and at a load) and keeps what it saw in the persist key `burrows`:
--   tiles (base), blocks (nb), the burrow id, and the tiles themselves as RUNS, a flat list {z, y, x0, x1, ...} sorted
--   by z, y, x0 and merged (a fort of 80: some thousand runs, about 14 bytes each in JSON; RUNS_MAX caps it).
-- A reading is a game day apart from the last one and, because a game day lasts 2-12 real seconds at the speeds of the runs
-- and a big burrow costs about a quarter of a second to read, at least `every_s` real seconds (a bound on the cost, not on the news).
-- A reading that falls below `base` by more than shrink_pct % (or a burrow that is gone) opens an EPISODE: the baseline
-- and its runs stay as they were at the last good reading, the loss is announced once (BURROW_SHRUNK, util/cadence),
-- and the tiles of the runs that the burrow lacks are painted again (act.burrow_tiles), at most repair_per_day a game
-- day, the ones next to the hospital, the wells and the refuge first. The episode ends when nothing is left to paint
-- (or, without a repair, when the burrow is above the line again), or settle_days after the last progress.
-- Everything here is pure: seal passes the readings in and the DF reads (`assigned`) as functions.
local M = {}

M.DEF = {on = true, shrink_pct = 30, repair_per_day = 2000, settle_days = 14, every_s = 120}
M.LIM = {shrink_pct = {5, 95}, repair_per_day = {0, 20000}, settle_days = {1, 365}, every_s = {10, 3600}}
M.RUNS_MAX = 8000       -- runs one burrow keeps (about 110 KB of JSON at the most); more: the first RUNS_MAX, kp = 1
M.MIN_TILES = 20        -- a baseline below this is too small to judge by a share (a burrow that is gone is judged)
M.NEAR = 8              -- tiles around a hospital, a well or the refuge anchor whose runs are repainted first

local function int(v) return type(v) == 'number' and math.tointeger(v) or nil end

-- the knobs of config/baseline.json `burrow.guard` (`cfg` = the whole file's table); a value of another type or out of
-- range keeps its default (dfpilot/fairplay.py burrow_errors refuses it in lint --config)
function M.conf(cfg)
  local c = {}
  for k, v in pairs(M.DEF) do c[k] = v end
  local g = type(cfg) == 'table' and type(cfg.burrow) == 'table' and cfg.burrow.guard or nil
  if type(g) ~= 'table' then return c end
  if type(g.on) == 'boolean' then c.on = g.on end
  for k, lim in pairs(M.LIM) do
    local v = int(g[k])
    if v and v >= lim[1] and v <= lim[2] then c[k] = v end
  end
  return c
end

-- rows {{z, y, x0, x1}, ...} -> flat {z, y, x0, x1, ...} sorted by z, y, x0 and merged where runs touch or overlap.
-- Returns flat, tiles (of all runs), runs (all of them), part (true when more than `max` runs: flat holds the first max)
function M.pack(rows, max)
  max = max or M.RUNS_MAX
  table.sort(rows, function(a, b)
    if a[1] ~= b[1] then return a[1] < b[1] end
    if a[2] ~= b[2] then return a[2] < b[2] end
    return a[3] < b[3]
  end)
  local flat, nr, tiles, part = {}, 0, 0, false
  local cz, cy, c0, c1
  local function put()
    if cz == nil then return end
    tiles = tiles + (c1 - c0 + 1)
    nr = nr + 1
    if nr <= max then
      local i = #flat
      flat[i + 1], flat[i + 2], flat[i + 3], flat[i + 4] = cz, cy, c0, c1
    else part = true end
  end
  for _, r in ipairs(rows) do
    if cz == r[1] and cy == r[2] and r[3] <= c1 + 1 then
      if r[4] > c1 then c1 = r[4] end
    else
      put()
      cz, cy, c0, c1 = r[1], r[2], r[3], r[4]
    end
  end
  put()
  return flat, tiles, nr, part
end

function M.size(flat)
  local n = 0
  for i = 1, #flat - 3, 4 do n = n + (flat[i + 3] - flat[i + 2] + 1) end
  return n, #flat // 4
end

function M.has(flat, x, y, z)
  if type(flat) ~= 'table' then return false end
  for i = 1, #flat - 3, 4 do
    if flat[i] == z and flat[i + 1] == y and x >= flat[i + 2] and x <= flat[i + 3] then return true end
  end
  return false
end

function M.same(a, b)
  if a == b then return true end
  if type(a) ~= 'table' or type(b) ~= 'table' or #a ~= #b then return false end
  for i = 1, #a do if a[i] ~= b[i] then return false end end
  return true
end

-- did `now` tiles fall below `was` by more than pct %? A baseline under MIN_TILES is judged only when nothing is left
function M.shrunk(was, now, pct)
  if was <= 0 then return false end
  if now <= 0 then return true end
  return was >= M.MIN_TILES and now * 100 < was * (100 - pct)
end

-- what to do with a reading of one burrow. r = its record (nil: never seen), rd = {exists, n, ...}
--   none | first | ok        no episode: nothing to keep / a new baseline / the baseline moves on
--   shrunk | gone            an episode opens (the burrow lost more than pct %, or is missing)
--   open | recovered         an episode is open: still below the line, or back above it
function M.judge(r, rd, pct)
  if not r then return rd.exists and 'first' or 'none' end
  local below = not rd.exists or M.shrunk(r.base, rd.n, pct)
  if r.ep then return below and 'open' or 'recovered' end
  if not rd.exists then return 'gone' end
  return below and 'shrunk' or 'ok'
end

-- the tiles of `flat` that `assigned(x, y, z)` denies, at most `cap`, the runs within `r` tiles (same level) of one of
-- the points `pts` ({x, y, z}) first. Returns list ({x, y, z}), scanned (tiles looked at), complete (every tile of the
-- runs was looked at: the list is all that is missing)
function M.missing(flat, assigned, cap, pts, r)
  local out, scanned = {}, 0
  if cap <= 0 or type(flat) ~= 'table' then return out, scanned, false end
  local order, rest = {}, {}
  local n = #flat // 4
  for i = 0, n - 1 do
    local z, y, x0, x1 = flat[4 * i + 1], flat[4 * i + 2], flat[4 * i + 3], flat[4 * i + 4]
    local near = false
    for _, p in ipairs(pts or {}) do
      if p[3] == z and math.abs(p[2] - y) <= r and p[1] >= x0 - r and p[1] <= x1 + r then near = true; break end
    end
    if near then order[#order + 1] = i else rest[#rest + 1] = i end
  end
  for _, i in ipairs(rest) do order[#order + 1] = i end
  for _, i in ipairs(order) do
    local z, y, x0, x1 = flat[4 * i + 1], flat[4 * i + 2], flat[4 * i + 3], flat[4 * i + 4]
    for x = x0, x1 do
      scanned = scanned + 1
      if not assigned(x, y, z) then
        out[#out + 1] = {x, y, z}
        if #out >= cap then return out, scanned, false end
      end
    end
  end
  return out, scanned, true
end

---------------------------------------------------------------- the persisted record
local function sane_ep(e)
  if type(e) ~= 'table' or not int(e.t) then return nil end
  local crit = {}
  for i, c in ipairs(type(e.crit) == 'table' and e.crit or {}) do
    if type(c) == 'string' and i <= 4 then crit[#crit + 1] = c:sub(1, 12) end
  end
  return {t = int(e.t), was = int(e.was) or 0, now = int(e.now) or 0, nbw = int(e.nbw) or 0, nb = int(e.nb) or 0,
          cause = e.cause == 'load' and 'load' or 'runtime', gone = int(e.gone) == 1 and 1 or nil,
          day = int(e.day) or -1, fd = int(e.fd) or 0, fx = int(e.fx) or 0, z = int(e.z) or int(e.t), crit = crit,
          ask = int(e.ask) == 1 and 1 or nil, st = type(e.st) == 'string' and e.st:sub(1, 16) or nil,
          rid = int(e.rid), id = int(e.id)}
end

-- raw (the persist key `burrows` as decoded) -> {v = 2, ad = adoption tick, b = {[name] = record}}. A record of another
-- adoption (a reclaimed or re-adopted fort: its burrows are another fort's) is dropped; so is anything malformed
function M.load(raw, adopted)
  adopted = int(adopted) or 0
  local out = {v = 2, ad = adopted, b = {}}
  if type(raw) ~= 'table' or int(raw.ad) ~= adopted then return out end
  for name, r in pairs(type(raw.b) == 'table' and raw.b or {}) do
    if type(name) == 'string' and #name > 0 and #name <= 40 and type(r) == 'table' and int(r.base) and int(r.base) >= 0 then
      local k
      if type(r.k) == 'table' and #r.k % 4 == 0 and #r.k <= 4 * M.RUNS_MAX then
        k = {}
        for i, v in ipairs(r.k) do
          local n = int(v)
          if not n then k = nil; break end
          k[i] = n
        end
        if k and #k == 0 then k = nil end
      end
      out.b[name] = {id = int(r.id) or -1, base = int(r.base), nb = int(r.nb) or 0, t = int(r.t) or 0, k = k,
                     kp = int(r.kp) == 1 and 1 or nil, cad = type(r.cad) == 'table' and r.cad or nil,
                     ep = sane_ep(r.ep)}
    end
  end
  return out
end

return M
