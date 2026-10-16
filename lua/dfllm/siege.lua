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
--     the outside is sealed (a rescue); BREACH falls back to SIEGE once the fort is sealed again.
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

local POSTURE = {PEACE = 'TRAIN', ALERT = 'STATION_B1', SIEGE = 'READY_STATION', DRILL = 'READY_STATION',
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
          siege = (great > 0 and 'great') or (inv >= 6 and 'invaders') or nil, hostile = vis > 0,
          quiet = fresh and vis == 0, calm = fresh and vis == 0, fresh = fresh}
end

local function gate_state(K, b)
  local ok, s = K.call('gate', 'state', b)
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
    K.emit('BREACH', 'A', 'breach: ' .. (bridge and (bridge .. ' not up at T+900') or 'hostile inside Kern+'),
           {why = why == 'gate_fail' and 'gate_fail' or 'inside', bridge = bridge})
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
    why = 'the outside is not verified sealed'
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
local function failed_bridge(K, g)
  local h = K.census.h
  local nb = type(h) == 'table' and type(h.near_bridge) == 'table' and h.near_bridge or {}
  for _, list in ipairs({g.outer, g.inner}) do
    for _, b in ipairs(list) do
      if gate_state(K, b) ~= 'up' then
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
local function alert_plan(K, a, g, now)
  local held = alert_held(K)
  local on, burrow = alert_wanted(K, a, g, now, held), K.mode() == 'BREACH' and g.refuge or g.kern
  local note, brief, audited, flee
  if on then
    local okb, pick, why, short, fl = K.call('seal', 'alert_burrow', K.mode(), burrow, held)
    if okb then
      burrow, on, audited, flee = pick, pick ~= nil, true, fl == true
      note, brief = type(why) == 'string' and why or nil, type(short) == 'string' and short or nil
    end
  end
  return on, burrow, held, note, brief or note, audited, flee
end

local function set_posture(K, P, now)
  if mem.posture == P and now - mem.posture_tick < M.POSTURE_REASSERT then return end
  if mem.posture_want == P and now < (mem.posture_retry or now) then return end
  mem.posture_want = P
  local ok, r = K.call('military', 'posture', P)
  if ok and r ~= false then mem.posture, mem.posture_tick = P, now
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
      if not why then
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
      if why and not held[b] and not rescuing(b) and want(K, b, 'up', why, st.t0 + M.BREACH_AT) and not st.req[b] then
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
    for _, b in ipairs(g.core) do
      want(K, b, 'down', 'recovery')
      if gate_state(K, b) ~= 'down' then cores = false end
    end
    low = cores
    if cores and not keep then
      for _, b in ipairs(g.inner) do
        want(K, b, 'down', 'recovery')
        if gate_state(K, b) ~= 'down' then low = false end
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
local function kills(K, g, P, now)
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
  local sig = table.concat(ids, ',')
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
  local ok, r = K.call('military', 'kill', ids)
  if ok and r ~= false then mem.kill_sig, mem.kill_set = sig, set
  elseif mem.kill_sig then                       -- refused: never leave the old order running
    withdraw(K, P, now)
    mem.kill_sig, mem.kill_set = nil, nil
  end
end

local function apply(K, a, g, now)
  local mode = K.mode()
  if mode == 'SIEGE' or mode == 'DRILL' then raise(K, g, now)
  elseif mode == 'BREACH' then
    -- BUG-028: never over a rescue, and a raise that would cut citizens off from drink or food waits (c)
    local fresh = {}
    for _, b in ipairs(g.all) do
      if not rescuing(b) and gate_state(K, b) ~= 'up' then fresh[#fresh + 1] = b end
    end
    local held = #fresh > 0 and cut_holds(K, g, fresh, now) or {}
    for _, b in ipairs(g.all) do
      if not held[b] and not rescuing(b) then want(K, b, 'up', 'breach', st.tb + M.BREACH_AT) end
    end
  elseif mode == 'ALERT' then
    if a and a.near_o1 >= 0 and a.near_o1 <= M.ALERT_O1 then
      for _, b in ipairs(g.outer) do want(K, b, 'up', 'alert') end
    end
  elseif mode == 'RECOVERY' then lower(K, g) end
  local on, burrow, held, _, _, audited, flee = alert_plan(K, a, g, now)
  set_alert(K, on, burrow, g, now, held, audited, flee)
  set_posture(K, POSTURE[mode], now)
  if mode == 'SIEGE' or mode == 'BREACH' then kills(K, g, POSTURE[mode], now) end
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
  if mode ~= 'DRILL' and (mode ~= 'RECOVERY' or st.str.rescue) then rescue_step(K, a, g, now) end   -- BUG-028 (a)
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
    if to == 'PEACE' or to == 'DRILL' then st.ep = nil end
    dirty = true
    apply(K, assess(K), geometry(K), now)    -- T0 actions in the detecting step
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
