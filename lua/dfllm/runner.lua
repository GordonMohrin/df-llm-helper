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
-- Run 11 siege 8: seal first (seals and plugs before everything, SEAL_STUCK) and the rebuild policy (state sched).
local json = require('dfllm.util.json')
local C = require('dfllm.util.contract')
local geom = require('dfllm.util.geom')
local CAD = require('dfllm.util.cadence')   -- BUG-022: PROJECT_BLOCKED once per stage and cause
local fio = require('dfllm.io')             -- Run 11: the bp folder (explores that left the list)

local M = {name = 'runner', every = {ticks = 600},
           reports = {DIG_CANCEL_DAMP = true, DIG_CANCEL_WARM = true, CAVE_COLLAPSE = true,
                      FEATURE_DISCOVERY = true}}

local DAY = C.TICKS.DAY
M.CFG = {
  active = 3,            -- projects worked on at once (DESIGN §4)
  qf_per_slice = 1,      -- quickfort calls per slice
  probe = 300,           -- snapshot.tile probes per slice
  hidden_wait = 2 * DAY, -- a dig stage whose only pending tiles are hidden completes after this long
                         -- without progress (live L1: a 'j' above a 'u' stays hidden, DF posts no job)
  stall = 7 * DAY,       -- no progress for this long -> blocked 'stalled' (builds wait for materials)
  meas_every = 2 * DAY,  -- a stalled project without a slot is re-measured (no applies) this often
  meas_extra = 1,        -- such measure-only passes per run, outside the slot budget
  blocked_a = 2 * DAY,   -- blocked longer than this -> PROJECT_BLOCKED (A), once per episode
  dry_every = 2 * DAY,   -- dig measurement by quickfort dry run when there is no snapshot module
  keep_every = 3 * DAY, req_cool = 7 * DAY,
  lost_pct = 10,         -- buildings still missing after one re-apply that let a stage pass (%)
  remake_max = 4,        -- Run 11: more re-applies of a seal stage whose lost pieces economy can make (M.remake)
  -- BUG-022 (Run 10: fortcore stage 2 ended build_lost for two game years, B1 and its levers never built): a
  -- build_lost stage is tried again from its dig stage once the hidden tiles that dig completed without are
  -- revealed or more of its missing cells stand on open floor (checked every retry_check), at the latest
  -- retry_every after the block; at most retry_max times; skip_max hidden tiles kept per project
  retry_every = C.TICKS.SEASON, retry_check = DAY, retry_max = 8, retry_probe = 120, skip_max = 200,
  plan_loads = 1, list_max = 64, done_keep = 16, fail_max = 3,
  orders_cells = 8,      -- cells per quickfort 'orders' call (S6: one 19-cell call took 60 ms; KPI: any call
                         -- <= 50 ms; about 8 ms fixed plus 1-2 ms per cell), one call per slice
  -- BUG-042 (Run 11, y471: 110 ConstructDoor among 446 manager orders): seals, their retries and remakes ordered a
  -- door again for every door cell whose planned door was gone, while the older rock orders still waited for stone. A
  -- door or hatch cell gets no quickfort order while the open one-time orders of its job hold orders_cap items
  -- (economy's T.jmake orders what a planned door still waits for, counting those orders)
  orders_cap = 10,
  -- BUG-044 (Run 11 y483: a seal door got no order while the fort held 110 open door orders): a seal's door and hatch cells
  -- ignore orders_cap, at most orders_seal door/hatch items for one seal project in all (retries and remakes included).
  -- A door stuck seal_wall_days after SEAL_STUCK becomes a constructed wall when the last entrance check (at most
  -- wall_age old) shows the citizens another way (seal.opening_ways). config seal_first {wall, wall_days}
  orders_seal = 12, seal_wall = true, seal_wall_days = 2, wall_age = 60 * DAY,
  -- BUG-045 (Run 11 note 47): designations DF removed while an alert froze a dig project are designated again, at most
  -- redig_max times a chunk (they do not count against the second-loss block 'dig_lost')
  redig_max = 6,
  -- BUG-046: a part lost or refused while other parts wait is placed again up to reapply_max times, reapply_gap apart
  reapply_max = 6, reapply_gap = DAY,
  breach_r = 3, cavern_r = 10, undo_now = 2,
  -- live L6 (Laborkings: a light aquifer under most of the map, damp from z128 down): a human digs through a
  -- light aquifer - damp stone is designated again and shallow seepage (<= seep_max/7) is no stop. Deep
  -- water, caverns, magma and warm stone still stop the project.
  damp_dig = false, damp_redig = 6, seep_max = 3,   -- per fort: persist m.runner.damp_dig (light aquifer site)
  -- Run 11 (Kilrudrabed site98): an explore shaft broke into a cavern lake (1146 visible water tiles on z127) and was
  -- stopped as 'damp'. A breach is a cavern lake when >= lake_min revealed water tiles outside the project's own dug
  -- tiles connect to it within lake_r (its level +- 1) and a revealed cavern tile lies there or beside it; an explore
  -- shaft open to a cavern is plugged at once (a constructed wall on its two top stair tiles; the lower one is given
  -- up when a step of it waits plug_wait). Projects stopped as damp/water/cavern look again every `recheck`.
  lake_r = 12, lake_min = 30, plug_wait = DAY, recheck = DAY, cav_keep = 16,
  -- BUG-129 (Run 14: a seal's walls far apart spanned the map as one audit box): boxes() names a project's tile
  -- clusters (tiles within part_gap join) as parts, at most part_max of them
  part_gap = {6, 6, 1}, part_max = 8,
  lake_r0 = 4,           -- BUG-033: the first wider box; lake_r only when the flood reaches its edge
  -- Run 11 (c1a14676 stood 'stalled' with its shaft open to a cavern lake): every explore shaft is looked at daily
  -- whatever its project's state, at most shaft_n per run, reading at most shaft_probe of its dug tiles for water
  shaft_n = 4, shaft_probe = 60, shaft_keep = 24, scan_n = 8, cav_levels = 32,
  -- BUG-033 (Run 11 site98, y438: runner 35 ms/s in PEACE, frames up to 447 ms): the check is sliced (the stopped
  -- digs and the bp scan one slice, then one shaft a slice); a finished explore (done, cancelled, gone) whose last
  -- look found water in reach but no cavern is looked at every fin_every (a dry one and live ones stay daily); a bp
  -- file is decoded only when it is an explore's (and once a boot: what the check needs of it is kept, S.xdoc)
  fin_every = 8 * DAY,
  -- BUG-039 (Run 11 y451: 'cavern check: ... 11 more next run' every run, the same shafts again and again: runs 4+ days
  -- apart, 15 shafts due daily, shaft_n looks a run): while more shafts are due than a run looks at (saturated), a
  -- finished shaft whose look did not change waits fin_every, then twice as long after each unchanged look, at most
  -- fin_max_d days; a change, or a live explore: daily again. Live explores are looked at first. The log line only
  -- names news (a changed look, the first look after a boot, a plug, a stop); else a summary per util/cadence
  fin_max_d = 64,
  -- Run 11 (siege 8, y441 spring: pop 52 -> 3): the way in 114,73,143 had no door; its seal (c1a147c261), placed two
  -- days before the attack, waited unfinished behind the other projects. Seal first: an open seal or cavern plug takes
  -- the first slots (also when stalled), digs at designation priority 1 and moves its quickfort orders to the top of
  -- the work orders; in PEACE the housing/work projects pause until it is done, or until it built nothing for
  -- seal_stuck_days (SEAL_STUCK, A: the others run again). Rebuild (Run 11 after siege 8: 2 citizens, 59 unburied
  -- dead): below rebuild_pop citizens in a fort past P1 or that had rebuild_off of them, in PEACE/RECOVERY only seal,
  -- plug, tombs, food/drink, beds, wall repairs and the depot run, until rebuild_off. config/baseline.json "runner":
  -- {seal_first: {on, stuck_days, food_d, drink_d}, rebuild: {pop, off}} (fairplay.RUNNER_LIM; a bad value: default)
  seal_first = true, seal_stuck_days = 3, emerg_food_d = 30, emerg_drink_d = 30, rebuild_pop = 10, rebuild_off = 12,
  -- BUG-116 (Run 14 note 89: hospital_out for 60 game years, the hospital placed seven times and parked at "dig 0 %, slot
  -- yielded"): care first. While hospital_out is set or care_patients patients lie in the fort the hospital project runs first
  -- and the work and housing projects pause (PEACE); one that makes no progress for care_stuck_days stops pausing them.
  -- config/baseline.json "runner": {care_first: {on, stuck_days, patients}}
  care_first = true, care_stuck_days = 10, care_patients = 1,
  hold_n = 3,            -- paused projects in a dig stage watched per run (miners dig what is designated: a breach)
  -- BUG-037 (Run 11 y449: bedrooms, stockroom, tavern, tombs and a prio-2 depot 'queued' at 0 % for months, 15 of 27
  -- adults idle): a slot holder whose own progress (a chunk applied, manager orders made, measured progress, a stage
  -- done: R.ps) is yield_days old yields its slot (it competes with the stalled projects); a seal or plug keeps its slot
  -- while stalled only until it is stuck (seal_first.stuck_days). A project blocked for good (build_lost with its
  -- retries spent, breach:*, apply_fail, bp_missing, plug_refused) is parked after park_days: it no longer counts for
  -- the seal-first pause, the keepers, M.pending, the depot keeper and PLAN_EXHAUSTED, its row goes last, and
  -- PROJECT_BLOCKED names the cancel command once. Never cancelled by the kernel (an undo removes built work, and an
  -- explore's box stays in the audit). config/baseline.json "runner": {queue: {yield_days, park_days}}. Watchdog: a
  -- task that yields task_slices times in a row is skipped this run (kern.log); state sched.run once no run ended for
  -- run_idle_d days
  yield_days = 7, park_days = 30, task_slices = 600, run_idle_d = 3,
  -- BUG-066 (Run 14 y560: a toppled MetalsmithsForge stayed `built` in manifest.json and "bp sites workshops" said
  -- "nothing left to build" while a mood dwarf had no workshop) and FR-76 (Run 12 Trussroads, a reclaimed fort with
  -- workshops no project of ours built): once a game day the manifest's workshops are compared with the workshops that
  -- stand. One missing for rec_scans scans in a row leaves the manifest (and is listed in manifest.gone, so the
  -- fragments of the bp files older than the loss no longer count either); a standing built one the manifest lacks is
  -- added (adoption). rec_min = standing workshops adopted at the first scan that make the fort a reclaimed one;
  -- rec_ask = days a mandatory workshop of a reclaimed fort may be missing before PROJECT_REQUEST workshops
  -- why=mandatory. config/baseline.json "runner": {reclaim: {on, gone_scans, min_ws, ask_days}}
  rec_scans = 2, rec_min = 3, rec_ask = 3,
}
local MODES = {dig = true, build = true, place = true, zone = true, burrow = true}
local CLASSES = {defense = true, infra = true, living = true, beauty = true}
local MINE = {d = true, h = true, u = true, j = true, i = true, r = true}  -- dig keys that remove the wall
local WALL = {['#'] = true, S = true}
local HAZARD = {w = 'water', ['~'] = 'water', ['%'] = 'warm'}
local REPORT_WHY = {DIG_CANCEL_DAMP = 'damp', DIG_CANCEL_WARM = 'warm', FEATURE_DISCOVERY = 'cavern',
                    CAVE_COLLAPSE = 'cavern'}
-- breach kinds a look at the revealed tiles may raise (never lower): damp/water seepage < cavern < cavern lake
local RANK = {damp = 1, water = 2, cavern = 3, cavern_lake = 4}
local CAVERN = {cavern = true, cavern_lake = true}
-- the 12 moodable workshop types (dfpilot/bp/rooms.py MOODABLE_TYPES, DESIGN §5.9)
M.MOODABLE = {'Carpenters', 'Masons', 'Craftsdwarfs', 'Jewelers', 'MetalsmithsForge', 'Bowyers',
              'Clothiers', 'Leatherworks', 'Tanners', 'Loom', 'GlassFurnace', 'Mechanics'}
-- deliverable kind -> module that makes it measurable; an absent module skips the deliverable
local OWNER = {baseline = 'baseline', squads = 'military', metal = 'military', drill = 'readiness',
               ready = 'readiness', stock = 'economy', orders = 'economy', bolts = 'economy', trade = 'trade'}
local PLAN_DRIVEN = {proj = true, workshops = true}

local S = {}   -- module state, rebuilt by init (persist docs + caches)
local Q = {}   -- BUG-037: the slot and park rules (a table: the main chunk is near Lua's 200 locals)

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
local SEALS = {seal = true, plug = true}     -- seal first (Run 11 siege 8): what closes a way in runs before the rest
local function dprio(P) return SEALS[P.tpl] and 1 or P.prio end   -- a seal's dig designations: priority 1
local function pnum(id) return int(tostring(id or ''):match('^P([0-9])$')) end
local function qf_room() return S.slice.qf < S.slice.qf_max end
-- BUG-039 (Run 11 y451: one runner step took 68.6 s, kern.log named only 'runner'): what this slice does, for kern's
-- slow and huge step lines (M.doing): 'work y451s3b0 s2.place chunk 1/1 (task 1/3, slice 1)'
function Q.doing(P, st, what)
  local d = S.dtask
  S.doing = string.format('%s%s%s%s%s', d and d.k or 'run', P and (' ' .. P.id) or '', st and (' ' .. st.label) or '',
                          what and (' ' .. what) or '', d and string.format(' (task %d/%d, slice %d)', d.i, d.n, d.sl) or '')
end
local function qf(K, p) S.slice.qf = S.slice.qf + 1; return K.act.quickfort(p) end

-- last = no stall before it (waiting resets it); ps = the project's own last progress (BUG-037: waiting for a slot
-- resets it, holding one does not)
local function new_R(t, si)
  return json.object{si = si, prog = 0, last = t, ps = t, cd = '', cdt = 0, b = {}, c = {}, uns = 0, ra = 0, fail = 0}
end
local function moved(K, R) local t = now(K); R.last, R.ps = t, t end
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
  if S.own then S.own[id] = nil end                -- BUG-033: own_tiles cache
  S.bbox[id], S.meas[id] = nil, nil
  if S.cl then S.cl[id] = nil end                   -- BUG-129: tile clusters
  if S.rt and S.rt.skip then S.rt.skip[id], S.rt.rty[id], S.rt.pb[id] = nil, nil, nil end   -- BUG-022 records
  if S.rt and S.rt.br then S.rt.br[id] = nil end    -- Run 11: the breach record (m.runner cav outlives the project)
  if S.rt and S.rt.dw then S.rt.dw[id] = nil end    -- Run 11: the seal doors planned as walls (door_walls)
  if S.rt and S.rt.sw then S.rt.sw[id], S.rt.so[id] = nil, nil end    -- BUG-044: stuck doors walled, door order items
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
          if d then ok, err = register(K, id, d, int(b.prio) or 4, b.tpl)
          elseif b.tpl == 'seal' and err == 'missing' then
            -- BUG-047: plan apply left a seal out that had nothing to close (every opening closed, or a seal has it)
            ok = true
            K.log('info', 'plan build %s (seal): no blueprint, nothing was left to close when the plan was applied', id)
          end
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
    elseif BY[k] then
      dst[k] = replace_by(dst[k], v, BY[k][1], BY[k][2])
      if k == 'workshops' and type(dst.gone) == 'table' then dst.gone = Q.ungone(dst.gone, v) end   -- BUG-066
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

-- dig: true for a dig stage. Miners are shared: a dig stage only stalls when no dig stage of any project
-- progressed for `stall` (live L1b: a dining hall queued behind a 200-tile workshop dig was reported
-- blocked after 7 days while three miners dug next door)
local function progress(K, P, d, R, done, total, dig)
  P.pct = pct_of(P, d, total > 0 and (100 * done) // total or 0)
  local t = now(K)
  if done > R.prog then
    R.prog, R.last, R.ps = done, t, t
    if dig then S.rt.dpt = t end
    if P.blocked == 'stalled' then set_blocked(K, P, '') end
  elseif P.blocked == '' and t - R.last >= M.CFG.stall and not (dig and t - (S.rt.dpt or -M.CFG.stall) < M.CFG.stall) then
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
-- plug (Run 11): the cavern plug's own rule: no hazard stops it, and a channel ('h' on a stair) is done only once the
-- tile is open space (or walled already); a stair that keeps no designation was refused or cancelled.
local function probe(K, t, seen, plug)
  local ok, v = K.call('snapshot', 'tile', t[1], t[2], t[3])
  if not ok then return nil end
  S.slice.probes = S.slice.probes + 1
  local key = t[4]
  if type(v) ~= 'table' or v.c == nil or v.c == '?' then          -- hidden or off the map
    local onm = on_map(t[1], t[2], t[3])
    if MINE[key] and onm and not on_edge(t[1], t[2], t[3]) then return 'pend', nil, true, true end
    return 'skip', nil, nil, onm or nil                             -- BUG-022: hidden, kept for the retry
  end
  if plug then
    if v.dig ~= nil and v.dig ~= '' then return 'pend', nil, true end
    if key == 'h' and not (v.c == '_' or v.c == 'v' or v.c == 'C') then return seen and 'lost' or 'skip' end
    return 'done'
  end
  if HAZARD[v.c] == 'water' and M.CFG.damp_dig then
    local depth = int(v.flow) or 7
    if depth <= M.CFG.seep_max and not v.magma then return 'done' end
  end
  if HAZARD[v.c] then return 'breach', HAZARD[v.c] end
  if v.dig ~= nil and v.dig ~= '' then return 'pend', nil, true end
  if MINE[key] then
    if not WALL[v.c] then return 'done' end
    if seen then return 'lost' end
    return 'skip', 'wall'                  -- BUG-045: a wall nobody saw designated (refused, or DF took it in an alert)
  end
  if (key == 's' and v.c == '#') or (key == 'F' and WALL[v.c]) then return 'skip' end
  return 'done'
end

local function mask_set(s, i)
  if #s < i then s = s .. string.rep('0', i - #s) end
  return s:sub(1, i - 1) .. '1' .. s:sub(i + 1)
end

local breach -- forward
local note_cavern -- forward (Run 11: cavern breach levels for the explore ranking)

-- DF announces a damp or warm stop with DIG_CANCEL_DAMP / DIG_CANCEL_WARM (spike S7 ids 52/51); this
-- scans the newest `n` entries of the vanilla announcement log (world.status.reports, what the player
-- reads) for one near `bb`. Returns 'damp'/'warm', nil when there is none, 'unknown' when the log cannot
-- be read (callers then stay on the safe side).
local CANCEL_REPORT = {DIG_CANCEL_DAMP = 'damp', DIG_CANCEL_WARM = 'warm'}
function M.cancel_reported(bb, r, n)
  local ok, why = pcall(function()
    local reps = df.global.world.status.reports
    for i = #reps - 1, math.max(0, #reps - (n or 200)), -1 do
      local rep = reps[i]
      local w = CANCEL_REPORT[df.announcement_type[rep.type] or '']
      if w and near({rep.pos.x, rep.pos.y, rep.pos.z}, bb, r) then return w end
    end
  end)
  if not ok then return 'unknown' end
  return why
end

-- A designated tile turned into an undesignated wall. Live L1: this happened on the first ramp tiles of
-- both fortcore sites with no damp report in the announcement log, and the very tile then dug fine, so a
-- lost designation alone is no damp proof. Damp/warm stop on their vanilla reports (on.REPORT, or found
-- here in the log); otherwise the chunk is designated again once (quickfort only re-marks walls still
-- standing) and a second loss blocks the project ('dig_lost', PROJECT_BLOCKED after 2 days) without undo.
-- BUG-045 (Run 11 note 47: the stair designation at z127 of the deep shaft vanished after a BREACH, the ones below stayed,
-- and the shaft stood still): nothing in the kernel cancels a designation (no code path does), so DF took it while an
-- alert had frozen the project. The runner marks that freeze (R.fz, step and begin_run) and, once the project runs
-- again, designates the chunk's walls anew: quickfort marks only walls still standing. Once per freeze and chunk
-- (R.fd), at most redig_max times a chunk (R.ar); this loss does not count against the second-loss block 'dig_lost'.
-- The freeze is a mode that does not let the project run (ALERT/SIEGE/BREACH for an infra project) or the civil alert
-- being on (S.civ: the miners are confined to its burrow in every mode, a reflex lockdown too); the chunk is designated
-- anew only once the alert is off (the miners could not dig it before), and never when a damp or warm cancel report lies
-- near the stage (that is the stop's business: BREACH_STOP 'damp'/'warm', never digging into the seepage again).
-- true = designated again, 'yield' = no quickfort call left in this slice, 'wait' = the alert is still on, false = no
-- alert, a report near, or the budget is spent
function Q.froze(K, P, d, R)
  local st = d and d.stages[P.stage + 1]
  if st and st.mode == 'dig' and P.chunk > 0 and R.si == P.stage then R.fz = now(K) end
end
function Q.redesignate(K, P, d, R, ci, n)
  local sk = tostring(ci)
  R.fd, R.ar = obj(R.fd), obj(R.ar)
  if not (int(R.fz) and int(R.fz) > (int(R.fd[sk]) or 0)) or (int(R.ar[sk]) or 0) >= M.CFG.redig_max then return false end
  if M.cancel_reported(stage_tiles(P.id, d, P.stage).bbox, M.CFG.breach_r) then return false end
  if S.civ then return 'wait' end
  if not qf_room() then return 'yield' end
  local ch = Q.nogather(P, d.stages[P.stage + 1].chunks[ci])
  qf(K, {mode = 'dig', data = chunk_data(ch), pos = ch.pos, priority = dprio(P)})
  R.fd[sk], R.ar[sk] = now(K), (int(R.ar[sk]) or 0) + 1
  K.log('warn', '%s %s chunk %d: %d tiles lost their designation (an alert froze the project): designated again (%d/%d)',
        P.id, d.stages[P.stage + 1].label, ci - 1, n, R.ar[sk], M.CFG.redig_max)
  dirty()
  return true
end

local function lost(K, P, d, R, ci, t)
  local ch = d.stages[P.stage + 1].chunks[ci]
  local bb = stage_tiles(P.id, d, P.stage).bbox
  local why = P.tpl ~= 'plug' and M.cancel_reported(bb, M.CFG.breach_r) or nil   -- the cavern plug never stops
  R.rl = obj(R.rl)
  local sk = tostring(ci)
  -- light aquifer (damp_dig): DF often cancels damp stone without a report the log search finds (live L6)
  if (why == nil or why == 'damp' or why == 'unknown') and M.CFG.damp_dig then
    if (R.rl[sk] or 0) < M.CFG.damp_redig and qf_room() then
      R.rl[sk] = (R.rl[sk] or 0) + 1
      qf(K, {mode = 'dig', data = chunk_data(ch), pos = ch.pos, priority = dprio(P)})
      K.log('warn', '%s chunk %d: damp stone at %d,%d,%d designated again (light aquifer, %d/%d)', P.id, ci - 1,
            t[1], t[2], t[3], R.rl[sk], M.CFG.damp_redig)
      dirty()
      return
    end
    why = 'damp'
  end
  if why then return breach(K, P, why == 'unknown' and 'damp' or why, {t[1], t[2], t[3]}, 'cancel') end
  if Q.redesignate(K, P, d, R, ci, 1) then return end         -- BUG-045: an alert took it: no count against dig_lost
  if (R.rl[sk] or 0) >= 1 or not qf_room() then
    if (R.rl[sk] or 0) >= 1 then
      K.log('error', '%s %s chunk %d: designation at %d,%d,%d lost twice without a damp report: blocked', P.id,
            d.stages[P.stage + 1].label, ci - 1, t[1], t[2], t[3])
      set_blocked(K, P, 'dig_lost')
    end
    return
  end
  R.rl[sk] = 1                                  -- the seen marks stay: the tiles are designated again
  qf(K, {mode = 'dig', data = chunk_data(ch), pos = ch.pos, priority = dprio(P)})
  K.log('warn', '%s %s chunk %d: designation at %d,%d,%d lost without a damp report: chunk designated again', P.id,
        d.stages[P.stage + 1].label, ci - 1, t[1], t[2], t[3])
  dirty()
end

-- BUG-022: the hidden tiles a dig stage completed without (quickfort could not designate them, or nobody reached
-- them), per chunk: m.runner skip[<proj>] = {si, n, c = {['<chunk>'] = {{x, y, z}, ...}}}, at most skip_max tiles.
-- A build_lost retry asks snapshot.tile whether they are revealed now (hidden tiles answer nil and are never read).
local function note_skipped(P, si, ci, list)
  if #list == 0 then return end
  local r = S.rt.skip[P.id]
  if type(r) ~= 'table' or r.si ~= si then r = {si = si, n = 0, c = json.object{}}; S.rt.skip[P.id] = r end
  r.c = obj(r.c)
  local key = tostring(ci)
  local l = type(r.c[key]) == 'table' and r.c[key] or {}
  for _, t in ipairs(list) do
    if r.n >= M.CFG.skip_max then break end
    l[#l + 1] = {t[1], t[2], t[3]}
    r.n = r.n + 1
  end
  r.c[key] = l
  dirty()
end

local function measure_dig(K, P, d, R)
  local tiles = stage_tiles(P.id, d, P.stage)
  local m = S.meas[P.id]
  if not m or m.si ~= P.stage then
    m = {si = P.stage, ci = 1, pend = 0, done = 0, hid = 0, snap = S.snap_ok, hidl = {}}
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
        local hs, hp, walls = {}, {}, 0      -- BUG-022: hidden tiles skipped / pending in this chunk; BUG-045: walls skipped
        local plug = P.tpl == 'plug'
        for i, t in ipairs(tl) do
          local seen = sp:sub(i, i) == '1'
          local r, why, mark, hidden
          if t[4] == 'p' and P.tpl == 'seal' then r = Q.gathered(K, P, d, R, t)    -- BUG-041: no gather waited for
          else r, why, mark, hidden = probe(K, t, seen, plug) end
          if r == 'skip' and why == 'wall' then walls = walls + 1 end
          if hidden then
            if r == 'pend' then m.hid = m.hid + 1; hp[#hp + 1] = t else hs[#hs + 1] = t end
          end
          if r == nil then S.snap_ok, S.meas[P.id] = false, nil; return 'yield' end   -- dry run instead
          if mark and not seen then sp = mask_set(sp, i); R.sp[sk] = sp; dirty() end
          if r == 'breach' then
            S.meas[P.id] = nil
            breach(K, P, why, {t[1], t[2], t[3]}, 'tile')
            return 'done'
          end
          if r == 'lost' then
            S.meas[P.id] = nil
            lost(K, P, d, R, ci, t)
            return 'done'
          end
          if r == 'pend' then pend = pend + 1 elseif r == 'skip' then skip = skip + 1 else done = done + 1 end
        end
        if walls > 0 then                    -- BUG-045: walls without a designation after an alert froze the project
          local rd = Q.redesignate(K, P, d, R, ci, walls)
          if rd == 'yield' then return 'yield' end
          if rd then pend, skip = pend + walls, skip - walls end      -- designated again, or the alert is still on
        end
        if pend > 0 then m.hidl[#m.hidl + 1] = {ci = ci - 1, hs = hs, hp = hp} end
        if pend == 0 then
          R.sp[sk] = nil
          note_skipped(P, P.stage, ci - 1, hs)
          if skip > 0 then
            R.sk = (R.sk or 0) + skip
            K.log('info', '%s %s chunk %d: %d tiles never designated, skipped', P.id, d.stages[P.stage + 1].label,
                  ci - 1, skip)
          end
        end
        done = done + skip
      else
        if not qf_room() then return 'yield' end
        local ch = Q.nogather(P, chunks[ci])  -- BUG-041: a seal's gather cells count as done
        local left = 0
        if #ch.cells > 0 then
          local ok, st = qf(K, {mode = 'dig', data = chunk_data(ch), pos = ch.pos, dry_run = true})
          left = ok and type(st) == 'table' and int(st.dig_designated)       -- dig.lua:878, still to dig
        end
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
  progress(K, P, d, R, R.cdt + m.done, tiles.n, true)
  if m.pend > 0 and not (m.snap and m.pend == m.hid and now(K) - R.last >= M.CFG.hidden_wait) then return 'done' end
  if m.pend > 0 then
    K.log('warn', '%s %s: %d hidden tiles never reached; stage completes without them', P.id,
          d.stages[P.stage + 1].label, m.pend)
    R.sk = (R.sk or 0) + m.pend
    for _, h in ipairs(m.hidl) do
      local all = {}
      for _, t in ipairs(h.hs) do all[#all + 1] = t end
      for _, t in ipairs(h.hp) do all[#all + 1] = t end
      note_skipped(P, P.stage, h.ci, all)
    end
  end
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
  -- one re-apply: quickfort places only what is missing (Run 11: a seal again while economy can make its pieces).
  -- BUG-046 (Run 12 note 32: the workshops project stood at 62% 'stalled', its forge never built, and its kitchen, a part
  -- quickfort had refused, was never placed again): a part lost or refused is placed again whatever the other parts
  -- wait for; before, this was looked at only once every other building was built
  -- (while parts wait: up to reapply_max more times, reapply_gap apart, as a unit or an item in the way goes in hours)
  local t = now(K)
  if lost > 0 and (R.ra ~= 1 or (pend > 0 and (int(R.rn) or 0) < M.CFG.reapply_max
                                 and t - (int(R.rt) or 0) >= M.CFG.reapply_gap) or M.remake(K, P, d, R)) then
    R.b, R.uns, R.ra, P.chunk = keep, lost, 1, 0
    R.rn, R.rt = (int(R.rn) or 0) + 1, t
    dirty()
    return 'reapply'
  end
  if pend > 0 then return 'done' end
  if lost * 100 > total * M.CFG.lost_pct then
    set_blocked(K, P, 'build_lost')
    local q = obj(S.rt.rty[P.id])          -- BUG-022: the retry record (count kept across retries)
    q.n, q.t, q.sig, q.c = int(q.n) or 0, now(K), nil, now(K)
    S.rt.rty[P.id] = q
    return 'done'
  end
  R.lost = lost
  return 'complete'
end

---------------------------------------------------------------- cavern breach and plug (Run 11)
-- Run 11 (Kilrudrabed site98): the explore shaft 136,73 (z137 down) broke into a cavern lake on z127 (1146 visible
-- water tiles there, 662 on z126); DF's damp report stopped it and BREACH_STOP said 'damp', so nothing showed that the
-- shaft now led from the cavern into the core (Run 3 fell to forgotten beasts through an opened shaft). Fair play: only
-- revealed tiles (snapshot.liquids; snapshot.tile legend and cav = designation.feature_global), never water_table.
local function tkey(x, y, z) return x .. ',' .. y .. ',' .. z end

local N26 = {}
for dz = -1, 1 do
  for dy = -1, 1 do
    for dx = -1, 1 do if dx ~= 0 or dy ~= 0 or dz ~= 0 then N26[#N26 + 1] = {dx, dy, dz} end end
  end
end

-- every tile the project's stages name: water there lies in our own excavation (seepage), not in a natural body.
-- BUG-033: kept per project (S.own; forget and door_walls drop it): the damp reports and the daily check ask often
local function own_tiles(P, d)
  S.own = S.own or {}
  if S.own[P.id] then return S.own[P.id] end
  local own = {}
  for si = 0, #d.stages - 1 do
    local tiles = stage_tiles(P.id, d, si)
    for ci = 1, #tiles do
      for _, t in ipairs(tiles[ci]) do own[tkey(t[1], t[2], t[3])] = true end
    end
  end
  S.own[P.id] = own
  return own
end

-- the same for the document of a project that left the list (its bp file): not cached, nothing outlives the check
local function doc_own(d)
  local own = {}
  for _, st in ipairs(type(d) == 'table' and type(d.stages) == 'table' and d.stages or {}) do
    for _, ch in ipairs(type(st.chunks) == 'table' and st.chunks or {}) do
      for _, cell in ipairs(type(ch.cells) == 'table' and ch.cells or {}) do
        local out = {}
        cell_tiles(ch, cell, out)
        for _, t in ipairs(out) do own[tkey(t[1], t[2], t[3])] = true end
      end
    end
  end
  return own
end

local function tile_at(K, x, y, z)
  local ok, v = K.call('snapshot', 'tile', x, y, z)
  if S.slice then S.slice.probes = S.slice.probes + 1 end
  return ok and type(v) == 'table' and v or nil
end

-- What a breach at pos opened, from the revealed tiles: 'cavern_lake' (>= lake_min revealed water tiles outside the
-- project's own tiles, connected to pos within lake_r on its level +- 1, with a revealed cavern tile beside pos or in
-- that water, or none of the sampled water under the open sky), 'water' (such a body on the surface: a brook, a
-- river), 'cavern' (a revealed cavern tile beside pos), else nil (seepage: damp stays damp). Second value: the
-- connected water tiles counted. own = the project's own tiles (own_tiles / doc_own).
-- lq (BUG-033): a memo of the liquids reads, shared by the candidates of one shaft look (the same column: the same
-- wide boxes on overlapping levels)
local function opened_at(K, own, pos, lq)
  local x, y, z = int(pos and pos[1]), int(pos and pos[2]), int(pos and pos[3])
  if not (x and y and z) then return nil, 0 end
  local wet = {}
  local function liquids(x0, y0, x1, y1, zz)
    local key = x0 .. ',' .. y0 .. ',' .. x1 .. ',' .. y1 .. ',' .. zz
    local hit = lq and lq[key]
    if hit then return true, hit end
    local ok, list = K.call('snapshot', 'liquids', x0, y0, x1, y1, zz, 1)
    if lq and ok and type(list) == 'table' then lq[key] = list end
    return ok, list
  end
  -- the flood starts only at pos or a tile beside it: a dry 3x3x3 needs no wider read (the daily shaft check asks
  -- often); BUG-033: the box then grows (lake_r0, then lake_r) only while the flood reaches its edge, so a pocket of
  -- seepage costs a 9x9 read, not the 25x25 one
  local seen, queue, n, body
  local function flood(r)
    seen, queue, n, body = {}, {}, 0, {}
    local edge = false
    local function push(k) if wet[k] and not seen[k] then seen[k] = true; queue[#queue + 1] = wet[k] end end
    push(tkey(x, y, z))
    for _, o in ipairs(N26) do push(tkey(x + o[1], y + o[2], z + o[3])) end
    local i = 1
    while i <= #queue do
      local t = queue[i]
      i = i + 1
      if math.max(math.abs(t[1] - x), math.abs(t[2] - y)) >= r then edge = true end
      if not own[tkey(t[1], t[2], t[3])] then
        n = n + 1
        if #body < 16 then body[#body + 1] = t end
      end
      for dy = -1, 1 do
        for dx = -1, 1 do if dx ~= 0 or dy ~= 0 then push(tkey(t[1] + dx, t[2] + dy, t[3])) end end
      end
      push(tkey(t[1], t[2], t[3] - 1))
      push(tkey(t[1], t[2], t[3] + 1))
    end
    return edge
  end
  local radii = {1, math.min(M.CFG.lake_r0 or M.CFG.lake_r, M.CFG.lake_r), M.CFG.lake_r}
  for ri, r in ipairs(radii) do
    if ri == 1 or r > radii[ri - 1] then
      for dz = -1, 1 do
        local ok, list = liquids(x - r, y - r, x + r, y + r, z + dz)
        for _, w in ipairs(ok and type(list) == 'table' and list or {}) do
          wet[tkey(w[1], w[2], z + dz)] = {w[1], w[2], z + dz}
        end
      end
      if next(wet) == nil then break end
      if ri > 1 and (not flood(r) or ri == #radii) then break end
    end
  end
  if not seen then flood(M.CFG.lake_r) end
  local function cav(t) local v = tile_at(K, t[1], t[2], t[3]); return v ~= nil and v.cav == true end
  local found = cav({x, y, z})
  for _, o in ipairs(N26) do
    if found then break end
    found = cav({x + o[1], y + o[2], z + o[3]})
  end
  for _, t in ipairs(body) do
    if found then break end
    found = cav(t)
  end
  -- third value (BUG-033): the water tiles the flood reached ('x,y,z' set): a candidate among them answers the same
  if n >= M.CFG.lake_min then
    if found then return 'cavern_lake', n, seen end
    local ok, outs = K.call('snapshot', 'outside_near', body, 0)   -- an underground body without the cavern flag
    for _, o in ipairs(ok and type(outs) == 'table' and outs or {}) do if o == 1 then return 'water', n, seen end end
    return 'cavern_lake', n, seen
  end
  if found then return 'cavern', n, seen end
  return nil, n, seen
end

function M.opened(K, P, d, pos) return opened_at(K, own_tiles(P, d), pos) end

-- the project's stair column (dig cells u/j/i: the one under pos, else the longest): {x, y, top, low, zs = {[z] =
-- true}} or nil; tiles_of(si) = the document's tiles of stage si per chunk (stage_tiles, or raw_tiles uncached)
local STAIR_KEY = {u = true, j = true, i = true}
local function column_of(d, tiles_of, pos)
  local cols, keys = {}, {}
  for si = 0, #d.stages - 1 do
    if d.stages[si + 1].mode == 'dig' then
      local tiles = tiles_of(si)
      for ci = 1, #tiles do
        for _, t in ipairs(tiles[ci]) do
          if STAIR_KEY[t[4]] then
            local k = t[1] .. ',' .. t[2]
            if not cols[k] then cols[k] = {x = t[1], y = t[2], zs = {}, n = 0}; keys[#keys + 1] = k end
            if not cols[k].zs[t[3]] then cols[k].zs[t[3]], cols[k].n = true, cols[k].n + 1 end
          end
        end
      end
    end
  end
  table.sort(keys)
  local best
  for _, k in ipairs(keys) do
    local c = cols[k]
    if pos and c.x == int(pos[1]) and c.y == int(pos[2]) then best = c; break end
    if not best or c.n > best.n then best = c end
  end
  if not best then return nil end
  for z in pairs(best.zs) do
    if not best.top or z > best.top then best.top = z end
    if not best.low or z < best.low then best.low = z end
  end
  return best
end

-- a column read top down on revealed tiles: {x, y, top, bot, s0 = {x, y, z, char, building or nil}, s1 = the tile
-- below s0 or nil, wet = {{x, y, z}, ...} its tiles that hold water}; nil, why ('not dug': the top is rock, the column
-- does not reach the fort; 'hidden') otherwise. col.zs (else every z from top down to col.low) names its levels.
local function read_shaft(K, col)
  local v0 = tile_at(K, col.x, col.y, col.top)
  if not v0 then return nil, 'hidden' end
  if WALL[v0.c] then return nil, 'not dug' end        -- never dug at the top: the column does not reach the fort
  local b0 = (v0.bld == 'Hatch' or v0.bld == 'Door') and v0.bld or nil     -- Run 11: a hatch/door on the top
  local sh = {x = col.x, y = col.y, top = col.top, bot = col.top, s0 = {col.x, col.y, col.top, v0.c, b0}, wet = {}}
  if HAZARD[v0.c] == 'water' then sh.wet[1] = {col.x, col.y, col.top} end
  local z = col.top - 1
  while (col.zs and col.zs[z]) or (not col.zs and z >= (int(col.low) or col.top)) do
    local v = tile_at(K, col.x, col.y, z)
    if not v or WALL[v.c] then break end
    if z == col.top - 1 then sh.s1 = {col.x, col.y, z, v.c} end
    if HAZARD[v.c] == 'water' then sh.wet[#sh.wet + 1] = {col.x, col.y, z} end
    sh.bot, z = z, z - 1
  end
  return sh
end

local function shaft_of(K, P, d, pos)
  local col = column_of(d, function(si) return stage_tiles(P.id, d, si) end, pos)
  return col and read_shaft(K, col) or nil
end

-- the shaft is closed by a constructed wall: on its top, or (Run 11: a hatch or door on the top, the live 136,73,137)
-- on the tile below it. A hatch or a door alone is no plug: forgotten beasts and building destroyers pass them.
local COVER = {Hatch = true, Door = true}
local function walled(K, s0, s1)
  local v0 = type(s0) == 'table' and tile_at(K, s0[1], s0[2], s0[3]) or nil
  if not v0 then return false end
  if v0.c == 'C' then return true, 'top' end
  if v0.c ~= '+' and not COVER[v0.bld] then return false end
  local v1 = type(s1) == 'table' and tile_at(K, s1[1], s1[2], s1[3]) or nil
  return v1 ~= nil and v1.c == 'C', 'below'
end

-- Run 11 (c1a14676): the explore's shaft record m.runner xs[<id>] (see shaft_prep), made from d, else its bp file,
-- when the project is first looked at, done or cancelled (it outlives the project); nil for other templates or
-- without a stair column. raw_tiles: a stage's tiles per chunk, not cached (the record must not keep caches alive).
local function raw_tiles(d, si)
  local out = {}
  for ci, ch in ipairs(d.stages[si + 1].chunks) do
    local l = {}
    for _, cell in ipairs(ch.cells) do cell_tiles(ch, cell, l) end
    out[ci] = l
  end
  return out
end

-- BUG-033 (Run 11: every boot decoded each bp file of the fort, twice for the non-explores, 8 files a run, and every
-- daily look decoded a finished explore's file again): only an explore's file is decoded (the files are compact JSON,
-- Python's files.dumps and util/json alike: the template reads `"tpl":"explore"`), once a boot. What the check needs
-- of it is kept in S.xdoc[id] = {stages = {{mode}}, tiles = {[si] = per-chunk dig tiles}, own = its tiles}, or false.
local function file_doc(K, id)
  S.xdoc = S.xdoc or {}
  local c = S.xdoc[id]
  if c ~= nil then return c or nil end
  S.xdoc[id] = false
  local f = io.open(K.cfg.paths.save .. '/bp/' .. id .. '.json', 'rb')
  if not f then return nil end
  local raw = f:read('a')
  f:close()
  if type(raw) ~= 'string' or not raw:find('"tpl":"explore"', 1, true) then return nil end
  local d = json.try_decode(raw)
  if type(d) ~= 'table' or d == json.null or check_doc(d, 'explore') ~= nil then return nil end
  c = {stages = {}, tiles = {}, own = doc_own(d)}
  for si, st in ipairs(d.stages) do
    c.stages[si] = {mode = st.mode}
    if st.mode == 'dig' then c.tiles[si - 1] = raw_tiles(d, si - 1) end
  end
  S.xdoc[id] = c
  return c
end

-- a stage's tiles per chunk of a live document (uncached) or of a file_doc record
local function tiles_fn(d)
  if d.tiles then return function(si) return d.tiles[si] or {} end end
  return function(si) return raw_tiles(d, si) end
end

local function note_shaft(K, P, d)
  if P.tpl ~= 'explore' then return nil end
  local r = S.rt.xs[P.id]
  if type(r) == 'table' then return r end
  d = d or file_doc(K, P.id)
  if type(d) ~= 'table' or type(d.stages) ~= 'table' then return nil end
  local col = column_of(d, tiles_fn(d), nil)
  if not col then return nil end
  r = {x = col.x, y = col.y, top = col.top, low = col.low, t = now(K)}
  S.rt.xs[P.id] = r
  dirty()
  return r
end

-- quickfort keys that wall one shaft tile: walls cannot stand on stairs (quickfort build.lua
-- is_valid_tile_construction: floor, open space, ramp top), so a stair is channelled into open space first
-- Run 11: a hatch or door on the tile (the live shaft top 136,73,137 got a hatch by hand) is removed first: quickfort
-- undo of its build key (the player's 'remove building', a deconstruct job; PEACE only), then channel and wall
local STAIR_C = {['<'] = true, ['>'] = true, X = true}
local FREE_KEY = {Hatch = 'H', Door = 'd'}
local function piece_keys(c, bld)
  if c == 'C' then return {} end
  if STAIR_C[c] then return {'h', 'Cw'} end
  if c == '+' or FREE_KEY[bld] then return {'free:' .. (FREE_KEY[bld] or 'H'), 'h', 'Cw'} end   -- door/hatch
  return {'Cw'}
end
local function is_free(st) return st.label:sub(-5) == '.free' end

local function wall_list(rec)
  local out = {}
  for _, p in ipairs({rec.s1 or false, rec.s0 or false}) do
    if type(p) == 'table' then out[#out + 1] = string.format('%d,%d,%d', p[1], p[2], p[3]) end
  end
  return out
end

-- Run 11 (y432-433: explores kept hitting the cavern lakes on z127): every tile where a dig broke into a cavern (the
-- breach of BREACH_STOP cavern/cavern_lake, the shaft check's hit) is kept, m.runner cz = {{x, y, z, why, t}, ...}
-- (<= cav_levels, newest kept), and mirrored into the fort manifest as `caverns` = {{x, y, z}, ...}: bp.sites' explore
-- ranking avoids those levels (no shaft reaches one), so plan propose fits the depth above them.
local function publish_caverns(K)
  local man = K.manifest()
  local list = {}
  for i, c in ipairs(S.rt.cz) do list[i] = {c[1], c[2], c[3]} end
  man.caverns = list
  K.persist.set('manifest', man)
end

function note_cavern(K, pos, why)
  local x, y, z = int(type(pos) == 'table' and pos[1]), int(type(pos) == 'table' and pos[2]),
                  int(type(pos) == 'table' and pos[3])
  if not (x and y and z) then return end
  S.rt.cz = type(S.rt.cz) == 'table' and S.rt.cz or {}
  for _, c in ipairs(S.rt.cz) do if c[1] == x and c[2] == y and c[3] == z then return end end
  table.insert(S.rt.cz, {x, y, z, tostring(why or 'cavern'), now(K)})
  while #S.rt.cz > M.CFG.cav_levels do table.remove(S.rt.cz, 1) end
  publish_caverns(K)
  dirty()
  K.log('info', 'cavern at %d,%d,%d (%s): explore shafts stop above z%d', x, y, z, tostring(why), z)
end

-- BUG-130 (Run 9 site96, Run 14 replay y707 site90: the fortcore stopped as breach:damp, parked for good and never
-- re-sited): every breach stop is remembered, one entry per project with its tile, kind and template, m.runner dz =
-- {{pos, why, proj, tpl, t}, ...} (<= br_max, newest kept), mirrored into the fort manifest as `breaches` = {{pos, why,
-- proj, tpl}, ...}: bp.sites keeps a new fortcore away from those tiles and `plan propose` re-sites a stopped fortcore.
-- Module fields (runner.lua sits at Lua's limit of 200 locals).
M.BR_MAX = 32
function M.publish_breaches(K)
  local man, list = K.manifest(), {}
  for i, c in ipairs(S.rt.dz) do list[i] = {pos = {c.pos[1], c.pos[2], c.pos[3]}, why = c.why, proj = c.proj, tpl = c.tpl} end
  man.breaches = list
  K.persist.set('manifest', man)
end

function M.note_breach(K, id, tpl, why, pos)
  local x, y, z = int(type(pos) == 'table' and pos[1]), int(type(pos) == 'table' and pos[2]),
                  int(type(pos) == 'table' and pos[3])
  if not (x and y and z) or type(id) ~= 'string' then return end
  S.rt.dz = type(S.rt.dz) == 'table' and S.rt.dz or {}
  for i, c in ipairs(S.rt.dz) do
    if c.proj == id then table.remove(S.rt.dz, i); break end
  end
  table.insert(S.rt.dz, {pos = {x, y, z}, why = trunc(tostring(why or 'damp'), 16), proj = id,
                         tpl = trunc(tostring(tpl or '?'), 24), t = now(K)})
  while #S.rt.dz > M.BR_MAX do table.remove(S.rt.dz, 1) end
  M.publish_breaches(K)
  dirty()
end

-- at boot: m.runner dz kept, the breach records of an older kernel (m.runner br) of the projects still known taken over,
-- and the manifest's `breaches` written again when it lost them
function M.breach_boot(K, rt, pd)
  if type(rt.dz) ~= 'table' then rt.dz = {} end
  local have, tpl = {}, {}
  for _, c in ipairs(rt.dz) do if type(c) == 'table' then have[c.proj] = true end end
  for _, P in ipairs(pd.list) do tpl[P.id] = P.tpl end
  local ids = {}
  for id in pairs(rt.br) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local r = rt.br[id]
    if not have[id] and tpl[id] and type(r) == 'table' and type(r.pos) == 'table' then
      M.note_breach(K, id, tpl[id], r.why, r.pos)
    end
  end
  local man = K.manifest().breaches
  if #rt.dz > 0 and (type(man) ~= 'table' or #man ~= #rt.dz) then M.publish_breaches(K) end
end

-- the plug project: per piece (the lower one first: it is reached through the upper one) 'pN.free' (a hatch or door
-- on it removed), 'pN.dig' (channel) and 'pN.wall' (a constructed wall); buildingplan waits for the material (no
-- orders), like runner.repair
local function plug_doc(rec)
  local stages, walls = {}, 0
  for _, pc in ipairs({{'p1', rec.s1 or false}, {'p0', rec.s0 or false}}) do
    local p = pc[2]
    if type(p) == 'table' then
      for _, key in ipairs(piece_keys(p[4], p[5])) do
        local dig, free = key == 'h', key:sub(1, 5) == 'free:'
        stages[#stages + 1] = {label = pc[1] .. (dig and '.dig' or free and '.free' or '.wall'),
                               mode = dig and 'dig' or 'build', orders = 0, defense = 1,
                               chunks = {{pos = {p[1], p[2], p[3]}, cells = {{0, 0, 0, free and key:sub(6) or key}}}}}
        if not dig and not free then walls = walls + 1 end
      end
    end
  end
  if #stages == 0 then return nil end
  return {v = 2, tpl = 'plug', site = 'plug', class = 'defense', params = obj{of = rec.proj}, rot = 0,
          anchor = {rec.s0[1], rec.s0[2], rec.s0[3]}, manifest = {v = 2}, materials = obj{wall = walls}, stages = stages}
end

local function plug_emit(K, rec, phase, msg, extra)
  local dd = {phase = phase, proj = rec.proj, plug = rec.plug or '', why = rec.why}
  local walls = wall_list(rec)
  if #walls > 0 then dd.walls = walls end
  if type(rec.pos) == 'table' then dd.pos = {rec.pos[1], rec.pos[2], rec.pos[3]} end
  if type(rec.s0) == 'table' then dd.shaft, dd.z1 = {rec.s0[1], rec.s0[2], rec.s0[3]}, rec.bot end
  if (rec.n or 0) > 0 then dd.n = rec.n end
  for k, v in pairs(extra or {}) do dd[k] = v end
  K.emit('CAVERN_PLUG', 'A', trunc(msg, 200), dd)
  K.flush()
end

local function plug_id(K)
  local t = now(K)
  local id, n = 'pl' .. t, 0
  while find(id) do n = n + 1; id = string.format('pl%d-%d', t, n) end
  return id
end

-- A dig project broke into a cavern (why cavern/cavern_lake) at pos. An explore shaft (a dead end into the unknown) is
-- plugged at once by a `plug` project (prio 1, every mode, never stopped by a hazard): its top stair tile and the one
-- below get a constructed wall each. Other templates get CAVERN_PLUG 'none' (their stairs may be the fort's own:
-- walled by hand). m.runner cav[<proj>] = {proj, tpl, why, pos, n, t, st = open|done|failed|none, plug, s0, s1, bot, s1x,
-- state}. ex (the daily shaft check, Run 11 c1a14676): {sh = the shaft read already, state = the explore's state then
-- (running, stalled, blocked:<why>, breach:<why>, cancel, done, cancelled)}; P may then be a stub {id, tpl}.
local function plug(K, P, d, why, pos, n, ex)
  ex = ex or {}
  if CAVERN[why] then note_cavern(K, pos, why) end
  if P.tpl == 'plug' or type(S.rt.cav[P.id]) == 'table' then return end
  local rec = {proj = P.id, tpl = P.tpl, why = why, t = now(K), n = n or 0, st = 'none', plug = '', state = ex.state}
  if type(pos) == 'table' and int(pos[1]) then rec.pos = {int(pos[1]), int(pos[2]), int(pos[3])} end
  S.rt.cav[P.id] = rec
  dirty()
  local label = (why:gsub('_', ' '))
  local where = rec.pos and string.format(' at %d,%d,%d', rec.pos[1], rec.pos[2], rec.pos[3]) or ''
  local sh = ex.sh or (P.tpl == 'explore' and d and shaft_of(K, P, d, rec.pos)) or nil
  local who = ex.state and string.format('%s (%s; shaft check)', P.id, ex.state) or P.id
  local st_d = ex.state and {state = trunc(ex.state, 40)} or nil
  if not sh then
    local hint = P.tpl == 'explore' and 'no dug stair column reaches the fort' or ('no automatic plug for ' .. P.tpl)
    plug_emit(K, rec, 'none', string.format('%s (%s): %s%s; %s: wall the way in by hand (a constructed wall, '
                                            .. 'bp.place seal close=wall)', P.id, P.tpl, label, where, hint),
              {hint = trunc(hint, 60)})
    return
  end
  rec.s0, rec.s1, rec.bot = sh.s0, sh.s1, sh.bot
  local pd = plug_doc(rec)
  if not pd then
    rec.st = 'done'
    K.log('info', '%s: the shaft %d,%d z%d-%d into the %s is walled already', P.id, sh.x, sh.y, sh.top, sh.bot, label)
    return
  end
  -- a plug project for this shaft that outlived its record (site data written at different times, then a reload)
  local id
  for _, Q in ipairs(S.pd.list) do
    local qd = Q.tpl == 'plug' and Q.done ~= 1 and doc(K, Q.id)
    if qd and type(qd.params) == 'table' and qd.params.of == P.id then id = Q.id end
  end
  local ok, err = id ~= nil, nil
  if not id then
    id = plug_id(K)
    ok, err = register(K, id, pd, 1, 'plug')
  end
  if not ok then
    rec.st = 'failed'
    plug_emit(K, rec, 'failed', string.format('%s: the shaft %d,%d z%d-%d opens into a %s%s; plug not queued (%s): build '
                                              .. 'a constructed wall on %d,%d,%d by hand', who, sh.x, sh.y, sh.top, sh.bot,
                                              label, where, tostring(err), sh.x, sh.y, sh.top),
              {hint = trunc(err, 60), state = st_d and st_d.state})
    return
  end
  rec.plug, rec.st = id, 'open'
  local msg = string.format('%s: the shaft %d,%d z%d-%d opens into a %s%s; plug %s: constructed walls at %s '
                            .. '(stairs channelled first)', who, sh.x, sh.y, sh.top, sh.bot, label, where, id,
                            table.concat(wall_list(rec), ' + '))
  K.log('warn', '%s', msg)
  plug_emit(K, rec, 'queued', msg, st_d)
end

local function plug_rec(id)
  for _, r in pairs(S.rt.cav) do if type(r) == 'table' and r.plug == id then return r end end
end

-- the lower wall (p1.*) is given up (quickfort refused it, or DF did not build it within plug_wait: the tile is reached
-- only from the stair above): the plug goes on with the top tile (p0.*)
local function plug_skip(K, P, d, why)
  local to = #d.stages
  for i, st in ipairs(d.stages) do if st.label:sub(1, 3) == 'p0.' then to = i - 1; break end end
  local rec = plug_rec(P.id)
  if rec then rec.s1x = trunc(why, 40) end
  K.log('warn', '%s: lower wall (%s) given up: %s; walling the shaft top', P.id, d.stages[P.stage + 1].label, why)
  local t = now(K)
  P.stage, P.chunk, P.orders_done, P.since = to, 0, 0, t
  if P.blocked == 'stalled' then P.blocked = '' end
  P.pct = pct_of(P, d, 0)
  S.rt.p[P.id] = new_R(t, P.stage)
  S.meas[P.id] = nil
  dirty()
end

-- why: nil = quickfort refused the step; else why it ended (Run 11: the hatch on the top was not removed in time)
local function plug_refused(K, P, d, st, why)
  local what = why or ('quickfort refused ' .. st.label)
  if st.label:sub(1, 3) == 'p1.' then return plug_skip(K, P, d, what) end
  set_blocked(K, P, 'plug_refused')
  local rec = plug_rec(P.id)
  if rec and rec.st ~= 'failed' then
    rec.st = 'failed'
    dirty()
    local p = st.chunks[1].pos
    plug_emit(K, rec, 'failed', string.format('plug %s for %s: %s at %d,%d,%d: build a constructed wall there by hand '
                                              .. '(%s)', P.id, rec.proj, what, p[1], p[2], p[3],
                                              is_free(st) and 'remove the hatch or door, channel the stair, wall it'
                                              or 'channel the stair first'),
              {hint = trunc(why or ('refused ' .. st.label), 60)})
  end
end

-- end of every run: a plug record is done once a constructed wall stands on the shaft top (the plug's, or one built by
-- hand), or below a hatch/door on the top (walled; a hatch alone never counts); a plug project that is gone, finished
-- without the wall or blocked fails once (the record stays open: R0)
local function plug_watch(K)
  local ids, old = {}, {}
  for id in pairs(S.rt.cav) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local r = S.rt.cav[id]
    if type(r) ~= 'table' then S.rt.cav[id] = nil; dirty()
    elseif (r.st == 'open' or r.st == 'failed') and type(r.s0) == 'table' then
      local shut, where = walled(K, r.s0, r.s1)
      if shut and where == 'below' then
        r.st, r.td = 'done', now(K)
        dirty()
        plug_emit(K, r, 'done', string.format('plug %s for %s: constructed wall on %d,%d,%d below the %s on %d,%d,%d; the '
                                              .. 'shaft to the %s is closed', r.plug ~= '' and r.plug or '(by hand)', id,
                                              r.s1[1], r.s1[2], r.s1[3], r.s0[5] or 'building', r.s0[1], r.s0[2],
                                              r.s0[3], (r.why:gsub('_', ' '))))
      elseif shut then
        local low = ''
        if type(r.s1) == 'table' then
          local v1 = tile_at(K, r.s1[1], r.s1[2], r.s1[3])
          low = (v1 and v1.c == 'C') and string.format(' and on %d,%d,%d', r.s1[1], r.s1[2], r.s1[3])
                or ('; no wall below it' .. (r.s1x and (' (' .. r.s1x .. ')') or ''))
        end
        r.st, r.td = 'done', now(K)
        dirty()
        plug_emit(K, r, 'done', string.format('plug %s for %s: constructed wall on %d,%d,%d%s; the shaft to the %s is '
                                              .. 'closed', r.plug ~= '' and r.plug or '(by hand)', id, r.s0[1], r.s0[2],
                                              r.s0[3], low, (r.why:gsub('_', ' '))))
      elseif r.st == 'open' then
        local Q = r.plug ~= '' and find(r.plug) or nil
        local why
        if not Q then why = 'the plug project is gone'
        elseif Q.done == 1 then why = 'the plug project ended without the wall'
        elseif Q.blocked ~= '' and Q.blocked ~= 'stalled' then why = 'the plug is blocked: ' .. Q.blocked end
        if why then
          r.st = 'failed'
          dirty()
          plug_emit(K, r, 'failed', string.format('%s for %s: %s; build a constructed wall on %d,%d,%d by hand (channel '
                                                  .. 'the stair first)', r.plug, id, why, r.s0[1], r.s0[2], r.s0[3]),
                    {hint = trunc(why, 60)})
        end
      end
    elseif r.st == 'done' or r.st == 'none' then old[#old + 1] = id end
  end
  if #old > M.CFG.cav_keep then
    table.sort(old, function(a, b) return (S.rt.cav[a].t or 0) < (S.rt.cav[b].t or 0) end)
    for i = 1, #old - M.CFG.cav_keep do S.rt.cav[old[i]] = nil end
    dirty()
  end
end

---------------------------------------------------------------- applying stages
local function is_construction(b) return b:getType() == df.building_type.Construction end

-- live L2: a stage placed again over buildings it already has (fortcore stages 2-3 re-placed without their
-- traps) finds those tiles occupied, and quickfort counts them as unsuitable (building.lua:517-559), which
-- read as lost buildings (build_lost). Before a build chunk, the tiles that already hold a building or a
-- finished construction are counted (returned) and their buildings tracked like ours (an unbuilt one keeps
-- the stage pending).
local OCCUPIED = {C = true, F = true, ['='] = true, H = true, B = true, ['^'] = true, ['+'] = true}
local function pre_occupied(K, ch, R)
  local tiles, n, seen = {}, 0, {}
  for _, cell in ipairs(ch.cells) do cell_tiles(ch, cell, tiles) end
  for _, id in ipairs(R.b) do seen[id] = true end
  local find = dfhack.buildings and dfhack.buildings.findAtTile             -- Lua API.txt:2484
  for _, t in ipairs(tiles) do
    local ok, b = false, nil
    if find then ok, b = pcall(find, t[1], t[2], t[3]) end
    if ok and b then
      n = n + 1
      if not seen[b.id] and not is_construction(b) then seen[b.id] = true; R.b[#R.b + 1] = b.id end
    else
      local okt, tile = K.call('snapshot', 'tile', t[1], t[2], t[3])
      if okt and type(tile) == 'table' and OCCUPIED[tile.c] then n = n + 1 end
    end
  end
  return n
end

-- live L2/L3: a second tombs project on the same coffins (and care's `burial -c` racing the zone stage) stacked
-- tomb zones on coffins that already had one; DF assigned the dead to the new, "free" zones of occupied coffins
-- and five citizens lay unburied (one ghost held the fort in BREACH). A one-owner zone cell (tomb, bedroom,
-- office) is left out where every tile already lies in a zone of that type, as nobody draws a second one.
-- FR-27 (Run 9: up to 3 tomb zones stacked on one coffin): a tomb cell is left out as soon as ANY of its tiles
-- lies in a tomb zone; bp.place refuses such cells before the project is queued.
M.ZONE_ONE = {T = 'Tomb', b = 'Bedroom', o = 'Office'}
-- dup, first zoned tile: a tomb cell with any tile in a tomb zone, a bedroom/office cell with every tile zoned
local function zone_dup(tl)
  local find = dfhack.buildings and dfhack.buildings.findCivzonesAt              -- Lua API.txt:2488
  local want = M.ZONE_ONE[tl[1] and tl[1][4] or '']
  if not find or not df.civzone_type or want == nil then return false end
  local ty = df.civzone_type[want]
  local first, all = nil, true
  for _, t in ipairs(tl) do
    local ok, zs = pcall(find, {x = t[1], y = t[2], z = t[3]})
    local hit = false
    for _, zn in ipairs(ok and type(zs) == 'table' and zs or {}) do if zn.type == ty then hit = true end end
    if hit then first = first or t else all = false end
    if want ~= 'Tomb' and not all then return false end
  end
  if want == 'Tomb' then return first ~= nil, first end
  return all, tl[1]
end

local function zoned_cells(ch)
  if not (dfhack.buildings and dfhack.buildings.findCivzonesAt) or not df.civzone_type then return ch, 0 end
  local keep, skip = {}, 0
  for _, cell in ipairs(ch.cells) do
    local tl = {}
    cell_tiles(ch, cell, tl)
    if zone_dup(tl) then skip = skip + 1 else keep[#keep + 1] = cell end
  end
  if skip == 0 then return ch, 0 end
  return {pos = ch.pos, cells = keep}, skip
end

-- FR-27 (bp.place, before a project is queued): the tomb cells ('T') of its zone stages that have a tile in a tomb
-- zone are cut from the document d (chunks and stages left empty go too). Returns cut, total tomb cells, the first
-- zoned tile {x, y, z}; bp.place refuses the document when every tomb cell was cut.
local function tomb_dups(d)
  local cut, total, first = 0, 0, nil
  if not (dfhack.buildings and dfhack.buildings.findCivzonesAt) or not df.civzone_type then return 0, 0 end
  local stages = {}
  for _, st in ipairs(d.stages) do
    local chunks = {}
    for _, ch in ipairs(st.mode == 'zone' and st.chunks or {}) do
      local cells = {}
      for _, cell in ipairs(ch.cells) do
        local tl = {}
        cell_tiles(ch, cell, tl)
        local dup, at = false, nil
        if tl[1] and tl[1][4] == 'T' then
          total = total + 1
          dup, at = zone_dup(tl)
        end
        if dup then cut, first = cut + 1, first or at else cells[#cells + 1] = cell end
      end
      if #cells > 0 then chunks[#chunks + 1] = {pos = ch.pos, cells = cells} end
    end
    if st.mode ~= 'zone' then stages[#stages + 1] = st
    elseif #chunks > 0 then
      local copy_st = {}
      for k, v in pairs(st) do copy_st[k] = v end
      copy_st.chunks = chunks
      stages[#stages + 1] = copy_st
    end
  end
  if cut > 0 and cut < total then d.stages = stages end
  return cut, total, first
end

-- Run 11 (Kilrudrabed site98 y435): the seal piece door 128,121,143 (a door already stood on its neighbour 127,121,143)
-- stayed build_lost with 26 boulders and 171 logs in stock: quickfort said 'Unsuitable tiles for building: 1', while a
-- constructed wall on the same tile went in at once. quickfort places a door only where one of its four orthogonal
-- neighbours has the tile shape WALL or FORTIFICATION (build.lua is_tile_generic_and_wall_adjacent; a door, hatch or
-- planned wall beside it does not count; dfpilot/bp/defense.py states the rule and its uncertainty). A seal door that
-- quickfort counts as unsuitable is planned once as a constructed wall on the same tile (Cw: any open floor takes it):
-- the cell's key in the project's copy becomes Cw (bp.<id> set again, the one exception to 'written once'; a seal
-- document is small), the chunk is applied again, m.runner dw[<proj>] keeps the tiles ('x,y,z', <= 8), and the
-- kern.log line, PROJECT_BLOCKED and PROJECT_DONE name them ('door unsuitable at x,y,z: wall instead').
local DOOR_SUPPORT = {['#'] = true, S = true, C = true, F = true, T = true}   -- snapshot legend of WALL/FORTIFICATION
local N4 = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}}

-- the door rule on the revealed tiles: 'no wall or fortification beside it' when all four orthogonal neighbours are
-- revealed and none is one, else '' (a hidden neighbour may be a wall: quickfort reads it, we may not)
local function door_unsupported(K, x, y, z)
  for _, n in ipairs(N4) do
    local ok, v = K.call('snapshot', 'tile', x + n[1], y + n[2], z)
    if not (ok and type(v) == 'table') or v.c == nil or v.c == '?' or DOOR_SUPPORT[v.c] then return '' end
  end
  return 'no wall or fortification beside it'
end

-- 'door unsuitable at x,y,z: wall instead' (doors ... walls) for the project's walled doors, and their tiles; nil without
local function walled_note(id)
  local l = S.rt.dw and S.rt.dw[id]
  local sw = S.rt.sw and S.rt.sw[id]          -- BUG-044: doors that stayed stuck, replaced by walls (Q.stuck_walls)
  local parts, all = {}, {}
  for _, e in ipairs({{l, 'unsuitable'}, {sw, 'stuck'}}) do
    local list = e[1]
    if type(list) == 'table' and #list > 0 then
      parts[#parts + 1] = string.format(#list == 1 and 'door %s at %s: wall instead' or 'doors %s at %s: walls instead',
                                        e[2], table.concat(list, ', '))
      for _, x in ipairs(list) do all[#all + 1] = x end
    end
  end
  if #parts == 0 then return nil end
  return table.concat(parts, '; '), all
end

-- does a cell's tile hold what the stage placed? A building there (findAtTile, else snapshot's bld), or a finished
-- construction / closing tile (snapshot legend); hidden tiles hold nothing we may know of (BUG-022)
local function cell_present(K, t)
  local find = dfhack.buildings and dfhack.buildings.findAtTile
  if find then
    local ok, b = pcall(find, t[1], t[2], t[3])
    if ok and b then return true end
  end
  local okt, tile = K.call('snapshot', 'tile', t[1], t[2], t[3])
  if not (okt and type(tile) == 'table') then return false, nil end
  return (tile.bld ~= nil and tile.bld ~= '') or OCCUPIED[tile.c] == true, tile
end

-- after a seal build chunk: its doors quickfort refused (n unsuitable cells, nothing on a door's revealed tile now)
-- become constructed walls in the project's copy; returns how many
local function door_walls(K, P, d, st, ch, n)
  if P.tpl ~= 'seal' or n <= 0 or type(d) ~= 'table' then return 0 end
  local got = 0
  for _, c in ipairs(ch.cells) do
    if got >= n then break end
    if c[4]:match('^[^{(:/]*') == 'd' then
      local x, y, z = ch.pos[1] + c[1], ch.pos[2] + c[2], ch.pos[3] + c[3]
      local here, tile = cell_present(K, {x, y, z})
      if not here and tile then
        c[4], got = 'Cw', got + 1
        local l = type(S.rt.dw[P.id]) == 'table' and S.rt.dw[P.id] or {}
        if #l < 8 then l[#l + 1] = tkey(x, y, z) end
        S.rt.dw[P.id] = l
        local why = door_unsupported(K, x, y, z)
        K.log('warn', '%s %s: door unsuitable at %d,%d,%d: wall instead (quickfort refused the door%s)', P.id,
              st.label, x, y, z, why ~= '' and ('; ' .. why) or '')
      end
    end
  end
  if got == 0 then return 0 end
  local m = d.materials
  if type(m) == 'table' and int(m.door) then
    m.door, m.wall = int(m.door) > got and int(m.door) - got or nil, (int(m.wall) or 0) + got
  end
  K.persist.set('bp.' .. P.id, d)
  for k in pairs(S.tiles) do if k:sub(1, #P.id + 1) == P.id .. '/' then S.tiles[k] = nil end end
  if S.own then S.own[P.id] = nil end
  dirty()
  return got
end

-- BUG-072 (Run 11 y451: one place call with three food stockpiles took 68,603 ms): quickfort's configure_stockpile imports
-- library/cat_food for every pile (place.lua:256-260), and the food import copies all raw materials per element
-- (StockpileSerializer.cpp:479-484, OrganicMatLookup.cpp:28), so the cost grows with the piles in a call and with the
-- age of the world. A place chunk with two or more food cells (a key with `f`) is applied as separate calls, one per
-- food cell, one per slice; the cells between them (other piles) stay together in one call. Order and cells are the
-- document's. Q.pile_part answers the cells of the next call and {k = its number, n = calls of the chunk} (R.pc =
-- {c = chunk, n = calls done}); a pile that stands (a stockpile of its name, else any, on its first and last tile) is
-- not placed again. nil: the chunk is applied whole, as before
function Q.food_cell(cell) return (cell[4]:match('^[^{(:/]*') or ''):find('f', 1, true) ~= nil end
function Q.pile_stands(ch, cell)
  local find = dfhack.buildings and dfhack.buildings.findAtTile
  if not (find and df.building_type and df.building_type.Stockpile) then return false end
  local name = cell[4]:match('name=([^%s}]+)')
  local tl = {}
  cell_tiles(ch, cell, tl)
  for _, t in ipairs({tl[1], tl[#tl]}) do
    local ok, b = pcall(find, t[1], t[2], t[3])
    if not (ok and b) then return false end
    local okt, ty = pcall(function() return b:getType() end)
    if not okt or ty ~= df.building_type.Stockpile then return false end
    if name and b.name ~= name then return false end
  end
  return true
end
function Q.pile_part(K, P, st, ch, R)
  local nfood = 0
  for _, c in ipairs(ch.cells) do if Q.food_cell(c) then nfood = nfood + 1 end end
  if nfood < 2 then return ch, nil end
  local calls, rest = {}, {}
  for _, c in ipairs(ch.cells) do
    if Q.food_cell(c) then
      if #rest > 0 then calls[#calls + 1] = rest; rest = {} end
      calls[#calls + 1] = {c}
    else rest[#rest + 1] = c end
  end
  if #rest > 0 then calls[#calls + 1] = rest end
  local done = type(R.pc) == 'table' and R.pc.c == P.chunk and int(R.pc.n) or 0
  local pc = done
  while pc < #calls and #calls[pc + 1] == 1 and Q.food_cell(calls[pc + 1][1]) and Q.pile_stands(ch, calls[pc + 1][1]) do
    local c = calls[pc + 1][1]
    K.log('info', '%s %s chunk %d: the food pile at %d,%d,%d stands, not placed again', P.id, st.label, P.chunk,
          ch.pos[1] + c[1], ch.pos[2] + c[2], ch.pos[3] + c[3])
    pc = pc + 1
  end
  if pc ~= done then R.pc = {c = P.chunk, n = pc} end
  return {pos = ch.pos, cells = calls[pc + 1] or {}}, {k = pc + 1, n = #calls}
end

local function apply(K, P, st, R)
  local ch = st.chunks[P.chunk + 1]
  if P.tpl == 'plug' then
    local c = ch.cells[1]
    local v = tile_at(K, ch.pos[1] + c[1], ch.pos[2] + c[2], ch.pos[3] + c[3])
    if is_free(st) then                      -- Run 11: the hatch/door on the shaft top: the player's 'remove building'
      local ok, stats = qf(K, {mode = 'build', data = chunk_data(ch), pos = ch.pos, command = 'undo'})
      K.log('info', '%s %s: removing the %s at %d,%d,%d (quickfort undo: %s)', P.id, st.label, c[4] == 'd' and 'door'
            or 'hatch', ch.pos[1], ch.pos[2], ch.pos[3], ok and 'ok' or tostring(stats))
      P.chunk = P.chunk + 1; moved(K, R)
      dirty()
      return true
    end
    -- a channel on a tile that is open already (the removed hatch stood on open space or a floor): nothing to dig
    if st.mode == 'dig' and v and (v.c == '_' or v.c == 'v' or v.c == 'C') then
      P.chunk = P.chunk + 1; moved(K, R)
      dirty()
      return true
    end
  end
  if st.mode == 'zone' then
    local skip
    ch, skip = zoned_cells(ch)
    if skip > 0 then
      K.log('info', '%s %s chunk %d: %d cells already zoned, left out', P.id, st.label, P.chunk, skip)
      if #ch.cells == 0 then P.chunk = P.chunk + 1; moved(K, R); dirty(); return true end
    end
  elseif st.mode == 'dig' then                 -- BUG-041: a seal's gather cells are never designated (Q.nogather)
    local skip
    ch, skip = Q.nogather(P, ch)
    if skip > 0 and #ch.cells == 0 then P.chunk = P.chunk + 1; moved(K, R); dirty(); return true end
  end
  local part                                  -- BUG-072: a place chunk with several food piles, one call per pile
  if st.mode == 'place' then
    ch, part = Q.pile_part(K, P, st, ch, R)
    if part and part.k > part.n then            -- every call is done (the piles stand): the chunk is
      P.chunk = P.chunk + 1; R.pc = nil; moved(K, R); dirty(); return true
    end
  end
  local p = {mode = st.mode, data = chunk_data(ch), pos = ch.pos}
  Q.doing(P, st, part and string.format('chunk %d/%d call %d/%d', P.chunk + 1, #st.chunks, part.k, part.n)
                  or string.format('chunk %d/%d', P.chunk + 1, #st.chunks))
  if st.mode == 'dig' then p.priority = dprio(P) end
  local pre = st.mode == 'build' and pre_occupied(K, ch, R) or 0
  -- FR-22: seal remembers the closing cells (walls, doors, bridges) and takes a reach baseline before they are queued
  if st.mode == 'build' then K.call('seal', 'closing', P.id, P.tpl, P.class, ch) end
  -- quickfort allocates the ids of the buildings it places (build.lua:1259 constructBuilding)
  local n0 = st.mode == 'build' and df.global.building_next_id or nil
  local t0 = st.mode == 'place' and dfhack.getTickCount and dfhack.getTickCount() or nil
  local ok, stats = qf(K, p)
  if t0 then                                  -- BUG-072: what a place call cost, for the next live read (food cells only)
    local nf = 0
    for _, c in ipairs(ch.cells) do if Q.food_cell(c) then nf = nf + 1 end end
    if nf > 0 then
      -- the live datum that decides whether a cheaper blueprint is needed: ms per call against the creature raws of the world
      local okr, nraws = pcall(function() return #df.global.world.raws.creatures.all end)
      K.log('info', '%s %s chunk %d%s: %s with %d food pile%s took %d ms%s', P.id, st.label, P.chunk,
            part and string.format(' call %d/%d', part.k, part.n) or '', ok and 'quickfort place' or 'quickfort place failed',
            nf, nf == 1 and '' or 's', int(dfhack.getTickCount() - t0) or 0,
            okr and int(nraws) and string.format(' (%d creature raws)', nraws) or '')
    end
  end
  if not ok then
    R.fail = (R.fail or 0) + 1
    if R.fail >= M.CFG.fail_max then set_blocked(K, P, 'apply_fail') end
    dirty()
    return false
  end
  stats = type(stats) == 'table' and stats or {}
  R.fail = 0
  if part and part.k < part.n then            -- BUG-072: the next pile goes in the next slice
    R.pc = {c = P.chunk, n = part.k}
    moved(K, R); dirty()
    return true
  end
  R.pc = nil
  if P.tpl == 'plug' then                    -- Run 11: quickfort refused the channel or the wall on this tile
    local no = st.mode == 'dig' and (int(stats.dig_invalid_tiles) or 0) + (int(stats.out_of_bounds) or 0)
               or st.mode == 'build' and (int(stats.build_unsuitable) or 0) or 0
    if no > 0 then
      P.chunk = P.chunk + 1; moved(K, R)
      dirty()
      plug_refused(K, P, doc(K, P.id), st)
      return true
    end
  end
  local bad = int(stats.invalid_keys) or 0
  if bad > 0 then K.log('warn', '%s %s chunk %d: %d invalid quickfort keys', P.id, st.label, P.chunk, bad) end
  if P.tpl == 'mood_drink' and st.mode == 'place' then    -- BUG-102: quickfort's "Stockpile tiles skipped (tile occupied)"
    local des, occ = int(stats.place_designated), int(stats.place_occupied) or 0
    local c = ch.cells[1]
    if c and (occ > 0 or des == 0) then
      P.refused = string.format('%d,%d,%d', ch.pos[1] + c[1], ch.pos[2] + c[2], ch.pos[3] + c[3])
      K.log('warn', '%s mood drink nook refused by quickfort at %s (%d tiles occupied, %d stockpiles designated)', P.id,
            P.refused, occ, des or -1)
    end
  end
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
    -- Run 11: the seal doors quickfort refused are constructed walls now; this chunk is applied again with them
    local walls = door_walls(K, P, doc(K, P.id), st, ch, (int(stats.build_unsuitable) or 0) - pre)
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
      else R.uns = R.uns + math.max(0, (int(stats.build_unsuitable) or 0) - pre - walls) + bad end
    end
    if walls > 0 then moved(K, R); dirty(); return true end
  end
  P.chunk = P.chunk + 1
  moved(K, R)
  dirty()
  return true
end

-- the stage's cells in absolute coordinates, grouped by building key (quickfort merges one key's items into
-- one manager order, so a group seldom spans two calls): {{x, y, z, text}, ...}
local function order_cells(st)
  local list = {}
  for _, ch in ipairs(st.chunks) do
    for _, c in ipairs(ch.cells) do
      list[#list + 1] = {ch.pos[1] + c[1], ch.pos[2] + c[2], ch.pos[3] + c[3], c[4], #list + 1,
                         c[4]:match('^[^{(:/]*')}
    end
  end
  table.sort(list, function(a, b)
    if a[6] ~= b[6] then return a[6] < b[6] end
    return a[5] < b[5]
  end)
  return list
end

-- quickfort 'orders' for the stage, sliced (live L1b: one call for a whole stage took 60 ms): each call
-- takes the next orders_cells cells (R.oc = next index). Each manager order created comes back as an array
-- entry = its quantity (orders.lua:162-165 is_order stats; act.quickfort must run orders.create_orders,
-- which apply_blueprint alone never does: quickfort.lua:43-56, command.lua:183). Returns true when the
-- stage's orders are complete, 'more' after a slice, false = failed (retried next run; after fail_max
-- failures the rest of the stage is built without orders).
-- live L2: a cell whose tile already holds a building or a finished construction (a stage placed again) gets
-- no manager order (three placements of fortcore stages 2-3 had ordered 93 mechanisms)
local function occupied_cell(K, c)
  local find = dfhack.buildings and dfhack.buildings.findAtTile
  if find then
    local ok, b = pcall(find, c[1], c[2], c[3])
    if ok and b then return true end
  end
  local okt, tile = K.call('snapshot', 'tile', c[1], c[2], c[3])
  return okt and type(tile) == 'table' and OCCUPIED[tile.c] == true
end

-- BUG-042: quickfort keys whose manager orders are capped (orders_cap) and the items the open one-time orders of their
-- jobs still make ({ConstructDoor = n}); {} when the orders cannot be read
M.CAP_KEYS = {d = 'ConstructDoor', H = 'ConstructHatchCover'}
function M.open_piece_orders()
  local r = {}
  pcall(function()
    local one = df.workquota_frequency_type.OneTime
    for _, o in ipairs(df.global.world.manager_orders.all) do
      local n = int(o.amount_left) or 0
      local job = n > 0 and o.frequency == one and df.job_type[o.job_type]
      if job == 'ConstructDoor' or job == 'ConstructHatchCover' then r[job] = (r[job] or 0) + n end
    end
  end)
  return r
end

-- the id DF gives the next manager order (nil when it cannot be read)
local function next_order_id()
  local ok, v = pcall(function() return df.global.world.manager_orders.manager_order_next_id end)
  return ok and math.type(v) == 'integer' and v or nil
end

-- seal first (Run 11 siege 8: ~110 rock orders stood before a seal's door): the manager orders a seal's quickfort
-- `orders` call made (ids n0 .. the next id - 1) move to the top of the work orders, the player's up arrow
local function orders_first(K, P, st, n0)
  local n1 = next_order_id()
  if not (n0 and n1 and n1 > n0) then return end
  local ids = {}
  for id = n0, math.min(n1 - 1, n0 + 31) do ids[#ids + 1] = id end
  local ok, n = K.act.order_top(ids)
  if ok and (int(n) or 0) > 0 then
    K.log('info', '%s %s: %d manager orders moved to the top of the work orders (seal first)', P.id, st.label, n)
  end
end

local function orders(K, P, st, R)
  local cells = order_cells(st)
  local i0 = math.max(1, int(R.oc) or 1)
  local i1 = math.min(#cells, i0 + M.CFG.orders_cells - 1)
  local data, n = {}, 0
  local open, capped = M.open_piece_orders(), {}
  for i = i0, i1 do
    local c = cells[i]
    local job = M.CAP_KEYS[tostring(c[4]):match('^[^{(:/]*')]
    -- BUG-044: a seal's door ignores the cap (110 stuck rock orders left the seal door of Run 11 without an order), but
    -- at most orders_seal door/hatch items for one seal project in all (m.runner so)
    local own = job and SEALS[P.tpl] and (int(S.rt.so[P.id]) or 0) < M.CFG.orders_seal
    if job and not own and (open[job] or 0) >= M.CFG.orders_cap then capped[job] = (capped[job] or 0) + 1
    elseif not occupied_cell(K, c) then
      if own then S.rt.so[P.id] = (int(S.rt.so[P.id]) or 0) + 1; dirty() end
      if job then open[job] = (open[job] or 0) + 1 end
      local gz = data[c[3]] or {}
      data[c[3]] = gz
      local row = gz[c[2]] or {}
      gz[c[2]] = row
      row[c[1]] = c[4]
      n = n + 1
    end
  end
  for job, k in pairs(capped) do
    K.log('info', '%s %s: %d %s cells get no manager order: %d open %s orders (cap %d)', P.id, st.label, k,
          job == 'ConstructDoor' and 'door' or 'hatch', open[job] or 0, job, M.CFG.orders_cap)
  end
  local ok, res = true, {}
  local n0 = SEALS[P.tpl] and n > 0 and next_order_id() or nil
  if n > 0 then ok, res = qf(K, {mode = st.mode, data = data, pos = {0, 0, 0}, command = 'orders'}) end
  if ok and n0 then orders_first(K, P, st, n0) end
  if ok and n > 0 then R.ps = now(K) end      -- BUG-037: manager orders made are new jobs
  if not ok then
    R.of = (R.of or 0) + 1
    dirty()
    if R.of < M.CFG.fail_max then
      K.log('warn', '%s %s: quickfort orders failed (%d): %s', P.id, st.label, R.of, tostring(res))
      return false
    end
    K.log('error', '%s %s: quickfort orders failed %d times, building without orders: %s', P.id, st.label,
          R.of, tostring(res))
    i1 = #cells
  else
    local n, q = 0, 0
    for k, v in pairs(type(res) == 'table' and res or {}) do
      if math.type(k) == 'integer' and type(v) == 'number' then n, q = n + 1, q + v end
    end
    R.on, R.ord = (R.on or 0) + n, (R.ord or 0) + (math.tointeger(q) or math.floor(q))
  end
  R.oc = i1 + 1
  dirty()
  if R.oc <= #cells then return 'more' end
  if (R.on or 0) > 0 then K.log('info', '%s %s: %d manager orders, %d items', P.id, st.label, R.on, R.ord or 0)
  else K.log('warn', '%s %s: quickfort orders created no manager orders', P.id, st.label) end
  P.orders_done = 1
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

-- live L4: a finished cistern's pipe (108 tiles to the brook) left the audit box; the audit read the cut-off
-- pipe as a way in (bypass, R1 -> R0). A cistern's box is kept after it is done (m.runner keep): the pipe ends
-- at its closed floodgate and fortification, which the audit then sees.
-- live L7: a finished bedrooms block at the audit box edge read as a way in (bypass, readiness R0 for a year):
-- every finished room project stays inside the audit box, not only the cistern
-- BUG-043 (Run 11 y479: the audit must cover the entrances and the shafts): finished seals, plugs and repairs (the
-- pieces that close the ways in) and explores (their shaft: a column part of the audit export) stay too; m.runner kk
-- names their template (KEEP_BOX 'kind'), so boxes() knows a kept shaft and kept_in() answers with rooms only
local KEEP_BOX = {cistern = true, bedrooms = true, tombs = true, hall = true, guildhall = true, barracks = true,
                  temple = true, tavern = true, dining = true, hospital = true, office = true, workshops = true,
                  farms = true, furnaces = true, captives = true, refuge_drink = true,
                  seal = 'kind', plug = 'kind', repair = 'kind', explore = 'kind'}

local function keep_box(P, d)
  S.rt.keep[P.id] = project_bbox(P.id, d)
  if KEEP_BOX[P.tpl] == 'kind' then S.rt.kk[P.id] = P.tpl end
  S.rt.kp[P.id] = Q.tile_parts(P.id, d)                  -- BUG-129: the clusters of its tiles (nil: one)
end

-- BUG-129: the clusters of a project's tiles (all stages) when there are two or more, else nil (cached)
function Q.tile_parts(id, d)
  S.cl = S.cl or {}
  local c = S.cl[id]
  if c == nil then
    local tl = {}
    for si = 0, #d.stages - 1 do
      for _, list in ipairs(stage_tiles(id, d, si)) do for _, t in ipairs(list) do tl[#tl + 1] = t end end
    end
    c = geom.clusters(tl, M.CFG.part_gap, M.CFG.part_max)
    c = #c > 1 and c or false
    S.cl[id] = c
  end
  return c or nil
end

-- FR-76 (Run 12 Trussroads: fortcore stage 2 "site: same" finished at once, its tiles already open in the old fort, with
-- stage 1 parked at breach:damp and never done; the plan then counted stage 1 as delivered): the lowest stage a document
-- works on (params.stage, else its lowest sN.* label) and whether the stage before it ran (the finished stages of the
-- template, another live project of it that passed that stage, or, for a fort of an older kernel, a merged fortcore:
-- zones in the manifest)
function Q.first_stage(d)
  local st = type(d.params) == 'table' and int(d.params.stage) or nil
  if st and st > 0 then return st end
  local lo
  for _, s in ipairs(d.stages) do
    local n = int(tostring(s.label):match('^s([0-9]+)%.'))
    if n and (not lo or n < lo) then lo = n end
  end
  return lo or 1
end

function Q.pre_ran(K, P, d, before)
  local h = S.rt.hist[P.tpl]
  if type(h) == 'table' and ((int(h.ps) or 0) >= before or (int(h.ls) or 0) >= before) then return true end
  for _, P2 in ipairs(S.pd.list) do
    if P2.tpl == P.tpl and P2.id ~= P.id and P2.done ~= 1 then
      local d2 = doc(K, P2.id)
      if d2 and Q.first_stage(d2) <= before and labels_done(d2, P2.stage) >= before then return true end
    end
  end
  if P.tpl == 'fortcore' then
    for _, list in pairs(type(K.manifest().zones) == 'table' and K.manifest().zones or {}) do
      if type(list) == 'table' and #list > 0 then return true end
    end
  end
  return false
end

local function finish(K, P, d)
  if KEEP_BOX[P.tpl] then keep_box(P, d) end
  local man = K.manifest()
  M.merge_manifest(man, d.manifest)
  K.persist.set('manifest', man)
  local first = Q.first_stage(d)
  local pre = first < 2 or Q.pre_ran(K, P, d, first - 1)
  local h = obj(S.rt.hist[P.tpl])
  h.n = (h.n or 0) + 1
  if pre then                                -- FR-76: a stage whose predecessor never ran is not counted as delivered
    h.ps = math.max(h.ps or 0, int(type(d.params) == 'table' and d.params.stage) or 0)
    h.ls = math.max(h.ls or 0, labels_done(d, #d.stages))
  else
    K.log('warn', '%s (%s) stage %d done, but stage %d never ran: not counted as delivered (place stage %d)', P.id, P.tpl,
          first, first - 1, first - 1)
  end
  S.rt.hist[P.tpl] = h
  P.done, P.pct, P.blocked, P.since = 1, 100, '', now(K)
  local xr = note_shaft(K, P, d)              -- Run 11: a finished explore's shaft stays open: the shaft check watches it
  if xr then xr.fin = 'done' end
  local wn, wl = walled_note(P.id)            -- Run 11: the seal doors quickfort refused stand as walls
  K.persist.set('bp.' .. P.id, nil)
  S.rt.p[P.id] = nil
  forget(P.id)
  K.emit('PROJECT_DONE', 'B', trunc(P.id .. ' (' .. P.tpl .. ') done' .. (wn and ('; ' .. wn) or '') ..
                                    (P.refused and ('; refused by quickfort at ' .. P.refused .. ' (tile occupied)') or '') ..
                                    (pre and '' or ('; stage ' .. (first - 1) .. ' never ran: not counted')), 200),
         {proj = P.id, tpl = P.tpl, walled = wl, pre = (not pre) and (first - 1) or nil})
  K.log('info', '%s (%s) done', P.id, P.tpl)  -- BUG-039: kern.log names every project that leaves the open list
  K.flush()
  dirty()
end

-- seal first / rebuild (Run 11 siege 8): a paused project's applied dig chunks are still dug by the miners: a hazard
-- on one of their revealed tiles stops it as the measure does (breach src 'tile'); no progress, no new chunk
local function hold_watch(K, P, d, st, R)
  if st.mode ~= 'dig' or P.chunk == 0 then return 'done' end
  local tiles = stage_tiles(P.id, d, P.stage)
  for ci = 1, math.min(P.chunk, #tiles) do
    if R.cd:sub(ci, ci) ~= '1' then
      for _, t in ipairs(tiles[ci]) do
        if S.slice.probes >= M.CFG.probe then return 'done' end
        local r, why = probe(K, t, true, false)
        if r == nil then return 'done' end
        if r == 'breach' then
          breach(K, P, why, {t[1], t[2], t[3]}, 'tile')
          return 'done'
        end
      end
    end
  end
  return 'done'
end

-- meas: measure-only pass of a stalled project without a slot (no orders, no applies); hold: a paused project (seal
-- first, rebuild): measured, never ordered or applied (its next stage waits), its applied dig chunks watched
local function work(K, P, meas, hold)
  local d = doc(K, P.id)
  if not d then set_blocked(K, P, 'bp_missing'); return 'done' end
  local applied = false
  for _ = 1, 100000 do                       -- every pass applies, measures, advances or returns
    if P.stage >= #d.stages then finish(K, P, d); return 'done' end
    local st, R = d.stages[P.stage + 1], R_of(K, P)
    -- Run 11: each step of the plug's lower wall waits at most plug_wait (DF may never reach that tile: it lies below the
    -- shaft top, reached only from the stair above); the top wall comes then
    if P.tpl == 'plug' and not meas and st.label:sub(1, 3) == 'p1.' and now(K) - P.since >= M.CFG.plug_wait then
      if P.chunk > 0 then
        if not qf_room() then return 'yield' end
        local ch = st.chunks[1]
        qf(K, {mode = st.mode, data = chunk_data(ch), pos = ch.pos, command = 'undo'})
      end
      local n = math.max(1, M.CFG.plug_wait // DAY)
      plug_skip(K, P, d, string.format('not done within %d day%s', n, n == 1 and '' or 's'))
      return 'yield'
    end
    -- Run 11: a hatch/door on the shaft top: none of it once the wall below it stands (the shaft is closed by a
    -- constructed wall); else removed only in PEACE (an open shaft in a fight, seal's perimeter diff), given up after
    -- plug_wait
    if P.tpl == 'plug' and is_free(st) then
      local rec = plug_rec(P.id)
      if rec and walled(K, rec.s0, rec.s1) then
        K.log('info', '%s: the wall below the %s stands; the top stays as it is', P.id, rec.s0[5] or 'building')
        P.stage = #d.stages
        dirty()
        return work(K, P, meas, hold)
      end
      if K.mode() ~= 'PEACE' and P.chunk == 0 then P.since = now(K); R.last = now(K); dirty(); return 'done' end
      if not meas and P.chunk > 0 and now(K) - P.since >= M.CFG.plug_wait then
        local p = st.chunks[1].pos
        local v = tile_at(K, p[1], p[2], p[3])
        if v and v.c == '+' then
          local n = math.max(1, M.CFG.plug_wait // DAY)
          plug_refused(K, P, d, st, string.format('the %s was not removed within %d day%s', rec and rec.s0[5] or 'hatch',
                                                  n, n == 1 and '' or 's'))
          return 'done'
        end
      end
    end
    local need_orders = st.orders == 1 and P.orders_done ~= 1
    if meas and (need_orders or P.chunk < #st.chunks or (st.mode ~= 'dig' and st.mode ~= 'build')) then
      return 'done'
    end
    if need_orders then
      if hold then return 'done' end
      if not qf_room() then return 'yield' end
      local r = orders(K, P, st, R)
      if not r then return 'done' end
      if r == 'more' then return 'yield' end               -- the next orders slice in the next frame
    end
    if P.chunk < #st.chunks then
      if hold then return hold_watch(K, P, d, st, R) end
      if not qf_room() then return 'yield' end
      if not apply(K, P, st, R) then return 'done' end
      applied = true
    elseif applied and (st.mode == 'dig' or st.mode == 'build') then
      return 'done'                          -- measure from the next run on
    else
      local res = 'complete'
      if P.tpl == 'plug' and is_free(st) then    -- done once no hatch/door stands there any more
        local p = st.chunks[1].pos
        local v = tile_at(K, p[1], p[2], p[3])
        res = (v and v.c ~= '+' and not COVER[v.bld]) and 'complete' or 'done'
      elseif st.mode == 'dig' then res = measure_dig(K, P, d, R)
      elseif st.mode == 'build' then res = measure_build(K, P, d, R) end
      if res == 'complete' then stage_done(K, P, d, st, R)
      elseif res ~= 'reapply' then return res end
    end
  end
  return 'done'
end

---------------------------------------------------------------- undo (bp.cancel undo, BREACH_STOP)
local function remove(K, P)
  local xr = note_shaft(K, P, doc(K, P.id))   -- Run 11: a cancelled explore's shaft may still stand (shaft check)
  if xr then xr.fin = 'cancelled' end
  K.log('info', '%s (%s) cancelled at stage %d: removed from the list', P.id, P.tpl, P.stage)   -- BUG-039
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

-- 'e1: cavern lake (report, not damp: 1146 water tiles in reach), digging stopped'; the shaft check (state, Run 11):
-- 'c1a14676: cavern lake (check, was stalled: 1146 water tiles in reach), digging stopped'
local function breach_msg(id, why, src, was, n, state)
  local s = id .. ': ' .. (why:gsub('_', ' ')) .. ' (' .. src
  if was or state then
    s = s .. (was and (', not ' .. was) or (', was ' .. state))
          .. ((n or 0) > 0 and string.format(': %d water tiles in reach', n) or ': a revealed cavern tile beside it')
  end
  return s .. '), digging stopped'
end

-- Run 11: a damp/water/cavern stop is first held against the revealed tiles at pos (M.opened: a cavern lake or an open
-- cavern raises it, never lowers it); a cavern kind then plugs an explore shaft (CAVERN_PLUG). ex (the daily shaft
-- check found the opening already, src 'check'): {state = the project's state, n = water tiles, sh = the shaft read}
function breach(K, P, why, pos, src, ex)
  if P.tpl == 'plug' or P.blocked:sub(1, 7) == 'breach:' or P.blocked == 'cancel' then return false end
  local d, R = doc(K, P.id), R_of(K, P)
  local was, n
  if ex then n = ex.n
  elseif pos and d and RANK[why] then
    local k, cnt = M.opened(K, P, d, pos)
    if k and RANK[k] > RANK[why] then why, was, n = k, why, cnt end
  end
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
  if was then dd.was, dd.n = was, n end
  if ex then dd.state, dd.n = trunc(ex.state, 40), n or 0 end
  S.rt.br[P.id] = {why = why, pos = dd.pos, t = now(K), c = now(K)}   -- the recheck looks there first
  M.note_breach(K, P.id, P.tpl, why, dd.pos)                              -- BUG-130: manifest.breaches
  K.emit('BREACH_STOP', 'B', breach_msg(P.id, why, src, was, n, ex and ex.state), dd)
  K.flush()
  dirty()
  if CAVERN[why] and dd.pos and d then plug(K, P, d, why, dd.pos, n, ex) end
  return true
end

-- the dig tiles of a document that hold water (at most `probes` tiles read, `max` found): {{x, y, z}, ...}
local function wet_tiles(K, d, tiles_of, probes, max)
  local out, asked = {}, 0
  for si = 0, #d.stages - 1 do
    local tiles = d.stages[si + 1].mode == 'dig' and tiles_of(si) or {}
    for ci = 1, #tiles do
      for _, tt in ipairs(tiles[ci]) do
        if asked >= probes or #out >= max then return out end
        asked = asked + 1
        local v = tile_at(K, tt[1], tt[2], tt[3])
        if v and HAZARD[v.c] == 'water' then out[#out + 1] = {tt[1], tt[2], tt[3]} end
      end
    end
  end
  return out
end

-- a stop raised by a look at the revealed tiles (src 'recheck': the project was stopped as damp/water/cavern)
local function raise(K, P, b, kind, hit, was, cnt)
  set_blocked(K, P, 'breach:' .. kind)
  b.why, b.pos = kind, hit and {hit[1], hit[2], hit[3]} or b.pos
  M.note_breach(K, P.id, P.tpl, kind, b.pos)                               -- BUG-130
  local dd = {proj = P.id, why = kind, src = 'recheck', was = was, n = cnt or 0}
  if hit then dd.pos = {hit[1], hit[2], hit[3]} end
  K.emit('BREACH_STOP', 'B', breach_msg(P.id, kind, 'recheck', was, cnt), dd)
end

-- Run 11 (the live shaft was stopped as damp before this check existed): once a recheck, a project stopped as
-- damp/water/cavern without a plug record looks at its stored breach tile and its dug tiles that hold water; a
-- cavern lake or an open cavern there raises the stop (BREACH_STOP src 'recheck'; CAVERN_PLUG 'none': no automatic
-- plug for these templates). Explore projects are the shaft check's (below), in every state.
local RECHECK = {['breach:damp'] = true, ['breach:water'] = true, ['breach:cavern'] = true,
                 ['breach:cavern_lake'] = true}
local function recheck_stops(K, t, c)
  local parts = c.parts
  for _, P in ipairs(S.pd.list) do
    local b = S.rt.br[P.id]
    local due = type(b) ~= 'table' or not int(b.c) or t - int(b.c) >= M.CFG.recheck
    if due and P.done ~= 1 and RECHECK[P.blocked] and P.tpl ~= 'plug' and P.tpl ~= 'explore'
       and S.rt.cav[P.id] == nil then
      if type(b) ~= 'table' then b = {}; S.rt.br[P.id] = b end
      b.c = t
      dirty()
      local d = doc(K, P.id)
      if d then
        local was, st0 = P.blocked:sub(8), P.blocked
        local cands = {}
        if type(b.pos) == 'table' and int(b.pos[1]) then cands[1] = b.pos end
        for _, w in ipairs(wet_tiles(K, d, function(si) return stage_tiles(P.id, d, si) end, M.CFG.retry_probe,
                                     3 - #cands)) do cands[#cands + 1] = w end
        local hit, kind, cnt
        for _, c in ipairs(cands) do
          local k, n = M.opened(K, P, d, c)
          if k and CAVERN[k] then hit, kind, cnt = c, k, n; break end
        end
        -- a cavern stop from a report without a tile: only on what the tiles show (an explore shaft: the shaft check)
        if CAVERN[was] and kind and RANK[kind] < RANK[was] then kind = was end
        if kind then
          if kind ~= was then raise(K, P, b, kind, hit, was, cnt) end
          plug(K, P, d, kind, hit, cnt)
        end
        local line = string.format('%s (%s) %s: %s', P.id, P.tpl, st0,
                                   kind and ((kind:gsub('_', ' ')) .. ', no automatic plug') or 'no cavern')
        if Q.news(b, line) then parts[#parts + 1] = line else c.same = c.same + 1 end   -- BUG-039: news only
      end
    end
  end
end

-- Run 11 (Kilrudrabed site98, explore c1a14676: after a reload it stood at 'dig 98 % stalled' while its shaft 136,73
-- z137-127 opened into a cavern lake; the recheck above only looked at projects stopped as damp/water/cavern, so the
-- shaft stayed open): every explore's stair column is noted (m.runner xs[<id>] = {x, y, top, low, t, c = last check,
-- fin = done|cancelled once the project left, off = nothing left to watch}) and looked at once a day and at the first
-- runs after a boot, at most shaft_n per run, whatever the project's state: running, stalled, blocked, stopped, done or
-- cancelled. A column whose top is dug is read top down on revealed tiles; its bottom, its tiles that hold water, the
-- stored breach tile and the document's dug tiles that hold water are held against the revealed tiles (opened_at, the
-- breach test). A cavern lake or an open cavern there plugs the shaft at once (CAVERN_PLUG queued, field state); a
-- project still digging is stopped first (BREACH_STOP src 'check', its applied chunks undone), one stopped as
-- damp/water is raised (src 'recheck'). Each run that looked logs one line naming every shaft looked at and the result.
local function shaft_state(P, r)
  if not P then return r.fin or 'gone' end
  if P.done == 1 then return 'done' end
  local b = P.blocked
  if b == '' then return 'running' end
  if b == 'stalled' or b == 'cancel' or b:sub(1, 7) == 'breach:' then return b end
  return 'blocked:' .. b
end

local CAV_RES = {open = 'plug %s under way', failed = 'plug %s failed: wall the shaft top by hand', done = 'plugged'}

-- one shaft: the result text for the log line; r.off once nothing is left to watch
local function shaft_look(K, t, id, r)
  local P = find(id)
  local live = P ~= nil and P.done ~= 1
  local state = shaft_state(P, r)
  local c = S.rt.cav[id]
  if type(c) == 'table' and c.st ~= 'none' then
    if c.st == 'done' then r.off = 1 end
    return state, string.format(CAV_RES[c.st] or c.st, c.plug ~= '' and c.plug or '(by hand)')
  end
  local sh, why0 = read_shaft(K, r)
  local shut, where = false, nil
  if sh then shut, where = walled(K, sh.s0, sh.s1) end
  if not sh or shut then
    if sh or not live then r.off = 1 end
    return state, sh and (where == 'below' and string.format('closed (a constructed wall below the %s on its top)',
                                                              sh.s0[5] or 'building')
                          or 'closed (a constructed wall on its top)')
                  or (why0 == 'hidden' and 'top hidden' or 'not dug yet'), sh and sh.bot
  end
  -- a hatch or door on the top is no plug (doctrine: forgotten beasts and building destroyers pass them)
  local cover = (sh.s0[4] == '+' or sh.s0[5]) and string.format(' (the %s on its top is no plug)',
                                                               (sh.s0[5] or 'hatch'):lower()) or ''
  local d = live and doc(K, id) or nil
  local fd = not d and file_doc(K, id) or nil
  local own
  if d then own = own_tiles(P, d) elseif fd then own = fd.own else
    own = {}
    for z = r.low, r.top do own[tkey(r.x, r.y, z)] = true end
  end
  local cands, seen = {}, {}
  local function add(p)
    local x, y, z = int(type(p) == 'table' and p[1]), int(type(p) == 'table' and p[2]), int(type(p) == 'table' and p[3])
    if x and y and z and #cands < 4 and not seen[tkey(x, y, z)] then
      seen[tkey(x, y, z)] = true
      cands[#cands + 1] = {x, y, z}
    end
  end
  local b = S.rt.br[id]
  if type(b) == 'table' then add(b.pos) end
  add({sh.x, sh.y, sh.bot})
  for _, w in ipairs(sh.wet) do add(w) end
  local dd = d or fd
  if dd and #cands < 4 then
    local tiles_of = d and function(si) return stage_tiles(id, d, si) end or tiles_fn(fd)
    for _, w in ipairs(wet_tiles(K, dd, tiles_of, M.CFG.shaft_probe, 4)) do add(w) end
  end
  local hit, kind, cnt, best, bk = nil, nil, nil, 0, nil
  -- BUG-033: the candidates share their liquids reads, and one inside the water an earlier flood reached is skipped
  local lq, covered = {}, {}
  for _, cp in ipairs(cands) do
    if not covered[tkey(cp[1], cp[2], cp[3])] then
      local k, n, seen = opened_at(K, own, cp, lq)
      for key in pairs(seen or {}) do covered[key] = true end
      if (n or 0) > best then best, bk = n, k end
      if k and CAVERN[k] then hit, kind, cnt = cp, k, n; break end
    end
  end
  local was = live and P.blocked:match('^breach:(.+)$') or nil
  -- a cavern stop from a report without a tile: the explore shaft is plugged anyway (a dead end into the cavern)
  if was and CAVERN[was] and (not kind or RANK[kind] < RANK[was]) then kind, hit = was, hit or cands[1] end
  if not kind then
    return state, (best > 0 and string.format('no cavern (%d water tiles in reach%s)', best,
                                              bk == 'water' and ', under the open sky' or '') or 'no cavern') .. cover,
           sh.bot
  end
  if type(c) == 'table' then S.rt.cav[id] = nil end           -- an old 'none' (no dug column then): look again
  local ex = {sh = sh, state = state, n = cnt or 0}
  if live and was then
    if RANK[was] and RANK[kind] > RANK[was] then
      if type(b) ~= 'table' then b = {}; S.rt.br[id] = b end
      raise(K, P, b, kind, hit, was, cnt)
    end
  elseif live and P.blocked ~= 'cancel' then
    breach(K, P, kind, hit, 'check', ex)                       -- still digging: stop it, undo its designations
  end
  if S.rt.cav[id] == nil then plug(K, P or {id = id, tpl = 'explore'}, d, kind, hit, cnt, ex) end
  local c2 = S.rt.cav[id]
  local label = (kind:gsub('_', ' ')) .. ((cnt or 0) > 0 and string.format(' (%d water tiles)', cnt) or '')
  local out = c2 and c2.st == 'open' and ('plug ' .. c2.plug .. ' queued') or (c2 and c2.st == 'done' and 'walled already')
              or ('plug ' .. (c2 and c2.st or '?'))
  return state, label .. ' -> ' .. out .. cover, sh.bot
end

-- the shafts to look at this run (at most shaft_n, the never seen first) and how many more are due; also notes the
-- explores without a record and scans the bp folder (scan_n files a run)
local function shaft_prep(K, t)
  S.xseen, S.xmiss = S.xseen or {}, S.xmiss or {}
  -- explores queued before the check existed (or by an older kernel); BUG-039: never one whose record the trim dropped
  -- this boot (S.xmiss: it would be due again at once, the same shafts every run)
  for _, P in ipairs(S.pd.list) do
    if P.tpl == 'explore' and S.rt.xs[P.id] == nil and not S.xmiss[P.id] then
      local c = S.rt.cav[P.id]
      if not (type(c) == 'table' and c.st == 'done') and not note_shaft(K, P, P.done ~= 1 and doc(K, P.id) or nil) then
        S.xmiss[P.id] = true                -- no document and no bp file with a stair column: not read again this boot
      end
    end
  end
  -- explores that left the list before their shafts were recorded (Run 11: c1a14676 was cancelled under the older
  -- kernel, a hatch on its top): their bp files, scan_n a run from the first check after a boot on (state 'gone')
  if S.xscan == nil then
    S.xscan = {}
    for _, n in ipairs(fio.listdir(K.cfg.paths.save .. '/bp')) do
      local id = type(n) == 'string' and n:match('^([A-Za-z0-9_-]+)%.json$')
      local c = id and S.rt.cav[id]
      if id and not find(id) and S.rt.xs[id] == nil and not (type(c) == 'table' and c.st ~= 'none') then
        S.xscan[#S.xscan + 1] = id
      end
    end
    table.sort(S.xscan, function(a, b) return a > b end)    -- taken from the end: in name order
  end
  for _ = 1, M.CFG.scan_n do
    local id = table.remove(S.xscan)
    if not id then break end
    local r = not find(id) and S.rt.xs[id] == nil and not S.xmiss[id] and
              note_shaft(K, {id = id, tpl = 'explore'}, file_doc(K, id))
    if r then r.fin = 'gone' end
  end
  -- due: not looked at since the boot, else daily; a stopped explore keeps its stop's cadence (m.runner br: a fresh
  -- stop was looked at when it came, one without a record at once); BUG-033: a finished one whose last look found water
  -- in reach but no cavern (r.q) every fin_every
  -- BUG-039: a finished shaft's cadence r.per (days; r.q of an older kernel: fin_every)
  local function every(c, per) return not int(c) or t - c >= (per or M.CFG.recheck) or t < c end
  local due, lv = {}, {}
  for id, r in pairs(S.rt.xs) do
    if type(r) ~= 'table' or not (int(r.x) and int(r.y) and int(r.top) and int(r.low)) then S.rt.xs[id] = nil; dirty()
    elseif r.off ~= 1 then
      local P, b = find(id), S.rt.br[id]
      local stopped = P ~= nil and P.done ~= 1 and RECHECK[P.blocked]
      local live = P ~= nil and P.done ~= 1
      local per = not live and ((int(r.per) and int(r.per) * DAY) or (r.q == 1 and M.CFG.fin_every)) or nil
      if not S.xseen[id] or (stopped and every(type(b) == 'table' and b.c or nil)) or (not stopped and every(r.c, per)) then
        due[#due + 1], lv[id] = id, live and 0 or 1
      end
    end
  end
  table.sort(due, function(a, b)           -- the never seen this boot, then the live explores (BUG-039), then the oldest
    local ra, rb = S.rt.xs[a], S.rt.xs[b]
    local sa, sb = S.xseen[a] and 1 or 0, S.xseen[b] and 1 or 0
    if sa ~= sb then return sa < sb end
    if lv[a] ~= lv[b] then return lv[a] < lv[b] end
    if (ra.c or -1) ~= (rb.c or -1) then return (ra.c or -1) < (rb.c or -1) end
    return a < b
  end)
  S.xsat = #due > M.CFG.shaft_n                -- BUG-039: saturated: finished unchanged shafts wait longer
  local list = {}
  for i = 1, math.min(#due, M.CFG.shaft_n) do list[i] = due[i] end
  return list, math.max(0, #due - M.CFG.shaft_n)
end

-- BUG-039: a short signature of a look (its text without numbers: water counts move); news = it differs from the
-- record's last one (rec.sg, kept in the record)
function Q.sig(text)
  local h = 5381
  for ch in tostring(text):gsub('%d+', '#'):gmatch('.') do h = (h * 33 + ch:byte()) % 2147483647 end
  return h
end
function Q.news(rec, text)
  local sg = Q.sig(text)
  local was = rec.sg
  rec.sg = sg
  return was ~= sg
end

-- BUG-039: the cadence of a finished shaft after a look (r.per days; nil = daily): unchanged while the check is
-- saturated: fin_every, then doubled up to fin_max_d; changed: daily (a wet one: fin_every, BUG-033); live: daily
function Q.cadence(r, live, same, wet)
  local fd = M.CFG.fin_every // DAY
  r.q = nil
  if live then r.per = nil
  elseif not same then r.per = wet and fd or nil
  elseif S.xsat then r.per = math.min(M.CFG.fin_max_d, math.max(fd, 2 * (int(r.per) or 1)))
  elseif wet then r.per = math.max(fd, int(r.per) or 0) end
end

-- one shaft look (its own slice, BUG-033): the log part (BUG-039: only news; c.same counts the others)
local function shaft_one(K, t, id, c)
  local r, P = S.rt.xs[id], find(id)
  if type(r) ~= 'table' then return end
  local first = not S.xseen[id]
  r.c, S.xseen[id] = t, true
  if P and P.done ~= 1 and RECHECK[P.blocked] then
    if type(S.rt.br[id]) ~= 'table' then S.rt.br[id] = {} end
    S.rt.br[id].c = t
  end
  dirty()
  local state, res, bot = shaft_look(K, t, id, r)
  P = find(id)
  -- a finished shaft with water in reach but no cavern (the costly look: the wide water boxes) waits fin_every; a dry
  -- one (a 3x3x3 read per candidate) stays daily; BUG-039: an unchanged one waits longer while the check is saturated
  local same = not Q.news(r, state .. ': ' .. tostring(res))
  Q.cadence(r, P ~= nil and P.done ~= 1, same, type(res) == 'string' and res:find('^no cavern %(%d+ water') ~= nil)
  if same and not first then c.same = c.same + 1; return end
  c.parts[#c.parts + 1] = string.format('%s %d,%d z%d-%d %s: %s', id, r.x, r.y, r.top, bot or r.low, state, res)
end

-- at most shaft_keep records: the ones with nothing left to watch go first, then those of projects that left the list.
-- BUG-039: a done explore still in the list keeps its record (the next run noted it again, due at once: the same
-- shafts every run), and a dropped one is not noted again this boot (S.xmiss)
local function shaft_trim()
  local ids = {}
  for id in pairs(S.rt.xs) do ids[#ids + 1] = id end
  if #ids > M.CFG.shaft_keep then
    local function rank(id)
      local r, P = S.rt.xs[id], find(id)
      return (r.off == 1 and 0 or P == nil and 1 or 2)
    end
    table.sort(ids, function(a, b)
      local ka, kb = rank(a), rank(b)
      if ka ~= kb then return ka < kb end
      return (S.rt.xs[a].t or 0) < (S.rt.xs[b].t or 0)
    end)
    for i = 1, #ids - M.CFG.shaft_keep do
      if rank(ids[i]) < 2 then S.rt.xs[ids[i]], S.xmiss[ids[i]] = nil, true end
    end
    dirty()
  end
end

-- the daily look at stopped digs and explore shafts (task 'check' of every run, every mode; BUG-033: sliced, the
-- stopped digs and the bp scan in the first slice, then one shaft a slice): one log line per run that looked (the live
-- session reads why a shaft is or is not plugged there), and one at the first run after a boot even when there is
-- nothing to look at. -> 'yield' (more slices) or 'done'
-- BUG-039: the line names only news (a changed look, the first look after a boot, a plug or a stop); a run with none
-- logs a summary at most once per util/cadence (7 days and 10 min, again only after a line with news)
local function check_task(K, t)
  local c = S.chk
  if not c then
    c = {parts = {}, same = 0}
    recheck_stops(K, t, c)
    c.due, c.more = shaft_prep(K, t)
    c.n = #c.due
    S.chk = c
    if #c.due > 0 then return 'yield' end
  end
  local id = table.remove(c.due, 1)
  if id then
    shaft_one(K, t, id, c)
    if #c.due > 0 then return 'yield' end
  end
  S.chk = nil
  local parts = c.parts
  shaft_trim()
  local tail = (c.same > 0 and string.format('; %d unchanged', c.same) or '') ..
               (c.more > 0 and string.format('; %d more next run', c.more) or '')
  if #parts > 0 then
    if #parts > 8 then parts = {table.unpack(parts, 1, 8)}; parts[9] = '...' end
    K.log('info', 'cavern check: %s%s', table.concat(parts, '; '), tail)
    S.xq = CAD.quiet(S.xq)
  elseif c.same > 0 then
    local T = K.now()
    if CAD.due(S.xq, T, {}, {'same'}) then
      S.xq = CAD.mark(T, {}, {'same'})
      local n = 0
      for _ in pairs(S.rt.xs) do n = n + 1 end
      K.log('info', 'cavern check: nothing new (%d looked at, %d shafts watched%s)', c.n, n,
            c.more > 0 and string.format('; %d more next run: finished unchanged shafts wait longer', c.more) or '')
    end
  elseif not S.xlog then
    K.log('info', 'cavern check: no explore shaft and no stopped dig to look at')
  end
  S.xlog = true
  return 'done'
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

-- CONTRACTS §9.8 class gating: ALERT/RECOVERY defense+infra, SIEGE defense inside, beauty PEACE+R1; the cavern plug
-- (Run 11) in every mode: an open way from a cavern matters most in a fight; a lost bridge's repair (seal, BUG-030
-- rebuild policy: params.peace) only in PEACE without a reflex lockdown
local function allowed(K, P, d)
  if P.tpl == 'plug' then return true end
  local m = K.mode()
  if P.tpl == 'repair' and d and type(d.params) == 'table' and d.params.peace == 1 then
    if m ~= 'PEACE' then return false end
    local ok, why = K.call('reflex', 'holding')
    return not (ok and type(why) == 'string' and why ~= '')
  end
  if m == 'PEACE' then return P.class ~= 'beauty' or beauty_ok(K) end
  if m == 'ALERT' or m == 'RECOVERY' then return P.class == 'defense' or P.class == 'infra' end
  if m == 'SIEGE' then return P.class == 'defense' and d ~= nil and inside(K, P, d) end
  return false
end

-- seal first (Run 11 siege 8): seal and plug projects before every other, then prio, then age
local function sorted()
  local r = {}
  for _, P in ipairs(S.pd.list) do if P.done ~= 1 then r[#r + 1] = P end end
  local care = S.care_id                        -- BUG-116: the hospital that runs first, after the seals
  table.sort(r, function(a, b)
    local sa, sb = SEALS[a.tpl] and 0 or care == a.id and 1 or 2, SEALS[b.tpl] and 0 or care == b.id and 1 or 2
    if sa ~= sb then return sa < sb end
    if a.prio ~= b.prio then return a.prio < b.prio end
    if a.created ~= b.created then return a.created < b.created end
    return a.id < b.id
  end)
  return r
end

---------------------------------------------------------------- seal first and the rebuild policy (Run 11 siege 8)
-- What a project is to them (kind_of): seal (seal, plug), tombs (tombs, care's coffins), depot, explore (DECISIONS 4:
-- the ore search is paused by the rebuild policy but not by an open seal), supply (farms,
-- cistern, stockroom, refuge_drink (FR-69), a workshops project of food/drink shops only: follow's fishery), beds
-- (bedrooms, refuge_beds), repair (runner.repair of lost walls and doors, and seal's wall + door for a lost bridge,
-- BUG-081: params.cl; a peace-only one that rebuilds a bridge is defense), mood (care's drink nook beside a mood
-- workshop, BUG-063/081), defense (any other defense class project: fortcore stages 2-4, barracks, captives,
-- gallery_o1) and work (the rest: rooms, workshops, furnaces, explore, fortcore stage 1, beauty).
-- An open seal pauses in PEACE: work, beds, and supply unless an emergency holds (food or drink days below
-- seal_first food_d/drink_d, a patient without accepted water). Never paused: seal, tombs (GHOSTS: the dead must be
-- buried), mood (a dwarf in a strange mood drinks nothing while his job waits), the depot (a caravan leaves without one),
-- repairs and defense (they close or guard the fort too). While the
-- free stone is below what the rock orders and walls want (stock.rock < rock_need), a paused project in a dig stage
-- digs on: its boulders become the seal's walls.
-- The rebuild policy runs (PEACE/RECOVERY; the mode's class gating still holds) seal, tombs, supply, beds, repair, mood
-- and the depot; the rest pauses.
local SUPPLY = {farms = true, cistern = true, stockroom = true, refuge_drink = true}     -- FR-69: the refuge's store
local BEDS = {bedrooms = true, refuge_beds = true}
local FOOD_SHOPS = {Still = true, Kitchen = true, Butchers = true, Fishery = true}
local SEAL_PAUSES = {work = true, beds = true, supply = true}
local REBUILD_RUNS = {seal = true, tombs = true, supply = true, beds = true, repair = true, depot = true, mood = true}
local PIECE_NAME = {d = 'door', H = 'hatch', Cw = 'wall', W = 'grate', G = 'grate', B = 'bars', h = 'channel',
                    p = 'gather', t = 'chop'}

local function words(s)
  local out = {}
  for v in tostring(s or ''):gmatch('[^,%s]+') do out[#out + 1] = v end
  return out
end
local function plural(n, w) return string.format('%d %s%s', n, w, n == 1 and '' or 's') end

-- a workshops project of food and drink shops only (every moodable type skipped, `add` Still/Kitchen/Butchers/Fishery)
local function food_shops(d)
  local p = type(d) == 'table' and type(d.params) == 'table' and d.params or {}
  local add, skip = words(p.add), {}
  if #add == 0 then return false end
  for _, a in ipairs(add) do if not FOOD_SHOPS[a] then return false end end
  for _, s in ipairs(words(p.skip)) do skip[s] = true end
  for _, m in ipairs(M.MOODABLE) do if not skip[m] then return false end end
  return true
end

local function kind_of(P, d)
  local t = P.tpl
  if SEALS[t] then return 'seal' end
  if t == 'tombs' or t == 'depot' or t == 'explore' then return t end   -- DECISIONS 4: the ore search never rests
  if SUPPLY[t] or (t == 'workshops' and food_shops(d)) then return 'supply' end
  if BEDS[t] then return 'beds' end
  if t == 'repair' then
    local p = type(d) == 'table' and type(d.params) == 'table' and d.params or {}
    return (p.peace == 1 and p.cl ~= 1) and 'defense' or 'repair'     -- BUG-081: a closure is a repair, not a bridge
  end
  if t == 'mood_drink' then return 'mood' end                         -- BUG-081: a drink for a mood dwarf, never paused
  return P.class == 'defense' and 'defense' or 'work'
end

-- config/baseline.json "runner" over M.CFG (a value of another type or out of range keeps the default)
local function nat(v, lo, hi, d) return (math.type(v) == 'integer' and v >= lo and v <= hi) and v or d end
local function conf(K)
  local c = type(K.cfg) == 'table' and type(K.cfg.baseline) == 'table' and K.cfg.baseline.runner
  c = type(c) == 'table' and c or {}
  local sf = type(c.seal_first) == 'table' and c.seal_first or {}
  local rb = type(c.rebuild) == 'table' and c.rebuild or {}
  local q = type(c.queue) == 'table' and c.queue or {}
  local cf = type(c.care_first) == 'table' and c.care_first or {}           -- BUG-116
  local r = {on = M.CFG.seal_first, stuck = nat(sf.stuck_days, 1, 60, M.CFG.seal_stuck_days) * DAY,
             wall = M.CFG.seal_wall, wall_days = nat(sf.wall_days, 0, 60, M.CFG.seal_wall_days) * DAY,
             food_d = nat(sf.food_d, 0, 400, M.CFG.emerg_food_d), drink_d = nat(sf.drink_d, 0, 400, M.CFG.emerg_drink_d),
             pop = nat(rb.pop, 0, 250, M.CFG.rebuild_pop), off = nat(rb.off, 0, 250, M.CFG.rebuild_off),
             yield = nat(q.yield_days, 1, 60, M.CFG.yield_days) * DAY,     -- BUG-037
             park = nat(q.park_days, 1, 400, M.CFG.park_days) * DAY}
  -- BUG-066 / FR-76: the manifest follows the workshops that stand (reclaim = config runner.reclaim)
  local rc = type(c.reclaim) == 'table' and c.reclaim or {}
  r.rec = {on = rc.on ~= false, scans = nat(rc.gone_scans, 1, 10, M.CFG.rec_scans),
           min = nat(rc.min_ws, 1, 50, M.CFG.rec_min), ask = nat(rc.ask_days, 1, 60, M.CFG.rec_ask) * DAY}
  r.care = {on = M.CFG.care_first, stuck = nat(cf.stuck_days, 1, 60, M.CFG.care_stuck_days) * DAY,
            patients = nat(cf.patients, 1, 250, M.CFG.care_patients)}
  if type(cf.on) == 'boolean' then r.care.on = cf.on end
  if type(sf.on) == 'boolean' then r.on = sf.on end
  if type(sf.wall) == 'boolean' then r.wall = sf.wall end
  r.off = math.max(r.off, r.pop)
  return r
end

-- BUG-037: blocked for good (nothing in the kernel clears it: build_lost with its retries spent, a breach stop, quickfort
-- failing, the document gone, the plug refused); parked once it stood park_days (pt: conf(K).park)
Q.FINAL = {apply_fail = true, bp_missing = true, plug_refused = true}
function Q.terminal(P)
  local b = P.blocked
  if b:sub(1, 7) == 'breach:' or Q.FINAL[b] then return true end
  local q = b == 'build_lost' and S.rt.rty[P.id]
  return type(q) == 'table' and (int(q.n) or 0) >= M.CFG.retry_max
end
function Q.parked(K, P, pt)
  return P.done ~= 1 and P.blocked ~= '' and Q.terminal(P) and now(K) - (int(P.since) or 0) >= (pt or conf(K).park)
end
-- a project the keepers, M.pending, the depot keeper and PLAN_EXHAUSTED wait for: not done, not parked
function Q.live(K, P, pt) return P.done ~= 1 and not Q.parked(K, P, pt) end

-- a food, water or drink emergency (economy's stock days, water's dry hospital with patients), else nil
local function emergency(K, c)
  local v = K.view()
  local st = type(v.stock) == 'table' and v.stock or {}
  local fd, dd = int(st.food_d), int(st.drink_d)
  if fd and fd < c.food_d then return string.format('food %d d', fd) end
  if dd and dd < c.drink_d then return string.format('drink %d d', dd) end
  local w = type(v.water) == 'table' and v.water or {}
  if (int(w.patients) or 0) > 0 and w.hosp_ok == 0 then return 'patients without water' end
end

local function rock_short(K)
  local st = K.view().stock
  if type(st) ~= 'table' then return false end
  local rock, need = int(st.rock), int(st.rock_need)
  return rock ~= nil and need ~= nil and rock < need
end

-- a piece stands built on the tile: a finished building (not a planned one), or a finished construction / closing tile
-- on the snapshot (a construction is no building once it is built)
local function piece_built(K, t)
  local find = dfhack.buildings and dfhack.buildings.findAtTile
  if find then
    local ok, b = pcall(find, t[1], t[2], t[3])
    if ok and b then return not is_construction(b) and built(b) end
  end
  local okt, tile = K.call('snapshot', 'tile', t[1], t[2], t[3])
  return okt and type(tile) == 'table' and OCCUPIED[tile.c] == true
end

-- the pieces of an open seal or plug not built yet: their count and the first 6 as 'door 114,73,143'. One per tile (a
-- shrub's gather and the door after it are one piece); the current build stage reads its cells (piece_built), the
-- current dig stage counts the cells of chunks not measured done, a later stage every cell; a plug's hatch removal is
-- no piece
local function open_pieces(K, P, d)
  local order, key = {}, {}
  local R = S.rt.p[P.id]
  local cd = type(R) == 'table' and R.si == P.stage and type(R.cd) == 'string' and R.cd or ''
  for si = P.stage, #d.stages - 1 do
    local st = d.stages[si + 1]
    if not is_free(st) then
      for ci, ch in ipairs(st.chunks) do
        for _, cell in ipairs(ch.cells) do
          local tl = {}
          cell_tiles(ch, cell, tl)
          local t = tl[1]
          local open = t ~= nil
          if open and si == P.stage then
            if st.mode == 'build' then open = not piece_built(K, t)
            elseif st.mode == 'dig' then open = cd:sub(ci, ci) ~= '1' end
          end
          if open then
            local k = tkey(t[1], t[2], t[3])
            if not key[k] then order[#order + 1] = k end
            if not key[k] or st.mode == 'build' then key[k] = t[4] end
          end
        end
      end
    end
  end
  local names = {}
  for i = 1, math.min(#order, 6) do names[i] = (PIECE_NAME[key[order[i]]] or key[order[i]]) .. ' ' .. order[i] end
  return #order, names
end

-- BUG-041 (Run 11 y461: the seal door 59,62,146 on a shrub waited 220 days at seal.clear for a gather designation;
-- nobody gathers above 30 food days, economy's gather task): quickfort builds doors and constructions on SHRUB tiles
-- (internal/quickfort/build.lua is_valid_tile_generic, 53.16-r2: FLOOR, BOULDER, PEBBLES, TWIG, SAPLING, SHRUB), so a
-- seal's gather cell (`p`, stage seal.clear of the CLI before BUG-041) waits for nothing: apply leaves it out, the
-- measure counts it done and removes a gather designation still flagged on its tile (quickfort #dig x, the designations
-- screen's remove; a job DF posted already, without the flag, is left: the plant goes when the piece is built).
-- kern.log once per stage (R.gn), again when it removed a designation
function Q.nogather(P, ch)
  if P.tpl ~= 'seal' then return ch, 0 end
  local keep, n = {}, 0
  for _, c in ipairs(ch.cells) do
    if c[4]:match('^[^{(:/]*') == 'p' then n = n + 1 else keep[#keep + 1] = c end
  end
  if n == 0 then return ch, 0 end
  return {pos = ch.pos, cells = keep}, n
end
function Q.gathered(K, P, d, R, t)
  local ok, v = K.call('snapshot', 'tile', t[1], t[2], t[3])
  S.slice.probes = S.slice.probes + 1
  local rm = false
  if ok and type(v) == 'table' and v.dig ~= nil and v.dig ~= '' and v.dig ~= 'job' and qf_room() then
    local okx, sx = qf(K, {mode = 'dig', data = {[0] = {[0] = {[0] = 'x'}}}, pos = {t[1], t[2], t[3]}})
    rm = okx and type(sx) == 'table' and (int(sx.dig_designated) or 0) > 0
  end
  if R.gn == 1 and not rm then return 'done' end
  R.gn = 1
  local piece = 'piece'                        -- what a later stage builds on that tile (the seal.plant door)
  for si = P.stage + 2, #d.stages do
    for _, ch in ipairs(d.stages[si].chunks) do
      for _, c in ipairs(ch.cells) do
        if ch.pos[1] + c[1] == t[1] and ch.pos[2] + c[2] == t[2] and ch.pos[3] + c[3] == t[3] then
          piece = PIECE_NAME[c[4]:match('^[^{(:/]*')] or piece
        end
      end
    end
  end
  K.log('info', '%s %s: no gather at %d,%d,%d: the %s goes on the shrub (quickfort builds on shrub tiles; a gather job ' ..
        'waits for a plant gatherer)%s', P.id, d.stages[P.stage + 1].label, t[1], t[2], t[3], piece,
        rm and '; its gather designation removed' or '')
  dirty()
  return 'done'
end

-- BUG-041: why the first open piece of a stuck seal waits, as far as the labors and the revealed tiles tell (SEAL_STUCK
-- d.wait; once per stuck event, no scan of its own): a clear stage's job (chop FellTree, gather GatherPlants) with the
-- citizens who have its labor enabled; 'no citizen reaches <piece> or a tile beside it (walk groups 5018; citizens 7827)'
-- when the piece's tile, its 8 neighbours on the level and the tiles above and below (the builders' standing tiles,
-- generously) are on no citizen's walk group (snapshot.groups; a hidden one is unknown and makes no claim; tiles off
-- the map are no standing tiles). Informative only: the piece stays open (a raised bridge or a ramp not dug yet may
-- cut it off for now; flyers and climbers need no walk group)
Q.JOB = {t = {'FellTree', 'CUTWOOD', 'Wood cutting'}, p = {'GatherPlants', 'HERBALIST', 'Plant gathering'}}

-- BUG-044: what the building on a piece's tile and its construction job wait for (economy.build_state, read-only):
-- 'door 114,73,143: job 4711 suspended by buildingplan: waits for door x1 (0 free, 110 ordered)', 'nothing stands at ...';
-- nil when economy does not answer
function Q.piece_why(K, t)
  local ok, bs = K.call('economy', 'build_state', t[1], t[2], t[3])
  if not (ok and type(bs) == 'table' and type(bs.line) == 'string') then return nil end
  return string.format('%s %d,%d,%d: %s', PIECE_NAME[t[4]] or t[4], t[1], t[2], t[3], bs.line), bs
end

function Q.wait_why(K, P, d)
  local st = d.stages[P.stage + 1]
  if not st or is_free(st) then return nil end
  local R = S.rt.p[P.id]
  local cd = type(R) == 'table' and R.si == P.stage and type(R.cd) == 'string' and R.cd or ''
  local tiles, t = stage_tiles(P.id, d, P.stage), nil
  for ci = 1, #tiles do
    if st.mode ~= 'dig' or cd:sub(ci, ci) ~= '1' then
      for _, x in ipairs(tiles[ci]) do
        local done = (st.mode == 'build' and piece_built(K, x)) or (st.mode == 'dig' and x[4] == 'p' and P.tpl == 'seal')
        if not done then t = x; break end
      end
    end
    if t then break end
  end
  if not t then return nil end
  local cits, out = {}, {}
  local cu = K.census.u
  for _, id in ipairs(type(cu) == 'table' and type(cu.ids) == 'table' and cu.ids or {}) do
    local u = df.unit.find(id)
    if u then cits[#cits + 1] = u end
  end
  local job = st.mode == 'dig' and Q.JOB[t[4]]
  if job then
    local n = 0
    for _, u in ipairs(cits) do
      local ok, v = pcall(function() return u.status.labors[job[2]] end)
      if ok and v == true then n = n + 1 end
    end
    out[#out + 1] = string.format('%s at %d,%d,%d: %s enabled for %d of %d citizens%s', job[1], t[1], t[2], t[3], job[3],
                                  n, #cits, n == 0 and ': nobody takes it' or '')
  end
  if st.mode == 'build' then
    local w = Q.piece_why(K, t)             -- BUG-044: the building and its job, who suspends it
    if w then out[#out + 1] = w end
  end
  if #cits > 0 then
    local pts = {}
    for dz = -1, 1 do
      for dy = -1, 1 do
        for dx = -1, 1 do
          if (dz == 0 or (dx == 0 and dy == 0)) and on_map(t[1] + dx, t[2] + dy, t[3] + dz) then
            pts[#pts + 1] = {t[1] + dx, t[2] + dy, t[3] + dz}
          end
        end
      end
    end
    local np = #pts
    for i = 1, math.min(#cits, 50) do
      local ok, x, y, z = pcall(dfhack.units.getPosition, cits[i])
      if ok and int(x) then pts[#pts + 1] = {x, y, z} end
    end
    local ok, g = K.call('snapshot', 'groups', pts, false)
    if ok and type(g) == 'table' then
      local cg, cl, tg, tl, hit, unk = {}, {}, {}, {}, false, false
      for i = np + 1, #pts do
        local v = int(g[i])
        if v and v > 0 and not cg[v] then cg[v] = true; cl[#cl + 1] = v end
      end
      for i = 1, np do
        local v = int(g[i]) or -1
        if v < 0 then unk = true
        elseif v > 0 then
          hit = hit or cg[v] == true
          if not tg[v] then tg[v] = true; tl[#tl + 1] = v end
        end
      end
      if #cl > 0 and not hit and not unk then
        table.sort(tl)
        table.sort(cl)
        out[#out + 1] = string.format('no citizen reaches %s %d,%d,%d or a tile beside it (walk groups %s; citizens %s)',
                                      PIECE_NAME[t[4]] or t[4], t[1], t[2], t[3],
                                      #tl > 0 and table.concat(tl, ',', 1, math.min(#tl, 4)) or 'none',
                                      table.concat(cl, ',', 1, math.min(#cl, 4)))
      end
    end
  end
  return #out > 0 and table.concat(out, '; ') or nil
end

-- BUG-081 (integration audit I2): seal's wall + door for a lost bridge (runner.repair opts.closure, params.cl = 1) is a
-- seal in all but name: the same door waits for the same item, a suspended job or a builder, and the fort stays open
-- until it stands. It keeps the stuck clock of a seal (SEAL_STUCK with the cause, the wall fallback), but pauses nobody
function Q.closure(P, d)
  return P.tpl == 'repair' and type(d) == 'table' and type(d.params) == 'table' and d.params.cl == 1
end

-- SEAL_STUCK (A): the seal built nothing for stuck_days; util/cadence per project (r.ev): a repeat needs news and
-- 7 days (Run 9 GHOSTS rule). BUG-041: d.wait = Q.wait_why
local function stuck_event(K, P, d, n, names, ticks, r)
  local st = d.stages[P.stage + 1]
  local label = trunc(st and st.label or 'done', 24)
  local days = ticks // DAY
  local _, mat = M.remake_why(K, P, d)
  local okw, wait = pcall(Q.wait_why, K, P, d)
  wait = okw and type(wait) == 'string' and trunc(wait, 160) or nil
  local msg = string.format('%s (%s) built nothing for %s at %s: %s open%s%s%s%s; %s', P.id,
                            P.tpl, plural(days, 'day'), label, plural(n, 'piece'),
                            #names > 0 and (' (' .. table.concat(names, ', ') .. ')') or '',
                            P.blocked ~= '' and ('; ' .. P.blocked) or '', mat and ('; ' .. mat) or '',
                            wait and ('; ' .. wait) or '',
                            P.tpl == 'repair' and 'the lost bridge stays open' or 'the other projects run again')
  K.log('warn', 'seal first: %s', msg)
  local T = K.now()
  local ids = #names > 0 and names or {P.id}
  if not CAD.due(r.ev, T, ids, {'stuck'}) then return end
  r.ev = CAD.mark(T, ids, {'stuck'})
  local dd = {proj = P.id, tpl = P.tpl, stage = label, days = days, n = n, pieces = names}
  if mat then dd.mat = trunc(mat, 80) end
  if P.blocked ~= '' then dd.blocked = trunc(P.blocked, 24) end
  if wait then dd.wait = wait end
  K.emit('SEAL_STUCK', 'A', trunc(msg, 200), dd)
  K.flush()
end

-- the rebuild policy is for a fallen fort, not a new one: it had rebuild_off citizens (m.runner pk, this kernel's
-- record) or got past P1 (a fresh embark of 7 is no rebuild)
local function fallen(K, c)
  return (int(S.rt.pk) or 0) >= c.off or (pnum(S.phase) or 0) >= 2
end

-- BUG-116 (Run 14 note 89): care first. The hospital project that runs first while the hospital lies outside the burrows
-- (water state hosp_out) or care.patients patients lie in the fort, in PEACE: the first project after the seals, the work and
-- housing projects pause (Q.CARE_PAUSES; seals, tombs, the depot, repairs, defense, mood nooks and food/drink projects never).
-- The first live hospital project that is not halted leads. Its progress is watched like a seal's (state m.runner cf = {id,
-- sig, t, st}): no stage, chunk or percent change for care_first.stuck_days latches st = 1, the others run again (kern.log
-- warns once) until the hospital moves; the clock waits while the mode is not PEACE. Returns {id, why} or nil
Q.CARE_PAUSES = {work = true, beds = true}
function Q.care_lead(K, c, t)
  local cf = c.care
  local w = K.view().water
  local out = type(w) == 'table' and int(w.hosp_out) or 0
  local pat = type(w) == 'table' and int(w.patients) or 0
  local need = cf.on and (out > 0 or pat >= cf.patients)
  local rec = S.rt.cf
  if not need then
    if rec ~= nil then S.rt.cf = nil; dirty() end
    return nil
  end
  local lead
  for _, P in ipairs(sorted()) do
    if P.tpl == 'hospital' and P.done ~= 1 and not halted(P) and P.blocked ~= 'cancel' and not Q.parked(K, P, c.park) then
      lead = P
      break
    end
  end
  if not lead then
    if rec ~= nil then S.rt.cf = nil; dirty() end
    return nil
  end
  local R = S.rt.p[lead.id]
  local sig = string.format('%d:%d:%d:%d', lead.stage, lead.chunk, lead.pct or 0, type(R) == 'table' and int(R.prog) or 0)
  if type(rec) ~= 'table' or rec.id ~= lead.id or rec.sig ~= sig then
    rec = {id = lead.id, sig = sig, t = t, st = 0}
    S.rt.cf = rec
    dirty()
  elseif K.mode() ~= 'PEACE' then
    if rec.t ~= t then rec.t = t; dirty() end                    -- the clock waits while the mode freezes the project
  elseif rec.st ~= 1 and t - rec.t >= cf.stuck then
    rec.st = 1
    dirty()
    K.log('warn', 'care first: %s made no progress for %d days: the other projects run again (it leads again when it moves)',
          lead.id, cf.stuck // DAY)
  end
  local why = out > 0 and string.format('hospital_out %d', out) or plural(pat, 'patient')
  if rec.st == 1 then return {id = lead.id, why = why, stuck = true, days = (t - rec.t) // DAY} end
  if K.mode() ~= 'PEACE' then return nil end
  return {id = lead.id, why = why}
end

-- BUG-116 public (economy's TOOL_BLOCKED names the hospital that waits for a pick): {proj, why, stuck?} while care first
-- leads (or is latched stuck), else nil. Read-only
function M.care_first(K)
  local f = S.focus
  if f and f.care then return {proj = f.care, why = f.care_why, stuck = f.care_stuck} end
  return nil
end

-- once a run (begin_run): the open seals and their progress clocks (m.runner sf[<proj>] = {sig, t, st, ev}), the
-- rebuild switch (m.runner rb, pk) and what the pause rules need now (S.focus)
local function focus(K)
  local c, t = conf(K), now(K)
  local f = {c = c, n = 0, more = 0, stuck = {}, stk = {}, emerg = emergency(K, c), rock = rock_short(K)}
  -- BUG-116: care first. Own pcall: a fault costs only this rule, never the seal-first count
  S.care_id = nil
  local okc, cl = pcall(Q.care_lead, K, c, t)
  if okc and cl then
    f.care, f.care_why, f.care_stuck, f.care_days = cl.id, cl.why, cl.stuck, cl.days
    if not cl.stuck then S.care_id = cl.id end
  elseif not okc then
    K.log('error', 'care first failed, this run without it: %s', trunc(cl, 160))
  end
  S.rt.sf = obj(S.rt.sf)
  local open = {}
  for _, P in ipairs(sorted()) do
    -- BUG-037: a parked seal (blocked for good past park_days) is out of the way: it pauses nothing, SEAL_STUCK is done
    local d = (SEALS[P.tpl] or P.tpl == 'repair') and P.blocked ~= 'cancel' and not Q.parked(K, P, c.park) and doc(K, P.id)
    if d and P.tpl == 'repair' and not Q.closure(P, d) then d = nil end     -- BUG-081: only a closure keeps the clock
    if d then
      open[P.id] = true
      local n, names = open_pieces(K, P, d)
      local R = S.rt.p[P.id]
      local sig = string.format('%d:%d:%d:%d', P.stage, P.chunk, n, type(R) == 'table' and int(R.prog) or 0)
      local r = S.rt.sf[P.id]
      if type(r) ~= 'table' then r = {sig = sig, t = t, st = 0}; S.rt.sf[P.id] = r; dirty() end
      if r.sig ~= sig then                            -- a piece built, a stage or chunk further: the clock starts again
        if r.st == 1 then
          r.st, r.ev = 0, CAD.quiet(r.ev)
          K.log('info', 'seal first: %s moves again (%s open)%s', P.id, plural(n, 'piece'),
                P.tpl == 'repair' and '' or ': it pauses the others again')
        end
        r.sig, r.t, r.nw, r.nu, r.wt = sig, t, nil, nil, nil
        dirty()
      elseif r.st ~= 1 and (not c.on or not allowed(K, P, d)) then
        r.t = t                                       -- the clock waits while the mode freezes the seal
        dirty()
      elseif r.st ~= 1 and t - r.t >= c.stuck then
        r.st = 1
        dirty()
        stuck_event(K, P, d, n, names, t - r.t, r)
      end
      if P.tpl == 'repair' then                       -- BUG-081: a closure pauses nobody and is never "stuck" for the others
      elseif r.st == 1 then f.stuck[#f.stuck + 1] = {id = P.id, n = n, days = (t - r.t) // DAY}; f.stk[P.id] = true
      elseif not f.lead then f.lead, f.n, f.names = P.id, n, names
      else f.more = f.more + 1 end
    end
  end
  for id in pairs(S.rt.sf) do if not open[id] then S.rt.sf[id] = nil; dirty() end end
  -- rebuild: on below c.pop in a fallen fort, off again at c.off (hysteresis); c.pop 0 = off
  local cu = K.census.u
  local cit = type(cu) == 'table' and int(cu.cit) or nil
  if cit and cit > (int(S.rt.pk) or 0) then S.rt.pk = cit; dirty() end
  local rb = S.rt.rb
  if c.pop <= 0 then
    if type(rb) == 'table' then
      S.rt.rb = nil; dirty(); K.log('info', 'rebuild: off (rebuild.pop 0): every project runs again')
    end
  elseif cit and type(rb) ~= 'table' and cit < c.pop and fallen(K, c) then
    S.rt.rb = {t = t, pop = cit}
    dirty()
    K.log('warn', 'rebuild: pop %d < %d (peak %d, phase %s): only seal, plug, tombs, food/drink, beds, wall repairs and ' ..
          'the depot run until pop >= %d', cit, c.pop, int(S.rt.pk) or 0, tostring(S.phase or '-'), c.off)
  elseif cit and type(rb) == 'table' and cit >= c.off then
    S.rt.rb = nil
    dirty()
    K.log('info', 'rebuild over: pop %d >= %d: every project runs again', cit, c.off)
  end
  if type(S.rt.rb) == 'table' then f.rb = {pop = cit or int(S.rt.rb.pop) or 0, lo = c.pop, hi = c.off} end
  return f
end

-- BUG-044 (Run 11 y483-y497: the door 115,73,143 stayed open for 14 game years, sieges 13 and 14 cost 60 citizens
-- through it): "an open way in is worse than a missing door". A seal door that is still not built seal_first.wall_days
-- after SEAL_STUCK (in PEACE, nobody working at it) is replaced by a constructed wall on the same tile: its cell becomes
-- `Cw` in the project's copy, the planned door is removed (quickfort undo, the player's remove building) and the chunk is
-- applied again (a wall needs no door item: buildingplan takes any building material). Only where the last entrance check
-- (seal.opening_ways, at most wall_age old) shows the citizens another way: the opening has a door or a bridge on it, or
-- another opening has one; else the door stays and kern.log says why, once. SEAL_WALLED (B) once per piece. One piece a
-- run (one quickfort call). A fault here is logged and costs this fallback only, never the seal-first count (own pcall)
function Q.stuck_walls(K, c)
  if not (c.on and c.wall) or K.mode() ~= 'PEACE' then return end
  local okh, hold = K.call('reflex', 'holding')            -- a lockdown holds the doors: citizens may be coming in
  if okh and type(hold) == 'string' and hold ~= '' then return end
  local t = now(K)
  for _, P in ipairs(sorted()) do
    local r = (P.tpl == 'seal' or P.tpl == 'repair') and (P.blocked == '' or P.blocked == 'stalled') and S.rt.sf[P.id]
    local d = type(r) == 'table' and r.st == 1 and t - r.t >= c.stuck + c.wall_days and doc(K, P.id)
    if d and P.tpl == 'repair' and not Q.closure(P, d) then d = nil end       -- BUG-081
    local st = d and d.stages[P.stage + 1]
    if st and st.mode == 'build' and P.chunk >= #st.chunks and t - (int(r.wt) or -DAY) >= DAY then
      r.wt = t                                   -- looked at once a game day (read-only calls, a few reads)
      dirty()
      for _, ch in ipairs(st.chunks) do
        for _, cell in ipairs(ch.cells) do
          local tl = {}
          cell_tiles(ch, cell, tl)
          local tile = tl[1]
          if tile and cell[4] == 'd' and not piece_built(K, tile) and qf_room() and (int(r.nu) or 0) < 3 then
            local at = tkey(tile[1], tile[2], tile[3])
            local why, bs = Q.piece_why(K, tile)
            local okw, w = K.call('seal', 'opening_ways', tile[1], tile[2], tile[3])
            local refuse
            if type(bs) == 'table' and bs.work == true then refuse = false              -- a builder is at it: wait
            elseif not (okw and type(w) == 'table' and w.known) then refuse = 'no entrance check yet'
            elseif (int(w.age) or 0) > M.CFG.wall_age then
              refuse = string.format('the entrance check is %d days old', (int(w.age) or 0) // DAY)
            elseif not (w.here_closable or (int(w.others) or 0) >= 1) then
              refuse = (int(w.routes) or 0) == 0 and 'the entrance check shows no open way' or 'no other way in or out'
            end
            if refuse == nil then
              local bid = bs and not bs.none and int(bs.id)
              if bid then                              -- the planned door goes first (a wall cannot stand on its site)
                qf(K, {mode = 'build', data = {[0] = {[0] = {[0] = 'd'}}}, pos = {tile[1], tile[2], tile[3]},
                       command = 'undo'})
                local okf, b2 = pcall(dfhack.buildings.findAtTile, tile[1], tile[2], tile[3])
                if okf and b2 and not is_construction(b2) then     -- still there: again next run, three times at most
                  r.nu = (int(r.nu) or 0) + 1
                  if r.nu >= 3 then
                    r.nw = type(r.nw) == 'table' and r.nw or {}
                    r.nw[at] = 'the planned door was not removed (quickfort undo)'
                    K.log('warn', 'seal first: %s: door %s stays a door: quickfort undo did not remove the planned door ' ..
                          '(%d tries)', P.id, at, r.nu)
                  end
                  dirty()
                  return
                end
              end
              cell[4] = 'Cw'
              local m = d.materials
              if type(m) == 'table' and int(m.door) then
                m.door, m.wall = int(m.door) > 1 and int(m.door) - 1 or nil, (int(m.wall) or 0) + 1
              end
              K.persist.set('bp.' .. P.id, d)
              for k in pairs(S.tiles) do if k:sub(1, #P.id + 1) == P.id .. '/' then S.tiles[k] = nil end end
              if S.own then S.own[P.id] = nil end
              local R = R_of(K, P)
              local keep = {}
              for _, id in ipairs(R.b) do if df.building.find(id) then keep[#keep + 1] = id end end
              R.b, R.uns, R.ra, P.chunk = keep, (int(R.uns) or 0) + 1, 1, 0
              local l = type(S.rt.sw[P.id]) == 'table' and S.rt.sw[P.id] or {}
              if #l < 8 then l[#l + 1] = at end
              S.rt.sw[P.id] = l
              local days = (t - r.t) // DAY
              local msg = string.format('%s (%s): door %s stuck %d days replaced by a wall (%s)', P.id,
                                        P.tpl == 'seal' and 'seal' or 'closure', at, days, why or 'cause not readable')
              K.log('warn', 'seal first: %s', msg)
              K.emit('SEAL_WALLED', 'B', trunc(msg, 200), {proj = P.id, at = at, was = 'door', days = days,
                                                          why = trunc(why or 'cause not readable', 160)})
              dirty()
              return
            elseif refuse then
              r.nw = type(r.nw) == 'table' and r.nw or {}
              if r.nw[at] ~= refuse then
                r.nw[at] = refuse
                K.log('warn', 'seal first: %s: door %s stays a door: %s (%s)', P.id, at, refuse, why or 'cause not readable')
                dirty()
              end
            end
          end
        end
      end
    end
  end
end

-- why the policy pauses this project now ('seal <id>', 'rebuild pop 2<10'), else nil; seals never pause
local function paused(K, P, d)
  local f = S.focus
  if not f or SEALS[P.tpl] then return nil end
  local k, m = kind_of(P, d), K.mode()
  if f.lead and f.c.on and m == 'PEACE' and SEAL_PAUSES[k] and not (k == 'supply' and f.emerg) then
    local st = d and d.stages[P.stage + 1]
    if not (f.rock and st and st.mode == 'dig') then return 'seal ' .. f.lead end
  end
  -- BUG-116: care first (the hospital leads, the work and housing projects wait; never the hospital itself)
  if f.care and not f.care_stuck and f.care ~= P.id and m == 'PEACE' and Q.CARE_PAUSES[k] then
    return 'care ' .. f.care
  end
  if f.rb and (m == 'PEACE' or m == 'RECOVERY') and not REBUILD_RUNS[k] then
    return string.format('rebuild pop %d<%d', f.rb.pop, f.rb.lo)
  end
end

-- one kern.log line when the set of paused projects changes (who pauses them, the first 8), one when they resume
local function note_pause(K, pz)
  local f = S.focus
  local groups, order = {}, {}
  for _, e in ipairs(pz) do
    if not groups[e.why] then groups[e.why] = {}; order[#order + 1] = e.why end
    local g = groups[e.why]
    g[#g + 1] = e.P.id .. ' ' .. e.P.tpl
  end
  local parts = {}
  for _, why in ipairs(order) do
    local g, head = groups[why], why
    if why:sub(1, 5) == 'seal ' then
      head = string.format('seal first: %s with %s open%s runs first', f.lead, plural(f.n, 'piece'),
                           #f.names > 0 and (' (' .. table.concat(f.names, ', ') .. ')') or '')
      if f.emerg then head = head .. ' (' .. f.emerg .. ': food/drink projects go on)' end
    elseif why:sub(1, 5) == 'care ' then
      head = string.format('care first: %s with %s runs first', f.care, f.care_why or '?')
    elseif f.rb then
      head = string.format('rebuild: pop %d < %d (until %d), only seal/tombs/food/beds', f.rb.pop, f.rb.lo, f.rb.hi)
    end
    parts[#parts + 1] = string.format('%s; paused: %s%s', head, table.concat(g, ', ', 1, math.min(#g, 8)),
                                      #g > 8 and string.format(' +%d', #g - 8) or '')
  end
  local key = table.concat(order, '|') .. '|'
  for _, e in ipairs(pz) do key = key .. e.P.id .. ',' end
  if #pz == 0 then key = '' end
  local was = S.rt.pz or ''
  if key == was then return end
  S.rt.pz = key
  dirty()
  if #pz > 0 then K.log('info', '%s', table.concat(parts, ' | '))
  else
    local m = K.mode()
    local why = (f.lead or f.rb) and ('mode ' .. m) or (#f.stuck > 0 and ('seal ' .. f.stuck[1].id .. ' stuck'))
                or 'no seal open, no rebuild'
    K.log('info', 'paused projects run again (%s)', why)
  end
end

-- state.sched (status: `seal open: 3 pieces (c1a147c261), others paused`; `rebuild: pop 2 < 10, ...`)
local function sched_state(f, pz)
  local ns, nr, nc = 0, 0, 0
  for _, e in ipairs(pz) do
    if e.why:sub(1, 5) == 'seal ' then ns = ns + 1 elseif e.why:sub(1, 5) == 'care ' then nc = nc + 1 else nr = nr + 1 end
  end
  local s = {}
  if f.care then                                  -- BUG-116
    s.care = {proj = f.care, paused = nc, why = trunc(f.care_why or '', 24)}
    if f.care_stuck then s.care.stuck, s.care.days = 1, f.care_days or 0 end
  end
  if f.lead then
    s.seal = {proj = f.lead, n = f.n, paused = ns, more = f.more + #f.stuck, stuck = 0}
  elseif #f.stuck > 0 then
    local x = f.stuck[1]
    s.seal = {proj = x.id, n = x.n, paused = 0, more = #f.stuck - 1, stuck = 1, days = x.days}
  end
  if f.rb then s.rb = {pop = f.rb.pop, lo = f.rb.lo, hi = f.rb.hi, paused = nr} end
  return next(s) and s or nil
end

-- BUG-037: a queued row names the first slot holder ('queued behind c1a148696a3d6da701 +2', state sched.q has all);
-- a project that yielded its slot says so; parked projects come last ('parked: build_lost')
function rows(K)
  local out, pt, sl = {}, conf(K).park, S.slots or {}
  local behind = #sl > 0 and ('queued behind ' .. sl[1] .. (#sl > 1 and (' +' .. (#sl - 1)) or '')) or 'queued'
  local list, last, pk = {}, {}, {}
  for _, P in ipairs(sorted()) do
    if Q.parked(K, P, pt) then pk[P.id] = true; last[#last + 1] = P else list[#list + 1] = P end
  end
  for _, P in ipairs(last) do list[#list + 1] = P end
  for _, P in ipairs(list) do
    if #out >= 8 then break end
    local d = doc(K, P.id)
    local st = d and d.stages[P.stage + 1]
    local b = P.blocked
    if b == '' then
      local ok = allowed(K, P, d)
      local pw = ok and paused(K, P, d)
      local yd = S.yielded and S.yielded[P.id]
      if not ok then b = 'frozen'
      elseif pw then b = 'paused: ' .. pw
      elseif S.active and not S.active[P.id] then
        b = yd and string.format('no progress %d d: slot yielded', yd) or behind
      end
    elseif pk[P.id] then b = 'parked: ' .. b end
    out[#out + 1] = {P.id, trunc(st and st.label or 'done', 24), P.pct, trunc(b, 40)}
  end
  S.rows, S.npk = out, #last
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
      -- FR-76: a project that starts at stage 2 or later passes the stages before it only when they ran
      if d and labels_done(d, P.stage) >= stage then
        local first = Q.first_stage(d)
        if first < 2 or Q.pre_ran(K, P, d, first - 1) then return true end
      end
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
    -- live L1b: a mood needs the workshop type anywhere in the fort, also one built by hand
    pcall(function()
      for _, b in ipairs(df.global.world.buildings.other.WORKSHOP_ANY) do
        if built(b) then have[df.workshop_type[b.type] or ''] = true end
      end
      for _, b in ipairs(df.global.world.buildings.other.FURNACE_ANY) do
        if built(b) then have[df.furnace_type[b.type] or ''] = true end
      end
    end)
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

-- nothing queued (BUG-037: a parked project does not count), no plan build pending, and the phase cannot advance
-- through projects
local function exhausted(K)
  if S.plan_pending or not S.stuck then return end
  for _, P in ipairs(S.pd.list) do if Q.live(K, P) then return end end
  local pp = K.persist.get('plan')
  -- live L1b: once more after every finished project, so follow can start a phase's next deliverable
  local fin = 0
  for _, h in pairs(S.rt.hist) do fin = fin + (int(h.n) or 0) end
  local key = string.format('%s:%s:%s:%d', S.phase or '-', tostring(K.plan.year), tostring(pp and pp.loaded or 0), fin)
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
  for _, P in ipairs(S.pd.list) do if P.tpl == tpl and Q.live(K, P) then return false end end   -- BUG-037: not parked
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

---------------------------------------------------------------- temporary gather zone (live L6)
-- Laborkings (and Castlerisen L5, where 36 zones over 19,151 tiles were drawn by hand): below gather_below food days
-- in spring, summer or autumn one Gather/Pick Fruit zone (quickfort zone 'g', named dfllm-gather) of at most
-- gather_cap tiles is drawn around the fort's surface entrance (the fortcore anchor, else the depot + 2 z), on the
-- one or two levels around it with the most revealed open or tree tiles; above gather_off food days it is removed
-- again (act.zone_remove, the zones screen's remove). Never whole-map designations.
M.CFG.gather_below, M.CFG.gather_off, M.CFG.gather_cap, M.CFG.gather_side = 30, 120, 800, 28
M.CFG.gather_dz, M.CFG.gather_step = {0, 1, -1, 2}, 3
M.CFG.gather_rects = 60   -- BUG-074: rectangles per level (the zone follows the citizens' walk group; the largest are kept)
local GATHER = 'dfllm-gather'
local OPEN = {['.'] = true, T = true}

local function fort_center(K)
  for _, P in ipairs(S.pd.list) do
    if P.tpl == 'fortcore' then
      local d = doc(K, P.id) or read_bp(K, P.id)
      local a = type(d) == 'table' and d.anchor
      if type(a) == 'table' and int(a[1]) and int(a[2]) and int(a[3]) then return {int(a[1]), int(a[2]), int(a[3])} end
    end
  end
  local dp = K.manifest().depot
  if type(dp) == 'table' and int(dp[1]) and int(dp[2]) and int(dp[3]) then return {int(dp[1]), int(dp[2]), int(dp[3]) + 2} end
end

-- BUG-074 (Run 11 y479: 46 of the GatherPlants jobs of the zone were unreachable, 250-450 stood unclaimed): the zone covers
-- the tiles of the citizens' walk group only. home_group = the group most citizens stand on (census ids, their
-- positions, snapshot.groups); nil when unknown (no citizen read, a fault): the zone is drawn whole, as before.
function Q.home_group(K)
  local cu, pts = K.census.u, {}
  for _, id in ipairs(type(cu) == 'table' and type(cu.ids) == 'table' and cu.ids or {}) do
    if #pts >= 50 then break end
    local u = df.unit.find(id)
    local ok, x, y, z
    if u then ok, x, y, z = pcall(dfhack.units.getPosition, u) end
    if ok and int(x) then pts[#pts + 1] = {x, y, z} end
  end
  if #pts == 0 then return nil end
  local ok, g = K.call('snapshot', 'groups', pts, false)
  if not ok or type(g) ~= 'table' then return nil end
  local cnt, best = {}, nil
  for i = 1, #pts do
    local v = int(g[i])
    if v and v > 0 then
      cnt[v] = (cnt[v] or 0) + 1
      if not best or cnt[v] > cnt[best] or (cnt[v] == cnt[best] and v < best) then best = v end
    end
  end
  return best
end

-- the tiles of the square (x0, y0, side) on level z that lie on group g (snapshot.groups, near: a tree trunk answers the
-- group of its neighbours), as rectangles {x, y, w, h}: row runs, equal runs of consecutive rows joined; at most `cap`
-- (the largest) are kept. Returns rects, tiles in them, tiles left out (of the square: not on g, or cut by the cap)
function Q.gather_rects(K, g, x0, y0, side, z, cap)
  local pts = {}
  for y = y0, y0 + side - 1 do for x = x0, x0 + side - 1 do pts[#pts + 1] = {x, y, z} end end
  local ok, gr = K.call('snapshot', 'groups', pts, true)
  if not ok or type(gr) ~= 'table' then return nil end
  local rects, prev = {}, {}
  for r = 0, side - 1 do
    local runs, x = {}, 0
    while x < side do
      if int(gr[r * side + x + 1]) == g then
        local w = 0
        while x + w < side and int(gr[r * side + x + w + 1]) == g do w = w + 1 end
        local key = x .. ':' .. w
        local rc = prev[key]
        if rc then rc[4] = rc[4] + 1 else rc = {x0 + x, y0 + r, w, 1}; rects[#rects + 1] = rc end
        runs[key] = rc
        x = x + w
      else x = x + 1 end
    end
    prev = runs
  end
  table.sort(rects, function(a, b)
    if a[3] * a[4] ~= b[3] * b[4] then return a[3] * a[4] > b[3] * b[4] end
    if a[2] ~= b[2] then return a[2] < b[2] end
    return a[1] < b[1]
  end)
  local keep, tiles = {}, 0
  for i = 1, math.min(#rects, cap) do keep[i] = rects[i]; tiles = tiles + rects[i][3] * rects[i][4] end
  return keep, tiles, side * side - tiles
end

local function gather_zone(K)
  local st = K.view().stock
  local fd = type(st) == 'table' and int(st.food_d) or nil
  if not fd then return end
  local g = S.rt.gather
  -- BUG-074: a zone an older kernel drew (no v) covers its whole square, unreachable plants included: while food is still
  -- short it is removed once and drawn again on the citizens' walk group (when that group is known)
  if type(g) == 'table' and g.v ~= 2 and type(g.z) == 'table' and #g.z > 0 and fd < M.CFG.gather_below
     and (K.now().season or 0) < 3 and Q.home_group(K) then
    local ok, n = K.act.zone_remove(GATHER)
    K.log('info', 'gather zone of an older kernel (the whole square) removed, %s zones: drawn again on the citizens\' walk group',
          ok and tostring(n) or 'failed')
    S.rt.gather, g = nil, nil
    dirty()
  end
  if type(g) == 'table' then
    if fd > M.CFG.gather_off then
      local ok, n = K.act.zone_remove(GATHER)
      S.rt.gather = nil
      dirty()
      K.log('info', 'gather zone removed (food %d days, %s zones)', fd, ok and tostring(n) or 'failed')
    end
    return
  end
  if fd >= M.CFG.gather_below or (K.now().season or 0) >= 3 then return end
  local c = S.rt.gc or fort_center(K)
  if not c then return end
  S.rt.gc = c
  local half, step = M.CFG.gather_side // 2, M.CFG.gather_step
  local home = Q.home_group(K)                -- BUG-074: nil = unknown, the zone is drawn whole
  local lv = {}
  for _, dz in ipairs(M.CFG.gather_dz) do
    local z, n, pts = c[3] + dz, 0, {}
    for x = c[1] - half, c[1] + half, step do
      for y = c[2] - half, c[2] + half, step do
        local ok, v = K.call('snapshot', 'tile', x, y, z)
        S.slice.probes = S.slice.probes + 1
        if ok and type(v) == 'table' and OPEN[v.c] then pts[#pts + 1] = {x, y, z} end
      end
    end
    n = #pts
    if home and n > 0 then                    -- only the open tiles on the citizens' walk group count
      local okg, gr = K.call('snapshot', 'groups', pts, true)
      n = 0
      for i = 1, #pts do if okg and type(gr) == 'table' and int(gr[i]) == home then n = n + 1 end end
    end
    lv[#lv + 1] = {z = z, n = n}
  end
  table.sort(lv, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.z > b.z end)
  if lv[1].n == 0 then
    S.rt.gather = {z = {}, t = now(K)}   -- nothing open is revealed there: no retry until food recovers
    dirty()
    K.log('warn', 'gather zone: no revealed open tile %saround %d,%d,%d', home and 'on the citizens\' walk group ' or '',
          c[1], c[2], c[3])
    return
  end
  local levels = {lv[1].z}
  if lv[2] and lv[2].n * 3 >= lv[1].n then levels[2] = lv[2].z end
  local side = math.min(M.CFG.gather_side, math.floor(math.sqrt(M.CFG.gather_cap / #levels)))
  local x0, y0 = c[1] - side // 2, c[2] - side // 2
  if not on_map(x0, y0, levels[1]) then x0, y0 = math.max(1, x0), math.max(1, y0) end
  local made, drawn, out, nrect, whole = {}, 0, 0, 0, false
  for _, z in ipairs(levels) do
    local rects, tiles, left
    if home then rects, tiles, left = Q.gather_rects(K, home, x0, y0, side, z, M.CFG.gather_rects) end
    local cells
    if rects == nil then                      -- the walk group is unknown (or its read failed): the whole square, as before
      cells, tiles, left, whole = {[0] = {[0] = string.format('g{name=%s}(%dx%d)', GATHER, side, side)}}, side * side, 0, true
      nrect = nrect + 1
    elseif #rects > 0 then
      cells = {}
      for _, r in ipairs(rects) do
        local row = cells[r[2] - y0] or {}
        cells[r[2] - y0] = row
        row[r[1] - x0] = string.format('g{name=%s}(%dx%d)', GATHER, r[3], r[4])
      end
      nrect = nrect + #rects
    else out = out + left end                 -- nothing of this level lies on the group
    if cells and qf(K, {mode = 'zone', data = {[0] = cells}, pos = {x0, y0, z}}) then
      made[#made + 1] = z
      drawn, out = drawn + tiles, out + left
    end
  end
  S.rt.gather = {v = 2, z = made, x = x0, y = y0, side = side, t = now(K), g = home, n = drawn, out = out}
  dirty()
  if home and not whole then
    K.log('warn', 'food %d days: gather zone at %d,%d on z %s: %d tiles in %d rects on the citizens\' walk group %d, ' ..
          '%d tiles of the %dx%d square left out (not on that group, or past the %d-rect cap)', fd, x0, y0,
          table.concat(made, ','), drawn, nrect, home, out, side, side, M.CFG.gather_rects)
  else
    K.log('warn', 'food %d days: gather zone %dx%d at %d,%d on z %s (%d tiles; the citizens\' walk group is unknown, ' ..
          'nothing left out)', fd, side, side, x0, y0, table.concat(made, ','), side * side * #made)
  end
end

---------------------------------------------------------------- depot keeper (FR-43)
-- Run 9: a goblin siege razed the surface depot and two caravans came and left within a minute without trade.
-- In PEACE and RECOVERY (and when trade reports a caravan without a depot) a missing trade depot -- no
-- TRADE_DEPOT building at all, built or planned -- is queued again as a one-stage `depot` project: a 5x5 depot
-- (quickfort build 'D(5x5)', materials by buildingplan) centred on manifest.depot, else on the last depot the
-- runner saw standing (m.runner.depot). One project at a time; returns ok, project id | reason.
M.CFG.depot_prio = 2
local DEPOT_MODES = {PEACE = true, RECOVERY = true}

local function depot_seen()
  local have, c = false, nil
  pcall(function()
    for _, b in ipairs(df.global.world.buildings.other.TRADE_DEPOT) do
      have = true
      if int(b.centerx) and int(b.centery) and int(b.z) then c = {int(b.centerx), int(b.centery), int(b.z)}; break end
    end
  end)
  return have, c
end

-- the one-stage depot project around a centre pos
local function depot_doc(pos)
  local at = {pos[1] - 2, pos[2] - 2, pos[3]}
  return {v = 2, tpl = 'depot', site = 'S1', class = 'infra', params = json.object{}, anchor = at, rot = 0,
          stages = {{label = 'depot.build', mode = 'build', orders = 0, defense = 0,
                     chunks = {{pos = at, cells = {{0, 0, 0, 'D(5x5)'}}}}}},
          manifest = {v = 2, depot = {pos[1], pos[2], pos[3]}}, materials = json.object{trade_depot = 1}}
end

function M.depot_keep(K, why)
  if not DEPOT_MODES[K.mode()] then return false, 'not in ' .. K.mode() end
  local have, c = depot_seen()
  if have then
    local d = S.rt.depot
    if c and (type(d) ~= 'table' or d[1] ~= c[1] or d[2] ~= c[2] or d[3] ~= c[3]) then S.rt.depot = c; dirty(); save(K) end
    return true, 'standing'
  end
  for _, P in ipairs(S.pd.list) do
    if P.tpl == 'depot' and Q.live(K, P) then return true, P.id end   -- BUG-037: a parked one is no depot project
  end
  local m = K.manifest().depot
  local pos = type(m) == 'table' and int(m[1]) and int(m[2]) and int(m[3]) and {int(m[1]), int(m[2]), int(m[3])}
              or (type(S.rt.depot) == 'table' and int(S.rt.depot[1]) and S.rt.depot) or nil
  if not pos then return false, 'no known depot site' end
  local n = (int(S.rt.depot_n) or 0) + 1
  local id = string.format('depot%d', n)
  local ok, err = register(K, id, depot_doc(pos), M.CFG.depot_prio, 'depot')
  if not ok then return false, err end
  S.rt.depot_n = n
  dirty()
  save(K)
  K.log('warn', 'trade depot missing (%s): project %s at %d,%d,%d', tostring(why or 'keeper'), id, pos[1], pos[2], pos[3])
  return true, id
end

-- BUG-005 (Run 9: the depot at the shaft head stayed a construction site and four caravans left): economy's daily
-- jobs pass calls this after depot_move_after resumes of the depot job that did not hold, with a new centre `at`
-- inside the entrance, off the army route (economy picked it: revealed roofed floor, reachable, no items). A depot
-- project still open is cancelled with undo; else the planned depot at `old` = {x1, y1, z} is undone by quickfort
-- like the building sheet's cancel. Then a depot project is queued at `at`. Returns ok, project id | reason.
function M.depot_move(K, at, why, old)
  if not DEPOT_MODES[K.mode()] then return false, 'not in ' .. K.mode() end
  local x, y, z
  if type(at) == 'table' then x, y, z = int(at[1]), int(at[2]), int(at[3]) end
  if not (x and y and z) or not on_map(x - 2, y - 2, z) or not on_map(x + 2, y + 2, z) then return false, 'bad site' end
  local cancelled = 0
  for _, P in ipairs(S.pd.list) do
    if P.tpl == 'depot' and P.done ~= 1 and P.blocked ~= 'cancel' then
      cancel(K, P, true)
      cancelled = cancelled + 1
    end
  end
  if cancelled == 0 and type(old) == 'table' and int(old[1]) and int(old[2]) and int(old[3]) then
    K.act.quickfort({mode = 'build', data = {[0] = {[0] = {[0] = 'D(5x5)'}}}, pos = {int(old[1]), int(old[2]), int(old[3])},
                     command = 'undo'})
  end
  local n = (int(S.rt.depot_n) or 0) + 1
  local id = string.format('depot%d', n)
  local ok, err = register(K, id, depot_doc({x, y, z}), M.CFG.depot_prio, 'depot')
  if not ok then return false, err end
  S.rt.depot_n, S.rt.depot = n, {x, y, z}
  dirty()
  rows(K)
  save(K)
  K.log('warn', 'trade depot moved (%s): project %s at %d,%d,%d', trunc(why, 120), id, x, y, z)
  return true, id
end

local function keepers(K)
  local t = now(K)
  if K.mode() ~= 'PEACE' or (S.rt.kt and t - S.rt.kt < M.CFG.keep_every) then return end
  S.rt.kt = t
  dirty()
  gather_zone(K)
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

---------------------------------------------------------------- the manifest follows what stands (BUG-066, FR-76)
-- Workshops and furnaces that stand, from the game's building vectors: {t = type name, x1, y1, x2, y2, z, b = built}.
-- nil when a vector cannot be read (nothing is then pruned: a failed read says nothing about what stands).
function Q.stand()
  local out = {}
  local oth = df.global.world.buildings.other
  for _, spec in ipairs({{'WORKSHOP_ANY', 'workshop_type'}, {'FURNACE_ANY', 'furnace_type'}}) do
    local vec, enum = oth[spec[1]], df[spec[2]]
    if vec == nil or enum == nil then return nil end
    for _, b in ipairs(vec) do
      local name = enum[b.type]
      local x1, y1, x2, y2, z = int(b.x1), int(b.y1), int(b.x2), int(b.y2), int(b.z)
      if type(name) == 'string' and name ~= 'Custom' and x1 and y1 and x2 and y2 and z then
        local okb, done = pcall(built, b)
        out[#out + 1] = {t = name, x1 = x1, y1 = y1, x2 = x2, y2 = y2, z = z, b = not okb or done == true}
      end
    end
  end
  return out
end

function Q.covers(b, name, pos)
  return b.t == name and b.z == pos[3] and pos[1] >= b.x1 and pos[1] <= b.x2 and pos[2] >= b.y1 and pos[2] <= b.y2
end

function Q.pos3(p)
  if type(p) ~= 'table' then return nil end
  local x, y, z = int(p[1]), int(p[2]), int(p[3])
  return x and y and z and {x, y, z} or nil
end

-- manifest.gone entries a (re)built workshop of `frag` ({{type, pos}}) cancels
function Q.ungone(gone, frag)
  local out = {}
  for _, g in ipairs(gone) do
    local hit = false
    for _, w in ipairs(frag) do
      local a, b = Q.pos3(g.pos), Q.pos3(w.pos)
      if type(w) == 'table' and w.type == g.type and a and b and a[1] == b[1] and a[2] == b[2] and a[3] == b[3] then
        hit = true
      end
    end
    if not hit then out[#out + 1] = g end
  end
  return out
end

-- once a game day: prune the manifest's workshops that no longer stand, adopt the standing built ones it lacks, count
-- what stands (rt.ad: the state's `adopt`), and ask for the mandatory workshops a reclaimed fort lacks
function Q.sync(K, t)
  local rc = conf(K).rec
  if not rc.on or (S.rt.wsy and t - S.rt.wsy < DAY) then return end
  S.rt.wsy = t
  dirty()
  local oks, stand = pcall(Q.stand)
  if not oks or type(stand) ~= 'table' then return end
  local man = K.manifest()
  local list, keep, changed = type(man.workshops) == 'table' and man.workshops or {}, {}, false
  S.rt.wm = type(S.rt.wm) == 'table' and S.rt.wm or obj{}
  local gone = type(man.gone) == 'table' and man.gone or {}
  local pruned, added, nbuilt, have = 0, 0, 0, {}
  for _, b in ipairs(stand) do
    have[b.t] = true
    if b.b then nbuilt = nbuilt + 1 end
  end
  for _, w in ipairs(list) do
    local p = type(w) == 'table' and Q.pos3(w.pos)
    local key = p and (tostring(w.type) .. '@' .. table.concat(p, ','))
    local here = false
    if p then
      for _, b in ipairs(stand) do if Q.covers(b, w.type, p) then here = true; break end end
    end
    if not p or here then
      keep[#keep + 1] = w
      if key then S.rt.wm[key] = nil end
    else
      local n = (int(S.rt.wm[key]) or 0) + 1
      if n >= rc.scans then
        S.rt.wm[key] = nil
        pruned, changed = pruned + 1, true
        gone[#gone + 1] = {type = tostring(w.type), pos = p, w = K.now().wall}
        K.log('warn', 'manifest: workshop %s at %d,%d,%d no longer stands (%d scans): out of the manifest', tostring(w.type),
              p[1], p[2], p[3], n)
      else
        S.rt.wm[key] = n
        keep[#keep + 1] = w
      end
    end
  end
  for _, b in ipairs(stand) do
    if b.b then
      local known = false
      for _, w in ipairs(keep) do
        local p = type(w) == 'table' and Q.pos3(w.pos)
        if p and Q.covers(b, w.type, p) then known = true; break end
      end
      if not known and #keep < 100 then
        keep[#keep + 1] = {type = b.t, pos = {(b.x1 + b.x2) // 2, (b.y1 + b.y2) // 2, b.z}}
        added, changed = added + 1, true
      end
    end
  end
  if added > 0 or pruned > 0 then
    local g2 = {}
    for _, g in ipairs(gone) do                   -- a workshop that stands again is no longer gone
      local back = false
      for _, w in ipairs(keep) do
        local a, c2 = Q.pos3(g.pos), Q.pos3(w.pos)
        if w.type == g.type and a and c2 and a[1] == c2[1] and a[2] == c2[2] and a[3] == c2[3] then back = true end
      end
      if not back then g2[#g2 + 1] = g end
    end
    while #g2 > 50 do table.remove(g2, 1) end
    man.workshops, man.gone = keep, g2
    K.persist.set('manifest', man)
    if added > 0 then K.log('info', 'manifest: %d standing workshop%s adopted (%d in all)', added, added == 1 and '' or 's', #keep) end
  end
  -- the adoption record and the fort's other standing rooms (counts only; the vectors are not walked)
  local ad = S.rt.ad
  if type(ad) ~= 'table' then
    ad = {t = t, new = 0, gone = 0, rec = added >= rc.min and 1 or 0}
    S.rt.ad = ad
    if ad.rec == 1 then
      K.log('warn', 'reclaimed fort: %d standing workshops adopted into the manifest at the first scan', added)
    end
  end
  ad.ws, ad.new, ad.gone = nbuilt, (int(ad.new) or 0) + added, (int(ad.gone) or 0) + pruned
  local oth = df.global.world.buildings.other
  for _, k in ipairs({{'stock', 'STOCKPILE'}, {'wells', 'WELL'}, {'beds', 'BED'}, {'doors', 'DOOR'}}) do
    local okn, n = pcall(function() return #oth[k[2]] end)
    ad[k[1]] = okn and int(n) or nil
  end
  local miss = {}
  for _, name in ipairs(Q.MANDATORY) do if not have[name] then miss[#miss + 1] = name end end
  ad.miss = miss
  if ad.rec == 1 and #miss > 0 then
    S.rt.wmiss = int(S.rt.wmiss) or t
    if K.mode() == 'PEACE' and t - S.rt.wmiss >= rc.ask and M.pending(K, 'workshops') == 0
       and (not S.rt.req.wsm or t - S.rt.req.wsm >= M.CFG.req_cool) then
      S.rt.req.wsm = t
      local names = table.concat(miss, ', ')
      K.log('warn', 'reclaimed fort without %s: workshops project requested (dfllm bp sites workshops; the fort cannot ' ..
            'make coffins, crafts or meals without them)', names)
      K.emit('PROJECT_REQUEST', 'B', trunc('workshops x' .. #miss .. ': mandatory ' .. names .. ' missing', 200),
             {tpl = 'workshops', n = #miss, why = 'mandatory', types = miss})
    end
  else
    S.rt.wmiss = nil
  end
  dirty()
end
Q.MANDATORY = {'Carpenters', 'Masons', 'Craftsdwarfs', 'Still', 'Kitchen'}

---------------------------------------------------------------- build_lost: missing pieces and the retry (BUG-022)

-- the name of a piece: the manifest bridge whose footprint holds the cell (B1), a bridge's lever ('lever B1'),
-- 'trap' for a trap key, else the key
local function piece_name(d, t, key)
  local br = type(d.manifest) == 'table' and type(d.manifest.bridges) == 'table' and d.manifest.bridges or {}
  local names = {}
  for n in pairs(br) do names[#names + 1] = n end
  table.sort(names)
  for _, n in ipairs(names) do
    local b = br[n]
    local fp = type(b) == 'table' and b.fp
    if type(fp) == 'table' and #fp == 6 and geom.in_bbox(t, fp) then return n end
    for _, l in ipairs(type(b) == 'table' and type(b.levers) == 'table' and b.levers or {}) do
      if l[1] == t[1] and l[2] == t[2] and l[3] == t[3] then return 'lever ' .. n end
    end
  end
  if key:sub(1, 1) == 'T' and key ~= 'Tl' then return 'trap' end
  if key == 'Tl' then return 'lever' end
  return key
end

-- the pieces of the blocked build stage still missing: {'B1', 'lever B1 x2', 'trap x3'} (<= 8, first-seen order) and
-- the number of missing cells that stand on open floor now (the retry signature)
local function missing_pieces(K, P, d)
  local st = d and d.stages[P.stage + 1]
  if not (st and st.mode == 'build') then return {}, 0 end
  local order, cnt, open = {}, {}, 0
  for _, ch in ipairs(st.chunks) do
    for _, cell in ipairs(ch.cells) do
      local tl = {}
      cell_tiles(ch, cell, tl)
      local key = tl[1] and tl[1][4] or ''
      local cons = key:sub(1, 1) == 'C'
      local miss, floor = false, false
      for i, t in ipairs(tl) do
        if i > 1 and not cons then break end                  -- a building occupies its cell's first tile
        local here, tile = cell_present(K, t)
        if not here then
          miss = true
          if tile and tile.c == '.' then floor = true end
        end
      end
      if miss then
        local n = piece_name(d, tl[1], key)
        if not cnt[n] then cnt[n] = 0; order[#order + 1] = n end
        cnt[n] = cnt[n] + 1
        if floor then open = open + 1 end
      end
    end
  end
  local out = {}
  for i, n in ipairs(order) do
    if i > 8 then break end
    out[#out + 1] = trunc(cnt[n] > 1 and (n .. ' x' .. cnt[n]) or n, 60)
  end
  return out, open
end

-- how far the map came since the block: the kept hidden tiles of the project now revealed (snapshot.tile answers
-- revealed tiles only; at most retry_probe asked) plus the missing cells now on open floor
local function retry_sig(K, P, d)
  local n, asked = 0, 0
  local r = S.rt.skip[P.id]
  for _, l in pairs(type(r) == 'table' and type(r.c) == 'table' and r.c or {}) do
    for _, t in ipairs(type(l) == 'table' and l or {}) do
      if asked >= M.CFG.retry_probe then break end
      asked = asked + 1
      local ok, v = K.call('snapshot', 'tile', t[1], t[2], t[3])
      if ok and type(v) == 'table' and v.c ~= nil and v.c ~= '?' then n = n + 1 end
    end
  end
  local _, open = missing_pieces(K, P, d)
  return n + open
end

-- Run 11 (Kilrudrabed y432): `seal at=last` ended build_lost (missing d) while ConstructDoor was cancelled for rock and
-- logs could have made the door. The lost pieces of a seal stage are asked of economy.mat_for: can = one of them can be
-- made now (a free item, rock, wood, a building material buildingplan takes), why = economy's reason for the first
-- that cannot ('no material for door: no rock, no logs'); measure_build places them again (remake_max), PROJECT_BLOCKED
-- names the reason, a build_lost seal is retried once they can be made
local KEY_PIECE = {d = 'door', H = 'hatch', Cw = 'wall', W = 'grate', G = 'grate'}
function M.remake_why(K, P, d)
  if P.tpl ~= 'seal' then return false end
  local can, why = false, nil
  for _, s in ipairs((missing_pieces(K, P, d))) do
    local kind = KEY_PIECE[s:match('^(%S+)') or '']
    if kind then
      local ok, via, w = K.call('economy', 'mat_for', kind, int(s:match(' x(%d+)$')) or 1)
      if ok and via then can = true elseif ok and not why then why = w end
    end
  end
  return can, why
end

function M.remake(K, P, d, R)
  if P.tpl ~= 'seal' or (int(R.rm) or 0) >= M.CFG.remake_max then return false end   -- BUG-033: before the cell reads
  local can, why = M.remake_why(K, P, d)
  if not can then return false end
  R.rm = (int(R.rm) or 0) + 1
  K.log('info', '%s %s: lost pieces placed again (%d/%d): economy can make them%s', P.id, d.stages[P.stage + 1].label,
        R.rm, M.CFG.remake_max, why and ('; ' .. why) or '')
  return true
end

-- Run 11 (c1a147087d, build_lost before the door_walls fix): 'x,y,z' of a missing door of a blocked seal stage that the
-- revealed tiles show without a wall or fortification beside it (door_unsupported), else nil: the retry lets quickfort
-- refuse it once more, and door_walls plans it as a wall
local function lost_door(K, P, d)
  local st = P.tpl == 'seal' and d and d.stages[P.stage + 1]
  if not (st and st.mode == 'build') then return nil end
  for _, ch in ipairs(st.chunks) do
    for _, c in ipairs(ch.cells) do
      local x, y, z = ch.pos[1] + c[1], ch.pos[2] + c[2], ch.pos[3] + c[3]
      if c[4]:match('^[^{(:/]*') == 'd' and not cell_present(K, {x, y, z}) and door_unsupported(K, x, y, z) ~= '' then
        return tkey(x, y, z)
      end
    end
  end
end

-- the stage to start a retry from: the last dig stage at or before the blocked stage (its skipped tiles may be
-- designated now), else the blocked stage itself
local function retry_from(d, si)
  for i = si, 0, -1 do
    if d.stages[i + 1] and d.stages[i + 1].mode == 'dig' then return i end
  end
  return si
end

-- BUG-022 (the live workaround, done by the runner: cancel + re-plan stage 2 at site=same): a build_lost project
-- runs again from its dig stage once the map came further (retry_sig grew) or retry_every passed, retry_max times
local function retry_step(K, P, t)
  local q = S.rt.rty[P.id]
  if type(q) ~= 'table' then
    q = {n = 0, t = P.since, c = P.since}
    S.rt.rty[P.id] = q
  end
  q.n = int(q.n) or 0
  if q.n >= M.CFG.retry_max then return end
  local d = doc(K, P.id)
  if not d then return end
  local why
  if q.sig == nil then                          -- the baseline, taken in the run that blocked it
    q.sig, q.c = retry_sig(K, P, d), t
    q.cant = P.tpl == 'seal' and not M.remake_why(K, P, d)      -- Run 11: blocked for want of material
    dirty()
  end
  if t - (int(q.t) or t) >= M.CFG.retry_every then why = 'a season passed'
  elseif t - (int(q.c) or 0) >= M.CFG.retry_check then
    q.c = t
    local sig = retry_sig(K, P, d)
    if sig > q.sig then why = string.format('%d more tiles revealed or open', sig - q.sig)
    -- (a seal blocked by an older kernel has no record of it: tried as soon as its pieces can be made)
    elseif P.tpl == 'seal' and q.cant ~= false and M.remake_why(K, P, d) then why = 'its pieces can be made now'
    -- Run 11: a door quickfort refused under an older kernel (no wall beside it): once, so door_walls walls it
    elseif P.tpl == 'seal' and q.dw ~= 1 then
      local at = lost_door(K, P, d)
      if at then q.dw, why = 1, 'its door at ' .. at .. ' has no wall or fortification beside it: a wall if quickfort ' ..
                                'refuses the door' end
    end
    dirty()
  end
  if not why then return end
  local from = retry_from(d, P.stage)
  local blocked = d.stages[P.stage + 1] and d.stages[P.stage + 1].label or '?'
  q.n, q.t, q.c, q.sig, q.cant = q.n + 1, t, t, nil, nil
  P.stage, P.chunk, P.orders_done = from, 0, 0
  set_blocked(K, P, '')
  P.pct = pct_of(P, d, 0)
  S.rt.p[P.id] = new_R(t, from)
  S.meas[P.id] = nil
  S.rt.skip[P.id] = nil                       -- the dig stage keeps the tiles it skips this time
  K.log('info', '%s: build_lost at %s, retry %d/%d from %s (%s)', P.id, blocked, q.n, M.CFG.retry_max,
        d.stages[from + 1].label, why)
  dirty()
end

-- BUG-046: the parts of a stalled build stage that wait, with what each waits for (economy.build_state): at most 3 as
-- 'MetalsmithsForge 72,61,129: job 22236 suspended by buildingplan: waits for building material x1' (the cells of the
-- current stage not built yet; a part economy does not answer for is left out). {} for another stage or project.
function Q.parts(K, P, d)
  local st = d and d.stages[P.stage + 1]
  local out = {}
  if not (st and st.mode == 'build') then return out end
  local looked = 0
  for _, ch in ipairs(st.chunks) do
    for _, cell in ipairs(ch.cells) do
      local tl = {}
      cell_tiles(ch, cell, tl)
      local t = tl[1]
      if t and #out < 3 and looked < 16 and not piece_built(K, t) then
        looked = looked + 1
        local ok, bs = K.call('economy', 'build_state', t[1], t[2], t[3])
        if ok and type(bs) == 'table' and type(bs.line) == 'string' then
          out[#out + 1] = trunc(string.format('%s %d,%d,%d: %s', bs.sub or bs.kind or PIECE_NAME[t[4]] or t[4], t[1], t[2],
                                              t[3], bs.line), 120)
        end
      end
    end
  end
  return out
end

-- PROJECT_BLOCKED (A) after blocked_a; util/cadence per project: once per stage and cause (a stall that clears and
-- comes back at the same stage is no news; Run 10: "PROJECT_BLOCKED stalled every few days" for two game years);
-- build_lost names the missing pieces and the retry, and a spent retry budget is one more (final) announcement
local function blocked_event(K, P, t)
  local d = doc(K, P.id)
  local st = d and d.stages[P.stage + 1]
  local label = trunc(st and st.label or '', 24)
  local q = S.rt.rty[P.id]
  local nr = type(q) == 'table' and int(q.n) or 0
  local final = P.blocked == 'build_lost' and nr >= M.CFG.retry_max
  local T = K.now()
  local ids, toks = {P.id .. ':' .. label}, {final and 'build_lost:final' or P.blocked}
  local rec = S.rt.pb[P.id]
  if not CAD.due(rec, T, ids, toks) then return end
  S.rt.pb[P.id] = CAD.mark(T, ids, toks)
  local msg = P.id .. ' (' .. P.tpl .. ') blocked: ' .. P.blocked
  local dd = {proj = P.id, tpl = P.tpl, stage = label, why = P.blocked, ticks = t - P.since}
  local wn, wl = walled_note(P.id)            -- Run 11: seal doors quickfort refused, planned as walls (door_walls)
  dd.walled = wl
  if P.blocked == 'build_lost' then
    local miss = missing_pieces(K, P, d)
    dd.missing, dd.retry = miss, nr
    msg = msg .. ' at ' .. label .. (#miss > 0 and (', missing ' .. table.concat(miss, ', ')) or '')
    local _, mw = M.remake_why(K, P, d)      -- Run 11: why economy cannot make a seal's pieces
    if mw then msg, dd.mat = msg .. ' (' .. mw .. ')', trunc(mw, 80) end
    if wn then msg = msg .. '; ' .. wn end
    if final then msg = msg .. string.format('; %d retries spent: bp.cancel and place it again', nr)
    else
      msg = msg .. string.format('; retry %d/%d once the skipped tiles are revealed, at the latest next season',
                                 nr + 1, M.CFG.retry_max)
    end
  elseif wn then msg = msg .. ' at ' .. label .. '; ' .. wn end
  if P.blocked == 'stalled' then                -- BUG-046: which part waits (the rest of the stage is not frozen by it)
    local parts = Q.parts(K, P, d)
    if #parts > 0 then
      dd.parts = trunc(table.concat(parts, '; '), 200)
      msg = msg .. (wn and '' or (' at ' .. label)) .. '; waits: ' .. table.concat(parts, '; ')
    end
  end
  K.emit('PROJECT_BLOCKED', 'A', trunc(msg, 200), dd)
  dirty()
end

-- BUG-037: a parked project (blocked for good past park_days) is announced once (PROJECT_BLOCKED d.park, util/cadence
-- per project, m.runner park) with the command that cancels it. The kernel never cancels it itself: an undo would
-- remove what it built, and an explore stays in the audit box and its shaft in the shaft check either way.
function Q.park_event(K, P, t)
  local d = doc(K, P.id)
  local st = d and d.stages[P.stage + 1]
  local label = trunc(st and st.label or '', 24)
  local T = K.now()
  local ids, toks = {P.id .. ':' .. label}, {'parked'}
  if not CAD.due(S.rt.park[P.id], T, ids, toks) then return end
  S.rt.park[P.id] = CAD.mark(T, ids, toks)
  local days = (t - P.since) // DAY
  local keep = P.tpl == 'explore' and 'its shaft stays watched' or P.blocked == 'build_lost' and 'what it built stays'
               or 'nothing is undone'
  local msg = string.format('%s (%s) blocked %d d: %s at %s; parked; cancel: dfllm cmd bp.cancel \'{"proj":"%s"}\' '
                            .. '(no undo: %s)', P.id, P.tpl, days, P.blocked, label, P.id, keep)
  K.log('warn', '%s', msg)
  K.emit('PROJECT_BLOCKED', 'A', trunc(msg, 200),
         {proj = P.id, tpl = P.tpl, stage = label, why = P.blocked, ticks = t - P.since, park = days})
  dirty()
end

---------------------------------------------------------------- runs
local function end_run(K)
  local t = now(K)
  local pt = conf(K).park
  if K.mode() == 'PEACE' then
    for _, P in ipairs(S.pd.list) do
      if P.done ~= 1 and P.blocked == 'build_lost' then retry_step(K, P, t) end
      if Q.parked(K, P, pt) then Q.park_event(K, P, t)
      elseif P.done ~= 1 and P.blocked ~= '' and P.blocked ~= 'cancel' and t - P.since > M.CFG.blocked_a then
        blocked_event(K, P, t)
      end
    end
  end
  for id, r in pairs(S.rt.park) do              -- a park record whose project left (or runs again): quiet
    local P = find(id)
    if not P or P.done == 1 then S.rt.park[id] = nil; dirty()
    elseif type(r) == 'table' and #(r.ids or {}) > 0 and not Q.parked(K, P, pt) then S.rt.park[id] = CAD.quiet(r); dirty() end
  end
  plug_watch(K)                              -- Run 11: the plug's wall (every mode); the check ran as its own task
  local oks, err = pcall(Q.sync, K, t)       -- BUG-066 / FR-76: a fault here must not stop the run
  if not oks then K.log('error', 'manifest sync failed: %s', trunc(err, 160)) end
  phases(K)
  if K.mode() == 'PEACE' then exhausted(K) end
  if DEPOT_MODES[K.mode()] then M.depot_keep(K, 'keeper') end
  keepers(K)
  prune(M.CFG.done_keep)
  rows(K)
end

-- BUG-075 (DECISIONS 11): a fault inside the seal-first count is an event, not only a log line. KERN_FAULT (A, module
-- runner, backoff_s 0: the module is not backed off, this run goes on without seal first and the rebuild policy), once
-- per distinct message (util/cadence: a message announced in this episode is never repeated; a new one waits 7 days and
-- 10 min after the last announcement; a run that counts again ends the episode). S.fc = runs that faulted in a row
function Q.fault(K, err)
  S.fc = (S.fc or 0) + 1
  err = err:gsub('^.*[/\\]([%w_]+%.lua:)', '%1')      -- the file name, not the install path
  local T, rec = K.now(), S.fev
  if not CAD.due(rec, T, {}, {err}) then return end
  local toks = {}
  for _, v in ipairs(type(rec) == 'table' and type(rec.toks) == 'table' and rec.toks or {}) do toks[#toks + 1] = v end
  toks[#toks + 1] = err
  while #toks > 8 do table.remove(toks, 1) end
  S.fev = CAD.mark(T, {}, toks)
  K.emit('KERN_FAULT', 'A', trunc('runner: seal first/rebuild failed, this run goes on without them: ' .. err, 200),
         {module = 'runner', err = err, n = S.fc, backoff_s = 0})
end

local function begin_run(K)
  sync_plan(K)
  S.snap_ok = K.enabled('snapshot')
  S.active = {}
  -- Run 11 siege 8: seal first and the rebuild policy. BUG-037: a fault in them must not stop every project (a begin_run
  -- that dies here leaves every row 'queued' and applies nothing): this run goes on without them, kern.log names it
  local okf, f = pcall(focus, K)
  if not okf then
    local err = trunc(f, 160)
    if S.ferr ~= err then S.ferr = err; K.log('error', 'seal first/rebuild failed, this run without them: %s', err) end
    Q.fault(K, err)
    f = {c = conf(K), n = 0, more = 0, stuck = {}, stk = {}}
    S.care_id = nil                           -- BUG-116: no care lead without a focus
  else S.ferr, S.fc, S.fev = nil, nil, CAD.quiet(S.fev) end
  S.focus = f
  -- BUG-045: the civil alert confines the miners to its burrow in every mode: a dig project with applied chunks is frozen
  -- for as long as it is on (Q.froze), whatever the mode lets it do
  local okc, civ = pcall(function() return df.global.plotinfo.alerts.civ_alert_idx end)
  S.civ = okc and (int(civ) or 0) ~= 0
  if S.civ then
    for _, P in ipairs(sorted()) do
      local d0 = doc(K, P.id)
      if d0 then Q.froze(K, P, d0, R_of(K, P)) end
    end
  end
  if okf then                                 -- BUG-044: own pcall, a fault costs only this fallback
    local okw, err = pcall(Q.stuck_walls, K, f.c)
    if not okw then
      err = trunc(err, 160)
      if S.werr ~= err then S.werr = err; K.log('error', 'seal wall fallback failed: %s', err) end
    else S.werr = nil end
  end
  local tasks, n, t, c = {}, 0, now(K), f.c
  local list = sorted()
  for _, P in ipairs(list) do
    local R = S.rt.p[P.id]
    if (type(R) == 'table' and R.undo) or P.blocked == 'cancel' then tasks[#tasks + 1] = {k = 'undo', id = P.id} end
  end
  -- pass 1: projects that can progress (and every open seal or plug that is not stuck, stalled or not: seal first);
  -- pass 2 (the slots left over, else up to meas_extra measure-only passes when due): stalled ones (waiting for
  -- materials or workers), a stuck seal, and (BUG-037) a project whose own progress (R.ps) is c.yield old: its slot goes
  -- to a waiting project. A paused project waits like a frozen one (no chunk, no stall); waiting for a slot is no
  -- idleness (R.ps), holding one is
  local function second(P, R)
    if SEALS[P.tpl] and c.on and not f.stk[P.id] then return false end
    if S.care_id == P.id and P.blocked ~= 'stalled' then return false end         -- BUG-116: the hospital never yields
    if P.blocked == 'stalled' or (SEALS[P.tpl] and f.stk[P.id]) then return true end
    return type(R) == 'table' and R.si == P.stage and t - (int(R.ps) or t) >= c.yield
  end
  local extra, pz, held, slots, yielded, waiting = 0, {}, 0, {}, {}, 0
  for pass = 1, 2 do
    for _, P in ipairs(list) do
      local R0 = S.rt.p[P.id]
      if type(R0) == 'table' and R0.ps == nil then R0.ps = t; dirty() end      -- a project of an older kernel
      local p2 = not halted(P) and second(P, R0)
      if not halted(P) and p2 == (pass == 2) then
        local d = doc(K, P.id)
        local ok = allowed(K, P, d)
        local why = ok and paused(K, P, d) or nil
        if why then
          ok = false
          pz[#pz + 1] = {P = P, why = why}
          local st = d and d.stages[P.stage + 1]
          if st and st.mode == 'dig' and P.chunk > 0 and held < M.CFG.hold_n then   -- its designations are dug on
            held = held + 1
            tasks[#tasks + 1] = {k = 'work', id = P.id, hold = true}
          end
        end
        if ok and n < M.CFG.active then
          n = n + 1
          S.active[P.id] = true
          slots[#slots + 1] = P.id
          tasks[#tasks + 1] = {k = 'work', id = P.id}
        else
          local R = R_of(K, P)
          if not ok and not why then Q.froze(K, P, d, R) end        -- BUG-045: the mode froze it (an alert)
          if ok and pass == 2 and extra < M.CFG.meas_extra and (R.mt == nil or t - R.mt >= M.CFG.meas_every) then
            extra, R.mt = extra + 1, t
            tasks[#tasks + 1] = {k = 'work', id = P.id, meas = true}
          end
          if ok and pass == 1 then waiting = waiting + 1 end
          if ok and p2 and P.blocked ~= 'stalled' and not SEALS[P.tpl] then yielded[P.id] = (t - int(R.ps)) // DAY end
          R.last = t                         -- waiting (queued, frozen or paused) is no stall
          if pass == 1 then R.ps = t end     -- BUG-037: nor is it idleness
          dirty()
        end
      end
    end
  end
  note_pause(K, pz)
  S.sched = sched_state(S.focus, pz)
  -- BUG-037: who holds the slots while others wait (state sched.q, the rows 'queued behind <id>'; the idle days of each)
  S.slots, S.yielded, S.q = slots, yielded, nil
  if waiting > 0 then
    local by = {}
    for _, id in ipairs(slots) do
      local P, R = find(id), S.rt.p[id]
      by[#by + 1] = {id, trunc(P and P.tpl or '?', 16), type(R) == 'table' and math.max(0, (t - (int(R.ps) or t)) // DAY) or 0}
    end
    S.q = {n = waiting, by = by}
  end
  tasks[#tasks + 1] = {k = 'check'}           -- Run 11 cavern stops and shafts (BUG-033: sliced)
  tasks[#tasks + 1] = {k = 'end'}
  S.run, S.chk = {tasks = tasks, i = 1, t = t, sl = 0, ty = 0}, nil
end

---------------------------------------------------------------- module interface
function M.init(K)
  S = {tiles = {}, bbox = {}, meas = {}, absent = {}, rows = {}, active = nil, slice = {qf = 0, probes = 0, qf_max = 1},
       boot = K.now().tick}
  local pd = K.persist.get('projects')
  if type(pd) ~= 'table' or type(pd.list) ~= 'table' then pd = {v = 2, list = {}}; K.persist.set('projects', pd) end
  S.pd = pd
  local rt = K.persist.get('m.runner')
  if type(rt) ~= 'table' then rt = {} end
  M.CFG.damp_dig = rt.damp_dig == true
  rt.v, rt.p, rt.hist, rt.planned, rt.req, rt.keep = 2, obj(rt.p), obj(rt.hist), obj(rt.planned), obj(rt.req),
    obj(rt.keep)
  rt.skip, rt.rty, rt.pb = obj(rt.skip), obj(rt.rty), obj(rt.pb)   -- BUG-022: skipped tiles, retries, cadence
  rt.cav, rt.br, rt.xs = obj(rt.cav), obj(rt.br), obj(rt.xs)       -- Run 11: cavern plugs, breach records, shafts
  rt.dw = obj(rt.dw)                                                 -- Run 11: seal doors planned as walls
  rt.sw = obj(rt.sw)                                                 -- BUG-044: stuck seal doors replaced by walls
  rt.so = obj(rt.so)                                                 -- BUG-044: door/hatch order items per seal project
  rt.kk = obj(rt.kk)                                                 -- BUG-043: the template of a kept seal/explore box
  rt.kp = obj(rt.kp)                                                 -- BUG-129: the tile clusters of a kept box
  rt.park = obj(rt.park)                                             -- BUG-037: parked projects announced
  if type(rt.cz) ~= 'table' then rt.cz = {} end                      -- Run 11: cavern breach tiles
  if type(rt.exh) ~= 'string' then rt.exh = '' end
  K.persist.set('m.runner', rt)
  S.rt = rt
  -- cavern breaches recorded before the level list existed (CAVERN_PLUG and BREACH_STOP records, Run 11)
  local man_cav = type(K.manifest().caverns) == 'table' and #K.manifest().caverns or 0
  for _, tbl in ipairs({rt.cav, rt.br}) do
    local ids = {}
    for id in pairs(tbl) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
      local r = tbl[id]
      if type(r) == 'table' and CAVERN[r.why] and type(r.pos) == 'table' then note_cavern(K, r.pos, r.why) end
    end
  end
  if #rt.cz > 0 and man_cav ~= #rt.cz then publish_caverns(K) end
  M.breach_boot(K, rt, pd)                                           -- BUG-130: breach tiles of an older kernel
  -- 'dig_lost' is no safety stop (damp/warm/water are 'breach:*'): every boot retries such projects once
  for _, P in ipairs(pd.list) do
    if P.blocked == 'dig_lost' then
      P.blocked, P.since = '', K.now().tick
      local R = rt.p[P.id]
      if type(R) == 'table' then R.rl = nil end
      K.log('info', '%s: dig_lost block cleared at boot, digging resumes', P.id)
      S.dirty = true
    end
  end
  save(K)
  local ph = K.persist.get('phase')
  S.phase = type(ph) == 'table' and ph.phase or nil
  rows(K)
end

-- BUG-037 watchdog: a task that yields task_slices slices in a row is skipped for this run (kern.log; what it did stays,
-- the next run goes on from there), so one task can never hold the run, and with it every slot, for good
function M.step(K, budget, ctx)
  S.slice = {qf = 0, probes = 0, qf_max = M.CFG.qf_per_slice}
  if not (ctx and ctx.cont) or not S.run then S.dtask, S.doing = nil, 'begin run'; begin_run(K) end
  local run = S.run
  run.sl = (run.sl or 0) + 1
  while run.i <= #run.tasks do
    local task = run.tasks[run.i]
    local P = task.id and find(task.id)
    S.dtask = {k = task.k, i = run.i, n = #run.tasks, sl = run.sl}
    local d0 = P and doc(K, P.id)
    Q.doing(P, d0 and d0.stages[P.stage + 1])
    local r = 'done'
    if task.k == 'end' then end_run(K)
    elseif task.k == 'check' then r = check_task(K, run.t or now(K)) == 'yield' and 'yield' or 'done'   -- the run's tick
    elseif P and task.k == 'undo' then r = undo(K, P)
    elseif P and task.k == 'work' and P.done ~= 1 and not halted(P) then
      -- the mode may change between slices of one run (SIEGE/BREACH freeze the runner at once)
      local d = doc(K, P.id)
      if not allowed(K, P, d) then
        local R = R_of(K, P)
        moved(K, R)
        Q.froze(K, P, d, R)
        dirty()
      elseif task.hold or paused(K, P, d) then r = work(K, P, task.meas, true)
      else r = work(K, P, task.meas) end
    end
    if r == 'yield' then
      run.ty = (run.ty or 0) + 1
      if run.ty < M.CFG.task_slices then save(K); return 'more' end
      S.wd = (S.wd or 0) + 1
      K.log('warn', 'runner watchdog: task %d/%d (%s%s) yielded %d slices in a row: skipped this run', run.i, #run.tasks,
            task.k, task.id and (' ' .. task.id) or '', run.ty)
      if task.k == 'check' then S.chk = nil end
    end
    run.i, run.ty = run.i + 1, 0
  end
  S.run, S.ended = nil, now(K)
  save(K)
end

-- BUG-039: what the runner's last slice did (kern asks right after a slow or huge step or handler)
function M.doing() return S.doing end

-- BUG-037: no run ended for run_idle_d days (or since the boot): {d, i, n, task, sl, age} of the run in hand, else nil
function Q.run_state(K)
  local t, t0 = now(K), S.ended or S.boot
  if not t0 or t - t0 < M.CFG.run_idle_d * DAY then return nil end
  local out, r = {d = (t - t0) // DAY}, S.run
  if r then
    local task = r.tasks[r.i]
    out.i, out.n, out.sl, out.age = r.i, #r.tasks, int(r.sl) or 0, math.max(0, (t - r.t) // DAY)
    if task then out.task = trunc(task.k .. (task.id and (' ' .. task.id) or ''), 40) end
  end
  return out
end

-- FR-76: what stands (workshops, stockpiles, wells, beds, doors) and the manifest's repairs, nil before the first scan
function Q.adopt_state()
  local ad = S.rt.ad
  if type(ad) ~= 'table' or ad.ws == nil then return nil end
  local r = {ws = math.max(0, int(ad.ws) or 0), new = math.max(0, int(ad.new) or 0)}
  if (int(ad.gone) or 0) > 0 then r.gone = int(ad.gone) end
  for _, k in ipairs({'stock', 'wells', 'beds', 'doors'}) do if int(ad[k]) then r[k] = math.max(0, int(ad[k])) end end
  if ad.rec == 1 then r.rec = 1 end
  if type(ad.miss) == 'table' and #ad.miss > 0 and ad.rec == 1 then
    r.miss = {}
    for i, n in ipairs(ad.miss) do if i <= 8 then r.miss[i] = trunc(n, 24) end end
  end
  return r
end

function M.state(K)
  local sc, q, run, pk = S.sched, S.q, Q.run_state(K), (S.npk or 0) > 0 and S.npk or nil
  if q or run or pk then
    sc = sc and copy(sc) or {}
    sc.q, sc.run, sc.pk = q, run, pk
  end
  return {phase = S.phase, proj = S.rows, sched = sc, adopt = Q.adopt_state()}
end

-- BUG-037 (economy's inspect workload and idle rule): the runner's queue in one clause, nil when nothing waits;
-- data {n, by = {{id, tpl, idle days}}, run = run_state, pk}
function M.queue(K)
  local q, run = S.q, Q.run_state(K)
  local data = {n = q and q.n or 0, by = q and q.by or {}, run = run, pk = S.npk or 0}
  if run then
    return string.format('runner: no run ended for %d days%s, %d projects wait', run.d,
                         run.task and string.format(' (at task %d/%d %s, %d slices)', run.i, run.n, run.task, run.sl)
                         or '', data.n), data
  end
  if not q then return nil, data end
  local names, idle = {}, 0
  for _, b in ipairs(q.by) do
    names[#names + 1] = string.format('%s %s%s', b[1], b[2], b[3] >= 2 and string.format(' %d d without progress', b[3])
                                                                 or '')
    if b[3] >= 2 then idle = idle + 1 end
  end
  return string.format('runner: %d project%s queued behind %d slot holder%s%s (%s)', q.n, q.n == 1 and '' or 's',
                       #q.by, #q.by == 1 and '' or 's', idle == #q.by and #q.by > 0 and ' without progress' or '',
                       table.concat(names, ', ')), data
end

-- public (live L2, BUG-043): the boxes of the projects the audit snapshot holds, named: {{b, id, tpl, parts?, done?}}:
-- the projects not done yet and the kept boxes of finished ones (KEEP_BOX; a kept seal, plug, repair or explore by
-- m.runner kk, else the list's template or 'done'; done = true). snapshot's default audit box is made of them (an
-- explore as a column part). BUG-129: parts = the clusters of its tiles when they lie apart (m.runner kp for a kept one)
function M.boxes(K)
  local r, tpl = {}, {}
  for _, P in ipairs(S.pd.list) do
    tpl[P.id] = P.tpl
    if P.done ~= 1 then
      local d = doc(K, P.id)
      if d then r[#r + 1] = {b = project_bbox(P.id, d), id = P.id, tpl = P.tpl, parts = Q.tile_parts(P.id, d)} end
    elseif KEEP_BOX[P.tpl] and not S.rt.keep[P.id] then   -- finished before the box was kept: its bp file
      local d = read_bp(K, P.id)
      if d and not check_doc(d, P.tpl) then keep_box(P, d); forget(P.id); dirty() end
    end
  end
  local ids = {}
  for id in pairs(S.rt.keep) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do
    r[#r + 1] = {b = S.rt.keep[id], id = id, tpl = S.rt.kk[id] or tpl[id] or 'done', parts = S.rt.kp[id], done = true}
  end
  return r
end

-- public (live L2): the boxes of M.boxes alone
function M.bboxes(K)
  local r = {}
  for i, e in ipairs(M.boxes(K)) do r[i] = e.b end
  return r
end

-- WP8 (economy, live L1b): tiles still to dig in the dig stage every running project is in (its tile count
-- minus the progress last measured); economy sizes the Miners detail from it
function M.dig_backlog(K)
  local n = 0
  for _, P in ipairs(S.pd and S.pd.list or {}) do
    if P.done ~= 1 and not halted(P) then
      local d = doc(K, P.id)
      local st = d and d.stages[P.stage + 1]
      if st and st.mode == 'dig' then
        local R = S.rt.p[P.id]
        local prog = type(R) == 'table' and R.si == P.stage and int(R.prog) or 0
        n = n + math.max(0, stage_tiles(P.id, d, P.stage).n - prog)
      end
    end
  end
  return n
end

-- absolute cells {{x, y, z, text}, ...} sorted by z, y, x, in chunks of <= 40 whose pos is the chunk's min corner
-- (offsets stay >= 0)
local function sort_cells(list)
  table.sort(list, function(a, b)
    if a[3] ~= b[3] then return a[3] < b[3] end
    if a[2] ~= b[2] then return a[2] < b[2] end
    return a[1] < b[1]
  end)
end
local function abs_chunks(list)
  local chunks = {}
  for i = 1, #list, 40 do
    local part = {table.unpack(list, i, math.min(#list, i + 39))}
    local x0, y0, z0 = part[1][1], part[1][2], part[1][3]
    for _, c in ipairs(part) do x0, y0, z0 = math.min(x0, c[1]), math.min(y0, c[2]), math.min(z0, c[3]) end
    local ch = {pos = {x0, y0, z0}, cells = {}}
    for _, c in ipairs(part) do ch.cells[#ch.cells + 1] = {c[1] - x0, c[2] - y0, c[3] - z0, c[4]} end
    chunks[#chunks + 1] = ch
  end
  return chunks
end
local function new_id(K, prefix)
  local t = now(K)
  local id, n = string.format('%s%d', prefix, t), 0
  while find(id) do n = n + 1; id = string.format('%s%d-%d', prefix, t, n) end
  return id
end

-- FR-56 (seal): a defense project that builds lost perimeter pieces again. cells = {{x, y, z, text}, ...} absolute
-- quickfort build cells (Cw, d, gw(3x1) ...); like cmd.py's repair_doc, buildingplan waits for the materials (no
-- orders) and there is no manifest fragment. opts.peace (seal, a lost bridge; BUG-030 rebuild policy): params.peace
-- = 1, the project is built only in PEACE without a reflex lockdown (allowed). opts.closure (seal's wall + door for a
-- lost bridge, BUG-081): params.cl = 1, prio 1, the walls in stage s1.walls and the door in s2.door; a repair that
-- closes a way in is kind 'repair' for the rebuild policy (it runs) and keeps the seal clock of SEAL_STUCK and the wall
-- fallback of BUG-044 (Q.closure). Returns ok, project id.
function M.repair(K, cells, why, opts)
  if type(cells) ~= 'table' or #cells == 0 or #cells > 500 then return false, 'need 1-500 cells' end
  local list = {}
  for i, c in ipairs(cells) do
    local x, y, z = int(type(c) == 'table' and c[1]), int(type(c) == 'table' and c[2]), int(type(c) == 'table' and c[3])
    if not (x and y and z) or type(c[4]) ~= 'string' or #c[4] < 1 or #c[4] > 64 then return false, 'bad cell ' .. i end
    list[#list + 1] = {x, y, z, c[4]}
  end
  sort_cells(list)
  local id = new_id(K, 'rp')
  local cl = type(opts) == 'table' and opts.closure == true     -- BUG-081: the keeper's wall + door for a lost bridge
  local stages = {{label = 's1.build', mode = 'build', orders = 0, defense = 1, chunks = abs_chunks(list)}}
  if cl then
    -- the walls first, the door in a stage of its own: quickfort places a door only beside a standing WALL or
    -- FORTIFICATION, a planned wall beside it does not count (door_walls), so a door in the walls' own call is refused
    -- and, the walls built meanwhile, the project ended build_lost with the door never placed (a season until its retry)
    local walls, doors = {}, {}
    for _, c in ipairs(list) do
      local t = c[4]:match('^[^{(:/]*') == 'd' and doors or walls
      t[#t + 1] = c
    end
    if #walls > 0 and #doors > 0 then
      stages = {{label = 's1.walls', mode = 'build', orders = 0, defense = 1, chunks = abs_chunks(walls)},
                {label = 's2.door', mode = 'build', orders = 0, defense = 1, chunks = abs_chunks(doors)}}
    end
  end
  local d = {v = 2, tpl = 'repair', site = 'repair', class = 'defense',
             params = cl and obj{peace = 1, cl = 1} or (type(opts) == 'table' and opts.peace) and obj{peace = 1} or obj{},
             rot = 0, anchor = {list[1][1], list[1][2], list[1][3]}, manifest = {v = 2}, materials = obj{},
             stages = stages}
  local ok, err = register(K, id, d, cl and 1 or 2, 'repair')
  if not ok then return false, err end
  save(K)
  K.log('info', 'repair %s queued: %d cells (%s)', id, #list, tostring(why or ''))
  return true, id
end

-- FR-61 (care's coffin provisioner; Run 9: 25 unburied, 0 free coffins, nothing built new ones): a `tombs` project
-- in dug space that already stands. tiles = {{x, y, z}, ...} (1-60 coffin tiles, care picked them: free revealed
-- floor of the citizens' walk group, outside every zone, roofed, away from the entrances). Stage 1 builds a coffin
-- on each ('n', no quickfort orders: care queues ConstructCoffin in a material the fort can use and buildingplan
-- waits for the coffins), stage 2 draws one 1x1 tomb zone per coffin ('T(1x1)'; zoned_cells leaves out a tile
-- that has one, care's `burial -c` zones each coffin as soon as it is built). Returns ok, project id.
M.CFG.coffins_max = 60
function M.coffins(K, tiles, why, prio)
  if type(tiles) ~= 'table' or #tiles == 0 or #tiles > M.CFG.coffins_max then
    return false, string.format('need 1-%d tiles', M.CFG.coffins_max)
  end
  local build, zone, seen = {}, {}, {}
  for i, t in ipairs(tiles) do
    local x, y, z
    if type(t) == 'table' then x, y, z = int(t[1] or t.x), int(t[2] or t.y), int(t[3] or t.z) end
    if not (x and y and z) or not on_map(x, y, z) then return false, 'bad tile ' .. i end
    local k = x .. ',' .. y .. ',' .. z
    if seen[k] then return false, 'tile ' .. i .. ' twice' end
    seen[k] = true
    build[#build + 1] = {x, y, z, 'n'}
    zone[#zone + 1] = {x, y, z, 'T(1x1)'}
  end
  sort_cells(build)
  sort_cells(zone)
  local p = int(prio) or 3
  if p < 1 or p > 7 then return false, 'prio must be 1..7' end
  local id = new_id(K, 'cof')
  local d = {v = 2, tpl = 'tombs', site = 'care', class = 'living', params = obj{n = #build}, rot = 0,
             anchor = {build[1][1], build[1][2], build[1][3]}, manifest = {v = 2}, materials = obj{coffin = #build},
             stages = {{label = 'tombs.build', mode = 'build', orders = 0, defense = 0, chunks = abs_chunks(build)},
                       {label = 'tombs.zone', mode = 'zone', orders = 0, defense = 0, chunks = abs_chunks(zone)}}}
  local ok, err = register(K, id, d, p, 'tombs')
  if not ok then return false, err end
  save(K)
  K.log('info', 'coffins %s queued: %d coffins with tomb zones at %d,%d,%d (%s)', id, #build, build[1][1], build[1][2],
        build[1][3], trunc(why, 80))
  return true, id
end

-- public (BUG-126, care's coffin provisioner): what became of the `tombs` project `id`: nil when it is not on the list
-- (done and pruned, cancelled, unknown), else a table {done 0|1, stage (index), chunk, pct, blocked (reason or ''),
-- label (stage name)}. Care compares two readings to tell a project that moves from one that waits for good.
function M.coffins_state(K, id)
  local P = type(id) == 'string' and find(id) or nil
  if not P then return nil end
  local d = doc(K, P.id)
  local st = d and d.stages[P.stage + 1]
  return {done = P.done == 1 and 1 or 0, stage = P.stage, chunk = P.chunk, pct = P.pct or 0, blocked = P.blocked or '',
          label = trunc(st and st.label or 'done', 24)}
end

-- public (BUG-126): the stale `tombs` project `id` that care's coffin provisioner placed leaves the list, without an undo:
-- the coffins it planned stay (buildingplan waits for their items, care orders them and `burial -c` zones them once
-- built), only the project that never ends goes (it held back every new search and every empty-zone repair). Refused for
-- a project of another template or one that is done. Returns ok, reason.
function M.coffins_drop(K, id)
  local P = type(id) == 'string' and find(id) or nil
  if not P then return false, 'no project ' .. tostring(id) end
  if P.tpl ~= 'tombs' then return false, P.id .. ' is no tombs project' end
  if P.done == 1 then return false, P.id .. ' is already done' end
  cancel(K, P, false)
  rows(K)
  save(K)
  return true, 'dropped ' .. P.id
end

-- BUG-063 (care; Run 14 y484/y485/y558: strange-mood dwarves died of thirst at 63,000 - 75,000, a mood dwarf neither drinks
-- nor eats while the job waits): a one-barrel drink-only stockpile `dfllm-mood` on one free floor tile beside the
-- claimed workshop (quickfort `place`, a player's own stockpile; the haulers fill it from `take`), so a drink stands
-- beside the workshop. Nothing is given to the dwarf and no job is made for him. tile = {x, y, z}; take = the pile it
-- takes from ('' none). Returns ok, project id. Cell text is at most 64 bytes (check_doc): the source pile is dropped
-- when its name does not fit.
function M.mooddrink(K, tile, take, why)
  local x, y, z
  if type(tile) == 'table' then x, y, z = int(tile[1] or tile.x), int(tile[2] or tile.y), int(tile[3] or tile.z) end
  if not (x and y and z) or not on_map(x, y, z) then return false, 'bad tile' end
  local props = 'name=dfllm-mood barrels=1'
  if type(take) == 'string' and take:match('^[%w_%-]+$') and #take <= 20 then props = props .. ' take_from=' .. take end
  local cell = 'f{' .. props .. '}:=booze(1x1)'
  if #cell > 64 then cell = 'f{name=dfllm-mood barrels=1}:=booze(1x1)' end
  local id = new_id(K, 'mdr')
  local d = {v = 2, tpl = 'mood_drink', site = 'care', class = 'living', params = obj{n = 1}, rot = 0,
             anchor = {x, y, z}, manifest = {v = 2}, materials = obj{},
             stages = {{label = 'mood.drink', mode = 'place', orders = 0, defense = 0, chunks = abs_chunks({{x, y, z, cell}})}}}
  local ok, err = register(K, id, d, 1, 'mood_drink')
  if not ok then return false, err end
  save(K)
  K.log('info', 'mood drink nook %s queued at %d,%d,%d (%s)', id, x, y, z, trunc(why, 80))
  return true, id
end

-- public (BUG-102, care's drink nook): what became of the mood_drink project `id`: 'pending' (not finished), 'refused'
-- (finished, but quickfort designated no stockpile: second value 'x,y,z' of the tile), 'placed' (finished, or the fake
-- quickfort answered no place stats); nil when the project is not on the list (pruned after done_keep, or unknown)
function M.nook_state(K, id)
  local P = type(id) == 'string' and find(id) or nil
  if not P then return nil end
  if P.done ~= 1 then return 'pending' end
  if P.refused then return 'refused', P.refused end
  return 'placed'
end

-- Run 11: explore shafts open to a cavern whose top wall does not stand yet (readiness keeps R0 `caverns` for them,
-- threat counts hostiles near them): n, {{x, y, z_top, z_bottom}, ...}
function M.cavern_open(K)
  local n, list = 0, {}
  for _, r in pairs(S.rt and S.rt.cav or {}) do
    if type(r) == 'table' and (r.st == 'open' or r.st == 'failed') then
      n = n + 1
      if type(r.s0) == 'table' then list[#list + 1] = {r.s0[1], r.s0[2], r.s0[3], int(r.bot) or r.s0[3]} end
    end
  end
  table.sort(list, function(a, b) return a[1] * 100000 + a[2] < b[1] * 100000 + b[2] end)
  return n, list
end

-- public (BUG-040, water's CISTERN_DRY): the id of the finished project whose kept box (m.runner keep) holds the centre
-- of bbox b ({x0, y0, z0, x1, y1, z1}), the smallest such box; nil when none
function M.kept_in(K, b)
  if type(b) ~= 'table' or not int(b[1]) or not int(b[6]) then return nil end
  local cx, cy, cz = (b[1] + b[4]) // 2, (b[2] + b[5]) // 2, (b[3] + b[6]) // 2
  local best, size
  for id, k in pairs(S.rt and S.rt.keep or {}) do
    if type(k) == 'table' and int(k[1]) and cx >= k[1] and cx <= k[4] and cy >= k[2] and cy <= k[5] and cz >= k[3]
       and cz <= k[6] and not (S.rt.kk and S.rt.kk[id]) then        -- BUG-043: a kept seal or shaft is no room
      local n = (k[4] - k[1] + 1) * (k[5] - k[2] + 1) * (k[6] - k[3] + 1)
      if not size or n < size or (n == size and tostring(id) < tostring(best)) then best, size = id, n end
    end
  end
  return best
end

-- public (BUG-040, water's CISTERN_DRY: piped or bucket-fed): a project's params from its bp file (read once per report;
-- the persisted doc is gone once the project is done), nil when the file is missing or unreadable
function M.bp_params(K, id)
  if type(id) ~= 'string' or not id:match('^[%w_.%-]+$') then return nil end
  local d = read_bp(K, id)
  return type(d) == 'table' and type(d.params) == 'table' and d.params or nil
end

-- WP7/WP8 (care): projects of a template that are not done yet (capacity requests wait for them; BUG-037: not parked)
function M.pending(K, tpl)
  local n = 0
  for _, P in ipairs(S.pd and S.pd.list or {}) do if P.tpl == tpl and Q.live(K, P) then n = n + 1 end end
  return n
end

-- BUG-058 (DECISIONS 9; Run 11: five farms projects 'build_lost, parked', one after the other, no soil): the projects of a
-- template blocked for good by build_lost (its retries spent), whether parked yet or not: count, the first project's id.
-- economy asks for no further farms project while one stands; cancelling it (bp.cancel) or placing it elsewhere ends it.
function M.lost(K, tpl)
  local n, first = 0, nil
  for _, P in ipairs(S.pd and S.pd.list or {}) do
    if P.tpl == tpl and P.done ~= 1 and P.blocked == 'build_lost' and Q.terminal(P) then
      n, first = n + 1, first or P.id
    end
  end
  return n, first
end

M.on = {
  -- damp/warm cancel and cavern reports stop the dig of every nearby project (no pos: all diggers)
  REPORT = function(K, ev)
    local why = REPORT_WHY[ev.type]
    if not why then return end
    local text = type(ev.text) == 'string' and ev.text:lower() or ''
    if why == 'cavern' then
      if text:find('magma', 1, true) then why = 'warm'
      -- Run 11: DF's discovery of underground water is a cavern lake (or river), not seepage
      elseif text:find('river', 1, true) or text:find('lake', 1, true) or text:find('water', 1, true) then
        why = 'cavern_lake'
      end
    end
    local p = type(ev.pos) == 'table' and ev.pos or nil
    local pos = p and {int(p.x or p[1]), int(p.y or p[2]), int(p.z or p[3])}
    if pos and not (pos[1] and pos[2] and pos[3]) then pos = nil end
    if not pos and ev.type == 'CAVE_COLLAPSE' then return end
    -- light aquifer (damp_dig): lost() designates damp stone again, unless a cavern shows at the report (Run 11)
    if why == 'damp' and M.CFG.damp_dig and not pos then return end
    local r = (why == 'damp' or why == 'warm') and M.CFG.breach_r or M.CFG.cavern_r
    S.slice = {qf = 0, probes = 0, qf_max = M.CFG.undo_now}
    for _, P in ipairs(S.pd.list) do
      local d = P.done ~= 1 and P.tpl ~= 'plug' and doc(K, P.id)      -- the cavern plug is never stopped
      local st = d and d.stages[P.stage + 1]
      if st and st.mode == 'dig' and P.chunk > 0 and (not pos or near(pos, stage_tiles(P.id, d, P.stage).bbox, r)) then
        if not (why == 'damp' and M.CFG.damp_dig and not CAVERN[(M.opened(K, P, d, pos))]) then
          if breach(K, P, why, pos, 'report') then undo(K, P) end
        end
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
  -- FR-78 (Run 14 note 65): a civzone in a box through quickfort's zone mode (lua/dfllm/zonelib.lua)
  ['zone.place'] = function(K, args, cmd) return require('dfllm.zonelib').verb(K, args, cmd) end,
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
    local bad = check_doc(d, args.tpl)
    if bad then return false, bad end
    -- FR-27: never a second tomb zone on a tile (Run 9: up to 3 stacked on one coffin)
    local cut, total, at = tomb_dups(d)
    if total > 0 and cut == total then
      return false, string.format('refused: a tomb zone already stands on all %d tomb cells (first at %d,%d,%d); '
                                  .. 'place the tombs elsewhere (FR-27)', total, at[1], at[2], at[3])
    end
    local ok, e = register(K, id, d, prio, args.tpl)
    if not ok then return false, e end
    save(K)
    local msg = string.format('queued %s (%s, %d stages)', id, d.tpl, #d.stages)
    if cut > 0 then
      msg = msg .. string.format('; %d of %d tomb cells left out: a tomb zone stands there (first %d,%d,%d)', cut,
                                 total, at[1], at[2], at[3])
      K.log('info', '%s: %d of %d tomb cells already zoned, left out (FR-27)', id, cut, total)
    end
    return true, msg, {proj = id}
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
