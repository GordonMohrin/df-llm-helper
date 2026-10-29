-- cavern (WP6, FR-98/FR-99; Gordon's goal G16 "the military clears the caverns of beasts"): the cavern sweep.
-- The fort keeps its caverns plugged (runner: CAVERN_PLUG walls the explore shaft that broke into one). From phase P6 on,
-- with the plan's `caverns.sweep` on (plan propose drafts it, plan check gates it, plan apply sends it), this module opens
-- ONE plugged shaft under a hatch, sends squad A down with kill orders on the cavern beasts the player can see, calls it
-- back and walls the shaft again:
--   wait    the gates, once a game day: plan caverns.sweep, phase >= P6, PEACE, no lockdown, no hostile in sight, rest
--           after the last sweep, a plugged shaft (runner.cav_sealed), readiness >= R1, squad A >= 3 soldiers and worn >=
--           80 %, a visible cavern beast near the shaft's bottom and no great danger (forgotten beast, titan, building
--           destroyer: the squad alone is not enough; Gordon decides)
--   open    runner.sweep_open: the unplug project (the plug walls removed, a down stair and a hatch cover on the top, then
--           the lower wall removed and an up/down stair below); blocked or too slow: walled again (why blocked)
--   muster  the hatch is forbidden (the hatch sheet's forbid, act.door_forbid), squad A stands beside the shaft top
--           (military.hold_order station: the posture leaves it alone); half of the squad there: the hatch is opened
--   kill    military.hold_order kill on the visible beasts in the cavern box, renewed as the picture changes; ends done
--           (no beast in sight for clear_looks looks), losses (lost soldiers), great (a great danger came), timeout
--   recall  squad A back to the station; once nobody stands below the shaft top (or recall_max x 5): the hatch is forbidden,
--           the squad released to its posture
--   close   runner.sweep_close: a plug project walls the shaft (CAVERN_PLUG done); CAVERN_SWEEP_END (A) names the result
-- SIEGE, BREACH, RECOVERY or a drill at any time: the kernel's own defense wins: the squad is released at once (the posture
-- takes it home through the hatch), the sweep goes to recall (or straight to close while the shaft is being opened) and
-- ends why siege. Fair play (RULES 1.1): units are read only when the player sees them (isVisible, not hidden), tiles only
-- through snapshot.tile (revealed), every action is a player's (designations, the hatch sheet, the squads screen).
-- State `cav` (status: `caverns: ...`), persist m.cavern, inspect what=cavern; events CAVERN_SWEEP_START (B),
-- CAVERN_SWEEP_STEP (C), CAVERN_SWEEP_END (A). runner's P6 deliverable `sweep` asks M.cleared.
local M = {name = 'cavern', every = {ticks = 100}, verbs = {}, on = {}, inspect = {}}

M.CFG = {
  phase = 'P6',              -- the earliest phase of a sweep
  ready = 1,                 -- readiness level at least
  worn = 80,                 -- squad A worn % at least
  sol = 3,                   -- squad A soldiers at least
  lost = 1,                  -- soldiers lost that end the kill (withdraw)
  look = 1200,               -- ticks between two looks while waiting (a game day)
  scan = 200,                -- ticks between two beast scans in the kill
  radius = 40, depth = 12, above = 1,   -- the cavern box: x/y around the shaft, levels below / above its bottom
  open_max = 4 * 33600,      -- the unplug project may take four months
  muster_max = 2400, kill_max = 24000, recall_max = 2400, close_max = 2 * 33600,
  clear_looks = 3,           -- scans without a beast in sight end the kill as done
  cool = 100800, cool_bad = 2 * 100800,   -- rest after a sweep: a season, two after any other end
  near = 2,                  -- tiles from the station: a soldier has mustered
}
M.SQUAD, M.TAG = 'A', 'cavern'
M.ABORT = {SIEGE = true, BREACH = true, RECOVERY = true, DRILL = true}
M.RUN = {open = true, muster = true, kill = true, recall = true, close = true}
M.DAY = 1200

local st      -- persisted m.cavern {v, ph, acc, pos, bot, t0, tp, open, plug, ids0, tg, k, l, clear, ls, sg, why, hatch, sta,
              -- cool, last, lk, ll, ok, rw}
