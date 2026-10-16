-- siege (WP5): the mode FSM (DESIGN §3 mode table, §4 siege reflex, CONTRACTS §14) and the sole
-- writer of the civ alert and its burrow list (via act -> gui/civ-alert, civ-alert.lua:27-50).
-- Inputs are visibility only (threat.assess over K.census.h); a raised bridge cuts the walk
-- groups, so path existence is never used to leave a siege.
--   T0 (detecting step): mode SIEGE, civ alert on (Kern+), posture READY_STATION, SIEGE_START. The alert
--     burrow list is the mode's burrow plus the lever rooms gate allows in the mode (gate.rooms, live L3), and
--     while a pull is pending on levers outside both, seal's lever burrow with the lever tiles (BUG-013).
--   T0..T0+450: O1/B1 up as soon as nobody (soldiers excluded) is outside, or at T+450, or when a
--     visible hostile is <= 10 tiles from that bridge (gate keeps the single-pending invariant).
--   T0+900: an outer/inner bridge not up -> BREACH in-game (alert Tiefe+, B2 up, B2_HOLD); BUG-027: not while gate
--     reports it waiting (units on its footprint, its pull under way) and no hostile is within NEAR_RAISE of it.
--   BUG-028 (stranded citizens, see that section): a first raise that would cut citizens off from drink or food waits
--     for a hostile at the gate; citizens thirsty or hungry behind raised gates get the inner/core bridges lowered once
--     the outside is sealed (a rescue); BREACH falls back to SIEGE once the fort is sealed again. BUG-031: thirsty or
--     hungry in the alert's own burrow with the stock on their walk group: seal refuses that burrow (relax).
--   RECOVERY after 2,400 quiet ticks; on quiet time +1,200 B2 then B1 down and alert off,
--     +2,400 O1 down, +8,400 PEACE and SIEGE_END (A). Any visible invader -> SIEGE again.
-- Non-invader hostiles count only within reach of the fort (threat.lua), the same rule for entry,
-- re-entry and quiet. Kill orders are withdrawn when no target is left in a kill box. Losses are
-- checked against every citizen seen in the episode (the census drops the dead before UNIT_DEATH).
-- Run 9 / FR-49/52: SIEGE_START is class A (wakes at once). While the reflex module holds a lockdown with the alert
-- action (an arrival announcement, INVASION, the first armed hostile in sight), the civ alert is wanted in every mode,
-- PEACE included; reflex kicks it in the same step (siege.hold_alert). BUG-011: the kick and the step share one
-- decision (alert_plan: seal chooses the burrow, the interior one kept for a lockdown) and nothing switches the alert
-- off while the lockdown holds it, so siege stays the one owner of its state. With peace_gates (D-14) up, RECOVERY
-- lowers only the core seal (outer/inner stay up). Without manifest outer/inner bridges sealed_ticks counts the time
-- gate.sealed() holds (the unmanaged bridges a lockdown raised), so a fort without fortcore reports its seal too.
-- Intake waves, the sortie through O1 and the inner station (Gordon 2026-10-16, BUG-029): see that section below.
-- BUG-030 (Run 10 y421: 58 goblins and 6 trolls destroyed O1, B1 and B2): a bridge gate reports destroyed (gate.state's
-- third value) is an open way: never wanted up, no raise hold or STRANDED for it, a destroyed outer/inner bridge in
-- SIEGE is a BREACH at once (why destroyed), RECOVERY counts it as lowered; and the deep defense (plan B, see that
-- section): building destroyers in sight, an army over stations.core_ratio x our soldiers or weak squads send the
-- civilians to the separated refuge and every squad to the core station.
local geom = require('dfllm.util.geom')

-- every frame, but a full step only on a fresh hostile census or every PERIOD ticks, so the
-- decision lands in the frame that sense published the census (latency = sense scan period)
local M = {name = 'siege', every = {ticks = 1}, critical = true}
M.PERIOD, M.PERIOD_ARMED = 25, 10

-- RAISE_BY: live L2 drills measured 256-297 ticks from the queued pull to a raised bridge (a dwarf takes the
-- job after 156-243 ticks, the bridge moves 91-108); drill 1 pulled at T+600 and raised O1 at T+917. In drill
-- 2 (pull at T+540) nobody took O1's job for 200 ticks, gate cancelled it and pulled the backup lever, and O1
-- was up at T+945. The timer pull therefore goes out at T+450 (worst case seen: about T+855).
M.RAISE_BY, M.BREACH_AT, M.NEAR_RAISE = 450, 900, 10
M.QUIET, M.ALERT_QUIET = 2400, 1200
M.REC_INNER, M.REC_OUTER, M.REC_PEACE = 1200, 2400, 8400
M.ALERT_CIV_ON, M.ALERT_CIV_OFF, M.ALERT_CIV_HOLD, M.ALERT_O1 = 30, 40, 600, 30
M.ANCHORS = 20             -- alert anchors kept (positions of citizens outside at alert-on)
M.STATUS, M.RETRY, M.POSTURE_REASSERT, M.KILL_EVERY = 600, 600, 3600, 100
M.DRILL_MAX = 3600         -- a drill normally ends at T+1,200 (drill module)

-- BUG-029: SIEGE stands the squads at the inner station (READY_IN; INTAKE only while a wave runs)
local POSTURE = {PEACE = 'TRAIN', ALERT = 'STATION_B1', SIEGE = 'READY_IN', DRILL = 'READY_STATION',
                 BREACH = 'B2_HOLD', RECOVERY = 'STATION_B1'}
local EPISODE = {SIEGE = true, BREACH = true, RECOVERY = true}
local SHAFT = {['<'] = true, ['>'] = true, X = true, _ = true}

local st      -- persisted m.siege
local mem     -- runtime only (what was applied, ids seen)
local dirty

local function int(v) return type(v) == 'number' and math.tointeger(v) or nil end
local function save(K) if dirty then K.persist.set('m.siege', st); dirty = false end end

