-- trash: FR-90 (Run 14 note 98). A library, not a kernel module (like zonelib/orderlib): a READ-ONLY view of the fort's garbage,
-- for `inspect what=items key=trash` and for the reason economy names at CANCEL_LOOP "Dump item cancelled 5 times today"
-- (y701, y703, y707). The kernel changes nothing here: the dump zone is placed with the verb zone.place type=dump (zonelib),
-- and a trash bridge/chute is only read, never pulled, built or removed.
--
-- Reads (all on demand, never per tick): the dump zones (zonelib.zones), items.other.IN_PLAY (at most SCAN_MAX items; loose =
-- on the ground, not inside a building/stockpile/container/inventory, outside every dump zone; marked = of them flagged for
-- dumping; in_zone = lying on a dump zone tile), the DumpItem jobs on world.jobs.list (waiting = nobody works them), the
-- citizens' walk group and the building occupancy of the zone tiles (both through the snapshot module: K.call).
local Z = require('dfllm.zonelib')
local M = {}

M.SCAN_MAX = 60000          -- items looked at per inspect (a clipped scan says so)
M.TILE_MAX = 2500           -- zone tiles looked at per zone
M.JOB_MAX = 100000          -- job list nodes walked
M.FAR_MAX = 400             -- marked loose items whose walk group is asked (BUG-148)
M.JOB = 'dump item'         -- the job name in the CANCEL_JOB report ("X cancels Dump item: ..."), lower case

local function int(v) return math.type(v) == 'integer' and v or math.tointeger(v) end

function M.is_cancel(job) return tostring(job or ''):lower() == M.JOB end