local rt      -- runtime: next look, the last wait reason, beasts seen, plugged shafts

local function int(v) return type(v) == 'number' and math.tointeger(v) or nil end
local function try(f) local ok, r = pcall(f); if ok then return r end end
local function cut(s, n) s = tostring(s or ''); return #s > n and s:sub(1, n) or s end
local function now(K) return K.now().tick end
local function save(K) K.persist.set('m.cavern', st) end
local function call(K, mod, fn, ...)
  local r = table.pack(K.call(mod, fn, ...))
  if not r[1] then return nil end
  return table.unpack(r, 2, r.n)
end
local function pstr(p) return type(p) == 'table' and string.format('%d,%d,%d', p[1], p[2], p[3]) or '?' end

---------------------------------------------------------------- what the player sees
-- the cavern box below a plugged shaft a = {s0, bot}: {x0, y0, z0, x1, y1, z1} (never the shaft top's level)
function M.box(a)
  local c = M.CFG
  return {a.s0[1] - c.radius, a.s0[2] - c.radius, a.bot - c.depth,
          a.s0[1] + c.radius, a.s0[2] + c.radius, math.min(a.bot + c.above, a.s0[3] - 1)}
end

-- the visible wild dangers in the cavern box of shaft a (snapshot.cave_units: only units the player sees): {{id, x, y,
-- z}, ...} by id, and how many of them are great dangers or building destroyers
function M.beasts(K, a)
  local ok, list, great = K.call('snapshot', 'cave_units', M.box(a))
  if not ok or type(list) ~= 'table' then return {}, 0 end
  return list, int(great) or 0
end
local function unit_pos(id)
  return try(function()
    local u = df.unit.find(id)
    if u and not dfhack.units.isDead(u) then return {u.pos.x, u.pos.y, u.pos.z} end
  end)
end
local function dead(id)
  local u = try(function() return df.unit.find(id) end)
  if not u then return true end
  return try(function() return dfhack.units.isDead(u) end) == true
end
local function count_dead(ids)
  local n = 0
  for _, id in ipairs(ids or {}) do if dead(id) then n = n + 1 end end
  return n
end

local function squad(K) return call(K, 'military', 'squad_info', M.SQUAD) end

-- the hatch cover on the shaft top (the hatch sheet), its building id or nil
function M.hatch_at(p)
  return try(function()
    local b = dfhack.buildings.findAtTile(p[1], p[2], p[3])
    if b and df.building_type.Hatch ~= nil and b:getType() == df.building_type.Hatch then return b.id end
  end)
end

-- where squad A musters: a revealed floor beside the shaft top (snapshot.tile), else the top itself
local AROUND = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}, {1, 1}, {-1, -1}, {1, -1}, {-1, 1}}
local function station(K, s0)
  for _, d in ipairs(AROUND) do
    local v = call(K, 'snapshot', 'tile', s0[1] + d[1], s0[2] + d[2], s0[3])
    if type(v) == 'table' and v.c == '.' then return {s0[1] + d[1], s0[2] + d[2], s0[3]} end
  end
  return {s0[1], s0[2], s0[3]}
end

---------------------------------------------------------------- steps
local function step_ev(K, phase, why, d)
  d = d or {}
  d.phase, d.why = phase, why and cut(why, 120) or nil
  if type(st.pos) == 'table' then d.pos = {st.pos[1], st.pos[2], st.pos[3]} end
  K.emit('CAVERN_SWEEP_STEP', 'C', cut(string.format('cavern sweep %s at %s: %s', phase, pstr(st.pos), why or ''), 200), d)
end

local function go(K, ph, why)
  st.ph, st.tp = ph, now(K)
  step_ev(K, ph, why)
  K.log('info', 'cavern sweep %s: %s (%s)', tostring(st.acc), ph, tostring(why or ''))
  save(K)
end

local function lock(K, on)
  if not st.hatch then return false end
  local ok = K.act.door_forbid(st.hatch, on and true or false)
  return ok == true
end

local function kills()
  return count_dead(st.tg)
end

