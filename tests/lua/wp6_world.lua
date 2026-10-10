-- WP6 test world: tests/lua/siege_world.lua (manifest, burrows, bridges, levers, lever/bridge
-- simulator) plus fake DF military structures: squads with 10 positions, routines, historical
-- figures, the fort entity's position assignments, work details, skills, attributes, inventory
-- items with materials, caravans, and act fakes for squad_create/add/remove/routine/order/uniform.
--   local X = require('wp6_world')
--   local W = X.world{n = 30}; X.load(W, {'military'}); W.run(3600, {skip = 9})
local kmock = require('dfllm.util.k_mock')
local S = require('siege_world')

local X = {S = S, Z = S.Z}
local Z = S.Z
local vec = kmock.vec
X.GROUP = 77
X.CATS = {'body', 'head', 'pants', 'gloves', 'shoes', 'shield', 'weapon'}
X.CAT_TYPE = {body = 'ARMOR', head = 'HELM', pants = 'PANTS', gloves = 'GLOVES', shoes = 'SHOES', shield = 'SHIELD',
              weapon = 'WEAPON'}
X.ROUTINES = {'Off duty', 'Staggered training', 'Constant training', 'Ready'}

---------------------------------------------------------------- units
-- a citizen inside Kern+ (S.KERN): i-th of a grid; extra = spec overrides
function X.cit(id, extra)
  local i = id % 400
  local u = {id = id, pos = {45 + i % 30, 70 + (i // 30) % 20, Z}, citizen = true, adult = true}
  for k, v in pairs(extra or {}) do u[k] = v end
  return u
end

function X.citizens(n, first, extra)
  local r = {}
  for i = 1, n do r[i] = X.cit((first or 1) + i - 1, extra) end
  return r
end

-- DF-side fields the WP6 modules read (k_mock units only fake pos/flags/military)
function X.decorate(W, u)
  local m = u._m
  u.hist_figure_id = 50000 + u.id
  W.hfs[u.hist_figure_id] = {id = u.hist_figure_id, unit_id = u.id}
  local lab = {}
  for k, v in pairs(m.labors or {}) do lab[k] = v end
  u.status.labors = lab
  u.mood = m.mood or -1
  return u
end

function X.add(W, spec) return X.decorate(W, W.add_unit(spec)) end

---------------------------------------------------------------- squads and items
function X.new_squad(W, alias)
  W.squad_seq = W.squad_seq + 1
  local s = {id = W.squad_seq, entity_id = X.GROUP, alias = alias, cur_routine_idx = 0, orders = vec{},
             positions = vec{}}
  for _ = 0, 9 do
    local uni = {}
    for _, c in ipairs(X.CATS) do uni[c] = vec{} end
    s.positions:insert('#', {occupant = -1, equipment = {uniform = uni, assigned_items = vec{}}})
  end
  W.squads[s.id] = s
  df.global.world.squads.all:insert('#', s)
  return s
end

function X.seat(W, s, pos, uid)
  local u = W.unit(uid)
  s.positions[pos].occupant = u.hist_figure_id
  u.military.squad_id, u.military.squad_position = s.id, pos
end

function X.unseat(W, s, uid)
  local u = W.unit(uid)
  for i = 0, 9 do
    if s.positions[i].occupant == u.hist_figure_id then s.positions[i].occupant = -1 end
  end
  u.military.squad_id, u.military.squad_position = -1, -1
end

-- uniform specs like act.squad_uniform would create them (df squad_uniform_spec: item = -1 or a fixed
-- item id, assigned = item ids; v1 scripts/claude/mil.lua:567). spec.positions = 0-based positions only
function X.set_uniform(s, spec)
  local only
  if spec.positions then only = {}; for _, i in ipairs(spec.positions) do only[i] = true end end
  for i, p in ipairs(s.positions) do
    if not only or only[i] then
      for _, c in ipairs(X.CATS) do p.equipment.uniform[c] = vec{} end
      for _, it in ipairs(spec.items or {}) do
        p.equipment.uniform[it.cat]:insert('#', {item_type = it.type, subtype = it.subtype, item = -1, assigned = vec{}})
      end
    end
  end
end

function X.item(W, typ, mat)
  W.item_seq = W.item_seq + 1
  local it = {id = W.item_seq, _type = typ, _mat = mat or 'INORGANIC:COPPER'}
  it.getType = function(self) return df.item_type[self._type] end
  W.items_by_id[it.id] = it
  return it
end

local function position_of(W, uid)
  local u = W.unit(uid)
  local s = W.squads[u.military.squad_id]
  if not s then return nil end
  for i = 0, 9 do if s.positions[i].occupant == u.hist_figure_id then return s.positions[i], s end end
end

-- the soldier wears items for its uniform slots: opts.n = at most n specs, opts.mat = material
-- token, opts.assign = false: worn but not assigned, opts.wear = false: assigned but not worn,
-- opts.pairs: gloves and shoes as 2 items per spec (as DF makes them), opts.skip = {cat = true}:
-- leave these specs empty, opts.orphans = n: n more worn items in assigned_items that no spec holds
function X.equip(W, uid, opts)
  opts = opts or {}
  local p = position_of(W, uid)
  assert(p, 'unit ' .. uid .. ' is not in a squad')
  local u = W.unit(uid)
  local n = 0
  local function give(c, sp)
    local it = X.item(W, X.CAT_TYPE[c], opts.mat)
    if opts.assign ~= false then
      p.equipment.assigned_items:insert('#', it.id)
      if sp then sp.assigned:insert('#', it.id) end
    end
    if opts.wear ~= false then
      local mode = (c == 'weapon' or c == 'shield') and df.inv_item_role_type.Weapon or df.inv_item_role_type.Worn
      u.inventory:insert('#', {item = it, mode = mode})
    end
  end
  for _, c in ipairs(X.CATS) do
    for _, sp in ipairs(p.equipment.uniform[c]) do
      if (opts.n == nil or n < opts.n) and not (opts.skip or {})[c] then
        give(c, sp)
        if opts.pairs and (c == 'gloves' or c == 'shoes') then give(c, sp) end
        n = n + 1
      end
    end
  end
  for _ = 1, opts.orphans or 0 do give('head', nil) end
  return n
end

function X.equip_all(W, opts)
  for _, s in pairs(W.squads) do
    for _, p in ipairs(s.positions) do
      if p.occupant >= 0 then X.equip(W, W.hfs[p.occupant].unit_id, opts) end
    end
  end
end

-- every uniform item unassigned (worn items stay in the inventory, but no spec holds them)
function X.unassign_all(W)
  for _, s in pairs(W.squads) do
    for _, p in ipairs(s.positions) do
      p.equipment.assigned_items = vec{}
      for _, c in ipairs(X.CATS) do
        for _, sp in ipairs(p.equipment.uniform[c]) do sp.assigned = vec{} end
      end
    end
  end
end

-- true if any position of the squad has a uniform spec
function X.has_uniform(s)
  for _, p in ipairs(s.positions) do
    for _, c in ipairs(X.CATS) do if #p.equipment.uniform[c] > 0 then return true end end
  end
  return false
end

function X.squad_of(W, alias)
  for _, s in pairs(W.squads) do if s.alias == alias then return s end end
end

function X.members(s)
  local n = 0
  for _, p in ipairs(s.positions) do if p.occupant >= 0 then n = n + 1 end end
  return n
end

---------------------------------------------------------------- install
function X.install(W, opts)
  opts = opts or {}
  local g = df.global
  W.squads, W.hfs, W.items_by_id = {}, {}, W.items_by_id or {}
  W.squad_seq, W.item_seq = 300, 9000
  W.create_mode, W.uniform_mode = opts.create_mode or 'ok', opts.uniform_mode or 'ok'
  g.plotinfo.group_id = X.GROUP
  g.world.squads = {all = vec{}}
  df.squad = {find = function(id) return W.squads[id] end}
  df.historical_figure = {find = function(hf) return W.hfs[hf] end}
  local routines = {}
  for i, n in ipairs(opts.routines or X.ROUTINES) do routines[i] = {id = i - 1, name = n} end
  g.plotinfo.alerts.routines = vec(routines)
  g.plotinfo.main = {fortress_entity = {positions = {
    own = vec{{id = 1, code = 'MILITIA_COMMANDER'}, {id = 2, code = 'MILITIA_CAPTAIN'}, {id = 3, code = 'MANAGER'}},
    assignments = vec{{id = 10, position_id = 1, histfig = -1, squad_id = -1},
                      {id = 11, position_id = 3, histfig = -1, squad_id = -1}}}}}
  g.plotinfo.labor_info = {work_details = vec(opts.work_details or {})}
  g.plotinfo.caravans = vec{}
  df.job_skill = kmock.enum{'MINING', 'WOODCUTTING', 'AXE', 'SWORD', 'DAGGER', 'MACE', 'HAMMER', 'SPEAR', 'CROSSBOW',
                            'SHIELD', 'ARMOR', 'PIKE', 'WHIP', 'BOW', 'BLOWGUN', 'MELEE_COMBAT', 'RANGED_COMBAT',
                            'WRESTLING', 'DODGING', 'MASONRY'}
  df.physical_attribute_type = kmock.enum{'STRENGTH', 'AGILITY', 'TOUGHNESS', 'ENDURANCE', 'RECUPERATION',
                                          'DISEASE_RESISTANCE'}
  df.inv_item_role_type = kmock.enum{'Hauled', 'Weapon', 'Worn', 'Piercing', 'Flask', 'WrappedAround', 'StuckIn',
                                     'InMouth', 'Pet', 'SewnInto', 'Strapped'}
  df.item_type = kmock.enum{'BAR', 'BOULDER', 'WEAPON', 'ARMOR', 'SHOES', 'SHIELD', 'HELM', 'GLOVES', 'PANTS', 'AMMO',
                            'QUIVER'}
  df.caravan_state = {T_trade_state = kmock.enum{'None', 'Approaching', 'AtDepot', 'Leaving', 'Stuck'}}
  local U = dfhack.units
  U.getNominalSkill = function(u, sk) return (u._m.skills or {})[df.job_skill[sk]] or 0 end
  U.getPhysicalAttrValue = function(u, a) return (u._m.attrs or {})[df.physical_attribute_type[a]] or 1000 end
  U.getNoblePositions = function(u)
    if u._m.noble then return {{position = {code = u._m.noble}}} end
  end
  dfhack.matinfo = {decode = function(it) return it and {getToken = function() return it._mat end} end}
  dfhack.military.getSquadName = function(id) local s = W.squads[id]; return s and s.alias or ('Squad ' .. id) end
  for _, u in ipairs(g.world.units.active) do X.decorate(W, u) end
  -- act fakes (the real act.lua implements these with dfhack.military, CONTRACTS §5)
  W.act_result('squad_create', function(name, o)
    if W.create_mode == 'fail' then return false, 'assignment_id required [S2]' end
    local s = X.new_squad(W, name)
    if o and o.leader and W.create_mode ~= 'noleader' then X.seat(W, s, 0, o.leader) end
    return true, s.id
  end)
  W.act_result('squad_add', function(sid, uid)
    local s = W.squads[sid]
    if not s or s.positions[0].occupant < 0 then return false, 'addToSquad refused' end
    if W.unit(uid).military.squad_id >= 0 then return false, 'already in a squad' end
    for i = 1, 9 do
      if s.positions[i].occupant < 0 then X.seat(W, s, i, uid); return true, sid end
    end
    return false, 'squad full'
  end)
  W.act_result('squad_remove', function(sid, uid)
    local s = W.squads[sid]
    if not s or W.unit(uid).military.squad_id ~= sid then return false, 'unit not in squad' end
    X.unseat(W, s, uid)
    return true
  end)
  W.act_result('squad_routine', function(sid, name)
    local s = W.squads[sid]
    if not s then return false, 'no squad' end
    for i, r in ipairs(g.plotinfo.alerts.routines) do
      if r.name:lower() == tostring(name):lower() then s.cur_routine_idx = i; return true, i end
    end
    return false, 'no routine named ' .. tostring(name)
  end)
  W.act_result('squad_order', function(sid, order)
    local s = W.squads[sid]
    if not s then return false, 'no squad' end
    s.orders = vec{}
    if order.kind == 'station' or order.kind == 'kill' then
      s.orders:insert('#', {kind = order.kind, pos = order.pos, units = order.units})
    end
    return true, order.kind
  end)
  W.act_result('squad_uniform', function(sid, spec)
    if W.uniform_mode == 'fail' then return false, 'squad_uniform not implemented until spike S2' end
    local s = W.squads[sid]
    if not s then return false, 'no squad' end
    X.set_uniform(s, spec)
    return true
  end)
  return W
end

-- DFHack fakes the REAL act.lua calls (Lua API.txt:1973-1993): makeSquad(assignment) without a
-- leader, addToSquad (fails while the leader slot is vacant), removeFromSquad, squad order types
function X.real_act(W)
  local ent = df.global.plotinfo.main.fortress_entity
  dfhack.military.makeSquad = function(aid)
    for _, a in ipairs(ent.positions.assignments) do
      if a.id == aid and a.squad_id == -1 then
        local s = X.new_squad(W, '')
        s.name = {nickname = ''}
        a.squad_id = s.id
        return s
      end
    end
  end
  dfhack.military.addToSquad = function(uid, sid, pos)
    local s, u = W.squads[sid], W.unit(uid)
    if not s or not u or s.positions[0].occupant < 0 or u.military.squad_id >= 0 then return false end
    for i = 1, 9 do
      if s.positions[i].occupant < 0 then X.seat(W, s, i, uid); return true end
    end
    return false
  end
  dfhack.military.removeFromSquad = function(uid)
    local u = W.unit(uid)
    local s = u and W.squads[u.military.squad_id]
    if not s then return false end
    X.unseat(W, s, uid)
    return true
  end
  df.squad_order_movest = {new = function() return {kind = 'station', pos = {}, delete = function() end} end}
  df.squad_order_kill_listst = {new = function() return {kind = 'kill', units = vec{}, delete = function() end} end}
end

-- a siege_world (k_mock, strict) with n citizens (ids 1..n) and the WP6 fakes
function X.world(opts)
  opts = opts or {}
  local units = opts.units or X.citizens(opts.n or 20)
  local W = S.world{units = units, persist = opts.persist, manifest = opts.manifest, mode = opts.mode,
                    lever_cfg = opts.lever_cfg, lever_default = opts.lever_default, tiefe = opts.tiefe,
                    strict = opts.strict, ytick = opts.ytick}
  return X.install(W, opts)
end

---------------------------------------------------------------- fake modules of other WPs
function X.runner(phase)
  local M = {name = 'runner', every = {ticks = 600}, phase = phase}
  function M.state(K) return M.phase and {phase = M.phase} or {} end
  return M
end

function X.economy(stock)
  local M = {name = 'economy', every = {ticks = 1200}, stock = stock or {drink_d = 200, food_d = 90, meals = 5}}
  function M.state(K) return {stock = M.stock} end
  return M
end

function X.snapshot(chars)
  local M = {name = 'snapshot', every = {ticks = 100}, exports = {}, n = 0}
  function M.export(K, o)
    M.n = M.n + 1
    M.exports[#M.exports + 1] = {opts = o, tick = K.now().tick}
    local id = 'snap' .. M.n
    K.emit('SNAPSHOT_READY', 'C', 'snapshot ' .. id, {id = id, path = 'snap/' .. id .. '.json',
                                                      purpose = type(o) == 'table' and o.purpose or 'debug'})
    return true, id
  end
  function M.tile(K, x, y, z) return {c = (chars or {})[x .. ',' .. y .. ',' .. z] or '.', dig = '', bld = ''} end
  return M
end

-- the inbox audit for a snapshot exported this boot (CONTRACTS §13: readiness accepts only those,
-- each once): export through the snapshot fake, deliver SNAPSHOT_READY, then send the verb
function X.audit(W, args)
  local _, ok, id = W.K.call('snapshot', 'export', {purpose = 'audit'})
  assert(ok, 'snapshot fake not loaded')
  W.frame(0, true)
  local a = {}
  for k, v in pairs(args) do a[k] = v end
  if a.snap == nil then a.snap = id end
  return W.inbox('audit', a, {by = 'follow'})
end

-- load WP5 modules (fresh tables) and the named WP6 modules, plus extra fakes
function X.load(W, wp6, extra, wp5)
  for _, n in ipairs(wp5 or {'sense', 'threat', 'siege', 'gate'}) do
    package.loaded['dfllm.' .. n] = nil
    W.load(require('dfllm.' .. n))
  end
  for _, n in ipairs(wp6 or {'military', 'drill', 'readiness'}) do
    package.loaded['dfllm.' .. n] = nil
    W.load(require('dfllm.' .. n))
  end
  for _, m in ipairs(extra or {}) do W.load(m) end
  return W
end

function X.mod(n) return package.loaded['dfllm.' .. n] end

-- K.call shortcut: returns the callee's values (asserts the call worked)
function X.call(W, mod, fn, ...)
  local r = table.pack(W.K.call(mod, fn, ...))
  assert(r[1], 'K.call ' .. mod .. '.' .. fn .. ': ' .. tostring(r[2]))
  return table.unpack(r, 2, r.n)
end

function X.acts(W, fn, pred)
  local r = {}
  for _, a in ipairs(W.find_acts(fn)) do if pred == nil or pred(a) then r[#r + 1] = a end end
  return r
end

-- run with the lever/bridge simulator (9-tick frames)
function X.run(W, ticks, opts) S.run(W, ticks, opts) end

return X
