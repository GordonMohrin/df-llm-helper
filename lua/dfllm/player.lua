-- dfllm.player (NEU1 P7, decision E5; docs/v2/NEU1-notausgang.md): the player's direct verbs, the emergency exit and the holds.
-- Run 16: players wrote "kein Befehl moeglich" beside a dying patient, one goblin killing six citizens in Kern+ ('lever: not allowed in
-- BREACH'), uncleaned fish without a labor verb, a lever link that waited 446 days. Two rules instead of special cases:
--  1. EMERGENCY EXIT. Once a game day the state document (K.view) and the mode are read. A critical condition (inside: BREACH or a
--     hostile inside the lockdown; gate: a manifest bridge down in SIEGE/BREACH; thirst: a patient's thirst >= player.thirst;
--     deaths:<cause>: player.deaths_n citizens of one cause within player.deaths_days) held player.exit_days game days (deaths at once)
--     opens the exit: EMERGENCY (A) wakes the player, the arbiter clamps the clock (M.clock), the tactical verbs (contract.VERB_EMG:
--     lever up in any mode, squad.station, burrow.unit, door.lock) work. It closes player.grace_days after the last critical day
--     (EMERGENCY_END, C): the stationed squads go back to the kernel, the tactical holds end. A missing reading counts as not critical
--     (fail closed: nothing is unlocked without data).
--  2. HOLDS. The act calls of a hold verb (contract.VERB_HOLD) leave holds on the objects they touched (util/hold.lua keys); kern
--     refuses the kernel's own act calls on a held object (no ACT_FAIL) for player.hold_days (tactical ones: until the exit closes).
-- Stage-1 verbs (any mode, player.verbs): zone.remove, building.remove, labor.set, workdetail.set, lever.link, furniture.place,
-- room.assign. Every verb is one click of a vanilla screen: no dig, no item, no `lua`.
local json = require('dfllm.util.json')
local C = require('dfllm.util.contract')
local HOLD = require('dfllm.util.hold')

local M = {name = 'player', every = {ticks = 1200}, verbs = {}, on = {}}
local DAY = C.TICKS.DAY

M.DEF = {exit = true, exit_days = 1, grace_days = 3, thirst = 50000, deaths_n = 2, deaths_days = 14, slow = true,
         verbs = true, hold = true, hold_days = 28}
M.LIM = {exit_days = {0, 30}, grace_days = {0, 60}, thirst = {10000, 200000}, deaths_n = {1, 20}, deaths_days = {1, 120},
         hold_days = {1, 400}}
M.BOOLS = {exit = true, slow = true, verbs = true, hold = true}
M.IGNORE = {old_age = true, other = true}       -- care died_y keys that are no avoidable cause (old age, the rest of the top 5)
M.HOLDS_MAX = 200
-- furniture.place: the quickfort build key of one piece (schema.FURNITURE)
M.FURNITURE = {bed = 'b', table = 't', chair = 'c', door = 'd', cabinet = 'f', chest = 'h', coffin = 'n', weapon_rack = 'r',
               armor_stand = 'a', statue = 's', hatch = 'H'}
M.EMG_VERBS = {'lever (up, any mode)', 'squad.station', 'squad.sortie', 'burrow.unit', 'door.lock'}

local function int(v) return type(v) == 'number' and math.tointeger(v) or nil end

local st            -- persisted m.player: {v = 1, holds = {{k, u, v, e}}, crit = {cond = since}, dl = {cause = n}, dt = {cause = {ticks}},
                    --  emg = {since, last, why = {conds}, sq = {key = true}} | nil}
local cfg = nil     -- the knobs of the last step (M.held runs outside a module call)

-- the knobs of config/baseline.json `player`; a value of another type or out of range keeps its default (fairplay.player_errors)
function M.conf(base)
  local c = {}
  for k, v in pairs(M.DEF) do c[k] = v end
  local p = type(base) == 'table' and type(base.player) == 'table' and base.player or nil
  if not p then return c end
  for k in pairs(M.BOOLS) do if type(p[k]) == 'boolean' then c[k] = p[k] end end
  for k, lim in pairs(M.LIM) do
    local v = int(p[k])
    if v and v >= lim[1] and v <= lim[2] then c[k] = v end
  end
  return c
end

local function fresh() return {v = 1, holds = {}, crit = {}, dl = {}, dt = {}} end
local function save(K) K.persist.set('m.player', st) end
local function conf(K) cfg = M.conf(K.cfg and K.cfg.baseline); return cfg end

function M.init(K)
  local p = K.persist.get('m.player')
  st = type(p) == 'table' and p or fresh()
  for _, k in ipairs({'holds', 'crit', 'dl', 'dt'}) do if type(st[k]) ~= 'table' then st[k] = {} end end
  if type(st.emg) ~= 'table' then st.emg = nil end
  conf(K)
end

---------------------------------------------------------------- the readings
-- the critical conditions now: {cond = true}; `now` the abs tick (deaths are counted from the rises of care's died_y)
function M.readings(K, c, now)
  local v = K.view()
  v = type(v) == 'table' and v or {}
  local mode = K.mode()
  local out = {}
  local al = type(v.alarm) == 'table' and v.alarm or nil
  if mode == 'BREACH' or (al and al.qw == 'inside') then out.inside = true end
  if mode == 'SIEGE' or mode == 'BREACH' then
    local man = K.manifest()
    local br = type(v.bridges) == 'table' and v.bridges or {}
    for name in pairs(type(man) == 'table' and type(man.bridges) == 'table' and man.bridges or {}) do
      if br[name] == 'down' then out.gate = true end
    end
  end
  local w = type(v.water) == 'table' and v.water or nil
  if w and (int(w.patients) or 0) > 0 and (int(w.thirst_max) or 0) >= c.thirst then out.thirst = true end
  local care = type(v.care) == 'table' and v.care or nil
  local dy = care and type(care.died_y) == 'table' and care.died_y or nil
  if dy then
    for cause, n in pairs(dy) do
      n = int(n)
      if n and type(cause) == 'string' and not M.IGNORE[cause] then
        local last = int(st.dl[cause])
        if last and n > last then
          local l = type(st.dt[cause]) == 'table' and st.dt[cause] or {}
          for _ = 1, math.min(n - last, 20) do l[#l + 1] = now end
          st.dt[cause] = l
        end
        st.dl[cause] = n          -- the first reading of a cause is its baseline (old deaths open nothing)
      end
    end
  end
  for cause, l in pairs(st.dt) do
    local keep = {}
    for _, t in ipairs(type(l) == 'table' and l or {}) do
      if int(t) and now - t <= c.deaths_days * DAY then keep[#keep + 1] = t end
    end
    st.dt[cause] = #keep > 0 and keep or nil
    if #keep >= c.deaths_n then out['deaths:' .. cause] = true end
  end
  return out
end

local function sorted(set)
  local r = {}
  for k in pairs(set) do r[#r + 1] = k end
  table.sort(r)
  return r
end

local function until_tick(c) return st.emg and ((int(st.emg.last) or 0) + c.grace_days * DAY) or 0 end

-- public (gate's lever verb, own tactical verbs, K.call): the emergency exit is open now
function M.open(K)
  local c = cfg or conf(K)
  return c.exit == true and st ~= nil and st.emg ~= nil
end

-- public (arbiter.clamp_why, K.call): why the clock is clamped for the exit, or nil
function M.clock(K)
  local c = cfg or conf(K)
  if M.open(K) and c.slow then return 'emergency' end
  return nil
end

local function emit_open(K, c, now, added)
  local e = st.emg
  local why = table.concat(e.why, ' ')
  local days = 0
  for _, k in ipairs(e.why) do
    local s = int(st.crit[k])
    if s then days = math.max(days, (now - s) // DAY) end
  end
  K.emit('EMERGENCY', 'A', string.format('EMERGENCY %s: %s (%d days). Unlocked until the state ends + %d days: %s. ' ..
                                         'Holds keep the kernel from undoing them.', added and 'grows' or 'open', why, days,
                                         c.grace_days, table.concat(M.EMG_VERBS, ', ')),
         {why = why:sub(1, 200), verbs = json.array(M.EMG_VERBS), ['until'] = until_tick(c), days = days,
          causes = json.array(e.why)})
end

local function close(K, why)
  local e = st.emg
  if not e then return end
  for key in pairs(type(e.sq) == 'table' and e.sq or {}) do K.call('military', 'release', key, 'player') end
  local keep = {}
  for _, h in ipairs(st.holds) do if h.e ~= 1 then keep[#keep + 1] = h end end
  st.holds = keep
  local days = (K.now().tick - (int(e.since) or K.now().tick)) // DAY
  st.emg = nil
  K.emit('EMERGENCY_END', 'C', string.format('emergency exit closed (%s) after %d days; tactical verbs locked again', why, days),
         {why = why, days = days})
end

function M.step(K)
  local c = conf(K)
  local now = K.now().tick
  local keep = {}
  for _, h in ipairs(st.holds) do if type(h) == 'table' and (int(h.u) or 0) > now then keep[#keep + 1] = h end end
  st.holds = keep
  if not c.exit then
    if st.emg then close(K, 'exit off') end
    st.crit = {}
    save(K)
    return
  end
  local r = M.readings(K, c, now)
  for k in pairs(st.crit) do if not r[k] then st.crit[k] = nil end end
  local due = {}
  for k in pairs(r) do
    st.crit[k] = int(st.crit[k]) or now
    if k:sub(1, 7) == 'deaths:' or now - st.crit[k] >= c.exit_days * DAY then due[k] = true end
  end
  if next(due) then
    if not st.emg then
      st.emg = {since = now, last = now, why = sorted(due), sq = {}}
      emit_open(K, c, now, false)
      K.log('info', 'player: emergency exit open: %s', table.concat(st.emg.why, ' '))
    else
      st.emg.last = now
      local had, added = {}, false
      for _, k in ipairs(st.emg.why) do had[k] = true end
      for _, k in ipairs(sorted(due)) do if not had[k] then st.emg.why[#st.emg.why + 1] = k; added = true end end
      if added then emit_open(K, c, now, true) end
    end
  elseif st.emg and now >= until_tick(c) then
    close(K, 'quiet ' .. c.grace_days .. ' days')
  end
  save(K)
end

function M.state(K)
  if not (st and st.emg) then return {} end
  local c = cfg or conf(K)
  local left = math.max(0, (until_tick(c) - K.now().tick) // DAY)
  return {emg = {o = 1, why = table.concat(st.emg.why, ' '):sub(1, 60), left = left}}
end

---------------------------------------------------------------- holds
-- public (kern's act env, a plain call): the verb that holds one of `keys`, or nil
function M.held(keys, now)
  if not st or (cfg and cfg.hold == false) then return nil end
  local h = HOLD.match(st.holds, keys, now)
  return h and tostring(h.v or '?') or nil
end

-- public (kern after a successful hold verb): the act calls {fn, args, res} of that verb leave their holds
function M.hold_acts(K, acts, verb)
  local c = conf(K)
  if not c.hold then return 0 end
  local now = K.now().tick
  local emg = C.VERB_EMG[verb] == true and st.emg ~= nil
  local u = emg and until_tick(c) or now + c.hold_days * DAY
  local n = 0
  for _, a in ipairs(type(acts) == 'table' and acts or {}) do
    for _, k in ipairs(HOLD.recorded(HOLD.keys(a.fn, a.args, a.res))) do
      for i = #st.holds, 1, -1 do if st.holds[i].k == k then table.remove(st.holds, i) end end
      st.holds[#st.holds + 1] = {k = k, u = u, v = verb, e = emg and 1 or nil}
      n = n + 1
    end
  end
  while #st.holds > M.HOLDS_MAX do table.remove(st.holds, 1) end
  if n > 0 then save(K) end
  return n
end

---------------------------------------------------------------- verbs
local function stage1(K)
  if not conf(K).verbs then return 'player verbs are off (config player.verbs)' end
end
local function tactical(K, verb)
  if not M.open(K) then
    return verb .. ' only while the emergency exit is open (no EMERGENCY now; ' ..
           (conf(K).exit and 'it opens when a critical state holds a day)' or 'config player.exit is off)')
  end
end
local function held_note(K, verb)
  local c = conf(K)
  if not c.hold then return '' end
  if C.VERB_EMG[verb] then return '; held until the exit closes' end
  return string.format('; held %d days', c.hold_days)
end

M.verbs['zone.remove'] = function(K, args)
  local no = stage1(K); if no then return false, no end
  local ok, res = K.act.building_remove(args.id, 'zone')
  if not ok then return false, 'zone.remove: ' .. tostring(res) end
  return true, string.format('zone %d %s%s', args.id, res.how == 'gone' and 'removed' or 'marked for removal',
                             held_note(K, 'zone.remove')), {how = res.how}
end

M.verbs['building.remove'] = function(K, args)
  local no = stage1(K); if no then return false, no end
  local ok, res = K.act.building_remove(args.id, 'building', args.approve == true)
  if not ok then return false, 'building.remove: ' .. tostring(res) end
  return true, string.format('%s %d %s%s', tostring(res.type), args.id, res.how == 'gone' and 'removed' or 'marked for removal',
                             held_note(K, 'building.remove')), {how = res.how}
end

M.verbs['labor.set'] = function(K, args)
  local no = stage1(K); if no then return false, no end
  local ok, res = K.act.labor_set(args.unit, args.labor, args.on == true, true)
  if not ok then return false, 'labor.set: ' .. tostring(res) end
  return true, string.format('unit %d %s %s%s', args.unit, args.labor, tostring(res), held_note(K, 'labor.set'))
end

M.verbs['workdetail.set'] = function(K, args)
  local no = stage1(K); if no then return false, no end
  local ok, res = K.act.work_detail(args.detail, args.unit, args.on == true)
  if not ok then return false, 'workdetail.set: ' .. tostring(res) end
  return true, string.format('unit %d %s %s%s', args.unit, args.on and 'joins' or 'leaves', args.detail,
                             held_note(K, 'workdetail.set'))
end

-- the building at the centre of a manifest bridge's footprint, or nil
local function bridge_id(K, name)
  local man = K.manifest()
  local b = type(man) == 'table' and type(man.bridges) == 'table' and man.bridges[name] or nil
  local fp = type(b) == 'table' and b.fp or nil
  if type(fp) ~= 'table' or #fp < 6 then return nil end
  local x, y, z = (fp[1] + fp[4]) // 2, (fp[2] + fp[5]) // 2, fp[3]
  local ok, bld = pcall(function() return dfhack.buildings.findAtTile(x, y, z) end)
  return ok and bld and int(bld.id) or nil
end

M.verbs['lever.link'] = function(K, args)
  local no = stage1(K); if no then return false, no end
  local target = int(args.target)
  if not target then
    target = bridge_id(K, args.bridge)
    if not target then return false, 'lever.link: no built bridge ' .. tostring(args.bridge) .. ' in the manifest' end
  end
  local ok, res = K.act.link_lever(args.lever, target)
  if not ok then return false, 'lever.link: ' .. tostring(res) end
  return true, string.format('lever %d -> building %d: %s%s', args.lever, target,
                             res == 'linked' and 'already linked' or ('link job ' .. tostring(res)), held_note(K, 'lever.link'))
end

M.verbs['furniture.place'] = function(K, args)
  local no = stage1(K); if no then return false, no end
  local key = M.FURNITURE[args.kind]
  if not key then return false, 'furniture.place: kind must be one of the build > furniture pieces' end
  local p = args.pos
  local ok, res = K.act.quickfort({mode = 'build', data = {[0] = {[0] = {[0] = key}}}, pos = {p[1], p[2], p[3]}})
  if not ok then return false, 'furniture.place: ' .. tostring(res) end
  local n = type(res) == 'table' and int(res.build_designated) or nil
  if n == 0 then
    return false, string.format('furniture.place: quickfort placed no %s at %d,%d,%d (no free floor there, or no %s to build it)',
                                args.kind, p[1], p[2], p[3], args.kind)
  end
  return true, string.format('%s designated at %d,%d,%d (a builder brings the piece)', args.kind, p[1], p[2], p[3])
end

M.verbs['room.assign'] = function(K, args)
  local no = stage1(K); if no then return false, no end
  local ok, res = K.act.zone_assign(args.zone, args.unit)
  if not ok then return false, 'room.assign: ' .. tostring(res) end
  return true, string.format('zone %d assigned to unit %d%s', args.zone, args.unit, held_note(K, 'room.assign'))
end

M.verbs['squad.station'] = function(K, args)
  local no = tactical(K, 'squad.station'); if no then return false, no end
  local key = args.squad
  if args.release == true then
    local ok, res = K.call('military', 'release', key, 'player')
    if st.emg and st.emg.sq then st.emg.sq[key] = nil end
    if not ok then return false, 'squad.station: ' .. tostring(res) end
    return true, 'squad ' .. key .. ' back to the kernel'
  end
  if type(args.pos) ~= 'table' then return false, 'squad.station needs pos=x,y,z (or release=true)' end
  local okc, ok, res = K.call('military', 'hold_order', key, {kind = 'station', pos = args.pos}, 'player')
  if not okc then return false, 'squad.station: military: ' .. tostring(ok) end
  if not ok then return false, 'squad.station: ' .. tostring(res) end
  st.emg.sq = type(st.emg.sq) == 'table' and st.emg.sq or {}
  st.emg.sq[key] = true
  save(K)
  local p = args.pos
  return true, string.format('squad %s stationed at %d,%d,%d (%s) until release=true or the exit closes', key, p[1], p[2], p[3],
                             tostring(res))
end

-- the burrow's living citizens now (the act takes the whole list), or nil, why
local function members(name)
  local ok, r = pcall(function()
    local b = dfhack.burrows.findByName(name)
    if not b then return nil end
    local ids = {}
    for _, id in ipairs(b.units) do
      local u = df.unit.find(id)
      if u and dfhack.units.isCitizen(u) and not dfhack.units.isDead(u) then ids[#ids + 1] = id end
    end
    return ids
  end)
  if not ok then return nil, tostring(r) end
  if not r then return nil, 'no burrow ' .. name end
  return r
end

M.verbs['burrow.unit'] = function(K, args)
  local no = tactical(K, 'burrow.unit'); if no then return false, no end
  local ids, why = members(args.burrow)
  if not ids then return false, 'burrow.unit: ' .. tostring(why) end
  local list, had = {}, false
  for _, id in ipairs(ids) do
    if id == args.unit then had = true end
    if id ~= args.unit or args.on then list[#list + 1] = id end
  end
  if args.on and not had then list[#list + 1] = args.unit end
  local ok, res = K.act.burrow_units(args.burrow, list)
  if not ok then return false, 'burrow.unit: ' .. tostring(res) end
  return true, string.format('unit %d %s burrow %s (%d members)%s', args.unit, args.on and 'in' or 'out of', args.burrow, #list,
                             held_note(K, 'burrow.unit'))
end

M.verbs['door.lock'] = function(K, args)
  local no = tactical(K, 'door.lock'); if no then return false, no end
  local ok, res = K.act.door_forbid(args.door, args.on == true, args.on == true)
  if not ok then return false, 'door.lock: ' .. tostring(res) end
  return true, string.format('door %d %s (was %s)%s', args.door, args.on and 'locked' or 'unlocked', res and 'locked' or 'open',
                             held_note(K, 'door.lock'))
end

return M