local function end_sweep(K, why, sealed, extra)
  local t = now(K)
  call(K, 'military', 'release', M.SQUAD)
  local k, l = kills(), count_dead(st.ids0)
  local a = {s0 = st.pos, bot = st.bot}
  local left = type(st.pos) == 'table' and #(M.beasts(K, a)) or 0
  local d = {why = why, acc = cut(st.acc, 60), killed = k, lost = l, left = left, sealed = sealed and 1 or 0,
             ticks = t - (st.t0 or t), plug = st.plug ~= nil and cut(st.plug, 60) or nil}
  if type(st.pos) == 'table' then d.pos = {st.pos[1], st.pos[2], st.pos[3]} end
  local msg = string.format('cavern sweep at %s ended: %s; %d beast%s killed, %d soldier%s lost, %d in sight; %s%s', pstr(st.pos),
                            why, k, k == 1 and '' or 's', l, l == 1 and '' or 's', left,
                            sealed and 'the shaft is walled again' or 'the shaft is NOT walled: wall ' .. pstr(st.pos) .. ' by hand',
                            extra or '')
  K.emit('CAVERN_SWEEP_END', 'A', cut(msg, 200), d)
  K.log(sealed and 'info' or 'warn', '%s', msg)
  K.flush()
  -- ok (review fix): a clean sweep (done, walled again) keeps the P6 deliverable met (M.cleared) when new beasts come later
  local clean = why == 'done' and sealed
  st = {v = 1, ph = 'wait', cool = t + (clean and M.CFG.cool or M.CFG.cool_bad), last = why, lk = k, ll = l,
        ok = (clean or st.ok == 1) and 1 or nil}
  rt.next = t + M.CFG.look
  save(K)
end

-- the shaft is walled again: the hatch forbidden, the squad released, the plug queued
local function to_close(K, why)
  st.why = st.why or why
  -- review fix: a hatch the unplug built already is forbidden also when the sweep closes before its muster (a siege or a
  -- block while the lower wall is gone: an unlocked hatch would join the cavern to the fort until the plug stands)
  if not st.hatch and type(st.pos) == 'table' then st.hatch = M.hatch_at(st.pos) end
  lock(K, true)
  call(K, 'military', 'release', M.SQUAD)
  local ok, pid = call(K, 'runner', 'sweep_close', st.acc)
  if not ok then return end_sweep(K, 'seal_failed', false, ' (' .. cut(pid, 60) .. '; was ' .. tostring(st.why) .. ')') end
  if pid == '' then return end_sweep(K, st.why or 'done', true) end
  st.plug = pid
  go(K, 'close', 'plug ' .. tostring(pid) .. ' (' .. tostring(st.why) .. ')')
end

local function to_recall(K, why)
  st.why = st.why or why
  go(K, 'recall', why)
end

-- who would be walled in: squad A's soldiers below the shaft top (anywhere: one may chase a beast far), and (review
-- fix) every other citizen in the cavern box or the shaft column (a hauler after the corpses, a gatherer: the open
-- hatch let them down; the player always sees his citizens); soldiers + citizens, citizens
local function below(K)
  if type(st.pos) ~= 'table' then return 0, 0 end
  local q = squad(K)
  local n, seen = 0, {}
  for _, id in ipairs(q and q.ids or st.ids0 or {}) do
    seen[id] = true
    local p = unit_pos(id)
    if p and p[3] < st.pos[3] then n = n + 1 end
  end
  local c = 0
  local ok, ids = K.call('snapshot', 'cave_citizens', M.box({s0 = st.pos, bot = st.bot}), st.pos)
  for _, id in ipairs(ok and type(ids) == 'table' and ids or {}) do if not seen[id] then c = c + 1 end end
  return n + c, c
end

