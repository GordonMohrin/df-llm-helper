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

-- FR-95: the aquifer pass (tpl aqshaft, observe mode for damp reports): a library the runner hosts (a field, not a
-- local: the main chunk is at Lua's 200-local limit)
M.AQ = require('dfllm.aqshaft')

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
  -- BUG-184: an unanswered mandatory workshops request backs off: the k-th repeat of the same types waits
  -- req_cool * 2^(k-1) game ticks and req_wall_s * 2^(k-1) wall seconds, k at most req_backoff
  req_wall_s = 900, req_backoff = 4,
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
  seal_first = true, seal_stuck_days = 3, seal_lead_days = 10, emerg_food_d = 30, emerg_drink_d = 30, rebuild_pop = 10, rebuild_off = 12,
  -- BUG-336 (Run 15b Earthboat y384-y387: the refuge hatch 55,82,133 'stalled 0%' 911 days, trolls walked down the open
  -- stair, 92 -> 1): a stuck seal without progress for seal_esc_days (1-60) asks the player (DECISION_NEEDED
  -- seal_stalled, A, again every seal_esc_days while it stays so) with the piece, the cause, what the kernel tried and the
  -- commands; the refuge's seal is never set aside (BUG-328). config seal_first {esc_days}
  seal_esc_days = 30,
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
  -- BUG-637 (Run 16b i2 Valleyhame y376: bedrooms 58 %, hospital 25 % and a seal stood build_lost 300+ days, parked, holding their
  -- tiles ('taken by'), the plan's builds and the DECISIONs, until the player cancelled each by hand; Run 16a i1 hospital c1a1c154 the
  -- same): a project parked for good (build_lost with the retries spent) is cancelled by the kernel itself lost_days after the block
  -- began (no undo: what it built stays, its unbuilt pieces and jobs go), PROJECT_BLOCKED d.autocancel names why and the command that
  -- places it again; at most lost_max times per template, then it stays parked (the reason in the park event). 0 = off.
  -- config "runner": {queue: {lost_days}}
  lost_days = 60, lost_max = 2,
  occupied_days = 3,         -- BUG-720: a seal blocked `occupied` this long is cancelled (0 = off); the audit names another wall tile
  -- BUG-328 (Run 15c Inkintense y377: 'runner: no run ended for 176 d, 78 slices': a task yielding every slice, the runner
  -- paced and demoted to a few slices a game day, so 600 slices took 130 game days and every project and the seal waited
  -- that long): a task yielding for task_days game days is skipped too, whatever its slice count. A project without own
  -- progress (R.ps) for idle_days is set aside: no runner slot (measured meas_every like a stalled one, so DF's builders
  -- finishing it is noticed), its row last ('set aside N d: no progress'), PROJECT_BLOCKED d.idle with the commands; it
  -- comes back by itself on progress, by `bp.resume` (a fresh idle_days) or goes by `bp.cancel`. Not set aside: a mood
  -- project, the hospital care first leads, an aqshaft watching an open level, the refuge drink, a seal in SIEGE/BREACH,
  -- a food/drink project in an emergency (Q.idle_keep; a set-aside one comes back once it becomes one). config "runner":
  -- {queue: {idle_days}}
  task_days = 3, idle_days = 30,
  -- BUG-486 (Run 16d i4 Trumpetrealms: dining, tavern, temple, hospital 'set aside, no runner slot (the others go first)' for 478 d while 15
  -- of 16 adults had no job: `active` = 3 projects at once whatever the fort's size): the slots grow with the idle hands and the
  -- population, active + free idle adults // slots_idle + adults // slots_pop, at most slots_max. The order of the
  -- queue is the same (seal, care, mood, then the plan's order); only more of them run. slots_idle 0 = off (active slots only).
  -- config "runner": {queue: {slots_idle, slots_pop, slots_max}}
  slots_idle = 3, slots_pop = 40, slots_max = 8,
  -- BUG-435 (Run 16d i4 Mazelanterns y401: traps 912 d, tombs 461 d, fortcore 341 d set aside, 'waits for trapparts': nine projects
  -- clogged the brief for ever): a project set aside stale_days without progress is announced (PROJECT_BLOCKED why=stale, A) with
  -- what it waits for and the commands, again every stale_every days; follow cancels the replaceable templates itself
  -- (plan.stale_project_days); the kernel never cancels. 0 = never announced. config "runner": {queue: {stale_days, stale_every}}
  stale_days = 300, stale_every = 90,
  -- BUG-444 (Run 16c i3 Castletongs: aqshaft S1 kept a runner slot 556 days at 7 %, no event; bp.resume 'not set aside'): the
  -- projects idle_keep exempts from the set-aside rule (an aqshaft watching a level, the refuge drink, a seal in a siege, a mood
  -- or care project, supply in an emergency) and every other RUNNING project that holds a slot are watched too: no progress
  -- (R.ps) for stall_days is announced (PROJECT_BLOCKED why=stalled, A) with the cause and a command, again every stall_every
  -- days. Announcement only: the project keeps its slot. 0 = off. config "runner": {queue: {stall_days, stall_every}}
  stall_days = 60, stall_every = 60,
  -- BUG-529 (Run 16a i1 Basementflew y402-y403: aqshaft c1a1ada7 stood 425 days at z124 / 38 % 'ring has not moved', kept as a level it
  -- watches, and the hospital and the fortcore stayed 'queued behind c1a1ada7' until the player cancelled it; the kernel only reported): a
  -- shaft that holds a level and has made no progress (R.ps) for release_days gives up its FIRST-pass slot: it queues with the stalled
  -- projects (second pass: the slots the others leave, its level still measured), and one DECISION_NEEDED project_released (A) names the
  -- cause and the cancel command, again every stall_every days while it stays so. It comes back by itself on progress. Never cancelled by
  -- the kernel. 0 = off. config "runner": {queue: {release_days}}
  release_days = 60,
  -- BUG-352 (Run 16c site97: fortcore stage 1 on soil beyond the brook, 30 d at s1.dig 0 %, 'unreachable DigChannel'): a
  -- dig stage without own progress (R.ps) for reach_days whose revealed tiles (or their neighbours) lie in no walk group a
  -- citizen stands in is announced (PROJECT_BLOCKED d.why 'unreachable', row 'unreachable N d', Q.reach_scan): the
  -- commands cancel it and place it again at a site `bp sites` offers (it lists reachable sites only). Informative: the
  -- project stays. config "runner": {queue: {reach_days}}
  reach_days = 3,
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
               ready = 'readiness', stock = 'economy', orders = 'economy', bolts = 'economy', trade = 'trade',
               sweep = 'cavern',     -- FR-99: the P6 cavern sweep (cavern.cleared)
               kit = 'military'}                                                         -- FR-100
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
  if S.life then S.life[id] = nil end               -- BUG-347: the life-support burrow check
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
          if d and (d.tpl == 'seal' or d.tpl == 'repair') then
            -- BUG-487: the plan's seal goes through the reach check bp.place makes (Q.place_walls): a wall that would cut a
            -- citizen or a farm, well, depot, workshop or office off (or whose reach cannot be proven) is built as a door
            d.id = id
            local walls = Q.place_walls(K, d, 'plan')
            if walls then
              local n = Q.walls_to_doors(K, d)
              if n > 0 then
                K.log('warn', 'plan build %s (%s): %d wall(s) built as doors: %s', id, d.tpl, n, walls)
              else
                d, err = nil, walls
              end
            end
          end
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
local BY = {killboxes = {'id', 20}, rooms = {'id', 200}, workshops = {'pos', 100}, traps = {'id', 40}}   -- traps: FR-96

-- FR-96: a way's lane (id T<x>_<y>_<z>) keeps its tiles when a later traps project re-arms part of it (the union of the
-- tiles, same kind, <= 64); Z2 (fortcore stage 4's hall) and a kind change are replaced as a whole
function Q.merge_traps(dst, src)
  local old, add = {}, {}
  for _, e in ipairs(type(dst) == 'table' and dst or {}) do if type(e) == 'table' then old[key_of(e.id)] = e end end
  for _, e in ipairs(type(src) == 'table' and src or {}) do
    local o = type(e) == 'table' and old[key_of(e.id)] or nil
    if o and type(e.id) == 'string' and e.id:sub(1, 1) == 'T' and o.kind == e.kind and type(o.tiles) == 'table'
        and type(e.tiles) == 'table' then
      e = copy(e)
      e.tiles = append_unique(o.tiles, e.tiles, 64)
    end
    add[#add + 1] = e
  end
  return replace_by(dst, add, 'id', 40)
end

-- maps replaced per key; id/pos lists replaced per entry; plain lists appended without duplicates
function M.merge_manifest(dst, frag)
  for k, v in pairs(type(frag) == 'table' and frag or {}) do
    if k == 'v' then -- keep
    elseif MAPS[k] and type(v) == 'table' then
      dst[k] = obj(dst[k])
      for kk, vv in pairs(v) do
        local old, new = dst[k][kk], copy(vv)
        -- BUG-713 (Run 16b i2 Whirledrampart y430: after `bp.place fortcore stage=3 retrofit=2` the levers of B2 / O1 that stood read 'no
        -- lever at ...'): the fragment of a bridge replaces its entry; the levers of the entry it replaces stay in the list (the same
        -- bridge, same footprint), so a retrofit never drops a lever gate knows (and its link) from the manifest
        if k == 'bridges' and type(old) == 'table' and type(new) == 'table' and type(old.levers) == 'table'
           and type(old.fp) == 'table' and key_of(old.fp) == key_of(new.fp) then
          new.levers = append_unique(old.levers, new.levers, 12)
        end
        dst[k][kk] = new
      end
    elseif LISTS[k] and type(v) == 'table' then
      dst[k] = obj(dst[k])
      for kk, list in pairs(v) do dst[k][kk] = append_unique(dst[k][kk], list, LISTS[k]) end
    elseif k == 'traps' then dst[k] = Q.merge_traps(dst[k], v)
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
  -- FR-95: a project in observe mode (S.aqo, set by measure_dig/hold_watch) digs on through shallow seepage too, unless
  -- the flow in that tile rises (M.AQ.wet: then the stop below, made heavy_aquifer by breach)
  if HAZARD[v.c] == 'water' and (M.CFG.damp_dig or S.aqo) then
    local depth = int(v.flow) or 7
    if depth <= M.CFG.seep_max and not v.magma then
      if S.aqo and M.AQ.wet(Q.aqx(K), S.aqo, t, depth) then return 'breach', 'water' end
      return 'done'
    end
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

-- BUG-365 (Run 16c i3 Yawninggilt, 16a-d: 's1.dig chunk 8: designation at 111,80,124 lost twice without a damp report:
-- blocked', 'dig_lost' 4 times; the chunk lies 45 tiles from the anchor 66,80,127 because it is the civilian stair at v 45 of
-- the 35 x 52 fort, not an offset): DF cancelled the designation on an aquifer tile (gamelog: 'Digging designation cancelled:
-- damp stone located', 56 of them) and the announcement log search found none of them (the newest 200 reports held fights and
-- caravan notices by then). The lost tile itself answers: a revealed tile with the aquifer flag (snapshot.tile `aq`) is damp
-- stone, whatever the log says. Hidden tiles answer nothing (their flag is never read).
function Q.lost_on_aquifer(K, t)
  local ok, v = K.call('snapshot', 'tile', t[1], t[2], t[3])
  return ok and type(v) == 'table' and v.aq == true
end

local function lost(K, P, d, R, ci, t)
  local ch = d.stages[P.stage + 1].chunks[ci]
  local bb = stage_tiles(P.id, d, P.stage).bbox
  local why = P.tpl ~= 'plug' and M.cancel_reported(bb, M.CFG.breach_r) or nil   -- the cavern plug never stops
  if why == nil and P.tpl ~= 'plug' and Q.lost_on_aquifer(K, t) then why = 'damp' end   -- BUG-365
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
  if Q.aq_lost(K, P, R, ci, ch, t, why) then return end                -- FR-95: observe mode, the damp marker
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
  S.aqo = M.AQ.observing(S.rt, P.id) and P or nil      -- FR-95: probe's seepage rule for a project in observe mode
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

-- BUG-357 (Run 16b i2 y372 d28-60, Run 16c i3: farms and two workshops projects stood 32 days at build 50% "waits for door
-- (0 free, 3 ordered)", the door's order "no Carpenters workshop", ConstructBlocks "no Masons workshop", and no shop stood
-- for 130 days): a door is made at a Carpenter's or a Mason's workshop. While neither stands built, a planned door of a room
-- or farm project is not awaited: the stage goes on without it (the planned door stays on the map and DF builds it once a
-- shop makes the item), and the mandatory shops are requested (Q.sync). Seals, plugs and repairs keep their doors: a way in
-- is not left open on that account. nil = unreadable (no claim).
Q.DOOR_KEEP = {seal = true, plug = true, repair = true}
-- BUG-581 (Run 16a i1 Basementflew y423-y426: the hospital project stood 'build_lost at build' at 28 % for 8 retries, 300 days, patients
-- dying of thirst: its traction bench needs a mechanism and the fort had no reachable hard stone): the pieces below are optional. A
-- planned one nobody can build yet is not awaited, a missing one (quickfort refused it, its tile is empty) does not count as lost; the
-- rest of the room is built and the project is done. The bench stays on the map where it was placed and DF builds it once a mechanism
-- exists. Keys of the stage's cells (the build key of the template: R = traction bench).
Q.OPTIONAL = {hospital = {R = true}}
Q.OPT_TYPE = {hospital = {TractionBench = true}}
function Q.optional_missing(K, P, d)
  local opt = Q.OPTIONAL[P.tpl]
  local st = opt and d and d.stages and d.stages[P.stage + 1]
  if not (st and st.mode == 'build') then return 0 end
  local n = 0
  for _, ch in ipairs(st.chunks) do
    for _, cell in ipairs(ch.cells) do
      local tl = {}
      cell_tiles(ch, cell, tl)
      if tl[1] and opt[tl[1][4]] and not Q.bld_at(tl[1][1], tl[1][2], tl[1][3]) then n = n + 1 end
    end
  end
  return n
end

function Q.no_door_shop()
  local have = false
  local ok = pcall(function()
    for _, b in ipairs(df.global.world.buildings.other.WORKSHOP_ANY) do
      local n = df.workshop_type[b.type]
      if (n == 'Carpenters' or n == 'Masons') and b:getBuildStage() >= b:getMaxBuildStage() then have = true; return end
    end
  end)
  if not ok then return nil end
  return not have
end

local function measure_build(K, P, d, R)
  if R.noid == 1 then return 'complete' end
  local pend, done, keep = 0, 0, {}
  local noshop, deferred, nopt = nil, 0, 0
  for _, id in ipairs(R.b) do
    local b = df.building.find(id)
    if b then
      keep[#keep + 1] = id
      if built(b) then done = done + 1
      else
        local door = P.class ~= 'defense' and not Q.DOOR_KEEP[P.tpl] and b:getType() == df.building_type.Door
        if door and noshop == nil then noshop = Q.no_door_shop() end
        local ot = Q.OPT_TYPE[P.tpl]
        local optional = ot ~= nil and ot[df.building_type[b:getType()] or ''] == true       -- BUG-581
        if optional then
          done = done + 1
          nopt = nopt + 1
        elseif door and noshop then deferred = deferred + 1; done = done + 1 else pend = pend + 1 end   -- BUG-357
      end
    end
  end
  if deferred > 0 then
    S.rt.dd = S.rt.dd or now(K)
    if R.dd ~= deferred then
      R.dd = deferred
      K.log('warn', '%s (%s): %d door(s) not awaited: no Carpenters or Masons workshop stands (a door is made at one); the stage ' ..
            'goes on, the planned door is built once a shop exists (BUG-357)', P.id, P.tpl, deferred)
    end
  end
  for _, id in ipairs(R.c) do               -- a finished construction is no building any more
    local b = df.building.find(id)
    if b and not built(b) then pend = pend + 1 else done = done + 1 end
  end
  local lost = #R.b - #keep + R.uns
  local total = #R.b + #R.c + R.uns
  -- BUG-565: a seal whose every piece tile holds a building of another kind (pre_occupied, R.occ) built nothing and stands for nothing:
  -- it is blocked for good with the reason, never 'done' at 100 % (the bypass it was placed for would stay and nobody would know why)
  if type(R.occ) == 'table' and #R.occ > 0 and P.tpl == 'seal' then
    if done == 0 and pend == 0 then
      if P.blocked ~= 'occupied' then
        K.log('warn', '%s (seal): nothing built: %s; the project is blocked (cancel it; a wall cannot stand there)', P.id,
              table.concat(R.occ, ', '))
      end
      set_blocked(K, P, 'occupied')
      dirty()
      return 'done'
    elseif R.occw ~= #R.occ then
      R.occw = #R.occ
      K.log('warn', '%s (seal): a piece tile holds another building: %s', P.id, table.concat(R.occ, ', '))
    end
  end
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
    -- BUG-328 review: the kernel's own step, as the seal fallbacks: a set-aside project comes back (its next run applies
    -- the lost part; a measure-only task stops before measure_build while P.chunk < #chunks, so nothing else moves R.ps)
    moved(K, R)
    dirty()
    return 'reapply'
  end
  if pend > 0 then return 'done' end
  -- BUG-581: an optional piece (the hospital's traction bench) that was never placed or is not built is no loss of the room
  local nmiss = Q.optional_missing(K, P, d)
  local lost_eff = math.max(0, lost - nmiss)
  if (nmiss > 0 or nopt > 0) and R.opt ~= nmiss + nopt then
    R.opt = nmiss + nopt
    K.log('warn', '%s (%s): %d optional piece(s) not built (%s): the stage goes on without them; DF builds a placed one once its ' ..
          'material exists (BUG-581)', P.id, P.tpl, nmiss + nopt, P.tpl == 'hospital' and 'traction bench: needs a mechanism' or '?')
  end
  if lost_eff * 100 > total * M.CFG.lost_pct then
    set_blocked(K, P, 'build_lost')
    local q = obj(S.rt.rty[P.id])          -- BUG-022: the retry record (count kept across retries)
    q.n, q.t, q.sig, q.c = int(q.n) or 0, now(K), nil, now(K)
    S.rt.rty[P.id] = q
    return 'done'
  end
  R.lost = lost_eff
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

-- BUG-584 (Run 16d i4 Trumpetrealms y412-y415: four explore probes in a mudstone fort, 'no ore, no hard stone' and nobody could tell which rock
-- the shafts had passed): the rock layers of a finished explore's stair column, top down, one entry per run of one stone ('MUDSTONE z136-z131').
-- DFHack's tile-material GetLayerMat reads the layer of the biome at x, y, z (M.layer_mat: tests replace it); nil = not readable.
function M.layer_mat(x, y, z)
  if Q.tilemat == nil then
    local ok, tm = pcall(require, 'tile-material')
    Q.tilemat = ok and type(tm) == 'table' and tm or false
  end
  if not Q.tilemat then return nil end
  local ok, mi = pcall(Q.tilemat.GetLayerMat, x, y, z)
  local id = ok and mi ~= nil and mi.inorganic ~= nil and mi.inorganic.id
  return type(id) == 'string' and id or nil
end
function Q.shaft_rocks(xr)
  if type(xr) ~= 'table' or not (xr.x and xr.y and xr.top and xr.low) then return nil end
  local out, cur = {}, nil
  for z = xr.top, math.max(xr.low, xr.top - 40), -1 do
    local id = M.layer_mat(xr.x, xr.y, z)
    if id then
      if cur and cur.id == id then cur.z1 = z
      else
        if #out >= 6 then break end
        cur = {id = id, z0 = z, z1 = z}
        out[#out + 1] = cur
      end
    end
  end
  if #out == 0 then return nil end
  local names = {}
  for i, e in ipairs(out) do
    names[i] = e.z0 == e.z1 and string.format('%s z%d', e.id, e.z0) or string.format('%s z%d-z%d', e.id, e.z0, e.z1)
  end
  return names
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

-- FR-95: a project that digs again (a breach:damp park resumed in observe mode) leaves `breaches`: plan propose does not
-- re-site a fortcore that is digging (a later stop, heavy_aquifer, notes it again)
function M.drop_breach(K, id)
  if type(S.rt.dz) ~= 'table' then return end
  for i = #S.rt.dz, 1, -1 do
    if type(S.rt.dz[i]) == 'table' and S.rt.dz[i].proj == id then table.remove(S.rt.dz, i) end
  end
  M.publish_breaches(K)
  dirty()
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
    -- FR-95: a project with an aquifer record (observe mode resumed it, or an aqshaft) is no stopped project to re-site
    if not have[id] and tpl[id] and type(r) == 'table' and type(r.pos) == 'table'
       and not (type(rt.aq) == 'table' and type(rt.aq[id]) == 'table') then
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
  local sh = ex.sh or (Q.SHAFT[P.tpl] and d and shaft_of(K, P, d, rec.pos)) or nil      -- FR-95: aqshaft too
  local who = ex.state and string.format('%s (%s; shaft check)', P.id, ex.state) or P.id
  local st_d = ex.state and {state = trunc(ex.state, 40)} or nil
  if not sh then
    local hint = Q.SHAFT[P.tpl] and 'no dug stair column reaches the fort' or ('no automatic plug for ' .. P.tpl)
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

-- BUG-329 (Run 15c Inkintense y372-y378: farms c1a18745d4e25dac02 'build_lost at build, missing p' for 8 retries while its
-- p(7x5) stood as plot 17696 at 76,50,131, Plump Helmet growing; Drillchamber farms likewise): a finished farm plot sets no
-- building occupancy on its tiles (a planned one does: findAtTile found the unbuilt FarmPlot 86,87,133 and its job), so
-- dfhack.buildings.findAtTile, which returns at once on a tile without the occupancy bit (Buildings.cpp findAtTile), and
-- snapshot's legend (bld '' on a None occupancy) both miss it. The building on a tile: findAtTile, else a farm plot of
-- buildings.other.FARM_PLOT whose rectangle (and extent, when it has one) holds the tile
function Q.bld_at(x, y, z)
  local find = dfhack.buildings and dfhack.buildings.findAtTile
  if find then
    local ok, b = pcall(find, x, y, z)
    if ok and b then return b end
  end
  local ok, b = pcall(function()
    for _, p in ipairs(df.global.world.buildings.other.FARM_PLOT) do
      if p.z == z and x >= p.x1 and x <= p.x2 and y >= p.y1 and y <= p.y2 then
        local rm = p.room
        local ex, w, rx, ry = rm and rm.extents, rm and int(rm.width), rm and int(rm.x), rm and int(rm.y)
        if not (ex and w and w > 0 and rx and ry) then return p end
        local okv, v = pcall(function() return ex[(y - ry) * w + (x - rx)] end)
        if not okv or (v ~= nil and v ~= 0 and v ~= false) then return p end    -- an unreadable extent: the rectangle
      end
    end
  end)
  return ok and b or nil
end

-- live L2: a stage placed again over buildings it already has (fortcore stages 2-3 re-placed without their
-- traps) finds those tiles occupied, and quickfort counts them as unsuitable (building.lua:517-559), which
-- read as lost buildings (build_lost). Before a build chunk, the tiles that already hold a building or a
-- finished construction are counted (returned) and their buildings tracked like ours (an unbuilt one keeps
-- the stage pending).
local OCCUPIED = {C = true, F = true, ['='] = true, H = true, B = true, ['^'] = true, ['+'] = true}
-- BUG-565 (Run 16c i3 Sealcertain y405 `bp.place seal at=55,132,137 close=wall` behind the hatch 54,132,137: 'done' at 100 %, nothing
-- built, SEAL_STUCK '0 pieces open', the bypass stayed): a seal piece cell on a tile that already holds a building of ANOTHER kind (a
-- hatch or door where a wall is wanted, a trap, a bridge) was adopted as the project's own piece below ("tracked like ours"), so the
-- stage measured it as built. What a seal key wants on its tile: Cw a constructed wall, d a door, H a hatch. A mismatch is not adopted
-- and is named (R.occ, 'Hatch 55,132,137 (a wall was wanted)'); measure_build blocks the seal when nothing else of it stands
Q.SEAL_WANT = {Cw = 'Construction', d = 'Door', H = 'Hatch'}
Q.SNAP_NAME = {['+'] = 'door or hatch', ['^'] = 'trap', ['='] = 'bridge', H = 'hatch', B = 'building'}
function Q.seal_mismatch(P, cell_key, b, c)
  local want = Q.SEAL_WANT[tostring(cell_key):match('^[^{(:/]*')]
  if not (want and P and P.tpl == 'seal') then return nil end
  if b then
    local ty = df.building_type[b:getType()]
    if ty == want then return nil end
    return ty or '?'
  end
  if want == 'Construction' and Q.SNAP_NAME[c] then return Q.SNAP_NAME[c] end
  return nil
end
local function pre_occupied(K, ch, R, P)
  local tiles, n, seen = {}, 0, {}
  for _, cell in ipairs(ch.cells) do cell_tiles(ch, cell, tiles) end
  for _, id in ipairs(R.b) do seen[id] = true end
  for _, t in ipairs(tiles) do
    local b = Q.bld_at(t[1], t[2], t[3])            -- findAtTile (Lua API.txt:2484); BUG-329: a finished farm plot too
    local okt, tile
    if not b then okt, tile = K.call('snapshot', 'tile', t[1], t[2], t[3]) end
    local mis = Q.seal_mismatch(P, t[4], b, okt and type(tile) == 'table' and tile.c or nil)
    -- BUG-719 (Run 16c i3 Doorwings / 16d i4 Pagedsculpture: depot1..25 'done' in 5 s, no depot): any building on any of the 25 depot tiles was
    -- adopted as the depot, built, so the stage was done. Only a trade depot is the depot's; anything else in the footprint is an
    -- unsuitable tile (quickfort refuses the 5x5) and the stage is build_lost with the reason (lost_why)
    if t[4] == 'D' and not mis then
      local isdep = false
      if b then
        local okty, ty = pcall(function() return b:getType() end)
        isdep = okty and (not (df.building_type and df.building_type.TradeDepot ~= nil) or ty == df.building_type.TradeDepot)
      end
      if not isdep then goto continue end
    end
    if mis then
      n = n + 1
      R.occ = type(R.occ) == 'table' and R.occ or {}
      if #R.occ < 3 then R.occ[#R.occ + 1] = string.format('%s %d,%d,%d (%s wanted)', mis, t[1], t[2], t[3],
                                                           t[4] == 'Cw' and 'a wall' or t[4] == 'd' and 'a door' or 'a hatch') end
    elseif b then
      n = n + 1
      if not seen[b.id] and not is_construction(b) then seen[b.id] = true; R.b[#R.b + 1] = b.id end
    elseif okt and type(tile) == 'table' and OCCUPIED[tile.c] then n = n + 1 end
    ::continue::
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
  local b0 = Q.bld_at(t[1], t[2], t[3])
  if t[4] == 'D' then
    -- BUG-719 (Run 16c i3 Doorwings / 16d i4 Pagedsculpture: depot1..25 'done' in 5 s each, no depot ever stood): the corner of a depot
    -- footprint holding ANY other building or construction counted as the depot; only a trade depot is the depot
    local ty
    if b0 then local okt, v = pcall(function() return b0:getType() end); if okt then ty = v end end
    if b0 and ty ~= nil and df.building_type and df.building_type.TradeDepot ~= nil and ty ~= df.building_type.TradeDepot then
      local _, tile0 = K.call('snapshot', 'tile', t[1], t[2], t[3])
      return false, type(tile0) == 'table' and tile0 or nil
    end
    if b0 then return true end
    local _, tile0 = K.call('snapshot', 'tile', t[1], t[2], t[3])
    return false, type(tile0) == 'table' and tile0 or nil
  end
  if b0 then return true end          -- BUG-329: a finished farm plot sets no occupancy
  local okt, tile = K.call('snapshot', 'tile', t[1], t[2], t[3])
  if not (okt and type(tile) == 'table') then return false, nil end
  return (tile.bld ~= nil and tile.bld ~= '') or OCCUPIED[tile.c] == true, tile
end

-- after a seal build chunk: its doors quickfort refused (n unsuitable cells, nothing on a door's revealed tile now)
-- become constructed walls in the project's copy; returns how many
local function door_walls(K, P, d, st, ch, n)
  if P.tpl ~= 'seal' or n <= 0 or type(d) ~= 'table' then return 0 end
  local got, seen, asked = 0, 0, false
  for _, c in ipairs(ch.cells) do
    if seen >= n then break end
    if c[4]:match('^[^{(:/]*') == 'd' then
      local x, y, z = ch.pos[1] + c[1], ch.pos[2] + c[2], ch.pos[3] + c[3]
      local here, tile = cell_present(K, {x, y, z})
      if not here and tile then
        seen = seen + 1
        -- BUG-458 (review): the second wall path needs the same reach check as the stuck fallback: a wall that would cut a
        -- citizen, farm, shop, depot or office off (or cannot be proven safe) is not built; the door stays, is asked for as a
        -- workshop task (economy.seal_doors) and seal_stalled names it
        local refuse = Q.wall_refuse(K, P, d, {x, y, z})
        if refuse then
          local r = S.rt.sf and S.rt.sf[P.id]
          if type(r) == 'table' then
            r.nw = type(r.nw) == 'table' and r.nw or {}
            r.nw[tkey(x, y, z)] = refuse
          end
          K.log('warn', '%s %s: door unsuitable at %d,%d,%d stays a door: %s', P.id, st.label, x, y, z, refuse)
          if not asked then
            asked = true
            local okd, nd = K.call('economy', 'seal_doors', 1)
            if okd and int(nd) and int(nd) > 0 then
              K.log('warn', '%s: %d door task(s) added at the workshops (no wall: %s)', P.id, int(nd), refuse)
            end
          end
        else
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

-- BUG-514 (Run 16a i1 Basementflew y403-y405, fortcore aquifer=pass: the core level lay in damp rock, the beds at 34,92,117 stood on
-- water, DF cancelled their jobs 'Building site submerged' and the stage hung at 35 % for 400 days): beds are not queued on a tile
-- that holds water (Q.WET_BUILD/7 or more, snapshot flow); they are left out as a refused part (R.uns), the stage goes on.
-- Returns the chunk without those cells and their number.
Q.WET_KEYS = {b = true}
Q.WET_BUILD = 4
function Q.wet_cells(K, P, st, ch)
  local keep, n = {}, 0
  for _, cell in ipairs(ch.cells) do
    local key = tostring(cell[4]):match('^[^{(:/]*')
    local wet
    if Q.WET_KEYS[key] then
      local tl = {}
      cell_tiles(ch, cell, tl)
      for _, t in ipairs(tl) do
        local v = tile_at(K, t[1], t[2], t[3])
        if v and HAZARD[v.c] == 'water' and (int(v.flow) or 7) >= Q.WET_BUILD then wet = {t[1], t[2], t[3], int(v.flow) or 7}; break end
      end
    end
    if wet then
      n = n + 1
      K.log('warn', '%s %s: bed at %d,%d,%d left out: the tile holds water %d/7 (DF would cancel it as submerged)', P.id, st.label,
            wet[1], wet[2], wet[3], wet[4])
    else keep[#keep + 1] = cell end
  end
  if n == 0 then return ch, 0 end
  return {pos = ch.pos, cells = keep}, n
end

-- BUG-522 (Run 16c i3 Sealcertain y385 d11: two citizens 'found dead: crushed (incident CAVEIN)' at 15,13,141, the brief said only
-- 'crushed 2', no event named a project or a tile): a floor tile that hangs free above a hole a dig chunk opens is what a cave-in
-- drops on whoever stands there or below. Of every dug tile (key d, h, u, j, i, r; a channel also opens the tile below) the roof tile
-- one level up is read (snapshot.tile, at most CFG.cave_probe a chunk): a revealed FLOOR tile that the chunk does not dig itself and
-- that has no revealed WALL tile among its eight neighbours on its level is a free-hanging floor (an unrevealed neighbour is no
-- verdict). CFG.cave_check: 'off', 'warn' (default: kern.log line naming project, chunk and tile, once a chunk, and the project's
-- `cave` record that care's CAVEIN death report reads: dig_near) or 'block' (the project is blocked `cavein_risk` before the
-- designation; bp.cancel it or place it again somewhere else). Returns true when the chunk was not designated.
M.CFG.cave_check, M.CFG.cave_probe = 'warn', 30
Q.CAVE_KEYS = {d = true, h = true, u = true, j = true, i = true, r = true}
function Q.cave_risk(K, ch)
  local tiles, own = {}, {}
  for _, cell in ipairs(ch.cells) do cell_tiles(ch, cell, tiles) end
  for _, t in ipairs(tiles) do own[tkey(t[1], t[2], t[3])] = true end
  local seen, n, out = {}, 0, {}
  for _, t in ipairs(tiles) do
    if Q.CAVE_KEYS[t[4]] then
      local x, y, z = t[1], t[2], t[3] + 1
      local k = tkey(x, y, z)
      if not seen[k] and not own[k] then
        seen[k] = true
        n = n + 1
        if n > M.CFG.cave_probe then break end
        local rt = tile_at(K, x, y, z)
        if rt and rt.shape == 'FLOOR' and (rt.bld or '') == '' then
          local wall, unknown = false, false
          for dy = -1, 1 do
            for dx = -1, 1 do
              if (dx ~= 0 or dy ~= 0) and not wall then          -- the first wall holds it: no more reads
                local nt = own[tkey(x + dx, y + dy, z)] and false or tile_at(K, x + dx, y + dy, z)
                if nt == nil then unknown = true elseif nt and nt.shape == 'WALL' then wall = true end
              end
            end
          end
          if not wall and not unknown then out[#out + 1] = {x, y, z} end
        end
      end
    end
  end
  return out
end

function Q.cave_guard(K, P, st, R, ch)
  local mode = M.CFG.cave_check
  if mode == 'off' or mode == false or mode == nil then return false end
  local ok, isl = pcall(Q.cave_risk, K, ch)
  if not ok or type(isl) ~= 'table' or #isl == 0 then return false end
  local at = isl[1]
  local rec = S.rt.cv[P.id]
  if type(rec) ~= 'table' then rec = {}; S.rt.cv[P.id] = rec end
  rec.chunk, rec.n, rec.at, rec.t = P.chunk, #isl, string.format('%d,%d,%d', at[1], at[2], at[3]), now(K)
  rec.pos = {ch.pos[1], ch.pos[2], ch.pos[3]}
  if R.cave_c ~= P.chunk then
    R.cave_c = P.chunk
    K.log('warn', '%s %s chunk %d: %d free-hanging floor tile(s) (first %s) lie above the hole this dig opens: a cave-in risk%s',
          P.id, st.label, P.chunk, #isl, rec.at, mode == 'block' and '; the project is blocked (bp.cancel or place it elsewhere)' or '')
  end
  dirty()
  if mode == 'block' then
    set_blocked(K, P, 'cavein_risk')
    return true
  end
  return false
end

-- BUG-522 (care's DEATH report of a CAVEIN): the projects whose dig lay within `r` tiles (xy) and one level of pos, newest first:
-- {{proj, stage, chunk, dist, days, risk}}; risk = a free-hanging floor was seen above one of its chunks. Read-only.
function M.dig_near(K, pos, r)
  local out = {}
  if type(pos) ~= 'table' then return out end
  local px, py, pz = int(pos[1] or pos.x), int(pos[2] or pos.y), int(pos[3] or pos.z)
  if not (px and py and pz) then return out end
  r = int(r) or 12
  local t = now(K)
  for _, P in ipairs(S.pd.list) do
    local d = doc(K, P.id)
    if d and P.done ~= 1 or (d and (t - (int(P.since) or t)) < 30 * DAY) then
      local bb = project_bbox(P.id, d)
      if bb and pz >= bb[3] - 1 and pz <= bb[6] + 1 then
        local dx = math.max(bb[1] - px, 0, px - bb[4])
        local dy = math.max(bb[2] - py, 0, py - bb[5])
        local dist = math.max(dx, dy)
        if dist <= r then
          local cv = S.rt.cv[P.id]
          out[#out + 1] = {proj = P.id, tpl = P.tpl, stage = P.stage, dist = dist, risk = type(cv) == 'table' and cv.at or nil,
                           days = (t - (int(P.since) or t)) // DAY}
        end
      end
    end
  end
  table.sort(out, function(a, b) if a.dist ~= b.dist then return a.dist < b.dist end return a.proj < b.proj end)
  while #out > 5 do table.remove(out) end
  return out
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
    if Q.cave_guard(K, P, st, R, ch) then return false end    -- BUG-522
  end
  local wet = 0
  if st.mode == 'build' and P.tpl ~= 'plug' then              -- BUG-514: no bed on a tile that holds water
    ch, wet = Q.wet_cells(K, P, st, ch)
    if wet > 0 and #ch.cells == 0 then
      if R.ra ~= 1 then R.uns = R.uns + wet end
      P.chunk = P.chunk + 1; moved(K, R); dirty(); return true
    end
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
  if st.mode == 'dig' then p.priority, p.marker = dprio(P), Q.aq_marker(P) end    -- FR-95: damp marker in observe mode
  local pre = st.mode == 'build' and pre_occupied(K, ch, R, P) or 0
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
      else R.uns = R.uns + math.max(0, (int(stats.build_unsuitable) or 0) - pre - walls) + bad + wet end
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
-- `orders` call made (ids n0 .. the next id - 1) move to the top of the work orders, the player's up arrow.
-- BUG-203 (live Earthboat: the P0 core's door, bed and block orders stood at places 82-88 of 89, behind imported library
-- orders that filled every shop): every project's piece orders go to the top the same way
local function orders_first(K, P, st, n0)
  local n1 = next_order_id()
  if not (n0 and n1 and n1 > n0) then return end
  local ids = {}
  for id = n0, math.min(n1 - 1, n0 + 31) do ids[#ids + 1] = id end
  local ok, n = K.act.order_top(ids)
  if ok and (int(n) or 0) > 0 then
    K.log('info', '%s %s: %d manager orders moved to the top of the work orders (%s first)', P.id, st.label, n,
          SEALS[P.tpl] and 'seal' or 'project')
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
  -- BUG-203: every project's orders go first, but never above an open seal's (seal first leads)
  local n0 = n > 0 and (SEALS[P.tpl] or not (S.focus and S.focus.lead)) and next_order_id() or nil
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
                  suites = true, grand_dining = true, grand_tavern = true, grand_temple = true, deepcore = true,  -- FR-102/103
                  seal = 'kind', plug = 'kind', repair = 'kind', explore = 'kind', aqshaft = 'kind'}

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
  local okw, errw = pcall(Q.keep_walls, K, P)  -- BUG-458: forget() drops the records, the walls stay: LOCKED_OUT still looks at them
  if not okw then K.log('warn', '%s: wall record not kept: %s', P.id, trunc(errw, 120)) end
  K.persist.set('bp.' .. P.id, nil)
  S.rt.p[P.id] = nil
  forget(P.id)
  local rocks = P.tpl == 'explore' and Q.shaft_rocks(xr) or nil           -- BUG-584: the rock the probe passed
  K.emit('PROJECT_DONE', 'B', trunc(P.id .. ' (' .. P.tpl .. ') done' .. (wn and ('; ' .. wn) or '') ..
                                    (P.refused and ('; refused by quickfort at ' .. P.refused .. ' (tile occupied)') or '') ..
                                    (rocks and ('; rock: ' .. table.concat(rocks, ', ')) or '') ..
                                    (pre and '' or ('; stage ' .. (first - 1) .. ' never ran: not counted')), 200),
         {proj = P.id, tpl = P.tpl, walled = wl, pre = (not pre) and (first - 1) or nil, rocks = rocks and json.array(rocks) or nil})
  K.log('info', '%s (%s) done', P.id, P.tpl)  -- BUG-039: kern.log names every project that leaves the open list
  K.flush()
  dirty()
end

-- seal first / rebuild (Run 11 siege 8): a paused project's applied dig chunks are still dug by the miners: a hazard
-- on one of their revealed tiles stops it as the measure does (breach src 'tile'); no progress, no new chunk
local function hold_watch(K, P, d, st, R)
  if st.mode ~= 'dig' or P.chunk == 0 then return 'done' end
  S.aqo = M.AQ.observing(S.rt, P.id) and P or nil      -- FR-95
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

---------------------------------------------------------------- FR-95: the aquifer pass (lua/dfllm/aqshaft.lua)
Q.SHAFT = {explore = true, aqshaft = true}      -- templates whose stair column the plug walls
-- what aqshaft.lua may do through the runner (made per call: the closures are the runner's own helpers)
function Q.aqx(K)
  return {
    rt = S.rt, now = function() return now(K) end, room = qf_room, dirty = dirty, flush = K.flush,
    tile = function(x, y, z) return tile_at(K, x, y, z) end,
    qf = function(p) return qf(K, p) end,
    emit = function(t, c, m, dd) return K.emit(t, c, trunc(m, 200), dd) end,
    log = function(...) return K.log(...) end,
    moved = function(P) moved(K, R_of(K, P)) end,
    block = function(P, why) set_blocked(K, P, why) end,
    next = function(P, d) stage_done(K, P, d, d.stages[P.stage + 1], R_of(K, P)) end,
    finish = function(P, d) finish(K, P, d) end,
    plug = function(P, d, pos, why)
      plug(K, P, d, why or 'heavy_aquifer', pos, 0)
      local r = S.rt.cav[P.id]
      return type(r) == 'table' and r.plug ~= '' and r.plug or nil
    end,
    level = function(z) Q.aq_level(K, z) end,
    aq_known = function(z)                     -- BUG-412: the manifest's aquifer levels (damp or wet seen)
      for _, v in ipairs(type(S.rt.aql) == 'table' and S.rt.aql or {}) do if v == z then return true end end
      return false
    end,
    heavy_known = function(z, span) return Q.heavy_known(z, span) end,      -- BUG-414: a recorded heavy level near z
    aq_below = function(z) return Q.aq_below(z) end,                        -- BUG-490: every known aquifer level under z
    hv = function(z) Q.hv_level(K, z) end,                                  -- BUG-414: record z as a heavy level
    -- BUG-662: a ring wall nobody built stopped the shaft: manifest breach `ring_wall` (bp sites aqshaft counts them, NOT a heavy level);
    -- a ring wall that stood drops them all (the material exists)
    ring_stop = function(P, pos) M.note_breach(K, P.id, P.tpl, 'ring_wall', pos) end,
    ring_ok = function() Q.ring_ok(K) end,
    unreachable = function(P, d)               -- BUG-412: no citizen reaches the stage's dig (BUG-352's test)
      local ok, tl = pcall(Q.unreachable, K, P, d, S.rt.p[P.id])
      return ok and tl ~= nil
    end,
    mat = function(n)
      local ok, via, why = K.call('economy', 'mat_for', 'wall', n)
      if not ok then return nil, 'no economy' end
      return via, why
    end,
    wall_alt = function(P)                     -- BUG-736: the wall's material when no stone is free: logs (buildingplan boulders off), else ore / flux
      local ok, t = K.call('economy', 'wall_alt')
      return ok and type(t) == 'string' and t or nil
    end,
    builders = function()                      -- BUG-745: citizens with the construction labor (nil: unknown)
      local ok, n = K.call('economy', 'wall_builders')
      return ok and math.tointeger(n) or nil
    end,
    wall_stock = function()                    -- BUG-443: the COUNT of free blocks, boulders and logs for walls (nil: unknown)
      local ok, st = K.call('economy', 'wall_stock')
      return ok and type(st) == 'table' and st or nil
    end,
    need = function(n, who)                    -- BUG-443: the ring's walls are a rock need (a stone dig, the caravans, trade.want)
      return K.call('economy', 'need', 'rock', n, who, 14)
    end,
    own = function(id)
      local P = find(id)
      local d = P and P.done ~= 1 and doc(K, id)
      return d and own_tiles(P, d) or nil
    end,
    live = function(id) local P = find(id); return P ~= nil and P.done ~= 1 end,
  }
end

-- BUG-414: heavy aquifer levels. m.runner hvl (<= 32 absolute z, sorted) keeps every level a dig met heavy water on; the
-- breach records (m.runner dz, why heavy_aquifer: a fortcore that stopped on one counts) are read too. A level is heavy-known
-- for z when a recorded one lies within `span` levels (an aquifer layer is rarely one level thick)
function Q.hv_level(K, z)
  z = int(z)
  if not z then return end
  Q.aq_level(K, z)                          -- BUG-490: a heavy level is an aquifer level of the manifest too (one list)
  S.rt.hvl = type(S.rt.hvl) == 'table' and S.rt.hvl or {}
  for _, v in ipairs(S.rt.hvl) do if v == z then return end end
  table.insert(S.rt.hvl, z)
  table.sort(S.rt.hvl)
  while #S.rt.hvl > 32 do table.remove(S.rt.hvl, 1) end
  dirty()
end

function Q.heavy_known(z, span)
  z, span = int(z), int(span) or 0
  if not z then return false end
  for _, v in ipairs(type(S.rt.hvl) == 'table' and S.rt.hvl or {}) do
    if math.abs(v - z) <= span then return true end
  end
  for _, c in ipairs(type(S.rt.dz) == 'table' and S.rt.dz or {}) do
    if type(c) == 'table' and c.why == 'heavy_aquifer' and type(c.pos) == 'table' and int(c.pos[3])
       and math.abs(int(c.pos[3]) - z) <= span then return true end
  end
  return false
end

-- BUG-490 (Run 16a i1 Basementflew: the manifest said aquifer_levels [119,126,127] while bp sites named z123 and the heavy rings
-- z120/z116): the ONE list of aquifer levels is the manifest's (m.runner aql) joined with every recorded heavy level (hvl and the
-- heavy_aquifer breaches); aq_below(z) = those under z, descending (the next ones a shaft meets)
function Q.aq_below(z)
  z = int(z)
  local seen, out = {}, {}
  local function add(v)
    v = int(v)
    if v and z and v < z and not seen[v] then seen[v] = true; out[#out + 1] = v end
  end
  for _, v in ipairs(type(S.rt.aql) == 'table' and S.rt.aql or {}) do add(v) end
  for _, v in ipairs(type(S.rt.hvl) == 'table' and S.rt.hvl or {}) do add(v) end
  for _, c in ipairs(type(S.rt.dz) == 'table' and S.rt.dz or {}) do
    if type(c) == 'table' and c.why == 'heavy_aquifer' and type(c.pos) == 'table' then add(c.pos[3]) end
  end
  table.sort(out, function(a, b) return a > b end)
  return out
end

-- the manifest's `aquifer_levels` (levels seen damp or wet, revealed tiles only; bp sites keeps rooms off them and off
-- the level below them; shafts may pass), m.runner aql (<= 64, sorted)
function Q.aq_level(K, z)
  z = int(z)
  if not z then return end
  S.rt.aql = type(S.rt.aql) == 'table' and S.rt.aql or {}
  for _, v in ipairs(S.rt.aql) do if v == z then return end end
  table.insert(S.rt.aql, z)
  table.sort(S.rt.aql)
  while #S.rt.aql > 64 do table.remove(S.rt.aql, 1) end
  local man = K.manifest()
  local list = {}
  for i, v in ipairs(S.rt.aql) do list[i] = v end
  man.aquifer_levels = list
  K.persist.set('manifest', man)
  dirty()
end

-- BUG-291 (Run 15 Inkintense: a sealed pit full of seepage on z130, 'no aquifer level known'): water's scan saw a revealed
-- tile with the aquifer flag beside (or under) water on level z; true when z is new to the manifest's aquifer_levels
function M.aq_seen(K, z)
  z = int(z)
  if not z then return false end
  for _, v in ipairs(type(S.rt.aql) == 'table' and S.rt.aql or {}) do if v == z then return false end end
  Q.aq_level(K, z)
  return true
end

-- BUG-662: the `ring_wall` breach records (an aqshaft whose ring wall nobody built) are dropped once any ring wall stands
function Q.ring_ok(K)
  if type(S.rt.dz) ~= 'table' then return end
  local n = 0
  for i = #S.rt.dz, 1, -1 do
    if type(S.rt.dz[i]) == 'table' and S.rt.dz[i].why == 'ring_wall' then table.remove(S.rt.dz, i); n = n + 1 end
  end
  if n > 0 then M.publish_breaches(K); dirty() end
end

function M.hv_level(K, z) return Q.hv_level(K, z) end       -- BUG-490: tests / callers record a heavy level
function M.aq_below(z) return Q.aq_below(z) end

function Q.aq_marker(P) return (P.tpl == 'aqshaft' or M.AQ.observing(S.rt, P.id)) and {damp = true} or nil end

-- lost(): a designation DF took. A damp cancel (or, in observe mode, one without a report the log search finds) is no
-- park: the chunk is designated again with the damp marker, at most aqshaft redig times a chunk (then the old stop)
function Q.aq_lost(K, P, R, ci, ch, t, why)
  if M.CFG.damp_dig or not M.AQ.CFG.on or P.tpl == 'plug' then return false end
  local obs = M.AQ.observing(S.rt, P.id)
  if not (why == 'damp' or (obs and (why == nil or why == 'unknown'))) then return false end
  -- BUG-192 (live i4): an observing project adds the tile too (A.tick smooths around r.pts; AQ_OBSERVE only when new)
  if not M.AQ.observe(Q.aqx(K), P, {t[1], t[2], t[3]}, 'cancel') then return false end
  R.aqr = obj(R.aqr)
  local sk = tostring(ci)
  if (int(R.aqr[sk]) or 0) >= M.AQ.CFG.redig then return false end
  if not qf_room() then return true end
  R.aqr[sk] = (int(R.aqr[sk]) or 0) + 1
  qf(K, {mode = 'dig', data = chunk_data(ch), pos = ch.pos, priority = dprio(P), marker = {damp = true}})
  K.log('warn', '%s chunk %d: damp stone at %d,%d,%d designated again with the damp marker (observe, %d/%d)', P.id, ci - 1,
        t[1], t[2], t[3], R.aqr[sk], M.AQ.CFG.redig)
  dirty()
  return true
end

-- fortcore p.aquifer = pass: its digs wait for a passed aqshaft, then run in observe mode
function Q.aq_wait(K, P, d)
  local p = type(d) == 'table' and type(d.params) == 'table' and d.params or {}
  if P.tpl ~= 'fortcore' or p.aquifer ~= 'pass' then return nil end
  -- BUG-723: the shaft must have reached the core's deepest level (a shaft that ended above it has not seen the layers there)
  local lowest
  for _, st in ipairs(type(d.stages) == 'table' and d.stages or {}) do
    for _, ch in ipairs(st.chunks or {}) do
      for _, c in ipairs(ch.cells or {}) do
        local z = ch.pos[3] + c[3]
        if not lowest or z < lowest then lowest = z end
      end
    end
  end
  local ok, short = M.AQ.passed(S.rt, lowest)
  if not ok then
    if short and lowest then
      return string.format('shaft ends z%d, core z%d', short.bot, lowest)    -- the state row cuts at 40 chars
    end
    return 'aquifer: waits for an aqshaft pass'
  end
  if not M.AQ.observing(S.rt, P.id) then M.AQ.observe(Q.aqx(K), P, nil, 'pass') end
  return nil
end

-- boot: a project an older kernel parked at breach:damp (no cavern plug record) runs again in observe mode, its dig stage
-- applied again (the stop undid it)
function Q.aq_boot(K)
  if not M.AQ.CFG.on then return end
  for _, P in ipairs(S.pd.list) do
    if P.done ~= 1 and P.blocked == 'breach:damp' and S.rt.cav[P.id] == nil and S.rt.aq[P.id] == nil then
      local d, b = doc(K, P.id), S.rt.br[P.id]
      local st = d and d.stages[P.stage + 1]
      if st and st.mode == 'dig' and M.AQ.observe(Q.aqx(K), P, type(b) == 'table' and b.pos or nil, 'resume') then
        P.blocked, P.since, P.chunk = '', now(K), 0
        S.rt.p[P.id] = nil
        M.drop_breach(K, P.id)                     -- BUG-130's manifest.breaches: this core digs again, no re-site
        K.log('info', '%s (%s): breach:damp resumed in observe mode (FR-95)', P.id, P.tpl)
        dirty()
      end
    end
  end
end

-- BUG-226 (live i3 Earthboat: explores y380s0b0..s3b0 were placed at one plan apply with depth 12, z135-z123; the first
-- broke into a cavern at z123 and the kernel noted it in manifest.caverns, then s2b0 started and broke into z123 again,
-- BREACH_STOP, PROJECT_BLOCKED A): before an explore's dig stage designates its first chunk, the cavern levels the
-- manifest knows are held against the stage's z-range. A level inside it cuts the shaft to stop one level above it
-- (the chunks below dropped, the new bottom stair an up stair, params.depth = anchor z - cavern z - 1); when that leaves
-- less than 2 levels the explore is blocked (why cavern_known) with one PROJECT_BLOCKED (A) naming bp.cancel.
-- Returns nil (nothing known), 'cut' or 'park'.
function Q.explore_cav(K, P, d, st)
  if P.tpl ~= 'explore' or st.mode ~= 'dig' or P.chunk ~= 0 then return nil end
  local man = K.manifest()
  local cav = type(man) == 'table' and type(man.caverns) == 'table' and man.caverns or {}
  local top, low
  for _, ch in ipairs(st.chunks) do
    for _, c in ipairs(ch.cells) do
      local z = (int(ch.pos[3]) or 0) + (int(c[3]) or 0)
      top, low = math.max(top or z, z), math.min(low or z, z)
    end
  end
  local hit
  for _, c in ipairs(top and cav or {}) do
    local z = type(c) == 'table' and int(c[3]) or nil
    if z and z >= low and z <= top and (hit == nil or z > hit) then hit = z end
  end
  if not hit then return nil end
  local az = int(type(d.anchor) == 'table' and d.anchor[3]) or top
  local depth = az - hit - 1
  local label = trunc(st.label, 24)
  if depth < 2 then
    set_blocked(K, P, 'cavern_known')
    S.rt.pb[P.id] = CAD.mark(K.now(), {P.id .. ':' .. label}, {P.blocked})    -- blocked_event: no second wake for it
    local msg = string.format('%s (explore) blocked: cavern_known: cavern level z%d (manifest caverns) lies in its shaft '
                              .. 'z%d-%d; cancel: dfllm cmd bp.cancel \'{"proj":"%s"}\'', P.id, hit, top, low, P.id)
    K.log('warn', '%s', msg)
    K.emit('PROJECT_BLOCKED', 'A', trunc(msg, 200), {proj = P.id, tpl = P.tpl, stage = label, why = P.blocked, ticks = 0})
    return 'park'
  end
  local chunks, bottom = {}, nil
  for _, ch in ipairs(st.chunks) do
    local cells = {}
    for _, c in ipairs(ch.cells) do
      local z = (int(ch.pos[3]) or 0) + (int(c[3]) or 0)
      if z > hit then
        local nc = {c[1], c[2], c[3], c[4]}
        cells[#cells + 1] = nc
        if tostring(c[4]):match('^[ij]') and (bottom == nil or z < bottom.z) then bottom = {z = z, c = nc} end
      end
    end
    if #cells > 0 then
      local n = copy(ch)
      n.cells = cells
      chunks[#chunks + 1] = n
    end
  end
  if bottom and bottom.c[4]:sub(1, 1) == 'i' then bottom.c[4] = 'u' .. bottom.c[4]:sub(2) end
  st.chunks = chunks
  if type(d.params) == 'table' then d.params.depth = depth end
  K.persist.set('bp.' .. P.id, d)
  for k in pairs(S.tiles) do if k:sub(1, #P.id + 1) == P.id .. '/' then S.tiles[k] = nil end end
  if S.own then S.own[P.id] = nil end
  S.bbox[P.id], S.meas[P.id] = nil, nil
  if S.cl then S.cl[P.id] = nil end
  if S.xdoc then S.xdoc[P.id] = nil end
  S.rt.xs[P.id] = nil                             -- the shaft record is noted again with the new bottom
  dirty()
  K.log('info', '%s (explore): cavern level z%d known (manifest caverns): the shaft stops at z%d (depth %d, was z%d)',
        P.id, hit, hit + 1, depth, low)
  return 'cut'
end

-- meas: measure-only pass of a stalled project without a slot (no orders, no applies); hold: a paused project (seal
-- first, rebuild): measured, never ordered or applied (its next stage waits), its applied dig chunks watched
local function work(K, P, meas, hold)
  local d = doc(K, P.id)
  if not d then set_blocked(K, P, 'bp_missing'); return 'done' end
  if P.tpl == 'aqshaft' then return M.AQ.work(Q.aqx(K), P, d, meas, hold) end    -- FR-95: the lined shaft
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
      if Q.explore_cav(K, P, d, st) == 'park' then return 'done' end    -- BUG-226: a known cavern level in the shaft
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
-- BUG-471 (Run 16a i1 Basementflew y372-377: fortcore stage 1 and stage 3 cancelled after AQ_HEAVY / breach:water; the manifest
-- kept 'Tiefe+' z123 and the civilians' stair 98,87,124, nothing stood there, the refuge hatch was 'unreachable' 5x, plan check
-- demanded the seal every year, refuge_sep / civ_sep stayed red): what a cancelled project's fragment put into the manifest
-- (refuge and its burrow, stairs, zones, rooms, bridges, stations) leaves it again where the tiles are still undug rock.
-- undug(x, y, z) -> true only for a tile known to be solid; dug or unknown parts stay. Returns the names removed.
function M.unmerge_manifest(man, frag, undug)
  local out = {}
  if type(man) ~= 'table' or type(frag) ~= 'table' then return out end
  local function same(a, b) return key_of(a) == key_of(b) end
  local function solid(x, y, z) return undug(x, y, z) == true end
  local function box_solid(b)
    return type(b) == 'table' and #b >= 6 and solid(b[1], b[2], b[3]) and solid(b[4], b[5], b[6])
  end
  local fr = frag.refuge
  if type(fr) == 'table' and type(man.refuge) == 'table' and same(man.refuge, fr) and type(fr.anchor) == 'table'
      and solid(fr.anchor[1], fr.anchor[2], fr.anchor[3]) then
    man.refuge = nil
    out[#out + 1] = 'refuge'
    local bn = fr.burrow
    if type(bn) == 'string' and type(man.burrows) == 'table' and type(frag.burrows) == 'table' and frag.burrows[bn]
        and type(man.burrows[bn]) == 'table' and man.burrows[bn].role == 'refuge' then
      man.burrows[bn] = nil
      out[#out + 1] = 'burrow ' .. bn
    end
  end
  for kind, list in pairs(type(frag.stairs) == 'table' and frag.stairs or {}) do
    local have = type(man.stairs) == 'table' and man.stairs[kind]
    if type(have) == 'table' and type(list) == 'table' then
      local keep, n = {}, 0
      for _, e in ipairs(have) do
        local mine = false
        for _, f in ipairs(list) do if same(e, f) then mine = true end end
        if mine and type(e) == 'table' and #e >= 4 and solid(e[1], e[2], e[3]) then n = n + 1     -- its foot (the refuge level) is undug
        else keep[#keep + 1] = e end
      end
      if n > 0 then man.stairs[kind] = keep; out[#out + 1] = string.format('%d stair(s) %s', n, tostring(kind)) end
    end
  end
  for kind, list in pairs(type(frag.zones) == 'table' and frag.zones or {}) do
    local have = type(man.zones) == 'table' and man.zones[kind]
    if type(have) == 'table' and type(list) == 'table' then
      local keep, n = {}, 0
      for _, e in ipairs(have) do
        local mine = false
        for _, f in ipairs(list) do if same(e, f) then mine = true end end
        if mine and box_solid(e) then n = n + 1 else keep[#keep + 1] = e end
      end
      if n > 0 then man.zones[kind] = keep; out[#out + 1] = string.format('%d zone box(es) %s', n, tostring(kind)) end
    end
  end
  if type(frag.rooms) == 'table' and type(man.rooms) == 'table' then
    local ids = {}
    for _, f in ipairs(frag.rooms) do if type(f) == 'table' and f.id then ids[f.id] = f end end
    local keep, n = {}, 0
    for _, e in ipairs(man.rooms) do
      local f = type(e) == 'table' and ids[e.id]
      if f and same(e, f) and box_solid(e.bbox) then n = n + 1 else keep[#keep + 1] = e end
    end
    if n > 0 then man.rooms = keep; out[#out + 1] = string.format('%d room(s)', n) end
  end
  for _, key in ipairs({'bridges', 'stations'}) do
    local fk, mk = frag[key], man[key]
    if type(fk) == 'table' and type(mk) == 'table' then
      for name, f in pairs(fk) do
        if type(mk[name]) == 'table' and same(mk[name], f) then
          local at = key == 'bridges' and type(f) == 'table' and f.fp or f      -- a bridge's footprint box / a station's tile
          local gone = false
          if type(at) == 'table' and #at >= 6 then gone = box_solid(at)
          elseif type(at) == 'table' and #at >= 3 then gone = solid(at[1], at[2], at[3]) end
          if gone then mk[name] = nil; out[#out + 1] = key:sub(1, -2) .. ' ' .. tostring(name) end
        end
      end
    end
  end
  return out
end

-- a tile of the running map: true for a solid wall tile (undug rock or soil), false for anything else, nil unknown (not revealed)
function Q.undug_tile(K, x, y, z)
  local v = tile_at(K, x, y, z)
  if v == nil or v.c == nil then return nil end
  return v.c == '#' or v.c == 'S'
end

local function remove(K, P)
  local d0 = doc(K, P.id)
  if P.done ~= 1 and type(d0) == 'table' and type(d0.manifest) == 'table' then       -- BUG-471
    local man = K.manifest()
    local okm, gone = pcall(M.unmerge_manifest, man, d0.manifest, function(x, y, z) return Q.undug_tile(K, x, y, z) end)
    if okm and #gone > 0 then
      K.persist.set('manifest', man)
      K.log('info', '%s (%s) cancelled: its undug manifest parts left the manifest (%s)', P.id, P.tpl, table.concat(gone, ', '))
    end
  end
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
  if Q.remove_unbuilt(K, P, R) == 'yield' then return 'yield' end   -- BUG-314: a plain cancel's planned buildings
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
      if ch then
        local okq, sq = qf(K, {mode = st.mode, data = chunk_data(ch), pos = ch.pos, command = 'undo'})
        if u.plain and okq and type(sq) == 'table' then u.n = (int(u.n) or 0) + (int(sq.dig_designated) or 0) end
      end
      dirty()
    end
  end
  if u and u.plain then                       -- BUG-353: what a plain cancel took back of the project's own digging
    K.log('info', '%s (%s) cancelled: %d dig designation(s) of its applied chunks removed (tiles not dug yet)', P.id, P.tpl,
          int(u.n) or 0)
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
  -- FR-95: water in the own dug tiles of a project in observe mode (>= 4/7, or a rising flow) is a heavy aquifer
  if why == 'water' and M.AQ.observing(S.rt, P.id) then
    local v = pos and tile_at(K, pos[1], pos[2], pos[3])
    local f = v and int(v.flow) or 7
    M.AQ.heavy_obs(Q.aqx(K), P, pos, f, f >= M.AQ.CFG.heavy and 'flow' or 'rising')
    why = 'heavy_aquifer'
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
  if why == 'heavy_aquifer' and dd.pos then Q.hv_level(K, dd.pos[3]) end   -- BUG-414: the next shaft rings that level
  M.note_breach(K, P.id, P.tpl, why, dd.pos)                              -- BUG-130: manifest.breaches
  K.emit('BREACH_STOP', 'B', breach_msg(P.id, why, src, was, n, ex and ex.state), dd)
  K.flush()
  dirty()
  if (CAVERN[why] or why == 'heavy_aquifer') and dd.pos and d then plug(K, P, d, why, dd.pos, n, ex) end
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

-- BUG-314 (Run 15 Earthboat y382: after `bp.cancel proj=y373s1b0` the refuge hatch's DF job 8095 stayed; the seal placed
-- again adopted it (pre_occupied) and stood 'no builder' as before; Drillchamber y377 the same with job 10421): the cells
-- of the project's current stage whose building it placed or adopted (R.b, R.c) is not built yet, as {x, y, z, cell text}
-- for one quickfort undo each (the player's remove building on a planned one: its construction job goes with it). Built
-- pieces stay; a building the project does not own is never touched
function Q.unbuilt_cells(K, P, d, R)
  local out = {}
  local st = d and d.stages[P.stage + 1]
  if not (st and st.mode == 'build') or R.noid == 1 then return out end
  local own = {}
  for _, id in ipairs(R.b or {}) do own[id] = true end
  for _, id in ipairs(R.c or {}) do own[id] = true end
  local find = dfhack.buildings and dfhack.buildings.findAtTile
  if not find then return out end
  for _, ch in ipairs(st.chunks) do
    for _, cell in ipairs(ch.cells) do
      local tl = {}
      cell_tiles(ch, cell, tl)
      for _, t in ipairs(tl) do
        local ok, b = pcall(find, t[1], t[2], t[3])
        if ok and b and own[b.id] and not built(b) then
          out[#out + 1] = {ch.pos[1] + cell[1], ch.pos[2] + cell[2], ch.pos[3] + cell[3], cell[4], b.id}
          break
        end
      end
    end
  end
  return out
end

-- BUG-314: one queued removal of R.rm a call (quickfort undo of the cell); a piece built meanwhile stays. 'yield' while the
-- quickfort budget of this slice is spent, else the number removed
function Q.remove_unbuilt(K, P, R)
  local n = 0
  while type(R.rm) == 'table' and #R.rm > 0 do
    if not qf_room() then dirty(); return 'yield' end
    local c = table.remove(R.rm, 1)
    local b = df.building.find(int(c[5]) or -1)
    if b and not built(b) then
      qf(K, {mode = 'build', data = {[0] = {[0] = {[0] = c[4]}}}, pos = {c[1], c[2], c[3]}, command = 'undo'})
      n = n + 1
    end
    dirty()
  end
  R.rm = nil
  if n > 0 then
    K.log('info', '%s (%s) cancelled: %d unbuilt piece(s) removed with their construction jobs', P.id, P.tpl, n)
  end
  return n
end

-- BUG-353 (Run 16c r16c-w9-18-site97: two bp.cancel + re-place left ~1580 dig designations of the cancelled fortcore
-- projects on z120-124, the fort starved with nothing it could dig): the chunk indices (nearest the last applied first,
-- as a breach undo) of the current stage's dig the project applied, for one quickfort undo each. Quickfort's undo clears
-- the designation of a tile not dug yet and leaves a dug one; only cells of this project's own blueprint are named, so
-- another project's or the player's designations elsewhere stay. {} when the stage is no dig or nothing is applied.
function Q.applied_dig(P, d, R)
  local st = d and d.stages[P.stage + 1]
  if not (st and st.mode == 'dig') then return {} end
  local n = P.chunk
  if R.ra == 1 then n = #st.chunks end
  n = math.min(n or 0, #st.chunks)
  local l = {}
  for ci = n - 1, 0, -1 do l[#l + 1] = ci end
  return l
end

local function cancel(K, P, with_undo)
  local R, d = R_of(K, P), doc(K, P.id)
  if not with_undo then
    if R.undo and d then return set_blocked(K, P, 'cancel') end   -- finish a breach undo, then remove
    local rm = d and Q.unbuilt_cells(K, P, d, R) or {}             -- BUG-314: its planned buildings and their jobs go
    local ul = d and Q.applied_dig(P, d, R) or {}                  -- BUG-353: and the dig it designated, not dug yet
    if #rm > 0 or #ul > 0 then
      if #rm > 0 then R.rm = rm end
      if #ul > 0 then R.undo = {s = P.stage, l = ul, cancel = 0, plain = true, n = 0} end
      return set_blocked(K, P, 'cancel')
    end
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

-- BUG-347 (Run 15 Guildcleans y386-387, i2: the hospital c1a1a510be3991ea01, the stockroom and gallery_o1 stood 'dig 0%
-- BLOCKED:frozen' through a siege of 150+ days, patient 26739 died of thirst before the hospital was dug): the class gate
-- let only defense projects inside Z3/Z4 run in a SIEGE. Life support now runs in SIEGE (and the hospital, a living
-- project, in ALERT/RECOVERY) when every tile of its current stage lies inside a burrow the sounding civ alert holds the
-- citizens in (the care burrow Pflege+ aside: it reaches patients outside), or inside Kern+ (manifest role kern) while no
-- civ alert sounds in ALERT/RECOVERY (review fix merge16: not in a SIEGE, there it stays frozen): the work stays where the
-- citizens already are, nothing opens a way out. Life support: the hospital,
-- the cistern, the refuge's drink store, and farms / the stockroom while a food or drink emergency holds (S.focus.emerg:
-- seal_first food_d / drink_d, patients without water). A stage with a tile outside stays frozen; the row says how many
-- ('frozen: 9/11 tiles off Kern+'). Measured once per LIFE_TTL ticks and stage (S.life, runtime only).
Q.LIFE = {hospital = true, cistern = true, refuge_drink = true}
Q.LIFE_EMERG = {farms = true, stockroom = true}
Q.CARE_BURROW = 'Pflege+'                         -- water.M.CARE (BUG-330's care burrow)
M.LIFE_TTL = 1200

-- the burrows the work must lie in: the sounding civ alert's (plotinfo.alerts.list[idx].burrows, as water.alert_burrows
-- reads them), else Kern+ in ALERT/RECOVERY only; {burrow...}, the first name. Review fix (merge16): in a SIEGE/BREACH
-- with a silent civ alert (seal 'flee', BUG-031 relax: civ_alert_idx 0) the citizens are not held anywhere, so a
-- Kern+ fallback let a life project run with free citizens hauling material from everywhere (the surface too): none.
function Q.life_burrows(K, m)
  local bs, name = {}, nil
  pcall(function()
    local al = df.global.plotinfo.alerts
    local idx = int(al.civ_alert_idx) or 0
    if idx == 0 or not al.list[idx] then return end
    local ids = {}
    for _, id in ipairs(al.list[idx].burrows) do ids[id] = true end
    for _, b in ipairs(df.global.plotinfo.burrows.list) do
      if ids[b.id] and tostring(b.name) ~= Q.CARE_BURROW then
        bs[#bs + 1] = b
        name = name or tostring(b.name)
      end
    end
  end)
  if #bs == 0 and (m == 'ALERT' or m == 'RECOVERY') then
    local mb = K.manifest().burrows
    for nm, spec in pairs(type(mb) == 'table' and mb or {}) do
      if type(spec) == 'table' and spec.role == 'kern' then
        local ok, b = pcall(dfhack.burrows.findByName, nm)
        if ok and b then bs[#bs + 1] = b; name = name or nm end
      end
    end
  end
  return bs, name
end

-- true when P is life support whose current stage lies wholly inside the life burrows; false, why (nil: no life support)
function Q.life_ok(K, P, d)
  local life = Q.LIFE[P.tpl] or (Q.LIFE_EMERG[P.tpl] and type(S.focus) == 'table' and S.focus.emerg ~= nil)
  if not life or type(d) ~= 'table' or P.stage >= #d.stages then return false end
  local t = now(K)
  S.life = S.life or {}
  local m = K.mode()
  local bs, name = Q.life_burrows(K, m)
  -- a switch of the alert burrow (Kern+ <-> Tiefe+) or of the mode measures again
  local c = S.life[P.id]
  if c and c.si == P.stage and c.bn == name and c.m == m and t >= c.t and t - c.t < M.LIFE_TTL then return c.ok, c.why end
  local ok, why = false, nil
  if #bs == 0 then why = (m == 'ALERT' or m == 'RECOVERY') and 'no alert burrow' or 'no civ alert sounding'
  else
    local tl = stage_tiles(P.id, d, P.stage)
    local n, out = 0, 0
    local pos = {}
    for ci = 1, #d.stages[P.stage + 1].chunks do
      for _, tt in ipairs(tl[ci] or {}) do
        n = n + 1
        pos.x, pos.y, pos.z = tt[1], tt[2], tt[3]
        local inb = false
        for _, b in ipairs(bs) do
          local okb, yes = pcall(dfhack.burrows.isAssignedTile, b, pos)
          if okb and yes == true then inb = true; break end
        end
        if not inb then out = out + 1 end
      end
    end
    ok = n > 0 and out == 0
    if not ok then why = string.format('%d/%d tiles off %s', out, n, tostring(name)) end
  end
  S.life[P.id] = {t = t, si = P.stage, ok = ok, why = why, bn = name, m = m}
  return ok, why
end

-- CONTRACTS §9.8 class gating: ALERT/RECOVERY defense+infra, SIEGE defense inside, beauty PEACE+R1; the cavern plug
-- (Run 11) in every mode: an open way from a cavern matters most in a fight; a lost bridge's repair (seal, BUG-030
-- rebuild policy: params.peace) only in PEACE without a reflex lockdown; BUG-347: life support inside the alert burrow
local function allowed(K, P, d)
  if P.tpl == 'plug' then return true end
  local m = K.mode()
  -- BUG-306: a mood drink nook (one stockpile tile beside the claimed workshop) is life support, as in PEACE in ALERT/RECOVERY
  -- BUG-371 (Run 16d y376: the nook of a thirsty Possessed dwarf stood frozen through a bridge drill and waited 5,000 ticks for
  -- the next run): and in a DRILL, which freezes the rest for a day
  if P.tpl == 'mood_drink' and (m == 'ALERT' or m == 'RECOVERY' or m == 'DRILL') then return true end
  if P.tpl == 'repair' and d and type(d.params) == 'table' and d.params.peace == 1 then
    if m ~= 'PEACE' then return false end
    local ok, why = K.call('reflex', 'holding')
    return not (ok and type(why) == 'string' and why ~= '')
  end
  if m == 'PEACE' then return P.class ~= 'beauty' or beauty_ok(K) end
  if m == 'ALERT' or m == 'RECOVERY' then
    return P.class == 'defense' or P.class == 'infra' or (Q.LIFE[P.tpl] == true and (Q.life_ok(K, P, d)))
  end
  if m == 'SIEGE' then
    if P.class == 'defense' and d ~= nil and inside(K, P, d) then return true end
    return (Q.life_ok(K, P, d))                     -- BUG-347: life support inside the alert burrow
  end
  return false
end

-- seal first (Run 11 siege 8): seal and plug projects before every other, then prio, then age
-- BUG-497 (Run 16d i4 Trumpetrealms y384: no stone, the explore at 40 % 'set aside, no runner slot' for 1700 days behind bedrooms and
-- a tavern): while economy.stone_zero holds (S.stone0, set each scheduling pass) an explore project queues with the hospital
function Q.quarry_first(P)
  return S.stone0 == true and P ~= nil and P.tpl == 'explore'
end

-- BUG-527 (Run 16b i2 Brotherarrow y392-y393: Still and Kitchen missing for years, 89 orders stuck, 7 working adults and every project
-- 'set aside, no runner slot'): a live workshops project that builds a Still or a Kitchen no standing workshop of the map has is an
-- ESSENTIAL shop (S.ess_ids, set each scheduling pass by Q.ess_scan): it sorts with the hospital before the rest, takes a slot even when
-- the fort is short of hands, and is never set aside (idle_keep)
Q.ESSENTIAL = {Still = true, Kitchen = true}
function Q.ess_proj(P) return P ~= nil and (S.ess_ids or {})[P.id] == true end
function Q.ess_scan(K)
  local ids, have = {}, {}
  local okh = pcall(function()
    for _, b in ipairs(df.global.world.buildings.other.WORKSHOP_ANY) do
      if built(b) then have[df.workshop_type[b.type] or ''] = true end
    end
  end)
  if okh then
    for _, P in ipairs(S.pd and S.pd.list or {}) do
      if P.tpl == 'workshops' and Q.live(K, P) then
        local d = doc(K, P.id)
        local m = type(d) == 'table' and type(d.manifest) == 'table' and d.manifest.workshops
        for _, w in ipairs(type(m) == 'table' and m or {}) do
          if type(w) == 'table' and Q.ESSENTIAL[w.type] and not have[w.type] then ids[P.id] = true end
        end
      end
    end
  end
  S.ess_ids = ids
end

local function sorted()
  local r = {}
  for _, P in ipairs(S.pd.list) do if P.done ~= 1 then r[#r + 1] = P end end
  local care = S.care_id                        -- BUG-116: the hospital that runs first, after the seals
  -- BUG-283: a workshops project with a shop a strange mood waits for runs with the hospital, before the rest
  -- (M.mood_types marks them while care's mood check runs); BUG-306: the mood drink nook sorts with them
  table.sort(r, function(a, b)
    -- BUG-497: with no free boulder in the fort the explore shaft that digs to hard stone runs with the hospital, before the rest
    local sa = SEALS[a.tpl] and 0 or (care == a.id or Q.mood_proj(a) or Q.quarry_first(a) or Q.ess_proj(a)) and 1 or 2
    local sb = SEALS[b.tpl] and 0 or (care == b.id or Q.mood_proj(b) or Q.quarry_first(b) or Q.ess_proj(b)) and 1 or 2
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
-- and the depot; the rest pauses. BUG-133 (Run 14 y707: pop 8, the masons', carpenters' and craftsdwarfs' shops lost, the
-- rebuild policy paused the workshops project while 41 ghosts waited for slabs and 69 bodies for coffins): a workshops
-- project of Masons and/or Carpenters only (`tomb_shops`: every other moodable type skipped, nothing added; follow's
-- why=slabs / why=mandatory placement) runs too while care reports ghosts, old bodies or short coffins.
local SUPPLY = {farms = true, cistern = true, stockroom = true, refuge_drink = true}     -- FR-69: the refuge's store
local BEDS = {bedrooms = true, refuge_beds = true}
local FOOD_SHOPS = {Still = true, Kitchen = true, Butchers = true, Fishery = true}
local SEAL_PAUSES = {work = true, beds = true, supply = true}
local REBUILD_RUNS = {seal = true, tombs = true, supply = true, beds = true, repair = true, depot = true, mood = true}
SEAL_PAUSES.tomb_shops = true                    -- BUG-133: the tomb shops are work for the seal and care first
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

-- BUG-356: the startup shops (workshops params.surface = 1: still, kitchen, carpenter, mason on the surface beside the wagon)
-- are the first year's supply: no open seal pauses them
function Q.startup_shops(d)
  local p = type(d) == 'table' and type(d.params) == 'table' and d.params or {}
  return int(p.surface) == 1
end

-- BUG-133: a workshops project of the shops the dead need only (Masons: slabs and stone coffins, Carpenters: wood coffins)
Q.TOMB_SHOPS = {Masons = true, Carpenters = true}
function Q.tomb_shops(d)
  local p = type(d) == 'table' and type(d.params) == 'table' and d.params or {}
  if #words(p.add) > 0 then return false end
  local skip, n = {}, 0
  for _, s in ipairs(words(p.skip)) do skip[s] = true end
  for _, m in ipairs(M.MOODABLE) do
    if not skip[m] then
      if not Q.TOMB_SHOPS[m] then return false end
      n = n + 1
    end
  end
  return n > 0
end

-- BUG-133: what care reports for the dead (ghosts, bodies unburied too long, short coffins): the tomb shops are needed
function Q.dead_need(K)
  local cv = K.view().care
  if type(cv) ~= 'table' then return false end
  local cof = type(cv.coffins) == 'table' and cv.coffins or {}
  return (int(cv.ghosts) or 0) > 0 or (int(cv.corpses_old) or 0) > 0 or (int(cof.short) or 0) > 0
end

local function kind_of(P, d)
  local t = P.tpl
  if SEALS[t] then return 'seal' end
  if t == 'tombs' or t == 'depot' or t == 'explore' then return t end   -- DECISIONS 4: the ore search never rests
  if t == 'tradepost' then return 'depot' end                           -- BUG-488: the trade pile is part of the depot (no seal pauses it)
  if SUPPLY[t] or (t == 'workshops' and (food_shops(d) or Q.startup_shops(d))) then return 'supply' end
  if t == 'office' and Q.startup_shops(d) then return 'supply' end    -- BUG-396: the surface office; the manager validates the brews
  if t == 'workshops' and Q.tomb_shops(d) then return 'tomb_shops' end
  if BEDS[t] then return 'beds' end
  if t == 'repair' then
    local p = type(d) == 'table' and type(d.params) == 'table' and d.params or {}
    return (p.peace == 1 and p.cl ~= 1) and 'defense' or 'repair'     -- BUG-081: a closure is a repair, not a bridge
  end
  if t == 'mood_drink' or t == 'stonedig' then return 'mood' end      -- BUG-081: a drink for a mood dwarf, never paused; BUG-393: its stone
  if t == 'workshops' and Q.mood_shop(d) then return 'mood' end       -- BUG-283: a shop a strange mood waits for
  if t == 'aqshaft' then return 'aq' end              -- FR-95: an open aquifer level is never paused by seal or care first
  return P.class == 'defense' and 'defense' or 'work'
end

-- BUG-273 (Run 15 Drillchamber y372: the seal's door 102,124,144 waited for buildingplan 'door x1 (0 free, 3 ordered)', the
-- door orders for a Carpenter's workshop that stood in the paused workshops project; 37 orders 'workshop missing', SEAL_STUCK
-- after 20 days, food 27 d, 9 of 14 idle). A workshops project that builds a Carpenter's or a Mason's workshop is the seal's
-- enabler and is never paused by it while the lead seal has an open door or hatch whose building waits for its item
-- (economy.build_state who = buildingplan) and neither shop stands built (the workshop list; unreadable: no claim).
-- Once a run per focus (f.dn: the piece, or false)
Q.DOOR_SHOPS = {'Carpenters', 'Masons'}
function Q.door_shop(d)
  local p = type(d) == 'table' and type(d.params) == 'table' and d.params or {}
  local want = {}
  for _, a in ipairs(words(p.add)) do want[a] = true end
  local skip = {}
  for _, s in ipairs(words(p.skip)) do skip[s] = true end
  for _, m in ipairs(M.MOODABLE) do if not skip[m] then want[m] = true end end
  for _, s in ipairs(Q.DOOR_SHOPS) do if want[s] then return true end end
  return false
end
function Q.door_need(K, f)
  if f.dn ~= nil then return f.dn end
  f.dn = false
  local have = {}
  local okh = pcall(function()
    for _, b in ipairs(df.global.world.buildings.other.WORKSHOP_ANY) do
      if built(b) then have[df.workshop_type[b.type] or ''] = true end
    end
  end)
  if not okh then return false end
  for _, s in ipairs(Q.DOOR_SHOPS) do if have[s] then return false end end
  for _, nm in ipairs(f.names or {}) do
    local kind, x, y, z = nm:match('^(%a+) (%-?%d+),(%-?%d+),(%-?%d+)$')
    if kind == 'door' or kind == 'hatch' then
      local ok, bs = K.call('economy', 'build_state', tonumber(x), tonumber(y), tonumber(z))
      if ok and type(bs) == 'table' and bs.who == 'buildingplan' then f.dn = nm; return nm end
    end
  end
  return false
end

-- BUG-275 (same fort: food 27 d, drink 20 d, no kitchen, no still while the seal paused farms and food shops): food and
-- drink projects run beside an open seal while food or drink days are below seal_first.supply_d (60), not only in an
-- emergency (food_d / drink_d 30)
Q.SUPPLY_D = 60
function Q.low_supply(K, c)
  local st = K.view().stock
  if type(st) ~= 'table' then return nil end
  local fd, dd = int(st.food_d), int(st.drink_d)
  if fd and fd < c.supply_d then return string.format('food %d d < %d', fd, c.supply_d) end
  if dd and dd < c.supply_d then return string.format('drink %d d < %d', dd, c.supply_d) end
end

-- BUG-276 (Run 15 Guildcleans y375: a new opening 109,94,130 open 5 days, its door unsuitable and walled, while the open
-- perimeter held max-pop at 35): the seal names that it holds the pop cap (readiness.ceiling why open_perimeter), in the
-- seal-first kern.log line and SEAL_STUCK. Nil while the cap is not held
function Q.perim_hold(K)
  local rv = K.view().ready
  if type(rv) ~= 'table' or not int(rv.pd) then return nil end
  local ok, cap, why = K.call('readiness', 'ceiling', int(rv.lvl) or 0)
  if not (ok and why == 'open_perimeter' and int(cap)) then return nil end
  return string.format('pop cap %d held by the open perimeter (%d d: %s)', int(cap), int(rv.pd), trunc(rv.pw or '?', 40))
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
             esc = nat(sf.esc_days, 1, 60, M.CFG.seal_esc_days) * DAY,                    -- BUG-336
             lead = nat(sf.lead_days, 1, 400, M.CFG.seal_lead_days) * DAY,               -- BUG-472
             food_d = nat(sf.food_d, 0, 400, M.CFG.emerg_food_d), drink_d = nat(sf.drink_d, 0, 400, M.CFG.emerg_drink_d),
             pop = nat(rb.pop, 0, 250, M.CFG.rebuild_pop), off = nat(rb.off, 0, 250, M.CFG.rebuild_off),
             yield = nat(q.yield_days, 1, 60, M.CFG.yield_days) * DAY,     -- BUG-037
             park = nat(q.park_days, 1, 400, M.CFG.park_days) * DAY,
             lost = nat(q.lost_days, 0, 3000, M.CFG.lost_days) * DAY,            -- BUG-637
             idle = nat(q.idle_days, 1, 400, M.CFG.idle_days) * DAY,               -- BUG-328
             stale = nat(q.stale_days, 0, 3000, M.CFG.stale_days) * DAY,           -- BUG-435
             stale_every = nat(q.stale_every, 1, 400, M.CFG.stale_every) * DAY,
             runstall = nat(q.stall_days, 0, 3000, M.CFG.stall_days) * DAY,        -- BUG-444
             runstall_every = nat(q.stall_every, 1, 400, M.CFG.stall_every) * DAY,
             release = nat(q.release_days, 0, 3000, M.CFG.release_days) * DAY,     -- BUG-529
             reach = nat(q.reach_days, 1, 60, M.CFG.reach_days) * DAY,             -- BUG-352
             slots_idle = nat(q.slots_idle, 0, 50, M.CFG.slots_idle),              -- BUG-486
             slots_pop = nat(q.slots_pop, 1, 250, M.CFG.slots_pop),
             slots_max = nat(q.slots_max, 1, 20, M.CFG.slots_max)}
  -- BUG-066 / FR-76: the manifest follows the workshops that stand (reclaim = config runner.reclaim)
  local rc = type(c.reclaim) == 'table' and c.reclaim or {}
  r.rec = {on = rc.on ~= false, scans = nat(rc.gone_scans, 1, 10, M.CFG.rec_scans),
           min = nat(rc.min_ws, 1, 50, M.CFG.rec_min), ask = nat(rc.ask_days, 1, 60, M.CFG.rec_ask) * DAY}
  r.care = {on = M.CFG.care_first, stuck = nat(cf.stuck_days, 1, 60, M.CFG.care_stuck_days) * DAY,
            patients = nat(cf.patients, 1, 250, M.CFG.care_patients)}
  if type(cf.on) == 'boolean' then r.care.on = cf.on end
  if type(sf.on) == 'boolean' then r.on = sf.on end
  if type(sf.wall) == 'boolean' then r.wall = sf.wall end
  r.supply_d = nat(sf.supply_d, 0, 400, Q.SUPPLY_D)                          -- BUG-275
  r.off = math.max(r.off, r.pop)
  return r
end

-- BUG-486: the projects worked on at once: M.CFG.active, plus one for every slots_idle free idle adults (economy.idle_free) and
-- one for every slots_pop adults, at most slots_max (never below active). The queue order does not change. c = conf(K)
function Q.slot_cap(K, c)
  local base = M.CFG.active
  if not c or c.slots_idle <= 0 then return base end
  local ok, free, adults = K.call('economy', 'idle_free')
  if not (ok and math.type(free) == 'integer' and math.type(adults) == 'integer') then return base end
  -- BUG-679 (Run 16d i4 Trumpetrealms y444: a Cook and a Dyer idle, 3 slots held, 6 projects 'set aside'): one free idle adult is one hand more
  -- than the slots feed, so the idle count rounds up (2 idle adults were 0 extra slots with slots_idle 3)
  local cap = math.max(base, math.min(c.slots_max, base + (free + c.slots_idle - 1) // c.slots_idle + adults // c.slots_pop))
  if cap ~= S.cap_seen then
    S.cap_seen = cap
    if cap > base then
      K.log('info', 'runner slots %d (active %d + %d free idle adults of %d): more projects run at once', cap, base, free, adults)
    end
  end
  return cap
end

-- BUG-037: blocked for good (nothing in the kernel clears it: build_lost with its retries spent, a breach stop, quickfort
-- failing, the document gone, the plug refused); parked once it stood park_days (pt: conf(K).park)
Q.FINAL = {apply_fail = true, bp_missing = true, plug_refused = true, occupied = true, ring_wall = true, ring_nostone = true}   -- BUG-662: ring_wall; BUG-677: ring_nostone (no stone for it)
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
  local b = Q.bld_at(t[1], t[2], t[3])                        -- BUG-329: a finished farm plot too
  if b then return not is_construction(b) and built(b) end
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
  local cls                                 -- BUG-274: the cause in one word (SEAL_STUCK d.why)
  if st.mode == 'build' then
    local w, bs = Q.piece_why(K, t)         -- BUG-044: the building and its job, who suspends it
    if w then out[#out + 1] = w end
    cls = Q.cls_of(bs)
    if (cls == 'no builder' or cls == 'boxed' or cls == 'no labor') and (int(bs.items) or 0) > 0 then
      out[#out + 1] = plural(int(bs.items), 'item') .. ' attached'
    end
  end
  local okc, civ = pcall(function() return df.global.plotinfo.alerts.civ_alert_idx end)
  local okh, hold = K.call('reflex', 'holding')
  if (okc and (int(civ) or 0) ~= 0) or (okh and type(hold) == 'string' and hold ~= '') then
    out[#out + 1] = (okc and (int(civ) or 0) ~= 0) and 'civil alert on: the citizens keep to its burrow'
                    or ('lockdown: ' .. trunc(hold, 40))
    cls = 'confined'
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
        cls = 'unreachable'
      end
    end
  end
  return #out > 0 and table.concat(out, '; ') or nil, cls
end

-- BUG-274: economy.build_state's answer in one word: no item (buildingplan waits for it), suspended (suspendmanager, DF),
-- no builder (a job nobody has taken), boxed (BUG-313: nobody takes it, no tile beside it on its level to build from: the
-- player cancels it, `seal at=refuge` puts the hatch one level up), building (a builder at it), not placed; nil unknown
function Q.cls_of(bs)
  if type(bs) ~= 'table' then return nil end
  if bs.none then return 'not placed' end
  if not int(bs.job) then return nil end
  if bs.susp then return bs.who == 'buildingplan' and 'no item' or 'suspended' end
  if not bs.work and bs.boxed then return 'boxed' end   -- BUG-313: walled in on its level, a re-place there is no help
  if not bs.work and bs.nolabor then return 'no labor' end   -- BUG-329: nobody has its labor on: a re-place is no help
  return bs.work and 'building' or 'no builder'
end

-- BUG-081 (integration audit I2): seal's wall + door for a lost bridge (runner.repair opts.closure, params.cl = 1) is a
-- seal in all but name: the same door waits for the same item, a suspended job or a builder, and the fort stays open
-- until it stands. It keeps the stuck clock of a seal (SEAL_STUCK with the cause, the wall fallback), but pauses nobody
function Q.closure(P, d)
  return P.tpl == 'repair' and type(d) == 'table' and type(d.params) == 'table' and d.params.cl == 1
end

-- BUG-336: the open piece of seal P on the refuge's stair column (seal.refuge_stair: its x,y), 'hatch x,y,z', else nil.
-- The column is read once per tick (S.rfc). Review fix (merge15): a piece beside the column on the refuge floor (the
-- foot doors seal.refuge_alt offers: the level below the manifest head, man) is the refuge's seal too; the second value
-- is then true (seal_escalate never offers to wall it: the stair is the refuge's only way in; idle_keep keeps it)
function Q.refuge_seal(K, P)
  local t = now(K)
  local c = S.rfc
  if not (c and c.t == t) then
    local ok, rs = K.call('seal', 'refuge_stair')
    local m = ok and type(rs) == 'table' and (rs.pos or rs.man) or nil
    local man = ok and type(rs) == 'table' and type(rs.man) == 'table' and rs.man or nil
    c = {t = t, x = m and int(m[1]), y = m and int(m[2]), zr = man and int(man[3]) and man[3] - 1}
    S.rfc = c
  end
  if not c.x then return nil end
  local d = doc(K, P.id)
  local st = d and d.stages[P.stage + 1]
  local foot
  for _, ch in ipairs(st and st.chunks or {}) do
    for _, cell in ipairs(ch.cells) do
      local tl = {}
      cell_tiles(ch, cell, tl)
      local tile = tl[1]
      if tile and not piece_built(K, tile) then
        local name = string.format('%s %d,%d,%d', PIECE_NAME[cell[4]] or cell[4], tile[1], tile[2], tile[3])
        if tile[1] == c.x and tile[2] == c.y then return name end
        if not foot and c.zr and tile[3] == c.zr and math.abs(tile[1] - c.x) <= 1 and math.abs(tile[2] - c.y) <= 1 then
          foot = name
        end
      end
    end
  end
  if foot then return foot, true end
end

-- BUG-336 review: the bp.place args (dfpilot/schema.py VERB_ARGS bp.place: tpl and site; the seal's own params in p) as the
-- command line's JSON
function Q.seal_place(at, close)
  return string.format("dfllm cmd bp.place '{\"tpl\":\"seal\",\"site\":\"S1\",\"p\":{\"at\":\"%s\"%s}}'", at,
                       close and string.format(',\"close\":\"%s\"', close) or '')
end

-- BUG-336 review: the opening of seal doc d whose piece stands on tile {x, y, z} ('x,y,z kind[ piece][ for=..]', its
-- kind), from d.params.at (a ramp's piece stands on the ramp top, one level up), else nil
Q.FLOORISH = {floor = true, boulder = true, pebbles = true, brook_top = true, passable = true, shrub = true}
function Q.seal_opening(d, tile)
  local at = type(d) == 'table' and type(d.params) == 'table' and d.params.at
  if type(at) ~= 'string' then return nil end
  for seg in at:gmatch('[^;]+') do
    local x, y, z, rest = seg:match('^%s*(%-?%d+),(%-?%d+),(%-?%d+)%s*(.*)$')
    x, y, z = int(x), int(y), int(z)
    if x then
      local kind = (rest or ''):match('^(%S+)') or 'floor'
      kind = kind:lower()
      local zt = kind == 'ramp' and z + 1 or z
      if x == tile[1] and y == tile[2] and zt == tile[3] then
        return seg:gsub('^%s+', ''):gsub('%s+$', ''), kind
      end
    end
  end
end

-- BUG-336: a stuck seal (r.st 1) without progress for c.esc asks the player, again every c.esc while it stays so (r.dn):
-- the piece, the cause (SEAL_STUCK's), what the kernel tried (re-placed: BUG-274 r.rp; walled: BUG-044 S.rt.sw) and the
-- commands. The refuge's seal says the refuge is not the civilians' burrow in a fight until it stands (seal.refuge_open).
-- Review: every command validates against the CLI schema (bp.place needs site S1, the seal's at/close go in p); the
-- refuge's hatch is never placed again on the same stair head (Earthboat did it four times, 'no builder has taken it'):
-- seal.refuge_alt names where at=refuge puts it now (BUG-313: a boxed head moves up the stair) when that is another tile,
-- else doors round the stair foot on the refuge floor (at most 4), else only the hand-built hatch and what to look at.
-- d.cmd = the commands alone (bp.cancel then bp.place; nil when there is none), d.how = what they do and the other way
function Q.seal_escalate(K, P, d, r, n, names, t, c)
  if P.tpl ~= 'seal' or t - r.t < c.esc or (int(r.dn) and t - r.dn < c.esc and t >= r.dn) then return end
  r.dn = t
  dirty()
  local days = (t - r.t) // DAY
  local rf, rfoot = Q.refuge_seal(K, P)
  local piece = rf or names[1] or '?'
  local tried = {}
  if type(r.rp) == 'table' and next(r.rp) then tried[#tried + 1] = 'removed and placed again' end
  if type(S.rt.sw) == 'table' and type(S.rt.sw[P.id]) == 'table' then tried[#tried + 1] = 'doors walled' end
  local px, py, pz = piece:match('(%-?%d+),(%-?%d+),(%-?%d+)')
  local tile = px and {int(px), int(py), int(pz)} or nil
  local cancel = string.format("dfllm cmd bp.cancel '{\"proj\":\"%s\"}' then ", P.id)
  -- d.cmd: the commands alone (every d string <= 200 bytes, CONTRACTS section 12: one that does not fit is left out);
  -- d.how: what they do and the other way (build it by hand), for the player
  -- BUG-349 (Run 15 Guildcleans y388-y390, i2: #7282/#7283 offered bp.cancel for a hatch open 4500 d and a wall 2300 d; the
  -- player did not dare to send them): every how with a command says whether it is safe and recommended (a plain
  -- bp.cancel drops only the unbuilt pieces and their jobs, nothing built goes; the way in is open now and stays so until
  -- the new piece stands); a wall waiting for an item (no item) gets no command: a new wall waits for the same item
  local place, how
  if rfoot then
    -- Review fix (merge15): the doors round the refuge's stair foot (refuge_alt's way): walling them cuts the refuge
    -- off from its only stair, so no command, only the hand build
    how = 'build the doors round the stair foot by hand in DF (units in the way? no builder reaches them?); never ' ..
          'wall these tiles: the stair is the only way into the refuge'
  elseif rf then
    local oka, alt = K.call('seal', 'refuge_alt', tile)
    alt = oka and type(alt) == 'table' and alt or {}
    local why = alt.boxed == true and 'no tile beside it to build from' or 'units on the stair? no builder reaches it?'
    if alt.moved and type(alt.head) == 'table' then
      place = Q.seal_place('refuge')
      how = string.format('recommended and safe (the cancel drops only the unbuilt hatch; the refuge stays open until ' ..
                          'the new one stands): place it at the head the map shows now (%d,%d,%d); or build it by hand',
                          alt.head[1], alt.head[2], alt.head[3])
    elseif type(alt.foot) == 'table' and #alt.foot > 0 then
      place = Q.seal_place(table.concat(alt.foot, ';'))
      how = string.format('recommended and safe (the cancel drops only the unbuilt hatch): put ' ..
                          'doors round the stair foot on the refuge floor (%d tiles); or build it by hand (%s)',
                          #alt.foot, why)
    else
      how = string.format('build it by hand in DF (%s); placing it again at the same head does not help%s', why,
                          alt.footwhy and ('; ' .. alt.footwhy) or '')
    end
  else
    local seg, kind = Q.seal_opening(d, tile or {})
    if r.why == 'no item' and piece:match('^wall ') then
      how = 'no command helps: the wall waits for a building item (stone, block, log) and none is free; placed again it ' ..
            'waits for the same; get one (trade.want stone, a stone dig) or build it by hand'
    elseif seg and Q.FLOORISH[kind] and Q.wall_refused(r, tile) then
      -- BUG-458: a wall here would cut citizens off (the runner's reach check said so): the door is the answer, made at the
      -- workshop (the kernel adds the task; by hand: order.add ConstructDoor), never the wall
      place = nil
      how = string.format('no wall (%s): the door is made at the workshop (task added); by hand: dfllm cmd order.add ' ..
                          '\'{"job":"ConstructDoor","amount":2}\'; or build it in DF', trunc(Q.wall_refused(r, tile), 56))
    elseif seg and Q.FLOORISH[kind] then
      place = Q.seal_place(seg:match('^(%-?%d+,%-?%d+,%-?%d+%s+%S+)') or seg, 'wall')
      -- BUG-504 (Run 16b i2 Roadvises y377: 'recommended where the citizens keep another way' with no check and no way named,
      -- the player chose blind): the entrance check names the ways that stay when this tile is walled; none = no wall
      local okw, w = K.call('seal', 'opening_ways', tile[1], tile[2], tile[3])
      w = okw and type(w) == 'table' and w or {}
      local where = type(w.where) == 'table' and w.where or {}
      local others = int(w.others) or #where
      local base = 'safe (the cancel drops only the unbuilt piece; open until the wall stands), recommended where the ' ..
                   'citizens keep another way'
      if #where > 0 then
        how = string.format('%s: they keep %s (%d other way%s with a door or bridge): wall the tile (a wall needs no door); ' ..
                            'or build it by hand in DF', base, table.concat(where, ', '), others, others == 1 and '' or 's')
      elseif w.known == true and others < 1 then
        place = nil
        how = 'no wall: the entrance check names no other way in or out with a door or bridge, a wall here would leave ' ..
              'the fort without one; place a door elsewhere first (dfllm cmd bp.place seal at=last), or build this door ' ..
              'by hand in DF'
      else
        how = base .. ': wall the tile (a wall needs no door)' .. (w.known == true and
              string.format(' (%d other way%s with a door or bridge)', others, others == 1 and '' or 's') or
              ' (the entrance check is not known: look at dfllm cmd inspect what=entrances first)') ..
              '; or build it by hand in DF'
      end
    elseif seg then
      place = Q.seal_place(seg)
      how = 'safe (the cancel drops only the unbuilt pieces; open until they stand): place it again; or build it by hand'
    else
      place = Q.seal_place('last')
      how = 'safe (the cancel drops only the unbuilt pieces; open until a new seal stands): seal the open ways in now ' ..
            '(at=last); or build it by hand in DF'
    end
  end
  local cmd = place and (cancel .. place) or nil
  if cmd and #cmd > 200 then cmd, how = nil, how .. ' (the command is too long: dfllm cmd inspect what=refuge)' end
  local q = string.format('seal %s: %s open %d d%s%s%s; %s', P.id, piece, days,
                          n > 1 and string.format(' (+%d)', n - 1) or '', r.why and (' (' .. r.why .. ')') or '',
                          #tried > 0 and ('; tried: ' .. table.concat(tried, ', ')) or '',
                          rf and "the refuge is NOT the civilians' burrow in a fight until it stands" or
                          'the way in stays open')
  K.log('warn', 'seal first: %s: %s%s', q, how, cmd and (': ' .. cmd) or '')
  K.emit('DECISION_NEEDED', 'A', trunc(q, 200), {id = 'seal_stalled', q = trunc(q, 200), n = days, mat = trunc(piece, 40),
                                                 cmd = cmd, how = trunc(how, 200), proj = P.id})
end

-- SEAL_STUCK (A): the seal built nothing for stuck_days; util/cadence per project (r.ev): a repeat needs news and
-- 7 days (Run 9 GHOSTS rule). BUG-041: d.wait = Q.wait_why
local function stuck_event(K, P, d, n, names, ticks, r)
  local st = d.stages[P.stage + 1]
  local label = trunc(st and st.label or 'done', 24)
  local days = ticks // DAY
  local _, mat = M.remake_why(K, P, d)
  local okw, wait, cls = pcall(Q.wait_why, K, P, d)
  wait = okw and type(wait) == 'string' and trunc(wait, 160) or nil
  cls = okw and type(cls) == 'string' and cls or nil
  r.why = cls                                   -- BUG-274: Q.stuck_replace reads it
  local ph = Q.ph                               -- BUG-276: the pop cap this seal holds (focus)
  ph = P.tpl == 'seal' and ph or nil
  local msg = string.format('%s (%s) built nothing for %s at %s: %s open%s%s%s%s%s%s; %s', P.id,
                            P.tpl, plural(days, 'day'), label, plural(n, 'piece'),
                            #names > 0 and (' (' .. table.concat(names, ', ') .. ')') or '',
                            P.blocked ~= '' and ('; ' .. P.blocked) or '', mat and ('; ' .. mat) or '',
                            cls and ('; cause: ' .. cls) or '', wait and ('; ' .. wait) or '', ph and ('; ' .. ph) or '',
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
  if cls then dd.why = cls end                  -- BUG-274
  if ph then dd.hold = trunc(ph, 100) end       -- BUG-276
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
Q.CARE_PAUSES = {work = true, beds = true, tomb_shops = true}
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
  f.low = not f.emerg and Q.low_supply(K, c) or nil                       -- BUG-275
  local okp, ph = pcall(Q.perim_hold, K)                                  -- BUG-276
  Q.ph = okp and ph or nil
  f.ph = Q.ph
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
                (P.tpl == 'repair' or r.ld == 1) and '' or ': it pauses the others again')
        end
        r.sig, r.t, r.nw, r.nu, r.wt, r.dn = sig, t, nil, nil, nil, nil
        dirty()
      elseif r.st ~= 1 and (not c.on or not allowed(K, P, d)) then
        r.t = t                                       -- the clock waits while the mode freezes the seal
        dirty()
      elseif r.st ~= 1 and t - r.t >= c.stuck then
        r.st = 1
        dirty()
        stuck_event(K, P, d, n, names, t - r.t, r)
      end
      -- BUG-472 (Run 16a i1 Basementflew y374-375, i4: a refuge hatch 'unreachable' led 'seal first' for months, bedrooms and
      -- workshops paused, the same decision eight times): a seal that leads this long without closing one more piece pauses
      -- nobody; SEAL_STUCK / the stalled decision speak for it, and it leads again only once a piece of it is built
      if not r.n0 or n < r.n0 or not r.ls then
        if r.ld == 1 then K.log('info', 'seal first: %s closed a piece (%s open): it leads again', P.id, plural(n, 'piece')) end
        r.n0, r.ls, r.ld = n, t, nil
        dirty()
      elseif r.ld ~= 1 and P.tpl ~= 'repair' and t - r.ls >= c.lead and allowed(K, P, d) then
        r.ld = 1
        dirty()
        K.log('warn', 'seal first: %s led %d days without closing a piece (%s open): the others run again; the seal stays stuck',
              P.id, (t - r.ls) // DAY, plural(n, 'piece'))
        if r.st ~= 1 then
          r.st = 1
          stuck_event(K, P, d, n, names, t - r.t, r)
        end
      end
      if r.st == 1 then
        local oke, erre = pcall(Q.seal_escalate, K, P, d, r, n, names, t, c)          -- BUG-336: own pcall
        if not oke then K.log('error', 'seal escalation failed: %s', trunc(erre, 160)) end
      end
      if P.tpl == 'repair' then                       -- BUG-081: a closure pauses nobody and is never "stuck" for the others
      elseif r.st == 1 or r.ld == 1 then f.stuck[#f.stuck + 1] = {id = P.id, n = n, days = (t - r.t) // DAY}; f.stk[P.id] = true
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
  if type(S.rt.rb) == 'table' then
    f.rb = {pop = cit or int(S.rt.rb.pop) or 0, lo = c.pop, hi = c.off}
    local okd, dead = pcall(Q.dead_need, K)           -- BUG-133: the masons' and carpenters' shops for the dead
    f.dead = okd and dead == true
  end
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
-- BUG-274 (Run 15 Earthboat y373-y375: the refuge hatch 55,82,133 open 619 days, 'job 8095 not suspended, no builder has
-- taken it', 9 idle; nothing placed it again): a door or hatch of a stuck seal (or closure) whose job nobody takes
-- (SEAL_STUCK why 'no builder', still so by economy.build_state) 2 x stuck_days after its clock stopped is removed (quickfort
-- undo, the player's remove building) and placed again (the chunk applied again: a fresh building and job), once per piece
-- (r.rp), one a run, in PEACE without a lockdown. kern.log names it; an unremovable one stays (kern.log once)
Q.REPLACE = {d = 'door', H = 'hatch'}
function Q.stuck_replace(K, c)
  if not c.on or K.mode() ~= 'PEACE' then return end
  local okh, hold = K.call('reflex', 'holding')
  if okh and type(hold) == 'string' and hold ~= '' then return end
  local t = now(K)
  for _, P in ipairs(sorted()) do
    local r = (P.tpl == 'seal' or P.tpl == 'repair') and (P.blocked == '' or P.blocked == 'stalled') and S.rt.sf[P.id]
    local d = type(r) == 'table' and r.st == 1 and r.why == 'no builder' and t - r.t >= 2 * c.stuck and doc(K, P.id)
    if d and P.tpl == 'repair' and not Q.closure(P, d) then d = nil end
    local st = d and d.stages[P.stage + 1]
    if st and st.mode == 'build' and P.chunk >= #st.chunks and t - (int(r.rpt) or -DAY) >= DAY then
      r.rpt = t
      r.rp = type(r.rp) == 'table' and r.rp or {}
      dirty()
      for _, ch in ipairs(st.chunks) do
        for _, cell in ipairs(ch.cells) do
          local tl = {}
          cell_tiles(ch, cell, tl)
          local tile, what = tl[1], Q.REPLACE[cell[4]]
          local at = tile and tkey(tile[1], tile[2], tile[3])
          if what and not r.rp[at] and qf_room() and not piece_built(K, tile) then
            local why, bs = Q.piece_why(K, tile)
            -- BUG-298: the piece lies outside the burrow its builders keep to: that burrow takes the piece's own tile
            -- (the burrows screen's paint brush; a building job's site is its tile), once per piece, before the re-place.
            -- Only that tile: a perimeter door's outer neighbours stay out of the burrow a civil alert keeps citizens in
            r.bw = type(r.bw) == 'table' and r.bw or {}
            if Q.cls_of(bs) == 'no builder' and type(bs.burrow) == 'string' and not r.bw[at] then
              r.bw[at] = 1
              local pts = {{tile[1], tile[2], tile[3]}}
              local okb, nb = K.act.burrow_tiles(bs.burrow, pts)
              K.log('warn', 'seal first: %s: %s %s outside the burrow %s its builders keep to (%s): %s', P.id, what, at,
                    bs.burrow, tostring(bs.bwhy), okb and string.format('%d tiles added to it', int(nb) or 0)
                    or ('not widened: ' .. trunc(tostring(nb), 60)))
              if okb then r.bwt = t; return end              -- a fresh wait (stuck_days) before the re-place
            end
            local waiting = int(r.bwt) and t - r.bwt < c.stuck
            if Q.cls_of(bs) == 'no builder' and int(bs.id) and not waiting then
              r.rp[at] = 1
              qf(K, {mode = 'build', data = {[0] = {[0] = {[0] = cell[4]}}}, pos = {tile[1], tile[2], tile[3]},
                     command = 'undo'})
              local okf, b2 = pcall(dfhack.buildings.findAtTile, tile[1], tile[2], tile[3])
              if okf and b2 and not is_construction(b2) then
                K.log('warn', 'seal first: %s: %s %s stays: quickfort undo did not remove it (%s)', P.id, what, at, why)
                return
              end
              local R = R_of(K, P)
              local keep = {}
              for _, id in ipairs(R.b) do if df.building.find(id) then keep[#keep + 1] = id end end
              R.b, R.uns, R.ra, P.chunk = keep, (int(R.uns) or 0) + 1, 1, 0
              moved(K, R)                                      -- BUG-328: the kernel's own step (a set-aside seal is back)
              K.log('warn', 'seal first: %s: %s %s open %d days, its job taken by no builder (%s): removed and placed ' ..
                    'again (once)', P.id, what, at, (t - r.t) // DAY, trunc(why, 100))
              r.st, r.t, r.ev, r.why = 0, t, CAD.quiet(r.ev), nil       -- a fresh start: the stuck clock again
              return
            end
          end
        end
      end
    end
  end
end

-- BUG-458 (LOCKED_OUT): walls the kernel put up where a door stayed unbuilt (m.runner sw: the stuck fallback; dw: a door
-- quickfort refused) that leave a citizen or a farm, well, depot, workshop or office on another walk group than the citizens'
-- main one: DECISION_NEEDED locked_out (A), once a game day looked at, again after Q.LOCK_AGAIN days, with the citizens and
-- places outside, the wall tiles and the command that takes our wall down (bp.cancel reopen=, below). The kernel takes no wall
-- down itself. PEACE and RECOVERY only (a lockdown or a siege holds doors on purpose)
Q.LOCK_AGAIN = 30 * DAY
-- the built 'Cw' cells of a seal or repair document (a wall that came in through bp.place close=wall, or past the record cap of
-- sw / dw): {'x,y,z', ...}, {['x,y,z'] = the cell}
function Q.doc_walls(K, P, d)
  local out, cells = {}, {}
  if not (P.tpl == 'seal' or P.tpl == 'repair') then return out, cells end
  for _, st in ipairs(type(d) == 'table' and d.stages or {}) do
    if st.mode == 'build' then
      for _, ch in ipairs(st.chunks or {}) do
        for _, cell in ipairs(ch.cells or {}) do
          if #out >= 48 then return out, cells end
          if type(cell[4]) == 'string' and cell[4]:match('^[^{(:/]*') == 'Cw' then
            local tl = {}
            cell_tiles(ch, cell, tl)
            if tl[1] and piece_built(K, tl[1]) then
              local at = tkey(tl[1][1], tl[1][2], tl[1][3])
              cells[at] = cell
              out[#out + 1] = at
            end
          end
        end
      end
    end
  end
  return out, cells
end
-- a finished project forgets its sw / dw records and drops its document: the walls it leaves are kept (S.rt.ow) for the LOCKED_OUT
-- scan and reopen
function Q.keep_walls(K, P)
  local d = doc(K, P.id)
  local list, seen = {}, {}
  local function add(at)
    if not seen[at] and #list < 48 then seen[at] = true; list[#list + 1] = at end
  end
  for _, src in ipairs({S.rt.sw, S.rt.dw}) do
    local l = type(src) == 'table' and src[P.id]
    for _, at in ipairs(type(l) == 'table' and l or {}) do add(tostring(at)) end
  end
  for _, at in ipairs((Q.doc_walls(K, P, d))) do add(at) end
  if #list > 0 then S.rt.ow[P.id] = list; S.lo = S.lo or {}; S.lo.t = nil end    -- BUG-487: looked at on the next run
end
-- the walls of ours at a project: the records of the kernel's own fallbacks (sw, dw: capped at 8 per project), the walls a finished
-- project left (ow, only while they stand) and the built Cw cells of a running seal / repair document.
-- {'x,y,z', ...} (at most 48), {['x,y,z'] = the document cell} for the document's walls, and the document
function Q.own_walls(K, P)
  local out, seen = {}, {}
  local function add(at)
    if not seen[at] and #out < 48 then seen[at] = true; out[#out + 1] = at end
  end
  for _, src in ipairs({S.rt.sw, S.rt.dw}) do
    local l = type(src) == 'table' and src[P.id]
    for _, at in ipairs(type(l) == 'table' and l or {}) do add(tostring(at)) end
  end
  local kept = type(S.rt.ow) == 'table' and S.rt.ow[P.id]
  if type(kept) == 'table' then
    local keep = {}
    for _, at in ipairs(kept) do
      local x, y, z = tostring(at):match('^(%-?%d+),(%-?%d+),(%-?%d+)$')
      if x and piece_built(K, {int(x), int(y), int(z)}) then keep[#keep + 1] = at; add(at) end
    end
    if #keep ~= #kept then
      S.rt.ow[P.id] = #keep > 0 and keep or nil
      dirty()
    end
  end
  local d = P.done ~= 1 and doc(K, P.id) or nil
  local dl, cells = Q.doc_walls(K, P, d)
  for _, at in ipairs(dl) do add(at) end
  return out, cells, d
end

-- BUG-487: take our walls at `ats` ('x,y,z' of seal.locked_out's `at`; own = {tile = project id}) down and put a door there: bp.cancel
-- reopen (the document cell of a running project becomes a door), for a wall of a finished project a repair project with the
-- door cell (PEACE only, buildingplan makes the door; quickfort's refusal walks the BUG-458 guard: the door stays) and the door
-- task at the workshop. Returns the tiles reopened
M.CFG.lock_reopen = true
-- BUG-479 review: the refuge plug (seal.plug_state: the repair project and its 'Cw' cells round the stair foot) is not a wall the
-- lockout scan may take down: it separates the refuge from the main walk group on purpose and only seal.plug_lift removes it
-- (PEACE, PLUG.lift quiet ticks). Returns the project id and the set of 'x,y,z' keys (both empty without a plug)
function Q.plug_guard(K)
  local ok, ps = K.call('seal', 'plug_state')
  if not (ok and type(ps) == 'table') then return nil, {} end
  local set = {}
  for _, c in ipairs(type(ps.tiles) == 'table' and ps.tiles or {}) do
    if type(c) == 'table' and int(c[1]) and int(c[2]) and int(c[3]) then set[int(c[1]) .. ',' .. int(c[2]) .. ',' .. int(c[3])] = true end
  end
  return type(ps.id) == 'string' and ps.id ~= '' and ps.id or nil, set
end
function Q.lock_reopen(K, ats, own)
  local by, order = {}, {}
  local pid, pset = Q.plug_guard(K)
  for _, at in ipairs(ats) do
    local proj = own[at]
    if proj and proj ~= pid and not pset[at] then
      if not by[proj] then by[proj] = {}; order[#order + 1] = proj end
      by[proj][#by[proj] + 1] = at
    end
  end
  local done = {}
  for _, proj in ipairs(order) do
    local P = find(proj)
    if P then
      local running = P.done ~= 1
      local ok, msg = Q.reopen(K, P, {reopen = table.concat(by[proj], ';')})
      if ok then
        local cells = {}
        for _, at in ipairs(by[proj]) do
          done[#done + 1] = at
          local x, y, z = at:match('^(%-?%d+),(%-?%d+),(%-?%d+)$')
          if x then cells[#cells + 1] = {int(x), int(y), int(z), 'd'} end
        end
        if not running and #cells > 0 then
          local okr, okp, rid = pcall(M.repair, K, cells, 'BUG-487: a door where our wall shut citizens out', {peace = true})
          if not (okr and okp) then K.log('warn', 'locked out: door project not queued: %s', trunc(okr and rid or okp, 100)) end
        end
        pcall(K.call, 'economy', 'seal_doors', #cells)
        K.log('warn', 'locked out: %s (taken down by the kernel, BUG-487)', msg)
      else
        K.log('warn', 'locked out: reopen of %s at %s failed: %s', proj, table.concat(by[proj], ';'), trunc(msg, 120))
      end
    end
  end
  return done
end

function Q.lockout_scan(K, c, t)
  S.lo = S.lo or {}
  local m = K.mode()
  -- BUG-479 review: nothing is taken down while a siege episode lasts (SIEGE, BREACH, RECOVERY, ALERT, a reflex hold): the citizens
  -- are confined on purpose, a wall that 'shuts them out' is the defense (the refuge plug above all); PEACE only
  if m ~= 'PEACE' then return end
  local okh, hold = K.call('reflex', 'holding')
  if okh and type(hold) == 'string' and hold ~= '' then return end
  if t - (S.lo.t or -DAY) < DAY then return end
  S.lo.t = t
  local tiles, own = {}, {}
  local pid, pset = Q.plug_guard(K)
  -- BUG-487: every project, the finished ones too (sorted() lists the open ones only: the walls a finished seal left in S.rt.ow were
  -- never looked at once the project was done)
  for _, P in ipairs(S.pd.list) do
    for _, at in ipairs(P.id ~= pid and Q.own_walls(K, P) or {}) do
      local x, y, z = at:match('^(%-?%d+),(%-?%d+),(%-?%d+)$')
      if x and #tiles < 48 and not own[at] and not pset[at] then
        tiles[#tiles + 1] = {int(x), int(y), int(z)}
        own[at] = P.id
      end
    end
  end
  if #tiles == 0 then S.lo.n = nil; return end
  local ok, w = K.call('seal', 'locked_out', tiles)
  if not (ok and type(w) == 'table' and w.known == true) or #(w.at or {}) == 0 then S.lo.n = nil; return end
  local outside = (int(w.n) or 0)
  if outside == 0 and #(w.places or {}) == 0 then S.lo.n = nil; return end
  S.lo.n = outside
  -- BUG-487 (Run 16b i2 Roadvises y401: 12 citizens died of thirst behind the kernel's own wall, the question waited for a
  -- player for 5 days): a wall of ours that shuts citizens or places out comes down at once, every look, and a door goes
  -- there (the project's document cell, else a repair project; the door task at the workshop)
  local reopened = M.CFG.lock_reopen ~= false and Q.lock_reopen(K, w.at, own) or {}
  S.lo = S.lo or {t = t}                          -- Q.reopen clears it
  if S.lo.ann and t - S.lo.ann < Q.LOCK_AGAIN then return end
  S.lo.ann = t
  local proj = own[w.at[1]]
  local mine = {}
  for _, at in ipairs(w.at) do if own[at] == proj and #mine < 6 then mine[#mine + 1] = at end end
  local ids, places = {}, {}
  for i, u in ipairs(w.cits or {}) do if i <= 6 then ids[#ids + 1] = u.id end end
  for i, pl in ipairs(w.places or {}) do if i <= 4 then places[#places + 1] = string.format('%s %d,%d,%d', pl.kind, pl.x, pl.y, pl.z) end end
  local cmd = string.format('dfllm cmd bp.cancel \'{"proj":"%s","reopen":"%s"}\'', proj, table.concat(mine, ';'))
  if #cmd > 200 then cmd = nil end
  local q = string.format('LOCKED OUT: our wall at %s shuts %d citizen(s)%s off the fort; reopen it, then place a door (doors are made ' ..
                          'at the workshop)', table.concat(mine, ' '), outside,
                          #places > 0 and (' and ' .. places[1] .. (#places > 1 and ' (+)' or '')) or '')
  local how = 'reopen takes only the wall the kernel built there down (quickfort undo, the wall is deconstructed); then ' ..
              'dfllm cmd bp.place seal at=last puts a door, the kernel orders it as a workshop task'
  if #reopened > 0 then
    q = q .. string.format('; the kernel took %d wall(s) down itself and puts a door there', #reopened)
    how = 'the walls are designated for removal (quickfort undo), a door goes there (' .. table.concat(reopened, ' ', 1, math.min(#reopened, 3)) .. ')'
  end
  K.log('warn', 'locked out: %s: %s%s', q, how, cmd and (': ' .. cmd) or '')
  K.emit('DECISION_NEEDED', 'A', trunc(q, 200), {id = 'locked_out', q = trunc(q, 200), n = outside, at = mine, units = ids,
                                                 places = places, proj = proj, cmd = cmd, how = trunc(how, 200),
                                                 reop = #reopened > 0 and #reopened or nil})
  K.flush()
end

-- BUG-458: bp.cancel {proj, reopen = 'x,y,z;...'}: takes down walls the kernel built itself where a door stayed unbuilt (the
-- project's sw / dw records and the built Cw cells of its finished seal / repair document, never another wall): quickfort undo of a constructed wall on the tile (the player's
-- remove construction). The project may be done; its door can then be placed again (bp.place seal at=last)
function Q.reopen(K, P, args)
  if type(args.reopen) ~= 'string' or args.reopen == '' then return false, 'reopen: name tiles as x,y,z;x,y,z' end
  local own = {}
  local mine, dcells, d = Q.own_walls(K, P)
  for _, at in ipairs(mine) do own[at] = true end
  local got, bad = {}, {}
  for seg in args.reopen:gmatch('[^;]+') do
    local x, y, z = seg:match('^%s*(%-?%d+),(%-?%d+),(%-?%d+)%s*$')
    local at = x and tkey(int(x), int(y), int(z))
    if at and own[at] then got[#got + 1] = {int(x), int(y), int(z), at} else bad[#bad + 1] = seg end
  end
  if #bad > 0 or #got == 0 then
    return false, string.format('reopen: %s not a wall the kernel built for %s (its records: %s)',
                                #bad > 0 and table.concat(bad, ';') or args.reopen, P.id, next(own) and 'see kern.log' or 'none')
  end
  local n = 0
  for _, g in ipairs(got) do
    local ok = K.act.quickfort({mode = 'build', data = {[0] = {[0] = {[0] = 'Cw'}}}, pos = {g[1], g[2], g[3]}, command = 'undo'})
    if ok then
      n = n + 1
      for _, src in ipairs({S.rt.sw, S.rt.dw, S.rt.ow}) do
        local l = type(src) == 'table' and src[P.id]
        if type(l) == 'table' then
          for i = #l, 1, -1 do if l[i] == g[4] then table.remove(l, i) end end
        end
      end
      K.log('warn', '%s: wall at %s taken down by bp.cancel reopen (quickfort undo)', P.id, g[4])
      local cell = dcells[g[4]]
      if cell and d then                 -- a wall of the document: it is a door there now, so no later step builds the wall again
        cell[4] = 'd'
        local m = d.materials
        if type(m) == 'table' and int(m.wall) then
          m.wall, m.door = int(m.wall) > 1 and int(m.wall) - 1 or nil, (int(m.door) or 0) + 1
        end
        K.persist.set('bp.' .. P.id, d)
        for k in pairs(S.tiles) do if k:sub(1, #P.id + 1) == P.id .. '/' then S.tiles[k] = nil end end
        if S.own then S.own[P.id] = nil end
      end
    end
  end
  S.lo = nil
  dirty()
  save(K)
  if n == 0 then return false, 'reopen: quickfort undo failed on every tile (kern.log)' end
  return true, string.format('reopen %s: %d wall(s) designated for removal; place the door: dfllm cmd bp.place seal at=last', P.id, n)
end

-- BUG-458 (Run 16d Orbblock y376-y377: 'doors stuck at 95,69,137, 95,71,137: walls instead' shut the only surface farm, the
-- manager and the broker outside; 'farm: none on the citizens' group', idle_why noreach 15, no order validated for 145-234 days,
-- 23 starved): the wall fallback holds when the walls (this one and the project's other planned walls) would cut a citizen or a
-- farm, well, depot, workshop or office off the main walk group (seal.wall_cuts, a flood with the tiles closed). The reason
-- starts with 'a wall ' (Q.wall_text); the door stays and the missing doors are made at the workshops (economy.seal_doors).
-- nil = no objection (also when the seal module has no such check)
-- the reach answer for walls on `tiles`: nil (no objection, or the seal module has no such check), else 'unknown' (why),
-- 'partial' (the flood ran out of tiles) or 'cut', with the places count and the raw answer
function Q.wall_reach(K, tiles)
  local ok, w = K.call('seal', 'wall_cuts', tiles)
  if not (ok and type(w) == 'table') then return nil end
  if w.known ~= true then return 'unknown', 0, w end
  if (int(w.n) or 0) > 0 then return w.partial and 'partial' or 'cut', int(w.n), w end
  return nil
end
function Q.cut_parts(w, max)
  local parts = {}
  for i, cut in ipairs(w.cuts or {}) do
    if i <= max then parts[#parts + 1] = string.format('%s %d,%d,%d', cut.kind, cut.x, cut.y, cut.z) end
  end
  return table.concat(parts, ', ')
end
function Q.wall_refuse(K, P, d, tile)
  local tiles = {{tile[1], tile[2], tile[3]}}
  for _, st in ipairs(d.stages or {}) do
    if st.mode == 'build' then
      for _, ch in ipairs(st.chunks or {}) do
        for _, cell in ipairs(ch.cells) do
          if cell[4] == 'Cw' then
            local tl = {}
            cell_tiles(ch, cell, tl)
            if tl[1] and not piece_built(K, tl[1]) and #tiles < 24 then tiles[#tiles + 1] = {tl[1][1], tl[1][2], tl[1][3]} end
          end
        end
      end
    end
  end
  local kind, n, w = Q.wall_reach(K, tiles)
  if kind == 'unknown' then return string.format("a wall cannot be proven safe: the citizens' reach is not known (%s)", trunc(w.why or '?', 60)) end
  if kind == 'partial' then
    return string.format('a wall cannot be proven safe: the reach check ran out of tiles (%d places not met: %s)', n, Q.cut_parts(w, 3))
  end
  if kind == 'cut' then return string.format('a wall would cut off %d (%s)', n, Q.cut_parts(w, 3)) end
  return nil
end
function Q.wall_text(s) return type(s) == 'string' and s:sub(1, 7) == 'a wall ' end
-- BUG-458: a seal or repair document with constructed walls (close=wall, a nodoor opening) is refused when those walls would cut a
-- citizen or a farm, well, depot, workshop or office off the main walk group (seal.wall_cuts with all its wall tiles closed), and
-- fails closed like the runner's fallback (Q.wall_refuse): a reach check that does not know the citizens or ran out of tiles refuses
-- too (a repair outside PEACE/RECOVERY only on a proven cut: a breach is closed in a siege). The doors of the same seal are no
-- objection. nil = placed (also when the seal module has no such check)
function Q.place_walls(K, d, how)
  local tiles = {}
  for _, st in ipairs(d.stages or {}) do
    if st.mode == 'build' then
      for _, ch in ipairs(st.chunks or {}) do
        for _, cell in ipairs(ch.cells or {}) do
          if type(cell[4]) == 'string' and cell[4]:match('^[^{(:/]*') == 'Cw' and #tiles < 24 then
            local tl = {}
            cell_tiles(ch, cell, tl)
            if tl[1] then tiles[#tiles + 1] = {tl[1][1], tl[1][2], tl[1][3]} end
          end
        end
      end
    end
  end
  if #tiles == 0 then return nil end
  local kind, n, w = Q.wall_reach(K, tiles)
  if not kind then return nil end
  local m = K.mode()
  if kind ~= 'cut' and d.tpl == 'repair' and m ~= 'PEACE' and m ~= 'RECOVERY' then return nil end
  local way = 'close with doors (close=door: the kernel orders them at the workshop) or wall once they are in (BUG-458)'
  if kind == 'cut' then
    Q.note_cut(K, tiles, n, how or 'place', d.id, Q.cut_parts(w, 4))
    return string.format('refused: the %s walls (%d) would cut %d off the main walk group (%s); %s', d.tpl, #tiles, n,
                         Q.cut_parts(w, 4), way)
  end
  local why = kind == 'unknown' and string.format("the citizens' reach is not known (%s)", trunc(w.why or '?', 60))
              or string.format('the reach check ran out of tiles (%d places not met: %s)', n, Q.cut_parts(w, 4))
  Q.note_cut(K, tiles, 0, how or 'place', d.id, why)
  return string.format('refused: the %s walls (%d) cannot be proven safe: %s; %s', d.tpl, #tiles, why, way)
end

-- BUG-487 (Run 16b i2 Roadvises y401: `bp.place seal at=audit` was refused here for a wall that cuts one citizen off, then the
-- plan's seal@S1 on the same bypass went through plan.reload -> sync_plan -> register with no reach check, the kernel built
-- the wall and 12 citizens died of thirst behind it): the refusals leave WALL_REFUSED (B, once a game day per tile) in the
-- event stream, so `plan check` / `plan propose` / follow's seal at=audit know the tile and draft close=door
function Q.note_cut(K, tiles, n, how, proj, why)
  S.rt.wc = obj(S.rt.wc)
  local t, ats = now(K), {}
  local fresh = false
  for _, tl in ipairs(tiles) do
    local at = tkey(tl[1], tl[2], tl[3])
    if #ats < 6 then ats[#ats + 1] = at end
    if t - (int(S.rt.wc[at]) or -2 * DAY) >= DAY then S.rt.wc[at] = t; fresh = true end
  end
  if not fresh then return end
  local keys = {}
  for k in pairs(S.rt.wc) do keys[#keys + 1] = k end
  if #keys > 64 then                              -- a short memory: the oldest entries go
    table.sort(keys, function(a, b) return S.rt.wc[a] < S.rt.wc[b] end)
    for i = 1, #keys - 64 do S.rt.wc[keys[i]] = nil end
  end
  dirty()
  local msg = string.format('wall refused (%s): %s at %s: %s', how or '?', n > 0 and string.format('would cut %d off', n) or 'cannot be proven safe',
                            table.concat(ats, ' '), trunc(why or '?', 100))
  K.log('warn', '%s%s', msg, proj and (' (' .. tostring(proj) .. ')') or '')
  K.emit('WALL_REFUSED', 'B', trunc(msg, 200), {at = ats, n = n, how = how or '?', proj = type(proj) == 'string' and proj or nil,
                                                 why = trunc(why or '?', 160)})
end

-- BUG-487: a plan build's seal / repair walls that cut citizens off (or whose reach cannot be proven) become doors: the cells
-- 'Cw...' -> 'd...' (materials wall -> door). A wall on a ramp top cannot be a door (quickfort builds a door on a floor): then
-- nothing changes and the caller refuses the build. Returns the cells changed (0 = nothing)
function Q.walls_to_doors(K, d)
  local ramp = {}
  for x, y, z in tostring(type(d.params) == 'table' and d.params.at or ''):gmatch('(%-?%d+),(%-?%d+),(%-?%d+) ramp') do
    ramp[tkey(int(x), int(y), int(z) + 1)] = true
  end
  local list = {}
  for _, st in ipairs(d.stages or {}) do
    if st.mode == 'build' then
      for _, ch in ipairs(st.chunks or {}) do
        for _, cell in ipairs(ch.cells or {}) do
          if type(cell[4]) == 'string' and cell[4]:match('^[^{(:/]*') == 'Cw' then
            local tl = {}
            cell_tiles(ch, cell, tl)
            if tl[1] and ramp[tkey(tl[1][1], tl[1][2], tl[1][3])] then return 0 end
            list[#list + 1] = cell
          end
        end
      end
    end
  end
  for _, cell in ipairs(list) do cell[4] = 'd' .. cell[4]:sub(3) end
  local m = d.materials
  if #list > 0 and type(m) == 'table' and int(m.wall) then
    m.wall, m.door = int(m.wall) > #list and int(m.wall) - #list or nil, (int(m.door) or 0) + #list
  end
  return #list
end
-- the reason the wall fallback holds the door at `tile` back (r = the seal's S.rt.sf record), else nil
function Q.wall_refused(r, tile)
  local w = type(r) == 'table' and type(r.nw) == 'table' and tile and r.nw[tkey(tile[1], tile[2], tile[3])]
  return Q.wall_text(w) and w or nil
end

-- BUG-538 (Run 16d i4 Trumpetrealms y391-y399: the seal hatch on the stair 94,94,140 'walled in on its level' stayed stalled and
-- stale 300+ days under a seal_stalled decision, and `seal at=last` placed it again each time): a seal whose every open piece is
-- boxed (economy.build_state: no tile beside it on its level to build from, nobody takes it) for seal_boxed_days since its clock
-- stopped is cancelled by the kernel (a plain cancel drops only the unbuilt pieces and their jobs; what stands stays), with the
-- reason in kern.log and PROJECT_BLOCKED why boxed_cancel. Never the refuge's seal (it moves up its stair, BUG-313), never a piece
-- that is not boxed, one project a run. `seal at=last` no longer offers such a piece (cmd.stair_piece).
M.CFG.seal_boxed_days = 30
function Q.all_boxed(K, P, d)
  local st = d and d.stages[P.stage + 1]
  if not (st and st.mode == 'build') or P.stage + 1 < #d.stages then return false, 0 end
  local n, names = 0, {}
  for _, ch in ipairs(st.chunks) do
    for _, cell in ipairs(ch.cells) do
      local tl = {}
      cell_tiles(ch, cell, tl)
      local t = tl[1]
      if t and not piece_built(K, t) then
        local ok, bs = K.call('economy', 'build_state', t[1], t[2], t[3])
        if not (ok and Q.cls_of(bs) == 'boxed') then return false, 0 end
        n = n + 1
        if #names < 3 then names[#names + 1] = string.format('%s %d,%d,%d', PIECE_NAME[cell[4]] or cell[4], t[1], t[2], t[3]) end
      end
    end
  end
  return n > 0, n, names
end

function Q.boxed_cancel(K, c)
  if not c.on or K.mode() ~= 'PEACE' then return end
  local t = now(K)
  for _, P in ipairs(sorted()) do
    local r = P.tpl == 'seal' and P.done ~= 1 and P.blocked ~= 'cancel' and S.rt.sf[P.id]
    if type(r) == 'table' and r.st == 1 and r.why == 'boxed' and t - r.t >= M.CFG.seal_boxed_days * DAY
       and not Q.refuge_seal(K, P) then
      local d = doc(K, P.id)
      local all, n, names = Q.all_boxed(K, P, d)
      if all then
        local msg = string.format('%s (seal) cancelled by the kernel: %s walled in on its level (no tile beside it to build from), ' ..
                                  'no builder can take it; open %d d. Nothing built is removed. dfllm bp sites seal --fresh shows ' ..
                                  'what is still open', P.id, table.concat(names, ', '), (t - r.t) // DAY)
        K.log('warn', 'seal first: %s', msg)
        K.emit('PROJECT_BLOCKED', 'A', trunc(msg, 200), {proj = P.id, tpl = P.tpl, why = 'boxed_cancel', ticks = t - r.t,
                                                          parts = trunc(table.concat(names, '; '), 200)})
        cancel(K, P, false)
        rows(K)
        save(K)
        return
      end
    end
  end
end

function Q.stuck_walls(K, c)
  local okr, er = pcall(Q.stuck_replace, K, c)                 -- BUG-274: own pcall
  if not okr then K.log('error', 'seal re-place failed: %s', trunc(er, 160)) end
  local okb, eb = pcall(Q.boxed_cancel, K, c)                  -- BUG-538: own pcall
  if not okb then K.log('error', 'boxed seal cancel failed: %s', trunc(eb, 160)) end
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
            if refuse == nil and not (type(bs) == 'table' and bs.work == true) then
              refuse = Q.wall_refuse(K, P, d, tile)         -- BUG-458: never wall off a citizen, a farm, a shop, a depot, an office
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
              moved(K, R)                                      -- BUG-328: the kernel's own step (a set-aside seal is back)
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
              if Q.wall_text(refuse) then                   -- BUG-458: no wall here: the door is made at the workshop
                Q.note_cut(K, {tile}, 0, 'door', P.id, refuse)      -- BUG-487: the tile is known to the plan
                local okd, n = K.call('economy', 'seal_doors', 1)
                if okd and int(n) and int(n) > 0 then
                  K.log('warn', 'seal first: %s: door %s: %d door task(s) added at the workshops (no wall: %s)', P.id, at, int(n),
                        refuse)
                end
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
  local aw = Q.aq_wait(K, P, d)                  -- FR-95: a fortcore below the aquifer waits for the passed shaft
  if aw then return aw end
  local f = S.focus
  if not f or SEALS[P.tpl] then return nil end
  local k, m = kind_of(P, d), K.mode()
  if f.lead and f.c.on and m == 'PEACE' and SEAL_PAUSES[k] and not (k == 'supply' and (f.emerg or f.low)) then
    local st = d and d.stages[P.stage + 1]
    local en = P.tpl == 'workshops' and Q.door_shop(d) and Q.door_need(K, f)     -- BUG-273: the seal's enabler runs
    if en then
      f.en = f.en or {}
      if not f.en[P.id] then f.en[P.id] = en; f.en[#f.en + 1] = P.id end
    elseif not (f.rock and st and st.mode == 'dig') then return 'seal ' .. f.lead end
  end
  -- BUG-116: care first (the hospital leads, the work and housing projects wait; never the hospital itself)
  if f.care and not f.care_stuck and f.care ~= P.id and m == 'PEACE' and Q.CARE_PAUSES[k] then
    return 'care ' .. f.care
  end
  if f.rb and (m == 'PEACE' or m == 'RECOVERY') and not REBUILD_RUNS[k] and not (k == 'tomb_shops' and f.dead) then
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
      if f.emerg or f.low then head = head .. ' (' .. (f.emerg or f.low) .. ': food/drink projects go on)' end
      if f.en and #f.en > 0 then                  -- BUG-273
        head = string.format('%s (%s workshops go on: Carpenter\'s/Mason\'s for %s)', head, f.en[1], f.en[f.en[1]])
      end
      if f.ph then head = head .. ' (' .. f.ph .. ')' end                     -- BUG-276
    elseif why:sub(1, 5) == 'care ' then
      head = string.format('care first: %s with %s runs first', f.care, f.care_why or '?')
    elseif f.rb and why:sub(1, 8) == 'rebuild ' then
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
  local list, last, pk, aside = {}, {}, {}, {}
  for _, P in ipairs(sorted()) do
    if Q.parked(K, P, pt) then pk[P.id] = true; last[#last + 1] = P
    elseif Q.idle(P) then aside[#aside + 1] = P                -- BUG-328: set aside, before the parked ones
    else list[#list + 1] = P end
  end
  for _, P in ipairs(aside) do list[#list + 1] = P end
  for _, P in ipairs(last) do list[#list + 1] = P end
  local t = now(K)
  for _, P in ipairs(list) do
    if #out >= 8 then break end
    local d = doc(K, P.id)
    local st = d and d.stages[P.stage + 1]
    local b = P.blocked
    if not pk[P.id] and Q.idle(P) then             -- BUG-328 (no 'parked' word: plan reads that as blocked for good)
      local R = S.rt.p[P.id]
      local ps = type(R) == 'table' and int(R.ps) or int(S.rt.ip[P.id].ps) or t
      b = string.format('set aside %d d: %s (bp.resume)', math.max(0, (t - ps) // DAY), S.rt.ip[P.id].why or 'no progress')
    elseif (b == '' or b == 'stalled') and S.ur and S.ur[P.id] then
      local R = S.rt.p[P.id]                       -- BUG-352: no citizen reaches its dig
      local ps = type(R) == 'table' and int(R.ps) or int(S.ur[P.id].ps) or t
      b = string.format('unreachable %d d: bp.cancel, place again', math.max(0, (t - ps) // DAY))
    elseif b == '' then
      local ok = allowed(K, P, d)
      local pw = ok and paused(K, P, d)
      local yd = S.yielded and S.yielded[P.id]
      if not ok then
        b = 'frozen'
        local lw = S.life and S.life[P.id]                        -- BUG-347: life support with tiles off the burrow
        -- only a measure of this mode (BREACH/DRILL freeze everything and never measure: no stale tile count)
        if lw and lw.si == P.stage and lw.why and lw.m == K.mode() then b = 'frozen: ' .. lw.why end
      elseif pw then b = 'paused: ' .. pw
      elseif S.active and not S.active[P.id] then
        -- BUG-371: a mood project never queues behind others, it starts in the next run (said so, not 'queued behind <seal>')
        b = yd and string.format('no progress %d d: slot yielded', yd) or (Q.mood_proj(P) and 'mood: starts next run') or behind
      end
    elseif pk[P.id] then b = 'parked: ' .. b
    elseif b == 'stalled' then                     -- BUG-154 (live i4): a stalled project is not halted and still paused
      local pw = allowed(K, P, d) and paused(K, P, d)
      if pw then b = 'stalled, paused: ' .. pw end
    end
    if P.tpl == 'aqshaft' and b == '' then b = M.AQ.stall_text(S.rt, P.id) end     -- BUG-412: a visible stall
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
  -- BUG-300 (Run 15 Inkintense: P0 for years beside a farm plot that stands, its project parked build_lost at 40 %):
  -- farms is met once a farm plot stands, whoever built it
  proj = function(K, dv)
    return proj_reached(K, dv.tpl, int(dv.stage)) or (dv.tpl == 'farms' and not dv.stage and Q.farm_plots() > 0)
  end,
  squads = function(K, dv) local v = K.view().mil; return v ~= nil and (v.squads or 0) >= dv.n end,
  -- BUG-493: a drill whose bridges worked meets the phase (the R2 pass also wants worn >= 90: a fort without metal never gets it)
  drill = function(K) local v = K.view().ready; return v ~= nil and ((v.drill_age or -1) >= 0 or (v.drill_mech_age or -1) >= 0) end,
  stock = function(K, dv)
    local v = K.view().stock
    return v ~= nil and type(v[dv.key]) == 'number' and v[dv.key] >= dv.min
  end,
  orders = function(K, dv) local ok, v = K.call('economy', 'imported', dv.lib); return ok and v == true end,
  trade = function(K, dv) local ok, v = K.call('trade', 'done'); return ok and type(v) == 'number' and v >= dv.n end,
  ready = function(K, dv) local v = K.view().ready; return v ~= nil and (v.lvl or 0) >= dv.lvl end,
  metal = function(K, dv) local v = K.view().mil; return v ~= nil and (v.metal_pct or 0) >= dv.pct end,
  bolts = function(K, dv) local v = K.census.i; return v ~= nil and (v.bolts or 0) >= dv.n end,
  -- FR-99: the caverns are clear (no beast seen at a plugged shaft, the last sweep done) or no cavern way is known
  sweep = function(K) local ok, v = K.call('cavern', 'cleared'); return ok and v == true end,
  -- FR-100 (G18): soldiers fully equipped (armor + a weapon in hand, state mil.kit) >= pct % of the soldiers, and some
  kit = function(K, dv)
    local v = K.view().mil
    local t = type(v) == 'table' and v.kit
    return type(t) == 'table' and (t.n or 0) > 0 and 100 * (t.full or 0) >= (dv.pct or 100) * t.n
  end,
  workshops = function(K, dv) return #Q.ws_missing(K, dv) == 0 end,
}

-- the workshop types of a `workshops` deliverable that no workshop of the manifest or the map has (BUG-301: the status
-- line names them)
function Q.ws_missing(K, dv)
    local have, miss = {}, {}
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
      for _, n in ipairs(t == 'moodable' and M.MOODABLE or {t}) do if not have[n] then miss[#miss + 1] = n end end
    end
    return miss
end

-- BUG-300: built farm plots on the map (0 when unreadable)
function Q.farm_plots()
  local ok, n = pcall(function()
    local c = 0
    for _, b in ipairs(df.global.world.buildings.other.FARM_PLOT) do if built(b) then c = c + 1 end end
    return c
  end)
  return ok and n or 0
end

-- BUG-300/301: a deliverable's key (what phase.waive names: the template, 'fortcore 2', 'workshops', or the kind) and
-- the text the status line shows for one that is not met
function Q.dv_key(dv)
  if dv.k == 'proj' then return tostring(dv.tpl) .. (int(dv.stage) and (' ' .. int(dv.stage)) or '') end
  -- review: several stock / orders deliverables of one phase (P5 drink_d and food_d, P3 three order libraries) get
  -- keys of their own, so one waiver never waives its siblings ('stock_drink_d', 'orders_rockstock')
  local sub = dv.k == 'stock' and dv.key or (dv.k == 'orders' and type(dv.lib) == 'string' and dv.lib:match('([^/]+)$'))
  if sub then return trunc(((tostring(dv.k) .. '_' .. tostring(sub)):lower():gsub('[^a-z_0-9]', '_')), 24) end
  return tostring(dv.k)
end
function Q.dv_text(K, dv)
  local k = Q.dv_key(dv)
  if dv.k == 'workshops' then
    local m = Q.ws_missing(K, dv)
    return trunc(k .. ' ' .. table.concat(m, ',', 1, math.min(#m, 4)) .. (#m > 4 and ('+' .. (#m - 4)) or ''), 40)
  end
  if dv.k == 'stock' then return trunc(string.format('%s>=%s', k, tostring(dv.min)), 40) end
  if dv.k == 'orders' then   -- BUG-524: the library's stage gate says what is missing (economy.held_why)
    local ok, why = K.call('economy', 'held_why', dv.lib)
    return trunc(k .. ((ok and type(why) == 'string' and why ~= '') and (' ' .. why) or ''), 40)
  end
  local n = dv.n or dv.lvl or dv.pct or dv.lib
  return trunc(n ~= nil and (k .. ' ' .. tostring(n)) or k, 40)
end

-- BUG-300 (Run 15 Drillchamber: P0 for six years, plans at P5, because `farms` can never be built: every farm site is
-- stone without water, 0 of 126 farm tiles, `bp sites farms` 0 ranked; so traps P5, kit and sweep P6, rooms P7 never came):
-- a deliverable that cannot be made is waived with its reason (persist phase.waive {d, why, ph, t, by}: by phase.waive of
-- follow or the player, or the kernel's own rule: every farms project lost to build_lost (plots need soil or mud) and
-- parked). A waived deliverable does not hold the phase; the status line names it.
Q.WAIVE_MAX = 8
function Q.waiver(ph, key)
  for _, w in ipairs(type(ph) == 'table' and type(ph.waive) == 'table' and ph.waive or {}) do
    -- review: a waiver holds in the phase it was given for only (P0 workshops waived must not waive P1 workshops,
    -- nor P2 squads those of P5)
    if w.d == key and (w.ph == nil or w.ph == ph.phase) then return w end
  end
end
function Q.add_waive(K, ph, key, why, by)
  if type(ph.waive) ~= 'table' then ph.waive = {} end
  ph.waive[#ph.waive + 1] = {d = trunc(key, 40), why = trunc(why, 80), ph = ph.phase, t = now(K), by = trunc(by, 16)}
  while #ph.waive > Q.WAIVE_MAX do table.remove(ph.waive, 1) end
  K.persist.touch('phase')
  K.log('warn', 'phase %s: %s cannot be made (%s, by %s): waived, the phase goes on without it', ph.phase, key,
        trunc(why, 80), trunc(by, 16))
end
function Q.auto_waive(K, dv)
  if dv.k ~= 'proj' or dv.tpl ~= 'farms' or dv.stage then return nil end
  local n = M.lost(K, 'farms')
  if (n or 0) == 0 then return nil end
  local pt = conf(K).park
  for _, P in ipairs(S.pd.list) do if P.tpl == 'farms' and Q.live(K, P, pt) then return nil end end
  return string.format('%d farms project(s) lost to build_lost: plots need soil or mud', n)
end

-- all deliverables pass?; second value: a failing one depends on projects (proj, workshops)
-- BUG-300/301: third and fourth values: the texts of the deliverables it waits for, and the waived ones ('farms: why');
-- pd = the persisted phase doc (its waivers)
local function check_phase(K, ph, pd)
  local pass, plan_fail, wait, wv = true, false, {}, {}
  for _, dv in ipairs(type(ph.deliver) == 'table' and ph.deliver or {}) do
    local f = CHECK[dv.k]
    local mod = dv.k == 'stock' and dv.key == 'hosp_water' and 'care' or OWNER[dv.k]
    local ok = f ~= nil and ((mod ~= nil and absent(K, mod)) or f(K, dv) == true)
    if not ok then
      local key = Q.dv_key(dv)
      local w = Q.waiver(pd, key)
      if not w and type(pd) == 'table' then
        local why = Q.auto_waive(K, dv)
        if why then Q.add_waive(K, pd, key, why, 'kernel'); w = Q.waiver(pd, key) end
      end
      if w then wv[#wv + 1] = trunc(key .. ': ' .. tostring(w.why), 100)
      else
        pass = false; plan_fail = plan_fail or PLAN_DRIVEN[dv.k] == true
        wait[#wait + 1] = Q.dv_text(K, dv)
      end
    end
  end
  return pass, plan_fail, wait, wv
end

local function phases(K)
  local list = phase_list(K)
  local ph = K.persist.get('phase')
  S.stuck = true
  S.phw = nil
  if not list then S.phase = type(ph) == 'table' and ph.phase or nil; return end
  if type(ph) ~= 'table' or not idx_of(list, ph.phase) then
    ph = {v = 2, phase = list[1].id, since = now(K), done = {}}
    K.persist.set('phase', ph)
  end
  local target = pnum(K.plan.phase_target) or 0
  for _ = 1, #list do
    local i = idx_of(list, ph.phase)
    local cur, nxt = list[i], list[i + 1]
    local pass, plan_fail, wait, wv = check_phase(K, cur, ph)
    -- BUG-301: what holds the phase (and what was waived) for the status line
    S.phw = (#wait > 0 or #wv > 0) and {wait = {table.unpack(wait, 1, math.min(#wait, 4))},
                                         waived = {table.unpack(wv, 1, math.min(#wv, 4))}} or nil
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
  -- BUG-382 (Run 16c i3: drink 150 -> 0 days with 16 brews waiting and 'no brewable plants' beside food 378 days; the zone
  -- was removed at food > gather_off and never drawn again): economy's stock.bshort (drink below gather.drink_d, too few
  -- brewable plants) draws the zone like low food does, and keeps it
  local dshort = type(st) == 'table' and int(st.bshort) == 1
  local g = S.rt.gather
  -- BUG-074: a zone an older kernel drew (no v) covers its whole square, unreachable plants included: while food is still
  -- short it is removed once and drawn again on the citizens' walk group (when that group is known)
  if type(g) == 'table' and g.v ~= 2 and type(g.z) == 'table' and #g.z > 0 and (fd < M.CFG.gather_below or dshort)
     and (K.now().season or 0) < 3 and Q.home_group(K) then
    local ok, n = K.act.zone_remove(GATHER)
    K.log('info', 'gather zone of an older kernel (the whole square) removed, %s zones: drawn again on the citizens\' walk group',
          ok and tostring(n) or 'failed')
    S.rt.gather, g = nil, nil
    dirty()
  end
  if type(g) == 'table' then
    -- BUG-382: a zone drawn for the drink (g.dr) goes once the drink is back and food is not low; one drawn for food at
    -- gather_off food days, unless the drink needs it
    if not dshort and (fd > M.CFG.gather_off or (g.dr and fd >= M.CFG.gather_below)) then
      local ok, n = K.act.zone_remove(GATHER)
      S.rt.gather = nil
      dirty()
      K.log('info', 'gather zone removed (food %d days, %s zones)', fd, ok and tostring(n) or 'failed')
    end
    return
  end
  if (fd >= M.CFG.gather_below and not dshort) or (K.now().season or 0) >= 3 then return end
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
  S.rt.gather = {v = 2, z = made, x = x0, y = y0, side = side, t = now(K), g = home, n = drawn, out = out,
                 dr = (fd >= M.CFG.gather_below and dshort) or nil}
  dirty()
  if home and not whole then
    K.log('warn', 'food %d days%s: gather zone at %d,%d on z %s: %d tiles in %d rects on the citizens\' walk group %d, ' ..
          '%d tiles of the %dx%d square left out (not on that group, or past the %d-rect cap)', fd,
          dshort and ', drink plants short' or '', x0, y0,
          table.concat(made, ','), drawn, nrect, home, out, side, side, M.CFG.gather_rects)
  else
    K.log('warn', 'food %d days%s: gather zone %dx%d at %d,%d on z %s (%d tiles; the citizens\' walk group is unknown, ' ..
          'nothing left out)', fd, dshort and ', drink plants short' or '', side, side, x0, y0, table.concat(made, ','), side * side * #made)
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

-- BUG-612 (Run 16c i3 Wallfree y375-y376: DEPOT_MISSING 'no known depot site (no fortcore depot)', a caravan unloaded nothing, drink 201 -> 15 d,
-- the template `depot` and `bp sites depot` found no site): a fort with no fortcore and no manifest depot looks for a flat 5x5 block of walkable
-- open floor around its citizens on their own walk group (snapshot.groups, 25 tiles in one call), nearest first, at most DEPOT_TRIES blocks, and
-- tries again only after DEPOT_RETRY ticks. Returns {x, y, z} (the middle) or nil, why.
M.CFG.depot_tries, M.CFG.depot_radius, M.CFG.depot_retry = 220, 30, 36000
M.CFG.depot_resite_max = 4

-- BUG-719 (Run 16c i3 Doorwings y372: depot1..25 on the aqshaft anchor 94,98,148; Run 16d i4 Pagedsculpture y372: depot1..15 at 96,95,142 with a
-- stair, a trap and a door in the footprint): the tiles of the projects still open (an aqshaft, a fortcore ...) and the sites that already failed
-- are no depot site; a depot footprint is open floor on every one of its 25 tiles (a stair is walkable and shares the walk group, so the walk
-- group alone proved nothing). Returns the set 'x,y,z' = why of the tiles to keep off.
function Q.depot_avoid(K)
  local avoid = {}
  for _, P in ipairs(S.pd.list) do
    if P.tpl ~= 'depot' and P.done ~= 1 then
      local d = doc(K, P.id)
      if type(d) == 'table' and type(d.stages) == 'table' then
        local okd, own = pcall(own_tiles, P, d)
        if okd and type(own) == 'table' then for k in pairs(own) do avoid[k] = P.id end end
      end
    end
  end
  return avoid
end
function Q.depot_bad(pos)
  local bad = type(S.rt.depot_bad) == 'table' and S.rt.depot_bad or {}
  return bad[tkey(pos[1], pos[2], pos[3])] == true
end
-- nil when the 5x5 block around pos is clear (every tile open floor, nothing built or designated, no tile of another open project), else why
function Q.depot_block_why(K, pos, avoid)
  for y = pos[2] - 2, pos[2] + 2 do
    for x = pos[1] - 2, pos[1] + 2 do
      local k = tkey(x, y, pos[3])
      if avoid[k] then return string.format('%s lies in project %s', k, tostring(avoid[k])) end
      local ok, v = K.call('snapshot', 'tile', x, y, pos[3])
      if not (ok and type(v) == 'table') or v.c == nil or v.c == '?' then return k .. ' is hidden' end
      if type(v.bld) == 'string' and v.bld ~= '' then return string.format('%s holds a %s', k, v.bld) end
      if v.c ~= '.' then return string.format('%s is no open floor (%s)', k, tostring(v.c)) end
      if type(v.dig) == 'string' and v.dig ~= '' then return k .. ' is designated' end
    end
  end
  return nil
end

function Q.depot_fallback(K)
  local cu, pts = K.census.u, {}
  for _, id in ipairs(type(cu) == 'table' and type(cu.ids) == 'table' and cu.ids or {}) do
    if #pts >= 50 then break end
    local u = df.unit.find(id)
    local ok, x, y, z
    if u then ok, x, y, z = pcall(dfhack.units.getPosition, u) end
    if ok and int(x) then pts[#pts + 1] = {x, y, z} end
  end
  if #pts == 0 then return nil, 'no citizen position' end
  local home = Q.home_group(K)
  if not home then return nil, 'the walk group of the citizens is unknown' end
  local sx, sy, sz, zs = 0, 0, {}, nil
  for _, q in ipairs(pts) do sx, sy = sx + q[1], sy + q[2]; sz[q[3]] = (sz[q[3]] or 0) + 1 end
  for z, n in pairs(sz) do if not zs or n > sz[zs] or (n == sz[zs] and z > zs) then zs = z end end
  local cx, cy = sx // #pts, sy // #pts
  local R, cand, avoid = M.CFG.depot_radius, {}, nil
  for dx = -R, R, 3 do for dy = -R, R, 3 do cand[#cand + 1] = {dx, dy, dx * dx + dy * dy} end end
  table.sort(cand, function(a, b) if a[3] ~= b[3] then return a[3] < b[3] end if a[1] ~= b[1] then return a[1] < b[1] end return a[2] < b[2] end)
  for i = 1, math.min(#cand, M.CFG.depot_tries) do
    local x0, y0 = cx + cand[i][1] - 2, cy + cand[i][2] - 2
    if on_map(x0, y0, zs) and on_map(x0 + 4, y0 + 4, zs) then
      local block = {}
      for y = y0, y0 + 4 do for x = x0, x0 + 4 do block[#block + 1] = {x, y, zs} end end
      if S.slice then S.slice.probes = S.slice.probes + 1 end
      local okg, gr = K.call('snapshot', 'groups', block, false)
      local all = okg and type(gr) == 'table'
      for k = 1, #block do if not (all and int(gr[k]) == home) then all = false; break end end
      if all then
        local mid = {x0 + 2, y0 + 2, zs}
        avoid = avoid or Q.depot_avoid(K)
        if not Q.depot_bad(mid) and not Q.depot_block_why(K, mid, avoid) then return mid end   -- BUG-719: every tile, not only the middle
      end
    end
  end
  return nil, string.format('no flat 5x5 block of open floor within %d tiles of the citizens', R)
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
    if c then       -- BUG-719: a site that held a depot is no failed site
      S.rt.depot_stood = type(S.rt.depot_stood) == 'table' and S.rt.depot_stood or {}
      local k = tkey(c[1], c[2], c[3])
      if not S.rt.depot_stood[k] then S.rt.depot_stood[k] = true; dirty() end
    end
    return true, 'standing'
  end
  -- BUG-719: a depot project that reported done (or build_lost twice) while no depot stands has a site that cannot take it: that site is
  -- remembered as bad, the project is dropped and the next site looks elsewhere; after depot_resite_max failed sites the keeper stops and says why
  S.rt.depot_bad = type(S.rt.depot_bad) == 'table' and S.rt.depot_bad or {}
  for _, P in ipairs(S.pd.list) do
    if P.tpl == 'depot' then
      local dd = doc(K, P.id)
      local c = type(dd) == 'table' and type(dd.manifest) == 'table' and dd.manifest.depot
      local site = type(c) == 'table' and int(c[1]) and int(c[2]) and int(c[3]) and {int(c[1]), int(c[2]), int(c[3])} or nil
      local q = S.rt.rty[P.id]
      local lost = P.blocked == 'build_lost' and type(q) == 'table' and (int(q.n) or 0) >= 2
      S.rt.depot_chk = type(S.rt.depot_chk) == 'table' and S.rt.depot_chk or {}
      local stood = type(S.rt.depot_stood) == 'table' and site and S.rt.depot_stood[tkey(site[1], site[2], site[3])]
      if site and not stood and ((P.done == 1 and not S.rt.depot_chk[P.id]) or lost) then
        S.rt.depot_chk[P.id] = true
        local why = (P.done == 1) and 'reported done, no trade depot stands' or 'build_lost twice'
        if lost then
          local okl, lw = pcall(Q.lost_why, K, P, dd)
          if okl and lw then why = why .. ': ' .. trunc(lw, 100) end
        end
        S.rt.depot_bad[tkey(site[1], site[2], site[3])] = true
        S.rt.dfb_t = nil                  -- the next site is searched at once
        if P.done ~= 1 then cancel(K, P, true) end
        if type(S.rt.depot) == 'table' and S.rt.depot[1] == site[1] and S.rt.depot[2] == site[2] and S.rt.depot[3] == site[3] then
          S.rt.depot = nil
        end
        K.log('warn', 'trade depot site %d,%d,%d given up (%s: %s)', site[1], site[2], site[3], P.id, why)
        dirty()
      elseif Q.live(K, P) then
        return true, P.id               -- BUG-037: a parked one is no depot project
      end
    end
  end
  local nb = 0
  for _ in pairs(S.rt.depot_bad) do nb = nb + 1 end
  if nb >= M.CFG.depot_resite_max then
    if not S.rt.depot_stop then
      S.rt.depot_stop = true
      dirty()
      K.log('warn', 'trade depot: %d sites failed (no depot stood after the project), no more projects; place one by hand: bp.place with a site, or cancel the project that holds the tiles', nb)
    end
    return false, 'no depot site stood the build'
  end
  local m = K.manifest().depot
  local pos = type(m) == 'table' and int(m[1]) and int(m[2]) and int(m[3]) and {int(m[1]), int(m[2]), int(m[3])}
              or (type(S.rt.depot) == 'table' and int(S.rt.depot[1]) and S.rt.depot) or nil
  if pos and Q.depot_bad(pos) then pos = nil; S.rt.dfb_t = nil end        -- BUG-719: that site failed; search another
  local fb
  local stood0 = type(S.rt.depot_stood) == 'table' and pos and S.rt.depot_stood[tkey(pos[1], pos[2], pos[3])]
  if pos and not stood0 then          -- a site that held a depot is rebuilt where it stood (FR-43), never re-checked
    local why = Q.depot_block_why(K, pos, Q.depot_avoid(K))
    if why and (type(m) ~= 'table' or not int(m[1])) then            -- a remembered fallback site: re-checked; a manifest site is the plan's
      S.rt.depot_bad[tkey(pos[1], pos[2], pos[3])] = true
      K.log('warn', 'trade depot site %d,%d,%d given up: %s', pos[1], pos[2], pos[3], why)
      pos, S.rt.depot, S.rt.dfb_t = nil, nil, nil
      dirty()
    end
  end
  if not pos then
    -- BUG-612: no fortcore, no manifest depot: a flat block of open floor beside the citizens (looked for every depot_retry ticks)
    local t = now(K)
    if S.rt.dfb_t and t - S.rt.dfb_t < M.CFG.depot_retry then return false, 'no known depot site' end
    S.rt.dfb_t = t
    dirty()
    local why2
    pos, why2 = Q.depot_fallback(K)
    if not pos then
      K.log('warn', 'trade depot missing, no site: %s', tostring(why2))
      return false, 'no known depot site'
    end
    fb = true
  end
  local n = (int(S.rt.depot_n) or 0) + 1
  local id = string.format('depot%d', n)
  local ok, err = register(K, id, depot_doc(pos), M.CFG.depot_prio, 'depot')
  if not ok then return false, err end
  S.rt.depot_n = n
  if fb then S.rt.depot = pos end
  dirty()
  save(K)
  K.log('warn', 'trade depot missing (%s): project %s at %d,%d,%d%s', tostring(why or 'keeper'), id, pos[1], pos[2], pos[3],
        fb and ' (surface fallback beside the citizens: no fortcore, no manifest depot)' or '')
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
        K.log('warn', 'manifest: workshop %s at %d,%d,%d no longer stands (%d scans): out of the manifest; `bp.place workshops ' ..
              'only=%s rebuild=1` builds it again there (BUG-562)', tostring(w.type), p[1], p[2], p[3], n, tostring(w.type))
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
  -- BUG-357: a new fort whose stages deferred a door for want of a Carpenters or Masons workshop asks for the mandatory shops
  -- like a reclaimed one (S.rt.dd, set by measure_build)
  if (ad.rec == 1 or int(S.rt.dd)) and #miss > 0 then
    S.rt.wmiss = int(S.rt.wmiss) or t
    -- BUG-181: a pending workshops project holds back only the types it builds (live i4: skip=Masons held the Masons back)
    local want = M.uncovered(K, 'workshops', miss)
    if K.mode() == 'PEACE' and t - S.rt.wmiss >= rc.ask and #want > 0 and M.req_due(K, 'wsm', want) then
      miss = want
      local names = table.concat(miss, ', ')
      K.log('warn', 'reclaimed fort without %s: workshops project requested (dfllm bp sites workshops; the fort cannot ' ..
            'make coffins, crafts or meals without them)', names)
      K.emit('PROJECT_REQUEST', 'B', trunc('workshops x' .. #miss .. ': mandatory ' .. names .. ' missing', 200),
             {tpl = 'workshops', n = #miss, why = 'mandatory', types = miss})
    end
  else
    S.rt.wmiss = nil
    if #miss == 0 then S.rt.dd = nil end                                    -- BUG-357: every mandatory shop stands
    if type(S.rt.req.wsm) == 'table' then S.rt.req.wsm.k = 0 end            -- BUG-184: a new episode starts unbacked
  end
  dirty()
end
Q.MANDATORY = {'Carpenters', 'Masons', 'Craftsdwarfs', 'Still', 'Kitchen'}

---------------------------------------------------------------- build_lost: missing pieces and the retry (BUG-022)

-- BUG-536 (Run 16d i4 Trumpetrealms: 'blocked: build_lost at build, missing D' for a depot, 16 retries, no reason): the name of a
-- multi-tile building's key
M.BIG_PIECE = {D = 'trade depot'}
-- BUG-655 (Run 16a i1 Basementflew y442-y466: hospital 'build_lost at build, missing b x4' in six projects, nobody knew what b was): the
-- furniture keys of a build stage by name. Doors, plots and walls keep their key (d, p, Cw): the older messages and tests read them.
M.PIECE_WORD = {b = 'bed', h = 'chest', t = 'table', c = 'chair', R = 'traction bench'}

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
  return M.BIG_PIECE[key] or M.PIECE_WORD[key] or key
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

-- BUG-608 (Run 16a i1 Basementflew y426-y429: the hospital stayed build_lost, 7 parts 'buildingplan: waiting for materials', 8 retries; its
-- boulders, blocks and logs lay in the flooded z117 complex on another walk group): the pieces of the blocked build stage that economy cannot make
-- now (economy.mat_for per piece kind: 'no material for bed: no logs'), with the stock that lies out of the citizens' reach
-- (census rock_far / blocks_far / doors_far ...). Text or nil (all can be made, or nothing is known). build_lost names it, and
-- retry_step does not repeat a season-old retry while it stands (the pieces would wait for the same material again).
Q.KEY_KIND = {b = 'bed', t = 'table', h = 'chest', c = 'chair', f = 'cabinet', d = 'door', H = 'hatch', W = 'grate', G = 'grate'}
function Q.mat_why(K, P, d)
  local st = d and d.stages[P.stage + 1]
  if not (st and st.mode == 'build') then return nil end
  local need, order = {}, {}
  for _, ch in ipairs(st.chunks) do
    for _, cell in ipairs(ch.cells) do
      local tl = {}
      cell_tiles(ch, cell, tl)
      local t = tl[1]
      local kind = t and Q.KEY_KIND[t[4]]
      if kind and not cell_present(K, t) then
        if not need[kind] then need[kind] = 0; order[#order + 1] = kind end
        need[kind] = need[kind] + 1
      end
    end
  end
  local bad = {}
  for _, kind in ipairs(order) do
    local ok, via, w = K.call('economy', 'mat_for', kind, need[kind])
    if ok and not via and type(w) == 'string' then bad[#bad + 1] = string.format('%s x%d: %s', kind, need[kind], (w:gsub('^no material for %S+ ?%S*: ', ''))) end
  end
  if #bad == 0 then return nil end
  local far, inv = {}, K.census.i or {}
  for _, k in ipairs({'rock_far', 'blocks_far', 'doors_far', 'chairs_far', 'tables_far'}) do
    local n = int(inv[k]) or 0
    if n > 0 then far[#far + 1] = string.format('%d %s', n, k:gsub('_far$', '')) end
  end
  return trunc(table.concat(bad, '; ') .. (#far > 0 and ('; out of reach (another walk group): ' .. table.concat(far, ', ')) or ''), 160)
end

-- BUG-655 (Run 16a i1 Basementflew: the hospital's four beds 'missing b x4' for 8 retries in six projects, 283 logs in the fort, no order for
-- them, no word why): per missing piece kind (bed, chest, table, ...) what its supply lacks, from economy.piece_supply ('bed x4: no
-- ConstructBed order open, Carpenters cut off at ...'). Text (<= 160) and the command lines that fix it, or nil when every kind is
-- supplied (an order is open and the shop stands: the wait is the shop's)
function Q.supply_why(K, P, d)
  local st = d and d.stages[P.stage + 1]
  if not (st and st.mode == 'build') then return nil end
  local need, order = {}, {}
  for _, ch in ipairs(st.chunks) do
    for _, cell in ipairs(ch.cells) do
      local tl = {}
      cell_tiles(ch, cell, tl)
      local t = tl[1]
      local kind = t and Q.KEY_KIND[t[4]]
      if kind and not cell_present(K, t) then
        if not need[kind] then need[kind] = 0; order[#order + 1] = kind end
        need[kind] = need[kind] + 1
      end
    end
  end
  local parts, cmds = {}, {}
  for _, kind in ipairs(order) do
    local ok, txt, cmd = K.call('economy', 'piece_supply', kind, need[kind])
    if ok and type(txt) == 'string' then
      parts[#parts + 1] = txt
      if type(cmd) == 'string' and #cmds < 3 then cmds[#cmds + 1] = cmd end
    end
  end
  if #parts == 0 then return nil end
  return trunc(table.concat(parts, '; '), 160), cmds
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
  -- BUG-257 (Run 15 Inkintense/Drillchamber: farms build_lost 'missing p' re-dug on the same stone site for 8 seasons):
  -- quickfort builds a farm plot only on soil or mud, a dig brings neither; the retries are spent at once (lost for good:
  -- economy asks follow for farms at another site, M.lost)
  if P.tpl == 'farms' then
    q.n = M.CFG.retry_max
    K.log('warn', '%s: farms build_lost: plots need soil or mud, a re-dig brings none: lost for good (placed elsewhere)',
          P.id)
    dirty()
    return
  end
  local d = doc(K, P.id)
  if not d then return end
  local why
  if q.sig == nil then                          -- the baseline, taken in the run that blocked it
    q.sig, q.c = retry_sig(K, P, d), t
    q.cant = P.tpl == 'seal' and not M.remake_why(K, P, d)      -- Run 11: blocked for want of material
    dirty()
  end
  -- BUG-608: a build_lost room (not a seal: M.remake_why has those) whose pieces cannot be made is not re-dug every season: it waits for
  -- the map (more tiles revealed or open) or for the material
  local aged = t - (int(q.t) or t) >= M.CFG.retry_every
  local nomat = aged and P.tpl ~= 'seal' and Q.mat_why(K, P, d) or nil
  if nomat and q.hold ~= nomat then
    q.hold = nomat
    K.log('warn', '%s: build_lost retry held, the pieces cannot be made: %s', P.id, nomat)
    dirty()
  end
  if aged and not nomat then why = 'a season passed'
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
  q.n, q.t, q.c, q.sig, q.cant, q.hold = q.n + 1, t, t, nil, nil, nil
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
  -- BUG-749 (Run 16a i1 Basementflew: the explore and tombs digs 'stalled 30 d at dig 6%: set aside' with nothing after it): a dig stage names its dig
  -- jobs (open, taken, suspended, raised) and the Miners detail (idle or at what job) and the tool answer
  if st and st.mode == 'dig' then
    local okb, tiles = pcall(stage_tiles, P.id, d, P.stage)
    local bb = okb and type(tiles) == 'table' and tiles.bbox or nil
    if bb and (tiles.n or 0) > 0 then
      local ok, dw = K.call('economy', 'dig_wait', bb)
      if ok and type(dw) == 'table' and type(dw.text) == 'string' then out[1] = trunc('dig: ' .. dw.text, 140) end
    end
    return out
  end
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
          -- BUG-679: the cause first (economy.build_state `short`), so the 80-110 characters the events keep name it
          out[#out + 1] = trunc(string.format('%s %d,%d,%d: %s', bs.sub or bs.kind or PIECE_NAME[t[4]] or t[4], t[1], t[2],
                                              t[3], type(bs.short) == 'string' and bs.short or bs.line), 140)
        end
      end
    end
  end
  return out
end

-- BUG-536: why a multi-tile building of the blocked build stage (the depot's 5x5) was not placed: the tiles of its footprint that
-- are no open floor on the revealed map (wall, tree, ramp, stair, open air, water, another building, hidden), and for the depot the
-- material economy cannot make. Text, or nil when the stage has no such building. A footprint that looks clear and a material that
-- exists say so: the cause is then not on the revealed map.
Q.FOOT_BAD = {['#'] = 'wall', S = 'wall', C = 'wall', F = 'wall', T = 'tree', ['<'] = 'stair', ['>'] = 'stair', X = 'stair',
                  r = 'ramp', v = 'ramp', ['_'] = 'open air'}
function Q.lost_why(K, P, d)
  local st = d and d.stages[P.stage + 1]
  if not (st and st.mode == 'build') then return nil end
  for _, ch in ipairs(st.chunks) do
    for _, cell in ipairs(ch.cells) do
      local w, h = cell[4]:match('%((%-?[0-9]+)x(%-?[0-9]+)%)')
      if w and h and (math.abs(int(w) or 1) > 1 or math.abs(int(h) or 1) > 1) then
        local tl = {}
        cell_tiles(ch, cell, tl)
        if not cell_present(K, tl[1]) then
          local bad, hidden, n = {}, 0, 0
          for _, t in ipairs(tl) do
            local ok, v = K.call('snapshot', 'tile', t[1], t[2], t[3])
            local why
            if not (ok and type(v) == 'table') or v.c == nil or v.c == '?' then hidden = hidden + 1
            elseif type(v.bld) == 'string' and v.bld ~= '' then why = 'a ' .. v.bld
            elseif Q.FOOT_BAD[v.c] then why = Q.FOOT_BAD[v.c]
            elseif (int(v.flow) or 0) >= 4 then why = 'water'
            elseif v.magma then why = 'magma' end
            if why then
              n = n + 1
              if #bad < 3 then bad[#bad + 1] = string.format('%d,%d,%d %s', t[1], t[2], t[3], why) end
            end
          end
          local parts = {}
          if n > 0 then parts[#parts + 1] = string.format('%d of %d footprint tiles are no open floor (%s)', n, #tl, table.concat(bad, ', ')) end
          if hidden > 0 then parts[#parts + 1] = string.format('%d hidden', hidden) end
          if P.tpl == 'depot' then
            local okm, via, mw = K.call('economy', 'mat_for', 'depot', 3)
            if okm and not via and mw then parts[#parts + 1] = 'no building material: ' .. trunc(tostring(mw), 60) end
          end
          if #parts == 1 and n == 0 and hidden > 0 then return nil end   -- only hidden tiles: the retry text says so already
          if #parts == 0 then
            parts[1] = string.format('the %dx%d footprint at %d,%d,%d looks clear and material exists: quickfort refused the site; ' ..
                                     'place it elsewhere', math.abs(int(w) or 1), math.abs(int(h) or 1), tl[1][1], tl[1][2], tl[1][3])
          end
          return table.concat(parts, '; ')
        end
      end
    end
  end
  -- BUG-721 (Run 16a i1 Basementflew: 'build_lost at build, missing bed x3' with no word why, 8 retries): the one-tile pieces. Those of the
  -- blocked stage that are not built and whose tile is no open floor (wall, tree, stair, ramp, open air, water, magma, another building) are named
  local bad, n, tot = {}, 0, 0
  for _, ch in ipairs(st.chunks) do
    for _, cell in ipairs(ch.cells) do
      local tl = {}
      cell_tiles(ch, cell, tl)
      local t = tl[1]
      if t and #tl == 1 and not cell_present(K, t) then
        tot = tot + 1
        local ok, v = K.call('snapshot', 'tile', t[1], t[2], t[3])
        local why
        if ok and type(v) == 'table' and v.c ~= nil and v.c ~= '?' then
          if type(v.bld) == 'string' and v.bld ~= '' then why = 'a ' .. v.bld
          elseif Q.FOOT_BAD[v.c] then why = Q.FOOT_BAD[v.c]
          elseif (int(v.flow) or 0) >= 4 then why = 'water'
          elseif v.magma then why = 'magma' end
        end
        if why then
          n = n + 1
          if #bad < 3 then bad[#bad + 1] = string.format('%d,%d,%d %s (%s)', t[1], t[2], t[3], why, M.PIECE_WORD[t[4]] or t[4]) end
        end
      end
    end
  end
  if n > 0 then
    return string.format('%d of %d missing pieces stand on tiles that are no open floor (%s)', n, tot, table.concat(bad, ', '))
  end
  return nil
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
    local sw, scmds
    if P.tpl ~= 'seal' then sw, scmds = Q.supply_why(K, P, d) end       -- BUG-655
    if not mw and P.tpl ~= 'seal' then mw = Q.mat_why(K, P, d) or sw end     -- BUG-608: the same for a room (a hospital)
    if mw then msg, dd.mat = msg .. ' (' .. mw .. ')', trunc(mw, 80) end
    local lw = Q.lost_why(K, P, d)           -- BUG-536: why the depot (a 5x5 building) was not placed
    if lw then msg, dd.parts = msg .. ': ' .. lw, trunc(lw, 200) end
    if wn then msg = msg .. '; ' .. wn end
    if final then msg = msg .. string.format('; %d retries spent: bp.cancel and place it again', nr)
    else
      msg = msg .. string.format('; retry %d/%d once the skipped tiles are revealed, at the latest next season',
                                 nr + 1, M.CFG.retry_max)
    end
  elseif wn then msg = msg .. ' at ' .. label .. '; ' .. wn end
  if P.blocked == 'occupied' then               -- BUG-565: the tile holds a building of another kind
    local R = S.rt.p[P.id]
    local occ = type(R) == 'table' and type(R.occ) == 'table' and table.concat(R.occ, ', ') or '?'
    dd.parts = trunc(occ, 200)
    msg = msg .. ' at ' .. label .. ': nothing built, ' .. occ .. '; cancel it: dfllm cmd bp.cancel ' .. string.format('{"proj":"%s"}', P.id)
  end
  if P.blocked == 'stalled' then                -- BUG-046: which part waits (the rest of the stage is not frozen by it)
    local parts = Q.parts(K, P, d)
    if #parts > 0 then
      dd.parts = trunc(table.concat(parts, '; '), 200)
      msg = msg .. (wn and '' or (' at ' .. label)) .. '; waits: ' .. table.concat(parts, '; ')
    end
  end
  K.emit('PROJECT_BLOCKED', 'A', trunc(msg, 200), dd)
  -- BUG-655: the retries are spent and a piece's supply is what lacks: the input is a DECISION with the fix, once (this branch is cadence-gated)
  if final and P.blocked == 'build_lost' and P.tpl ~= 'seal' then
    local sw, scmds = Q.supply_why(K, P, d)
    if sw and scmds and #scmds > 0 then
      local q = trunc(string.format('%s (%s) lost its pieces %d times: %s', P.id, P.tpl, nr, sw), 200)
      K.log('warn', 'decision: %s: %s', q, table.concat(scmds, ' | '))
      K.emit('DECISION_NEEDED', 'A', q, {id = 'piece_missing', q = q, n = nr, mat = trunc(sw, 40), cmds = scmds, why = 'supply'})
    end
  end
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
  local lw = P.blocked == 'build_lost' and Q.lost_why(K, P, d) or nil     -- BUG-536
  local msg = string.format('%s (%s) blocked %d d: %s at %s%s; parked; cancel: dfllm cmd bp.cancel \'{"proj":"%s"}\' '
                            .. '(no undo: %s)', P.id, P.tpl, days, P.blocked, label, lw and (' (' .. trunc(lw, 70) .. ')') or '',
                            P.id, keep)
  K.log('warn', '%s', msg)
  K.emit('PROJECT_BLOCKED', 'A', trunc(msg, 200),
         {proj = P.id, tpl = P.tpl, stage = label, why = P.blocked, ticks = t - P.since, park = days})
  dirty()
end

-- BUG-638 (Run 16b i2 Valleyhame y376-y377: seal y376s0b1 / y377s0b1 'hatch 107,88,126: nothing stands there' twice build_lost, the stalled
-- decision offering the same cancel / place for 64 days; Run 16c i3 Wallfree y374-y376: seal y374s0b0 / y376s0b0 for the hatch 67,44,139 of a
-- stair that was never dug, SEAL_STUCK and DECISION_NEEDED every month): a seal piece is built on an existing open tile. A piece whose
-- tile is SOLID rock on the revealed map (snapshot legend '#' or smoothed 'S'; hidden tiles say nothing) has nothing to stand on: a
-- phantom. The seal whose unbuilt pieces are all phantoms is cancelled at once (PROJECT_BLOCKED d.phantom, once; follow's plan check reads the
-- tiles: cmd.refuge_stair), bp.place refuses such a document (the same tiles, with the reason).
Q.PHANTOM = {['#'] = true, S = true}
-- the unbuilt build-stage cells of document d (stages from `from` on) as {phantom 'x,y,z c' tiles, unbuilt count}; hatch, door and wall
-- cells alike, gather ('p') cells and tiles holding a building not counted
-- BUG-657 (Run 16c i3 Wallfree y400-y404 / Run 16b i2 Valleyhame y378: the phantom seal came back every year, no PROJECT_BLOCKED phantom
-- ever): the hatch of a stair that was never dug lies on a HIDDEN tile (snapshot.tile answers nil), not on a revealed '#', so BUG-638's
-- scan found nothing. `hidden` (the scan of a seal already build_lost / SEAL_STUCK, never bp.place) counts a hidden tile with no building
-- on it, placed again 4 times and never standing, as a phantom too ('x,y,z ?')
function Q.phantom_cells(K, d, from, built, hidden)
  local ph, n, seen = {}, 0, {}
  for si = from or 0, #d.stages - 1 do
    local st = d.stages[si + 1]
    if st.mode == 'build' and not is_free(st) then
      for _, ch in ipairs(st.chunks) do
        for _, cell in ipairs(ch.cells) do
          local tl = {}
          cell_tiles(ch, cell, tl)
          local t = tl[1]
          if t and t[4]:match('^[^{(:/]*') ~= 'p' then
            local k = tkey(t[1], t[2], t[3])
            if not seen[k] and not (built and built(t)) then
              seen[k] = true
              n = n + 1
              local ok, v = K.call('snapshot', 'tile', t[1], t[2], t[3])
              if ok and type(v) == 'table' and Q.PHANTOM[v.c] and not (type(v.bld) == 'string' and v.bld ~= '') then
                ph[#ph + 1] = k .. ' ' .. v.c
              elseif hidden and ok and v == nil and not Q.bld_at(t[1], t[2], t[3]) then
                ph[#ph + 1] = k .. ' ?'                       -- BUG-657: never dug, never revealed, nothing planned there
              end
            end
          end
        end
      end
    end
  end
  return ph, n
end

-- bp.place of a seal: refused when every piece lies on solid rock (text), else nil
function Q.phantom_doc(K, d)
  if type(d) ~= 'table' or d.tpl ~= 'seal' or type(d.stages) ~= 'table' then return nil end
  local ph, n = Q.phantom_cells(K, d, 0)
  if n == 0 or #ph < n then return nil end
  return string.format('refused: nothing to build on: %s %s solid rock on the revealed map (a seal piece stands on an open tile; no stair or ' ..
                       'floor was dug there). Name the tile that is really open: dfllm bp sites seal --fresh, then at="x,y,z floor"',
                       table.concat(ph, ', '), #ph == 1 and 'is' or 'are')
end

-- the open seal projects whose unbuilt pieces are all phantoms: cancelled (no undo; their jobs and planned buildings go), one event
function Q.phantom_scan(K, t)
  for _, P in ipairs(sorted()) do
    local r = P.tpl == 'seal' and P.done ~= 1 and P.blocked ~= 'cancel' and S.rt.sf[P.id]
    if P.tpl == 'seal' and P.done ~= 1 and P.blocked ~= 'cancel' and (P.blocked == 'build_lost' or (type(r) == 'table' and r.st == 1)) then
      local d = doc(K, P.id)
      local st = d and d.stages[P.stage + 1]
      if st and st.mode == 'build' then
        local ph, n = Q.phantom_cells(K, d, P.stage, function(tl) return piece_built(K, tl) end, true)
        if n > 0 and #ph == n then
          local msg = string.format('%s (seal) cancelled: %s %s solid rock or never revealed, nothing to build on (no stair or floor was dug ' ..
                                    'there); a seal for it is not placed again (BUG-638, BUG-657)', P.id, table.concat(ph, ', '),
                                    #ph == 1 and 'is' or 'are')
          K.log('warn', '%s', msg)
          K.emit('PROJECT_BLOCKED', 'A', trunc(msg, 200),
                 {proj = P.id, tpl = 'seal', stage = trunc(st.label or '', 24), why = P.blocked ~= '' and P.blocked or 'phantom',
                  ticks = t - (int(P.since) or t), phantom = ph})
          cancel(K, P, false)
          rows(K)
          save(K)
          return                          -- one a run
        end
      end
    end
  end
end

-- BUG-637: the templates the kernel never cancels for a lost build: the cores and shafts (the manifest, the audit box and the shaft
-- check hang on them), the plug, the depot (its keeper replaces it) and the mood projects (a mood is on the clock)
Q.LOST_KEEP = {fortcore = true, surfacecore = true, aqshaft = true, explore = true, plug = true, depot = true, repair = true,
               mood_drink = true, stonedig = true}
-- the bp.place command for the same template and params at the best site (`site` S1 is resolved by the CLI against `bp sites`), nil for
-- a seal (its entrance comes from the next audit, not from a copy of the lost one)
function Q.replace_cmd(K, P)
  if P.tpl == 'seal' then return nil end
  local prm = M.bp_params(K, P.id)
  local items = {}
  for k, v in pairs(type(prm) == 'table' and prm or {}) do
    if type(v) == 'number' or type(v) == 'boolean' or (type(v) == 'string' and not v:find('[^%w_.,:+ -]')) then
      items[#items + 1] = string.format('%q:%s', k, type(v) == 'string' and string.format('%q', v) or tostring(v))
    end
  end
  table.sort(items)
  return string.format("dfllm cmd bp.place '{\"tpl\":\"%s\",\"site\":\"S1\"%s}'", P.tpl,
                       #items > 0 and (',"p":{' .. table.concat(items, ',') .. '}') or '')
end

-- BUG-720 (Run 16a i1 Basementflew y440: seal c1a1c7a48e hung 40 days at 'Coffin 97,92,129 (a wall wanted)', the audit kept naming
-- 97,92,129 and `seal at=audit` answered 'nothing to close'): a seal blocked `occupied` (another building stands on every piece tile, nothing
-- built) for occupied_days is cancelled (nothing of it stands, no undo), PEACE only, one a run; the project and its runner slot go, the
-- PROJECT_BLOCKED (A) names the building and tile (d.parts, as BUG-579 reads it: the audit's avoid set) and d.autocancel. The next
-- audit names the next closable tile of the route (cmd.audit_avoid), so the seal goes beside the coffin, not on it.
function Q.occupied_cancel(K, c, t)
  local days = int(M.CFG.occupied_days) or 0
  if days <= 0 then return end
  for _, P in ipairs(sorted()) do
    if P.done ~= 1 and P.tpl == 'seal' and P.blocked == 'occupied' and t - (int(P.since) or t) >= days * DAY then
      local R = S.rt.p[P.id]
      local occ = type(R) == 'table' and type(R.occ) == 'table' and table.concat(R.occ, ', ') or '?'
      local d = doc(K, P.id)
      local st = d and d.stages[P.stage + 1]
      local msg = string.format('%s (seal) blocked occupied for %d d: %s; cancelled by the kernel (nothing of it stands); the next audit names ' ..
                                'another wall tile of the route', P.id, (t - (int(P.since) or t)) // DAY, occ)
      K.log('warn', '%s', msg)
      K.emit('PROJECT_BLOCKED', 'A', trunc(msg, 200),
             {proj = P.id, tpl = P.tpl, stage = trunc(st and st.label or '', 24), why = 'occupied', parts = trunc(occ, 200),
              ticks = t - (int(P.since) or t), autocancel = (t - (int(P.since) or t)) // DAY})
      cancel(K, P, false)
      rows(K)
      save(K)
      return                              -- one a run
    end
  end
end

-- BUG-637: a project parked for good by build_lost for lost_days: cancelled (no undo), one a run, PEACE only. A template that was
-- cancelled lost_max times without one of its projects finishing meanwhile stays parked (the park event has the reason).
function Q.lost_cancel(K, c, t)
  if not c.lost or c.lost <= 0 then return end
  for _, P in ipairs(S.pd.list) do        -- a template with a finished project starts its count again
    if P.done == 1 and (int(S.rt.lostc[P.tpl]) or 0) > 0 then S.rt.lostc[P.tpl] = nil; dirty() end
  end
  for _, P in ipairs(sorted()) do
    if P.done ~= 1 and P.blocked == 'build_lost' and not Q.LOST_KEEP[P.tpl] and not Q.mood_proj(P) and Q.terminal(P)
       and t - (int(P.since) or t) >= c.lost then
      local n = int(S.rt.lostc[P.tpl]) or 0
      if n >= M.CFG.lost_max then return end
      local d = doc(K, P.id)
      local st = d and d.stages[P.stage + 1]
      local label = trunc(st and st.label or '', 24)
      local miss = missing_pieces(K, P, d)
      local mw
      if P.tpl == 'seal' then local _, w = M.remake_why(K, P, d); mw = w else mw = Q.mat_why(K, P, d) or Q.supply_why(K, P, d) end
      local lw = Q.lost_why(K, P, d)
      local why = (#miss > 0 and ('missing ' .. table.concat(miss, ', ')) or 'pieces missing')
                  .. (mw and (' (' .. trunc(tostring(mw), 70) .. ')') or '') .. (lw and ('; ' .. trunc(lw, 70)) or '')
      local cmd = Q.replace_cmd(K, P)
      local days = (t - (int(P.since) or t)) // DAY
      S.rt.lostc[P.tpl] = n + 1
      local msg = string.format('%s (%s) build_lost for %d d at %s, retries spent (%s): cancelled by the kernel (no undo: what it built ' ..
                                'stays, its unbuilt pieces go); %s', P.id, P.tpl, days, label, why,
                                cmd and ('place it again: ' .. cmd) or 'the next audit places a seal again if one is still needed')
      K.log('warn', '%s', msg)
      K.emit('PROJECT_BLOCKED', 'A', trunc(msg, 200),
             {proj = P.id, tpl = P.tpl, stage = label, why = 'build_lost', ticks = t - (int(P.since) or t), autocancel = days, cmd = cmd})
      cancel(K, P, false)
      rows(K)
      save(K)
      return                              -- one a run
    end
  end
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
    local okp, errp = pcall(Q.phantom_scan, K, t)                -- BUG-638
    if not okp then K.log('error', 'phantom seal scan failed: %s', trunc(errp, 160)) end
    local okl, errl = pcall(Q.lost_cancel, K, conf(K), t)       -- BUG-637
    if not okl then K.log('error', 'lost-project cancel failed: %s', trunc(errl, 160)) end
    local okq, errq = pcall(Q.occupied_cancel, K, conf(K), t)   -- BUG-720
    if not okq then K.log('error', 'occupied-seal cancel failed: %s', trunc(errq, 160)) end
  end
  for id, r in pairs(S.rt.park) do              -- a park record whose project left (or runs again): quiet
    local P = find(id)
    if not P or P.done == 1 then S.rt.park[id] = nil; dirty()
    elseif type(r) == 'table' and #(r.ids or {}) > 0 and not Q.parked(K, P, pt) then S.rt.park[id] = CAD.quiet(r); dirty() end
  end
  plug_watch(K)                              -- Run 11: the plug's wall (every mode); the check ran as its own task
  local oka, erra = pcall(M.AQ.tick, Q.aqx(K))   -- FR-95: observe mode's smoothing beside the damp tiles
  if not oka then K.log('error', 'aquifer tick failed: %s', trunc(erra, 160)) end
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

-- BUG-328: set aside for want of progress (m.runner ip[<proj>] = {t, ps, si, why}); see M.CFG.idle_days
function Q.idle(P) return type(S.rt.ip) == 'table' and type(S.rt.ip[P.id]) == 'table' end
-- BUG-328 review: never set aside, and a set-aside one comes back once this holds (the reason): a mood project,
-- the hospital care first leads, an aqshaft watching an open level, the refuge's drink store, a seal or plug in
-- SIEGE/BREACH and a food/drink project (SUPPLY) while a food/drink emergency holds
function Q.idle_keep(K, P)
  if Q.mood_proj(P) then return 'a strange mood waits for it' end
  if Q.ess_proj(P) then return 'an essential shop (Still, Kitchen) is missing' end      -- BUG-527
  if S.care_id == P.id then return 'care leads it' end
  if P.tpl == 'aqshaft' and M.AQ.holds(S.rt, P.id) then return 'an open aquifer level' end
  if P.tpl == 'refuge_drink' then return 'the refuge drink' end
  local m = K.mode()
  if SEALS[P.tpl] and (m == 'SIEGE' or m == 'BREACH') then return 'a seal in ' .. m end
  if P.tpl == 'seal' and Q.refuge_seal(K, P) then return 'the refuge seal' end       -- BUG-336: it escalates instead
  local f = S.focus
  if SUPPLY[P.tpl] and type(f) == 'table' and f.emerg then return tostring(f.emerg) end
end
-- the commands that end it, for the event and status
function Q.idle_cmds(id)
  return string.format('resume: dfllm cmd bp.resume \'{"proj":"%s"}\'; cancel: dfllm cmd bp.cancel \'{"proj":"%s"}\'', id, id)
end
-- once a run in PEACE (begin_run, before the slots): projects without own progress (R.ps) for c.idle are set aside
-- (kern.log, PROJECT_BLOCKED d.idle = days); a set-aside one whose R.ps moved (a measure found progress, the seal fallback
-- placed a piece again) or whose stage changed comes back. What it placed in DF stays; nothing is undone
function Q.idle_scan(K, c, t)
  S.rt.ip = obj(S.rt.ip)
  for id, r in pairs(S.rt.ip) do
    local P = find(id)
    local R = P and S.rt.p[P.id]
    local keep = P and type(r) == 'table' and Q.idle_keep(K, P)
    if not P or P.done == 1 or halted(P) or type(r) ~= 'table' then S.rt.ip[id] = nil; dirty()
    elseif type(R) == 'table' and (R.si ~= int(r.si) or (int(R.ps) or 0) > (int(r.ps) or 0)) then
      S.rt.ip[id] = nil
      dirty()
      K.log('info', '%s (%s) moves again after %d days set aside: it takes a runner slot again', P.id, P.tpl,
            (t - (int(r.t) or t)) // DAY)
    elseif keep then                         -- BUG-328 review: it became life-critical while set aside
      S.rt.ip[id] = nil
      if type(R) == 'table' then R.ps, R.last = t, t end           -- a fresh idle_days once that ends
      dirty()
      K.log('info', '%s (%s) back after %d days set aside (%s): it takes a runner slot again', P.id, P.tpl,
            (t - (int(r.t) or t)) // DAY, keep)
    end
  end
  if K.mode() ~= 'PEACE' then return end
  for _, P in ipairs(sorted()) do
    local R = S.rt.p[P.id]
    local ps = type(R) == 'table' and R.si == P.stage and int(R.ps) or nil
    if ps and P.done ~= 1 and not halted(P) and not S.rt.ip[P.id] and t - ps >= c.idle and not Q.idle_keep(K, P) then
      local d = doc(K, P.id)
      local st = d and d.stages[P.stage + 1]
      local label = trunc(st and st.label or '', 24)
      local days = (t - ps) // DAY
      local why = P.blocked == 'stalled' and 'stalled' or 'no progress'
      local wait
      if P.blocked == 'stalled' and d then
        local okp, parts = pcall(Q.parts, K, P, d)
        if okp and type(parts) == 'table' and #parts > 0 then wait = trunc(parts[1], 110) end
      end
      S.rt.ip[P.id] = {t = t, ps = ps, si = P.stage, why = why}
      dirty()
      -- BUG-748 (Run 16b i2 Whirledrampart: 'set aside, no runner slot' beside runner slots 4-6 and 8 free idle adults): the set-aside is the runner's
      -- answer to a project that does not move; it says nothing about slots. The free idle adults are named: the wait is then in DF's job list
      local okf, free = K.call('economy', 'idle_free')
      free = okf and math.type(free) == 'integer' and free > 0 and free or nil
      local msg = string.format('%s (%s) %s %d d at %s %d%%%s: set aside for want of progress, not of slots%s; %s', P.id,
                                P.tpl, why, days, label, int(P.pct) or 0, wait and ('; waits: ' .. wait) or '',
                                free and string.format(' (%d free idle adults)', free) or '', Q.idle_cmds(P.id))
      K.log('warn', '%s', msg)
      K.emit('PROJECT_BLOCKED', 'A', trunc(msg, 200), {proj = P.id, tpl = P.tpl, stage = label, why = why,
                                                       ticks = t - ps, idle = days, parts = wait, free = free})
    end
  end
end

-- BUG-435: a project set aside stale_days without progress (r.ps = its last progress) is announced, again every stale_every days
-- (r.sn = the last announcement): what it waits for (the first parts of its stage) and the commands that end it
function Q.stale_scan(K, c, t)
  local sd = c.stale
  if not sd or sd <= 0 or K.mode() ~= 'PEACE' then return end
  for id, r in pairs(S.rt.ip) do
    local P = find(id)
    local ps = type(r) == 'table' and int(r.ps) or nil
    local sn = type(r) == 'table' and int(r.sn) or nil
    if P and ps and P.done ~= 1 and not halted(P) and t - ps >= sd and (not sn or t - sn >= c.stale_every)
       and not Q.idle_keep(K, P) then
      r.sn = t
      dirty()
      local d = doc(K, P.id)
      local st = d and d.stages[P.stage + 1]
      local label = trunc(st and st.label or '', 24)
      local wait
      if d then
        local okp, parts = pcall(Q.parts, K, P, d)
        if okp and type(parts) == 'table' and #parts > 0 then wait = trunc(parts[1], 110) end
      end
      local days = (t - ps) // DAY
      local cmds = string.format("dfllm cmd bp.cancel '{\"proj\":\"%s\"}', then dfllm plan propose (follow cancels traps, tombs and "
                                 .. 'the other replaceable templates itself after plan.stale_project_days)', P.id)
      local msg = string.format('%s (%s) stale: set aside %d d without progress at %s %d%%%s; %s', P.id, P.tpl, days, label,
                                int(P.pct) or 0, wait and ('; waits: ' .. wait) or '', cmds)
      K.log('warn', '%s', msg)
      K.emit('PROJECT_BLOCKED', 'A', trunc(msg, 200), {proj = P.id, tpl = P.tpl, stage = label, why = 'stale', ticks = t - ps,
                                                       idle = days, parts = wait, cmd = trunc(cmds, 200)})
    end
  end
end

-- BUG-529: has this shaft (it holds a level, so idle_keep never sets it aside) made no progress for c.release? Then its slot is the
-- others' (second pass in the scheduler). R.ps is its last own progress (waiting for a slot never sets it in the second pass)
function Q.slot_release(P, R, t, c)
  if not c or not c.release or c.release <= 0 or type(R) ~= 'table' or R.si ~= P.stage then return false end
  local ps = int(R.ps)
  return ps ~= nil and t - ps >= c.release
end

-- BUG-664 (Run 16a i1 Basementflew y455-y463: 83 `project_released` decisions and a `stalled` PROJECT_BLOCKED every 60 d for two shafts, the
-- same words and only the day count changed): an aqshaft's stalled / released announcement is made again only when its cause changed (the
-- level's stall why, the block, the stage); R[key] is the record of the last one. true = it would repeat unchanged
function Q.aq_repeat(K, P, R, key)
  if P.tpl ~= 'aqshaft' or type(R) ~= 'table' then return false end
  local d = doc(K, P.id)
  local st = d and d.stages[P.stage + 1]
  local ids = {P.id .. ':' .. (st and st.label or '')}
  -- BUG-677: the project's progress stamp is a token too: a shaft that moved (and stalls again for the same cause later) is news again
  local toks = {P.blocked ~= '' and P.blocked or 'run', M.AQ.stall_key(S.rt, P.id), 'p' .. tostring(int(R.ps) or 0)}
  local T = K.now()
  if CAD.due(R[key], T, ids, toks, {ticks = 0, wall_s = 0}) then
    R[key] = CAD.mark(T, ids, toks)
    dirty()
    return false
  end
  return true
end

-- BUG-529: the DECISION that goes with the release (PEACE only, once, again every stall_every days while it stays so; R.rls = the last one)
function Q.release_scan(K, c, t)
  if not c.release or c.release <= 0 or K.mode() ~= 'PEACE' then return end
  for _, P in ipairs(sorted()) do
    local R = S.rt.p[P.id]
    if P.tpl == 'aqshaft' and P.done ~= 1 and not halted(P) and type(R) == 'table' and M.AQ.holds(S.rt, P.id)
       and Q.slot_release(P, R, t, c) then
      local sn = int(R.rls)
      if (not sn or sn < int(R.ps) or t - sn >= c.runstall_every) and not Q.aq_repeat(K, P, R, 'rlc') then
        R.rls = t
        dirty()
        local d = doc(K, P.id)
        local st = d and d.stages[P.stage + 1]
        local label = trunc(st and st.label or '', 24)
        local cause = {}
        local w = M.AQ.where(S.rt, P.id)
        if w ~= '' then cause[#cause + 1] = w end
        local sx = M.AQ.stall_text(S.rt, P.id)
        if sx ~= '' then cause[#cause + 1] = sx end
        if P.blocked ~= '' then cause[#cause + 1] = P.blocked end
        local why = #cause > 0 and table.concat(cause, '; ') or 'no cause found (dfllm cmd inspect what=workload)'
        local days = (t - int(R.ps)) // DAY
        local cancel = string.format("dfllm cmd bp.cancel '{\"proj\":\"%s\"}'", P.id)
        local q = string.format('%s (aqshaft) has not moved for %d d at %s %d%% (%s): its runner slot is released, the other projects run ' ..
                                'first (hospital, fortcore, ...); cancel it with %s (only what is not built goes), or fix the cause',
                                P.id, days, label, int(P.pct) or 0, trunc(why, 80), cancel)
        K.log('warn', '%s', q)
        K.emit('DECISION_NEEDED', 'A', trunc(q, 200), {id = 'project_released', q = trunc(q, 200), proj = P.id, n = days,
                                                       cause = trunc(why, 120), cmds = {cancel, 'dfllm bp sites aqshaft --fresh'}})
      end
    end
  end
end

-- BUG-444 (Run 16c i3 Castletongs: aqshaft S1 held a runner slot 556 days at 7 %, no event, 'bp.resume' said 'not set aside (it runs)'):
-- idle_keep exempts a shaft watching a level (and the refuge drink, a seal in a siege, ...) from the set-aside rule for good. A
-- project that is neither done, halted nor set aside and whose own progress (R.ps) is stall_days old says so (PROJECT_BLOCKED
-- why=stalled, A): the cause (the aqshaft's level and ring state, what its stage waits for, why it is kept) and the commands; again
-- every stall_every days (R.sks). Informative: the project keeps its slot, nothing is cancelled
function Q.stall_scan(K, c, t)
  local sd = c.runstall
  if not sd or sd <= 0 or K.mode() ~= 'PEACE' then return end
  for _, P in ipairs(sorted()) do
    local R = S.rt.p[P.id]
    local ps = type(R) == 'table' and R.si == P.stage and int(R.ps) or nil
    local sn = type(R) == 'table' and int(R.sks) or nil
    if ps and P.done ~= 1 and not halted(P) and not Q.idle(P) and t - ps >= sd and (not sn or t - sn >= c.runstall_every)
       and not Q.aq_repeat(K, P, R, 'skc') then
      R.sks = t
      dirty()
      local d = doc(K, P.id)
      local st = d and d.stages[P.stage + 1]
      local label = trunc(st and st.label or '', 24)
      local cause = {}
      local keep = Q.idle_keep(K, P)
      if P.tpl == 'aqshaft' then
        local w = M.AQ.where(S.rt, P.id)
        if w ~= '' then cause[#cause + 1] = w end
        local sx = M.AQ.stall_text(S.rt, P.id)
        if sx ~= '' then cause[#cause + 1] = sx end
      end
      if d then
        local okp, parts = pcall(Q.parts, K, P, d)
        if okp and type(parts) == 'table' and #parts > 0 then cause[#cause + 1] = 'waits: ' .. trunc(parts[1], 110) end
      end
      if keep then cause[#cause + 1] = 'kept (' .. keep .. ')' end
      if P.blocked ~= '' then cause[#cause + 1] = P.blocked end
      local why = #cause > 0 and table.concat(cause, '; ') or 'no cause found (dfllm cmd inspect what=workload)'
      local days = (t - ps) // DAY
      local cmds = string.format("dfllm cmd inspect '{\"what\":\"workload\"}'; dfllm cmd bp.cancel '{\"proj\":\"%s\"}' (only what is "
                                 .. 'not built goes)%s', P.id, P.tpl == 'aqshaft' and '; dfllm bp sites aqshaft --fresh' or '')
      local msg = string.format('%s (%s) stalled: no progress for %d d at %s %d%%: %s; %s', P.id, P.tpl, days, label,
                                int(P.pct) or 0, why, cmds)
      K.log('warn', '%s', msg)
      K.emit('PROJECT_BLOCKED', 'A', trunc(msg, 200), {proj = P.id, tpl = P.tpl, stage = label, why = 'stalled', ticks = t - ps,
                                                       idle = days, parts = trunc(why, 120), cmd = trunc(cmds, 200)})
    end
  end
end

-- BUG-352: does a citizen reach the dig stage of P? Up to 30 pending tiles of the stage (walls to cut: a tile without a
-- walk group answers its neighbours' first, snapshot.groups near) against the walk groups of up to 50 citizens. Claims
-- only when some tile has a known group, none shares a citizen's group and a citizen stands somewhere (a hidden tile is
-- unknown and a tile with no group nothing: no claim). Returns the tile groups and the citizens' groups as lists, or nil
function Q.unreachable(K, P, d, R)
  local tiles = stage_tiles(P.id, d, P.stage)
  local cd = type(R) == 'table' and R.si == P.stage and type(R.cd) == 'string' and R.cd or ''
  local all = {}
  for ci = 1, #tiles do
    if cd:sub(ci, ci) ~= '1' then
      for _, x in ipairs(tiles[ci]) do all[#all + 1] = x end
    end
  end
  if #all == 0 then return nil end
  local step = math.max(1, (#all + 29) // 30)
  local pts = {}
  for i = 1, #all, step do
    local x = all[i]
    if on_map(x[1], x[2], x[3]) then pts[#pts + 1] = {x[1], x[2], x[3]} end
  end
  local np = #pts
  if np == 0 then return nil end
  local cu = K.census.u
  local n = 0
  for _, id in ipairs(type(cu) == 'table' and type(cu.ids) == 'table' and cu.ids or {}) do
    if n >= 50 then break end
    local u = df.unit.find(id)
    if u then
      local ok, x, y, z = pcall(dfhack.units.getPosition, u)
      if ok and int(x) then pts[#pts + 1] = {x, y, z}; n = n + 1 end
    end
  end
  if n == 0 then return nil end
  local ok, g = K.call('snapshot', 'groups', pts, true)
  if not (ok and type(g) == 'table') then return nil end
  local cg, cl, tg, tl = {}, {}, {}, {}
  for i = np + 1, #pts do
    local v = int(g[i])
    if v and v > 0 and not cg[v] then cg[v] = true; cl[#cl + 1] = v end
  end
  for i = 1, np do
    local v = int(g[i])
    if v and v > 0 then
      if cg[v] then return nil end
      if not tg[v] then tg[v] = true; tl[#tl + 1] = v end
    end
  end
  if #cl == 0 or #tl == 0 then return nil end
  table.sort(tl)
  table.sort(cl)
  return tl, cl
end

-- BUG-352: once a run in PEACE (begin_run): a dig stage without own progress for c.reach that no citizen reaches is
-- announced once (S.ur[id] = {t, ps, si}; PROJECT_BLOCKED d.why 'unreachable' with the commands, kern.log, its row says
-- 'unreachable N d'); the record goes when the project moves on, changes stage or leaves. It sets nothing aside and
-- cancels nothing: the commands are the player's (the cancel drops only the unbuilt pieces; a plain cancel leaves the
-- dig designations the stage placed: BUG-352, open)
function Q.reach_scan(K, c, t)
  S.ur = S.ur or {}
  for id, r in pairs(S.ur) do
    local P = find(id)
    local R = P and S.rt.p[P.id]
    if not P or P.done == 1 or halted(P) or type(R) ~= 'table' or R.si ~= int(r.si)
       or (int(R.ps) or 0) > (int(r.ps) or 0) then
      S.ur[id] = nil
    end
  end
  if K.mode() ~= 'PEACE' then return end
  for _, P in ipairs(sorted()) do
    local R = S.rt.p[P.id]
    local ps = type(R) == 'table' and R.si == P.stage and int(R.ps) or nil
    if ps and P.done ~= 1 and not halted(P) and not S.ur[P.id] and not Q.idle(P) and t - ps >= c.reach then
      local d = doc(K, P.id)
      local st = d and d.stages[P.stage + 1]
      if st and st.mode == 'dig' then
        local okr, tl, cl = pcall(Q.unreachable, K, P, d, R)
        if okr and tl then
          S.ur[P.id] = {t = t, ps = ps, si = P.stage}
          local label = trunc(st.label or '', 24)
          local days = (t - ps) // DAY
          local kv = {}
          for k, v in pairs(type(d.params) == 'table' and d.params or {}) do
            if type(v) == 'number' or (type(v) == 'string' and v:match('^[%w:_,.%-]+$')) then kv[#kv + 1] = k .. '=' .. tostring(v) end
          end
          table.sort(kv)
          local cmd = string.format('dfllm cmd bp.cancel proj=%s; dfllm bp sites %s --fresh; dfllm cmd bp.place tpl=%s site=S1%s',
                                    P.id, P.tpl, P.tpl, #kv > 0 and (' ' .. table.concat(kv, ' ')) or '')
          local msg = string.format('%s (%s) unreachable: no citizen reaches the %s dig (walk groups %s; citizens %s), %d d ' ..
                                    'without progress at %s %d%%; cancel it and place it at a site the citizens reach ' ..
                                    '(bp sites lists those): %s', P.id, P.tpl, label, table.concat(tl, ',', 1, math.min(#tl, 4)),
                                    table.concat(cl, ',', 1, math.min(#cl, 4)), days, label, int(P.pct) or 0, cmd)
          K.log('warn', '%s', msg)
          K.emit('PROJECT_BLOCKED', 'A', trunc(msg, 200),
                 {proj = P.id, tpl = P.tpl, stage = label, why = 'unreachable', ticks = t - ps, unreach = days,
                  cmd = #cmd <= 200 and cmd or nil})
          K.flush()
        end
      end
    end
  end
end

-- BUG-328: the set-aside projects for state sched.ip: {n, by = {{id, tpl, days}}} (<= 8), nil without
function Q.idle_state(K)
  local t, by, n = now(K), {}, 0
  for _, P in ipairs(sorted()) do
    local r = Q.idle(P) and S.rt.ip[P.id]
    if r then
      n = n + 1
      local R = S.rt.p[P.id]
      local ps = type(R) == 'table' and int(R.ps) or int(r.ps) or t
      if #by < 8 then by[#by + 1] = {P.id, trunc(P.tpl, 16), math.max(0, (t - ps) // DAY)} end
    end
  end
  return n > 0 and {n = n, by = by} or nil
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
  local oke, erre = pcall(Q.ess_scan, K)                  -- BUG-527: own pcall, a fault costs only the priority
  if not oke then S.ess_ids = {}; K.log('error', 'runner essential shops scan failed: %s', trunc(erre, 160)) end
  local oki, erri = pcall(Q.idle_scan, K, f.c, now(K))   -- BUG-328: own pcall, a fault costs only the set-aside rule
  if not oki then K.log('error', 'runner set-aside failed: %s', trunc(erri, 160)) end
  local oks, errs = pcall(Q.stale_scan, K, f.c, now(K))   -- BUG-435: own pcall, a fault costs only this announcement
  if not oks then K.log('error', 'runner stale scan failed: %s', trunc(errs, 160)) end
  local okk, errk = pcall(Q.stall_scan, K, f.c, now(K))   -- BUG-444: own pcall, a fault costs only this announcement
  if not okk then K.log('error', 'runner stall scan failed: %s', trunc(errk, 160)) end
  local okq, errq = pcall(Q.release_scan, K, f.c, now(K))  -- BUG-529: own pcall, a fault costs only this announcement
  if not okq then K.log('error', 'runner release scan failed: %s', trunc(errq, 160)) end
  local okr, errr = pcall(Q.reach_scan, K, f.c, now(K))  -- BUG-352: own pcall, a fault costs only this announcement
  if not okr then K.log('error', 'runner reach scan failed: %s', trunc(errr, 160)) end
  local okl, errl = pcall(Q.lockout_scan, K, f.c, now(K))  -- BUG-458: own pcall, a fault costs only this announcement
  if not okl then K.log('error', 'runner locked-out scan failed: %s', trunc(errl, 160)) end
  local tasks, n, t, c = {}, 0, now(K), f.c
  local okz, zero = K.call('economy', 'stone_zero')       -- BUG-497: no free boulder: the quarry dig goes first
  S.stone0 = okz and zero == true
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
    if Q.idle(P) and not Q.idle_keep(K, P) then return true end                   -- BUG-328: set aside
    if SEALS[P.tpl] and c.on and not f.stk[P.id] then return false end
    if P.tpl == 'aqshaft' and M.AQ.holds(S.rt, P.id) then return Q.slot_release(P, R, t, c) end  -- BUG-191: an open level; BUG-529: not for ever
    if S.care_id == P.id and P.blocked ~= 'stalled' then return false end         -- BUG-116: the hospital never yields
    if Q.mood_proj(P) and P.blocked ~= 'stalled' then return false end             -- BUG-306: nor a mood project
    if P.blocked == 'stalled' or (SEALS[P.tpl] and f.stk[P.id]) then return true end
    return type(R) == 'table' and R.si == P.stage and t - (int(R.ps) or t) >= c.yield
  end
  local extra, pz, held, slots, yielded, waiting, nm = 0, {}, 0, {}, {}, 0, 0
  local okc, cap = pcall(Q.slot_cap, K, c)                  -- BUG-486: more slots for idle hands; a fault keeps `active`
  if not okc or math.type(cap) ~= 'integer' then cap = M.CFG.active end
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
        -- BUG-306: beside `active`; BUG-371: the one-tile drink nook needs no slot of the mood_slots (two mood shops projects
        -- that hold them never keep a nook, the dwarf's life support, waiting 'queued behind')
        local mood_slot = ok and Q.mood_proj(P) and (nm < (int(M.CFG.mood_slots) or 2) or P.tpl == 'mood_drink')
        local aside = Q.idle(P) and not Q.idle_keep(K, P)       -- BUG-328: set aside: measured only, never a slot
        if ok and not aside and (n < cap or mood_slot) then
          if mood_slot then nm = nm + 1 else n = n + 1 end
          S.active[P.id] = true
          slots[#slots + 1] = P.id
          tasks[#tasks + 1] = {k = 'work', id = P.id}
        else
          local R = R_of(K, P)
          if not ok and not why then Q.froze(K, P, d, R) end        -- BUG-045: the mode froze it (an alert)
          -- BUG-191: an aqshaft with an open level waiting for a slot is measured too (its heavy watch reads only)
          if ok and (pass == 2 or (P.tpl == 'aqshaft' and M.AQ.holds(S.rt, P.id))) and extra < M.CFG.meas_extra
             and (R.mt == nil or t - R.mt >= M.CFG.meas_every) then
            extra, R.mt = extra + 1, t
            tasks[#tasks + 1] = {k = 'work', id = P.id, meas = true}
          end
          if ok and pass == 1 then waiting = waiting + 1 end
          if ok and p2 and not aside and P.blocked ~= 'stalled' and not SEALS[P.tpl] then
            yielded[P.id] = (t - int(R.ps)) // DAY
          end
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
  S = {tiles = {}, bbox = {}, meas = {}, absent = {}, rows = {}, ur = {}, active = nil, slice = {qf = 0, probes = 0, qf_max = 1},
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
  rt.ow = obj(rt.ow)                                                 -- BUG-458: walls of finished seals / repairs (LOCKED_OUT, reopen)
  rt.wc = obj(rt.wc)                                                 -- BUG-487: tiles whose wall was refused (WALL_REFUSED, once a day)
  rt.so = obj(rt.so)                                                 -- BUG-044: door/hatch order items per seal project
  rt.kk = obj(rt.kk)                                                 -- BUG-043: the template of a kept seal/explore box
  rt.kp = obj(rt.kp)                                                 -- BUG-129: the tile clusters of a kept box
  rt.park = obj(rt.park)                                             -- BUG-037: parked projects announced
  rt.lostc = obj(rt.lostc)                                           -- BUG-637: auto-cancelled build_lost projects per template
  rt.ip = obj(rt.ip)                                                 -- BUG-328: projects set aside (no progress)
  rt.cv = obj(rt.cv)                                                 -- BUG-522: chunks with a free-hanging floor above (cave-in risk)
  rt.aq = obj(rt.aq)                                                 -- FR-95: aquifer shafts and observe mode
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
  local okb, errb = pcall(Q.aq_boot, K)           -- FR-95: breach:damp parks of an older kernel go on in observe mode
  if not okb then K.log('error', 'aquifer resume failed: %s', trunc(errb, 160)) end
  save(K)
  local ph = K.persist.get('phase')
  S.phase = type(ph) == 'table' and ph.phase or nil
  rows(K)
end

-- BUG-037 watchdog: a task that yields task_slices slices in a row is skipped for this run (kern.log; what it did stays,
-- the next run goes on from there), so one task can never hold the run, and with it every slot, for good
-- BUG-371 (Run 16d y376: "runner paced: over its share of 4 ms/s ... runs and slices wait" while a thirsty Possessed dwarf's drink
-- nook stood queued): while a drink nook is pending the runner asks kern for the boost (no demotion, a bigger share); it lapses
-- by itself and is dropped at once when the nook is done
function Q.mood_boost(K)
  local pend = false
  for _, P in ipairs(S.pd and S.pd.list or {}) do
    if P.tpl == 'mood_drink' and P.done ~= 1 and not halted(P) then pend = true; break end
  end
  if pend and type(K.boost) == 'function' then
    K.boost('mood drink nook pending', false)
    S.mboost = true
  elseif S.mboost then
    S.mboost = nil
    if type(K.unboost) == 'function' then K.unboost() end
  end
end

function M.step(K, budget, ctx)
  S.slice = {qf = 0, probes = 0, qf_max = M.CFG.qf_per_slice}
  if K.reset and not S.rq_done then
    local okr, err = pcall(Q.requeue_reset, K)                 -- BUG-521
    if not okr then K.log('warn', 'runner: timeline reset re-queue: %s', tostring(err)) end
  end
  if not (ctx and ctx.cont) or not S.run then S.dtask, S.doing = nil, 'begin run'; begin_run(K) end
  pcall(Q.mood_boost, K)
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
      run.tt = run.tt or now(K)                      -- BUG-328: when this task began to yield
      local age = now(K) - run.tt
      if run.ty < M.CFG.task_slices and age < M.CFG.task_days * DAY then save(K); return 'more' end
      S.wd = (S.wd or 0) + 1
      K.log('warn', 'runner watchdog: task %d/%d (%s%s) yielded %d slices in a row (%d days): skipped this run', run.i,
            #run.tasks, task.k, task.id and (' ' .. task.id) or '', run.ty, age // DAY)
      if task.k == 'check' then S.chk = nil end
    end
    run.i, run.ty, run.tt = run.i + 1, 0, nil
  end
  S.run, S.ended = nil, now(K)
  save(K)
end

-- BUG-039: what the runner's last slice did (kern asks right after a slow or huge step or handler)
function M.doing() return S.doing end

-- BUG-521 (Run 16d i4 Trumpetrealms y389: "TIMELINE RESET: older save loaded", the fortcore st3 retrofit placed and finished in the
-- discarded timeline was gone from the loaded save; the player noticed only at the next `inspect defense`): the runner's projects live
-- in the save, the runtime folder (bp files, commands.log) does not. At the first step after a boot that found the clock jumped back
-- (K.reset kind clock) the bp.place commands of the discarded timeline (commands.log lines after the older save's tick, newest
-- stretch of the file, result ok, not cancelled by a later bp.cancel) whose project the loaded save does not have are placed again,
-- in their order, through the bp.place verb itself (every placement check runs again), at most M.CFG.requeue_max. PROJECTS_REQUEUED
-- (B) names the ones queued and the ones refused with the reason; a project the player does not want is cancelled as any other.
-- Plan builds (y<Y>s<S>b<I>) are not read here: the plan lives in the save and plan.reload makes them again.
M.CFG.requeue_max = 12
function Q.read_lines(path)
  local f = io.open(path, 'rb')
  if not f then return {} end
  local s = f:read('a') or ''
  f:close()
  local out = {}
  for ln in (s .. '\n'):gmatch('([^\r\n]*)\r?\n') do if ln ~= '' then out[#out + 1] = ln end end
  return out
end

function Q.reset_cmds(K, tick_neu)
  local dir = K.cfg.paths.save
  local lines = Q.read_lines(fio.rotated(dir .. '/commands.log'))
  for _, ln in ipairs(Q.read_lines(dir .. '/commands.log')) do lines[#lines + 1] = ln end
  local rows_ = {}
  for i, ln in ipairs(lines) do
    local ts, tk, origin, verb, args, res = ln:match('^(%d+)\t(%d+)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t?(.*)$')
    if tk then rows_[#rows_ + 1] = {tick = tonumber(tk), origin = origin, verb = verb, args = args, res = res} end
  end
  -- this boot's own lines come last and their ticks start at the loaded clock: the last place where the tick falls going forward is
  -- the border between the discarded timeline and this boot (ticks never fall inside one boot)
  local border = #rows_ + 1
  for i = #rows_, 2, -1 do
    if rows_[i - 1].tick > rows_[i].tick then border = i; break end
  end
  local seg = {}
  for i = border - 1, 1, -1 do
    if rows_[i].tick <= tick_neu then break end                -- the stretch both timelines share begins here
    seg[#seg + 1] = rows_[i]
  end
  local out, cancelled = {}, {}
  for i = #seg, 1, -1 do                                     -- oldest first
    local e = seg[i]
    local id = e.origin:match('^inbox:([A-Za-z0-9_-]+):')
    if id and e.res:sub(1, 2) == 'ok' then
      local a = json.try_decode(e.args)
      if e.verb == 'verb:bp.place' and type(a) == 'table' and type(a.tpl) == 'string' then
        out[#out + 1] = {id = id, args = a}
      elseif e.verb == 'verb:bp.cancel' and type(a) == 'table' and type(a.proj) == 'string' and a.reopen == nil then
        cancelled[a.proj] = true
      end
    end
  end
  return out, cancelled
end

function Q.requeue_reset(K)
  local R = K.reset
  S.rq_done = true
  if not (type(R) == 'table' and R.kind == 'clock' and math.type(R.tick_neu) == 'integer') or M.CFG.requeue_max <= 0 then return end
  local ok, cmds, cancelled = pcall(Q.reset_cmds, K, R.tick_neu)
  if not ok then K.log('warn', 'runner: timeline reset: commands.log unreadable (%s)', tostring(cmds)); return end
  local queued, failed, skipped = {}, {}, 0
  for _, c in ipairs(cmds) do
    if not find(c.id) and not cancelled[c.id] then
      if #queued + #failed >= M.CFG.requeue_max then skipped = skipped + 1
      else
        local okv, vok, msg = pcall(M.verbs['bp.place'], K, c.args, {id = c.id})
        if okv and vok == true then queued[#queued + 1] = c.id
        else failed[#failed + 1] = c.id .. ': ' .. trunc(okv and msg or vok, 60) end
      end
    end
  end
  if #queued + #failed + skipped == 0 then return end
  local txt = string.format('timeline reset (older save loaded): %d project(s) placed in the discarded timeline queued again: %s%s%s',
                            #queued, table.concat(queued, ', '),
                            #failed > 0 and ('; refused: ' .. table.concat(failed, '; ')) or '',
                            skipped > 0 and string.format('; %d more not queued (limit %d)', skipped, M.CFG.requeue_max) or '')
  K.log('warn', 'runner: %s', txt)
  K.emit('PROJECTS_REQUEUED', 'B', trunc(txt, 200),
         {ids = {table.unpack(queued, 1, math.min(#queued, 12))}, n = #queued, failed = #failed > 0 and {table.unpack(failed, 1, math.min(#failed, 4))} or nil,
          skipped = skipped > 0 and skipped or nil, tick_alt = R.tick_alt, tick_neu = R.tick_neu})
  rows(K)
  save(K)
end

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
  local okip, ip = pcall(Q.idle_state, K)                         -- BUG-328: the set-aside projects
  ip = okip and ip or nil
  if q or run or pk or ip then
    sc = sc and copy(sc) or {}
    sc.q, sc.run, sc.pk, sc.ip = q, run, pk, ip
  end
  return {phase = S.phase, phw = S.phw, proj = S.rows, sched = sc, adopt = Q.adopt_state()}
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
  -- BUG-505 (review of BUG-487: seal.lua KP.extend / KP.close / the perimeter repair after a siege / the lost-bridge repair queued
  -- `Cw` walls here with no reach check, only bp.place and the plan build had one): the walls of a repair that would cut a citizen
  -- or a farm, well, depot, workshop or office off the main walk group, or whose reach cannot be proven, become doors (the cells
  -- 'Cw' -> 'd', as the plan build does); a closure (a wall + door that replaces a bridge) or a wall on a ramp top cannot, it is
  -- refused with the reason and the caller waits or logs. opts.noreach: the refuge plug confines on purpose (BUG-479).
  if not (type(opts) == 'table' and opts.noreach == true) then
    d.id = id
    local refused = Q.place_walls(K, d, 'repair')
    d.id = nil
    if refused then
      if not cl and Q.walls_to_doors(K, d) > 0 then
        K.log('warn', 'repair %s: %s -> its walls are built as doors (BUG-505)', id, trunc(refused, 140))
      else
        return false, refused
      end
    end
  end
  -- BUG-754 (Run 16b i2 Whirledrampart y437-y440: B1 and O1 toppled in tantrums, 14-20 days until they stood again, open perimeter): opts.prio
  -- (1..7, a number) sets the project's priority; seal gives a lost bridge's repair prio 1, ahead of the plan's own projects
  local prio = type(opts) == 'table' and int(opts.prio) or nil
  if prio and (prio < 1 or prio > 7) then prio = nil end
  local ok, err = register(K, id, d, cl and 1 or prio or 2, 'repair')
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
  Q.join_run(K, id)                                  -- BUG-306: not after the run in hand
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

-- BUG-393 (Run 16c i3 Yawninggilt y380: 'boulders(hard) x1: none in the fort', four moods failed, the stone dig a mood asks for is a
-- `bedrooms` project that needs a fortcore room site, so no dig was ever placed): care's small stone dig for a strange mood. tiles =
-- {{x, y, z}, ...} (1-stonedig_max wall tiles care picked: revealed hard-stone wall on the citizens' walk group, a tunnel from open
-- floor, away from water, magma, aquifer and caverns). One dig stage, no room, no door, no burrow, no manifest: every dug wall
-- tile is a boulder. PEACE only (class living). Returns ok, project id.
M.CFG.stonedig_max = 12
function M.stonedig(K, tiles, why)
  if type(tiles) ~= 'table' or #tiles == 0 or #tiles > M.CFG.stonedig_max then
    return false, string.format('need 1-%d tiles', M.CFG.stonedig_max)
  end
  local cells, seen = {}, {}
  for i, t in ipairs(tiles) do
    local x, y, z
    if type(t) == 'table' then x, y, z = int(t[1] or t.x), int(t[2] or t.y), int(t[3] or t.z) end
    if not (x and y and z) or not on_map(x, y, z) then return false, 'bad tile ' .. i end
    local k = x .. ',' .. y .. ',' .. z
    if seen[k] then return false, 'tile ' .. i .. ' twice' end
    seen[k] = true
    cells[#cells + 1] = {x, y, z, 'd'}
  end
  sort_cells(cells)
  local id = new_id(K, 'sdg')
  local d = {v = 2, tpl = 'stonedig', site = 'care', class = 'living', params = obj{n = #cells}, rot = 0,
             anchor = {cells[1][1], cells[1][2], cells[1][3]}, manifest = {v = 2}, materials = obj{},
             stages = {{label = 'stone.dig', mode = 'dig', orders = 0, defense = 0, chunks = abs_chunks(cells)}}}
  local ok, err = register(K, id, d, 1, 'stonedig')
  if not ok then return false, err end
  Q.join_run(K, id)                                  -- a mood waits: not after the run in hand
  save(K)
  K.log('info', 'stone dig %s queued: %d tiles from %d,%d,%d (%s)', id, #cells, cells[1][1], cells[1][2], cells[1][3],
        trunc(why, 80))
  return true, id
end

-- Run 11: explore shafts open to a cavern whose top wall does not stand yet (readiness keeps R0 `caverns` for them,
-- threat counts hostiles near them): n, {{x, y, z_top, z_bottom}, ...}
function M.cavern_open(K)
  local n, list = 0, {}
  for id, r in pairs(S.rt and S.rt.cav or {}) do
    -- FR-98: a shaft the cavern sweep opened counts as open once no sweep runs on it (the sweep module gone or lost it)
    if type(r) == 'table' and (r.st == 'open' or r.st == 'failed' or (r.st == 'sweep' and not M.swept(K, id)))
       and r.why ~= 'heavy_aquifer' and r.why ~= 'ring_wall' then   -- FR-95; BUG-662: an unbuilt ring wall is no open cavern
      n = n + 1
      if type(r.s0) == 'table' then list[#list + 1] = {r.s0[1], r.s0[2], r.s0[3], int(r.bot) or r.s0[3]} end
    end
  end
  table.sort(list, function(a, b) return a[1] * 100000 + a[2] < b[1] * 100000 + b[2] end)
  return n, list
end

---------------------------------------------------------------- FR-98: the cavern sweep (cavern.lua, Gordon's goal G16)
-- The sweep opens one plugged explore shaft under a hatch, sends squad A down and walls the shaft again. Its two runner
-- projects are the player's own designations: `unplug` (u0.rm/u1.rm: quickfort dig `n` = remove construction on the plug
-- walls; u1.stair/u0.stair: constructed stairs `Cx`/`Cd` in their place; u0.hatch: a hatch cover `H` on the top) and a
-- `plug` again (the plug machinery: p1 the lower tile, then p0 the top; a stair is removed with `n`, the hatch with the
-- player's remove building, then constructed walls). The record m.runner cav[<id>] holds st = 'sweep' (sw = the unplug
-- project) while the sweep runs; module fields (runner.lua sits at Lua's limit of 200 locals).

-- true when the cavern module runs a sweep on record `id` (absent module: false)
function M.swept(K, id)
  local ok, v = K.call('cavern', 'running', id)
  return ok and v == true
end

-- public: the plugged cavern ways the sweep may open, {{id, s0 = {x, y, z}, s1, bot, why, st (done | sweep), sw}}, by id
function M.cav_sealed(K)
  local out = {}
  for id, r in pairs(S.rt and S.rt.cav or {}) do
    if type(r) == 'table' and (r.st == 'done' or r.st == 'sweep') and CAVERN[r.why] and type(r.s0) == 'table' then
      out[#out + 1] = {id = id, s0 = {r.s0[1], r.s0[2], r.s0[3]}, bot = int(r.bot) or r.s0[3], why = r.why, st = r.st,
                       s1 = (type(r.s1) == 'table' and not r.s1x) and {r.s1[1], r.s1[2], r.s1[3]} or nil, sw = r.sw}
    end
  end
  table.sort(out, function(a, b) return tostring(a.id) < tostring(b.id) end)
  return out
end

-- public: the record's state ('done', 'open', 'failed', 'sweep', 'none') and its plug project, nil when unknown
function M.cav_state(K, id)
  local r = S.rt and S.rt.cav and S.rt.cav[id]
  if type(r) ~= 'table' then return nil end
  return r.st, r.plug
end

-- public (cavern.lua): any project's progress, {done, stage, chunk, pct, blocked, label} or nil (gone)
M.proj_state = function(K, id) return M.coffins_state(K, id) end

function Q.sw_stage(label, mode, p, key)
  return {label = label, mode = mode, orders = 0, defense = 1, chunks = {{pos = {p[1], p[2], p[3]}, cells = {{0, 0, 0, key}}}}}
end

-- public (cavern.lua): queue the unplug project of a plugged shaft; ok, project id
function M.sweep_open(K, id)
  local r = S.rt and S.rt.cav and S.rt.cav[id]
  if type(r) ~= 'table' or r.st ~= 'done' or type(r.s0) ~= 'table' or not CAVERN[r.why] then
    return false, 'no plugged cavern shaft ' .. tostring(id)
  end
  local s0, s1 = r.s0, (type(r.s1) == 'table' and not r.s1x) and r.s1 or nil
  -- the top first: its wall goes, a down stair and the hatch take its place while the lower wall still closes the shaft;
  -- then the lower wall goes and an up/down stair joins the shaft below (nothing climbs into the open tile before it)
  local stages = {Q.sw_stage('u0.rm', 'dig', s0, 'n'), Q.sw_stage('u0.stair', 'build', s0, 'Cd'),
                  Q.sw_stage('u0.hatch', 'build', s0, 'H')}
  if s1 then
    stages[#stages + 1] = Q.sw_stage('u1.rm', 'dig', s1, 'n')
    stages[#stages + 1] = Q.sw_stage('u1.stair', 'build', s1, 'Cx')
  end
  local pid = new_id(K, 'us')
  local d = {v = 2, tpl = 'unplug', site = 'plug', class = 'defense', params = obj{un = id}, rot = 0,
             anchor = {s0[1], s0[2], s0[3]}, manifest = {v = 2}, materials = obj{hatch = 1}, stages = stages}
  local ok, err = register(K, pid, d, 1, 'unplug')
  if not ok then return false, err end
  r.st, r.sw, r.plug = 'sweep', pid, ''
  dirty()
  save(K)
  K.log('info', 'cavern sweep: %s opens the shaft %d,%d,%d of %s (remove the plug walls, stairs, a hatch on top)', pid,
        s0[1], s0[2], s0[3], id)
  return true, pid
end

-- the steps that wall one shaft tile as it stands now (lower tile first, like the plug): a wall stands: none; a hatch, a
-- door or a building the unplug planned there: the player's remove building first; a stair (our constructed one, also
-- under a hatch): removed (`n`); then a constructed wall
Q.SW_STAIR = {['<'] = true, ['>'] = true, X = true}
function Q.sw_keys(v)
  if not v or v.c == 'C' then return {} end
  local bld = type(v.bld) == 'string' and v.bld ~= '' and v.bld or nil
  local out = {}
  if v.c == '+' or bld then out[1] = 'free:' .. (bld == 'Door' and 'd' or 'H') end
  if v.c == '+' or Q.SW_STAIR[v.c] then out[#out + 1] = 'n' end
  out[#out + 1] = 'Cw'
  return out
end

-- public (cavern.lua): wall the shaft of record `id` again: the unplug project (if it still runs) leaves the list without
-- an undo, then a plug project (prio 1, every mode; CAVERN_PLUG done once the walls stand); ok, project id ('' when the
-- walls stand already)
function M.sweep_close(K, id)
  local r = S.rt and S.rt.cav and S.rt.cav[id]
  if type(r) ~= 'table' or type(r.s0) ~= 'table' then return false, 'no cavern record ' .. tostring(id) end
  local U = type(r.sw) == 'string' and find(r.sw) or nil
  if U and U.done ~= 1 then
    -- a removal it designated and nobody took yet is taken back (a lower wall must not go once the shaft closes)
    local ud = doc(K, U.id)
    local ust = ud and ud.stages[U.stage + 1]
    if ust and ust.mode == 'dig' and U.chunk > 0 then
      local ch = ust.chunks[1]
      K.act.quickfort({mode = 'dig', data = chunk_data(ch), pos = ch.pos, command = 'undo'})
    end
    cancel(K, U, false)
  end
  local stages = {}
  for _, pc in ipairs({{'p1', (type(r.s1) == 'table' and not r.s1x) and r.s1 or false}, {'p0', r.s0}}) do
    local p = pc[2]
    if type(p) == 'table' then
      for _, key in ipairs(Q.sw_keys(tile_at(K, p[1], p[2], p[3]))) do
        local free = key:sub(1, 5) == 'free:'
        stages[#stages + 1] = Q.sw_stage(pc[1] .. (key == 'n' and '.rm' or free and '.free' or '.wall'),
                                          key == 'n' and 'dig' or 'build', p, free and key:sub(6) or key)
      end
    end
  end
  if #stages == 0 then
    r.st, r.td, r.sw = 'done', now(K), nil
    dirty()
    save(K)
    return true, ''
  end
  local walls = 0
  for _, st in ipairs(stages) do if st.label:sub(-5) == '.wall' then walls = walls + 1 end end
  local pid = plug_id(K)
  local d = {v = 2, tpl = 'plug', site = 'plug', class = 'defense', params = obj{of = r.proj, sweep = 1}, rot = 0,
             anchor = {r.s0[1], r.s0[2], r.s0[3]}, manifest = {v = 2}, materials = obj{wall = walls}, stages = stages}
  local ok, err = register(K, pid, d, 1, 'plug')
  if not ok then return false, err end
  r.st, r.plug, r.sw = 'open', pid, nil
  dirty()
  save(K)
  K.log('info', 'cavern sweep: plug %s walls the shaft %d,%d,%d of %s again (%d stages)', pid, r.s0[1], r.s0[2], r.s0[3],
        id, #stages)
  return true, pid
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

-- BUG-181: the workshop types the pending (live) projects of tpl build, from their docs' manifest.workshops: set, all
-- (true when a pending project's doc lists no workshop: it may build anything), n (the pending projects)
function M.pending_types(K, tpl)
  local out, all, n = {}, false, 0
  for _, P in ipairs(S.pd and S.pd.list or {}) do
    if P.tpl == tpl and Q.live(K, P) then
      n = n + 1
      local d = doc(K, P.id)
      local m = type(d) == 'table' and type(d.manifest) == 'table' and d.manifest.workshops
      if type(m) ~= 'table' or #m == 0 then all = true
      else
        for _, w in ipairs(m) do if type(w) == 'table' and type(w.type) == 'string' then out[w.type] = true end end
      end
    end
  end
  return out, all, n
end

-- BUG-283 (Run 15 Drillchamber y375: the Glass Furnace a fey glassmaker waited for stood in a 12-shop `workshops` project at
-- prio 4 that took 27 days; the mood failed 54,481 ticks after the claim): the workshop types open strange moods wait for,
-- per unit (care's mood check calls M.mood_types every few hundred ticks). A workshops project that builds one of them is
-- kind 'mood' (never paused by seal first, care first or the rebuild policy) and sorts with the hospital before the rest.
Q.MOODWS = {}                                    -- unit id (string) -> {type = true}
function Q.mood_shop(d)
  if not next(Q.MOODWS) then return false end
  local m = type(d) == 'table' and type(d.manifest) == 'table' and d.manifest.workshops
  for _, w in ipairs(type(m) == 'table' and m or {}) do
    local t = type(w) == 'table' and w.type
    if type(t) == 'string' then
      for _, set in pairs(Q.MOODWS) do if set[t] then return true end end
    end
  end
  return false
end

-- BUG-306 (Run 15 Earthboat y382: MOOD_CRITICAL, thirst 53,516, the drink nook mdr154252539 'BLOCKED:queued behind
-- c1a1884b90c4405401 +1', the refuge seal that hung for weeks): a mood project (the drink nook, a shop a mood waits for) takes a
-- slot of its own beyond `active` (at most mood_slots of them), never yields it and starts in the run in hand when it is queued
-- while one runs: nothing else may hold the slots while a dwarf in a strange mood waits
M.CFG.mood_slots = 2
function Q.mood_proj(P)
  return P ~= nil and (P.tpl == 'mood_drink' or P.tpl == 'stonedig' or (S.mood_ids or {})[P.id] == true)
end
-- a mood project queued while a run is in hand works in it (a task before the run's check/end), its slot beside `active`
function Q.join_run(K, id)
  local run, P = S.run, find(id)
  if not (run and P and S.active) or S.active[id] then return false end
  local nm = 0
  for pid in pairs(S.active) do if Q.mood_proj(find(pid)) then nm = nm + 1 end end
  if nm >= (int(M.CFG.mood_slots) or 2) and not (find(id) and find(id).tpl == 'mood_drink') then return false end   -- BUG-371
  local at = #run.tasks + 1
  for i = math.max(run.i, 1), #run.tasks do
    local k = run.tasks[i].k
    if k == 'check' or k == 'end' then at = i; break end
  end
  table.insert(run.tasks, at, {k = 'work', id = id})
  S.active[id] = true
  S.slots = S.slots or {}
  S.slots[#S.slots + 1] = id
  rows(K)
  return true
end

-- public (BUG-283, care): the mood of unit `sid` waits for `types` (an empty list: the mood ended). Marks the live workshops
-- projects that build one of the types (S.mood_ids, read by sorted()) and returns the types no live project of mood shops
-- only (every type of it a wanted one) builds yet: those care asks follow for (PROJECT_REQUEST workshops why=mood).
function M.mood_types(K, sid, types)
  sid = tostring(sid or '')
  local set, list = {}, {}
  for _, t in ipairs(type(types) == 'table' and types or {}) do
    if type(t) == 'string' and not set[t] then set[t] = true; list[#list + 1] = t end
  end
  Q.MOODWS[sid] = next(set) and set or nil
  local ids, own = {}, {}
  for _, P in ipairs(S.pd and S.pd.list or {}) do
    if P.tpl == 'workshops' and Q.live(K, P) then
      local d = doc(K, P.id)
      if Q.mood_shop(d) then
        ids[P.id] = true
        local m = type(d) == 'table' and type(d.manifest) == 'table' and d.manifest.workshops or {}
        local only = #m > 0
        for _, w in ipairs(m) do if not (type(w) == 'table' and set[w.type]) then only = false end end
        if only then for _, w in ipairs(m) do own[w.type] = true end end
      end
    end
  end
  S.mood_ids = ids
  local out = {}
  for _, t in ipairs(list) do if not own[t] then out[#out + 1] = t end end
  return out
end

-- public (BUG-373, readiness' R0 mood_ws): the workshop types the open strange moods wait for now (care's chain: his shop, Loom
-- for cloth, Tanners for leather ...), sorted; {} without a mood
function M.mood_wanted(K)
  local set, out = {}, {}
  for _, ts in pairs(Q.MOODWS) do for t in pairs(ts) do set[t] = true end end
  for t in pairs(set) do out[#out + 1] = t end
  table.sort(out)
  return out
end

-- BUG-181: the types of list no pending project of tpl builds (all of them while none is pending)
function M.uncovered(K, tpl, list)
  local set, all = M.pending_types(K, tpl)
  local out = {}
  if all then return out end
  for _, t in ipairs(list) do if not set[t] then out[#out + 1] = t end end
  return out
end

-- BUG-184 (live i4: 'reclaimed fort without Masons, Still, Kitchen' and its PROJECT_REQUEST every 9-10k ticks, about a
-- minute at 145 ticks/s, with follow off): whether request key may go out for ids now. A set with a new type waits
-- req_cool (a set that only lost types, one of them built meanwhile, counts as the same);
-- the k-th repeat of the same set waits req_cool * 2^(k-1) ticks AND req_wall_s * 2^(k-1) wall seconds (k <= req_backoff).
-- Records the request when due. S.rt.req[key]: {t, w, k, ids} (an old plain tick counts as k 1)
function M.req_due(K, key, ids)
  local rec = S.rt.req[key]
  if type(rec) == 'number' then rec = {t = rec, k = 1, ids = ids} end
  local T0 = K.now()
  local k, same = 0, false
  if type(rec) == 'table' then
    k = int(rec.k) or 1
    local was = {}
    for _, v in ipairs(type(rec.ids) == 'table' and rec.ids or {}) do was[v] = true end
    same = #ids > 0                                    -- no new type (a built one dropped out): the backoff goes on
    for _, v in ipairs(ids) do if not was[v] then same = false end end
    if not same or k < 1 then
      if (T0.tick or 0) - (int(rec.t) or 0) < M.CFG.req_cool then return false end
    else
      local f = 1 << (math.min(k, int(M.CFG.req_backoff) or 4) - 1)
      if not CAD.elapsed(rec, T0, M.CFG.req_cool * f, (M.CFG.req_wall_s or 0) * f) then return false end
    end
  end
  local cp = {}
  for i, v in ipairs(ids) do cp[i] = v end
  S.rt.req[key] = {t = T0.tick, w = T0.wall, k = same and k + 1 or 1, ids = cp}
  return true
end

-- BUG-200: the types of request key's last request while its episode stands (wsm: the mandatory workshops, S.rt.wmiss
-- set), else nil; economy's slab request does not ask for a Masons that request already names
function M.req_types(K, key)
  local rec = S.rt and S.rt.req and S.rt.req[key]
  if key == 'wsm' and not (S.rt and S.rt.wmiss) then return nil end
  return type(rec) == 'table' and type(rec.ids) == 'table' and rec.ids or nil
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

function Q.waive_verb(K, args, cmd)
  local tpl, why = args.tpl, args.why
  if type(tpl) ~= 'string' or tpl == '' then return false, 'tpl required (the deliverable, e.g. farms)' end
  if type(why) ~= 'string' or why == '' then return false, 'why required (what makes it impossible)' end
  local key = tpl .. (int(args.stage) and (' ' .. int(args.stage)) or '')
  local list, ph = phase_list(K), K.persist.get('phase')
  local i = list and type(ph) == 'table' and idx_of(list, ph.phase)
  if not i then return false, 'no phase list or phase yet' end
  local keys, hit = {}, nil
  for _, dv in ipairs(type(list[i].deliver) == 'table' and list[i].deliver or {}) do
    keys[#keys + 1] = Q.dv_key(dv)
    if Q.dv_key(dv) == key then hit = dv end
  end
  if not hit then
    return false, string.format('%s is no deliverable of %s (%s)', key, ph.phase, table.concat(keys, ', '))
  end
  if Q.waiver(ph, key) then return true, string.format('%s is waived already in %s', key, ph.phase) end
  local f = CHECK[hit.k]
  if f and f(K, hit) == true then return false, string.format('%s is met already in %s', key, ph.phase) end
  if hit.k == 'proj' then
    local pt = conf(K).park
    for _, P in ipairs(S.pd.list) do
      if P.tpl == hit.tpl and Q.live(K, P, pt) then
        return false, string.format('project %s (%s) runs: it may still deliver it (bp.cancel it first)', P.id, P.tpl)
      end
    end
  end
  local from = ph.phase
  Q.add_waive(K, ph, key, why, type(cmd) == 'table' and cmd.by or 'player')
  phases(K)
  rows(K)
  save(K)
  -- BUG-456: the verb takes 200 bytes, the waiver keeps 80 (the status line): a longer reason is cut and the reply says so
  return true, string.format('%s waived in %s (%s%s); phase now %s', key, from, trunc(why, 80),
                             #why > 80 and string.format(', reason cut from %d to 80 bytes', #why) or '', tostring(S.phase)),
         {phase = S.phase}
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
    -- light aquifer (damp_dig): lost() designates damp stone again, unless a cavern shows at the report (Run 11);
    -- FR-95: otherwise observe mode (aqshaft.observe) instead of a park, unless a cavern shows there
    if why == 'damp' and M.CFG.damp_dig and not pos then return end
    local r = (why == 'damp' or why == 'warm') and M.CFG.breach_r or M.CFG.cavern_r
    S.slice = {qf = 0, probes = 0, qf_max = M.CFG.undo_now}
    for _, P in ipairs(S.pd.list) do
      local d = P.done ~= 1 and P.tpl ~= 'plug' and doc(K, P.id)      -- the cavern plug is never stopped
      local st = d and d.stages[P.stage + 1]
      if st and st.mode == 'dig' and P.chunk > 0 and (not pos or near(pos, stage_tiles(P.id, d, P.stage).bbox, r)) then
        local cav = why == 'damp' and CAVERN[(M.opened(K, P, d, pos))]
        if why == 'damp' and not cav and (M.CFG.damp_dig or M.AQ.observe(Q.aqx(K), P, pos, 'report')) then
          dirty()                                    -- no stop: damp_dig re-designates, observe mode digs on
        elseif breach(K, P, why, pos, 'report') then undo(K, P) end
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
  -- BUG-300: a deliverable of the current phase that cannot be made is waived with its reason (follow sends it when farms
  -- find no site at all; the player when a template cannot be built). Refused for a deliverable met already, for one of
  -- another phase and while a project of that template runs
  ['phase.waive'] = function(K, args, cmd) return Q.waive_verb(K, args, cmd) end,
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
    local walls = (d.tpl == 'seal' or d.tpl == 'repair') and Q.place_walls(K, d) or nil   -- BUG-458: no wall that cuts citizens or places off
    if walls then return false, walls end
    local phantom = Q.phantom_doc(K, d)                                                  -- BUG-638: no seal onto solid rock
    if phantom then return false, phantom end
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
  -- BUG-328: a project set aside for want of progress takes a runner slot again, with a fresh idle_days
  ['bp.resume'] = function(K, args)
    local P = type(args.proj) == 'string' and find(args.proj)
    if not P then return false, 'no project ' .. tostring(args.proj) end
    if P.done == 1 then return false, P.id .. ' is already done' end
    if not Q.idle(P) then
      return false, string.format('%s is not set aside (%s)', P.id, P.blocked ~= '' and P.blocked or 'it runs')
    end
    local t = now(K)
    local r = S.rt.ip[P.id]
    S.rt.ip[P.id] = nil
    local R = S.rt.p[P.id]
    if type(R) == 'table' then R.ps, R.last = t, t end
    dirty()
    K.log('info', '%s (%s) resumed by bp.resume after %d days set aside', P.id, P.tpl, (t - (int(r.t) or t)) // DAY)
    rows(K)
    save(K)
    return true, string.format('resumed %s: it takes a runner slot again (set aside again after %d days without progress)',
                               P.id, conf(K).idle // DAY), {proj = P.id}
  end,
  ['bp.cancel'] = function(K, args)
    local P = type(args.proj) == 'string' and find(args.proj)
    if not P then return false, 'no project ' .. tostring(args.proj) end
    if args.reopen ~= nil then return Q.reopen(K, P, args) end          -- BUG-458: our walls come down, the project stays
    if P.done == 1 then return false, P.id .. ' is already done' end
    if args.undo ~= nil and type(args.undo) ~= 'boolean' then return false, 'undo must be true or false' end
    if P.blocked == 'cancel' then return true, P.id .. ' is already being cancelled' end
    cancel(K, P, args.undo == true)
    rows(K)
    save(K)
    local R = S.rt.p[P.id]
    local nrm = not args.undo and type(R) == 'table' and type(R.rm) == 'table' and #R.rm or 0
    local nul = not args.undo and type(R) == 'table' and type(R.undo) == 'table' and R.undo.plain and #R.undo.l or 0
    if nul > 0 then                                  -- BUG-353: the applied dig chunks are taken back first
      return true, string.format('cancelling %s (%d applied dig chunk(s) taken back%s)', P.id, nul,
                                 nrm > 0 and string.format(', %d unbuilt piece(s) removed', nrm) or '')
    end
    if nrm > 0 then                                  -- BUG-314: the unbuilt pieces go first (their DF jobs with them)
      return true, string.format('cancelling %s (%d unbuilt piece(s) removed first, their jobs with them)', P.id, nrm)
    end
    return true, (args.undo and 'cancelling ' .. P.id .. ' (undo queued)' or 'cancelled ' .. P.id)
  end,
}

-- BUG-329 (tests, read-only): the building on a tile (a finished farm plot too), build_state's answer in one word
M.bld_at, M.cls_of = Q.bld_at, Q.cls_of
M.lost_why, M.all_boxed, M.boxed_cancel = Q.lost_why, Q.all_boxed, Q.boxed_cancel     -- BUG-536 / BUG-538 (tests)
M.mat_why, M.depot_fallback = Q.mat_why, Q.depot_fallback          -- BUG-608 / BUG-612 (tests)
M.supply_why = Q.supply_why                                         -- BUG-655 (tests)

-- BUG-479 review (seal's plug_lift): the state of a project by id, nil when the runner has no such project (lost), else
-- {done = bool}
function M.plug_proj(K, id)
  local P = type(id) == 'string' and find(id)
  if not P then return nil end
  return {done = P.done == 1, cancelling = P.blocked == 'cancel' or nil}
end
-- the plug's project is cancelled without an undo: its unbuilt pieces and their jobs go, what stands stays (seal removes it).
-- true when a project was cancelled or is being, false when it is done or unknown
function M.cancel_proj(K, id)
  local P = type(id) == 'string' and find(id)
  if not P or P.done == 1 then return false end
  if P.blocked ~= 'cancel' then cancel(K, P, false); rows(K); save(K) end
  return true
end

return M
