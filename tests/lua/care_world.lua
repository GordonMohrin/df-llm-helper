-- Test world for care's strange moods and mood reserve (live L4), on wp8_world: citizens with jobs, Kern+,
-- a revealed-tile reader, an item_flag act that really toggles the fake item's flag, stockpile contents, and
-- optional fakes for runner (phase, pending), economy (alarm) and the snapshot walk-group hook.
-- Test-only (CONTRACTS §1.4 exempts tests/**).
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')

local CW = {F = F}

CW.MANIFEST = {v = 2, burrows = {['Kern+'] = {role = 'kern'}},
               bridges = {O1 = {role = 'outer', fp = {20, 20, 10, 22, 20, 10}, levers = {{1, 1, 10}}}},
               zones = {Z4 = {{0, 0, 5, 50, 50, 5}}}}

function CW.fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end

-- economy's census.i with everything at zero but food and drink, then the overrides. `boulders` is the whole
-- BOULDER vector, `rock` the free boulders (ores and flux among them), `thread` the collected thread.
function CW.census_i(over)
  local c = {tick = 0, drink = 100, food = 100, meals = 10, meal_kinds = 3, cloth = 0, leather = 0, bone = 0, shell = 0,
             gems = 0, bars = 0, bolts = 0, wood = 0, fuel = 0, drink_forb = 0, food_forb = 0, cookable = 0,
             boulders = 0, blocks = 0, crafts = 0, barrels_empty = 10, rock = 0, ore = 0, flux = 0, thread = 0}
  for k, v in pairs(over or {}) do c[k] = v end
  return c
end

-- a strange-mood job (StrangeMoodCrafter) holding filters; attached = {{job_item_idx=, item=}}
function CW.mood_job(W, id, holder, filters, attached)
  return {id = id, job_type = df.job_type.StrangeMoodCrafter, _holder = holder,
          job_items = {elements = kmock.vec(filters or {})}, items = kmock.vec(attached or {})}
end

-- a job of another type that counts job_items reads (care may read the filters of mood jobs only)
function CW.counting_job(W, id, holder, jtype)
  return setmetatable({id = id, items = kmock.vec{}, _holder = holder, job_type = jtype},
                      {__index = function(_, k) if k == 'job_items' then W.job_items_reads = (W.job_items_reads or 0) + 1 end end})
end

-- a stockpile named `name` holding `items` (getStockpileContents returns them)
function CW.pile(W, name, items)
  local b = F.building(W, 'STOCKPILE', {name = name})
  b._items = items
  return b
end

-- opts: cit, units, persist, mode, phase, census_i (table or false), alarm (string|false: loads economy),
--       economy (true: loads economy; its reserve(key, n, who) records W.floors), economy_reserve (a replacement),
--       reach (function(a, b) -> bool, loads it on snapshot), pending ({tpl = n}), kern (false: none),
--       reserve (config overrides), setup(W); FR-61: tile (function(x, y, z) -> snapshot.tile result, default open
--       floor), snap ({name = function(K, ...)}: more snapshot functions), runner (true: the real runner module)
function CW.world(opts)
  opts = opts or {}
  local n = opts.cit or 4
  local units, ids = {}, {}
  for i = 1, n do units[i] = {id = i, citizen = true, pos = {5, 5, 5}}; ids[i] = i end
  for _, u in ipairs(opts.units or {}) do units[#units + 1] = u end
  local persist = opts.persist or {}
  if opts.manifest ~= false then persist.manifest = persist.manifest or opts.manifest or CW.MANIFEST end
  local cfg = F.cfg()
  cfg.reserve.share = {}           -- the fake forts are small: the stock share cap (live L6) is tested on its own
  for k, v in pairs(opts.reserve or {}) do cfg.reserve[k] = v end
  local W = F.world{cfg = {baseline = cfg}, units = units, mode = opts.mode, persist = persist, strict = opts.strict}
  for i = 1, n do
    local u = W.unit(i)
    u.job = {current_job = nil}
    u.mood = -1
    u.inventory = kmock.vec{{mode = 2, item = {getType = function() return df.item_type.ARMOR end}}}
    u.status = {current_soul = {personality = {emotions = kmock.vec{}}}}
    u.counters = {death_cause = 1}
  end
  W.set_census('u', F.census_u(ids))
  if opts.census_i ~= false then W.set_census('i', CW.census_i(opts.census_i)) end
  if opts.kern ~= false then W.burrow('Kern+', {0, 0, 0, 50, 50, 9}) end
  W.hidden = {}
  W.act_result('item_flag', function(id, flag, on)
    local it = W.items_by_id[id]
    if not it then return false, 'no item' end
    it.flags[flag] = on
    return true, 'set'
  end)
  dfhack.buildings.getStockpileContents = function(sp) return sp._items or {} end
  if opts.setup then opts.setup(W) end
  local snap = {name = 'snapshot', every = {ticks = 100}, tile = function(K, x, y, z)
    if W.hidden[x .. ',' .. y .. ',' .. z] then return nil end
    if opts.tile then return opts.tile(x, y, z) end
    return {c = '.', dig = '', bld = ''}
  end}
  for k, f in pairs(opts.snap or {}) do snap[k] = f end
  if opts.reach then
    snap.reach = function(K, a, b)
      W.reach_calls = (W.reach_calls or 0) + 1
      return opts.reach(a, b)
    end
  end
  W.load(snap)
  if opts.runner then
    W.load(CW.fresh('runner'))
  elseif opts.phase or opts.pending then
    W.load({name = 'runner', every = {ticks = 600},
            state = function() return {phase = W.phase or opts.phase} end,
            pending = function(K, tpl) return (opts.pending or {})[tpl] or 0 end})
  end
  if opts.alarm ~= nil or opts.economy then
    W.alarm, W.floors, W.floor_calls = opts.alarm, {}, 0
    W.load({name = 'economy', every = {ticks = 1200}, alarm = function() return W.alarm or nil end,
            reserve = opts.economy_reserve or function(K, key, n, who)
              W.floor_calls = W.floor_calls + 1
              W.floors[key] = n
              W.floor_who = who
              return true, n
            end})
  end
  local care = CW.fresh('care')
  W.load(care)
  W.state()                                  -- compose once: K.view().phase for the first care run
  return W, care
end

-- a game day; economy's census (whatever census.i the test set) is published again at midday, as the real
-- one lands between two care runs (care tops a class up only after a census newer than its last write)
function CW.day(W, n)
  for _ = 1, n or 1 do
    W.run(600, {skip = 100})
    local i = W.K.census.i
    if type(i) == 'table' then i.tick = W.K.now().tick end
    W.run(600, {skip = 100})
  end
end

-- item_flag acts as {id, flag, on}, sorted by id then flag
function CW.flags(W, flag)
  local r = {}
  for _, a in ipairs(W.find_acts('item_flag')) do
    if flag == nil or a.args[2] == flag then r[#r + 1] = {a.args[1], a.args[2], a.args[3]} end
  end
  table.sort(r, function(a, b)
    if a[1] ~= b[1] then return a[1] < b[1] end
    if a[2] ~= b[2] then return a[2] < b[2] end
    return tostring(a[3]) < tostring(b[3])
  end)
  return r
end

-- FR-27/45 tombs: a coffin with a 1x1 tomb zone over it. opts: unit (assigned, default -1), active (default
-- true), closed (no_citizens), built (default true), zone (false: no zone), coffin (false: a zone without coffin)
function CW.tomb(W, x, y, z, opts)
  opts = opts or {}
  local cof
  if opts.coffin ~= false then
    cof = F.building(W, 'COFFIN', {x1 = x, y1 = y, x2 = x, y2 = y, z = z})
    cof.relations = kmock.vec{{type = df.civzone_type.Tomb}}     -- (a vector after the copy: k_mock copies specs)
    if opts.built == false then
      cof.getBuildStage = function() return 0 end
      cof.getMaxBuildStage = function() return 1 end
    end
  end
  local zn
  if opts.zone ~= false then
    zn = F.building(W, 'ZONE_TOMB', {x1 = x, y1 = y, x2 = x, y2 = y, z = z, type = df.civzone_type.Tomb,
                                     assigned_unit_id = opts.unit or -1, spec_sub_flag = {active = opts.active ~= false},
                                     zone_settings = {tomb = {flags = {no_citizens = opts.closed == true}}}})
  end
  return cof, zn
end

-- act.tomb_zone on the fake zones (what the real act does to them): remove, free, open, assign
function CW.tomb_acts(W)
  W.act_result('tomb_zone', function(op, id, uid)
    local zn = W.buildings[id]
    if not zn then return false, 'no zone' end
    if op == 'remove' then
      local v = df.global.world.buildings.other.ZONE_TOMB
      for i = #v - 1, 0, -1 do if v[i] == zn then v:erase(i) end end
      W.buildings[id] = nil
      return true, 'removed'
    elseif op == 'free' then zn.assigned_unit_id = -1; zn.zone_settings.tomb.flags.no_citizens = false; return true, 'freed'
    elseif op == 'open' then zn.zone_settings.tomb.flags.no_citizens = false; return true, 'opened'
    elseif op == 'assign' then
      if zn.assigned_unit_id >= 0 then return false, 'held' end
      zn.assigned_unit_id = uid
      return true, 'assigned'
    end
    return false, 'bad op'
  end)
end

-- tomb_zone acts as {op, zone, unit}
function CW.tacts(W, op)
  local r = {}
  for _, a in ipairs(W.find_acts('tomb_zone')) do
    if op == nil or a.args[1] == op then r[#r + 1] = {a.args[1], a.args[2], a.args[3]} end
  end
  return r
end

function CW.held(W)
  local p = W.K.persist.get('m.care')
  local r = {}
  for cls, ids in pairs(p and p.reserve and p.reserve.held or {}) do
    if #ids > 0 then
      local c = {}
      for i, id in ipairs(ids) do c[i] = id end
      table.sort(c)
      r[cls] = c
    end
  end
  return r
end

return CW