-- the dump zones as zonelib reads them
function M.zones()
  local out = {}
  for _, zn in ipairs(Z.zones()) do
    if Z.is_dump(zn.tname) then out[#out + 1] = zn end
  end
  return out
end

local function inside(zones, x, y, z)
  for _, zn in ipairs(zones) do
    if zn.z == z and x >= zn.x0 and x <= zn.x1 and y >= zn.y0 and y <= zn.y1 and (not zn.has or zn.has(x, y)) then return zn.id end
  end
  return nil
end

-- one K.call of the snapshot module (the only reader of tiles and walk groups): its result or nil
local function snap(K, fn, ...)
  local okc, res = K.call('snapshot', fn, ...)
  if okc then return res end
  return nil
end

-- {loose, marked, in_zone, scanned, clipped, marked_forbid, marked_far, marked_bld}: the occupancy of the tiles of the
-- candidate items is asked of snapshot in batches. BUG-148: of the marked loose items, forbidden ones and ones off the
-- citizens' walk group (at most FAR_MAX asked), and marked items inside a building, count apart.
function M.scan(K, zones)
  local r = {loose = 0, marked = 0, in_zone = 0, scanned = 0, clipped = false, marked_forbid = 0, marked_far = 0,
             marked_bld = 0}
  local asked = 0
  local okv, vec = pcall(function() return df.global.world.items.other.IN_PLAY end)
  if not okv or not vec then return r end
  local n = #vec
  if n > M.SCAN_MAX then n, r.clipped = M.SCAN_MAX, true end
  local pts, dump, forbid = {}, {}, {}
  local function flush()
    if #pts == 0 then return end
    local occ = snap(K, 'occupied', pts) or {}
    for i = 1, #pts do
      if (occ[i] or -1) <= 0 then              -- open floor (or a tile snapshot cannot read): loose
        r.loose = r.loose + 1
        if dump[i] then
          r.marked = r.marked + 1
          if forbid[i] then r.marked_forbid = r.marked_forbid + 1 end
          if asked < M.FAR_MAX then
            asked = asked + 1
            if snap(K, 'far', pts[i][1], pts[i][2], pts[i][3]) == true then r.marked_far = r.marked_far + 1 end
          end
        end
      end
    end
    pts, dump, forbid = {}, {}, {}
  end
  for i = 0, n - 1 do
    local it = vec[i]
    local f = it and it.flags
    if f and f.dump and f.in_building then r.marked_bld = r.marked_bld + 1 end
    if f and f.on_ground and not (f.in_building or f.in_inventory or f.trader or f.hostile or f.removed or f.garbage_collect) then
      r.scanned = r.scanned + 1
      local p = it.pos
      local x, y, z = int(p and p.x), int(p and p.y), int(p and p.z)
      if x and y and z and x >= 0 then
        if inside(zones, x, y, z) then
          r.in_zone = r.in_zone + 1
        else
          pts[#pts + 1] = {x, y, z}
          dump[#pts], forbid[#pts] = f.dump == true, f.forbid == true
          if #pts >= 2000 then flush() end
        end
      end
    end
  end
  flush()
  return r
end

-- {total, waiting}: the DumpItem jobs; waiting = no worker has taken them
function M.jobs()
  local r = {total = 0, waiting = 0}
  pcall(function()
    local want = df.job_type.DumpItem
    local link, n = df.global.world.jobs.list.next, 0
    while link and n < M.JOB_MAX do
      local j = link.item
      if j and j.job_type == want then
        r.total = r.total + 1
        local okw, w = pcall(dfhack.job.getWorker, j)
        if not (okw and w) then r.waiting = r.waiting + 1 end
      end
      link, n = link.next, n + 1
    end
  end)
  return r
end

-- one zone: {id, name, box, tiles (in the zone, at most TILE_MAX looked at), walk (walkable), free (walkable, no building),
-- reach (walkable and on the citizens' walk group)}
function M.zone_state(K, zn)
  local s = {id = zn.id, name = zn.name ~= '' and zn.name or nil, box = {zn.x0, zn.y0, zn.z, zn.x1, zn.y1, zn.z},
             tiles = 0, walk = 0, free = 0, reach = 0}
  local pts = {}
  for y = zn.y0, zn.y1 do
    for x = zn.x0, zn.x1 do
      if not zn.has or zn.has(x, y) then
        if #pts >= M.TILE_MAX then s.clipped = true; break end
        pts[#pts + 1] = {x, y, zn.z}
      end
    end
    if s.clipped then break end
  end
  s.tiles = #pts
  local grp, occ = snap(K, 'groups', pts) or {}, snap(K, 'occupied', pts) or {}
  for i, p in ipairs(pts) do
    if (grp[i] or -1) > 0 then
      s.walk = s.walk + 1
      if occ[i] == 0 then s.free = s.free + 1 end
      if snap(K, 'far', p[1], p[2], p[3]) ~= true then s.reach = s.reach + 1 end
    end
  end
  return s
end

-- the reason a dump job cannot finish, from facts: {code, text}; codes no_zone | unreachable | no_free_tile | ok
-- (inspect adds no_jobs: ok, items marked, but no DumpItem job; BUG-148)
function M.diagnose(zones, states)
  if #zones == 0 then
    return 'no_zone', 'no dump zone exists: zone.place type=dump on revealed floor away from paths and water'
  end
  local best, good
  for _, s in ipairs(states) do                -- BUG-148: name the zone with the most free tiles, not the first
    if s.reach > 0 and s.free > 0 and (not good or s.free > good.free) then good = s end
    best = best or s
  end
  if good then return 'ok', string.format('dump zone %s is reachable with %d free of %d tiles', tostring(good.id), good.free, good.tiles) end
  local reach = 0
  for _, s in ipairs(states) do reach = reach + s.reach end
  if reach == 0 then
    local ids = {}
    for _, s in ipairs(states) do ids[#ids + 1] = tostring(s.id) end
    return 'unreachable', string.format('dump zone %s not reachable: no walkable tile shares a walk group with a citizen', table.concat(ids, ','))
  end
  return 'no_free_tile', string.format('dump zone %s: every reachable tile is covered by a building (%d of %d tiles walkable)',
                                       tostring(best.id), best.walk, best.tiles)
end

-- the full picture for inspect and for the CANCEL_LOOP reason
function M.view(K)
  local zones = M.zones()
  local states = {}
  for _, zn in ipairs(zones) do states[#states + 1] = M.zone_state(K, zn) end
  local code, text = M.diagnose(zones, states)
  return zones, states, code, text
end

-- the reason for CANCEL_LOOP of the job named `job` (economy): nil for any other job; economy appends it to the msg
function M.reason(K, job)
  if not M.is_cancel(job) then return nil end
  local ok, _, _, code, text = pcall(M.view, K)
  if not ok then return nil end
  return text, code
end

-- inspect what=items key=trash: ok, msg, data. `seen` = economy's record of the Dump item cancels {n, why, day}
function M.inspect(K, seen)
  local zones, states, code, text = M.view(K)
  local sc, jobs = M.scan(K, zones), M.jobs()
  seen = type(seen) == 'table' and seen or {}
  if code == 'ok' and sc.marked > 0 and jobs.total == 0 then         -- BUG-148: a usable zone, marked items, no job
    code = 'no_jobs'
    text = string.format("no dump job for %d marked (%d forbidden, %d off the walk group, %d in a building): check refuse "
                         .. 'hauling; %s', sc.marked, sc.marked_forbid, sc.marked_far, sc.marked_bld, text)
  end
  local data = {zones = states, loose = sc.loose, marked = sc.marked, in_zone = sc.in_zone, scanned = sc.scanned,
                clipped = sc.clipped, jobs = jobs, reason = code, cancels = seen.n or 0, cancel_why = seen.why,
                marked_forbid = sc.marked_forbid, marked_far = sc.marked_far, marked_bld = sc.marked_bld}
  local msg = string.format('trash: %d loose item(s) (%d marked to dump), %d on dump zones, %d dump job(s) (%d waiting), %d zone(s); %s%s',
                            sc.loose, sc.marked, sc.in_zone, jobs.total, jobs.waiting, #zones, text,
                            seen.why and ('; last cancel: ' .. tostring(seen.why)) or '')
  return true, msg, data
end

return M