local function start(K, a, b, q)
  local t = now(K)
  local ok, pid = call(K, 'runner', 'sweep_open', a.id)
  if not ok then
    rt.why = cut('open refused: ' .. tostring(pid), 60)
    K.log('warn', 'cavern sweep: %s', rt.why)
    return
  end
  local ids = {}
  for _, e in ipairs(b) do ids[#ids + 1] = e.id end
  st = {v = 1, ph = 'open', acc = a.id, pos = {a.s0[1], a.s0[2], a.s0[3]}, bot = a.bot, t0 = t, tp = t, open = pid,
        ids0 = q.ids or {}, tg = {}, clear = 0, cool = st.cool, ok = st.ok}
  local msg = string.format('cavern sweep: squad A (%d, worn %d%%) clears the cavern below %s: %d beast%s in sight; %s opens '
                            .. 'the shaft under a hatch', q.n, q.worn, pstr(st.pos), #b, #b == 1 and '' or 's', pid)
  K.emit('CAVERN_SWEEP_START', 'B', cut(msg, 200), {acc = cut(a.id, 60), n = #b, pos = st.pos, bot = a.bot, sol = q.n,
                                                    worn = q.worn, ids = ids})
  K.log('info', '%s', msg)
  step_ev(K, 'open', pid)
  save(K)
end

-- the first gate that holds the sweep back: state, why; nil when every gate is open (then the squad info)
function M.gates(K, n_acc)
  local plan = K.plan or {}
  local cv = type(plan.caverns) == 'table' and plan.caverns or nil
  if not (cv and cv.sweep == true) then return 'off', 'plan caverns.sweep is off' end
  local v = K.view()
  local ph = v.phase
  if type(ph) ~= 'string' then ph = (K.persist.get('phase') or {}).phase end
  local pn = type(ph) == 'string' and tonumber(ph:match('^P(%d+)$')) or nil     -- numeric: P10 > P6
  if not pn or pn < tonumber(M.CFG.phase:sub(2)) then
    return 'wait', 'phase ' .. tostring(ph or '?') .. ' < ' .. M.CFG.phase
  end
  local mode = K.mode()
  if mode ~= 'PEACE' then return 'wait', 'mode ' .. mode end
  local t = now(K)
  if (st.cool or 0) > t then return 'wait', string.format('rest %d d after the last sweep', (st.cool - t) // M.DAY + 1) end
  if n_acc == 0 then return 'wait', 'no plugged cavern shaft' end
  local lvl = type(v.ready) == 'table' and v.ready.lvl or nil
  if type(lvl) ~= 'number' or lvl < M.CFG.ready then return 'wait', string.format('R%s < R%d', tostring(lvl or '?'), M.CFG.ready) end
  local q = squad(K)
  if type(q) ~= 'table' then return 'wait', 'no squad A' end
  if (q.n or 0) < M.CFG.sol then return 'wait', string.format('squad A %d < %d soldiers', q.n or 0, M.CFG.sol) end
  if (q.worn or 0) < M.CFG.worn then return 'wait', string.format('squad A worn %d%% < %d%%', q.worn or 0, M.CFG.worn) end
  if type(v.threat) == 'table' and (v.threat.vis or 0) > 0 then return 'wait', 'hostiles in sight' end
  local hold = call(K, 'reflex', 'holding')
  if type(hold) == 'string' and hold ~= '' then return 'wait', 'lockdown' end
  return nil, nil, q
end

local function wait_step(K, t)
  if t < (rt.next or 0) then return end
  rt.next = t + M.CFG.look
  local accs = call(K, 'runner', 'cav_sealed') or {}
  local done, total, great = {}, 0, 0
  local best, bb = nil, nil
  for _, a in ipairs(accs) do
    if a.st == 'sweep' then
      -- a shaft a sweep opened that this module no longer runs (m.cavern lost, a crash): walled at once
      K.log('warn', 'cavern sweep: the shaft %s of %s stands open without a sweep: walled again', pstr(a.s0), tostring(a.id))
      call(K, 'runner', 'sweep_close', a.id)
    else
      done[#done + 1] = a
      local b, g = M.beasts(K, a)
      total, great = total + #b, great + g
      if g == 0 and #b > 0 and (not bb or #b > #bb) then best, bb = a, b end
    end
  end
  rt.n, rt.acc = total, #done
  rt.clr = (#done == 0 or total == 0) and 1 or 0
  local s, why, q = M.gates(K, #done)
  if s then rt.st, rt.why = s, why; return end
  rt.st = 'wait'
  if total == 0 then rt.why = 'no cavern beast in sight'; return end
  if not best then rt.why = 'a great danger in the cavern: Gordon decides'; return end
  start(K, best, bb, q)
end

local function hold(K, order)
  local ok, msg = call(K, 'military', 'hold_order', M.SQUAD, order, M.TAG)
  if ok ~= true then K.log('warn', 'cavern sweep: squad A order %s refused: %s', tostring(order.kind), tostring(msg)) end
  return ok == true
end

local function near_station(K, q)
  local n = 0
  for _, id in ipairs(q.ids or {}) do
    local p = unit_pos(id)
    if p and p[3] == st.sta[3] and math.max(math.abs(p[1] - st.sta[1]), math.abs(p[2] - st.sta[2])) <= M.CFG.near then n = n + 1 end
  end
  return n
end

local function add_targets(b)
  local have, ids = {}, {}
  for _, id in ipairs(st.tg) do have[id] = true end
  for _, e in ipairs(b) do
    ids[#ids + 1] = e.id
    if not have[e.id] then st.tg[#st.tg + 1] = e.id; have[e.id] = true end
  end
  return ids
end

local function run_step(K, t)
  local mode = K.mode()
  local ph = st.ph
  if M.ABORT[mode] and not st.sg and ph ~= 'close' then
    -- the kernel's own defense wins: the squad goes back to its posture at once
    st.sg, st.why = 1, st.why or 'siege'
    call(K, 'military', 'release', M.SQUAD)
    if ph == 'open' then return to_close(K, 'siege') end
    if ph ~= 'recall' then return go(K, 'recall', 'mode ' .. mode .. ': the kernel\'s defense takes squad A') end
  end
  local a = {s0 = st.pos, bot = st.bot}
  if ph == 'open' then
    local ps = call(K, 'runner', 'proj_state', st.open)
    if type(ps) ~= 'table' then return to_close(K, 'blocked') end
    if ps.done == 1 then
      st.hatch = M.hatch_at(st.pos)
      if not st.hatch then return to_close(K, 'blocked') end
      lock(K, true)
      st.sta = station(K, st.pos)
      hold(K, {kind = 'station', pos = st.sta})
      return go(K, 'muster', 'the hatch at ' .. pstr(st.pos) .. ' stands (forbidden); squad A to ' .. pstr(st.sta))
    end
    if (ps.blocked ~= '' and ps.blocked ~= 'stalled') or t - st.tp >= M.CFG.open_max then
      return to_close(K, 'blocked')
    end
  elseif ph == 'muster' then
    local q = squad(K)
    if type(q) ~= 'table' or (q.n or 0) == 0 then return to_recall(K, 'muster') end
    if not st.sg then hold(K, {kind = 'station', pos = st.sta}) end
    local n = near_station(K, q)
    local late = t - st.tp >= M.CFG.muster_max
    if 2 * n >= q.n or (late and n > 0) then
      local b, g = M.beasts(K, a)
      if g > 0 then return to_recall(K, 'great') end
      if #b == 0 then return to_recall(K, 'done') end
      lock(K, false)
      hold(K, {kind = 'kill', units = add_targets(b)})
      st.ls, st.clear = t, 0
      return go(K, 'kill', string.format('%d of %d at the shaft; the hatch opened; kill order on %d', n, q.n, #b))
    elseif late then
      return to_recall(K, 'muster')
    end
  elseif ph == 'kill' then
    st.l = count_dead(st.ids0)
    if st.l >= M.CFG.lost then return to_recall(K, 'losses') end
    if t - st.tp >= M.CFG.kill_max then return to_recall(K, 'timeout') end
    local q = squad(K)
    if type(q) == 'table' and (q.worn or 0) < M.CFG.worn then return to_recall(K, 'worn') end
    if t - (st.ls or 0) < M.CFG.scan then return end
    st.ls = t
    local b, g = M.beasts(K, a)
    st.k = kills()
    if g > 0 then return to_recall(K, 'great') end
    if #b == 0 then
      st.clear = (st.clear or 0) + 1
      if st.clear >= M.CFG.clear_looks then return to_recall(K, 'done') end
    else
      st.clear = 0
      hold(K, {kind = 'kill', units = add_targets(b)})
    end
    save(K)
  elseif ph == 'recall' then
    if not st.sg and type(st.sta) == 'table' then hold(K, {kind = 'station', pos = st.sta}) end
    local n, nc = below(K)
    -- nobody is walled in: the shaft closes once nobody stands below its top; after recall_max x 5 it closes anyway
    if n == 0 or t - st.tp >= 5 * M.CFG.recall_max then
      return to_close(K, st.why)
    end
    if n > 0 and t - st.tp >= M.CFG.recall_max and not st.rw then
      st.rw = 1
      step_ev(K, 'recall', string.format('%d soldier%s, %d other citizen%s still below the shaft top', n - nc,
                                         n - nc == 1 and '' or 's', nc, nc == 1 and '' or 's'), {n = n})
    end
  elseif ph == 'close' then
    local s = call(K, 'runner', 'cav_state', st.acc)
    if s == 'done' then return end_sweep(K, st.why or 'done', true) end
    if s == 'failed' or s == nil then return end_sweep(K, 'seal_failed', false, ' (plug ' .. tostring(st.plug) .. ' failed; was '
                                                       .. tostring(st.why) .. ')') end
    if t - st.tp >= M.CFG.close_max then
      return end_sweep(K, 'seal_failed', false, ' (plug ' .. tostring(st.plug) .. ' still building; was ' .. tostring(st.why) .. ')')
    end
  end
end

---------------------------------------------------------------- kernel hooks
function M.init(K)
  local p = K.persist.get('m.cavern')
  st = type(p) == 'table' and p.v == 1 and p or {v = 1, ph = 'wait'}
  if type(st.tg) ~= 'table' then st.tg = {} end
  rt = {next = 0, st = 'wait', why = nil, n = 0, acc = 0, clr = 0}
  -- a held order does not survive a reboot (military's runtime): it is given again by the next step
end

function M.step(K)
  local t = now(K)
  if M.RUN[st.ph] then run_step(K, t) else wait_step(K, t) end
end

-- public (runner.cavern_open, readiness): a sweep runs on record id
function M.running(K, id) return M.RUN[st.ph] == true and st.ph ~= 'close' and st.acc == id end

-- public (runner's P6 deliverable `sweep`, FR-99): the caverns count as clear (no plugged shaft known, or no beast in sight
-- at any at the last look, or (review fix) a clean sweep ended once, and no sweep running)
function M.cleared(K) return not M.RUN[st.ph] and (rt.clr == 1 or st.ok == 1) end

function M.state(K)
  local running = M.RUN[st.ph] == true
  local plan = K.plan or {}
  local on = type(plan.caverns) == 'table' and plan.caverns.sweep == true
  if not (running or on or (rt.acc or 0) > 0) then return nil end
  local c = {st = running and st.ph or (rt.st or 'wait'), n = rt.n or 0, acc = rt.acc or 0, clr = rt.clr or 0}
  local why = running and st.why or rt.why
  if not running and st.last and rt.st ~= 'off' and (st.cool or 0) > now(K) then why = 'last ' .. st.last .. '; ' .. tostring(why) end
  if why then c.why = cut(why, 60) end
  if running then c.k, c.l = int(st.k) or 0, int(st.l) or 0 elseif st.last then c.k, c.l = st.lk or 0, st.ll or 0 end
  return {cav = c}
end

M.inspect.cavern = function(K, args)
  local accs = call(K, 'runner', 'cav_sealed') or {}
  local list = {}
  for i, a in ipairs(accs) do
    if i > 8 then break end
    local b, g = M.beasts(K, a)
    local ids = {}
    for j = 1, math.min(#b, 8) do ids[j] = b[j].id end
    list[#list + 1] = {id = a.id, top = a.s0, bot = a.bot, st = a.st, beasts = #b, great = g, ids = ids}
  end
  local s, why = M.gates(K, #accs)
  return true, string.format('cavern sweep %s%s; %d plugged shaft%s', st.ph, s and (': ' .. why) or '', #accs,
                             #accs == 1 and '' or 's'),
         {ph = st.ph, why = why, acc = st.acc, pos = st.pos, hatch = st.hatch, station = st.sta, kills = kills(),
          lost = count_dead(st.ids0), last = st.last, cool = st.cool, shafts = list}
end

return M