local function sorted_keys(t)
  local r = {}
  for k in pairs(t or {}) do r[#r + 1] = k end
  table.sort(r)
  return r
end

-- bridge names by role and burrow names from the manifest
local function geometry(K)
  local man = K.manifest()
  local g = {outer = {}, inner = {}, core = {}, all = {}, man = man}
  for _, name in ipairs(sorted_keys(man.bridges)) do
    local b = man.bridges[name]
    if type(b) == 'table' and type(b.fp) == 'table' and g[b.role] then
      local list = g[b.role]
      list[#list + 1] = name
      g.all[#g.all + 1] = name
    end
  end
  local kern, refuge
  for _, name in ipairs(sorted_keys(man.burrows)) do
    local role = type(man.burrows[name]) == 'table' and man.burrows[name].role
    if role == 'kern' and (kern == nil or name == 'Kern+') then kern = name end
    if role == 'refuge' and (refuge == nil or name == 'Tiefe+') then refuge = name end
  end
  if type(man.refuge) == 'table' and type(man.refuge.burrow) == 'string' then refuge = man.refuge.burrow end
  g.kern, g.refuge = kern or 'Kern+', refuge or 'Tiefe+'
  -- intake waves: the bailey (Z1), the trap hall (Z2), the killboxes, the zones past B1 (Z3/Z4), the stations
  local zones = type(man.zones) == 'table' and man.zones or {}
  local function boxes(keys)
    local r = {}
    for _, k in ipairs(keys) do
      for _, bb in ipairs(type(zones[k]) == 'table' and zones[k] or {}) do
        if type(bb) == 'table' and #bb == 6 then r[#r + 1] = bb end
      end
    end
    return r
  end
  g.z1, g.z2, g.z3, g.zpast, g.kb = boxes({'Z1'}), boxes({'Z2'}), boxes({'Z3'}), boxes({'Z3', 'Z4'}), {}
  for _, kb in ipairs(type(man.killboxes) == 'table' and man.killboxes or {}) do
    if type(kb) == 'table' and type(kb.bbox) == 'table' and #kb.bbox == 6 then g.kb[#g.kb + 1] = kb.bbox end
  end
  g.zin = {}
  for _, l in ipairs({g.z1, g.z2, g.kb}) do for _, bb in ipairs(l) do g.zin[#g.zin + 1] = bb end end
  g.stations = type(man.stations) == 'table' and man.stations or {}
  return g
end

---------------------------------------------------------------- inputs
-- threat.assess; minimal fallback on the census if threat is missing or disabled
local function assess(K)
  local ok, a = K.call('threat', 'assess')
  if ok then return a end
  local h = K.census.h
  if type(h) ~= 'table' then return nil end
  local fresh = K.now().tick - (h.tick or 0) <= 200
  local inv, great, vis, inside = h.inv or 0, h.great or 0, h.vis or 0, h.inside or 0
  return {vis = vis, inv = inv, great = great, undead = h.undead or 0, inside = inside,
          near_o1 = h.near_o1 or -1, near_cit = h.near_cit or -1, near_bridge = h.near_bridge or {},
          zin = h.zin or 0, zpast = h.zpast or 0, dz = h.dz or 0, dz_o1 = h.dz_o1 or -1, bd = h.bd or 0,
          siege = (great > 0 and 'great') or (inv >= 6 and 'invaders') or nil, hostile = vis > 0,
          quiet = fresh and vis == 0, calm = fresh and vis == 0, fresh = fresh}
end

-- 'up', 'down', 'moving', 'unknown' or (BUG-030) 'destroyed': gate found no bridge on the footprint any more
local function gate_state(K, b)
  local ok, s, _, gone = K.call('gate', 'state', b)
  if ok and gone then return 'destroyed' end
  return ok and s or 'unknown'
end

local function want(K, b, w, why, deadline)
  local ok, ok2 = K.call('gate', 'want', b, w, why, deadline)
  return ok and ok2 == true
end

local function alert_idx()
  local ok, v = pcall(function() return df.global.plotinfo.alerts.civ_alert_idx end)
  return ok and v or nil
end

local function wealth(K, why)
  local ok, d = pcall(function()
    local w = df.global.plotinfo.tasks.wealth
    return {created = int(w.total), exported = int(w.exported), imported = int(w.imported)}
  end)
  if ok and d and d.created then
    K.emit('WEALTH', 'B', string.format('wealth at %s: created %d', why, d.created), d)
  end
end

---------------------------------------------------------------- transitions
local function go(K, to, why, a, bridge)
  local from, ep = K.mode(), st.ep
  if not K.set_mode(to, why) then return false end
  local vis = a and a.vis or 0
  if to == 'SIEGE' then
    -- BUG-028 (b): back from BREACH once the fort is sealed again
    local txt = from == 'BREACH'
                and 'siege again (%s): breach over, every gate up, no hostile inside; %d visible, %d invaders'
                or 'siege (%s): %d visible, %d invaders'
    K.emit('SIEGE_START', 'A', string.format(txt, why, vis, a and a.inv or 0),
           {vis = vis, inv = a and a.inv or 0, great = a and a.great or 0, why = why})
    wealth(K, 'siege')
  elseif to == 'ALERT' then
    K.emit('ALERT_START', 'B', string.format('alert: %d visible hostiles', vis), {vis = vis})
    wealth(K, 'alert')
  elseif to == 'BREACH' then
    local what = (why == 'destroyed' and bridge and (bridge .. ' destroyed: an open way'))      -- BUG-030
                 or (bridge and (bridge .. ' not up at T+900')) or 'hostile inside Kern+'
    K.emit('BREACH', 'A', 'breach: ' .. what,
           {why = (why == 'gate_fail' or why == 'destroyed') and why or 'inside', bridge = bridge})
    wealth(K, 'breach')
  elseif to == 'PEACE' and from == 'ALERT' then
    K.emit('ALERT_END', 'B', 'alert over', {vis = vis})
  elseif to == 'PEACE' and from == 'RECOVERY' and ep then
    local hostiles = math.max(ep.hmax or 0, ep.seen or 0)
    K.emit('SIEGE_END', 'A', string.format('%d hostiles, %d killed, %d lost, sealed %d ticks',
           hostiles, ep.killed, ep.lost, ep.sealed),
           {hostiles = hostiles, killed = ep.killed, lost = ep.lost, captures = ep.caps, sealed_ticks = ep.sealed})
  end
  return true
end

-- contiguous quiet (visibility only)
local function quiet_for(a, now, n)
  if a and a.quiet then
    st.qs = st.qs or now
    return now - st.qs >= n
  end
  if st.qs then st.qs, dirty = nil, true end
  return false
end

---------------------------------------------------------------- stranded citizens (BUG-028)
-- Run 10 y419 (48 goblins in front of O1 for 60+ days): BREACH wanted B1, B2 and O1 up every pass and ended only on
-- 2,400 quiet ticks; 13 citizens and soldiers between O1 and B2 had no drink for 23+ days (thirst up to 74,090), at
-- least 2 died dehydrated while 3,093 drink units lay outside O1 and 737 in the core. Three rules, from seal's walk
-- groups (revealed tiles) and the units' own thirst and hunger counters (read only):
--   (a) rescue: citizens (soldiers too) over STRAND_THIRST / STRAND_HUNGER on a walk group without drink / food, cut
--       off by our raised bridges: once the outside is sealed (every outer bridge up, seal's entrance check after the
--       last bridge move: no route) and no hostile is inside or on the groups to be joined, the inner and core bridges
--       on the shortest way to a group with the stock come down (never an outer one; gate's footprint rules hold),
--       and go up again when every rescued citizen drank or ate, stands in the civ alert's burrow or is gone, after
--       RESCUE_MAX ticks, or at once when a hostile comes near (abort). STRANDED (A) names group, citizens, thirst and
--       bridges, and also a rescue that is not possible and why.
--   (b) BREACH falls back to SIEGE once every outer and inner bridge is up, seal's entrance check after the last move
--       says no route and no hostile is inside, for SEALED_HOLD ticks (seal releases the refuge then).
--   (c) before raising: seal.split says which part of the fort each citizen (soldiers excluded: their stations lie
--       there on purpose, (a) rescues them) would stand on; a raise that would leave citizens on a part without drink
--       or food waits (no BREACH for it) until a hostile is within CUT_NEAR tiles of that bridge, then goes ahead and
--       STRANDED (forced) says whom it cut off.
M.STRAND_THIRST, M.STRAND_HUNGER = 30000, 30000
M.RESCUE_EVERY, M.RESCUE_MAX = 100, 2400
M.CUT_NEAR, M.SEALED_HOLD, M.SPLIT_WAIT = 30, 600, 300
local CAD = require('dfllm.util.cadence')

local function counter(u, k)
  local ok, v = pcall(function() return u.counters2[k] end)
  return ok and int(v) or 0
end

local function near_bridge(K, b)
  local h = K.census.h
  local d = type(h) == 'table' and type(h.near_bridge) == 'table' and h.near_bridge[b]
  return int(d) or -1
end

-- STRANDED (A), once per news (new citizens or a new phase/bridge/reason); a standing condition (hold, refused) again
-- not before a game day and 60 s, the steps of a rescue and a forced raise at once
local function stranded(K, phase, txt, d, ids, toks)
  local now = K.now()
  local rec = st.str.rec
  local o = (phase == 'hold' or phase == 'refused') and {ticks = 1200, wall_s = 60} or {ticks = 0, wall_s = 0}
  if not CAD.due(rec, now, ids, toks, o) then return end
  st.str.rec, dirty = CAD.mark(now, ids, toks), true
  d.phase = phase
  K.emit('STRANDED', 'A', txt:sub(1, 200), d)
  K.log('warn', 'siege: %s', txt:sub(1, 200))
end

-- the fresh walk groups (seal.groups), or nil
local function groups(K)
  local ok, G = K.call('seal', 'groups')
  if ok and type(G) == 'table' and not G.stale then return G end
end

local function outer_up(K, g)
  if #g.outer == 0 then return false end
  for _, b in ipairs(g.outer) do if gate_state(K, b) ~= 'up' then return false end end
  return true
end

-- the shortest way over raised non-outer bridges from group `from` to a group with the needed stock: the bridges and
-- the groups on it, or nil
local function way(K, g, G, from, need)
  local adj = {}
  for _, b in ipairs(g.all) do
    local spec = g.man.bridges[b]
    if spec.role ~= 'outer' and gate_state(K, b) == 'up' then
      local ok, sides = K.call('seal', 'sides', spec.fp)
      local list = {}
      for s in pairs(ok and type(sides) == 'table' and sides or {}) do list[#list + 1] = s end
      table.sort(list)
      for i = 1, #list do
        for j = 1, #list do
          if i ~= j then
            local e = adj[list[i]] or {}
            e[#e + 1] = {list[j], b}
            adj[list[i]] = e
          end
        end
      end
    end
  end
  local prev, q, h = {[from] = false}, {from}, 1
  while h <= #q do
    local cur = q[h]
    h = h + 1
    if cur ~= from and (not need.drink or G.drink[cur]) and (not need.food or G.food[cur]) then
      local bs, gs, c = {}, {cur}, cur
      while prev[c] do
        bs[#bs + 1] = prev[c][2]
        c = prev[c][1]
        gs[#gs + 1] = c
      end
      return bs, gs
    end
    for _, e in ipairs(adj[cur] or {}) do
      if prev[e[1]] == nil then prev[e[1]] = {cur, e[2]}; q[#q + 1] = e[1] end
    end
  end
end

-- (a) the citizens over the thresholds on a group without what they need, the worst group first
local function cut_off(K, G)
  local cu = K.census.u
  local by = {}
  for gid, list in pairs(G.cit) do
    for _, c in ipairs(list) do
      local u = df.unit.find(c[1])
      if u then
        local th, hu = counter(u, 'thirst_timer'), counter(u, 'hunger_timer')
        local nd = th > M.STRAND_THIRST and not G.drink[gid]
        local nf = hu > M.STRAND_HUNGER and not G.food[gid]
        if nd or nf then
          local e = by[gid] or {g = gid, ids = {}, thirst = 0, hunger = 0, need = {}, pos = {c[2], c[3], c[4]}}
          by[gid] = e
          e.ids[#e.ids + 1] = c[1]
          e.thirst, e.hunger = math.max(e.thirst, th), math.max(e.hunger, hu)
          if nd then e.need.drink = true end
          if nf then e.need.food = true end
        end
      end
    end
  end
  local best
  for _, e in pairs(by) do
    table.sort(e.ids)
    if not best or #e.ids > #best.ids or (#e.ids == #best.ids and e.g < best.g) then best = e end
  end
  return best
end

local function needs_txt(e)
  return (e.need.drink and e.need.food) and 'drink and food' or (e.need.drink and 'drink' or 'food')
end

-- a patient (water's rule: needs health care or rests in bed): his thirst is the caregivers' business (water module)
local function patient(u)
  local ok, yes = pcall(function()
    if u.health and u.health.flags.needs_healthcare then return true end
    local j = u.job and u.job.current_job
    return j ~= nil and j.job_type == df.job_type.Rest
  end)
  return ok and yes == true
end

-- (e) BUG-031 (Run 11: STRANDED 'no rescue (the outside is not verified sealed)' for single citizens while the alert
-- held them in Tiefe+ without drink, no bridge in their way): citizens (soldiers and patients excluded) over a mark on
-- a walk group that has the drink or food, standing in a burrow of the sounding civ alert: the confinement keeps them
-- from it. seal marks that burrow dry when its audit finds none of it there (seal.dry), and the alert decision of this
-- step (apply) confines to a burrow that has it or turns the alert off, even in a lockdown. STRANDED relax names them
-- (once per news).
local function relax_step(K, G)
  if not mem.burrow or (alert_idx() or 0) == 0 then return end
  local bs = {}
  for _, n in ipairs(type(mem.alist) == 'table' and mem.alist or {mem.burrow}) do
    local ok, b = pcall(dfhack.burrows.findByName, n)
    if ok and b then bs[#bs + 1] = {n, b} end
  end
  if #bs == 0 then return end
  local cu = K.census.u
  local sold = {}
  for _, id in ipairs(type(cu) == 'table' and type(cu.soldier_ids) == 'table' and cu.soldier_ids or {}) do
    sold[id] = true
  end
  local by, names = {}, {}
  for _, gid in ipairs(sorted_keys(G.cit)) do
    for _, c in ipairs(G.cit[gid]) do
      local u = not sold[c[1]] and df.unit.find(c[1])
      if u and not patient(u) then
        local th, hu = counter(u, 'thirst_timer'), counter(u, 'hunger_timer')
        local nd = th > M.STRAND_THIRST and G.drink[gid] == true
        local nf = hu > M.STRAND_HUNGER and G.food[gid] == true
        if nd or nf then
          for _, e in ipairs(bs) do
            local ok, v = pcall(dfhack.burrows.isAssignedTile, e[2], {x = c[2], y = c[3], z = c[4]})
            if ok and v == true then
              local r = by[e[1]]
              if not r then
                r = {ids = {}, thirst = 0, hunger = 0, need = {}, pos = {c[2], c[3], c[4]}, g = gid}
                by[e[1]], names[#names + 1] = r, e[1]
              end
              r.ids[#r.ids + 1] = c[1]
              r.thirst, r.hunger = math.max(r.thirst, th), math.max(r.hunger, hu)
              if nd then r.need.drink = true end
              if nf then r.need.food = true end
              break
            end
          end
        end
      end
    end
  end
  for _, name in ipairs(names) do
    local r = by[name]
    table.sort(r.ids)
    local ok, marked, why = K.call('seal', 'dry', name, r.need, #r.ids)
    if ok and marked then
      stranded(K, 'relax', string.format('%d citizen%s confined to %s without %s (thirst %d, hunger %d; it is on their '
               .. 'walk group): the alert lets them out (%s)', #r.ids, #r.ids == 1 and '' or 's', name, needs_txt(r),
               r.thirst, r.hunger, tostring(why)),
               {n = #r.ids, units = r.ids, grp = r.g, thirst = r.thirst, hunger = r.hunger, pos = r.pos,
                need = needs_txt(r), burrow = name, why = 'confined'}, r.ids, {'relax', name})
    end
  end
end

-- (a) the rescue: open one, watch one, close it
local function rescue_step(K, a, g, now)
  local str = st.str
  if now - (mem.rs_t or -M.RESCUE_EVERY) < M.RESCUE_EVERY then return end
  mem.rs_t = now
  local r = str.rescue
  if r then
    local G = groups(K)
    local why
    if a and (a.inside or 0) > 0 then why = 'a hostile inside'
    elseif not outer_up(K, g) then why = 'an outer bridge is not up'
    elseif G and next(G.hostile) then
      for gid in pairs(G.hostile) do if G.cit[gid] then why = 'a hostile on the citizens\' walk group' end end
    end
    if not why then
      for _, b in ipairs(r.list) do
        local d = near_bridge(K, b)
        if d >= 0 and d <= M.CUT_NEAR then why = string.format('a hostile %d tiles from %s', d, b) end
      end
    end
    local done, left = why == nil, 0
    if not why then
      for _, id in ipairs(r.ids) do
        local u = df.unit.find(id)
        local alive = u and not (u.flags2 and u.flags2.killed)
        if alive then
          local ok_d = not r.need.drink or counter(u, 'thirst_timer') <= M.STRAND_THIRST     -- drank
          local ok_f = not r.need.food or counter(u, 'hunger_timer') <= M.STRAND_HUNGER      -- ate
          local home = false
          if mem.burrow and alert_idx() ~= 0 then
            local ok, b = pcall(dfhack.burrows.findByName, mem.burrow)
            local x, y, z = dfhack.units.getPosition(u)
            if ok and b and x then
              local ok2, v = pcall(dfhack.burrows.isAssignedTile, b, {x = x, y = y, z = z})
              home = ok2 and v == true
            end
          end
          if not ((ok_d and ok_f) or home) then left = left + 1 end
        end
      end
      done = left == 0 or now - r.since >= M.RESCUE_MAX
    end
    if why or done then
      str.rescue, dirty = nil, true
      for _, b in ipairs(r.list) do want(K, b, 'up', 'rescue_end', now + M.BREACH_AT) end
      local phase = why and 'abort' or 'done'
      local txt = why and string.format('rescue aborted (%s): raising %s again', why, table.concat(r.list, ', '))
                  or string.format('rescue over after %d ticks: %d of %d citizens through, raising %s again',
                                   now - r.since, #r.ids - left, #r.ids, table.concat(r.list, ', '))
      stranded(K, phase, txt, {grp = r.grp, n = #r.ids, units = r.ids, bridges = r.list, why = why or 'done',
               left = left}, r.ids, {phase, table.concat(r.list, ',')})
    end
    return
  end
  -- a new one: only when somebody is over a threshold (the counters are cheap; seal's group reads are not)
  local cu = K.census.u
  local any = false
  for _, id in ipairs(type(cu) == 'table' and type(cu.ids) == 'table' and cu.ids or {}) do
    local u = df.unit.find(id)
    if u and (counter(u, 'thirst_timer') > M.STRAND_THIRST or counter(u, 'hunger_timer') > M.STRAND_HUNGER) then
      any = true
      break
    end
  end
  if not any then return end
  local G = groups(K)
  if not G then return end
  relax_step(K, G)                                         -- (e) BUG-031: the confinement, not a bridge
  local e = cut_off(K, G)
  if not e then return end
  local base = string.format('%d citizens on walk group %d without %s (thirst %d, hunger %d)', #e.ids, e.g,
                             needs_txt(e), e.thirst, e.hunger)
  local d = {grp = e.g, n = #e.ids, units = e.ids, thirst = e.thirst, hunger = e.hunger, pos = e.pos,
             need = needs_txt(e)}
  local bs, gs = way(K, g, G, e.g, e.need)
  local why
  if not bs then why = 'no raised inner or core bridge leads to ' .. needs_txt(e)
  elseif a and (a.inside or 0) > 0 then why = 'a hostile inside'
  elseif not outer_up(K, g) then why = 'an outer bridge is not up'
  elseif not G.sealed then
    -- BUG-031: the way in the entrance check found (a door does not split DF's walk groups: a doored entrance is a
    -- route to the map edge; only raised bridges and walls seal for a rescue)
    why = 'the outside is not verified sealed' .. (G.leak and (': ' .. G.leak) or '')
    K.call('seal', 'entrance_doors', true)               -- a fresh check (urgent)
  else
    for _, gid in ipairs(gs) do
      if G.hostile[gid] then why = string.format('a hostile on walk group %d', gid) end
    end
  end
  if not why then
    for _, b in ipairs(bs) do
      local ok, ok2, msg = K.call('gate', 'want', b, 'down', 'rescue')
      if not (ok and ok2) then why = string.format('%s: %s', b, tostring(msg)) end
    end
  end
  if why then
    for _, b in ipairs(bs or {}) do want(K, b, 'up', 'rescue_end', now + M.BREACH_AT) end
    d.why, d.bridges = why, bs
    stranded(K, 'refused', string.format('%s: no rescue (%s)', base, why), d, e.ids, {'refused', why})
    return
  end
  str.rescue, dirty = {list = bs, grp = e.g, ids = e.ids, since = now, need = e.need}, true
  d.bridges = bs
  stranded(K, 'rescue', string.format('%s: lowering %s (outside sealed, outer gates up)', base, table.concat(bs, ', ')),
           d, e.ids, {'rescue', table.concat(bs, ',')})
end

-- a bridge a rescue holds down
local function rescuing(b)
  local r = st.str.rescue
  if not r then return false end
  for _, x in ipairs(r.list) do if x == b then return true end end
  return false
end

-- st.str.hold follows the held set of the bridges asked about (gate asks siege.held at a BREACH entry)
local function sync_holds(list, held, now)
  for _, b in ipairs(list) do
    if held[b] and not st.str.hold[b] then st.str.hold[b], dirty = now, true
    elseif not held[b] and st.str.hold[b] then st.str.hold[b], dirty = nil, true end
  end
  return held
end

-- (c) the bridges of `list` (names about to be wanted up, not up) whose raise would cut citizens off from all drink or
-- food: a set of held names; a raise goes ahead with a hostile within CUT_NEAR tiles of the bridge (STRANDED forced)
local function cut_holds(K, g, list, now)
  local held = {}
  local req = {}
  for _, b in ipairs(list) do
    local spec = g.man.bridges[b]
    if spec and not rescuing(b) then req[#req + 1] = {name = b, fp = spec.fp, role = spec.role} end
  end
  if #req == 0 then return held end
  local ok, sp, why = K.call('seal', 'split', req)
  if not (ok and type(sp) == 'table') then
    -- the answer is under way: hold for at most SPLIT_WAIT ticks (an unknown one never holds)
    if ok and why == 'pending' then
      mem.split_ask = mem.split_ask or now
      if now - mem.split_ask < M.SPLIT_WAIT then
        for _, b in ipairs(list) do held[b] = true end
      end
    end
    return sync_holds(list, held, now)
  end
  mem.split_ask = nil
  -- the way from each cut part to a part with drink and food, over the bridges of the request
  local adj = {}
  for b, ps in pairs(sp.edges or {}) do
    local l = {}
    for p in pairs(ps) do l[#l + 1] = p end
    for i = 1, #l do
      for j = 1, #l do
        if i ~= j then
          adj[l[i]] = adj[l[i]] or {}
          table.insert(adj[l[i]], {l[j], b})
        end
      end
    end
  end
  local forced = {}
  for _, pid in ipairs(sp.cut or {}) do
    local p = sp.parts[pid]
    local prev, q, h, goal = {[pid] = false}, {pid}, 1, nil
    while h <= #q and not goal do
      local cur = q[h]
      h = h + 1
      local c = sp.parts[cur]
      if cur ~= pid and c and c.drink > 0 and c.food > 0 then goal = cur end
      for _, e in ipairs(adj[cur] or {}) do
        if prev[e[1]] == nil then prev[e[1]] = {cur, e[2]}; q[#q + 1] = e[1] end
      end
    end
    local c = goal
    while c and prev[c] do
      local b = prev[c][2]
      local d = near_bridge(K, b)
      if d >= 0 and d <= M.CUT_NEAR then forced[#forced + 1] = {b, d, p}
      else held[b] = p end
      c = prev[c][1]
    end
  end
  local hs = {}
  for b in pairs(held) do hs[#hs + 1] = b; held[b] = true end
  table.sort(hs)
  if #hs > 0 then
    local ids, n = {}, 0
    for _, pid in ipairs(sp.cut) do
      for _, id in ipairs(sp.parts[pid].ids) do n = n + 1; ids[#ids + 1] = id end
    end
    stranded(K, 'hold', string.format('raising %s held: it would cut %d citizens off from drink or food; raised once a '
             .. 'hostile is within %d tiles', table.concat(hs, ', '), n, M.CUT_NEAR),
             {n = n, units = ids, bridges = hs, why = 'cut'}, ids, {'hold', table.concat(hs, ',')})
  end
  for _, f in ipairs(forced) do
    stranded(K, 'forced', string.format('%s raised although it cuts %d citizens off from drink or food: a hostile %d '
             .. 'tiles from it', f[1], f[3].n, f[2]), {n = f[3].n, units = f[3].ids, bridges = {f[1]}, why = 'hostile',
             hostile = f[2]}, f[3].ids, {'forced', f[1]})
  end
  return sync_holds(list, held, now)
end

-- (b) BREACH is over once the fort is sealed again: every outer and inner bridge up (an inner one a rescue holds down
-- excepted: the outer ones seal), seal's check after the last move says no route, no hostile inside or on a citizens'
-- walk group, SEALED_HOLD ticks long
local function breach_sealed(K, g, a, now)
  local ok = a ~= nil and (a.inside or 0) == 0 and #g.outer > 0
  if ok then
    for _, list in ipairs({g.outer, g.inner}) do
      for _, b in ipairs(list) do
        if gate_state(K, b) ~= 'up' and not (list == g.inner and rescuing(b)) then ok = false end
      end
    end
  end
  local G = ok and groups(K)
  if ok then
    ok = G ~= nil and G.sealed == true
    for gid in pairs(G and G.hostile or {}) do if G.cit[gid] then ok = false end end
  end
  if not ok then
    if st.str.bs then st.str.bs, dirty = nil, true end
    return false
  end
  st.str.bs = st.str.bs or now
  dirty = true
  return now - st.str.bs >= M.SEALED_HOLD
end

-- BUG-027 (Run 10: BREACH "O1 not up at T+900" while the pulls were under way, lever latency 11-19 s): a bridge gate
-- reports waiting (units on its footprint, or its pull under way) is no failure while no hostile is within NEAR_RAISE
-- intake waves and the sortie (Gordon 2026-10-16): a bridge they hold down (st.wd), or raise again within its deadline
-- (st.wu = the tick), is no gate failure and is not raised by the SIEGE timer
local function wave_skip(b, now)
  return st.wd[b] == true or (st.wu[b] ~= nil and now < st.wu[b])
end

local function failed_bridge(K, g)
  local h = K.census.h
  local nb = type(h) == 'table' and type(h.near_bridge) == 'table' and h.near_bridge or {}
  local now = K.now().tick
  for _, list in ipairs({g.outer, g.inner}) do
    for _, b in ipairs(list) do
      if gate_state(K, b) ~= 'up' and not wave_skip(b, now) then
        local d = nb[b]
        local okw, wait = K.call('gate', 'waiting', b)
        -- BUG-028: a raise held for citizens it would cut off (no hostile within CUT_NEAR), or a rescue's bridge
        local held = (st.str.hold[b] and not (d and d >= 0 and d <= M.CUT_NEAR)) or rescuing(b)
        if not held and not (okw and wait and not (d and d >= 0 and d <= M.NEAR_RAISE)) then return b end
      end
    end
  end
  return nil
end

-- BUG-030: the first destroyed outer or inner bridge (an open way), or nil
local function destroyed_gate(K, g)
  for _, list in ipairs({g.outer, g.inner}) do
    for _, b in ipairs(list) do if gate_state(K, b) == 'destroyed' then return b end end
  end
end

local function decide(K, a, g, now)
  local mode = K.mode()
  if mode == 'PEACE' then
    if not a then return end
    if a.siege then
      if go(K, 'SIEGE', a.siege, a) and a.inside > 0 then go(K, 'BREACH', 'inside', a) end
    elseif a.inside > 0 then
      if go(K, 'ALERT', 'inside', a) then go(K, 'BREACH', 'inside', a) end
    elseif a.hostile then go(K, 'ALERT', 'hostile', a) end
  elseif mode == 'ALERT' then
    if not a then return end
    if a.inside > 0 then go(K, 'BREACH', 'inside', a)
    elseif a.siege then go(K, 'SIEGE', a.siege, a)
    elseif a.calm then
      st.aq = st.aq or now
      if now - st.aq >= M.ALERT_QUIET then go(K, 'PEACE', 'quiet', a) end
    elseif st.aq then st.aq, dirty = nil, true end
  elseif mode == 'SIEGE' then
    if a and a.inside > 0 then go(K, 'BREACH', 'inside', a); return end
    local db = destroyed_gate(K, g)            -- BUG-030: no T+900 wait for a bridge that is gone
    if db then go(K, 'BREACH', 'destroyed', a, db); return end
    local fb = now - st.t0 >= M.BREACH_AT and failed_bridge(K, g)
    if fb then go(K, 'BREACH', 'gate_fail', a, fb)
    elseif quiet_for(a, now, M.QUIET) then go(K, 'RECOVERY', 'quiet', a) end
  elseif mode == 'BREACH' then
    if quiet_for(a, now, M.QUIET) then go(K, 'RECOVERY', 'quiet', a)
    elseif breach_sealed(K, g, a, now) then go(K, 'SIEGE', 'sealed', a) end      -- BUG-028 (b)
  elseif mode == 'RECOVERY' then
    if a and a.inside > 0 then go(K, 'BREACH', 'inside', a)
    elseif a and (a.inv > 0 or a.siege) then go(K, 'SIEGE', 'reentry', a)   -- same reach rule as entry
    else
      if a and a.quiet then st.rq = st.rq + math.max(0, now - st.rl) end   -- the clock stops otherwise
      st.rl, dirty = now, true
      if st.rq >= M.REC_PEACE then go(K, 'PEACE', 'recovered', a) end
    end
  elseif mode == 'DRILL' then
    if a and (a.siege or a.inside > 0) then
      if go(K, 'SIEGE', a.siege or 'inside', a) and a.inside > 0 then go(K, 'BREACH', 'inside', a) end
    elseif a and a.hostile then go(K, 'ALERT', 'hostile in drill', a)
    elseif not K.enabled('drill') or now - st.t0 >= M.DRILL_MAX then
      go(K, 'PEACE', 'drill timeout')          -- nobody else will end it (drill missing or stuck)
    end
  end
end

---------------------------------------------------------------- actuators (level-triggered)
-- ALERT anchors: where the citizens outside Kern+ stood when the civ alert went on (read by census
-- id, CONTRACTS §1.4). Obeying the alert takes them inside, so "near a citizen outside" stops being
-- measurable; the alert is held against these anchors (and O1) instead, which prevents flapping.
local function add_anchors(K)
  local cu = K.census.u
  local at = st.civ_at or {}
  for _, id in ipairs(type(cu) == 'table' and type(cu.outside_ids) == 'table' and cu.outside_ids or {}) do
    if #at >= M.ANCHORS then break end
    local u = df.unit.find(id)
    local x, y, z
    if u then x, y, z = dfhack.units.getPosition(u) end
    if x then
      local dup = false
      for _, p in ipairs(at) do if p[1] == x and p[2] == y and p[3] == z then dup = true; break end end
      if not dup then at[#at + 1] = {x, y, z} end
    end
  end
  st.civ_at = at
end

-- min distance from a listed hostile to the anchors or the O1 footprint centre; -1 when none
local function anchor_dist(K, g)
  local h = K.census.h
  local pts = {}
  for _, p in ipairs(st.civ_at or {}) do pts[#pts + 1] = {x = p[1], y = p[2], z = p[3]} end
  local o1 = g.man.bridges and g.man.bridges[g.outer[1]]
  if o1 then pts[#pts + 1] = geom.bbox_center(o1.fp) end
  local best = -1
  for _, e in ipairs(type(h) == 'table' and h.list or {}) do
    for _, p in ipairs(pts) do
      local d = geom.dist(e, p)
      if best < 0 or d < best then best = d end
    end
  end
  return best
end

-- the reflex lockdown wants the civ alert (FR-52), level-triggered
local function alert_held(K)
  local ok, why = K.call('reflex', 'holding', 'alert')
  return ok and type(why) == 'string' and why ~= ''
end

local function alert_wanted(K, a, g, now, held)
  if held then return true end
  local mode = K.mode()
  if mode == 'SIEGE' or mode == 'DRILL' or mode == 'BREACH' then return true end
  if mode == 'RECOVERY' then return not st.b1low end
  if mode ~= 'ALERT' then return false end
  -- ALERT: on while a hostile is <= 30 tiles from a citizen outside; held while a hostile is <= 40
  -- from a citizen still outside, an anchor or O1; off after 600 ticks beyond that
  if a then
    local d = a.near_cit
    if d >= 0 and d <= M.ALERT_CIV_ON then
      add_anchors(K)
      st.civ, st.far, dirty = true, nil, true
    elseif st.civ then
      local da = anchor_dist(K, g)
      local held = (d >= 0 and d <= M.ALERT_CIV_OFF) or (da >= 0 and da <= M.ALERT_CIV_OFF)
      if held then
        if st.far then st.far, dirty = nil, true end
      else
        st.far = st.far or now
        if now - st.far >= M.ALERT_CIV_HOLD then st.civ, st.far, st.civ_at = false, nil, nil end
        dirty = true
      end
    end
  end
  return st.civ == true
end

local function burrow_exists(name)
  local ok, b = pcall(function() return dfhack.burrows.findByName(name) end)
  return not ok or b ~= nil                -- unknown: let act decide
end

-- the alert burrow list: the mode's burrow first, then the lever rooms gate allows in this mode (live L3: in
-- BREACH the civ alert held everybody in Tiefe+ and no civilian could reach a lever, GATE_FAIL no_worker x3).
-- In BREACH gate.rooms is the B2 landing room only while B2 has no linked lever inside Tiefe+ (the fallback for
-- a fort without one); with one, the list is Tiefe+ alone and nobody is drawn toward a seal that may be down
-- BUG-013: gate adds seal's lever burrow ('Hebel+', the linked lever tiles) while a pull is pending on a bridge whose
-- levers all lie outside `burrow` and the rooms (Run 9 forced arrival: the alert held everybody in Kern+, the four
-- gate levers lay outside, their pulls stayed unclaimed); once the pulls are done it leaves the list again
local function alert_list(K, burrow)
  local l = {burrow}
  local ok, rooms = K.call('gate', 'rooms', K.mode(), burrow)
  for _, n in ipairs(ok and type(rooms) == 'table' and rooms or {}) do
    if n ~= burrow then l[#l + 1] = n end
  end
  return l
end

local function set_alert(K, on, burrow, g, now, held, audited, flee)
  local cur = alert_idx()
  if not on then
    -- BUG-011 (Run 9: on, then off 12 ticks later, every batch): while a reflex lockdown holds the alert nobody
    -- silences it; no usable burrow means the alert is not sounded, never that a sounding one is switched off.
    -- BUG-018 (the first real siege, 50 -> 1: the alert held everybody in the halls the goblins walked into): unless
    -- seal found no separated burrow at all (flee): confined, the citizens wait in the attackers' path; free, they flee
    if held and not flee then return end
    if cur ~= nil and cur ~= 0 then K.act.civ_alert(false) end
    return
  end
  -- live L1b: BREACH before fortcore stage 3 asked for Tiefe+ every RETRY (one ACT_FAIL each time); a refuge
  -- that does not exist yet means Kern+ at once. BUG-018: never for seal's pick (seal refused Kern+ for a reason)
  if not audited and burrow ~= g.kern and not burrow_exists(burrow) then burrow = g.kern end
  local list = alert_list(K, burrow)
  local sig = table.concat(list, '|')
  if mem.asig ~= sig and now >= (mem.alert_retry or now) then
    if K.act.alert_burrows(list) then mem.burrow, mem.asig, mem.alist = burrow, sig, list
    else                                   -- the burrow alone, else (e.g. no Tiefe+ yet) Kern+ beats no alert
      mem.alert_retry = now + M.RETRY
      if #list > 1 and K.act.alert_burrows({burrow}) then mem.burrow, mem.asig, mem.alist = burrow, burrow, {burrow}
      elseif not audited and burrow ~= g.kern and mem.burrow ~= g.kern and K.act.alert_burrows({g.kern}) then
        mem.burrow, mem.asig, mem.alist = g.kern, g.kern, {g.kern}
      end
    end
  end
  -- BUG-018: seal's pick could not be listed: the alert never sounds (or keeps sounding) on another, older list
  if audited and mem.burrow ~= burrow then
    if cur ~= nil and cur ~= 0 and not held then K.act.civ_alert(false) end
    return
  end
  if mem.burrow and cur == 0 and now >= (mem.civ_retry or now) then
    if not K.act.civ_alert(true) then mem.civ_retry = now + M.RETRY end
  end
end

-- BUG-011: the one decision behind the civ alert; the step (apply) and the reflex's kick (hold_alert) both use it, so
-- they can never disagree (Run 9: hold_alert sounded Kern+ without asking seal, the next step's seal answer nil
-- switched it off). FR-33/37/57: seal audits the burrow (drink, food, beds for the population; the refuge after a
-- BREACH until quiet) and may choose another one or none (nil: no confinement); a held lockdown keeps the interior
-- burrow (seal.choose). BUG-018: seal confines only to a separated burrow (or the dead end); flee = no burrow is
-- separated, the alert goes off even in a lockdown. Without seal the mode's burrow as before. Returns on, burrow, held,
-- note and brief (why not the mode's burrow, in full and short; nil when it is), audited (seal chose) and flee.
-- BUG-030: the deep defense in SIEGE asks for the separated refuge as a BREACH does (seal's BREACH level: no drink,
-- food or bed counts for breach_days; after it seal holds the refuge until back_days are quiet)
local function alert_plan(K, a, g, now)
  local held = alert_held(K)
  local mode = K.mode()
  local deep = mode == 'SIEGE' and st.deep ~= nil
  local on, burrow = alert_wanted(K, a, g, now, held), (mode == 'BREACH' or deep) and g.refuge or g.kern
  local note, brief, audited, flee
  if on then
    local okb, pick, why, short, fl = K.call('seal', 'alert_burrow', deep and 'BREACH' or mode, burrow, held)
    if okb then
      burrow, on, audited, flee = pick, pick ~= nil, true, fl == true
      note, brief = type(why) == 'string' and why or nil, type(short) == 'string' and short or nil
    end
  end
  return on, burrow, held, note, brief or note, audited, flee
end

-- var (BUG-029): the core bridges' states for the postures whose station depends on them (READY_IN, STATION_B1): a
-- change re-issues the stations at once
local function set_posture(K, P, now, var)
  var = var or ''
  if mem.posture == P and mem.pvar == var and now - mem.posture_tick < M.POSTURE_REASSERT then return end
  if mem.posture_want == P and mem.pvar_want == var and now < (mem.posture_retry or now) then return end
  mem.posture_want, mem.pvar_want = P, var
  local ok, r = K.call('military', 'posture', P)
  if ok and r ~= false then mem.posture, mem.posture_tick, mem.pvar = P, now, var
  else mem.posture_retry = now + M.RETRY end
end

-- T0..T0+600 raise rule for the outer and inner bridges. "Nobody outside" is trusted only from a
-- census taken at or after T0 (sense rescans inside the mode change); an older one may miss a
-- citizen who just walked out, and the reason is latched in st.req.
local function raise(K, g, now)
  local t = now - st.t0
  local cu, h = K.census.u, K.census.h
  local outside = type(cu) == 'table' and (cu.tick or -1) >= st.t0 and cu.outside or -1
  local nb = type(h) == 'table' and type(h.near_bridge) == 'table' and h.near_bridge or {}
  local whys, fresh = {}, {}
  for _, list in ipairs({g.outer, g.inner}) do
    for _, b in ipairs(list) do
      local why = st.req[b]
      if wave_skip(b, now) or gate_state(K, b) == 'destroyed' then why = nil      -- BUG-030: nothing to raise
      elseif not why then
        local d = nb[b]
        if outside == 0 then why = 'inside'
        elseif t >= M.RAISE_BY then why = 'timer'
        elseif d and d >= 0 and d <= M.NEAR_RAISE then why = 'hostile_near' end
        if why and gate_state(K, b) ~= 'up' and not rescuing(b) then fresh[#fresh + 1] = b end
      end
      whys[b] = why
    end
  end
  -- BUG-028 (c): a first raise that would cut citizens off from drink or food waits (until a hostile is near)
  local held = #fresh > 0 and cut_holds(K, g, fresh, now) or {}
  for _, list in ipairs({g.outer, g.inner}) do
    for _, b in ipairs(list) do
      local why = whys[b]
      if why and not held[b] and not rescuing(b) and not wave_skip(b, now)
         and want(K, b, 'up', why, st.t0 + M.BREACH_AT) and not st.req[b] then
        st.req[b], dirty = why, true
      end
    end
  end
end

-- RECOVERY: +1,200 quiet: B2 (core) down, then B1 (inner); +2,400: O1 (outer). peace_gates (D-14) up: the outer
-- and inner gates stay up (PEACE keeps them up anyway); only the core seal comes down.
local function lower(K, g)
  local q = st.rq
  local low = false
  local keep = tostring(K.cfg.decisions and K.cfg.decisions['D-14'] or 'down') == 'up'
  if q >= M.REC_INNER then
    local cores = true
    local function open(b)                    -- BUG-030: a destroyed bridge is an open way, as good as lowered
      local s = gate_state(K, b)
      return s == 'down' or s == 'destroyed'
    end
    for _, b in ipairs(g.core) do
      want(K, b, 'down', 'recovery')
      if not open(b) then cores = false end
    end
    low = cores
    if cores and not keep then
      for _, b in ipairs(g.inner) do
        want(K, b, 'down', 'recovery')
        if not open(b) then low = false end
      end
    end
  end
  if q >= M.REC_OUTER and not keep then
    for _, b in ipairs(g.outer) do want(K, b, 'down', 'recovery') end
  end
  if low ~= st.b1low then st.b1low, dirty = low, true end
end

local function on_stair(man, e)
  local stairs = type(man.stairs) == 'table' and man.stairs or {}
  for _, kind in ipairs({'civ', 'mil'}) do
    for _, c in ipairs(type(stairs[kind]) == 'table' and stairs[kind] or {}) do
      if e.x == c[1] and e.y == c[2] and e.z >= c[3] and e.z <= c[4] then return true end
    end
  end
  return false
end

-- withdraw siege's kill orders (squads back to their posture stations). military.kill({}) = clear
-- held kill orders and re-apply the posture, else posture(P, force): both are WP6 extensions of
-- CONTRACTS §7 (military keeps a running kill order as held, military.lua apply_squad).
local function withdraw(K, P, now)
  local ok, r = K.call('military', 'kill', {})
  if not (ok and r == true) then K.call('military', 'posture', P, true) end
  mem.posture, mem.posture_tick = P, now
  K.log('info', 'siege: kill orders withdrawn (no target left in a kill box)')
end

-- kill orders only on visible targets inside manifest.killboxes, never on stair/shaft tiles. An
-- ordered target that is no longer valid (dead, out of the box, out of view) replaces the order at
-- once with the remaining targets, or withdraws it when none is left; new targets every 100 ticks.
local function kills(K, g, P, now, melee)
  local h, man = K.census.h, g.man
  local boxes = type(man.killboxes) == 'table' and man.killboxes or {}
  if type(h) ~= 'table' then return end
  local ids, set = {}, {}
  for _, e in ipairs(#boxes > 0 and h.list or {}) do
    local p = {x = e.x, y = e.y, z = e.z}
    local inbox = false
    for _, kb in ipairs(boxes) do
      if type(kb.bbox) == 'table' and geom.in_bbox(p, kb.bbox) then inbox = true; break end
    end
    if inbox and not on_stair(man, e) then
      local ok, t = K.call('snapshot', 'tile', e.x, e.y, e.z)
      if not (ok and type(t) == 'table' and SHAFT[t.c]) then ids[#ids + 1] = e.id; set[e.id] = true end
    end
  end
  table.sort(ids)
  local sig = (#ids > 0 and melee) and ('m:' .. table.concat(ids, ',')) or table.concat(ids, ',')
  if sig == (mem.kill_sig or '') then return end
  local lost = false
  for id in pairs(mem.kill_set or {}) do if not set[id] then lost = true; break end end
  if #ids == 0 then
    withdraw(K, P, now)
    mem.kill_sig, mem.kill_set = nil, nil
    return
  end
  if not lost and now - (mem.kill_tick or -M.KILL_EVERY) < M.KILL_EVERY then return end
  mem.kill_tick = now
  local ok, r = K.call('military', 'kill', ids, melee and {melee = true} or nil)
  if ok and r ~= false then mem.kill_sig, mem.kill_set = sig, set
  elseif mem.kill_sig then                       -- refused: never leave the old order running
    withdraw(K, P, now)
    mem.kill_sig, mem.kill_set = nil, nil
  end
end

---------------------------------------------------------------- intake waves and the sortie through O1 (Gordon 2026-10-16)
-- Run 10 y419 (Handlelock): 47 goblins waited for weeks in front of the raised O1; the trap hall and the killing field
-- were never used, and no soldier could be sent out (squad.sortie only issued orders, `lever` is PEACE-only). Gordon's
-- decision: intake waves by default in SIEGE (config/reflex.json `intake`) and an approved sortie through O1.
-- Intake (st.ik.ph), SIEGE only, one step per siege pass:
--   idle    O1/B1 up, every squad at the inner station (READY_IN, BUG-029). Each pass checks the preconditions:
--           fortcore manifest (outer, inner, a killbox, zones Z1 and Z2; Kern+ covering none of that intake area: a
--           hostile on Kern+ is a BREACH), SIEGE for `stable` ticks, no STRANDED rescue
--           or raise hold, no sortie, every outer and inner bridge up, the civ alert sounding, no civilian in the intake
--           area (Z1, Z2, killboxes), no hostile there or past B1, no dangerous hostile in sight (sense dz: a great
--           danger, a building destroyer, trap avoider or flier by the caste raws), soldiers >= min_soldiers, worn >=
--           `worn`, visible hostiles <= army_ratio x soldiers, every trap of the intake area armed (snapshot.traps,
--           '?' when unreadable). A refusal is INTAKE refused (B), once per reason (util/cadence); waits (the siege
--           is young, a bridge still rises, a sortie, nobody in sight) only set state wave.why.
--   muster  posture INTAKE (melee to the field, crossbows to the gallery); a core bridge that is up (after a BREACH)
--           and B1 go down ('intake'; O1 stays up: the airlock, gate enforces it too); once the soldiers stand on
--           station (all of them, or min_soldiers after half of `muster`) and no civilian is in the area, B1 rises
--           again, and once it is up: open. `muster` ticks, a hostile in the area or a danger: back (abort).
--   open    O1 down ('intake'; BUG-027's footprint rules hold). Close (O1 up, raising onto hostiles is fine, gate never
--           raises onto our units) when the hostiles in the intake area reach min(wave, soldiers on station), the
--           wave's losses reach `losses` (WAVE_FAIL), a dangerous hostile is within danger_dist of O1, the soldiers on
--           station fall below min_soldiers, worn drops below `worn`, or nobody came within IK_OPEN_MAX ticks.
--   fight   O1 up; kill orders on the hostiles in the killboxes to the crossbows and to the melee in the field. The
--           field is clear once no visible hostile is left in the intake area -> back. `fight` ticks without a clear
--           field: WAVE_FAIL stuck (B1 never opens while hostiles are in the area; the squads stay).
--   back    posture READY_IN; B1 down (O1 up, the area clear) until no soldier is left in the area or near the
--           gallery (or IK_BACK_MAX ticks), then B1 up -> cool.
--   cool    `cooldown` ticks for drink, food and rest -> idle.
--   stray   (BUG-029, also with intake off) idle with O1 and B1 up, the area clear and soldiers outside B1 (a raise at
--           T0 caught them, a restart): B1 down until they are in (or IK_BACK_MAX), then up -> idle. Soldiers between
--           B1 and B2 (zone Z3) while the core seal is up (BREACH -> SIEGE leaves it up): B2 goes down once, the
--           mode table's SIEGE state (INTAKE unseal).
-- Hostiles in the intake area are expected while a wave or a sortie runs: siege's BREACH needs a hostile on Kern+
-- (unchanged), and reflex skips them for INTRUDER (siege.expects); a hostile past B1 (sense zone 2: Kern+, Z3, Z4)
-- during a wave is WAVE_FAIL past_b1 and, on Kern+, BREACH as before. Leaving SIEGE ends a wave or a sortie at once.
-- Sortie (st.so), inbox squad.sortie with `gate` (approved), SIEGE only (siege.sortie checks and answers):
--   gather  the squad stands in the bailey (stations.bailey, else the centre of Z1; a held order, military.hold_order);
--           B1 down while somebody still has to come through (O1 up), B1 up once all are in the bailey -> open
--   open    O1 down ('sortie') -> out once it is down
--   out     kill order on the visible hostiles within `near` tiles of the target (else a move there); recall on losses
--           >= `losses` (WAVE_FAIL), no target left, `max_ticks`, a dangerous hostile in sight or a hostile past B1
--   recall  back to the bailey; O1 up once every member is in the bailey, or at once when a hostile is within
--           gate.force_near tiles of O1 or after `max_ticks` (WAVE_FAIL left_outside names who stays outside)
--   close   O1 up -> home: the squad is released (READY_IN), B1 down until nobody is left in the area, B1 up -> done.
-- Never O1 and B1 down at once while hostiles are visible: siege sequences them, gate refuses an intake/sortie 'down'
-- that would open both sides (the airlock).
M.IK = {on = true, wave = 6, min_soldiers = 4, worn = 80, army_ratio = 4, cooldown = 1200, danger_dist = 20,
        stable = 600, losses = 1, muster = 1200, fight = 4800}
M.IK_LIM = {wave = {1, 40}, min_soldiers = {1, 30}, worn = {0, 100}, army_ratio = {1, 50}, cooldown = {0, 33600},
            danger_dist = {0, 200}, stable = {0, 33600}, losses = {1, 30}, muster = {100, 33600}, fight = {300, 100800}}
M.SO = {worn = 80, losses = 1, max_ticks = 2400, gather = 1200, foe_cv = 10, near = 10}
M.SO_LIM = {worn = {0, 100}, losses = {1, 30}, max_ticks = {300, 33600}, gather = {100, 33600}, foe_cv = {0, 100},
            near = {1, 50}}
M.IK_OPEN_MAX, M.IK_BACK_MAX, M.IK_TRAPS_EVERY, M.SO_RETARGET = 2400, 1200, 600, 100
M.IK_IDLE_TTL, M.IK_STRAY_EVERY = 300, 100     -- idle: the KPI and the stray check are read this often at most
local IK_BUSY = {muster = true, open = true, fight = true, back = true, stray = true}
local IK_FIELD = {muster = true, open = true, fight = true}            -- posture INTAKE
local IK_SILENT = {stable = true, gate = true, sortie = true, none = true, census = true, stranded = true}

-- config/reflex.json `intake` / `sortie` (fail-open: a bad value is the default; dfpilot.lint --config warns)
local function cfg_block(K, key, def, lim)
  local r = type(K.cfg.reflex) == 'table' and type(K.cfg.reflex[key]) == 'table' and K.cfg.reflex[key] or {}
  local c = {}
  for k, v in pairs(def) do
    local x = r[k]
    if type(v) == 'boolean' then
      if type(x) == 'boolean' then c[k] = x else c[k] = v end
    else
      x = int(x)
      local l = lim[k]
      c[k] = (x and l and x >= l[1] and x <= l[2]) and x or v
    end
  end
  return c
end
local function ik_cfg(K) return cfg_block(K, 'intake', M.IK, M.IK_LIM) end
local function so_cfg(K) return cfg_block(K, 'sortie', M.SO, M.SO_LIM) end

-- BUG-030: the deep defense's reasons, in a fixed order ('destroyers,army,weak'), '' while it is off
local DEEP_WHY = {'destroyers', 'army', 'weak'}
local function deep_txt()
  local r = {}
  for _, w in ipairs(DEEP_WHY) do if st.deep and st.deep.why[w] then r[#r + 1] = w end end
  return table.concat(r, ',')
end

local function in_boxes(boxes, x, y, z)
  for _, b in ipairs(boxes) do
    if x >= b[1] and x <= b[4] and y >= b[2] and y <= b[5] and z >= b[3] and z <= b[6] then return true end
  end
  return false
end

local function posp(p)
  if type(p) ~= 'table' then return nil end
  local x, y, z = int(p[1] or p.x), int(p[2] or p.y), int(p[3] or p.z)
  if x and y and z then return {x, y, z} end
end

-- the civilians (census.u outside_ids: not soldiers, not on Kern+ or the refuge) standing in `boxes`; by id only
local function civ_in(K, boxes)
  local cu = K.census.u
  local n = 0
  for _, id in ipairs(type(cu) == 'table' and type(cu.outside_ids) == 'table' and cu.outside_ids or {}) do
    local u = df.unit.find(id)
    local x, y, z
    if u then x, y, z = dfhack.units.getPosition(u) end
    if x and in_boxes(boxes, x, y, z) then n = n + 1 end
  end
  return n
end

-- military.kpi (worn, soldiers on station: a pass over the squads' gear); `ttl` ticks of siege's own cache while idle
-- (kernel cost on a big fort), fresh (military's 25) while a wave runs
local function mil_kpi(K, ttl)
  local now = K.now().tick
  local c = mem.kpi
  if ttl and c and now >= c.t and now - c.t < ttl then return c.k end
  local ok, k = K.call('military', 'kpi')
  k = ok and type(k) == 'table' and k or nil
  mem.kpi = {t = now, k = k}
  return k
end

local function all_state(K, list, want_s)
  if #list == 0 then return false end
  for _, b in ipairs(list) do if gate_state(K, b) ~= want_s then return false end end
  return true
end

-- the wave's own wants: down (st.wd, never raised by the SIEGE timer) and up again (st.wu: no gate failure before its
-- deadline)
local function wave_down(K, list, why)
  local ok = true
  for _, b in ipairs(list) do
    local okc, ok2 = K.call('gate', 'want', b, 'down', why)
    if okc and ok2 == true then st.wd[b], st.wu[b], dirty = true, nil, true else ok = false end
  end
  return ok
end
local function wave_up(K, list, why, now)
  for _, b in ipairs(list) do
    if st.wd[b] or not st.wu[b] then st.wu[b] = now + M.BREACH_AT end
    st.wd[b], dirty = nil, true
    want(K, b, 'up', why, now + M.BREACH_AT)
  end
end
local function wave_settle(K)            -- a bridge the wave raised is up: the SIEGE rules take it back
  for b in pairs(st.wu) do
    if gate_state(K, b) == 'up' then st.wu[b], dirty = nil, true end
  end
end

local function ik_event(K, phase, txt, d)
  d = d or {}
  d.phase, d.wave = phase, st.ik.n
  K.emit('INTAKE', 'B', txt:sub(1, 200), d)
  K.log('info', 'siege: intake %s', txt:sub(1, 200))
end

-- WAVE_FAIL (A), once per wave (or sortie) and reason
local function wave_fail(K, rec, kind, why, txt, d)
  rec.fails = rec.fails or {}
  if rec.fails[why] then return end
  rec.fails[why], dirty = true, true
  d = d or {}
  d.kind, d.why = kind, why
  K.emit('WAVE_FAIL', 'A', txt:sub(1, 200), d)
  K.log('warn', 'siege: %s', txt:sub(1, 200))
end

local function ik_phase(K, ph, now)
  st.ik.ph, st.ik.t, st.ik.raise, dirty = ph, now, nil, true
end

-- the intake area plus a 3-tile box around the gallery: where soldiers of a wave may still stand
local function out_boxes(g)
  local r = {}
  for _, b in ipairs(g.zin) do r[#r + 1] = b end
  local gp = posp(g.stations.gallery)
  if gp then r[#r + 1] = {gp[1] - 3, gp[2] - 3, gp[3], gp[1] + 3, gp[2] + 3, gp[3]} end
  return r
end

-- armed traps of the intake area, cached IK_TRAPS_EVERY ticks: n, armed (nil: unreadable)
local function ik_traps(K, g, now)
  local c = mem.traps
  if c and now >= c.t and now - c.t < M.IK_TRAPS_EVERY then return c.n, c.armed end
  local ok, n, armed = K.call('snapshot', 'traps', g.zin)
  mem.traps = {t = now, n = ok and int(n) or nil, armed = ok and int(armed) or nil}
  return mem.traps.n, mem.traps.armed
end

-- tiles of the intake area on Kern+ (a hostile there is 'inside': BREACH), counted at most every 6,000 ticks and over
-- at most 4,000 tiles; -1 unknown (no Kern+)
local function kern_overlap(K, g, now)
  local c = mem.kov
  if c and now >= c.t and now - c.t < 6000 then return c.n end
  local n, seen = -1, 0
  local ok, kb = pcall(dfhack.burrows.findByName, g.kern)
  if ok and kb then
    n = 0
    for _, b in ipairs(g.zin) do
      for z = b[3], b[6] do
        for y = b[2], b[5] do
          for x = b[1], b[4] do
            seen = seen + 1
            if seen > 4000 then break end
            local ok2, v = pcall(dfhack.burrows.isAssignedTile, kb, {x = x, y = y, z = z})
            if ok2 and v == true then n = n + 1 end
          end
        end
      end
    end
  end
  mem.kov = {t = now, n = n}
  return n
end

-- why no wave may start now: reason text and token, or nil
local function ik_refuse(K, a, g, now, c)
  if #g.outer == 0 or #g.inner == 0 or #g.kb == 0 then return 'no fortcore O1/B1/killbox in the manifest', 'geometry' end
  if #g.z1 == 0 or #g.z2 == 0 then return 'the manifest has no zones Z1/Z2 (bailey, trap hall)', 'geometry' end
  local kov = kern_overlap(K, g, now)
  if kov > 0 then
    return string.format('%s covers %d tiles of the bailey, trap hall or field (a wave there is a BREACH)', g.kern, kov),
           'kern'
  end
  if now - st.t0 < c.stable then return string.format('the siege is %d ticks old (< %d)', now - st.t0, c.stable), 'stable' end
  if st.str.rescue or next(st.str.hold) then return 'a STRANDED rescue or raise hold runs', 'stranded' end
  if st.so then return 'a sortie is out', 'sortie' end
  for _, list in ipairs({g.outer, g.inner}) do
    for _, b in ipairs(list) do
      if gate_state(K, b) ~= 'up' then return b .. ' is not up', 'gate' end
    end
  end
  if not (a and a.fresh) then return 'no fresh hostile census', 'census' end
  if (alert_idx() or 0) == 0 then return 'the civ alert is not sounding', 'alert' end
  local nc = civ_in(K, g.zin)
  if nc > 0 then return string.format('%d civilians in the bailey, trap hall or killing field', nc), 'civ' end
  if (a.inside or 0) > 0 or (a.zpast or 0) > 0 then return 'a hostile past B1', 'past' end
  if (a.zin or 0) > 0 then return string.format('%d hostiles still in the bailey, trap hall or field', a.zin), 'field' end
  if (a.dz or 0) > 0 then return string.format('%d dangerous hostiles in sight (great danger, building destroyer, trap ' ..
                                               'avoider or flier)', a.dz), 'danger' end
  if (a.vis or 0) == 0 then return 'no hostile in sight', 'none' end
  local k = mil_kpi(K, M.IK_IDLE_TTL)
  local sol, worn = k and int(k.soldiers) or 0, k and int(k.worn) or 0
  if sol < c.min_soldiers then return string.format('%d soldiers < %d', sol, c.min_soldiers), 'soldiers' end
  if worn < c.worn then return string.format('worn %d%% < %d%%', worn, c.worn), 'worn' end
  if a.vis > c.army_ratio * sol then
    return string.format('%d hostiles in sight > %d x %d soldiers', a.vis, c.army_ratio, sol), 'army'
  end
  -- BUG-030: the deep defense holds every squad in the core
  if st.deep then return 'deep defense (' .. deep_txt() .. '): the squads hold the core', 'deep' end
  local tn, ta = ik_traps(K, g, now)
  if tn and ta and ta < tn then return string.format('traps re-arming: %d of %d armed', ta, tn), 'traps' end
  return nil
end

local function ik_back(K, now, why, txt)
  ik_phase(K, 'back', now)
  ik_event(K, why, txt, {why = why})
end

-- one intake pass (SIEGE)
local function intake_step(K, a, g, now)
  local ik = st.ik
  local c = ik_cfg(K)
  wave_settle(K)
  local ph = ik.ph
  if ph == 'cool' then
    if now - ik.t >= c.cooldown then ik_phase(K, 'idle', now) else return end
    ph = 'idle'
  end
  if ph == 'stray' then
    local okm, n_out = K.call('military', 'members_in', nil, out_boxes(g), true)
    if (a and (a.zin or 0) + (a.inside or 0) + (a.zpast or 0) > 0) or not all_state(K, g.outer, 'up') then
      wave_up(K, g.inner, 'intake', now)                 -- hostiles in the area or O1 not up: B1 up at once
      ik_phase(K, 'idle', now)
      return
    end
    if not ik.raise and ((okm and (int(n_out) or 0) == 0 and all_state(K, g.inner, 'down'))
                         or now - ik.t >= M.IK_BACK_MAX) then
      ik.raise, ik.left, dirty = true, okm and int(n_out) or 0, true
      wave_up(K, g.inner, 'intake', now)
    elseif ik.raise and all_state(K, g.inner, 'up') then
      local left = ik.left or 0
      ik_phase(K, 'idle', now)
      if left > 0 then ik.sn = now + 4 * M.IK_BACK_MAX end     -- they did not come: not again at once
      ik_event(K, 'back', string.format('soldiers inside, %s up again%s', table.concat(g.inner, ', '),
               left > 0 and string.format(' (%d still outside)', left) or ''), {why = 'stray', soldiers = left})
    end
    return
  end
  if ph == 'idle' then
    -- BUG-029: soldiers outside B1 between waves (a raise at T0 caught them, a restart) come in through the airlock;
    -- soldiers between B1 and the raised core seal get it lowered (SIEGE keeps B2 down)
    if #g.outer > 0 and #g.inner > 0 and #g.zin > 0 and now >= (ik.sn or 0)
       and now - (mem.stray_t or -M.IK_STRAY_EVERY) >= M.IK_STRAY_EVERY and a and a.fresh and (a.zin or 0) == 0
       and (a.inside or 0) + (a.zpast or 0) == 0 and all_state(K, g.outer, 'up') and all_state(K, g.inner, 'up')
       and not st.str.rescue and not st.so then
      mem.stray_t = now
      local okm, n_out = K.call('military', 'members_in', nil, out_boxes(g), true)
      if okm and (int(n_out) or 0) > 0 then
        local downs = {}
        for _, b in ipairs(g.core) do if gate_state(K, b) == 'up' then downs[#downs + 1] = b end end
        for _, b in ipairs(g.inner) do downs[#downs + 1] = b end
        if wave_down(K, downs, 'intake') then
          for _, b in ipairs(g.core) do st.wd[b] = nil end    -- the core seal stays down (SIEGE)
          ik_phase(K, 'stray', now)
          return ik_event(K, 'stray', string.format('%d soldiers outside %s between waves: %s down to let them in ' ..
                          '(%s up)', n_out, table.concat(g.inner, ', '), table.concat(downs, ', '),
                          table.concat(g.outer, ', ')), {soldiers = int(n_out)})
        end
      end
      local ups = {}
      for _, b in ipairs(g.core) do if gate_state(K, b) == 'up' then ups[#ups + 1] = b end end
      if #ups > 0 and #g.z3 > 0 then
        local okz, n_z3 = K.call('military', 'members_in', nil, g.z3, true)
        if okz and (int(n_z3) or 0) > 0 and wave_down(K, ups, 'intake') then
          for _, b in ipairs(ups) do st.wd[b] = nil end      -- the SIEGE state: it stays down
          ik_event(K, 'unseal', string.format('%d soldiers between %s and %s without drink: %s down (SIEGE keeps ' ..
                   'the core seal down)', n_z3, table.concat(g.inner, ', '), table.concat(ups, ', '),
                   table.concat(ups, ', ')), {soldiers = int(n_z3)})
        end
      end
    end
    if not c.on then
      if ik.why ~= 'off' then ik.why, dirty = 'off', true end
      return
    end
    local why, tok = ik_refuse(K, a, g, now, c)
    if why then
      if ik.why ~= why:sub(1, 40) then ik.why, dirty = why:sub(1, 40), true end
      if not IK_SILENT[tok] and CAD.due(ik.rec, K.now(), {}, {tok}, {ticks = 1200, wall_s = 60}) then
        ik.rec, dirty = CAD.mark(K.now(), {}, {tok}), true
        ik_event(K, 'refused', 'no intake wave: ' .. why, {why = tok})
      end
      return
    end
    local k = mil_kpi(K) or {}
    ik.n, ik.why = ik.n + 1, nil
    ik.lost0, ik.killed0, ik.fails, ik.rec = st.ep and st.ep.lost or 0, st.ep and st.ep.killed or 0, nil, CAD.quiet(ik.rec)
    ik_phase(K, 'muster', now)
    local downs = {}
    for _, b in ipairs(g.core) do
      local cs = gate_state(K, b)
      if cs == 'up' or cs == 'moving' then downs[#downs + 1] = b end
    end
    for _, b in ipairs(g.inner) do downs[#downs + 1] = b end
    wave_down(K, downs, 'intake')
    for _, b in ipairs(g.core) do st.wd[b] = nil end      -- the core seal stays down (the SIEGE state)
    local tn, ta = ik_traps(K, g, now)
    ik_event(K, 'muster', string.format('wave %d: %d soldiers to the killing field, %s down; %d hostiles in sight, traps %s',
             ik.n, int(k.soldiers) or 0, table.concat(downs, ', '), a.vis or 0,
             tn and string.format('%d/%d armed', ta or 0, tn) or '?'),
             {soldiers = int(k.soldiers), worn = int(k.worn), traps = tn, armed = ta})
    return
  end
  local k = mil_kpi(K) or {}
  local on, sol, worn = int(k.on_station) or 0, int(k.soldiers) or 0, int(k.worn) or 0
  local lost = (st.ep and st.ep.lost or 0) - (ik.lost0 or 0)
  local zin, past = a and a.zin or 0, a and ((a.inside or 0) + (a.zpast or 0)) or 0
  if past > 0 then
    wave_fail(K, ik, 'intake', 'past_b1', string.format('wave %d: %d hostiles past B1', ik.n, past),
              {wave = ik.n, n = past})
  end
  if lost >= c.losses and (ph == 'open' or ph == 'fight' or ph == 'back') then
    wave_fail(K, ik, 'intake', 'losses', string.format('wave %d: %d citizens lost (limit %d), O1 up', ik.n, lost,
              c.losses), {wave = ik.n, lost = lost})
  end
  if ph == 'muster' then
    local bad = (zin > 0 and 'hostiles in the area') or (past > 0 and 'a hostile past B1')
                or ((a and a.dz or 0) > 0 and 'a dangerous hostile in sight')
                or (sol < c.min_soldiers and 'too few soldiers') or (worn < c.worn and 'worn too low')
    if bad or now - ik.t >= c.muster then
      if zin > 0 or past > 0 then wave_up(K, g.inner, 'intake', now) end   -- else back takes them in with B1 down
      return ik_back(K, now, 'abort', string.format('wave %d not started: %s', ik.n,
                     bad or string.format('%d of %d soldiers on station after %d ticks', on, sol, now - ik.t)))
    end
    if not ik.raise then
      if not st.wd[g.inner[1]] then wave_down(K, g.inner, 'intake') end
      local ready = sol > 0 and (on >= sol or (on >= c.min_soldiers and now - ik.t >= c.muster // 2))
      if ready and civ_in(K, g.zin) == 0 then
        ik.raise, dirty = true, true
        wave_up(K, g.inner, 'intake', now)
      end
    elseif all_state(K, g.inner, 'up') then
      if wave_down(K, g.outer, 'intake') then
        ik_phase(K, 'open', now)
        ik.size, dirty = math.max(1, math.min(c.wave, on)), true
        ik_event(K, 'open', string.format('wave %d: %s down for up to %d hostiles (%d soldiers on station, worn %d%%)',
                 ik.n, table.concat(g.outer, ', '), ik.size, on, worn),
                 {size = ik.size, on_station = on, soldiers = sol, worn = worn})
      end
    end
    return
  end
  if ph == 'open' then
    local why
    if zin >= (ik.size or c.wave) then why = string.format('%d hostiles inside (wave %d)', zin, ik.size or c.wave)
    elseif lost >= c.losses then why = string.format('%d lost', lost)
    elseif past > 0 then why = 'a hostile past B1'
    elseif (a and a.dz_o1 or -1) >= 0 and a.dz_o1 <= c.danger_dist then
      why = string.format('a dangerous hostile %d tiles from O1', a.dz_o1)
    elseif on < c.min_soldiers then why = string.format('%d soldiers on station < %d', on, c.min_soldiers)
    elseif worn < c.worn then why = string.format('worn %d%% < %d%%', worn, c.worn)
    elseif now - ik.t >= M.IK_OPEN_MAX then why = string.format('nobody came for %d ticks', now - ik.t) end
    if why then
      wave_up(K, g.outer, 'intake', now)
      ik_phase(K, 'fight', now)
      ik_event(K, 'close', string.format('wave %d: %s up: %s', ik.n, table.concat(g.outer, ', '), why),
               {why = why:sub(1, 60), inside = zin, size = ik.size, lost = lost})
    end
    return
  end
  if ph == 'fight' then
    if zin == 0 and past == 0 and all_state(K, g.outer, 'up') then
      ik_phase(K, 'back', now)
      ik_event(K, 'clear', string.format('wave %d: field clear after %d ticks, %d killed, %d lost; squads back inside',
               ik.n, now - ik.t, (st.ep and st.ep.killed or 0) - (ik.killed0 or 0), lost),
               {killed = (st.ep and st.ep.killed or 0) - (ik.killed0 or 0), lost = lost})
    elseif now - ik.t >= c.fight then
      wave_fail(K, ik, 'intake', 'stuck', string.format('wave %d: %d hostiles still in the bailey, trap hall or field ' ..
                'after %d ticks; B1 stays up', ik.n, zin, now - ik.t), {wave = ik.n, n = zin, ticks = now - ik.t})
    end
    return
  end
  if ph == 'back' then
    if zin > 0 or past > 0 or not all_state(K, g.outer, 'up') then
      if not all_state(K, g.inner, 'up') or st.wd[g.inner[1]] then wave_up(K, g.inner, 'intake', now) end
      if zin > 0 and all_state(K, g.outer, 'up') then ik_phase(K, 'fight', now) end   -- they fight again
      return
    end
    if not ik.raise then
      if not st.wd[g.inner[1]] and not all_state(K, g.inner, 'down') then wave_down(K, g.inner, 'intake') end
      local ok, n_in = K.call('military', 'members_in', nil, out_boxes(g))
      if (ok and (int(n_in) or 0) == 0 and all_state(K, g.inner, 'down')) or now - ik.t >= M.IK_BACK_MAX then
        ik.raise, dirty = true, true
        wave_up(K, g.inner, 'intake', now)
      end
    elseif all_state(K, g.inner, 'up') then
      ik_phase(K, 'cool', now)
      ik_event(K, 'back', string.format('wave %d done: squads inside, %s up; next wave in %d ticks at the earliest',
               ik.n, table.concat(g.inner, ', '), c.cooldown), {ticks = c.cooldown})
    end
  end
end

---------------------------------------------------------------- the sortie through O1
local function so_event(K, phase, txt, d)
  d = d or {}
  d.phase, d.squad = phase, st.so and st.so.sq or d.squad
  K.emit('SORTIE', 'B', txt:sub(1, 200), d)
  K.log('info', 'siege: sortie %s', txt:sub(1, 200))
end

local function so_phase(K, ph, now) st.so.ph, st.so.t, st.so.raise, dirty = ph, now, nil, true end

local function bailey(g)
  local p = posp(g.stations.bailey)
  if p then return p end
  local b = g.z1[1]
  if b then local c = geom.bbox_center(b); return {c.x, c.y, c.z} end
end

-- where the squad gathers: the Z1 boxes, else a 3-tile box around the bailey station
local function bailey_boxes(g, p)
  if #g.z1 > 0 then return g.z1 end
  return {{p[1] - 3, p[2] - 3, p[3], p[1] + 3, p[2] + 3, p[3]}}
end

-- visible hostiles within `near` tiles of the target (census.h.list)
local function foes(K, tgt, near)
  local h = K.census.h
  local r = {}
  for _, e in ipairs(type(h) == 'table' and h.list or {}) do
    if math.max(math.abs(e.x - tgt[1]), math.abs(e.y - tgt[2]), math.abs(e.z - tgt[3])) <= near then r[#r + 1] = e.id end
  end
  table.sort(r)
  return r
end

local function force_near(K)
  local r = type(K.cfg.reflex) == 'table' and type(K.cfg.reflex.gate) == 'table' and K.cfg.reflex.gate or {}
  local fn = int(r.force_near)
  if not fn or fn < 0 or fn > 30 then fn = 3 end
  return fn
end

local function so_end(K, why, txt)
  local so = st.so
  K.call('military', 'release', so.sq)
  so_event(K, why, txt, {why = why})
  st.so, dirty = nil, true
end

-- one sortie pass (SIEGE)
local function sortie_step(K, a, g, now)
  local so = st.so
  if not so then return end
  local c = so_cfg(K)
  local gname = so.gate
  local lost = (st.ep and st.ep.lost or 0) - (so.lost0 or 0)
  local zin, past = a and a.zin or 0, a and ((a.inside or 0) + (a.zpast or 0)) or 0
  local dz = a and a.dz or 0
  local at = so.at
  if lost >= c.losses and so.ph ~= 'gather' and so.ph ~= 'home' then
    wave_fail(K, so, 'sortie', 'losses', string.format('sortie %s: %d citizens lost (limit %d): recall', so.sq, lost,
              c.losses), {squad = so.sq, lost = lost})
  end
  if so.ph == 'gather' then
    K.call('military', 'hold_order', so.sq, {kind = 'station', pos = at}, 'sortie')
    if zin > 0 or past > 0 or dz > 0 or now - so.t >= c.gather then
      if zin > 0 or past > 0 then wave_up(K, g.inner, 'sortie', now) end   -- else home takes them in with B1 down
      so_phase(K, 'home', now)
      K.call('military', 'release', so.sq)
      return so_event(K, 'abort', string.format('sortie %s not started: %s', so.sq,
                      (zin > 0 and 'hostiles in the area') or (past > 0 and 'a hostile past B1')
                      or (dz > 0 and 'a dangerous hostile in sight') or 'the squad did not gather in time'))
    end
    local _, n_in, n = K.call('military', 'members_in', so.sq, bailey_boxes(g, at))
    n_in, n = int(n_in) or 0, int(n) or 0
    if not so.raise then
      if n > 0 and n_in >= n then
        so.raise, dirty = true, true
        wave_up(K, g.inner, 'sortie', now)
      elseif not st.wd[g.inner[1]] then wave_down(K, g.inner, 'sortie') end
    elseif all_state(K, g.inner, 'up') then
      if wave_down(K, {gname}, 'sortie') then
        so_phase(K, 'open', now)
        so_event(K, 'open', string.format('sortie %s: %d in the bailey, %s down', so.sq, n, gname), {n = n})
      end
    end
    return
  end
  if so.ph == 'open' then
    if dz > 0 or past > 0 or lost >= c.losses or now - so.t >= c.gather then
      wave_up(K, {gname}, 'sortie', now)
      so_phase(K, 'recall', now)
      return so_event(K, 'recall', string.format('sortie %s: recalled before it went out', so.sq))
    end
    if gate_state(K, gname) == 'down' then
      so_phase(K, 'out', now)
      so.out = now
      so_event(K, 'out', string.format('sortie %s: %s down, out to %d,%d,%d', so.sq, gname, so.tgt[1], so.tgt[2],
               so.tgt[3]), {pos = so.tgt})
    end
    return
  end
  if so.ph == 'out' then
    local ids = foes(K, so.tgt, c.near)
    local why
    if lost >= c.losses then why = string.format('%d lost', lost)
    elseif dz > 0 then why = 'a dangerous hostile in sight'
    elseif past > 0 then why = 'a hostile past B1'
    elseif #ids == 0 and now - so.out >= M.SO_RETARGET then why = 'no target left'
    elseif now - so.out >= c.max_ticks then why = string.format('time (%d ticks)', now - so.out) end
    if why then
      so_phase(K, 'recall', now)
      K.call('military', 'hold_order', so.sq, {kind = 'station', pos = at}, 'sortie')
      return so_event(K, 'recall', string.format('sortie %s: recall (%s), %d killed, %d lost', so.sq, why,
                      (st.ep and st.ep.killed or 0) - (so.killed0 or 0), lost),
                      {why = why:sub(1, 60), lost = lost, killed = (st.ep and st.ep.killed or 0) - (so.killed0 or 0)})
    end
    if #ids > 0 then K.call('military', 'hold_order', so.sq, {kind = 'kill', units = ids}, 'sortie')
    else K.call('military', 'hold_order', so.sq, {kind = 'station', pos = so.tgt}, 'sortie') end
    return
  end
  if so.ph == 'recall' then
    K.call('military', 'hold_order', so.sq, {kind = 'station', pos = at}, 'sortie')
    local _, n_in, n, _, outs = K.call('military', 'members_in', so.sq, bailey_boxes(g, at))
    n_in, n = int(n_in) or 0, int(n) or 0
    local d = near_bridge(K, gname)
    local fn = force_near(K)
    local forced = (d >= 0 and d <= fn) and string.format('a hostile %d tiles from %s', d, gname)
                   or (now - so.t >= c.max_ticks and string.format('%d ticks', now - so.t)) or nil
    if n_in >= n or forced then
      wave_up(K, {gname}, 'sortie', now)
      if n_in < n then
        wave_fail(K, so, 'sortie', 'left_outside', string.format('sortie %s: %s raised with %d of %d members outside (%s)',
                  so.sq, gname, n - n_in, n, forced), {squad = so.sq, units = outs, n = n - n_in})
      end
      so_phase(K, 'close', now)
    end
    return
  end
  if so.ph == 'close' then
    if gate_state(K, gname) == 'up' then
      K.call('military', 'release', so.sq)
      so_phase(K, 'home', now)
      so_event(K, 'close', string.format('sortie %s: %s up, back inside through %s', so.sq, gname,
               table.concat(g.inner, ', ')))
    end
    return
  end
  if so.ph == 'home' then
    if zin > 0 or past > 0 or not all_state(K, g.outer, 'up') then
      if st.wd[g.inner[1]] or not all_state(K, g.inner, 'up') then wave_up(K, g.inner, 'sortie', now) end
      return
    end
    if not so.raise then
      if not st.wd[g.inner[1]] and not all_state(K, g.inner, 'down') then wave_down(K, g.inner, 'sortie') end
      local _, n_in = K.call('military', 'members_in', so.sq, out_boxes(g))
      if ((int(n_in) or 0) == 0 and all_state(K, g.inner, 'down')) or now - so.t >= c.gather then
        so.raise, dirty = true, true
        wave_up(K, g.inner, 'sortie', now)
      end
    elseif all_state(K, g.inner, 'up') then
      so_end(K, 'done', string.format('sortie %s done: %d killed, %d lost', so.sq,
             (st.ep and st.ep.killed or 0) - (so.killed0 or 0), lost))
    end
  end
end

-- public (military's squad.sortie with args.gate, approved): start a sortie through that outer bridge. Returns ok, msg
-- (the reply: the squad's combat value against the estimate of the target group, worn, or why not)
function M.sortie(K, args, cmd_id)
  local now = K.now().tick
  local g = geometry(K)
  local c = so_cfg(K)
  local key, gname = args and args.squad, args and args.gate
  if K.mode() ~= 'SIEGE' then
    return false, string.format('a sortie through %s runs in SIEGE only (mode %s)', tostring(gname), K.mode())
  end
  local spec = g.man.bridges and g.man.bridges[gname]
  if not (type(spec) == 'table' and spec.role == 'outer' and type(spec.fp) == 'table') then
    return false, tostring(gname) .. ' is no outer manifest bridge'
  end
  if st.so then return false, string.format('sortie %s is still out (%s)', st.so.sq, st.so.ph) end
  if IK_BUSY[st.ik.ph] then return false, 'an intake wave runs (' .. st.ik.ph .. ')' end
  if st.str.rescue then return false, 'a STRANDED rescue runs' end
  local tgt = posp(args.target)
  if not tgt then return false, 'target must be a position [x,y,z] outside ' .. gname end
  if in_boxes(g.zin, tgt[1], tgt[2], tgt[3]) or in_boxes(g.zpast, tgt[1], tgt[2], tgt[3]) then
    return false, 'the target lies inside the fort: squad.sortie without gate'
  end
  local at = bailey(g)
  if not at then return false, 'no bailey: manifest zones.Z1 or stations.bailey' end
  if #g.inner == 0 then return false, 'no inner bridge (B1): no airlock' end
  for _, b in ipairs(g.inner) do if gate_state(K, b) ~= 'up' then return false, b .. ' is not up' end end
  if gate_state(K, gname) ~= 'up' then return false, gname .. ' is not up' end
  local a = assess(K)
  if not a then return false, 'no hostile census' end
  if (a.inside or 0) + (a.zpast or 0) > 0 then return false, 'a hostile past B1' end
  if (a.zin or 0) > 0 then return false, string.format('%d hostiles in the bailey, trap hall or field', a.zin) end
  if (a.dz or 0) > 0 then return false, string.format('%d dangerous hostiles in sight', a.dz) end
  if civ_in(K, g.zin) > 0 then return false, 'civilians in the bailey, trap hall or field' end
  local ok, info = K.call('military', 'squad_info', key)
  if not (ok and type(info) == 'table') then return false, 'no squad ' .. tostring(key) end
  if (info.n or 0) == 0 then return false, 'squad ' .. key .. ' has no members' end
  local f = foes(K, tgt, c.near)
  local est = #f * c.foe_cv
  local cmp = string.format('cv %d vs ~%d hostiles x %d = %d, worn %d%%', info.cv or 0, #f, c.foe_cv, est, info.worn or 0)
  if (info.worn or 0) < c.worn then
    return false, string.format('squad %s not in uniform: worn %d%% < %d%% (%s)', key, info.worn or 0, c.worn, cmp)
  end
  if (info.cv or 0) < est then return false, string.format('squad %s too weak: %s', key, cmp) end
  st.so = {sq = key, gate = gname, ph = 'gather', t = now, t0 = now, tgt = tgt, at = at, cmd = tostring(cmd_id or '?'),
           lost0 = st.ep and st.ep.lost or 0, killed0 = st.ep and st.ep.killed or 0}
  dirty = true
  K.call('military', 'hold_order', key, {kind = 'station', pos = at}, 'sortie')
  local msg = string.format('sortie %s through %s: gathering in the bailey at %d,%d,%d, then out to %d,%d,%d; %s',
                            key, gname, at[1], at[2], at[3], tgt[1], tgt[2], tgt[3], cmp)
  so_event(K, 'gather', msg, {n = info.n, cv = info.cv, foes = #f, est = est, worn = info.worn, pos = tgt})
  save(K)
  return true, msg
end

-- public (reflex, INTRUDER): an intake wave or a sortie runs, so hostiles outside B1 are expected
function M.expects(K)
  return st ~= nil and (IK_BUSY[st.ik.ph] == true or st.so ~= nil)
end

-- a wave or a sortie moving B1/O1 (BUG-028's rescue waits: they own B1 and bring the soldiers back themselves); while a
-- wave fights (O1 and B1 up) the rescue runs as usual (a hostile on the joined walk groups refuses it)
local IK_GATES = {muster = true, open = true, back = true, stray = true}
local function wave_busy() return IK_GATES[st.ik.ph] == true or st.so ~= nil end

-- leaving SIEGE ends a wave and a sortie at once (BREACH raises every bridge anyway); a BREACH during one is WAVE_FAIL
-- (past_b1: a hostile on Kern+, else breach: a gate failure)
local function wave_abort(K, to, now, why)
  local fail = to == 'BREACH' and (why == 'inside' and 'past_b1' or 'breach') or nil
  if IK_BUSY[st.ik.ph] then
    ik_event(K, 'abort', string.format('wave %d ended: mode %s', st.ik.n, to), {why = 'mode'})
    if fail then
      wave_fail(K, st.ik, 'intake', fail, string.format('wave %d: BREACH (%s) while the wave ran', st.ik.n,
                tostring(why)), {wave = st.ik.n})
    end
  end
  if st.ik.ph ~= 'idle' then ik_phase(K, 'idle', now) end
  if st.so then
    if fail then
      wave_fail(K, st.so, 'sortie', fail, string.format('sortie %s: BREACH (%s) while it was out (%s)', st.so.sq,
                tostring(why), st.so.ph), {squad = st.so.sq})
    end
    so_end(K, 'abort', string.format('sortie %s ended: mode %s', st.so.sq, to))
  end
  for b in pairs(st.wd) do want(K, b, 'up', 'wave_end', now + M.BREACH_AT) end
  st.wd, st.wu, dirty = {}, {}, true
end

---------------------------------------------------------------- the deep defense (BUG-030, plan B)
-- Run 10 y421 (Handlelock): 58 goblins and 6 trolls (building destroyers) destroyed O1, B1 and B2; 19 recruits (worn 53
-- %, no metal) at the melee (130,128,122) and gallery (123,123,122) stations between O1 and B2 died first, then 40+
-- civilians in the main hall had nobody between them and the invaders. Raised bridges stop goblins; they are no plan
-- against an army that brings building destroyers, nor when the squads cannot hold the corridor. SIEGE only, on each
-- pass with a fresh hostile census; the reasons (st.deep.why):
--   destroyers  sense counts visible hostiles whose caste raws make them building destroyers (census.h.bd): the bridges
--               are no barrier (latched for the episode)
--   army        visible hostiles > stations.core_ratio (3) x soldiers (military.kpi; only a fort with soldiers: one
--               without relies on its bridges as before)
--   weak        worn < stations.worn (60 %) or the share of soldiers in iron/steel < stations.metal (0 = not checked)
-- While it holds: the civ alert confines to the separated refuge at seal's BREACH level (alert_plan asks seal as in a
-- BREACH: no drink, food or bed counts for breach_days, BUG-018/019; seal keeps the refuge afterwards until back_days
-- are quiet), every squad stands at the core station (posture CORE: stations.core on the core level next to the
-- civilians' stair, else stations.b2, else stations.melee), no kill orders (they would draw the crossbows to the
-- gallery and the field) and no intake wave (INTAKE refused 'deep'); a wave already in the field ends by its own
-- rules. SIEGE_DEEP (A) names the reasons and the destroyers, again only when a reason or a destroyer race is new
-- (util/cadence). army and weak end DEEP_HOLD ticks after they went away unless destroyers were seen; RECOVERY, PEACE
-- and ALERT end it (BREACH keeps it: the refuge is BREACH's own rule anyway, its squads hold the B2 choke). Kernel
-- cost: no new scan (bd rides on sense's hostile pass, the KPI on siege's 300-tick cache).
M.ST = {core_ratio = 3, worn = 60, metal = 0}
M.ST_LIM = {core_ratio = {1, 50}, worn = {0, 100}, metal = {0, 100}}
M.DEEP_HOLD = 2400
local function st_cfg(K) return cfg_block(K, 'stations', M.ST, M.ST_LIM) end

-- the reasons now (tokens in DEEP_WHY order) and the numbers behind them
local function deep_reasons(K, a)
  local why, d = {}, {bd = int(a.bd) or 0, vis = int(a.vis) or 0}
  if d.bd > 0 then why[#why + 1] = 'destroyers' end
  local k = mil_kpi(K, M.IK_IDLE_TTL)
  local sol = k and int(k.soldiers) or 0
  if sol > 0 then
    local c = st_cfg(K)
    d.sol, d.worn, d.metal, d.c = sol, int(k.worn) or 0, int(k.metal_pct) or 0, c
    if d.vis > c.core_ratio * sol then why[#why + 1] = 'army' end
    if d.worn < c.worn or d.metal < c.metal then why[#why + 1] = 'weak' end
  end
  return why, d
end

-- the visible building destroyers of census.h.list: {'TROLL x6'} by race, their ids, the nearest one's distance to O1
local function destroyers(K)
  local h = K.census.h
  local by, order, ids, near = {}, {}, {}, -1
  for _, e in ipairs(type(h) == 'table' and type(h.list) == 'table' and h.list or {}) do
    if e.bd == 1 then
      local ok, race = pcall(dfhack.units.getRaceName, df.unit.find(e.id))
      race = (ok and type(race) == 'string' and race ~= '') and race or '?'
      if not by[race] then by[race], order[#order + 1] = 0, race end
      by[race] = by[race] + 1
      if #ids < 20 then ids[#ids + 1] = e.id end
      local d = int(e.d_o1)
      if d and d >= 0 and (near < 0 or d < near) then near = d end
    end
  end
  table.sort(order)
  local races = {}
  for i, r in ipairs(order) do races[i] = string.format('%s x%d', r, by[r]) end
  table.sort(ids)
  return races, ids, near, order
end

-- the core station of posture CORE (military.station_of): stations.core, else stations.b2, else stations.melee
local function core_station(g) return posp(g.stations.core) or posp(g.stations.b2) or posp(g.stations.melee) end

local function deep_step(K, a, g, now)
  if not (a and a.fresh) then return end
  local why, d = deep_reasons(K, a)
  local dp = st.deep
  if #why == 0 then
    if dp and not dp.bd then
      if not dp.clear then dp.clear, dirty = now, true
      elseif now - dp.clear >= M.DEEP_HOLD then
        K.log('info', 'siege: deep defense over (%s gone for %d ticks): the squads go back to the inner station',
              deep_txt(), now - dp.clear)
        st.deep, st.deep_rec, dirty = nil, CAD.quiet(st.deep_rec), true
        mem.kill_sig, mem.kill_set = nil, nil
      end
    end
    return
  end
  if not dp then
    dp = {t = now, why = {}, bd = false}
    st.deep = dp
    mem.kill_sig, mem.kill_set = nil, nil      -- the posture change re-issues every squad's orders
  end
  if dp.clear then dp.clear = nil end
  for _, w in ipairs(why) do dp.why[w] = true end
  if d.bd > 0 then dp.bd = true end
  dirty = true
  local races, ids, near, kinds = destroyers(K)
  local toks = {}
  for _, w in ipairs(why) do toks[#toks + 1] = w end
  for _, r in ipairs(kinds) do toks[#toks + 1] = r end
  if not CAD.due(st.deep_rec, K.now(), {}, toks, {ticks = 0, wall_s = 0}) then return end
  st.deep_rec = CAD.mark(K.now(), {}, toks)
  local parts, has = {}, {}
  for _, w in ipairs(why) do has[w] = true end
  if has.destroyers then
    parts[#parts + 1] = string.format('%d building destroyer%s in sight (%s%s): the bridges are no barrier', d.bd,
                                      d.bd == 1 and '' or 's', #races > 0 and table.concat(races, ', ') or '?',
                                      near >= 0 and string.format(', %d tiles from O1', near) or '')
  end
  if has.army then
    parts[#parts + 1] = string.format('army %d > %d x %d soldiers', d.vis, d.c.core_ratio, d.sol)
  end
  if has.weak then
    parts[#parts + 1] = d.worn < d.c.worn and string.format('worn %d%% < %d%%', d.worn, d.c.worn)
                        or string.format('iron/steel %d%% < %d%%', d.metal, d.c.metal)
  end
  local p = core_station(g)
  local txt = string.format('deep defense: %s; civilians to %s (the separated refuge), every squad at the core station '
                            .. '%s, no intake waves', table.concat(parts, '; '), g.refuge,
                            p and string.format('%d,%d,%d', p[1], p[2], p[3]) or '(none in the manifest)')
  local all = {}
  for _, w in ipairs(DEEP_WHY) do if dp.why[w] then all[#all + 1] = w end end
  K.emit('SIEGE_DEEP', 'A', txt:sub(1, 200), {why = all, bd = d.bd, races = races, units = ids, vis = d.vis,
                                              soldiers = d.sol, worn = d.worn, metal = d.metal, refuge = g.refuge,
                                              pos = p})
  K.log('warn', 'siege: %s', txt:sub(1, 200))
end

-- BUG-030: a raise hold (BUG-028 c) on a bridge that is gone holds nothing
local function prune_holds(K)
  for b in pairs(st.str.hold) do
    if gate_state(K, b) == 'destroyed' then st.str.hold[b], dirty = nil, true end
  end
end

local function apply(K, a, g, now)
  local mode = K.mode()
  if mode == 'SIEGE' or mode == 'DRILL' then raise(K, g, now)
  elseif mode == 'BREACH' then
    -- BUG-028: never over a rescue, and a raise that would cut citizens off from drink or food waits (c); BUG-030:
    -- a destroyed bridge is neither raised nor held
    local fresh, gone = {}, {}
    for _, b in ipairs(g.all) do
      local s = gate_state(K, b)
      if s == 'destroyed' then gone[b] = true
      elseif not rescuing(b) and s ~= 'up' then fresh[#fresh + 1] = b end
    end
    local held = #fresh > 0 and cut_holds(K, g, fresh, now) or {}
    for _, b in ipairs(g.all) do
      if not held[b] and not rescuing(b) and not gone[b] then want(K, b, 'up', 'breach', st.tb + M.BREACH_AT) end
    end
  elseif mode == 'ALERT' then
    if a and a.near_o1 >= 0 and a.near_o1 <= M.ALERT_O1 then
      for _, b in ipairs(g.outer) do want(K, b, 'up', 'alert') end
    end
  elseif mode == 'RECOVERY' then lower(K, g) end
  local on, burrow, held, _, _, audited, flee = alert_plan(K, a, g, now)
  set_alert(K, on, burrow, g, now, held, audited, flee)
  local P = POSTURE[mode]
  local deep = mode == 'SIEGE' and st.deep ~= nil
  if mode == 'SIEGE' and IK_FIELD[st.ik.ph] then P = 'INTAKE'          -- an intake wave: field and gallery
  elseif deep then P = 'CORE' end                                       -- BUG-030: every squad at the core station
  local var
  if P == 'READY_IN' or P == 'STATION_B1' then                         -- BUG-029: the inner station follows B2
    local parts = {}
    for _, b in ipairs(g.core) do parts[#parts + 1] = gate_state(K, b) end
    var = table.concat(parts, ',')
  end
  set_posture(K, P, now, var)
  -- BUG-030: no kill orders in the deep defense (they would draw the crossbows into the gallery and the field)
  if mode == 'BREACH' or (mode == 'SIEGE' and (not deep or P == 'INTAKE')) then kills(K, g, P, now, P == 'INTAKE') end
end

---------------------------------------------------------------- episode bookkeeping
-- every citizen id seen in this episode: the census (every 25 ticks in SIEGE) drops the dead before
-- the UNIT_DEATH poll (eventful freq 100) delivers them, so the current census cannot decide
local function note_citizens(K)
  local cu = K.census.u
  if type(cu) ~= 'table' or mem.cit_src == cu then return end
  mem.cit_src = cu
  for _, list in ipairs({cu.ids, cu.insane_ids}) do
    for _, id in ipairs(type(list) == 'table' and list or {}) do mem.cit_ever[id] = true end
  end
end

local function track(K, g, now, dt)
  local ep = st.ep
  if not ep or not EPISODE[K.mode()] then return end
  note_citizens(K)
  local h, cu = K.census.h, K.census.u
  if type(h) == 'table' then
    if (h.vis or 0) > ep.hmax then ep.hmax = h.vis end
    for _, e in ipairs(h.list or {}) do
      if not mem.hseen[e.id] then mem.hseen[e.id], mem.nseen = true, mem.nseen + 1 end
    end
    if mem.nseen > (ep.seen or 0) then ep.seen = mem.nseen end
  end
  if type(cu) == 'table' and type(cu.caged) == 'table' then
    if mem.caged0 == nil then                    -- after a reload: current cages are not new
      mem.caged0 = {}
      for _, id in ipairs(cu.caged) do mem.caged0[id] = true end
    end
    for _, id in ipairs(cu.caged) do
      if not mem.caged0[id] and not mem.caps[id] then mem.caps[id], ep.caps = true, ep.caps + 1 end
    end
  end
  local b = g.inner[1] or g.outer[1]
  if b and dt > 0 and gate_state(K, b) == 'up' then ep.sealed = ep.sealed + dt
  elseif not b and dt > 0 then           -- no fortcore gate: the bridges a lockdown raised (gate.sealed, FR-49)
    local ok, sealed = K.call('gate', 'sealed')
    if ok and sealed == true then ep.sealed = ep.sealed + dt end
  end
  dirty = true
end

local function status(K, a, now)
  local ep = st.ep
  if not ep or not EPISODE[K.mode()] or now - (st.ls or -M.STATUS) < M.STATUS then return end
  st.ls, dirty = now, true
  local d = {vis = a and a.vis or 0, deaths = ep.lost, captures = ep.caps}
  local ok, k = K.call('military', 'kpi')
  if ok and type(k) == 'table' then d.worn, d.on_station = int(k.worn), int(k.on_station) end
  K.emit('SIEGE_STATUS', 'C', string.format('%s: %d visible, %d lost', K.mode(), d.vis, ep.lost), d)
end

-- public (FR-52, BUG-011): the reflex module started or ended a lockdown; apply the civ alert now, in the same step
-- and with the same decision as the step (alert_plan). Returns what really holds, for the ARRIVAL/LOCKDOWN text, in
-- full and short: '<burrow>' (sounding, confined there), '<burrow> (<note>)' (not the mode's burrow: seal's
-- REFUGE_FAIL reason), '<burrow> kept (<note>)' (a lockdown found no usable burrow, the alert sounding already stays
-- on), 'pending <burrow>' (the act failed, retried after RETRY), 'none (<note>)' (wanted, no usable burrow: not
-- sounded) or 'off'
function M.hold_alert(K)
  local now = K.now().tick
  local g = geometry(K)
  local on, burrow, held, note, brief, audited, flee = alert_plan(K, assess(K), g, now)
  local function say(fmt, b, n)
    if not n then return b end
    return string.format(fmt, b, note), string.format(fmt, b, brief)
  end
  if not on then
    set_alert(K, false, burrow, g, now, held, audited, flee)
    save(K)
    if not held then return 'off' end
    local idx = alert_idx()
    note, brief = note or 'no usable burrow', brief or 'no usable burrow'
    if idx ~= nil and idx ~= 0 and mem.burrow then return say('%s kept (%s)', mem.burrow, true) end
    return say('%s (%s)', 'none', true)
  end
  if not burrow_exists(burrow) and (audited or not burrow_exists(g.kern)) then
    return 'none (no burrow ' .. tostring(burrow) .. ')'
  end
  set_alert(K, true, burrow, g, now, held, audited, flee)
  save(K)
  local idx = alert_idx()
  if idx ~= nil and idx ~= 0 then return say('%s (%s)', tostring(mem.burrow or burrow), note) end
  return 'pending ' .. tostring(burrow)
end

-- public (BUG-028, gate): siege holds bridge `b` down: a raise that would cut citizens off from drink or food (c), or
-- a rescue's bridge (a); gate does not raise it on its own at a BREACH entry then
function M.held(K, b)
  return st ~= nil and st.str ~= nil and (st.str.hold[b] ~= nil or rescuing(b))
end

-- public (BUG-013, gate): the burrows the sounding civ alert holds the civilians in (the list siege set last); {} while
-- it is silent. gate counts a pull whose levers all lie outside them as blocked
function M.alert_names(K)
  local idx = alert_idx()
  if idx == nil or idx == 0 or type(mem.alist) ~= 'table' then return {} end
  local r = {}
  for i, n in ipairs(mem.alist) do r[i] = n end
  return r
end

-- state `wave` (Gordon 2026-10-16): the intake phase, the waves so far, the last refusal or wait, the sortie
function M.state(K)
  if not st then return {} end
  local ik, so = st.ik, st.so
  if K.mode() ~= 'SIEGE' and ik.ph == 'idle' and not so then return {} end
  local w = {ph = ik.ph, n = ik.n}
  if ik.why then w.why = ik.why:sub(1, 40) end
  if so then w.so = (so.sq .. ' ' .. so.ph):sub(1, 24) end
  if st.deep and K.mode() == 'SIEGE' then w.deep = deep_txt():sub(1, 24) end    -- BUG-030: the deep defense
  return {wave = w}
end

---------------------------------------------------------------- module
function M.init(K)
  local now = K.now().tick
  local p = K.persist.get('m.siege')
  p = type(p) == 'table' and p or {}
  st = {v = 2, t0 = int(p.t0) or K.mode_since(), tb = int(p.tb) or K.mode_since(), req = {},
        rq = int(p.rq) or 0, rl = now, civ = p.civ == true, b1low = p.b1low == true, ls = int(p.ls)}
  for b, why in pairs(type(p.req) == 'table' and p.req or {}) do
    if type(b) == 'string' then st.req[b] = tostring(why) end
  end
  -- BUG-028: an open rescue survives a reload (the live session: after `dfllm reload` BREACH raised B1/B2 at once)
  local ps = type(p.str) == 'table' and p.str or {}
  st.str = {hold = {}, rec = type(ps.rec) == 'table' and ps.rec or nil}
  local r = ps.rescue
  if type(r) == 'table' and type(r.list) == 'table' and #r.list > 0 and int(r.since) then
    local list, ids = {}, {}
    for _, b in ipairs(r.list) do if type(b) == 'string' then list[#list + 1] = b end end
    for _, id in ipairs(type(r.ids) == 'table' and r.ids or {}) do if int(id) then ids[#ids + 1] = int(id) end end
    local need = type(r.need) == 'table' and r.need or {}
    st.str.rescue = {list = list, ids = ids, grp = int(r.grp) or 0, since = int(r.since),
                     need = {drink = need.drink == true, food = need.food == true}}
  end
  for b, t in pairs(type(ps.hold) == 'table' and ps.hold or {}) do
    if type(b) == 'string' and int(t) then st.str.hold[b] = int(t) end
  end
  -- intake waves and the sortie (Gordon 2026-10-16) survive a reload
  local pk = type(p.ik) == 'table' and p.ik or {}
  local IKPH = {idle = true, muster = true, open = true, fight = true, back = true, cool = true, stray = true}
  st.ik = {ph = IKPH[pk.ph] and pk.ph or 'idle', n = int(pk.n) or 0, t = int(pk.t) or now, raise = pk.raise == true or nil,
           size = int(pk.size), lost0 = int(pk.lost0), killed0 = int(pk.killed0), sn = int(pk.sn), left = int(pk.left),
           why = type(pk.why) == 'string' and pk.why or nil, rec = type(pk.rec) == 'table' and pk.rec or nil}
  if type(pk.fails) == 'table' then
    st.ik.fails = {}
    for k, v in pairs(pk.fails) do if v == true then st.ik.fails[k] = true end end
  end
  st.wd, st.wu = {}, {}
  for b, v in pairs(type(p.wd) == 'table' and p.wd or {}) do if type(b) == 'string' and v == true then st.wd[b] = true end end
  for b, v in pairs(type(p.wu) == 'table' and p.wu or {}) do if type(b) == 'string' and int(v) then st.wu[b] = int(v) end end
  local ps2 = p.so
  local SOPH = {gather = true, open = true, out = true, recall = true, close = true, home = true}
  if type(ps2) == 'table' and type(ps2.sq) == 'string' and type(ps2.gate) == 'string' and SOPH[ps2.ph]
     and posp(ps2.tgt) and posp(ps2.at) then
    st.so = {sq = ps2.sq, gate = ps2.gate, ph = ps2.ph, t = int(ps2.t) or now, t0 = int(ps2.t0) or now,
             tgt = posp(ps2.tgt), at = posp(ps2.at), cmd = tostring(ps2.cmd or '?'), out = int(ps2.out),
             lost0 = int(ps2.lost0) or 0, killed0 = int(ps2.killed0) or 0, raise = ps2.raise == true or nil}
    if type(ps2.fails) == 'table' then
      st.so.fails = {}
      for k, v in pairs(ps2.fails) do if v == true then st.so.fails[k] = true end end
    end
  end
  -- BUG-030: the deep defense survives a reload within the episode
  local pd = p.deep
  if type(pd) == 'table' and type(pd.why) == 'table' then
    st.deep = {t = int(pd.t) or now, why = {}, bd = pd.bd == true, clear = int(pd.clear)}
    for _, w in ipairs(DEEP_WHY) do if pd.why[w] == true then st.deep.why[w] = true end end
    if not next(st.deep.why) then st.deep = nil end
  end
  st.deep_rec = type(p.deep_rec) == 'table' and p.deep_rec or nil
  if type(p.ep) == 'table' then
    st.ep = {}
    for _, f in ipairs({'start', 'hmax', 'seen', 'killed', 'lost', 'caps', 'sealed'}) do st.ep[f] = int(p.ep[f]) or 0 end
  end
  if type(p.civ_at) == 'table' then
    st.civ_at = {}
    for _, q in ipairs(p.civ_at) do
      if type(q) == 'table' and int(q[1]) and int(q[2]) and int(q[3]) then st.civ_at[#st.civ_at + 1] = {int(q[1]), int(q[2]), int(q[3])} end
    end
  end
  -- quiet windows restart after a load (persist may lag the save by a few seconds)
  mem = {hseen = {}, nseen = 0, caps = {}, caged0 = nil, posture_tick = 0, cit_ever = {}}
  dirty = true
end

function M.step(K, budget, ctx)
  local now = K.now().tick
  local h = K.census.h
  local htick = type(h) == 'table' and h.tick or -1
  local period = (type(h) == 'table' and h.armed == 1) and M.PERIOD_ARMED or M.PERIOD
  if htick == mem.htick and mem.last and now - mem.last < period then return end   -- nothing new
  local dt = mem.last and now - mem.last or 0
  mem.htick, mem.last = htick, now
  local a = assess(K)
  local g = geometry(K)
  decide(K, a, g, now)
  track(K, g, now, dt)
  local mode = K.mode()
  prune_holds(K)                                           -- BUG-030
  if mode == 'SIEGE' then deep_step(K, a, g, now) end
  -- BUG-028 (a); a wave or a sortie brings its soldiers back itself (it owns B1 meanwhile)
  if mode ~= 'DRILL' and (mode ~= 'RECOVERY' or st.str.rescue) and not wave_busy() then rescue_step(K, a, g, now) end
  if mode == 'SIEGE' then                                  -- Gordon 2026-10-16: the sortie, then the intake waves
    sortie_step(K, a, g, now)
    intake_step(K, a, g, now)
  end
  apply(K, a, g, now)
  status(K, a, now)
  save(K)
end

M.on = {
  MODE = function(K, ev)
    local to, now = ev.to, ev.tick or K.now().tick
    st.qs, st.aq = nil, nil
    if to == 'SIEGE' or to == 'DRILL' then st.t0, st.req = now, {} end
    if to == 'BREACH' then st.tb = now end
    st.str.bs = nil                              -- BUG-028 (b): the sealed clock starts again in every mode
    if to == 'RECOVERY' then st.rq, st.rl, st.b1low = 0, now, false end
    if to == 'ALERT' then st.civ, st.far, st.civ_at = false, nil, nil end
    if (to == 'SIEGE' or to == 'BREACH') and not st.ep then
      st.ep = {start = now, hmax = 0, seen = 0, killed = 0, lost = 0, caps = 0, sealed = 0}
      mem.hseen, mem.nseen, mem.caps, mem.caged0 = {}, 0, {}, nil
      mem.cit_ever, mem.cit_src = {}, nil
      note_citizens(K)
    end
    mem.kill_sig, mem.kill_set = nil, nil      -- a posture change re-issues every squad's orders
    if to ~= 'SIEGE' then wave_abort(K, to, now, ev.why) end   -- intake waves and the sortie run in SIEGE only
    if to == 'PEACE' or to == 'DRILL' then st.ep = nil end
    if to ~= 'SIEGE' and to ~= 'BREACH' then st.deep, st.deep_rec = nil, nil end   -- BUG-030: the episode is over
    dirty = true
    local a, g = assess(K), geometry(K)
    if to == 'SIEGE' then deep_step(K, a, g, now) end     -- BUG-030: destroyers at T0 send the civilians deep at once
    apply(K, a, g, now)                      -- T0 actions in the detecting step
    save(K)
  end,
  UNIT_DEATH = function(K, ev)
    if not st.ep then return end
    local id = ev.unit
    note_citizens(K)
    if mem.cit_ever[id] then st.ep.lost, dirty = st.ep.lost + 1, true
    elseif mem.hseen[id] then st.ep.killed, dirty = st.ep.killed + 1, true end
    save(K)
  end,
}

return M
