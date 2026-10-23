-- gate (WP5): drawbridges with the single-pending-pull invariant (DESIGN §4, CONTRACTS §7).
-- A pull is queued only if (1) the wanted state differs from gate_flags.raised (lever.lua:39-41),
-- (2) the bridge is not raising/lowering, (3) NO PullLever job is pending on any
-- lever of that bridge, and (4) no living unit that is not hostile stands on the footprint or next to it (MARGIN).
-- BUG-027 (Run 10 Handlelock, y417/y418: a recruit and a miner died on B1's footprint 128,127..129,122 after siege
-- raised it with goblins far away; no combat report, one "missing"): that holds for raising and lowering, in every
-- mode, and for every unit that is not hostile: fort members by census id (citizens, residents, soldiers and
-- recruits, insane ones), the fort's tame animals (census.a) and the friendly units sense lists near the footprints
-- gate watches (census.h.friends, gate.watch). The lever is pulled when the puller finishes
-- the job, so a pending pull of ours is cancelled (the UI cancel) as soon as such a unit comes on or next to the
-- footprint, and queued again once it is clear. A bridge is never raised onto a unit only because the wait was long
-- (the old SIEGE/BREACH rule raised after 300 ticks and ignored the margin and the pending check: the Run 10 deaths);
-- only a raise in SIEGE/BREACH with a visible hostile within force_near tiles of the footprint (config/reflex.json
-- `gate.force_near`, default 3, 0 = never) goes ahead, and GATE_FORCED (A) names the units. Bridges named in
-- `gate.manual` (manifest names or building ids) get no automatic pull at all (a stop-gap; the inbox `lever` still
-- works). A held 'up' reaches GATE_FAIL (blocked) at its deadline with the units and their squad stations named.
-- Our own job without a worker for 200 ticks is cancelled (act.cancel_own_lever_job, the UI
-- cancel) and the next pull goes to the backup lever.
-- Pulls go through act.pull -> reqscript('lever').leverPullJob (lever.lua:4, never deduplicates).
-- Lever rooms (live L3, the S3 fallback): manifest burrows named 'dfllm-levers*' hold levers; in SIEGE/DRILL/
-- BREACH gate assigns lever pullers to them (act.burrow_units, the burrow screen) and pulls a lever with a
-- puller present first; siege lists the allowed rooms in the civ alert (gate.rooms).
-- Lockdown (FR-49/52, Run 9: an army walked in over four lowered drawbridges the kernel did not know): while the
-- reflex module holds a lockdown (reflex.holding('gates')), every manifest outer/inner bridge is wanted up and so is
-- every lever-linked drawbridge OUTSIDE the manifest ('X<building id>', found from the levers' links): no manifest
-- needed (fail-open), the same single-pending-pull invariant, footprint and GATE_FAIL rules. SIEGE/BREACH raise those
-- unmanaged bridges too, with or without the reflex module. 'down' is refused while the lockdown holds. Afterwards
-- an unmanaged bridge the lockdown raised is lowered again in PEACE (peace_gates D-14 = down) or kept up (D-14 = up).
-- Peace gates (FR-55, D-14 = up): in PEACE the manifest outer/inner bridges (and kept unmanaged ones) stay up;
-- they open only for a window: a caravan on the map (trade state, or its arrival report), migrants arriving, an
-- inbox `lever` down (that bridge), each while no hostile is visible, and close WIN_CLOSE ticks after the reason ends.
-- Lever latency (FR-55): ticks and real seconds from our queued pull to the bridge in the wanted state (state lever).
-- Levers inside the civ alert (BUG-013, Run 9 forced arrival on 677bc3e: the alert held every civilian in Kern+, the
-- four gate levers lay outside it, their PullLever jobs stayed unclaimed for minutes and 1-3 of 4 bridges rose). How
-- DF treats a burrow-restricted unit (its own burrows, or every civilian's restriction to the alert's burrows while
-- the civ alert sounds): it takes only jobs whose site lies inside one of those burrows (and uses only items there);
-- its path is not restricted, it walks over tiles outside every burrow to reach a job site or another of its burrows.
-- A PullLever job's site is the lever's tile, where the puller stands (a 1x1 building). So a burrow holding just the
-- lever tiles is enough: seal paints its lever burrow (seal.CFG.levers, 'Hebel+') with every linked lever of the
-- bridges gate holds, and rooms() hands it to siege for the alert list while a pull is pending on a bridge none of
-- whose linked levers lies in the alert's main burrow or a lever room; once the pulls are done it leaves the list and
-- the alert draws the puller back. In BREACH only while no hostile is inside Kern+ or near those levers (BUG-027,
-- breach_safe; else the lever-room rule below: attacker-side levers). pulls() tells the
-- reflex what its deferred alert waits for and which pulls the alert blocks (levers outside every alert burrow).
-- Run 11 y432 winter (deep defense, GATE_FAIL O1 'no_worker', lever 18664 pulled again and again; by hand taken at
-- once): the confined civilians stood in Tiefe+, O1's refuge lever lay there, so Hebel+ was never listed, and the pulls
-- went to the Kern+ levers first (their order put Kern+ first outside BREACH), which nobody confined could take. Now:
-- a pull goes first to a lever in the burrows the sounding alert lists (BREACH: the refuge, as before); a pull that
-- waits on a lever outside them while a usable one lies inside moves to it at once (not after NO_WORKER); the lever
-- burrow is listed too when every lever inside failed this epoch; and whenever the alert confines to the refuge
-- (BREACH, the deep defense, a lockdown that took Tiefe+) the lever burrow follows breach_safe.
-- Intake waves and the sortie through O1 (Gordon 2026-10-16): siege's wants 'down' with why 'intake' (outer, inner,
-- core) or 'sortie' (outer, inner) pass in SIEGE and during a lockdown (SIEGE_DOWN; siege's own hostile checks replace
-- the 30-tile guard, the footprint rules hold), under the airlock: an outer bridge only while every inner one is up and
-- wanted up, an inner one only while every outer one is; the lockdown pass leaves those wants alone.
-- Destroyed bridges (BUG-030, Run 10 y421: trolls destroyed O1, B1 and B2; for nine days gate kept their wants, GATE_FAIL
-- read no_lever and siege's STRANDED named 'B1 raised' 40+ times while buildings.other.BRIDGE was empty): gate keeps the
-- building id of every manifest bridge it saw complete on its footprint (persisted m.gate.seen). When that building is
-- gone and no bridge stands on the footprint any more, the bridge is destroyed (or removed): BRIDGE_DESTROYED (A) once,
-- its want, pull and move record are dropped, no want is accepted for it (gate.want refuses), it is no gate failure, and
-- state `bridges` says 'destroyed'. gate.state(bridge) keeps answering 'unknown' for it (as for a bridge not built yet:
-- readiness' bridge:B blocker) and adds the tick it was found destroyed as its third value, so siege can treat it as an
-- open way. Its footprint is searched for a new complete bridge once a game day (GONE_RECHECK): a rebuilt one is a
-- plain manifest bridge again (GATE C 'rebuilt').
-- Loss history (BUG-030 rebuild policy; Run 11 site98, y434-y438: cave dragons destroyed O1 in all five sieges and the
-- perimeter keeper rebuilt it every time): per manifest bridge (persisted m.gate.lost) how often it was destroyed (n),
-- how often with building destroyers in sight (bd: census.h.bd within LOST_BD ticks before the loss), their races, the
-- newest LOST_EV losses (tick, year, mode, bd), how often it stood again (reb), the building items of the bridges lost
-- (it, mat: read from the building once, when gate first sees it complete) and the lever links gate queued after a
-- loss (lk). seal's perimeter keeper reads it (gate.losses) to stop rebuilding a bridge the destroyers keep breaking;
-- `inspect defense` shows it. A new footprint in the manifest starts a new record.
local geom = require('dfllm.util.geom')
local DT = require('dfllm.deaths')      -- BUG-027: the bridge-death match (library, no module)
local CAD = require('dfllm.util.cadence')   -- BUG-068: LEVER_NOEFFECT once per lever
local M = {name = 'gate', every = {ticks = 600}, critical = true, verbs = {},
           reports = {MIGRANT_ARRIVAL = true, MIGRANT_ARRIVAL_NAMED = true, D_MIGRANTS_ARRIVAL = true,
                      CARAVAN_ARRIVAL = true, FIRST_CARAVAN_ARRIVAL = true}}

M.FAST, M.SLOW = 25, 600   -- cadence: FAST in SIEGE/BREACH/DRILL or while a bridge has work
M.NO_WORKER = 200          -- ticks our queued pull may wait without a worker
-- live L4: a drill raised B1 15 ticks after the footprint had cleared; the militia commander, carrying her
-- baby, stepped back on while the bridge moved (108 ticks) and both died (death cause DRAWBRIDGE). A bridge
-- moves ~100 ticks after its pull, so every pull (BUG-027: in SIEGE/BREACH too) waits for this many tiles around
-- the footprint to be clear, and a pending one is cancelled when a unit comes that close. One tile: the commander
-- had just stepped off; fortcore's melee station stands 2 tiles from B1 and its soldiers would hold B1 down for a
-- whole drill with a wider margin.
M.MARGIN = 1
M.FORCE_NEAR = 3           -- BUG-027: SIEGE/BREACH raise onto a unit only with a visible hostile this close (cfg)
-- BUG-027: while one of our pulls is pending gate re-checks it every frame (M.PENDING); the census pass (every FAST
-- ticks) keeps the units within SCAN_R tiles of the footprint, and the frames in between re-read only their positions
-- (a dwarf walks about a tile per 9-tick frame, so nobody reaches the margin unseen within FAST ticks)
M.PENDING = 1
M.SCAN_R = 5
-- BUG-027 (Run 10: GATE_FAIL B1/O1 "timeout" at T+900 with the pulls under way, lever latency 11-19 s at 30 t/s): the
-- time a bridge waits for units on its footprint does not count toward its deadline (a bridge held for DEADLINE ticks
-- on end is GATE_FAIL blocked); a pull in progress at the deadline (a worker took it, or the bridge moves) goes once to
-- another linked lever and gets max(PULL_ALLOW, the measured lever latency) ticks more before GATE_FAIL slow
M.PULL_ALLOW = 300
-- BUG-027: each bridge move is recorded (gate.moves: the pull, the move window, every unit seen within SCAN_R tiles of
-- the footprint while the pull was pending or the bridge moved) for MOVES_KEEP ticks after it settled; a death that
-- matches one (dfllm.deaths.bridge) is BRIDGE_CRUSH (A) and care's DEATH cause `crushed` (src bridge)
M.MOVES_KEEP, M.MOVES_MAX, M.SEEN_MAX = 2400, 16, 40
M.WATCH_R = 6              -- BUG-027: sense lists friendly non-citizens within this many tiles of a watched footprint
M.NAME_MAX = 3             -- units named in a GATE / GATE_FAIL / GATE_FORCED text
M.HOLD_LOG = 25            -- ticks between kern.log lines of one bridge's new holders
M.SETTLE = 50              -- ticks after a pull job left the queue before another may be queued
M.DEADLINE = 900           -- default: an 'up' not reached by then -> GATE_FAIL (A)
M.DOWN_GUARD = 30          -- 'down' refused while a visible hostile is this close to the bridge
M.RESOLVE = 6000           -- ticks between re-resolving a complete bridge (findAtTile is a linear scan)
M.RESOLVE_RETRY = 100      -- incomplete (no bridge or no linked lever): retry this often ...
M.RESOLVE_URGENT = 20      -- ... and this often while the bridge is not in its wanted state
M.FAIL_REPEAT = 1200       -- the same bridge's GATE_FAIL at most once per day
M.EXTRA_EVERY = 1200       -- ticks between scans for lever-linked bridges outside the manifest
M.EXTRA_MAX = 16           -- at most this many of them are handled
M.WIN_CLOSE = 600          -- D-14 up: a window closes this many ticks after its last reason
M.WIN_MIGRANTS = 2400      -- ... a migrant arrival report keeps it open this long
M.WIN_CARAVAN = 4800       -- ... a caravan arrival report (trade's state keeps it open while a caravan is here)
M.WIN_LEVER = 2400         -- ... an inbox `lever` down keeps that bridge open this long
M.GONE_RECHECK = 1200      -- BUG-030: a destroyed bridge's footprint is searched for a rebuilt one once a game day
M.LOST_BD = 2400           -- loss history: building destroyers in sight this many ticks before a loss make it theirs
M.LOST_EV, M.LOST_RACES = 6, 4   -- ... the newest losses and the destroyer races kept per bridge
-- BUG-068 (Run 12 Trussroads, a reclaimed fort: lever 11808 of the old fort's bridge X11814 pulled six times in one
-- second at timestream speed with no effect): a pull whose job left the queue without the bridge moving counted
-- against that lever only until the other levers were tried; a bridge with one lever (or all failed) was pulled again
-- SETTLE ticks later, for ever. Now NE_MAX such pulls in a row park the lever for NE_WAIT ticks (a quarter of it in
-- SIEGE/BREACH/DRILL), doubling per further parking up to NE_TIMES times (config/reflex.json gate.noeffect_max and
-- gate.noeffect_wait). LEVER_NOEFFECT (B) reports it once per lever (util/cadence, persisted m.gate.ne), and a bridge
-- with a parked lever fails as GATE_FAIL `no_effect`. A pull that moved the bridge, or a mode change, clears the record.
M.NE_MAX, M.NE_WAIT, M.NE_TIMES = 3, 1200, 8

local FAST_MODES = {SIEGE = true, BREACH = true, DRILL = true}
local FORCE_MODES = {SIEGE = true, BREACH = true}       -- may RAISE onto a unit, only with a hostile at the gate
local LOCK_MODES = {SIEGE = true, BREACH = true}        -- raise the unmanaged bridges even without the reflex module
local GATE_ROLES = {outer = true, inner = true}         -- the bridges a lockdown and the peace gates hold up
local FAIL_WHY = {blocked = 'blocked', no_lever = 'no_lever', no_worker = 'no_worker', outside = 'outside_alert',
                  manual = 'manual', slow = 'slow', no_effect = 'no_effect'}

local st      -- persisted m.gate: {v, br = {<b> = {want, why, since, deadline, failed}}, kpi = {...},
              --   ex = {X<id> = {bid, raised}} (unmanaged bridges in hand), lat = {s, t}, win = tick, winb = {<b> = tick},
              --   seen = {<b> = {bid, fp, it, mat}} (BUG-030: the complete bridge last seen on the footprint fp
              --   'x,y,z,...', its building items and their material), gone = {<b> = {t, bid, last}} (destroyed: when,
              --   which building, its last state), lost = {<b> = {n, bd, reb, it, mat, lk, races, ev}} (loss history)}
local rt      -- runtime per bridge: building ids, own job, settle, block, rotation
local bds     -- runtime: {t, races} the last pass that saw building destroyers (census.h.bd), for the loss history
local rt_ex   -- runtime: cached unmanaged bridge list {tick, list = {{name, bid, spec}}}
local pub     -- precomputed state part {bridges = {...}}
local last_pass   -- tick of the last full pass (BUG-027: frames in between only re-check pending pulls)
local mvl         -- BUG-027 runtime: the last bridge moves, oldest first; crushed = {<unit id> = true} announced
local dirty
local PULL    -- df.job_type.PullLever

-- take = ticks from our queued pull to the first worker seen, per bridge (last pull); pp = pulls a lever puller
-- took; pa = puller assignments (live L3: O1's job was taken 156-243 ticks late)
local function new_kpi(t0)
  return {dbl = 0, t0 = t0, raise = {}, pulls = 0, cancels = 0, links = 0, fails = {}, take = {}, pp = 0, pa = 0}
end

local function flush(K)
  if dirty then K.persist.set('m.gate', st); dirty = false end
end

local function runtime(name)
  local r = rt[name]
  if not r then
    r = {levers = {}, linked = {}, bad = {}, nw = 0, pos = {}}
    rt[name] = r
  end
  return r
end

local function valid_spec(spec)
  return type(spec) == 'table' and type(spec.fp) == 'table' and #spec.fp == 6
end

local function bridge_names(man)
  local r = {}
  for name, spec in pairs(man.bridges or {}) do if valid_spec(spec) then r[#r + 1] = name end end
  table.sort(r)
  return r
end

-- why the reflex lockdown wants every linked bridge up now (FR-49/52), or nil (level-triggered: asked each pass)
local function lock_why(K)
  local ok, why = K.call('reflex', 'holding', 'gates')
  if ok and type(why) == 'string' and why ~= '' then return why end
end

-- peace_gates (D-14): 'up' keeps the gates up in PEACE (FR-55), 'down' (default) is the PEACE mode table
local function peace_up(K)
  return tostring(K.cfg.decisions and K.cfg.decisions['D-14'] or 'down') == 'up'
end

---------------------------------------------------------------- DF reads (buildings, jobs)
local function find_at(p)
  local ok, b = pcall(dfhack.buildings.findAtTile, p[1], p[2], p[3])   -- Lua API.txt:2484
  return ok and b or nil
end

local function is_bridge(b)
  local ok, r = pcall(function()
    if df.building_type and b.getType then return b:getType() == df.building_type.Bridge end
    return b.gate_flags ~= nil
  end)
  return ok and r == true
end

local function is_lever(b)
  local ok, r = pcall(function() return b.trap_type == df.trap_type.Lever end)
  return ok and r == true
end

-- ids of the buildings a lever is linked to (lever.lua:24-27), nil if unreadable
local function targets(lv)
  local r = {}
  local ok = pcall(function()
    for _, m in ipairs(lv.linked_mechanisms) do
      local ref = dfhack.items.getGeneralRef(m, df.general_ref_type.BUILDING_HOLDER)
      local tb = ref and ref:getBuilding()
      if tb then r[tb.id] = true end
    end
  end)
  return ok and r or nil
end

local function pull_type()
  PULL = PULL or (df.job_type and df.job_type.PullLever)
  return PULL
end

local function pull_job(lv)
  local t = pull_type()
  for _, j in ipairs(lv.jobs) do if j.job_type == t then return j end end
end

local function job_on(lv, id)
  for _, j in ipairs(lv.jobs) do if j.id == id then return j end end
end

local function worker(j)
  local ok, w = pcall(dfhack.job.getWorker, j)                         -- Lua API.txt:1360
  return ok and w or nil
end

-- a bridge's gate_flags are named raised/raising/lowering (lever.lua:39-41 flag_names[Bridge]; the
-- v1 BUG-427 fix read them live); doors/floodgates use closed/closing/opening. Reading a field the
-- bitfield lacks raises, so each name is probed in pcall.
local function flag(gf, k)
  local ok, v = pcall(function() return gf[k] end)
  if ok then return v end
end
local function read(r)
  local b = r.bid and df.building.find(r.bid)
  if not b then return 'unknown' end
  local gf = b.gate_flags
  if flag(gf, 'raising') or flag(gf, 'lowering') or flag(gf, 'closing') or flag(gf, 'opening') then
    return 'moving'
  end
  local up = flag(gf, 'raised')
  if up == nil then up = flag(gf, 'closed') end
  if up == nil then return 'unknown' end
  return up and 'up' or 'down'
end

local function any_linked(r)
  for _, lid in ipairs(r.levers) do if r.linked[lid] then return true end end
  return false
end

-- the bridge building on a footprint: findAtTile first, else by extents in buildings.other.BRIDGE
-- (a raised bridge need not show at its tiles)
local function find_bridge(fp)
  local c = geom.bbox_center(fp)
  for _, p in ipairs({{c.x, c.y, c.z}, {fp[1], fp[2], fp[3]}, {fp[4], fp[5], fp[3]}}) do
    local x = find_at(p)
    if x and is_bridge(x) then return x end
  end
  local ok, r = pcall(function()
    for _, b in ipairs(df.global.world.buildings.other.BRIDGE) do
      if b.z == c.z and c.x >= b.x1 and c.x <= b.x2 and c.y >= b.y1 and c.y <= b.y2 then return b end
    end
  end)
  return ok and r or nil
end

-- bridge and lever building ids from the manifest positions, cached. A valid cached bridge is kept
-- (never re-found mid-siege). A complete resolution (bridge + a linked lever) is refreshed every
-- M.RESOLVE ticks; an incomplete one is never trusted for long, because linking a lever is a
-- separate job that often finishes after the bridge exists. r.resolved = nil forces a refresh.
local function resolve(r, spec, now, urgent)
  local parts = {table.concat(spec.fp, ',')}
  for _, p in ipairs(spec.levers or {}) do parts[#parts + 1] = table.concat(p, ',') end
  local sig = table.concat(parts, ';')
  local cached = r.bid and df.building.find(r.bid)
  if cached and not is_bridge(cached) then cached = nil end
  local same = r.sig == sig
  if same and r.resolved then
    local age = now - r.resolved
    if cached and any_linked(r) then
      if age < M.RESOLVE then return end
    elseif age < (urgent and M.RESOLVE_URGENT or M.RESOLVE_RETRY) then return end
  end
  r.sig, r.resolved = sig, now
  local b = (same and cached) or find_bridge(spec.fp) or cached
  r.bid = b and b.id or nil
  r.levers, r.linked, r.pos = {}, {}, {}
  local function add(lv, t, p)
    if #r.levers >= 4 or r.linked[lv.id] ~= nil then return end
    r.levers[#r.levers + 1] = lv.id
    r.linked[lv.id] = (t == nil) or (r.bid ~= nil and t[r.bid] == true)  -- unreadable link: usable
    r.pos[lv.id] = p
  end
  for _, p in ipairs(spec.levers or {}) do
    local lv = find_at(p)
    if lv and is_lever(lv) then add(lv, targets(lv), p) end
  end
  -- stale manifest positions: levers linked to this bridge (one vector scan per RESOLVE_RETRY at most)
  if r.bid and not any_linked(r) and now - (r.scan_tick or -M.RESOLVE_RETRY) >= M.RESOLVE_RETRY then
    r.scan_tick = now
    for _, lv in ipairs(df.global.world.buildings.other.TRAP) do      -- lever.lua:103
      if is_lever(lv) then
        local t = targets(lv)
        if t and t[r.bid] then add(lv, t, {lv.x1, lv.y1, lv.z}) end
      end
    end
  end
end

-- any pending PullLever job on any lever of the bridge (ours or not)
local function pending(r)
  for _, lid in ipairs(r.levers) do
    local lv = df.building.find(lid)
    if lv then
      local j = pull_job(lv)
      if j then return j, lid end
    end
  end
end

-- the lever is still there and still linked to this bridge (an unreadable link counts as linked)
local function linked_now(r, lid)
  local lv = df.building.find(lid)
  if not (lv and is_lever(lv)) then return false end
  local t = targets(lv)
  return t == nil or (r.bid ~= nil and t[r.bid] == true)
end

---------------------------------------------------------------- lever rooms and pullers (live L3, S3 fallback)
-- A lever room is a small manifest burrow named 'dfllm-levers*' (fortcore: the Z3 strip with the O1/B1 levers,
-- the Z4 landing strip with the B2 levers). Live L3 drills: O1's pull was taken 156-243 ticks after queueing
-- (the nearest idle dwarf walked up from the core), O1 rose at T+917/945/1,076. In SIEGE/DRILL/BREACH gate
-- assigns M.PULLERS adult civilians (no soldiers, children, insane or moody dwarves; inside Kern+/Tiefe+ and
-- nearest first) to every room whose bridges the mode raises (outer/inner in SIEGE/DRILL, core in BREACH):
-- act.burrow_units, the burrow screen's unit list. They stay next to the levers, and pick() takes a lever in a
-- room with a puller present first. A puller who is not in his room after PULLER_ARRIVE ticks, or who died,
-- went insane, was drafted or fell into a mood is replaced (and not chosen again in this episode). A puller who
-- gets thirsty or hungry is let go (the rooms hold no drink or food, and a burrow-held dwarf does not walk out to
-- drink: live L3, 21 thirsty citizens in the alert burrow) and may serve again after a drink and a meal. Other
-- modes release them. BREACH allows only rooms behind the core seal (a core lever, no outer/inner lever), and only
-- while one of their bridges has no linked lever inside the refuge: siege puts the allowed rooms into the civ alert
-- (gate.rooms); an attacker-side room, or the B2 landing while B2 may still be down, would draw fleeing civilians
-- out of Tiefe+ toward the attackers. fortcore gives every bridge a lever inside Tiefe+; once it is linked the
-- BREACH pulls go there. Without act.burrow_units nobody is assigned; the rooms still order the levers and stay
-- in the alert list.
M.ROOM_PREFIX = 'dfllm-levers'
M.PULLERS = 2
M.PULLER_ARRIVE = 600
M.PULLER_RETRY = 600       -- a refused assignment is tried again after this
M.PULLER_FILL = 100        -- a room that found too few candidates looks again after this (a census scan each time)
M.PULLER_THIRST = 20000    -- counters2 thirst_timer / hunger_timer at which a puller is let go (economy's supply
M.PULLER_HUNGER = 40000    -- alarm reads the same counters; DF shows 'thirsty' at 25,000 and 'hungry' at 50,000)
M.ROOM_EVERY = 100         -- ticks between re-reading which manifest levers lie in which room
local PULL_ROLES = {SIEGE = {outer = true, inner = true}, DRILL = {outer = true, inner = true}, BREACH = {core = true}}
local PT = {x = 0, y = 0, z = 0}      -- scratch coord for burrow tile reads
local pl                              -- runtime: {rooms = {<room> = {ids, at, skip, retry}}, warned}
local rooms_c                         -- cached room list {tick, list}

local function burrow(name)
  if type(name) ~= 'string' then return nil end
  local ok, b = pcall(dfhack.burrows.findByName, name)      -- Lua API.txt:2412
  return ok and b or nil
end

local function on_tile(b, x, y, z)
  if not b or x == nil then return false end
  PT.x, PT.y, PT.z = x, y, z
  local ok, r = pcall(dfhack.burrows.isAssignedTile, b, PT)   -- :2436
  return ok and r == true
end

local function unit_pos(u)
  if not u then return nil end
  local ok, x, y, z = pcall(dfhack.units.getPosition, u)
  if ok then return x, y, z end
end

-- the manifest's Kern+ and refuge burrow names (as siege/sense: role kern/refuge, refuge.burrow wins)
local function core_burrows(man)
  local kern, refuge
  local names = {}
  for name in pairs(type(man.burrows) == 'table' and man.burrows or {}) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    local role = type(man.burrows[name]) == 'table' and man.burrows[name].role
    if role == 'kern' and (kern == nil or name == 'Kern+') then kern = name end
    if role == 'refuge' and (refuge == nil or name == 'Tiefe+') then refuge = name end
  end
  if type(man.refuge) == 'table' and type(man.refuge.burrow) == 'string' then refuge = man.refuge.burrow end
  return kern or 'Kern+', refuge or 'Tiefe+'
end

-- existing rooms that hold manifest levers: {name, roles = {outer|inner|core}, bridges = {<b>}, c = lever centre}
local function room_list(K, now)
  if rooms_c and now >= rooms_c.tick and now - rooms_c.tick < M.ROOM_EVERY then return rooms_c.list end
  local man = K.manifest()
  local names, list = {}, {}
  for name in pairs(type(man.burrows) == 'table' and man.burrows or {}) do
    if type(name) == 'string' and name:sub(1, #M.ROOM_PREFIX) == M.ROOM_PREFIX then names[#names + 1] = name end
  end
  table.sort(names)
  for _, name in ipairs(names) do
    local b = burrow(name)
    if b then
      local rm, n, sx, sy, sz = {name = name, roles = {}, bridges = {}}, 0, 0, 0, 0
      for _, bn in ipairs(bridge_names(man)) do
        local spec = man.bridges[bn]
        for _, p in ipairs(spec.levers or {}) do
          if type(p) == 'table' and on_tile(b, p[1], p[2], p[3]) then
            rm.bridges[bn], rm.roles[tostring(spec.role)] = true, true
            n, sx, sy, sz = n + 1, sx + p[1], sy + p[2], sz + p[3]
          end
        end
      end
      if n > 0 then
        rm.c = {x = sx // n, y = sy // n, z = sz // n}
        list[#list + 1] = rm
      end
    end
  end
  rooms_c = {tick = now, list = list}
  return list
end

-- every bridge of the room has a linked lever on a tile of the refuge burrow (gate's resolved levers)
local function refuge_covers(K, rm)
  local _, rn = core_burrows(K.manifest())
  local rb = burrow(rn)
  if not rb then return false end
  for bn in pairs(rm.bridges) do
    local r, ok = rt[bn], false
    for _, lid in ipairs(r and r.levers or {}) do
      local p = r.pos[lid]
      if r.linked[lid] and type(p) == 'table' and on_tile(rb, p[1], p[2], p[3]) then ok = true; break end
    end
    if not ok then return false end
  end
  return true
end

-- BREACH: rooms behind the core seal only, and only while the refuge lacks a linked lever of their bridges (the
-- B2 landing lies next to B2, which may still be down while attackers are inside Kern+)
local function allowed(K, rm, mode)
  local live = false                            -- BUG-030: a room whose bridges are all destroyed has no duty
  for bn in pairs(rm.bridges) do if not st.gone[bn] then live = true; break end end
  if not live then return false end
  if mode ~= 'BREACH' then return true end
  return rm.roles.core == true and not rm.roles.outer and not rm.roles.inner and not refuge_covers(K, rm)
end

local function duty(K, rm, mode)
  local want = PULL_ROLES[mode]
  if not want or not allowed(K, rm, mode) then return false end
  for role in pairs(rm.roles) do if want[role] then return true end end
  return false
end

local function room_state(name)
  local p = pl.rooms[name]
  if not p then
    p = {ids = {}, at = {}, skip = {}}
    pl.rooms[name] = p
  end
  return p
end

-- assigned pullers of a room standing on its tiles now
local function present(rm)
  local p = pl.rooms[rm.name]
  if not p or #p.ids == 0 then return 0 end
  local b, n = burrow(rm.name), 0
  for _, id in ipairs(p.ids) do
    if on_tile(b, unit_pos(df.unit.find(id))) then n = n + 1 end
  end
  return n
end

local function puller_room(id)
  for name, p in pairs(pl.rooms) do
    for _, x in ipairs(p.ids) do if x == id then return name end end
  end
end

local function counter(u, k)
  local ok, v = pcall(function() return u.counters2[k] end)
  return ok and type(v) == 'number' and v or 0
end

-- why a citizen cannot be (or stay) a lever puller: 'gone' = dead, insane (isCitizen is sane only), no citizen,
-- child, soldier or in a strange mood (df.mood_type None = -1); 'needs' = thirsty or hungry; nil = fit
local function unfit(u)
  if not u then return 'gone' end
  local U = dfhack.units
  local ok, r = pcall(function()
    if U.isDead(u) or not U.isCitizen(u) or not U.isAdult(u) then return 'gone' end
    if u.military.squad_id >= 0 then return 'gone' end
    local m = u.mood
    if type(m) == 'number' and m >= 0 then return 'gone' end
    return false
  end)
  if not ok then return 'gone' end
  if r then return r end
  if counter(u, 'thirst_timer') >= M.PULLER_THIRST or counter(u, 'hunger_timer') >= M.PULLER_HUNGER then
    return 'needs'
  end
  return nil
end

-- the burrow's unit list as DF holds it (after a load our runtime is empty); nil if unreadable
local function live_units(name)
  local b = burrow(name)
  if not b then return nil end
  local ok, ids = pcall(function()
    local r = {}
    for _, id in ipairs(b.units) do r[#r + 1] = id end
    return r
  end)
  return ok and ids or nil
end

local function same_set(a, b)
  if #a ~= #b then return false end
  local s = {}
  for _, x in ipairs(a) do s[x] = true end
  for _, x in ipairs(b) do if not s[x] then return false end end
  return true
end

-- nearest eligible citizens inside Kern+/Tiefe+ (z counts double: stairs), outside ones only as a last resort
local function fill(K, rm, want, p, taken, now, home)
  local cu = K.census.u
  if type(cu) ~= 'table' or type(cu.ids) ~= 'table' then return end
  local c, cand = rm.c, {}
  for _, id in ipairs(cu.ids) do
    if not taken[id] and not p.skip[id] then
      local u = df.unit.find(id)
      if unfit(u) == nil then
        local x, y, z = unit_pos(u)
        if x then
          local d = math.max(math.abs(x - c.x), math.abs(y - c.y)) + 2 * math.abs(z - c.z)
          if not (on_tile(home.kern, x, y, z) or on_tile(home.refuge, x, y, z)) then d = d + 1000 end
          cand[#cand + 1] = {id = id, d = d}
        end
      end
    end
  end
  table.sort(cand, function(a, b) if a.d ~= b.d then return a.d < b.d end return a.id < b.id end)
  for _, e in ipairs(cand) do
    if #want >= M.PULLERS then break end
    want[#want + 1] = e.id
    taken[e.id], p.at[e.id] = rm.name, now
  end
end

-- level-triggered: every room's unit list = the pullers the mode wants (none outside SIEGE/DRILL/BREACH)
local function pullers_step(K, now)
  local set = rawget(K.act, 'burrow_units')   -- [S3]: act + contract.ACT entry pending (live engineer)
  local mode = K.mode()
  if not set then
    if PULL_ROLES[mode] and not pl.warned and #room_list(K, now) > 0 then
      pl.warned = true
      K.log('warn', 'gate: act.burrow_units missing, the lever rooms get no pullers')
    end
    return
  end
  local rooms = room_list(K, now)
  if #rooms == 0 then return end
  local kn, rn = core_burrows(K.manifest())
  local home = {kern = burrow(kn), refuge = burrow(rn)}
  local taken = {}
  for _, rm in ipairs(rooms) do
    local p = pl.rooms[rm.name]
    if not p then                                 -- first look after a load: adopt what DF holds
      p = room_state(rm.name)
      p.ids = live_units(rm.name) or {}
      for _, id in ipairs(p.ids) do p.at[id] = now end
    end
    for _, id in ipairs(p.ids) do taken[id] = rm.name end
  end
  for _, rm in ipairs(rooms) do
    local p = pl.rooms[rm.name]
    local want, why_of = {}, {}
    if duty(K, rm, mode) then
      local b = burrow(rm.name)
      for _, id in ipairs(p.ids) do
        local u = df.unit.find(id)
        local why = unfit(u)
        if not why and not on_tile(b, unit_pos(u)) and now - (p.at[id] or now) >= M.PULLER_ARRIVE then why = 'away' end
        if why then
          if why ~= 'needs' then p.skip[id] = true end   -- thirsty/hungry: may serve again after a drink and a meal
          taken[id], why_of[id] = nil, why
        else
          want[#want + 1] = id
        end
      end
      if #want < M.PULLERS and now >= (p.fill_at or now) then
        fill(K, rm, want, p, taken, now, home)
        p.fill_at = #want < M.PULLERS and now + M.PULLER_FILL or nil   -- too few candidates: no scan per step
      end
    elseif next(p.skip) or next(p.at) or p.fill_at then
      p.skip, p.at, p.fill_at = {}, {}, nil       -- the next episode starts afresh
    end
    if not same_set(want, p.ids) and now >= (p.retry or now) then
      local ok = set(rm.name, want)
      if ok then
        local had, keep, new, gone = {}, {}, 0, {}
        for _, id in ipairs(p.ids) do had[id] = true end
        for _, id in ipairs(want) do keep[id] = true; if not had[id] then new = new + 1 end end
        for _, id in ipairs(p.ids) do
          if not keep[id] then
            if taken[id] == rm.name then taken[id] = nil end
            if why_of[id] then gone[#gone + 1] = id .. ':' .. why_of[id] end
          end
        end
        if new > 0 then st.kpi.pa, dirty = (st.kpi.pa or 0) + new, true end
        K.log('info', 'gate: lever pullers %s = {%s} (%s)%s', rm.name, table.concat(want, ','), mode,
              #gone > 0 and (', let go ' .. table.concat(gone, ',')) or '')
        p.ids, p.retry = want, nil
      else
        p.retry = now + M.PULLER_RETRY
      end
    end
  end
end

---------------------------------------------------------------- levers inside the civ alert (BUG-013, see the head)
M.LEVER_TILES = 64         -- linked lever tiles handed to seal's lever burrow at most
local lb_name              -- runtime: the lever burrow's name as seal answered it last

-- the burrows the civ alert confines the civilians to now (siege's list) and their names; nil while it is silent
local function alert_burrows(K)
  local ok, names = K.call('siege', 'alert_names')
  if not (ok and type(names) == 'table' and #names > 0) then return nil end
  local bs = {}
  for _, n in ipairs(names) do bs[#bs + 1] = burrow(n) end
  return bs, names
end

-- lever `lid` of the bridge lies on a tile of one of the burrows `bs`
local function at_in(r, lid, bs)
  local p = r.pos[lid]
  if type(p) ~= 'table' then return false end
  for _, b in ipairs(bs) do if on_tile(b, p[1], p[2], p[3]) then return true end end
  return false
end

-- a linked lever of the bridge lies on a tile of one of the burrows `bs`; usable: one that did not fail this epoch
-- (r.bad: no worker took it, or its pull did nothing)
local function lever_in(r, bs, usable)
  for _, lid in ipairs(r and r.levers or {}) do
    if r.linked[lid] and not (usable and r.bad[lid]) and at_in(r, lid, bs) then return true end
  end
  return false
end

-- the bridge still needs a pull: its wanted state is not reached and it has a linked lever; a bridge waiting for a
-- citizen to leave its footprint (the alert calls him in), for the down guard or without a lever needs none now
-- BUG-082: no_effect (every linked lever parked, BUG-068) is no pull to wait for either: the lockdown's deferred civ alert
-- (reflex.alert_due, gate.pulls().left) must not wait for it up to ALERT_MAX ticks
local NO_PULL = {no_lever = true, blocked = true, guard = true, manual = true, no_effect = true}
local function needs_pull(name)
  local br, r = st.br[name], rt[name]
  if not (br and br.want and r) or r.last == br.want or NO_PULL[r.stuck] then return false end
  return any_linked(r)
end

-- every linked lever tile of the bridges gate holds (manifest ones and the unmanaged ones in hand), sorted
local function lever_tiles()
  local seen, list = {}, {}
  for _, r in pairs(rt) do
    for _, lid in ipairs(r.levers) do
      local p = r.pos[lid]
      if r.linked[lid] and type(p) == 'table' and p[1] and p[2] and p[3] then
        local k = p[1] .. ',' .. p[2] .. ',' .. p[3]
        if not seen[k] then seen[k], list[#list + 1] = true, {p[1], p[2], p[3]} end
      end
    end
  end
  table.sort(list, function(a, b)
    if a[3] ~= b[3] then return a[3] < b[3] end
    if a[2] ~= b[2] then return a[2] < b[2] end
    return a[1] < b[1]
  end)
  while #list > M.LEVER_TILES do list[#list] = nil end
  return list
end

-- BUG-027 lever burrow check (Run 10 y419: BREACH 'O1 not up at T+900' with the enemy far away; then GATE_FAIL "B1 not
-- up ... no worker: its levers lie outside the alert burrow" although its levers lie in Kern+: in BREACH the alert holds
-- the civilians in the refuge Tiefe+, and the lever burrow was never listed in BREACH, so nobody could pull a Kern+
-- lever). In BREACH the lever burrow is listed only while no visible hostile is inside Kern+ and none is within
-- LEVER_SAFE tiles of any linked lever of a bridge still to pull (a confined civilian walks from the refuge to the
-- lever and back); with a hostile inside or near, the old rule holds (attacker-side levers are not used).
M.LEVER_SAFE = 20
local function breach_safe(K, bs)
  local h = K.census.h
  if type(h) ~= 'table' or K.now().tick - (h.tick or -1e9) > 200 or (h.inside or 0) > 0 then return false end
  for name, r in pairs(rt) do
    if needs_pull(name) and not lever_in(r, bs) then
      for _, lid in ipairs(r.levers) do
        local p = r.pos[lid]
        if r.linked[lid] and type(p) == 'table' then
          for _, e in ipairs(type(h.list) == 'table' and h.list or {}) do
            if math.max(math.abs(e.x - p[1]), math.abs(e.y - p[2]), math.abs(e.z - p[3])) <= M.LEVER_SAFE then
              return false
            end
          end
        end
      end
    end
  end
  return true
end

-- Run 11 y432 winter (GATE_FAIL O1 'no_worker', lever 18664 pulled again and again, the same pull by hand taken at
-- once): the civ alert confines the civilians to the refuge in BREACH, in the deep defense (SIEGE_DEEP, BUG-030) and in
-- a lockdown whose seal pick was the refuge; there the lever burrow follows BREACH's safety rule (breach_safe)
local function refuge_level(K, mode, main)
  if mode == 'BREACH' then return true end
  local _, rn = core_burrows(K.manifest())
  return main ~= nil and main == rn
end

-- the lever burrow for siege's alert list in `mode`, or nil: only while a pull is pending on a bridge none of whose
-- linked levers lies on `main` (the alert's burrow) or one of `rooms`, or all of those failed this epoch (no worker
-- took them); seal paints the lever tiles (kept current: a new linked lever is added on the next ask) and answers its
-- name. While the alert confines to the refuge (BREACH, the deep defense, a lockdown) only while breach_safe (BUG-027).
local function lever_room(K, mode, main, rooms)
  local bs = {}
  for _, n in ipairs(rooms) do bs[#bs + 1] = burrow(n) end
  local mb = burrow(main)
  if mb then bs[#bs + 1] = mb end
  local need = false
  for name, r in pairs(rt) do
    if needs_pull(name) and not lever_in(r, bs, true) then need = true; break end
  end
  if not need then return nil end
  if refuge_level(K, mode, main) and not breach_safe(K, bs) then return nil end
  local ok, n = K.call('seal', 'lever_burrow', lever_tiles())
  if ok and type(n) == 'string' and n ~= '' then
    lb_name = n
    return n
  end
end

-- lever order for a pull: 0 = in an allowed room with a puller present, 1 = on a tile of the burrow the civ alert
-- holds the civilians in (BREACH: the refuge if it exists, as siege; else the burrows of the sounding alert, siege's
-- list; else Kern+), 2 = in another allowed room, 3 = the rest; manifest order inside a class (live L3: in BREACH the
-- levers in Kern+ had no worker, GATE_FAIL no_worker x3). In BREACH a linked refuge lever thus comes before the B2
-- landing; Run 11 y432 winter: in the deep defense (the alert in the refuge, mode SIEGE) the Kern+ levers came first
-- and no confined civilian could take them
local function order(K, r, cand, now)
  local mode = K.mode()
  local kn, rn = core_burrows(K.manifest())
  local homes = mode == 'BREACH' and burrow(rn) and {burrow(rn)} or alert_burrows(K)
  if not homes or #homes == 0 then homes = {burrow(kn)} end
  local rooms, pres = {}, {}
  for _, rm in ipairs(room_list(K, now)) do
    if allowed(K, rm, mode) then rooms[#rooms + 1] = {rm = rm, b = burrow(rm.name)} end
  end
  local function class(lid)
    local p = r.pos[lid]
    if type(p) ~= 'table' then return 3 end
    local room
    for _, e in ipairs(rooms) do
      if on_tile(e.b, p[1], p[2], p[3]) then room = e.rm; break end
    end
    if room then
      if pres[room.name] == nil then pres[room.name] = present(room) end
      if pres[room.name] > 0 then return 0 end
    end
    for _, b in ipairs(homes) do if on_tile(b, p[1], p[2], p[3]) then return 1 end end
    return room and 2 or 3
  end
  local cls, idx = {}, {}
  for i, lid in ipairs(cand) do cls[lid], idx[lid] = class(lid), i end
  table.sort(cand, function(a, b) if cls[a] ~= cls[b] then return cls[a] < cls[b] end return idx[a] < idx[b] end)
end

-- linked lever to pull next: first one that has not failed in this epoch, rotating after failures;
-- the link is re-checked right before the pull (a lever may have been unlinked or removed)
local function pick(K, r, now)
  local cand, parked = {}, 0
  if r.park and r.pm ~= K.mode() then r.park, r.ne = nil, nil end      -- BUG-068: a new mode, a new try
  for _, lid in ipairs(r.levers) do
    if r.linked[lid] then
      if r.park and (r.park[lid] or 0) > now then parked = parked + 1       -- BUG-068: parked, no effect
      else cand[#cand + 1] = lid end
    end
  end
  local n = #cand
  if n == 0 then return nil, parked > 0 and 'parked' or nil end
  if n > 1 then order(K, r, cand, now) end
  local start
  for i, lid in ipairs(cand) do if not r.bad[lid] then start = i; break end end
  if not start then
    r.bad, start = {}, 1
    for i, lid in ipairs(cand) do if lid == r.last_lever then start = i % n + 1 end end
  end
  for k = 0, n - 1 do
    local lid = cand[(start - 1 + k) % n + 1]
    if linked_now(r, lid) then return lid end
    r.linked[lid], r.resolved = false, nil     -- stale cache: resolve again on the next pass
  end
  return nil
end

local function grown(fp, m) return {fp[1] - m, fp[2] - m, fp[3], fp[4] + m, fp[5] + m, fp[6]} end

-- Chebyshev distance of a tile to a footprint box on its own z levels; nil on another z
local function fp_dist(fp, x, y, z)
  if type(x) ~= 'number' or z < fp[3] or z > fp[6] then return nil end
  local dx = x < fp[1] and fp[1] - x or (x > fp[4] and x - fp[4] or 0)
  local dy = y < fp[2] and fp[2] - y or (y > fp[5] and y - fp[5] or 0)
  return math.max(dx, dy)
end

-- BUG-027: the living units that are not hostile within `rad` tiles of a footprint (same z), by id only (CONTRACTS
-- §1.4): fort members from the census (citizens, residents, soldiers and recruits, children, babies (in arms: at
-- the mother's position, dfhack.units.getPosition), insane ones), the fort's tame
-- animals (census.a) and the friendly units sense lists near the footprints gate watches (census.h.friends).
-- {n, on, list = {{id, k, d, x, y, z}} sorted by distance (d = 0: on the footprint)}; nil while the census is unknown.
local function around(K, fp, rad)
  local cu = K.census.u
  if type(cu) ~= 'table' or type(cu.ids) ~= 'table' then return nil end
  local res, seen = {n = 0, on = 0, list = {}}, {}
  local isDead, getPos = dfhack.units.isDead, dfhack.units.getPosition
  local function add(id, k)
    if math.type(id) ~= 'integer' or seen[id] then return end
    seen[id] = true
    local u = df.unit.find(id)
    if not u or isDead(u) then return end
    local x, y, z = getPos(u)            -- a carried baby (or a caged unit) is where its carrier is, not at u.pos
    local d = fp_dist(fp, x, y, z)
    if not d or d > rad then return end
    if k == 'citizen' and u.military and u.military.squad_id >= 0 then k = 'soldier' end
    res.n = res.n + 1
    if d == 0 then res.on = res.on + 1 end
    res.list[#res.list + 1] = {id = id, k = k, d = d, x = x, y = y, z = z}
  end
  for _, id in ipairs(cu.ids) do add(id, 'citizen') end
  for _, id in ipairs(type(cu.insane_ids) == 'table' and cu.insane_ids or {}) do add(id, 'insane') end
  local h, a = K.census.h, K.census.a
  for _, e in ipairs(type(h) == 'table' and type(h.friends) == 'table' and h.friends or {}) do
    if type(e) == 'table' then add(e.id, type(e.k) == 'string' and e.k or 'visitor') end
  end
  for _, e in ipairs(type(a) == 'table' and type(a.list) == 'table' and a.list or {}) do
    if type(e) == 'table' then add(e.id, 'animal') end
  end
  table.sort(res.list, function(p, q) if p.d ~= q.d then return p.d < q.d end return p.id < q.id end)
  return res
end

-- the units of the last census pass (near = {t, list}) where they stand now (by id), as around() returns them
local function refresh(near, fp)
  local res = {n = 0, on = 0, list = {}}
  local isDead, getPos = dfhack.units.isDead, dfhack.units.getPosition
  for _, e in ipairs(near.list) do
    local u = df.unit.find(e.id)
    if u and not isDead(u) then
      local x, y, z = getPos(u)
      local d = fp_dist(fp, x, y, z)
      if d and d <= M.SCAN_R then
        res.n = res.n + 1
        if d == 0 then res.on = res.on + 1 end
        res.list[#res.list + 1] = {id = e.id, k = e.k, d = d, x = x, y = y, z = z}
      end
    end
  end
  table.sort(res.list, function(p, q) if p.d ~= q.d then return p.d < q.d end return p.id < q.id end)
  return res
end

-- the units of a scan (or a plain list of them) within `m` tiles of the footprint (the ones that hold a pull)
local function within(sc, m)
  local r = {}
  for _, e in ipairs(sc and (sc.list or sc) or {}) do if e.d <= m then r[#r + 1] = e end end
  return r
end

-- a soldier's squad and its station order (the squads screen): on the bridge (d 0), next to it (d <= MARGIN), his
-- squad's station a few tiles away while he stands at it (BUG-032: DF stands a squad's soldiers on the tiles around
-- its station point; siege has military re-station such a squad), or on the way through it
M.STATION_NEAR = 2          -- a soldier this close to his squad's station stands at it (military: spread + 1)
local function squad_note(id, fp, e)
  local ok, s = pcall(function()
    local u = df.unit.find(id)
    local sid = u and u.military.squad_id
    if math.type(sid) ~= 'integer' or sid < 0 then return nil end
    local sq = df.squad and df.squad.find(sid)
    if not sq then return 'squad ' .. sid end
    for _, o in ipairs(sq.orders) do
      local okp, x, y, z = pcall(function() return o.pos.x, o.pos.y, o.pos.z end)
      if okp and type(x) == 'number' and x >= 0 then
        local d = fp_dist(fp, x, y, z)
        if d == 0 then return string.format('squad %d stationed on the bridge at %d,%d,%d', sid, x, y, z) end
        if d and d <= M.MARGIN then
          return string.format('squad %d stationed next to the bridge at %d,%d,%d', sid, x, y, z)
        end
        if d and e and e.z == z and math.max(math.abs(e.x - x), math.abs(e.y - y)) <= M.STATION_NEAR then
          return string.format('squad %d stationed %d tiles from the bridge at %d,%d,%d', sid, d, x, y, z)
        end
        return string.format('squad %d on its way to its station %d,%d,%d', sid, x, y, z)
      end
    end
    return 'squad ' .. sid
  end)
  return ok and s or nil
end

-- "soldier 26535 on the footprint (squad 3 stationed on the bridge at ...), citizen 26099 next to it, +2 more"
local function who(list, fp)
  local parts = {}
  for i, e in ipairs(list) do
    if i > M.NAME_MAX then parts[#parts + 1] = string.format('+%d more', #list - M.NAME_MAX); break end
    local s = string.format('%s %d %s', e.k, e.id, e.d == 0 and 'on the footprint' or 'next to it')
    local q = e.k == 'soldier' and fp and squad_note(e.id, fp, e)
    parts[#parts + 1] = q and (s .. ' (' .. q .. ')') or s
  end
  return table.concat(parts, ', ')
end

local function ids_of(list)
  local r = {}
  for i, e in ipairs(list) do if i <= 20 then r[i] = e.id end end
  return r
end

-- config/reflex.json `gate` (BUG-027): {force_near = 0..30 tiles (0 = never raise onto a unit), manual = [bridge
-- name | building id]}; bad values fall back to the defaults (fail-open, `python -m dfpilot.lint --config` warns)
local function gcfg(K)
  local r = type(K.cfg.reflex) == 'table' and type(K.cfg.reflex.gate) == 'table' and K.cfg.reflex.gate or {}
  local fn = math.tointeger(r.force_near)
  if not fn or fn < 0 or fn > 30 then fn = M.FORCE_NEAR end
  return fn, type(r.manual) == 'table' and r.manual or {}
end

local function manual(K, name, bid)
  local _, list = gcfg(K)
  for _, v in ipairs(list) do
    if v == name or (bid ~= nil and math.tointeger(v) == bid) then return true end
  end
  return false
end

-- BUG-068: config/reflex.json gate.noeffect_max (1..20 pulls in a row without effect) and gate.noeffect_wait (100..24000
-- ticks of the first parking); bad values fall back to the defaults
function M.ne_cfg(K)
  local r = type(K.cfg.reflex) == 'table' and type(K.cfg.reflex.gate) == 'table' and K.cfg.reflex.gate or {}
  local n, w = math.tointeger(r.noeffect_max), math.tointeger(r.noeffect_wait)
  if not n or n < 1 or n > 20 then n = M.NE_MAX end
  if not w or w < 100 or w > 24000 then w = M.NE_WAIT end
  return n, w
end

-- BUG-068: a pull of lever `lid` left the queue and bridge `name` still stands in `s`. NE_MAX in a row park the lever
-- (NE_WAIT ticks, doubled per parking in a row up to NE_TIMES times), LEVER_NOEFFECT (B) once per lever (worker = how
-- many of those pulls a worker took: 0 means DF dropped every job unclaimed, e.g. no path to the lever)
function M.noeffect(K, name, r, lid, s, now, taken)
  local max, wait = M.ne_cfg(K)
  r.ne = r.ne or {}
  local e = r.ne[lid] or {n = 0, tot = 0, k = 0, w = 0}
  r.ne[lid] = e
  e.n, e.tot = e.n + 1, e.tot + 1
  if taken then e.w = e.w + 1 end                        -- pulls a worker took (else DF dropped the job unclaimed)
  if e.n < max then return end
  e.n, e.k = 0, math.min(e.k + 1, 30)
  if FAST_MODES[K.mode()] then wait = math.max(100, wait // 4) end        -- a fight: look again sooner
  local w = wait * math.min(1 << (e.k - 1), M.NE_TIMES)
  r.park = r.park or {}
  r.park[lid], r.pm = now + w, K.mode()
  st.ne = type(st.ne) == 'table' and st.ne or {}
  local key = tostring(lid)
  if CAD.due(st.ne[key], K.now(), {lid}, {}) then
    st.ne[key], dirty = CAD.mark(K.now(), {lid}, {}), true
    K.log('warn', 'gate: lever %d of %s pulled %d times without effect (bridge stays %s): no pull for %d ticks', lid, name,
          e.tot, s, w)
    K.emit('LEVER_NOEFFECT', 'B', string.format('lever %d of %s: %d pulls without effect, bridge stays %s; no pull for %d ticks',
                                                lid, name, e.tot, s, w),
           {bridge = name, lever = lid, pulls = e.tot, state = s, wait = w, worker = e.w})
  end
end

-- BUG-068: has any lever of the bridge been parked for no effect (a fail between two tries still says why)
function M.ne_any(r)
  for _, e in pairs(r.ne or {}) do if (e.k or 0) > 0 then return true end end
  return false
end

-- BUG-068: the lever moved its bridge: its record goes (the report may come again in a later episode)
function M.ne_clear(r, lid)
  if r.ne and r.ne[lid] then r.ne[lid] = nil end
  if r.park and r.park[lid] then r.park[lid] = nil end
  if st.ne and st.ne[tostring(lid)] then st.ne[tostring(lid)], dirty = CAD.quiet(st.ne[tostring(lid)]), true end
end

-- min Chebyshev distance of a listed visible hostile to a footprint (unmanaged bridges: sense only measures the
-- manifest ones); -1 none
local function list_dist(h, f)
  local best = -1
  for _, e in ipairs(type(h) == 'table' and h.list or {}) do
    local dx = e.x < f[1] and f[1] - e.x or (e.x > f[4] and e.x - f[4] or 0)
    local dy = e.y < f[2] and f[2] - e.y or (e.y > f[5] and e.y - f[5] or 0)
    local dz = e.z < f[3] and f[3] - e.z or (e.z > f[6] and e.z - f[6] or 0)
    local d = math.max(dx, dy, dz)
    if best < 0 or d < best then best = d end
  end
  return best
end

-- BUG-027: the distance of the nearest visible hostile to this bridge (sense's near_bridge for manifest bridges, else
-- the hostile list), -1 none or a stale census
local function hostile_dist(K, name, fp)
  local h = K.census.h
  if type(h) ~= 'table' or K.now().tick - (h.tick or -1e9) > 200 then return -1 end
  local d = type(h.near_bridge) == 'table' and h.near_bridge[name]
  if math.type(d) ~= 'integer' then d = list_dist(h, fp) end
  return d
end

-- BUG-027: who holds a pull of `name` toward `dir` now: {units within MARGIN} (empty = clear), and the force: a raise
-- in SIEGE/BREACH with a visible hostile within force_near tiles goes ahead anyway (returns the holders and the
-- hostile's distance). An unknown census (hold.unknown) holds every unforced pull.
local function holders(K, name, fp, sc, dir)
  local hold = within(sc, M.MARGIN)
  if dir == 'up' and FORCE_MODES[K.mode()] then
    local fn = gcfg(K)
    local d = fn > 0 and hostile_dist(K, name, fp) or -1
    if d >= 0 and d <= fn then return hold, d end
  end
  if not sc then hold.unknown = true end
  return hold, nil
end

-- the reasons siege lowers a manifest bridge in SIEGE (and BREACH for the rescue) and during a lockdown, by role:
-- BUG-028 rescue (inner/core), Gordon 2026-10-16 intake waves (outer to let a wave in, inner/core for the soldiers'
-- way to the killing field and back) and the approved sortie through O1 (outer, inner)
local SIEGE_DOWN = {rescue = {inner = true, core = true}, intake = {outer = true, inner = true, core = true},
                    sortie = {outer = true, inner = true}}
M.SIEGE_DOWN = SIEGE_DOWN

-- the airlock (Gordon 2026-10-16): an intake or sortie 'down' of an outer bridge needs every inner bridge up and wanted
-- up, of an inner one every outer bridge up and wanted up; never both sides open at once
local function airlock(K, name, role)
  local other = role == 'outer' and 'inner' or (role == 'inner' and 'outer') or nil
  if not other then return nil end
  local man = K.manifest()
  for _, n in ipairs(bridge_names(man)) do
    if man.bridges[n].role == other then
      local r, br = rt[n], st.br[n]
      if not (r and r.last == 'up') then return string.format('down refused: %s is not up (airlock)', n) end
      if br and br.want == 'down' then return string.format('down refused: %s is wanted down (airlock)', n) end
    end
  end
  return nil
end

local function down_guard(K, name, why)
  local m = K.mode()
  -- BUG-028: siege's rescue (citizens without drink or food behind our raised gates, the outside sealed) lowers an
  -- inner or core manifest bridge in these modes and during a lockdown; the hostile guard below still holds.
  -- Intake waves and the sortie (siege, SIEGE only): their own hostile checks replace the 30-tile guard (a wave is let
  -- in with the army at the gate); the airlock holds
  local br = st.br[name]
  local spec = (K.manifest().bridges or {})[name]
  local w = why or (br and br.want == 'down' and br.why) or nil
  local roles = SIEGE_DOWN[w]
  local role = type(spec) == 'table' and spec.role or nil
  local own = roles ~= nil and role ~= nil and roles[role] == true and (w == 'rescue' or m == 'SIEGE')
  if FAST_MODES[m] and not own then return 'down refused in ' .. m end
  if lock_why(K) and not own then return 'down refused: lockdown' end
  if own and w ~= 'rescue' then return airlock(K, name, role) end
  local h = K.census.h
  local d = type(h) == 'table' and type(h.near_bridge) == 'table' and h.near_bridge[name]
  if d == nil and rt[name] and rt[name].fp then d = list_dist(h, rt[name].fp) end
  if d and d >= 0 and d <= M.DOWN_GUARD then return 'down refused: hostile within ' .. M.DOWN_GUARD .. ' tiles' end
  return nil
end

-- our pull left the queue and the bridge moved: how long the job waited for its worker (live L3 KPI)
local function note_take(K, name, job, now)
  local t = (job.taken or now) - job.queued
  local by = job.wid and puller_room(job.wid)
  st.kpi.take[name] = t
  if by then st.kpi.pp = (st.kpi.pp or 0) + 1 end
  dirty = true
  K.log('info', 'gate: %s pull taken %d ticks after queueing%s', name, t, by and (' by a puller of ' .. by) or '')
end

local function unit_id(w)
  local ok, id = pcall(function() return w.id end)
  return ok and math.type(id) == 'integer' and id or nil
end

---------------------------------------------------------------- desired state
-- a new want starts a new epoch (deadline, failure flag, lever rotation); same want keeps it
local function set_want(name, w, why, deadline, now)
  if st.gone[name] then return false end        -- BUG-030: a destroyed bridge takes no want
  local br = st.br[name]
  if br and br.want == w then
    if deadline and br.deadline == nil then br.deadline, dirty = deadline, true end
    return false
  end
  st.br[name] = {want = w, why = tostring(why or ''):sub(1, 40), since = now,
                 deadline = w == 'up' and (deadline or now + M.DEADLINE) or nil, failed = false}
  local r = runtime(name)
  r.bad, r.nw, r.block_since, r.lat0, r.nw_out = {}, 0, nil, nil, nil
  r.block, r.block_ev, r.hold_log, r.forced_ev, r.hold_seen = nil, nil, nil, nil, nil
  r.held_sum, r.fail_at, r.switch, r.want_ms = nil, nil, nil, nil
  dirty = true
  return true
end

-- BUG-027 lever burrow check: a mode change renews an 'up' epoch without set_want; the failures of the old epoch (the
-- no-worker cancels and whether the alert kept everybody away then, the levers marked bad, the deadline allowance) must
-- not decide the new one's GATE_FAIL (a SIEGE no-worker cancel made a BREACH fail read outside_alert)
local function new_epoch(r)
  r.nw, r.nw_out, r.bad, r.fail_at, r.switch, r.held_sum, r.block_since = 0, nil, {}, nil, nil, nil, nil
end

-- BUG-027: the ticks this epoch waited for units on the footprint (they do not count toward the deadline)
local function held_ticks(r, now) return (r.held_sum or 0) + (r.block_since and math.max(0, now - r.block_since) or 0) end
local function unblock(r, now)
  if r.block_since then r.held_sum = held_ticks(r, now) end
  r.block_since, r.block = nil, nil
end
local function allow() return math.max(M.PULL_ALLOW, st.lat and st.lat.t or 0) end

-- BUG-027: units seen near the footprint while the bridge is pulled or moves, the closest sighting per unit
local function mv_note(m, list, now)
  for _, e in ipairs(list or {}) do
    local i = m.by[e.id]
    if not i and #m.seen < M.SEEN_MAX then
      m.seen[#m.seen + 1] = {id = e.id, k = e.k, d = e.d, x = e.x, y = e.y, z = e.z, t = now}
      m.by[e.id] = #m.seen
    elseif i and e.d < m.seen[i].d then
      m.seen[i] = {id = e.id, k = e.k, d = e.d, x = e.x, y = e.y, z = e.z, t = now}
    end
  end
end

local function mv_prune(now)
  local keep = {}
  for _, m in ipairs(mvl.list) do
    if now - (m.t1 or now) <= M.MOVES_KEEP then keep[#keep + 1] = m end
  end
  while #keep > M.MOVES_MAX do table.remove(keep, 1) end
  mvl.list = keep
end

-- a bridge left its settled state (or flipped between two passes): open a move record seeded with the units the last
-- scan saw near the footprint (the pull was done then)
local function mv_open(K, name, r, s, now, fp, prev, cur)
  local to = s == 'moving' and (r.settled == 'up' and 'down' or 'up') or s
  local m = {t = now, b = name, bid = r.bid, fp = fp and {fp[1], fp[2], fp[3], fp[4], fp[5], fp[6]} or nil, to = to,
             pull = r.job and r.job.queued or -1, lever = r.job and r.job.lever or -1, seen = {}, by = {}}
  if prev and now - prev.t <= 2 * M.FAST then mv_note(m, prev.list, prev.t) end
  if cur then mv_note(m, cur.list, now) end
  mvl.list[#mvl.list + 1] = m
  mv_prune(now)
  if s == 'moving' then r.mv = m else m.t1 = now end
  return m
end

local function observe(K, name, r, s, now, fp, prev, cur)
  if s == r.last then return end
  local m
  if (s == 'moving' or ((s == 'up' or s == 'down') and (r.last == 'up' or r.last == 'down'))) and not r.mv then
    m = mv_open(K, name, r, s, now, fp or r.foot, prev, cur)
  elseif r.mv and s ~= 'moving' then
    r.mv.t1, r.mv = now, nil
  end
  if r.last ~= nil then
    local d = {bridge = name, state = s}
    local near = m and within(m.seen, M.MARGIN)
    if near and #near > 0 then                        -- BUG-027: it moves with units on or next to it
      d.units = ids_of(near)
      K.log('warn', 'gate: %s moving %s with %s', name, m.to, who(near, m.fp))
    end
    K.emit('GATE', 'C', name .. ' ' .. s, d)
  end
  r.last = s
  if s == 'moving' or s == 'unknown' then return end
  local br = st.br[name]
  -- double toggle: the bridge reached the wanted state in this epoch and left it again
  if br and br.want and r.settled == br.want and s ~= br.want and (r.settled_at or -1) >= br.since then
    st.kpi.dbl = st.kpi.dbl + 1
    dirty = true
    K.log('warn', 'gate: double toggle on %s (wanted %s)', name, br.want)
  end
  if s == 'up' and r.settled ~= nil and r.settled ~= 'up' then
    st.kpi.raise[name] = now - st.kpi.t0
    dirty = true
  end
  -- FR-55 lever latency: our queued pull -> the bridge in the state it was pulled for
  local l0 = r.lat0
  if l0 and s == l0.want then
    local ms = K.now().ms - l0.ms
    st.lat = {s = (ms + 500) // 1000, t = now - l0.tick}
    r.lat0, dirty = nil, true
    K.log('info', 'gate: %s %s %d ticks (%d s) after the pull was queued', name, s, st.lat.t, st.lat.s)
  end
  if br and s == br.want then r.bad = {} end
  r.settled, r.settled_at = s, now
end

local function cut(s, n)
  s = tostring(s or '')
  return #s <= n and s or s:sub(1, n)
end

-- BUG-027: the bridge waits for the units that hold it: one GATE (C) per epoch naming them, then a kern.log line when a
-- unit not named yet in this epoch holds it (news only, at most every HOLD_LOG ticks: a corridor sees passers-by)
local function note_hold(K, name, fp, w, hold, now)
  local r = runtime(name)
  r.block = hold
  local txt = who(hold, fp)
  if not r.block_ev then
    r.block_ev, r.hold_seen, r.hold_log = true, {}, now
    for _, e in ipairs(hold) do r.hold_seen[e.id] = true end
    K.emit('GATE', 'C', cut(name .. ' ' .. w .. ' waits: ' .. txt, 200),
           {bridge = name, state = 'blocked', units = ids_of(hold)})
    K.log(FORCE_MODES[K.mode()] and 'warn' or 'info', 'gate: %s %s waits for %s', name, w, txt)
    return
  end
  local seen, news = r.hold_seen or {}, false
  for _, e in ipairs(hold) do if not seen[e.id] then news = true end end
  if news and now - (r.hold_log or -M.HOLD_LOG) >= M.HOLD_LOG then
    for _, e in ipairs(hold) do seen[e.id] = true end
    r.hold_seen, r.hold_log = seen, now
    K.log('info', 'gate: %s %s still waits for %s', name, w, txt)
  end
end

-- BUG-027: a raise forced by a hostile at the gate goes ahead with units on or next to the footprint: GATE_FORCED (A)
-- names them, once per pull
local function forced_event(K, name, fp, hold, hd, job)
  local r = runtime(name)
  if #hold == 0 or r.forced_ev == job then return end
  r.forced_ev = job
  local txt = string.format('%s raised onto %s: a hostile %d tiles from it (force_near %d)', name, who(hold, fp), hd,
                            (gcfg(K)))
  K.emit('GATE_FORCED', 'A', cut(txt, 200), {bridge = name, units = ids_of(hold), hostile = hd,
                                             pos = {hold[1].x, hold[1].y, hold[1].z}, job = job})
  K.log('warn', 'gate: %s', txt)
end

-- BUG-030: a building whose build stage cannot be read counts as complete (fail-open: the test worlds have none)
local function complete(b)
  local ok, r = pcall(function() return b:getBuildStage() >= b:getMaxBuildStage() end)
  return not ok or r == true
end

-- loss history: the building's construction items (use_mode 2, the building's item list in the UI): their count and
-- the first one's material and item type ('granite blocks'); nil, nil when DF does not say
local function bridge_items(b)
  local okn, n = pcall(function()
    local c = 0
    for _, ci in ipairs(b.contained_items) do if ci.use_mode == 2 then c = c + 1 end end
    return c
  end)
  if not okn or math.type(n) ~= 'integer' then return nil, nil end
  local okm, mat = pcall(function()
    for _, ci in ipairs(b.contained_items) do
      if ci.use_mode == 2 then
        local mi = dfhack.matinfo.decode(ci.item)
        local ty = df.item_type[ci.item:getType()]
        return string.format('%s %s', mi and mi:toString() or '?', tostring(ty or '?'):lower())
      end
    end
  end)
  return n, okm and type(mat) == 'string' and mat:sub(1, 40) or nil
end

-- BUG-048: the quickfort key of a bridge's raise direction (build.lua: ga left, gd right, gw up, gx down, gs
-- retracting), read from the building when gate first sees it complete; nil when DF does not say (seal then takes the
-- key fortcore builds, gw)
local DIR_KEY = {Left = 'ga', Right = 'gd', Up = 'gw', Down = 'gx', Retracting = 'gs'}
local function bridge_key(b)
  local ok, v = pcall(function()
    local d = b.direction
    if math.type(d) == 'integer' then
      local e = df.building_bridgest and df.building_bridgest.T_direction
      d = e and e[d] or d
    end
    return d
  end)
  return ok and DIR_KEY[tostring(v)] or nil
end

-- loss history: the races of the building destroyers in sight now (census.h.list entries with bd = 1), sorted
local function destroyer_races(h)
  local seen, races = {}, {}
  for _, e in ipairs(type(h) == 'table' and type(h.list) == 'table' and h.list or {}) do
    if type(e) == 'table' and e.bd == 1 then
      local ok, race = pcall(function() return dfhack.units.getRaceName(df.unit.find(e.id)) end)
      race = ok and type(race) == 'string' and race ~= '' and race:sub(1, 24) or '?'
      if not seen[race] and #races < M.LOST_RACES then seen[race], races[#races + 1] = true, race end
    end
  end
  table.sort(races)
  return races
end

-- loss history: note building destroyers in sight (each pass; their races at most once per SLOW ticks)
local function note_destroyers(K, now)
  local h = K.census.h
  local n = type(h) == 'table' and math.tointeger(h.bd) or nil
  if not n or n <= 0 then return false end
  if bds and now - bds.t < M.SLOW and #bds.races > 0 then bds.t = now
  else bds = {t = now, races = destroyer_races(h)} end
  return true
end

-- loss history: manifest bridge `name` (last seen as `seen`) was found destroyed now; returns its record
local function lose(K, name, seen, now, mode)
  local L = st.lost[name]
  if not L then
    L = {n = 0, bd = 0, reb = 0, it = 0, lk = 0, races = {}, ev = {}}
    st.lost[name] = L
  end
  local by = note_destroyers(K, now) or (bds ~= nil and now - bds.t <= M.LOST_BD)
  L.n = L.n + 1
  if by then
    L.bd = L.bd + 1
    local have = {}
    for _, r in ipairs(L.races) do have[r] = true end
    for _, r in ipairs(bds and bds.races or {}) do
      if not have[r] and #L.races < M.LOST_RACES then have[r], L.races[#L.races + 1] = true, r end
    end
    table.sort(L.races)
  end
  L.it = L.it + (seen.it or 0)
  if seen.mat then L.mat = seen.mat end
  L.ev[#L.ev + 1] = {t = now, y = K.now().year or 0, m = mode, bd = by and 1 or 0}
  while #L.ev > M.LOST_EV do table.remove(L.ev, 1) end
  return L, by
end

-- BUG-030: is manifest bridge `name` destroyed? It is when gate saw a complete bridge on this footprint (st.seen) and
-- now no bridge stands there (the cached building is gone and a fresh resolve finds none). The first time:
-- BRIDGE_DESTROYED (A); its want, our pull and its move record are dropped. A complete bridge on the footprint again
-- ends it (GATE C 'rebuilt'). Unmanaged bridges are left to extras_pass (forgotten when their levers lose them).
local function gone_check(K, name, r, spec, now)
  if spec.role == 'extra' then return false end
  if r.fps_src ~= spec.fp then r.fps_src, r.fps = spec.fp, table.concat(spec.fp, ',') end
  local sig = r.fps
  local seen = st.seen[name]
  if seen and seen.fp ~= sig then                 -- the manifest moved the bridge: a new footprint, a new record
    st.seen[name], st.gone[name], st.lost[name], seen, dirty = nil, nil, nil, nil, true
  end
  if r.bid and not df.building.find(r.bid) then   -- the cached building vanished: look at the footprint now
    r.resolved = nil
    resolve(r, spec, now, true)
  end
  if r.bid then
    if seen and seen.bid == r.bid and not st.gone[name] then return false end    -- it stands (one lookup)
    local b = df.building.find(r.bid)
    local done = b ~= nil and complete(b)
    if done and not (seen and seen.bid == r.bid) then
      local it, mat = bridge_items(b)
      st.seen[name], dirty = {bid = r.bid, fp = sig, it = it, mat = mat, key = bridge_key(b)}, true
    end
    if st.gone[name] then
      if not done then return true end            -- a new one is being built: still no barrier
      st.gone[name], r.gone_next, dirty = nil, nil, true
      local L = st.lost[name]
      if L then L.reb = L.reb + 1 end
      K.emit('GATE', 'C', name .. ' rebuilt', {bridge = name, state = 'rebuilt'})
      K.log('info', 'gate: %s rebuilt (building %d, %d losses so far)', name, r.bid, L and L.n or 0)
    end
    return false
  end
  if st.gone[name] then return true end
  if not seen then return false end               -- never seen complete: not built yet ('unknown' as before)
  local last = r.last or 'unknown'
  if r.job then K.act.cancel_own_lever_job(r.job.id); r.job = nil end
  if r.mv then r.mv.t1, r.mv = now, nil end
  unblock(r, now)
  r.block_ev, r.stuck, r.near, r.last, r.gone_next = nil, nil, nil, 'destroyed', now + M.GONE_RECHECK
  st.gone[name], st.br[name], dirty = {t = now, bid = seen.bid, last = last}, nil, true
  local c = geom.bbox_center(spec.fp)
  local mode = K.mode()
  local L, by = lose(K, name, seen, now, mode)
  -- BUG-064 (Run 13 note 55/43: bridges vanished in PEACE with '0 building destroyers'; DF's reports said "toppled by
  -- <dwarf>"): the stressed citizen or ghost care saw topple something near the footprint, with his stress
  local okt, tp = K.call('care', 'toppled', c.x, c.y, c.z)
  tp = okt and type(tp) == 'table' and tp.by and tp or nil
  local txt = string.format('%s destroyed%s: no bridge on its footprint at %d,%d,%d any more (building %d, last %s, %s); '
                            .. 'no pulls for it, an open way until it is rebuilt; lost %dx, %d with building '
                            .. 'destroyers in sight%s', name,
                            tp and string.format(' (toppled by %s%s%s)', tp.by, tp.ghost == 1 and ', a ghost' or '',
                                                 tp.cat and (', stress category ' .. tp.cat) or '') or '',
                            c.x, c.y, c.z, seen.bid, last, mode, L.n, L.bd,
                            by and #L.races > 0 and (' (' .. table.concat(L.races, ',') .. ')') or '')
  K.emit('BRIDGE_DESTROYED', 'A', cut(txt, 200), {bridge = name, bid = seen.bid, role = tostring(spec.role or ''),
                                                  last = last, mode = mode, pos = {c.x, c.y, c.z}, n = L.n, bd = L.bd,
                                                  destroyers = by and 1 or 0, races = L.races,
                                                  tby = tp and tp.by or nil, tunit = tp and tp.unit >= 0 and tp.unit or nil,
                                                  tcat = tp and tp.cat or nil, tghost = tp and tp.ghost == 1 and 1 or nil})
  K.log('warn', 'gate: %s', txt)
  return true
end

-- BUG-048: a destroyed bridge seal replaced by a wall and a door reads 'replaced' (no gate, no open way), else 'destroyed'
local function gone_name(K, name)
  local ok, rep = K.call('seal', 'replaced')
  return (ok and type(rep) == 'table' and rep[name] ~= nil) and 'replaced' or 'destroyed'
end

-- one controller pass for one bridge; returns the observed state
local function control(K, name, spec, now)
  local r = runtime(name)
  -- BUG-030: a destroyed bridge gets no pull; its footprint is looked at again once a game day
  if st.gone[name] then
    if r.gone_next and now < r.gone_next and r.gone_next - now <= M.GONE_RECHECK then return gone_name(K, name) end
    r.gone_next, r.resolved = now + M.GONE_RECHECK, nil
  end
  local br = st.br[name]
  local w = br and br.want
  resolve(r, spec, now, w ~= nil and w ~= r.last)
  if gone_check(K, name, r, spec, now) then return gone_name(K, name) end
  local s = read(r)
  r.foot, r.spec, r.stuck = spec.fp, spec, nil
  if w ~= nil and w ~= s and not r.want_ms then r.want_ms = K.now().ms end      -- GATE_FAIL names real seconds
  -- BUG-027: who is on or near the footprint, only while the bridge has work: a census pass every FAST ticks, the
  -- positions of the units it found near in the frames between
  local sc
  local prev = r.near
  if r.job or (w ~= nil and w ~= s) or s == 'moving' then
    if r.near and now >= r.near.t and now - r.near.t < M.FAST then sc = refresh(r.near, spec.fp)
    else
      sc = around(K, spec.fp, M.SCAN_R)
      r.near = sc and {t = now, list = sc.list} or nil
    end
  else r.near = nil end
  if r.nec and now >= r.nec.at then                  -- BUG-068: did the pull move the bridge?
    local x = r.nec
    r.nec = nil
    if s == x.before then M.noeffect(K, name, r, x.lid, s, now, x.taken) else M.ne_clear(r, x.lid) end
  end
  observe(K, name, r, s, now, spec.fp, prev, sc)
  if r.mv and sc then mv_note(r.mv, sc.list, now) end       -- who stands near it while it moves
  -- 1. our own queued pull
  if r.job then
    local lv = df.building.find(r.job.lever)
    local j = lv and job_on(lv, r.job.id)
    if not j then                                     -- done, or dropped by DF
      if s == r.job.before then r.bad[r.job.lever] = true
      else
        note_take(K, name, r.job, now)
        M.ne_clear(r, r.job.lever)
      end
      -- BUG-068: judged after SETTLE ticks (the top of a pass): the bridge may start to move a moment after the job left
      r.nec = {lid = r.job.lever, before = r.job.before, taken = r.job.taken ~= nil, at = now + M.SETTLE}
      r.job, r.settle = nil, now + M.SETTLE
    else
      local w0 = worker(j)
      if w0 and not r.job.taken then r.job.taken, r.job.wid = now, unit_id(w0) end
      local dir = r.job.before == 'up' and 'down' or 'up'
      -- stale: the want changed, lowering became unsafe, or the bridge moved without us (our
      -- pull would now toggle it back)
      local stale = (w ~= nil and w ~= dir) or (dir == 'down' and down_guard(K, name) ~= nil)
                    or s ~= r.job.before
      -- BUG-027 (Run 10: the old rule kept a SIEGE raise pending while a miner and a recruit walked onto B1): the
      -- lever moves the bridge when the puller finishes the job, so a unit on or next to the footprint cancels our
      -- pending pull in every mode and both ways (live L4: the margin); only a forced raise goes on (GATE_FORCED)
      if not stale then
        local hold, hd = holders(K, name, spec.fp, sc, dir)
        if hd then forced_event(K, name, spec.fp, hold, hd, r.job.id)
        elseif #hold > 0 then
          stale = 'blocked'
          r.block_since = r.block_since or now
          note_hold(K, name, spec.fp, dir, hold, now)
        end
      end
      -- BUG-027: the deadline passed with this pull under way: once to another linked lever (check_fail asks)
      if not stale and r.switch then stale = 'switch' end
      -- Run 11 y432 winter: our pull waits for a worker on a lever outside the burrows the sounding civ alert holds the
      -- civilians in (queued before the alert sounded, or the alert moved to the refuge) while another linked lever
      -- lies inside: that one at once, not after NO_WORKER ticks of nobody
      if not stale and not w0 and (r.job.ock == nil or now - r.job.ock >= M.FAST) then
        r.job.ock = now
        local bs = alert_burrows(K)
        if bs and not at_in(r, r.job.lever, bs) and lever_in(r, bs, true) then stale = 'outside' end
      end
      local has_worker = w0 ~= nil
      if not stale then
        if has_worker then r.job.nw = nil
        else
          r.job.nw = r.job.nw or now
          if now - r.job.nw >= M.NO_WORKER then stale = 'no_worker' end
        end
      end
      if not stale then
        r.stuck = (not has_worker) and 'no_worker' or nil
        return s
      end
      local ok = K.act.cancel_own_lever_job(r.job.id)       -- UI: cancel the queued pull
      st.kpi.cancels, dirty = st.kpi.cancels + 1, true
      if stale == 'no_worker' then
        r.bad[r.job.lever] = true; r.nw = r.nw + 1
        local bs = alert_burrows(K)                     -- BUG-013: was the alert keeping everybody away from it?
        r.nw_out = bs ~= nil and not lever_in(r, bs)
      elseif stale == 'switch' then
        r.bad[r.job.lever], r.switch = true, nil
        K.log('info', 'gate: %s pull on lever %d not done by the deadline, trying another lever', name, r.job.lever)
      elseif stale == 'outside' then
        K.log('info', 'gate: %s pull on lever %d lies outside the alert burrows, a lever inside them instead', name,
              r.job.lever)
      end
      r.job = nil
      if not ok then r.settle = now + M.SETTLE; return s end -- it may be completing right now
    end
  end
  -- 2. the invariant: never a second pending pull on any lever of this bridge
  local fj = pending(r)
  if fj then
    r.stuck = worker(fj) and 'pending' or 'no_worker'
    return s
  end
  if w == nil or w == s then
    unblock(r, now); r.block_ev = nil
    if r.ne or r.park then for _, lid in ipairs(r.levers) do M.ne_clear(r, lid) end; r.ne, r.park = nil, nil end   -- BUG-068
    r.nec = nil
    return s
  end
  if s == 'unknown' then r.stuck = 'no_lever'; return s end
  if s == 'moving' or now < (r.settle or 0) then return s end
  if w == 'down' and down_guard(K, name) then r.stuck = 'guard'; return s end
  -- BUG-027 stop-gap: a bridge in gate.manual gets no automatic pull (the inbox `lever` still pulls it)
  if manual(K, name, r.bid) and not tostring(br.why or ''):find('^lever:') then r.stuck = 'manual'; return s end
  -- (4) footprint (BUG-027): raising flings, lowering crushes. Both wait, as long as it takes, for every unit that is
  -- not hostile on or next to the footprint (an unknown census too); a raise in SIEGE/BREACH goes ahead only with a
  -- visible hostile within force_near tiles of it (never because the wait was long)
  local hold, hd = holders(K, name, spec.fp, sc, w)
  -- no census yet (the first frame after a boot): wait silently, the pull is still to do (reflex's alert waits for it)
  if not hd and hold.unknown then r.stuck = 'census'; return s end
  if not hd and #hold > 0 then
    r.block_since = r.block_since or now
    note_hold(K, name, spec.fp, w, hold, now)
    r.stuck = 'blocked'
    return s
  end
  unblock(r, now)
  local lid, why = pick(K, r, now)
  if not lid then
    if why == 'parked' then r.stuck = 'no_effect'; return s end      -- BUG-068: every linked lever is parked
    r.stuck, r.resolved = 'no_lever', nil
    return s
  end
  r.last_lever = lid
  local ok, job = K.act.pull(lid)
  if not ok then                                   -- 'no building', 'not a lever', ...: resolve again
    r.bad[lid], r.stuck, r.resolved = true, 'no_lever', nil
    return s
  end
  r.job = {id = job, lever = lid, queued = now, before = s, qms = K.now().ms}
  if not (r.lat0 and r.lat0.want == w) then r.lat0 = {tick = now, ms = K.now().ms, want = w} end
  st.kpi.pulls, dirty = st.kpi.pulls + 1, true
  K.emit('LEVER', 'C', 'pull ' .. name .. ' ' .. w, {bridge = name, lever = lid, job = job})
  if hd then forced_event(K, name, spec.fp, hold, hd, job) end
  return s
end

---------------------------------------------------------------- linking (S3, live L2)
-- A manifest lever that is built but not linked to its built bridge gets one link job (act.link_lever = the
-- lever sheet's "link up" with two mechanisms). One pending link job per lever; a refused attempt (usually
-- no free mechanism) is retried after LINK_RETRY, doubling per refusal up to LINK_RETRY_MAX (live L2: a fort
-- without stone refused every day, 50 ACT_FAIL), and the bridge's other levers wait for that retry too
-- (they would need the same mechanisms). Not in SIEGE/BREACH/DRILL: a mechanic must not walk out then.
M.LINK_RETRY, M.LINK_RETRY_MAX = 1200, 9600
local LINK_MODES = {PEACE = true, ALERT = true, RECOVERY = true}
local LINK

local function built(b)
  local ok, r = pcall(function() return b:getBuildStage() >= b:getMaxBuildStage() end)
  return ok and r == true
end

local function link_pending(lv)
  LINK = LINK or (df.job_type and df.job_type.LinkBuildingToTrigger)
  for _, j in ipairs(lv.jobs) do if j.job_type == LINK then return j end end
end

local function links(K, name, spec, r, now)
  if not LINK_MODES[K.mode()] or now < (r.link_at or 0) then return end
  local b = r.bid and df.building.find(r.bid)
  if not b or not built(b) then return end
  for _, p in ipairs(spec.levers or {}) do
    local lv = find_at(p)
    if lv and is_lever(lv) and built(lv) and not link_pending(lv) then
      local t = targets(lv)
      if t and not t[b.id] then
        local ok, res = K.act.link_lever(lv.id, b.id)
        if not ok then
          r.link_wait = math.min(M.LINK_RETRY_MAX, r.link_wait and r.link_wait * 2 or M.LINK_RETRY)
          r.link_at = now + r.link_wait
          return
        end
        r.link_wait = nil
        if math.type(res) == 'integer' then
          st.kpi.links, dirty = (st.kpi.links or 0) + 1, true
          local L = st.lost[name]                   -- loss history: a link for a rebuilt bridge (mechanisms)
          if L then L.lk = L.lk + 1 end
          K.emit('LEVER', 'C', 'link ' .. name, {bridge = name, lever = lv.id, job = res})
        end
        r.resolved = nil                          -- re-read the links on the next pass
      end
    end
  end
end

local function check_fail(K, name, now, mode)
  local br = st.br[name]
  if not (br and br.want == 'up' and not br.failed and br.deadline and now >= br.deadline) then return end
  local r = runtime(name)
  if r.last == 'up' then return end
  local slow
  if r.stuck == 'blocked' and r.block_since then
    -- BUG-027: waiting for units on the footprint is no timeout: GATE_FAIL blocked after DEADLINE ticks of it on end
    if now - r.block_since < M.DEADLINE then return end
  else
    if now < br.deadline + held_ticks(r, now) then return end
    -- a pull under way at the deadline: once to another linked lever, then allow() ticks more (GATE_FAIL slow)
    if r.last == 'moving' or (r.job and r.job.taken) or r.fail_at then
      if not r.fail_at then
        local n = 0
        for _, lid in ipairs(r.levers) do if r.linked[lid] then n = n + 1 end end
        r.fail_at, r.switch = now + allow(), r.job ~= nil and r.last ~= 'moving' and n > 1
        K.log('info', 'gate: %s not up at its deadline, pull under way%s; %d ticks more', name,
              r.switch and ', another lever next' or '', allow())
      end
      if now < r.fail_at then return end
      slow = true
    end
  end
  br.failed, dirty = true, true
  local why = FAIL_WHY[r.stuck] or (slow and FAIL_WHY.slow) or (M.ne_any(r) and FAIL_WHY.no_effect) or
              (r.nw > 0 and 'no_worker') or 'timeout'
  if why == 'no_worker' then                          -- BUG-013: nobody may take it while the alert sounds
    local out = r.nw_out                              -- seen at a no-worker cancel; else now, in a step only (a
    if out == nil and mode == nil then                -- mode change has just moved the alert to another burrow)
      local bs = alert_burrows(K)
      out = bs ~= nil and not lever_in(r, bs)
    end
    if out then why = FAIL_WHY.outside end
  end
  local f = st.kpi.fails
  if #f < 8 then f[#f + 1] = name .. ':' .. why end
  if (mode or K.mode()) == 'DRILL' then return end    -- a drill reports through drill.kpi, not A events
  if r.fail_tick and now - r.fail_tick < M.FAIL_REPEAT then return end
  r.fail_tick = now
  local txt = why
  if why == FAIL_WHY.outside then                     -- BUG-027: name the burrows the alert holds the civilians in
    local _, names = alert_burrows(K)
    txt = 'no worker: its levers lie outside the alert burrow' .. (names and (' ' .. table.concat(names, ', ')) or '')
  end
  local d = {bridge = name, want = 'up', why = why}
  if why == FAIL_WHY.blocked and r.block then         -- BUG-027: name who holds it (and the soldiers' stations)
    if #r.block > 0 then
      txt = 'blocked: ' .. who(r.block, r.foot) .. ', never raised onto them'
      d.units, d.pos = ids_of(r.block), {r.block[1].x, r.block[1].y, r.block[1].z}
    end
  elseif why == FAIL_WHY.manual then txt = 'manual: no automatic pull, config/reflex.json gate.manual' end
  local secs = r.want_ms and (K.now().ms - r.want_ms) // 1000 or nil
  K.emit('GATE_FAIL', 'A', cut(string.format('%s not up after %d ticks%s (%s)', name, now - br.since,
                                             secs and string.format(', %d s', secs) or '', txt), 200), d)
end

local function update_every(K)
  local fast = FAST_MODES[K.mode()] or false
  if not fast then
    for name, r in pairs(rt) do
      local br = st.br[name]
      if r.job or (br and br.want and br.want ~= r.last) then fast = true; break end
    end
  end
  local want = fast and M.FAST or M.SLOW
  for _, r in pairs(rt) do if r.job or r.mv then want = M.PENDING; break end end   -- BUG-027: every frame
  if M.every.ticks ~= want then M.every = {ticks = want} end
end

---------------------------------------------------------------- lockdown, peace gates, unmanaged bridges
-- D-14 up: is a PEACE window open (a caravan, migrants), or this bridge's own `lever` window? Never while a hostile
-- is visible or the census is stale. Closes WIN_CLOSE ticks after its last reason.
local function window_open(K, name, now)
  local h = K.census.h
  if not (type(h) == 'table' and (h.vis or 0) == 0 and now - (h.tick or -1e9) <= 200) then return false end
  if now < ((st.winb or {})[name] or -1) then return true end
  local v = K.view()
  local tr = type(v) == 'table' and v.trade
  if (type(tr) == 'table' and tr.caravan == 1) or now < (st.win or -1) then st.win_last = now; return true end
  return st.win_last ~= nil and now >= st.win_last and now - st.win_last < M.WIN_CLOSE
end

-- the PEACE want of a gate bridge (manifest outer/inner, or an unmanaged one kept up): lockdown up; D-14 up: up
-- unless a window is open; D-14 down: down (the mode table)
local function peace_want(K, name, role, now)
  if not GATE_ROLES[role] and role ~= 'extra' then return 'down', 'peace' end
  if lock_why(K) then return 'up', 'lockdown' end
  if peace_up(K) then
    if window_open(K, name, now) then return 'down', 'window' end
    return 'up', 'peace_gates'
  end
  return 'down', 'peace'
end

-- mode default for a bridge without a want: PEACE per peace_want, BREACH up
local function ensure_default(K, name, now)
  if st.br[name] ~= nil then return end
  local m = K.mode()
  local spec = (K.manifest().bridges or {})[name]
  if m == 'PEACE' then
    local w, why = peace_want(K, name, type(spec) == 'table' and spec.role, now)
    set_want(name, w, why, nil, now)
  elseif m == 'BREACH' and select(2, K.call('siege', 'held', name)) ~= true then   -- BUG-028: unless siege holds it
    set_want(name, 'up', 'breach', nil, now)
  end
end

-- lockdown and PEACE gates for the manifest bridges (level-triggered): a lockdown wants outer/inner up in every
-- mode; in PEACE D-14 up keeps them up outside a window, and a bridge the lockdown held goes back to its PEACE want
local function manifest_pass(K, man, now)
  local lock, mode = lock_why(K), K.mode()
  for _, name in ipairs(bridge_names(man)) do
    local role, br = man.bridges[name].role, st.br[name]
    local w, why
    if br and br.want == 'down' and SIEGE_DOWN[br.why] then w = nil   -- BUG-028 rescue, intake, sortie: until they end
    elseif lock and GATE_ROLES[role] then w, why = 'up', 'lockdown'
    elseif mode == 'PEACE' and GATE_ROLES[role] and (peace_up(K) or (br and br.why == 'lockdown')) then
      w, why = peace_want(K, name, role, now)
    end
    if w and not (br and br.want == w) then set_want(name, w, why, nil, now) end
  end
end

local function is_extra(name) return st.ex[name] ~= nil end

-- lever-linked drawbridges outside the manifest, found from the levers (buildings.other.TRAP, lever.lua:103); cached
-- for EXTRA_EVERY ticks. A bridge a manifest bridge already resolved to is not unmanaged.
local function discover(K, now, force)
  if not force and rt_ex and now >= rt_ex.tick and now - rt_ex.tick < M.EXTRA_EVERY then return rt_ex.list end
  local managed = {}
  for name, r in pairs(rt) do if r.bid and not is_extra(name) and not r.fp then managed[r.bid] = true end end
  local found, order = {}, {}
  local ok = pcall(function()
    for _, lv in ipairs(df.global.world.buildings.other.TRAP) do
      if is_lever(lv) then
        for bid in pairs(targets(lv) or {}) do
          local e = found[bid]
          -- BUG-027 stop-gap: a bridge in gate.manual is never taken in hand
          if not e and not managed[bid] and not manual(K, string.format('X%d', bid % 10000000), bid) then
            local b = df.building.find(bid)
            if b and is_bridge(b) then
              e = {bid = bid, b = b, levers = {}}
              found[bid], order[#order + 1] = e, bid
            end
          end
          if e and #e.levers < 4 then e.levers[#e.levers + 1] = {lv.x1, lv.y1, lv.z} end
        end
      end
    end
  end)
  if not ok then K.log('warn', 'gate: lever scan failed') end
  table.sort(order)
  local list = {}
  for i = 1, math.min(#order, M.EXTRA_MAX) do
    local e = found[order[i]]
    local b = e.b
    list[#list + 1] = {name = string.format('X%d', e.bid % 10000000), bid = e.bid,
                       spec = {role = 'extra', fp = {b.x1, b.y1, b.z, b.x2, b.y2, b.z}, levers = e.levers}}
  end
  rt_ex = {tick = now, list = list}
  return list
end

local function forget(name)
  st.ex[name], st.br[name], rt[name], dirty = nil, nil, nil, true
end

-- unmanaged bridges: up while the lockdown holds (or in SIEGE/BREACH); afterwards, in PEACE, the ones the lockdown
-- raised go down again (D-14 down) or stay up outside the windows (D-14 up); a lowered one is forgotten
local function extras_pass(K, now, force)
  local mode = K.mode()
  local hold = lock_why(K) or (LOCK_MODES[mode] and mode:lower()) or nil
  if not hold and next(st.ex) == nil then return {} end
  local list = discover(K, now, force)
  local states, seen = {}, {}
  local keep = peace_up(K)
  for _, e in ipairs(list) do
    local name, x = e.name, st.ex[e.name]
    seen[name] = true
    local r = runtime(name)
    r.fp = e.spec.fp
    if hold then
      if not x then
        resolve(r, e.spec, now, true)
        x = {bid = e.bid, raised = read(r) ~= 'up' and 1 or 0}
        st.ex[name], dirty = x, true
        K.log('info', 'gate: unmanaged bridge %s (lever-linked) in hand for %s, %s', name, hold, read(r))
      end
      local br = st.br[name]
      if not (br and br.want == 'up') then set_want(name, 'up', 'lockdown', nil, now) end
    elseif x and mode == 'PEACE' then
      -- only a bridge the lockdown raised is ours afterwards; one that was already up stays the player's
      local w, why
      if x.raised ~= 1 then w = nil
      elseif keep then w, why = peace_want(K, name, 'extra', now)
      else w, why = 'down', 'unlock' end
      local br = st.br[name]
      if not w then forget(name); x = nil
      elseif not (br and br.want == w) then set_want(name, w, why, nil, now) end
    end
    if x then
      states[name] = control(K, name, e.spec, now)
      check_fail(K, name, now)
      local br = st.br[name]
      if not hold and not keep and br and br.want == 'down' and states[name] == 'down' then
        forget(name)
        states[name] = nil
      end
    end
  end
  if rt_ex.tick == now then                 -- just rescanned: destroyed or unlinked since, nothing left to pull
    for name in pairs(st.ex) do if not seen[name] then forget(name) end end
  end
  return states
end

---------------------------------------------------------------- module
function M.init(K)
  local now = K.now().tick
  st = {v = 2, br = {}, kpi = new_kpi(now)}
  local p = K.persist.get('m.gate')
  if type(p) == 'table' then
    for name, br in pairs(type(p.br) == 'table' and p.br or {}) do
      if type(br) == 'table' and (br.want == 'up' or br.want == 'down') then
        st.br[name] = {want = br.want, why = br.why or '', since = br.since and math.tointeger(br.since) or now,
                       deadline = br.deadline and math.tointeger(br.deadline), failed = br.failed == true}
      end
    end
    if type(p.kpi) == 'table' then
      local function int(v) return type(v) == 'number' and math.tointeger(v) or nil end
      local k = new_kpi(int(p.kpi.t0) or now)
      for _, f in ipairs({'dbl', 'pulls', 'cancels', 'links', 'pp', 'pa'}) do k[f] = int(p.kpi[f]) or 0 end
      for n, v in pairs(type(p.kpi.raise) == 'table' and p.kpi.raise or {}) do k.raise[n] = int(v) end
      for n, v in pairs(type(p.kpi.take) == 'table' and p.kpi.take or {}) do k.take[n] = int(v) end
      for _, f in ipairs(type(p.kpi.fails) == 'table' and p.kpi.fails or {}) do k.fails[#k.fails + 1] = f end
      st.kpi = k
    end
  end
  st.ex, st.winb, st.seen, st.gone, st.lost = {}, {}, {}, {}, {}
  if type(p) == 'table' then
    local function int(v) return type(v) == 'number' and math.tointeger(v) or nil end
    -- BUG-030: the complete bridge last seen on each manifest footprint, and the destroyed ones
    for name, x in pairs(type(p.seen) == 'table' and p.seen or {}) do
      if type(name) == 'string' and type(x) == 'table' and int(x.bid) and type(x.fp) == 'string' then
        st.seen[name] = {bid = int(x.bid), fp = x.fp, it = int(x.it),
                         mat = type(x.mat) == 'string' and x.mat:sub(1, 40) or nil,
                         key = type(x.key) == 'string' and x.key:match('^g[adwxs]$') or nil}
      end
    end
    -- the loss history per manifest bridge (BUG-030 rebuild policy)
    for name, x in pairs(type(p.lost) == 'table' and p.lost or {}) do
      if type(name) == 'string' and type(x) == 'table' and int(x.n) then
        local L = {n = int(x.n), bd = int(x.bd) or 0, reb = int(x.reb) or 0, it = int(x.it) or 0, lk = int(x.lk) or 0,
                   mat = type(x.mat) == 'string' and x.mat:sub(1, 40) or nil, races = {}, ev = {}}
        for _, r in ipairs(type(x.races) == 'table' and x.races or {}) do
          if type(r) == 'string' and #L.races < M.LOST_RACES then L.races[#L.races + 1] = r:sub(1, 24) end
        end
        for _, e in ipairs(type(x.ev) == 'table' and x.ev or {}) do
          if type(e) == 'table' and int(e.t) and #L.ev < M.LOST_EV then
            L.ev[#L.ev + 1] = {t = int(e.t), y = int(e.y) or 0, m = tostring(e.m or '?'):sub(1, 9),
                               bd = int(e.bd) == 1 and 1 or 0}
          end
        end
        st.lost[name] = L
      end
    end
    for name, x in pairs(type(p.gone) == 'table' and p.gone or {}) do
      if type(name) == 'string' and type(x) == 'table' and int(x.t) and st.seen[name] then
        st.gone[name] = {t = int(x.t), bid = int(x.bid) or st.seen[name].bid,
                         last = tostring(x.last or 'unknown'):sub(1, 9)}
      end
    end
    for name, x in pairs(type(p.ex) == 'table' and p.ex or {}) do
      if type(name) == 'string' and type(x) == 'table' and int(x.bid) then
        st.ex[name] = {bid = int(x.bid), raised = int(x.raised) == 1 and 1 or 0}
        -- its want came back with st.br (the name is not in the manifest, so it is kept)
      end
    end
    if type(p.lat) == 'table' and int(p.lat.s) and int(p.lat.t) then st.lat = {s = int(p.lat.s), t = int(p.lat.t)} end
    st.win = int(p.win)
    st.ne = {}                                    -- BUG-068: LEVER_NOEFFECT cadence records per lever id
    for k, x in pairs(type(p.ne) == 'table' and p.ne or {}) do
      if type(k) == 'string' and k:match('^%d+$') and type(x) == 'table' and int(x.t) then
        st.ne[k] = {t = int(x.t), w = int(x.w), ids = type(x.ids) == 'table' and x.ids or {},
                    toks = type(x.toks) == 'table' and x.toks or {}}
      end
    end
    for name, t in pairs(type(p.winb) == 'table' and p.winb or {}) do
      if type(name) == 'string' and int(t) then st.winb[name] = int(t) end
    end
  end
  rt, rt_ex, pub, dirty, PULL, last_pass, bds = {}, nil, nil, false, nil, nil, nil
  mvl = {list = {}, crushed = {}}
  pl, rooms_c, lb_name = {rooms = {}}, nil, nil
  M.every = {ticks = FAST_MODES[K.mode()] and M.FAST or M.SLOW}
end

-- FR-55 lever state: last measured latency (-1 never), our pending pulls and how long the oldest one waits
local function lever_state(K)
  local ms, pend, wait = K.now().ms, 0, 0
  for _, r in pairs(rt) do
    if r.job then
      pend = pend + 1
      local w = (ms - (r.job.qms or ms)) // 1000
      if w > wait then wait = w end
    end
  end
  local lat = st.lat or {}
  return {lat_s = lat.s or -1, lat_t = lat.t or -1, pend = pend, wait_s = math.max(0, wait)}
end

local function pass(K, force)
  local now = K.now().tick
  local man = K.manifest()
  local states = {}
  local gone = {}                                -- forget bridges the manifest no longer lists (not the unmanaged)
  for name in pairs(rt) do gone[name] = true end
  for name in pairs(st.br) do gone[name] = true end
  for name in pairs(st.seen) do gone[name] = true end
  for name in pairs(st.lost) do gone[name] = true end
  for name in pairs(gone) do
    if not valid_spec((man.bridges or {})[name]) and not is_extra(name) and not (rt[name] and rt[name].fp) then
      rt[name], st.br[name], st.seen[name], st.gone[name], st.lost[name], dirty = nil, nil, nil, nil, nil, true
    end
  end
  note_destroyers(K, now)                        -- loss history: who was in sight before a bridge is lost
  pullers_step(K, now)
  manifest_pass(K, man, now)
  for _, name in ipairs(bridge_names(man)) do
    ensure_default(K, name, now)
    states[name] = control(K, name, man.bridges[name], now)
    check_fail(K, name, now)
    links(K, name, man.bridges[name], runtime(name), now)
  end
  for name, s in pairs(extras_pass(K, now, force)) do states[name] = s end
  pub = next(states) and {bridges = states, lever = lever_state(K)} or {}
  update_every(K)
  flush(K)
  return states
end

-- BUG-027: between the full passes (every FAST ticks while a bridge has work) a frame only re-checks the bridges with
-- a pull of ours pending, so a unit stepping next to the footprint cancels it before the puller is done
local function pending_pass(K, now)
  for name, r in pairs(rt) do
    if (r.job or r.mv) and r.spec then control(K, name, r.spec, now) end
  end
  update_every(K)
  flush(K)
end

function M.step(K, budget, ctx)
  local now = K.now().tick
  if M.every.ticks == M.PENDING and last_pass and now >= last_pass and now - last_pass < M.FAST then
    return pending_pass(K, now)
  end
  last_pass = now
  pass(K, false)
end

-- public (CONTRACTS §7): request a bridge state. 'up' is always honoured; 'down' is refused in
-- SIEGE/BREACH/DRILL and while a visible hostile is within 30 tiles. deadline (abs tick, optional,
-- WP5 extension) = when a missing 'up' becomes GATE_FAIL; default now + 900.
function M.want(K, bridge, want, why, deadline)
  if want ~= 'up' and want ~= 'down' then return false, 'want must be up or down' end
  local man = K.manifest()
  local spec = type(man.bridges) == 'table' and man.bridges[bridge]
  if not valid_spec(spec) then return false, 'no bridge ' .. tostring(bridge) end
  local GONE = ' destroyed: no bridge on its footprint'          -- BUG-030
  if st.gone[bridge] then return false, bridge .. GONE end
  if want == 'down' then
    local g = down_guard(K, bridge, why)
    if g then return false, g end
  end
  local now = K.now().tick
  local changed = set_want(bridge, want, why, deadline and math.tointeger(deadline), now)
  control(K, bridge, spec, now)
  update_every(K)
  flush(K)
  if st.gone[bridge] then return false, bridge .. GONE end         -- found destroyed just now
  return true, (changed and 'wanted ' or 'still ') .. bridge .. ' ' .. want
end

-- public (BUG-013, reflex): what the lockdown's deferred civ alert waits for, from the last pass: want (bridges wanted
-- up), up, left (wanted up, not up, a pull to do: queued or next), out (of left: no linked lever inside the burrows
-- the sounding civ alert holds the civilians in, so nobody may take the pull), foot (waiting for a citizen to leave
-- the footprint), nolever (no linked lever), lat_t (last lever latency in ticks, -1 never measured), lb (the lever
-- burrow while the sounding alert lists it)
function M.pulls(K)
  local res = {want = 0, up = 0, left = 0, out = 0, foot = 0, nolever = 0, lat_t = st.lat and st.lat.t or -1}
  local bs, names = alert_burrows(K)
  for name, s in pairs(pub and pub.bridges or {}) do
    local br, r = st.br[name], rt[name]
    if br and br.want == 'up' then
      res.want = res.want + 1
      if s == 'up' then res.up = res.up + 1
      elseif needs_pull(name) then
        res.left = res.left + 1
        if bs and not lever_in(r, bs) then res.out = res.out + 1 end
      elseif r and r.stuck == 'blocked' then res.foot = res.foot + 1
      elseif r and r.stuck == 'manual' then res.manual = (res.manual or 0) + 1      -- BUG-027 gate.manual
      elseif r and r.stuck == 'no_effect' then res.parked = (res.parked or 0) + 1   -- BUG-082: every lever parked
      else res.nolever = res.nolever + 1 end
    end
  end
  for _, n in ipairs(names or {}) do if n == lb_name then res.lb = n end end
  return res
end

-- public (FR-49/52): the reflex module started or ended a lockdown (it answers reflex.holding('gates')); run the gate
-- pass now (same step) with a fresh scan for unmanaged bridges. Returns {want, up, pend, names} and pulls()' fields
-- (left, out, foot, nolever, lat_t, lb): the bridges wanted up and how many already are; pend = our pulls queued now.
function M.lockdown(K)
  local now = K.now().tick
  local man = K.manifest()
  for _, name in ipairs(bridge_names(man)) do
    if not st.gone[name] then resolve(runtime(name), man.bridges[name], now) end
  end
  local states = pass(K, true)
  local info = M.pulls(K)
  info.pend, info.names = 0, {}
  local names = {}
  for name in pairs(states) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    local br = st.br[name]
    if br and br.want == 'up' then info.names[#info.names + 1] = name end
    if (rt[name] or {}).job then info.pend = info.pend + 1 end
  end
  return info
end

-- public (BUG-027, siege): why a bridge wanted up is not up yet without having failed: 'blocked' (units on or next to
-- its footprint) or 'pulling' (a pull of ours taken by a worker, or the bridge moving, inside its allowance); nil else.
-- siege does not count such a bridge as failed (BREACH) while no hostile is near it.
function M.waiting(K, bridge)
  local r, br = rt[bridge], st.br[bridge]
  if not (r and br and br.want == 'up') or r.last == 'up' then return nil end
  if r.stuck == 'blocked' then return 'blocked' end
  if r.fail_at then return K.now().tick < r.fail_at and 'pulling' or nil end   -- the allowance after the deadline
  if r.last == 'moving' or (r.job and r.job.taken) then return 'pulling' end
  return nil
end

-- public (BUG-032, military): the margin every pull waits for around a footprint (military keeps squad stations
-- farther away than this plus the spread of a squad around its station)
function M.margin(K) return M.MARGIN end

-- public (BUG-032, siege -> military.restation): the bridges whose pull waits for units on or next to the footprint now
-- (as of the last pass): {{bridge, want, fp = {x0, y0, z0, x1, y1, z1}, since, units = {{id, k, d, x, y, z}}}}, sorted
-- by bridge; k as in the GATE text (citizen, soldier, child, animal, ...), d = tiles from the footprint
function M.holds(K)
  local r = {}
  for name, x in pairs(rt or {}) do
    local br = st.br[name]
    if type(x.block) == 'table' and #x.block > 0 and x.foot and br and br.want then
      local units = {}
      for i, e in ipairs(x.block) do units[i] = {id = e.id, k = e.k, d = e.d, x = e.x, y = e.y, z = e.z} end
      local f = x.foot
      r[#r + 1] = {bridge = name, want = br.want, fp = {f[1], f[2], f[3], f[4], f[5], f[6]}, since = x.block_since,
                   units = units}
    end
  end
  table.sort(r, function(a, b) return a.bridge < b.bridge end)
  return r
end

-- public (BUG-027, sense): boxes {x0, y0, z0, x1, y1, z1} around the footprints of the bridges with work now (a want not
-- reached, a pull pending, moving), grown by WATCH_R on their z; sense lists the visible friendly non-citizens in them
-- (visitors, merchants, tame animals) as census.h.friends, so they hold the pull too. nil when none has work.
function M.watch(K)
  local list = {}
  for name, r in pairs(rt) do
    local br = st.br[name]
    local fp = r.foot
    if fp and (r.job or r.mv or r.last == 'moving' or (br and br.want and br.want ~= r.last)) then
      list[#list + 1] = {fp[1] - M.WATCH_R, fp[2] - M.WATCH_R, fp[3], fp[4] + M.WATCH_R, fp[5] + M.WATCH_R, fp[6]}
    end
  end
  return #list > 0 and list or nil
end

-- public (BUG-027, care): the recorded bridge moves, oldest first, as plain copies: {t, t1, b, bid, fp, to, pull, lever,
-- seen = {{id, k, d, x, y, z, t}}} (t = the tick gate saw the move start, t1 = settled, nil while moving; pull = the
-- tick our pull was queued, -1 a foreign one; seen = the closest sighting of each unit within SCAN_R tiles)
function M.moves(K)
  local r = {}
  for i, m in ipairs(mvl and mvl.list or {}) do
    local seen = {}
    for j, e in ipairs(m.seen) do seen[j] = {id = e.id, k = e.k, d = e.d, x = e.x, y = e.y, z = e.z, t = e.t} end
    r[i] = {t = m.t, t1 = m.t1, b = m.b, bid = m.bid, fp = m.fp, to = m.to, pull = m.pull, lever = m.lever, seen = seen}
  end
  return r
end

-- public (FR-49): the fort is sealed by its bridges: >= 1 gate bridge (manifest outer/inner, else the unmanaged ones
-- in hand) and every one of them up. siege counts sealed_ticks with it when the manifest has no outer/inner bridge.
function M.sealed(K)
  local b = pub and pub.bridges or {}
  local man = K.manifest()
  local list = {}
  for _, name in ipairs(bridge_names(man)) do
    if GATE_ROLES[man.bridges[name].role] then list[#list + 1] = name end
  end
  if #list == 0 then for name in pairs(st.ex) do list[#list + 1] = name end end
  if #list == 0 then return false end
  for _, name in ipairs(list) do if b[name] ~= 'up' then return false end end
  return true
end

-- public (FR-58): entrance points for an arrival ETA: centres of the manifest outer bridges, else of the unmanaged
-- bridges in hand (or found)
function M.points(K)
  local man, r = K.manifest(), {}
  for _, name in ipairs(bridge_names(man)) do
    if man.bridges[name].role == 'outer' then r[#r + 1] = geom.bbox_center(man.bridges[name].fp) end
  end
  if #r == 0 and rt_ex then
    for _, e in ipairs(rt_ex.list) do r[#r + 1] = geom.bbox_center(e.spec.fp) end
  end
  return r
end

-- module state part (no bridge) or public gate.state(bridge) -> state, pending job id, the tick it was found destroyed
-- (BUG-030; nil while it stands or was never built)
function M.state(K, bridge)
  if bridge == nil then return pub or {} end
  local man = K.manifest()
  local spec = type(man.bridges) == 'table' and man.bridges[bridge]
  if not valid_spec(spec) then return 'unknown', nil end
  -- BUG-030: a destroyed bridge reads 'unknown' (readiness: bridge:B) with the tick it was found destroyed
  if st.gone[bridge] then return 'unknown', nil, st.gone[bridge].t end
  local r = runtime(bridge)
  local now = K.now().tick
  resolve(r, spec, now)
  if gone_check(K, bridge, r, spec, now) then return 'unknown', nil, st.gone[bridge].t end
  local s = read(r)
  local j = r.job and r.job.id
  if not j then
    local fj = pending(r)
    j = fj and fj.id or nil
  end
  return s, j
end

-- public (BUG-030 rebuild policy): the loss history of manifest bridge `name` (a copy: {n, bd, reb, it, mat, lk, races,
-- ev = {{t, y, m, bd}}}, nil when it was never destroyed), or with `name` nil every record by bridge name
local function copy_lost(L)
  local ev, races = {}, {}
  for i, e in ipairs(L.ev) do ev[i] = {t = e.t, y = e.y, m = e.m, bd = e.bd} end
  for i, r in ipairs(L.races) do races[i] = r end
  return {n = L.n, bd = L.bd, reb = L.reb, it = L.it, mat = L.mat, lk = L.lk, races = races, ev = ev}
end
function M.losses(K, name)
  if name ~= nil then
    local L = st.lost[name]
    return L and copy_lost(L) or nil
  end
  local r = {}
  for n, L in pairs(st.lost) do r[n] = copy_lost(L) end
  return r
end

-- public (BUG-048, seal): the quickfort key of the raise direction of manifest bridge `name` as gate read it from the
-- complete building (ga/gd/gw/gx/gs), nil when it never saw it complete or DF did not say
function M.bridge_key(K, name)
  local x = st.seen[name]
  return x and x.key or nil
end

function M.kpi(K)
  local raise, fails, take, pullers = {}, {}, {}, {}
  for n, v in pairs(st.kpi.raise) do raise[n] = v end
  for i, f in ipairs(st.kpi.fails) do fails[i] = f end
  for n, v in pairs(st.kpi.take) do take[n] = v end
  for n, p in pairs(pl.rooms) do pullers[n] = #p.ids end
  return {double_toggles = st.kpi.dbl, last_raise_ticks = raise, pulls = st.kpi.pulls,
          cancels = st.kpi.cancels, links = st.kpi.links or 0, fails = fails, since = st.kpi.t0,
          take_ticks = take, puller_pulls = st.kpi.pp or 0, puller_assigns = st.kpi.pa or 0, pullers = pullers}
end

-- public (WP5 extension, live L3): the lever rooms allowed in `mode` (default: now) that exist, sorted; siege
-- adds them to the civ-alert burrow list (BREACH: only the rooms behind the core seal whose bridges have no
-- linked lever inside the refuge yet). BUG-013: then seal's lever burrow while a pull is pending on a bridge whose
-- linked levers all lie outside `main` (the alert's burrow) and those rooms, or failed there this epoch; while `main`
-- is the refuge or the mode BREACH only while breach_safe (Run 11 y432 winter, the deep defense)
function M.rooms(K, mode, main)
  mode = mode or K.mode()
  local r = {}
  for _, rm in ipairs(room_list(K, K.now().tick)) do
    if allowed(K, rm, mode) then r[#r + 1] = rm.name end
  end
  local lb = lever_room(K, mode, main, r)
  if lb then r[#r + 1] = lb end
  return r
end

-- public (WP5 extension, live L3): assigned pullers standing in an allowed room that holds a lever of `bridge`
function M.pullers(K, bridge)
  local mode, n = K.mode(), 0
  for _, rm in ipairs(room_list(K, K.now().tick)) do
    if rm.bridges[bridge] and allowed(K, rm, mode) then n = n + present(rm) end
  end
  return n
end

-- public (BUG-035, reflex's recall): the lever pullers gate holds in their rooms now, {[unit id] = room}: they stay by
-- the levers on purpose (siege lists the room in the alert), so the recall neither waits for them nor holds a door
function M.puller_of(K)
  local r = {}
  for name, p in pairs(pl and pl.rooms or {}) do
    for _, id in ipairs(p.ids or {}) do r[id] = name end
  end
  return r
end

function M.reset_kpi(K)
  st.kpi = new_kpi(K.now().tick)
  dirty = true
  flush(K)
end

-- BUG-027: a dead unit that gate saw on or next to a bridge as it was pulled or moved (by id; a missing death too: gate
-- saw it there alive), or whose body lies on or next to it (a found death of a fort member or tame animal), or whose
-- incident says DRAWBRIDGE, within the move's window: BRIDGE_CRUSH (A), once per unit. A combat incident is no crush.
local function unit_death(K, ev)
  local id = ev.unit
  if math.type(id) ~= 'integer' or not mvl or #mvl.list == 0 or mvl.crushed[id] then return end
  local now = ev.tick or K.now().tick
  local u = df.unit.find(id)
  local ic = u and DT.incident(u)
  if ic and ic.cause and DT.TYPE[ic.cause] == 'killed' then return end
  local pos
  if u and not (ic and not ic.found) then
    local U = dfhack.units
    local ok, own = pcall(function() return U.isOwnGroup(u) or U.isTame(u) end)
    if ok and own then
      local x, y, z = U.getPosition(u)
      if x then pos = {x, y, z} end
    end
  end
  local m = DT.bridge(id, now, mvl.list, pos, ic and ic.cause)
  if not m then return end
  mvl.crushed[id] = true
  local who_k = m.k or 'unit'
  local txt = string.format('%s %d crushed: %s', who_k, id, DT.bridge_why(m))
  local d = {bridge = tostring(m.b), unit = id, bid = m.bid, pull = m.pull, t = m.t, to = m.to, how = m.how, k = m.k}
  if m.pos then d.pos = m.pos end
  K.emit('BRIDGE_CRUSH', 'A', cut(txt, 200), d)
  K.log('warn', 'gate: %s', txt)
end

M.on = {
  UNIT_DEATH = unit_death,
  -- D-14 up: migrants and caravans open the PEACE window (trade's state keeps it open while a caravan is here)
  REPORT = function(K, ev)
    local now = K.now().tick
    local add = (ev.type == 'CARAVAN_ARRIVAL' or ev.type == 'FIRST_CARAVAN_ARRIVAL') and M.WIN_CARAVAN or M.WIN_MIGRANTS
    if peace_up(K) and now + add > (st.win or -1) then
      st.win, dirty = now + add, true
      K.log('info', 'gate: peace gates open for %s (%d ticks)', ev.type, add)
    end
  end,
  MODE = function(K, ev)
    local now = ev.tick or K.now().tick
    local man = K.manifest()
    pullers_step(K, now)                         -- T0: pullers walk to the levers; PEACE etc. release them
    for _, name in ipairs(bridge_names(man)) do
      local r = runtime(name)
      if not st.gone[name] then resolve(r, man.bridges[name], now) end
      -- BUG-030: a destroyed bridge has no epoch (one found destroyed now is BRIDGE_DESTROYED, never GATE_FAIL)
      if not (st.gone[name] or gone_check(K, name, r, man.bridges[name], now)) then
        observe(K, name, r, read(r), now, man.bridges[name].fp)
        check_fail(K, name, now, ev.from) -- settle the old epoch first (SIEGE->BREACH at T+900 = its deadline)
        local br = st.br[name]
        if ev.to == 'PEACE' then
          local w, why = peace_want(K, name, man.bridges[name].role, now)
          set_want(name, w, why, nil, now)
        elseif br and br.want == 'down' and br.why == 'rescue' then   -- BUG-028: siege's rescue holds across modes
        elseif ev.to == 'BREACH' and select(2, K.call('siege', 'held', name)) == true then
          st.br[name], dirty = nil, true         -- BUG-028: siege holds it (citizens it would cut off); siege wants it
        elseif ev.to == 'BREACH' then
          if br and br.want == 'up' and br.since < now then
            br.since, br.deadline, br.failed, dirty = now, now + M.DEADLINE, false, true
            new_epoch(r)
          else
            set_want(name, 'up', 'breach', now + M.DEADLINE, now)
          end
        elseif ev.to == 'SIEGE' or ev.to == 'DRILL' then
          if br and br.want == 'down' then st.br[name], dirty = nil, true      -- never lower now
          elseif br and br.want == 'up' and br.since < now then                -- new epoch, siege sets the deadline
            br.since, br.deadline, br.failed, dirty = now, nil, false, true
            new_epoch(r)
          end
        end
        control(K, name, man.bridges[name], now)   -- cancels a stale own pull at once
      end
    end
    update_every(K)
    flush(K)
  end,
}

-- inbox `lever` (PEACE only, checked by kern): {bridge, want}
M.verbs.lever = function(K, args, cmd)
  local b, w = args.bridge, args.want
  if type(b) ~= 'string' or (w ~= 'up' and w ~= 'down') then return false, 'need bridge and want up|down' end
  if w == 'down' and peace_up(K) then    -- D-14 up: the operator's planned opening is a window for this bridge
    st.winb[b], dirty = K.now().tick + M.WIN_LEVER, true
  end
  local ok, msg = M.want(K, b, w, 'lever:' .. tostring(cmd and cmd.by or '?'))
  if not ok then return false, msg end
  local r = runtime(b)
  if r.job then return true, 'queued ' .. b .. ' ' .. w, {job = r.job.id} end
  if r.last == w then return true, b .. ' already ' .. w end
  return true, 'wanted ' .. b .. ' ' .. w .. ' (' .. (r.stuck or 'waiting') .. ')'
end

return M
