-- Project runner (WP7; DESIGN §4, §5.12; CONTRACTS §7, §9.8-§9.9, §10-§13).
-- Projects come from <save>/bp/<id>.json (inbox bp.place, or plan builds y<Y>s<S>b<I>) and are
-- copied into persist bp.<id>. Stages run in document order (dig -> build -> place -> zone/burrow);
-- a stage starts when the previous one is complete. Each chunk (<= 40 cells) is one act.quickfort
-- call and one slice; a stage with orders=1 first gets one quickfort 'orders' call. Progress: dig
-- tiles through snapshot.tile (fallback: quickfort dry run), buildings by the ids quickfort
-- allocated. A done project merges its manifest fragment and is deregistered. Also phases (§9.9),
-- BREACH_STOP, PROJECT_BLOCKED and the bedroom/tomb capacity keepers. Suspended buildings are
-- suspendmanager's job: nothing here touches jobs. The mode is checked before every work slice,
-- so a run stops at once when SIEGE/BREACH begins; stalled projects only get slots nobody else wants.
local json = require('dfllm.util.json')
local C = require('dfllm.util.contract')
local geom = require('dfllm.util.geom')

local M = {name = 'runner', every = {ticks = 600},
           reports = {DIG_CANCEL_DAMP = true, DIG_CANCEL_WARM = true, CAVE_COLLAPSE = true,
                      FEATURE_DISCOVERY = true}}

local DAY = C.TICKS.DAY
M.CFG = {
  active = 3,            -- projects worked on at once (DESIGN §4)
  qf_per_slice = 1,      -- quickfort calls per slice
  probe = 300,           -- snapshot.tile probes per slice
  stall = 7 * DAY,       -- no progress for this long -> blocked 'stalled' (builds wait for materials)
  meas_every = 2 * DAY,  -- a stalled project without a slot is re-measured (no applies) this often
  meas_extra = 1,        -- such measure-only passes per run, outside the slot budget
  blocked_a = 2 * DAY,   -- blocked longer than this -> PROJECT_BLOCKED (A), once per episode
  dry_every = 2 * DAY,   -- dig measurement by quickfort dry run when there is no snapshot module
  keep_every = 3 * DAY, req_cool = 7 * DAY,
  lost_pct = 10,         -- buildings still missing after one re-apply that let a stage pass (%)
  plan_loads = 1, list_max = 64, done_keep = 16, fail_max = 3,
  breach_r = 3, cavern_r = 10, undo_now = 2,
}
local MODES = {dig = true, build = true, place = true, zone = true, burrow = true}
local CLASSES = {defense = true, infra = true, living = true, beauty = true}
local MINE = {d = true, h = true, u = true, j = true, i = true, r = true}  -- dig keys that remove the wall
local WALL = {['#'] = true, S = true}
local HAZARD = {w = 'water', ['~'] = 'water', ['%'] = 'warm'}
local REPORT_WHY = {DIG_CANCEL_DAMP = 'damp', DIG_CANCEL_WARM = 'warm', FEATURE_DISCOVERY = 'cavern',
                    CAVE_COLLAPSE = 'cavern'}
-- the 12 moodable workshop types (df_llm_helper/bp/rooms.py MOODABLE_TYPES, DESIGN §5.9)
M.MOODABLE = {'Carpenters', 'Masons', 'Craftsdwarfs', 'Jewelers', 'MetalsmithsForge', 'Bowyers',
              'Clothiers', 'Leatherworks', 'Tanners', 'Loom', 'GlassFurnace', 'Mechanics'}
-- deliverable kind -> module that makes it measurable; an absent module skips the deliverable
local OWNER = {baseline = 'baseline', squads = 'military', metal = 'military', drill = 'readiness',
               ready = 'readiness', stock = 'economy', orders = 'economy', bolts = 'economy', trade = 'trade'}
local PLAN_DRIVEN = {proj = true, workshops = true}

local S = {}   -- module state, rebuilt by init (persist docs + caches)

---------------------------------------------------------------- small helpers
local function int(v) return math.tointeger(type(v) == 'string' and tonumber(v) or v) end
local function now(K) return K.now().tick end
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function trunc(s, n) s = tostring(s or ''); return #s > n and s:sub(1, n) or s end
local function obj(t)       -- a map that encodes as {} even when empty
  if type(t) ~= 'table' or t == json.null or (json.is_array(t) and #t > 0) then return json.object{} end
  return json.object(t)
end
local function copy(t)
  if type(t) ~= 'table' then return t end
  local r = {}
  for k, v in pairs(t) do r[k] = copy(v) end
  return r
end
local function dirty() S.dirty = true end
local function save(K)
  if not S.dirty then return end
  S.dirty = false
  K.persist.touch('projects')
  K.persist.touch('m.runner')
end
local function find(id)
  for _, P in ipairs(S.pd.list) do if P.id == id then return P end end
end
local function doc(K, id) return K.persist.get('bp.' .. id) end
local function halted(P) return P.blocked ~= '' and P.blocked ~= 'stalled' end
local function pnum(id) return int(tostring(id or ''):match('^P([0-9])$')) end
local function qf_room() return S.slice.qf < S.slice.qf_max end
local function qf(K, p) S.slice.qf = S.slice.qf + 1; return K.act.quickfort(p) end

local function new_R(t, si)
  return json.object{si = si, prog = 0, last = t, cd = '', cdt = 0, b = {}, c = {}, uns = 0, ra = 0, fail = 0}
end
local function R_of(K, P)
  local r = S.rt.p[P.id]
  if type(r) ~= 'table' or r.si ~= P.stage then r = new_R(now(K), P.stage); S.rt.p[P.id] = r; dirty() end
  return r
end

local function set_blocked(K, P, why)
  if P.blocked == why then return end
  P.blocked, P.since = why, now(K)
  local R = S.rt.p[P.id]
  if R then R.be = 0 end
  dirty()
end

---------------------------------------------------------------- blueprint geometry
-- cell text 'key{props}(WxH)': leading key and extent (quickfort dig.lua:820-826 for negative extents)
local function cell_tiles(ch, cell, out)
  local text = cell[4]
  local key = text:match('^[^{(:/]*')
  local w, h = text:match('%((%-?[0-9]+)x(%-?[0-9]+)%)')
  w, h = clamp(int(w) or 1, -100, 100), clamp(int(h) or 1, -100, 100)
  local x, y, z = ch.pos[1] + cell[1], ch.pos[2] + cell[2], ch.pos[3] + cell[3]
  if w < 0 then x, w = x + w + 1, -w end
  if h < 0 then y, h = y + h + 1, -h end
  for dy = 0, h - 1 do
    for dx = 0, w - 1 do out[#out + 1] = {x + dx, y + dy, z, key} end
  end
end

-- per-chunk tile lists of stage si (0-based), cached: {[ci] = {{x,y,z,key},...}, n = total, bbox}
local function stage_tiles(id, d, si)
  local k = id .. '/' .. si
  local c = S.tiles[k]
  if c then return c end
  c = {n = 0}
  local bb
  for ci, ch in ipairs(d.stages[si + 1].chunks) do
    local tl = {}
    for _, cell in ipairs(ch.cells) do cell_tiles(ch, cell, tl) end
    for _, t in ipairs(tl) do
      local b = {t[1], t[2], t[3], t[1], t[2], t[3]}
      bb = bb and geom.bbox_union(bb, b) or b
    end
    c[ci], c.n = tl, c.n + #tl
  end
  c.bbox = bb or {0, 0, 0, 0, 0, 0}
  S.tiles[k] = c
  return c
end

local function project_bbox(id, d)
  local bb = S.bbox[id]
  if bb then return bb end
  for si = 0, #d.stages - 1 do
    local b = stage_tiles(id, d, si).bbox
    bb = bb and geom.bbox_union(bb, b) or b
  end
  S.bbox[id] = bb
  return bb
end

local function forget(id)
  for k in pairs(S.tiles) do if k:sub(1, #id + 1) == id .. '/' then S.tiles[k] = nil end end
  S.bbox[id], S.meas[id] = nil, nil
end

-- data[dz][dy][dx] = text relative to the chunk pos (quickfort.txt:170-176, api.lua:13)
local function chunk_data(ch)
  local data = {}
  for _, c in ipairs(ch.cells) do
    local gz = data[c[3]] or {}
    data[c[3]] = gz
    local row = gz[c[2]] or {}
    gz[c[2]] = row
    row[c[1]] = c[4]
  end
  return data
end

local function contains(outer, b)
  return b[1] >= outer[1] and b[2] >= outer[2] and b[3] >= outer[3] and b[4] <= outer[4] and
         b[5] <= outer[5] and b[6] <= outer[6]
end

local function near(pos, bb, r)
  local rz = math.min(r, 2)
  return geom.in_bbox(pos, {bb[1] - r, bb[2] - r, bb[3] - rz, bb[4] + r, bb[5] + r, bb[6] + rz})
end

---------------------------------------------------------------- documents and registration
local function check_doc(d, tpl)
  if type(d) ~= 'table' or d.v ~= 2 then return 'not a v2 bp document' end
  if type(d.tpl) ~= 'string' or not d.tpl:match('^[a-z][a-z0-9_]+$') then return 'bad tpl' end
  if tpl and d.tpl ~= tpl then return 'tpl ' .. d.tpl .. ' does not match ' .. tostring(tpl) end
  if not CLASSES[d.class] then return 'bad class ' .. tostring(d.class) end
  if type(d.stages) ~= 'table' or #d.stages < 1 or #d.stages > 64 then return 'bad stages' end
  for si, st in ipairs(d.stages) do
    if type(st) ~= 'table' or not MODES[st.mode] or type(st.label) ~= 'string' then return 'bad stage ' .. si end
    if type(st.chunks) ~= 'table' or #st.chunks < 1 or #st.chunks > 500 then return 'bad chunks in stage ' .. si end
    for _, ch in ipairs(st.chunks) do
      local p = ch.pos
      if type(p) ~= 'table' or not (int(p[1]) and int(p[2]) and int(p[3])) or type(ch.cells) ~= 'table' or
         #ch.cells < 1 or #ch.cells > 40 then return 'bad chunk in stage ' .. si end
      for _, c in ipairs(ch.cells) do
        if type(c) ~= 'table' or not (int(c[1]) and int(c[2]) and int(c[3])) or type(c[4]) ~= 'string' or
           #c[4] > 64 then return 'bad cell in stage ' .. si end
      end
    end
  end
  if d.manifest ~= nil and type(d.manifest) ~= 'table' then return 'bad manifest' end
  return nil
end

local function read_bp(K, id)
  local path = K.cfg.paths.save .. '/bp/' .. id .. '.json'
  local f = io.open(path, 'rb')
  if not f then return nil, 'missing' end
  local s = f:read('a')
  f:close()
  local d, err = json.try_decode(s or '')
  if type(d) ~= 'table' or d == json.null then return nil, 'bad json (' .. tostring(err) .. ')' end
  return d
end

local function prune(keep_done)       -- drop the oldest done projects beyond keep_done
  local done = {}
  for _, P in ipairs(S.pd.list) do if P.done == 1 then done[#done + 1] = P end end
  if #done <= keep_done then return end
  table.sort(done, function(a, b) return a.since < b.since end)
  local drop = {}
  for i = 1, #done - keep_done do drop[done[i]] = true end
  local keep = {}
  for _, P in ipairs(S.pd.list) do if not drop[P] then keep[#keep + 1] = P end end
  S.pd.list = keep
  dirty()
end

local rows -- forward

local function register(K, id, d, prio, tpl)
  if find(id) then return true end
  local err = check_doc(d, tpl)
  if err then return false, err end
  if #S.pd.list >= M.CFG.list_max then
    prune(0)
    if #S.pd.list >= M.CFG.list_max then return false, 'project list full' end
  end
  local t = now(K)
  d.id = id
  local site = type(d.site) == 'string' and #d.site <= 40 and d.site:match('^[A-Za-z0-9_-]+$') or 'S1'
  S.pd.list[#S.pd.list + 1] = {id = id, tpl = d.tpl, site = site, class = d.class, prio = clamp(prio, 1, 7),
                               stage = 0, chunk = 0, pct = 0, blocked = '', since = t, created = t, done = 0,
                               orders_done = 0}
  K.persist.set('bp.' .. id, d)
  S.rt.p[id] = new_R(t, 0)
  forget(id)
  dirty()
  rows(K)
  K.flush()
  K.log('info', 'queued %s (%s, %d stages)', id, d.tpl, #d.stages)
  return true
end

-- plan builds: entry i of season s is bp/y<year>s<s>b<i>.json, due from that season on (CONTRACTS §9.7)
local function sync_plan(K)
  S.plan_pending = false
  local plan, T, loads = K.plan, K.now(), 0
  if type(plan) ~= 'table' or type(plan.seasons) ~= 'table' or math.type(plan.year) ~= 'integer' then return end
  for id in pairs(S.rt.planned) do
    local y = int(id:match('^y([0-9]+)s'))
    if y and y < plan.year - 1 then S.rt.planned[id] = nil; dirty() end
  end
  for s = 0, 3 do
    local se = plan.seasons[s + 1]
    local due = T.year > plan.year or (T.year == plan.year and T.season >= s)
    for i, b in ipairs(type(se) == 'table' and type(se.build) == 'table' and se.build or {}) do
      local id = string.format('y%ds%db%d', plan.year, s, i - 1)
      if not S.rt.planned[id] then
        if find(id) then S.rt.planned[id] = 1; dirty()
        elseif not due or loads >= M.CFG.plan_loads then S.plan_pending = true
        else
          loads = loads + 1
          S.rt.planned[id] = 1
          dirty()
          local d, err = read_bp(K, id)
          local ok = false
          if d then ok, err = register(K, id, d, int(b.prio) or 4, b.tpl) end
          if not ok then
            K.log('error', 'plan build %s not queued: %s', id, tostring(err))
            K.emit('PROJECT_BLOCKED', 'A', 'plan build ' .. id .. ' not queued: ' .. tostring(err),
                   {proj = id, tpl = trunc(b.tpl, 32), why = trunc('bp: ' .. tostring(err), 40)})
          end
        end
      end
    end
  end
end

---------------------------------------------------------------- manifest merge (CONTRACTS §11)
local function key_of(v) return json.encode(v) end
local function append_unique(dst, src, cap)
  local out, seen = {}, {}
  for _, list in ipairs({dst or {}, src or {}}) do
    for _, v in ipairs(list) do
      local k = key_of(v)
      if not seen[k] and #out < cap then seen[k] = true; out[#out + 1] = copy(v) end
    end
  end
  return out
end
local function replace_by(dst, src, field, cap)
  local out, at = {}, {}
  for _, list in ipairs({dst or {}, src or {}}) do
    for _, v in ipairs(list) do
      local k = type(v) == 'table' and key_of(v[field]) or key_of(v)
      if at[k] then out[at[k]] = copy(v)
      elseif #out < cap then out[#out + 1] = copy(v); at[k] = #out end
    end
  end
  return out
end
local MAPS = {bridges = true, stations = true, burrows = true}
local LISTS = {zones = 50, stairs = 8}
local BY = {killboxes = {'id', 20}, rooms = {'id', 200}, workshops = {'pos', 100}}

-- maps replaced per key; id/pos lists replaced per entry; plain lists appended without duplicates
function M.merge_manifest(dst, frag)
  for k, v in pairs(type(frag) == 'table' and frag or {}) do
    if k == 'v' then -- keep
    elseif MAPS[k] and type(v) == 'table' then
      dst[k] = obj(dst[k])
      for kk, vv in pairs(v) do dst[k][kk] = copy(vv) end
    elseif LISTS[k] and type(v) == 'table' then
      dst[k] = obj(dst[k])
      for kk, list in pairs(v) do dst[k][kk] = append_unique(dst[k][kk], list, LISTS[k]) end
    elseif BY[k] then dst[k] = replace_by(dst[k], v, BY[k][1], BY[k][2])
    elseif k == 'edge' then dst[k] = append_unique(dst[k], v, 200)
    else dst[k] = copy(v) end                              -- refuge, pit, depot
  end
  dst.v = 2
  return dst
end

---------------------------------------------------------------- progress
local function labels_done(d, si)   -- highest N with every stage 'sK.*' (K <= N) before index si
  local pend, top = {}, 0
  for i, st in ipairs(d.stages) do
    local n = int(st.label:match('^s([0-9]+)%.'))
    if n then
      top = math.max(top, n)
      if i - 1 >= si then pend[n] = true end
    end
  end
  local r = 0
  for n = 1, top do if pend[n] then break end; r = n end
  return r
end

local function pct_of(P, d, frac)
  return clamp((100 * P.stage + clamp(frac, 0, 100)) // #d.stages, 0, 100)
end

local function progress(K, P, d, R, done, total)
  P.pct = pct_of(P, d, total > 0 and (100 * done) // total or 0)
  local t = now(K)
  if done > R.prog then
    R.prog, R.last = done, t
    if P.blocked == 'stalled' then set_blocked(K, P, '') end
  elseif P.blocked == '' and t - R.last >= M.CFG.stall then
    set_blocked(K, P, 'stalled')
  end
  dirty()
end

-- map bounds only, no tile contents (Lua API.txt:2229 isValidTilePos)
local function on_map(x, y, z)
  local ok, v = pcall(dfhack.maps.isValidTilePos, x, y, z)
  return not ok or v == true
end
-- quickfort never designates mine keys on the map edge (dig.lua:172, map.lua:62 is_on_map_edge)
local function on_edge(x, y, z)
  return not (on_map(x - 1, y, z) and on_map(x + 1, y, z) and on_map(x, y - 1, z) and on_map(x, y + 1, z))
end

-- one tile of a dig stage through snapshot.tile (CONTRACTS §7): result, hazard, mark; nil when the
-- call failed. mark = quickfort designated this tile (seen pending, or hidden under a mine key, which
-- quickfort always designates off the edge: dig.lua:173). 'skip' = quickfort never designated it
-- (off map, edge, soil, engraving, building; dig.lua:288-297, 842-845, 865-868): done for completion.
-- A wall without designation is a cancel ('lost') only when `seen` says it was designated before.
local function probe(K, t, seen)
  local ok, v = K.call('snapshot', 'tile', t[1], t[2], t[3])
  if not ok then return nil end
  S.slice.probes = S.slice.probes + 1
  local key = t[4]
  if type(v) ~= 'table' or v.c == nil or v.c == '?' then          -- hidden or off the map
    if MINE[key] and on_map(t[1], t[2], t[3]) and not on_edge(t[1], t[2], t[3]) then return 'pend', nil, true end
    return 'skip'
  end
  if HAZARD[v.c] then return 'breach', HAZARD[v.c] end
  if v.dig ~= nil and v.dig ~= '' then return 'pend', nil, true end
  if MINE[key] then
    if not WALL[v.c] then return 'done' end
    return seen and 'lost' or 'skip'
  end
  if (key == 's' and v.c == '#') or (key == 'F' and WALL[v.c]) then return 'skip' end
  return 'done'
end

local function mask_set(s, i)
  if #s < i then s = s .. string.rep('0', i - #s) end
  return s:sub(1, i - 1) .. '1' .. s:sub(i + 1)
end

local breach -- forward

local function measure_dig(K, P, d, R)
  local tiles = stage_tiles(P.id, d, P.stage)
  local m = S.meas[P.id]
  if not m or m.si ~= P.stage then
    m = {si = P.stage, ci = 1, pend = 0, done = 0, snap = S.snap_ok}
    if not m.snap then                       -- dry runs: one pass per dry_every, start to start
      if R.dry and now(K) - R.dry < M.CFG.dry_every then return 'done' end
      R.dry = now(K)
    end
    S.meas[P.id] = m
  end
  local chunks = d.stages[P.stage + 1].chunks
  while m.ci <= #tiles do
    local ci, tl = m.ci, tiles[m.ci]
    if R.cd:sub(ci, ci) ~= '1' then
      local pend, done, skip = 0, 0, 0
      if m.snap then
        if S.slice.probes > 0 and S.slice.probes + #tl > M.CFG.probe then return 'yield' end
        R.sp = obj(R.sp)                     -- per chunk: tiles seen designated ('1'), persisted
        local sk = tostring(ci)
        local sp = R.sp[sk] or ''
        for i, t in ipairs(tl) do
          local seen = sp:sub(i, i) == '1'
          local r, why, mark = probe(K, t, seen)
          if r == nil then S.snap_ok, S.meas[P.id] = false, nil; return 'yield' end   -- dry run instead
          if mark and not seen then sp = mask_set(sp, i); R.sp[sk] = sp; dirty() end
          if r == 'lost' or r == 'breach' then
            S.meas[P.id] = nil
            breach(K, P, r == 'lost' and 'damp' or why, {t[1], t[2], t[3]}, r == 'lost' and 'cancel' or 'tile')
            return 'done'
          end
          if r == 'pend' then pend = pend + 1 elseif r == 'skip' then skip = skip + 1 else done = done + 1 end
        end
        if pend == 0 then
          R.sp[sk] = nil
          if skip > 0 then
            R.sk = (R.sk or 0) + skip
            K.log('info', '%s %s chunk %d: %d tiles never designated, skipped', P.id, d.stages[P.stage + 1].label,
                  ci - 1, skip)
          end
        end
        done = done + skip
      else
        if not qf_room() then return 'yield' end
        local ch = chunks[ci]
        local ok, st = qf(K, {mode = 'dig', data = chunk_data(ch), pos = ch.pos, dry_run = true})
        local left = ok and type(st) == 'table' and int(st.dig_designated)  -- dig.lua:878, still to dig
        pend = left and math.min(left, #tl) or #tl
        done = #tl - pend
      end
      if pend == 0 then R.cd, R.cdt = mask_set(R.cd, ci), R.cdt + done
      else m.pend, m.done = m.pend + pend, m.done + done end
      dirty()
    end
    m.ci = ci + 1
  end
  S.meas[P.id] = nil
  progress(K, P, d, R, R.cdt + m.done, tiles.n)
  if m.pend > 0 then return 'done' end
  R.lost = R.sk or 0                         -- tiles left undug because quickfort skipped them
  return 'complete'
end

local function built(b) return b:getBuildStage() >= b:getMaxBuildStage() end

local function measure_build(K, P, d, R)
  if R.noid == 1 then return 'complete' end
  local pend, done, keep = 0, 0, {}
  for _, id in ipairs(R.b) do
    local b = df.building.find(id)
    if b then
      keep[#keep + 1] = id
      if built(b) then done = done + 1 else pend = pend + 1 end
    end
  end
  for _, id in ipairs(R.c) do               -- a finished construction is no building any more
    local b = df.building.find(id)
    if b and not built(b) then pend = pend + 1 else done = done + 1 end
  end
  local lost = #R.b - #keep + R.uns
  local total = #R.b + #R.c + R.uns
  progress(K, P, d, R, done, total)
  if pend > 0 then return 'done' end
  if lost > 0 and R.ra ~= 1 then            -- one re-apply: quickfort places only what is missing
    R.b, R.uns, R.ra, P.chunk = keep, lost, 1, 0
    dirty()
    return 'reapply'
  end
  if lost * 100 > total * M.CFG.lost_pct then set_blocked(K, P, 'build_lost'); return 'done' end
  R.lost = lost
  return 'complete'
end

---------------------------------------------------------------- applying stages
local function is_construction(b) return b:getType() == df.building_type.Construction end

local function apply(K, P, st, R)
  local ch = st.chunks[P.chunk + 1]
  local p = {mode = st.mode, data = chunk_data(ch), pos = ch.pos}
  if st.mode == 'dig' then p.priority = P.prio end
  -- quickfort allocates the ids of the buildings it places (build.lua:1259 constructBuilding)
  local n0 = st.mode == 'build' and df.global.building_next_id or nil
  local ok, stats = qf(K, p)
  if not ok then
    R.fail = (R.fail or 0) + 1
    if R.fail >= M.CFG.fail_max then set_blocked(K, P, 'apply_fail') end
    dirty()
    return false
  end
  stats = type(stats) == 'table' and stats or {}
  R.fail = 0
  local bad = int(stats.invalid_keys) or 0
  if bad > 0 then K.log('warn', '%s %s chunk %d: %d invalid quickfort keys', P.id, st.label, P.chunk, bad) end
  if st.mode == 'dig' then                  -- tiles quickfort did not designate (dig.lua:829, 862, 867)
    local oob, inv, eng = int(stats.out_of_bounds) or 0, int(stats.dig_invalid_tiles) or 0,
                          int(stats.dig_protected_engraving) or 0
    if oob + inv + eng > 0 then
      R.qs = (R.qs or 0) + oob + inv + eng
      K.log('info', '%s %s chunk %d: quickfort skipped %d off map, %d invalid, %d engraved', P.id, st.label,
            P.chunk, oob, inv, eng)
    end
  elseif st.mode == 'build' then
    local n1 = df.global.building_next_id
    if math.type(n0) ~= 'integer' or math.type(n1) ~= 'integer' then R.noid = 1
    else
      for id = n0, n1 - 1 do
        local b = df.building.find(id)
        if b then
          local list = is_construction(b) and R.c or R.b
          list[#list + 1] = id
        end
      end
      if R.ra == 1 then R.uns = math.max(0, R.uns - (n1 - n0))
      else R.uns = R.uns + (int(stats.build_unsuitable) or 0) + bad end
    end
  end
  P.chunk = P.chunk + 1
  R.last = now(K)
  dirty()
  return true
end

-- one 'orders' call for the whole stage, absolute coordinates. Each manager order created comes back
-- as an array entry = its quantity (orders.lua:162-165 is_order stats; act.quickfort must run
-- orders.create_orders, which apply_blueprint alone never does: quickfort.lua:43-56, command.lua:183).
-- false = failed, retried next run; after fail_max failures the stage is built without orders.
local function orders(K, P, st, R)
  local data = {}
  for _, ch in ipairs(st.chunks) do
    for _, c in ipairs(ch.cells) do
      local x, y, z = ch.pos[1] + c[1], ch.pos[2] + c[2], ch.pos[3] + c[3]
      local gz = data[z] or {}
      data[z] = gz
      local row = gz[y] or {}
      gz[y] = row
      row[x] = c[4]
    end
  end
  local ok, res = qf(K, {mode = st.mode, data = data, pos = {0, 0, 0}, command = 'orders'})
  if not ok then
    R.of = (R.of or 0) + 1
    dirty()
    if R.of < M.CFG.fail_max then
      K.log('warn', '%s %s: quickfort orders failed (%d): %s', P.id, st.label, R.of, tostring(res))
      return false
    end
    K.log('error', '%s %s: quickfort orders failed %d times, building without orders: %s', P.id, st.label,
          R.of, tostring(res))
  else
    local n, q = 0, 0
    for k, v in pairs(type(res) == 'table' and res or {}) do
      if math.type(k) == 'integer' and type(v) == 'number' then n, q = n + 1, q + v end
    end
    R.ord = q
    if n > 0 then K.log('info', '%s %s: %d manager orders, %d items', P.id, st.label, n, q)
    else K.log('warn', '%s %s: quickfort orders created no manager orders', P.id, st.label) end
  end
  P.orders_done = 1
  dirty()
  return true
end

local function stage_done(K, P, d, st, R)
  local t = now(K)
  P.stage, P.chunk, P.orders_done, P.since = P.stage + 1, 0, 0, t
  if P.blocked == 'stalled' then P.blocked = '' end
  P.pct = pct_of(P, d, 0)
  S.rt.p[P.id] = new_R(t, P.stage)
  S.meas[P.id] = nil
  K.emit('PROJECT_STAGE', 'C', P.id .. ' ' .. st.label .. ' done (' .. P.pct .. '%)',
         {proj = P.id, stage = st.label, pct = P.pct, defense = st.defense == 1 and 1 or 0, lost = R.lost or 0,
          qskip = R.qs or 0})
  dirty()
end

local function finish(K, P, d)
  local man = K.manifest()
  M.merge_manifest(man, d.manifest)
  K.persist.set('manifest', man)
  local h = obj(S.rt.hist[P.tpl])
  h.n = (h.n or 0) + 1
  h.ps = math.max(h.ps or 0, int(type(d.params) == 'table' and d.params.stage) or 0)
  h.ls = math.max(h.ls or 0, labels_done(d, #d.stages))
  S.rt.hist[P.tpl] = h
  P.done, P.pct, P.blocked, P.since = 1, 100, '', now(K)
  K.persist.set('bp.' .. P.id, nil)
  S.rt.p[P.id] = nil
  forget(P.id)
  K.emit('PROJECT_DONE', 'B', P.id .. ' (' .. P.tpl .. ') done', {proj = P.id, tpl = P.tpl})
  K.flush()
  dirty()
end

-- meas: measure-only pass of a stalled project without a slot (no orders, no applies)
local function work(K, P, meas)
  local d = doc(K, P.id)
  if not d then set_blocked(K, P, 'bp_missing'); return 'done' end
  local applied = false
  for _ = 1, 100000 do                       -- every pass applies, measures, advances or returns
    if P.stage >= #d.stages then finish(K, P, d); return 'done' end
    local st, R = d.stages[P.stage + 1], R_of(K, P)
    local need_orders = st.orders == 1 and P.orders_done ~= 1
    if meas and (need_orders or P.chunk < #st.chunks or (st.mode ~= 'dig' and st.mode ~= 'build')) then
      return 'done'
    end
    if need_orders then
      if not qf_room() then return 'yield' end
      if not orders(K, P, st, R) then return 'done' end
    end
    if P.chunk < #st.chunks then
      if not qf_room() then return 'yield' end
      if not apply(K, P, st, R) then return 'done' end
      applied = true
    elseif applied and (st.mode == 'dig' or st.mode == 'build') then
      return 'done'                          -- measure from the next run on
    else
      local res = 'complete'
      if st.mode == 'dig' then res = measure_dig(K, P, d, R)
      elseif st.mode == 'build' then res = measure_build(K, P, d, R) end
      if res == 'complete' then stage_done(K, P, d, st, R)
      elseif res ~= 'reapply' then return res end
    end
  end
  return 'done'
end

---------------------------------------------------------------- undo (bp.cancel undo, BREACH_STOP)
local function remove(K, P)
  for i, Q in ipairs(S.pd.list) do if Q == P then table.remove(S.pd.list, i); break end end
  K.persist.set('bp.' .. P.id, nil)
  S.rt.p[P.id] = nil
  forget(P.id)
  dirty()
  rows(K)
  K.flush()
end

-- walks R.undo = {s = stage, l = {chunk indices}, cancel = 0|1}; cancel walks back to stage 0
local function undo(K, P)
  local R, d = R_of(K, P), doc(K, P.id)
  local u = R.undo
  while u and d do
    if #u.l == 0 then
      if u.cancel ~= 1 or u.s <= 0 then break end
      u.s = u.s - 1
      local l = {}
      for ci = #d.stages[u.s + 1].chunks - 1, 0, -1 do l[#l + 1] = ci end
      u.l = l
    else
      if not qf_room() then dirty(); return 'yield' end
      local ci = table.remove(u.l, 1)
      local st = d.stages[u.s + 1]
      local ch = st and st.chunks[ci + 1]
      if ch then qf(K, {mode = st.mode, data = chunk_data(ch), pos = ch.pos, command = 'undo'}) end
      dirty()
    end
  end
  R.undo = nil
  dirty()
  if P.blocked == 'cancel' then remove(K, P) end
  return 'done'
end

function breach(K, P, why, pos, src)
  if P.blocked:sub(1, 7) == 'breach:' or P.blocked == 'cancel' then return false end
  local d, R = doc(K, P.id), R_of(K, P)
  set_blocked(K, P, 'breach:' .. why)
  local st = d and d.stages[P.stage + 1]
  if st and st.mode == 'dig' then           -- undo the applied chunks of this dig stage, nearest first
    local l, dist = {}, {}
    local tiles = stage_tiles(P.id, d, P.stage)
    for ci = 0, P.chunk - 1 do
      l[#l + 1] = ci
      dist[ci] = 0
      if pos then
        dist[ci] = math.huge
        for _, t in ipairs(tiles[ci + 1]) do dist[ci] = math.min(dist[ci], geom.dist(t, pos)) end
      end
    end
    table.sort(l, function(a, b)
      if dist[a] ~= dist[b] then return dist[a] < dist[b] end
      return a < b
    end)
    R.undo = {s = P.stage, l = l, cancel = 0}
    if S.run then table.insert(S.run.tasks, S.run.i + 1, {k = 'undo', id = P.id}) end  -- this run
  end
  local dd = {proj = P.id, why = why, src = src, pos = pos and {pos[1], pos[2], pos[3]} or nil}
  K.emit('BREACH_STOP', 'B', P.id .. ': ' .. why .. ' (' .. src .. '), digging stopped', dd)
  K.flush()
  dirty()
  return true
end

local function cancel(K, P, with_undo)
  local R, d = R_of(K, P), doc(K, P.id)
  if not with_undo then
    if R.undo and d then return set_blocked(K, P, 'cancel') end   -- finish a breach undo, then remove
    return remove(K, P)
  end
  if not d then return remove(K, P) end
  local s = math.min(P.stage, #d.stages - 1)
  local n = P.chunk
  if P.stage >= #d.stages or R.ra == 1 then n = #d.stages[s + 1].chunks end
  local l = {}
  for ci = n - 1, 0, -1 do l[#l + 1] = ci end
  R.undo = {s = s, l = l, cancel = 1}
  set_blocked(K, P, 'cancel')
end

---------------------------------------------------------------- mode gating
local function beauty_ok(K)
  local pol = K.plan and K.plan.policy
  if type(pol) == 'table' and pol.beauty == 'none' then return false end
  local ok, lvl = K.call('readiness', 'level')
  return ok and type(lvl) == 'number' and lvl >= 1
end

local function inside(K, P, d)    -- the whole project lies in one Z3/Z4 bbox (repairs inside)
  local z = K.manifest().zones
  if type(z) ~= 'table' then return false end
  local bb = project_bbox(P.id, d)
  for _, key in ipairs({'Z3', 'Z4'}) do
    for _, b in ipairs(type(z[key]) == 'table' and z[key] or {}) do if contains(b, bb) then return true end end
  end
  return false
end

-- CONTRACTS §9.8 class gating: ALERT/RECOVERY defense+infra, SIEGE defense inside, beauty PEACE+R1
local function allowed(K, P, d)
  local m = K.mode()
  if m == 'PEACE' then return P.class ~= 'beauty' or beauty_ok(K) end
  if m == 'ALERT' or m == 'RECOVERY' then return P.class == 'defense' or P.class == 'infra' end
  if m == 'SIEGE' then return P.class == 'defense' and d ~= nil and inside(K, P, d) end
  return false
end

local function sorted()
  local r = {}
  for _, P in ipairs(S.pd.list) do if P.done ~= 1 then r[#r + 1] = P end end
  table.sort(r, function(a, b)
    if a.prio ~= b.prio then return a.prio < b.prio end
    if a.created ~= b.created then return a.created < b.created end
    return a.id < b.id
  end)
  return r
end

function rows(K)
  local out = {}
  for _, P in ipairs(sorted()) do
    if #out >= 8 then break end
    local d = doc(K, P.id)
    local st = d and d.stages[P.stage + 1]
    local b = P.blocked
    if b == '' then
      if not allowed(K, P, d) then b = 'frozen' elseif S.active and not S.active[P.id] then b = 'queued' end
    end
    out[#out + 1] = {P.id, trunc(st and st.label or 'done', 24), P.pct, trunc(b, 40)}
  end
  S.rows = out
end

---------------------------------------------------------------- phases (CONTRACTS §9.9)
local function phase_list(K)
  local ph = K.plan and K.plan.phases
  if type(ph) == 'table' and type(ph.phases) == 'table' then ph = ph.phases end
  if type(ph) ~= 'table' or #ph == 0 then return nil end
  return ph
end
local function idx_of(list, id)
  for i, ph in ipairs(list) do if ph.id == id then return i end end
end

local function absent(K, mod)
  local ok, err = K.call(mod, '?')
  if ok or err ~= 'no module' then return false end
  if not S.absent[mod] then S.absent[mod] = true; K.log('info', 'deliverables of absent module %s are skipped', mod) end
  return true
end

local function proj_reached(K, tpl, stage)
  local h = S.rt.hist[tpl]
  if h and (stage == nil or (h.ps or 0) >= stage or (h.ls or 0) >= stage) then return true end
  if not stage then return false end
  for _, P in ipairs(S.pd.list) do
    if P.tpl == tpl and P.done ~= 1 then
      local d = doc(K, P.id)
      if d and labels_done(d, P.stage) >= stage then return true end
    end
  end
  return false
end

local CHECK = {
  -- marker.baseline (kern) or baseline.done() (m.baseline.done, WP8): kern owns the marker, so the
  -- baseline module publishes its own flag
  baseline = function(K)
    local m = K.persist.get('marker')
    if m ~= nil and m.baseline == 1 then return true end
    local ok, done = K.call('baseline', 'done')
    return ok and done == true
  end,
  proj = function(K, dv) return proj_reached(K, dv.tpl, int(dv.stage)) end,
  squads = function(K, dv) local v = K.view().mil; return v ~= nil and (v.squads or 0) >= dv.n end,
  drill = function(K) local v = K.view().ready; return v ~= nil and (v.drill_age or -1) >= 0 end,
  stock = function(K, dv)
    local v = K.view().stock
    return v ~= nil and type(v[dv.key]) == 'number' and v[dv.key] >= dv.min
  end,
  orders = function(K, dv) local ok, v = K.call('economy', 'imported', dv.lib); return ok and v == true end,
  trade = function(K, dv) local ok, v = K.call('trade', 'done'); return ok and type(v) == 'number' and v >= dv.n end,
  ready = function(K, dv) local v = K.view().ready; return v ~= nil and (v.lvl or 0) >= dv.lvl end,
  metal = function(K, dv) local v = K.view().mil; return v ~= nil and (v.metal_pct or 0) >= dv.pct end,
  bolts = function(K, dv) local v = K.census.i; return v ~= nil and (v.bolts or 0) >= dv.n end,
  workshops = function(K, dv)
    local have = {}
    for _, w in ipairs(K.manifest().workshops or {}) do have[w.type] = true end
    for _, t in ipairs(dv.types or {}) do
      for _, n in ipairs(t == 'moodable' and M.MOODABLE or {t}) do if not have[n] then return false end end
    end
    return true
  end,
}

-- all deliverables pass?; second value: a failing one depends on projects (proj, workshops)
local function check_phase(K, ph)
  local pass, plan_fail = true, false
  for _, dv in ipairs(type(ph.deliver) == 'table' and ph.deliver or {}) do
    local f = CHECK[dv.k]
    local mod = dv.k == 'stock' and dv.key == 'hosp_water' and 'care' or OWNER[dv.k]
    local ok = f ~= nil and ((mod ~= nil and absent(K, mod)) or f(K, dv) == true)
    if not ok then pass = false; plan_fail = plan_fail or PLAN_DRIVEN[dv.k] == true end
  end
  return pass, plan_fail
end

local function phases(K)
  local list = phase_list(K)
  local ph = K.persist.get('phase')
  S.stuck = true
  if not list then S.phase = type(ph) == 'table' and ph.phase or nil; return end
  if type(ph) ~= 'table' or not idx_of(list, ph.phase) then
    ph = {v = 2, phase = list[1].id, since = now(K), done = {}}
    K.persist.set('phase', ph)
  end
  local target = pnum(K.plan.phase_target) or 0
  for _ = 1, #list do
    local i = idx_of(list, ph.phase)
    local cur, nxt = list[i], list[i + 1]
    local pass, plan_fail = check_phase(K, cur)
    if not pass then S.stuck = plan_fail; break end
    if not nxt or (nxt.approve == true and target < (pnum(nxt.id) or 99)) then break end
    local done = append_unique(ph.done, {cur.id}, 99)
    while #done > 8 do table.remove(done, 1) end
    ph.done, ph.phase, ph.since = done, nxt.id, now(K)
    K.persist.touch('phase')
    K.emit('PHASE', 'B', cur.id .. ' -> ' .. nxt.id, {from = cur.id, to = nxt.id})
  end
  S.phase = ph.phase
end

-- nothing queued, no plan build pending, and the phase cannot advance through projects
local function exhausted(K)
  if S.plan_pending or not S.stuck then return end
  for _, P in ipairs(S.pd.list) do if P.done ~= 1 then return end end
  local pp = K.persist.get('plan')
  local key = string.format('%s:%s:%s', S.phase or '-', tostring(K.plan.year), tostring(pp and pp.loaded or 0))
  if S.rt.exh == key then return end
  S.rt.exh = key
  dirty()
  K.emit('PLAN_EXHAUSTED', 'A', 'plan exhausted in ' .. (S.phase or 'no phase'),
         {phase = S.phase or '', year = K.now().year})
end

---------------------------------------------------------------- capacity keepers
-- free and owned active zones of buildings.other[name] (civzones; hack/scripts/entomb.lua:44-56)
local function zones(name)
  local ok, free, owned = pcall(function()
    local f, o = 0, 0
    for _, z in ipairs(df.global.world.buildings.other[name]) do
      local sf = z.spec_sub_flag
      if not sf or sf.active ~= false then
        local u = z.assigned_unit_id
        if u ~= nil and u >= 0 then o = o + 1 else f = f + 1 end
      end
    end
    return f, o
  end)
  if ok then return free, owned end
end

local function keeper_on(K, tpl)
  for _, P in ipairs(S.pd.list) do if P.tpl == tpl and P.done ~= 1 then return false end end
  local last = S.rt.req[tpl]
  if last and now(K) - last < M.CFG.req_cool then return false end
  if S.rt.hist[tpl] then return true end
  local list = phase_list(K)
  local cur = list and S.phase and idx_of(list, S.phase)
  if not cur then return false end
  for i, ph in ipairs(list) do              -- from the first phase that delivers this template on
    for _, dv in ipairs(type(ph.deliver) == 'table' and ph.deliver or {}) do
      if dv.k == 'proj' and dv.tpl == tpl then return cur >= i end
    end
  end
  return false
end

local function request(K, tpl, n, why)
  S.rt.req[tpl] = now(K)
  dirty()
  K.emit('PROJECT_REQUEST', 'B', string.format('%s x%d: %s', tpl, n, why), {tpl = tpl, n = n, why = why})
end

local function keepers(K)
  local t = now(K)
  if K.mode() ~= 'PEACE' or (S.rt.kt and t - S.rt.kt < M.CFG.keep_every) then return end
  S.rt.kt = t
  dirty()
  local u = K.census.u
  if type(u) == 'table' and math.type(u.adults) == 'integer' and keeper_on(K, 'bedrooms') then
    local free, owned = zones('ZONE_BEDROOM')
    if free then                             -- free bedrooms >= adults without one + 4
      local homeless = math.max(0, u.adults - owned)
      local need = homeless + 4 - free
      if need > 0 then
        request(K, 'bedrooms', clamp(need, 4, 20), string.format('free %d < homeless %d + 4', free, homeless))
      end
    end
  end
  -- care owns the tomb request when it is loaded (CONTRACTS §18.4); this is the fallback
  if not K.enabled('care') and keeper_on(K, 'tombs') then
    local free = zones('ZONE_TOMB')
    if free then                             -- free tombs >= corpses + 6
      local v = K.view().care
      local corpses = type(v) == 'table' and int(v.corpses_old) or 0
      local need = corpses + 6 - free
      if need > 0 then
        request(K, 'tombs', clamp(need, 6, 30), string.format('free %d < corpses %d + 6', free, corpses))
      end
    end
  end
end

---------------------------------------------------------------- runs
local function end_run(K)
  local t = now(K)
  if K.mode() == 'PEACE' then
    for _, P in ipairs(S.pd.list) do
      if P.done ~= 1 and P.blocked ~= '' and P.blocked ~= 'cancel' and t - P.since > M.CFG.blocked_a then
        local R = R_of(K, P)
        if R.be ~= 1 then
          local d = doc(K, P.id)
          local st = d and d.stages[P.stage + 1]
          K.emit('PROJECT_BLOCKED', 'A', P.id .. ' (' .. P.tpl .. ') blocked: ' .. P.blocked,
                 {proj = P.id, tpl = P.tpl, stage = trunc(st and st.label or '', 24), why = P.blocked,
                  ticks = t - P.since})
          R.be = 1
          dirty()
        end
      end
    end
  end
  phases(K)
  if K.mode() == 'PEACE' then exhausted(K) end
  keepers(K)
  prune(M.CFG.done_keep)
  rows(K)
end

local function begin_run(K)
  sync_plan(K)
  S.snap_ok = K.enabled('snapshot')
  S.active = {}
  local tasks, n, t = {}, 0, now(K)
  local list = sorted()
  for _, P in ipairs(list) do
    local R = S.rt.p[P.id]
    if (type(R) == 'table' and R.undo) or P.blocked == 'cancel' then tasks[#tasks + 1] = {k = 'undo', id = P.id} end
  end
  -- pass 1: projects that can progress; pass 2: stalled ones (waiting for materials or workers) take
  -- the slots left over, otherwise up to meas_extra of them get a measure-only pass when due
  local extra = 0
  for pass = 1, 2 do
    for _, P in ipairs(list) do
      if not halted(P) and (P.blocked == 'stalled') == (pass == 2) then
        local ok = allowed(K, P, doc(K, P.id))
        if ok and n < M.CFG.active then
          n = n + 1
          S.active[P.id] = true
          tasks[#tasks + 1] = {k = 'work', id = P.id}
        else
          local R = R_of(K, P)
          if ok and pass == 2 and extra < M.CFG.meas_extra and (R.mt == nil or t - R.mt >= M.CFG.meas_every) then
            extra, R.mt = extra + 1, t
            tasks[#tasks + 1] = {k = 'work', id = P.id, meas = true}
          end
          R.last = t                         -- waiting (queued or frozen) is no stall
          dirty()
        end
      end
    end
  end
  tasks[#tasks + 1] = {k = 'end'}
  S.run = {tasks = tasks, i = 1}
end

---------------------------------------------------------------- module interface
function M.init(K)
  S = {tiles = {}, bbox = {}, meas = {}, absent = {}, rows = {}, active = nil, slice = {qf = 0, probes = 0, qf_max = 1}}
  local pd = K.persist.get('projects')
  if type(pd) ~= 'table' or type(pd.list) ~= 'table' then pd = {v = 2, list = {}}; K.persist.set('projects', pd) end
  S.pd = pd
  local rt = K.persist.get('m.runner')
  if type(rt) ~= 'table' then rt = {} end
  rt.v, rt.p, rt.hist, rt.planned, rt.req = 2, obj(rt.p), obj(rt.hist), obj(rt.planned), obj(rt.req)
  if type(rt.exh) ~= 'string' then rt.exh = '' end
  K.persist.set('m.runner', rt)
  S.rt = rt
  local ph = K.persist.get('phase')
  S.phase = type(ph) == 'table' and ph.phase or nil
  rows(K)
end

function M.step(K, budget, ctx)
  S.slice = {qf = 0, probes = 0, qf_max = M.CFG.qf_per_slice}
  if not (ctx and ctx.cont) or not S.run then begin_run(K) end
  local run = S.run
  while run.i <= #run.tasks do
    local task = run.tasks[run.i]
    local P = task.id and find(task.id)
    local r = 'done'
    if task.k == 'end' then end_run(K)
    elseif P and task.k == 'undo' then r = undo(K, P)
    elseif P and task.k == 'work' and P.done ~= 1 and not halted(P) then
      -- the mode may change between slices of one run (SIEGE/BREACH freeze the runner at once)
      if allowed(K, P, doc(K, P.id)) then r = work(K, P, task.meas)
      else R_of(K, P).last = now(K); dirty() end
    end
    if r == 'yield' then save(K); return 'more' end
    run.i = run.i + 1
  end
  S.run = nil
  save(K)
end

function M.state(K) return {phase = S.phase, proj = S.rows} end

M.on = {
  -- damp/warm cancel and cavern reports stop the dig of every nearby project (no pos: all diggers)
  REPORT = function(K, ev)
    local why = REPORT_WHY[ev.type]
    if not why then return end
    local text = type(ev.text) == 'string' and ev.text:lower() or ''
    if why == 'cavern' then
      if text:find('magma', 1, true) then why = 'warm'
      elseif text:find('river', 1, true) or text:find('lake', 1, true) or text:find('water', 1, true) then why = 'water' end
    end
    local p = type(ev.pos) == 'table' and ev.pos or nil
    local pos = p and {int(p.x or p[1]), int(p.y or p[2]), int(p.z or p[3])}
    if pos and not (pos[1] and pos[2] and pos[3]) then pos = nil end
    if not pos and ev.type == 'CAVE_COLLAPSE' then return end
    local r = (why == 'damp' or why == 'warm') and M.CFG.breach_r or M.CFG.cavern_r
    S.slice = {qf = 0, probes = 0, qf_max = M.CFG.undo_now}
    for _, P in ipairs(S.pd.list) do
      local d = P.done ~= 1 and doc(K, P.id)
      local st = d and d.stages[P.stage + 1]
      if st and st.mode == 'dig' and P.chunk > 0 and (not pos or near(pos, stage_tiles(P.id, d, P.stage).bbox, r)) then
        if breach(K, P, why, pos, 'report') then undo(K, P) end
      end
    end
    rows(K)
    save(K)
  end,
  ['EV:PROJECT_REQUEST'] = function(K, ev)
    local tpl = type(ev.d) == 'table' and ev.d.tpl
    if type(tpl) == 'string' and tpl ~= '' then S.rt.req[tpl] = ev.tick; dirty(); save(K) end
  end,
  MODE = function(K) rows(K) end,
  UNLOAD = function(K) save(K) end,
}

M.verbs = {
  ['bp.place'] = function(K, args, cmd)
    if type(args.tpl) ~= 'string' then return false, 'tpl required' end
    local id = type(cmd) == 'table' and cmd.id
    if type(id) ~= 'string' or not id:match('^[A-Za-z0-9_-]+$') or #id > 40 then return false, 'bad command id' end
    local P = find(id)
    if P then return true, (P.done == 1 and 'already done ' or 'already queued ') .. id, {proj = id} end
    local prio = args.prio == nil and 4 or int(args.prio)
    if not prio or prio < 1 or prio > 7 then return false, 'prio must be 1..7' end
    local d, err = read_bp(K, id)
    if not d then return false, 'bp/' .. id .. '.json: ' .. err end
    local ok, e = register(K, id, d, prio, args.tpl)
    if not ok then return false, e end
    save(K)
    return true, string.format('queued %s (%s, %d stages)', id, d.tpl, #d.stages), {proj = id}
  end,
  ['bp.cancel'] = function(K, args)
    local P = type(args.proj) == 'string' and find(args.proj)
    if not P then return false, 'no project ' .. tostring(args.proj) end
    if P.done == 1 then return false, P.id .. ' is already done' end
    if args.undo ~= nil and type(args.undo) ~= 'boolean' then return false, 'undo must be true or false' end
    if P.blocked == 'cancel' then return true, P.id .. ' is already being cancelled' end
    cancel(K, P, args.undo == true)
    rows(K)
    save(K)
    return true, (args.undo and 'cancelling ' .. P.id .. ' (undo queued)' or 'cancelled ' .. P.id)
  end,
}

return M
