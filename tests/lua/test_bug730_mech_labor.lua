-- BUG-730 (Run 16d i4 Pagedsculpture y373-y374: ConstructMechanisms orders 'no job for 12 days' for months, the planned traps waiting for trapparts): a
-- stale mechanism order puts the Mechanics labor on the best idle candidate when nobody holds it, and says so in the reason
local T = require('testlib')
local F = require('wp8_world')
local OL = require('dfllm.orderlib')
local kmock = require('dfllm.util.k_mock')
local json = require('dfllm.util.json')

F.ITEM_TYPES[#F.ITEM_TYPES + 1] = 'SLAB'     -- a real items_other vector the WP8 fakes do not list

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local function settle(W) for _ = 1, 60 do W.run(1) end end
local function days(W, n) for _ = 1, n do W.run(1200, {skip = 100}); settle(W) end end

local ONE = 0                        -- df.workquota_frequency_type.OneTime in the fakes
local function add_jobs(names)
  local jt, n = df.job_type, 0
  for _, v in pairs(jt) do if type(v) == 'number' and v > n then n = v end end
  for _, nm in ipairs(names) do
    if jt[nm] == nil then n = n + 1; jt[nm] = n; jt[n] = nm end
  end
end

-- opts: phase, ghosts, shops, wood, boulders, slabs ({blank = n, memorial = n, forbidden = n}), eco (config parts),
-- mode, cit, setup(W, ctl)
local function world(opts)
  opts = opts or {}
  local ctl = {phase = opts.phase or 'P3', ghosts = opts.ghosts or 0}
  local units = {}
  for i = 1, opts.cit or 8 do units[i] = {id = i, citizen = true} end
  local cfg = F.cfg()
  for k, v in pairs(opts.eco or {}) do cfg.economy[k] = v end
  local W = F.world{cfg = {baseline = cfg}, units = units, mode = opts.mode}
  add_jobs({'ConstructSlab', 'EngraveSlab', 'SpinThread', 'ShearCreature', 'ProcessPlants', 'ConstructMechanisms'})
  df.slab_engraving_type = {Slab = -1, Memorial = 0, [-1] = 'Slab', [0] = 'Memorial'}
  df.unit_labor = {MASON = 1, CARPENTER = 2, BREWER = 3, COOK = 4, MECHANIC = 5, [1] = 'MASON', [2] = 'CARPENTER', [3] = 'BREWER',
                   [4] = 'COOK', [5] = 'MECHANIC'}
  local ids = {}
  for i = 1, opts.cit or 8 do
    ids[i] = i
    local u = W.unit(i)
    u.job = {current_job = {id = 900 + i}}
    u.status.labors = {[1] = true, [2] = true, [3] = true, [4] = true, [5] = opts.mechanic == true}
    u.mood = -1
  end
  W.set_census('u', F.census_u(ids))
  W.load({name = 'runner', every = {ticks = 600}, dig_backlog = function() return 0 end,
          pending = function(K, tpl) return (opts.pending or {})[tpl] or 0 end,
          req_types = function(K, key) return (opts.req or {})[key] end,        -- BUG-200
          state = function() return {phase = ctl.phase} end})
  W.load({name = 'care', every = {ticks = 1200},
          unreach_ids = function() return ctl.unreach or {} end,          -- BUG-518: bodies nobody can walk to
          state = function()
            if ctl.nocare then return {} end            -- BUG-177: care's first run since the boot is not done
            return {care = {stressed_pct = 0, naked = 0, ghosts = ctl.ghosts, corpses_old = 0, tombs_free = 0, moods = 0}}
          end})
  for _ = 1, 8 do F.item(W, 'BARREL', {}) end
  F.item(W, 'DRINK', {stack_size = 2000})
  F.item(W, 'FOOD', {stack_size = 2000, subtype = 1})
  for _ = 1, opts.wood or 0 do F.item(W, 'WOOD', {}) end
  for _ = 1, opts.boulders or 0 do F.item(W, 'BOULDER', {mat_type = 0, mat_index = 5}) end
  F.mat(W, 0, 5, {token = 'INORGANIC:GRANITE', flags = {}})
  local sl = opts.slabs or {}
  for _ = 1, sl.blank or 0 do F.item(W, 'SLAB', {engraving_type = -1, topic = -1}) end
  for i = 1, sl.memorial or 0 do F.item(W, 'SLAB', {engraving_type = 0, topic = 3800 + i}) end
  for _ = 1, sl.forbidden or 0 do F.item(W, 'SLAB', {engraving_type = -1, topic = -1, flags = {forbid = true}}) end
  local shops = {}
  for _, ws in ipairs(opts.shops or {'Masons', 'Carpenters'}) do shops[ws] = F.workshop(W, ws) end
  ctl.shops = shops
  W.act_result('workorder', function(spec)
    local mo = df.global.world.manager_orders
    local id = mo.manager_order_next_id
    mo.manager_order_next_id = id + 1
    mo.all:insert('#', {id = id, job_type = df.job_type[spec.job], reaction_name = spec.reaction or '',
                        amount_left = spec.amount_total, amount_total = spec.amount_total, _spec = spec,
                        item_subtype = -1, mat_type = -1, mat_index = -1, frequency = ONE,
                        item_conditions = kmock.vec{}, status = {validated = true}})
    return true, id
  end)
  W.act_result('order_remove', function(id)
    local all = df.global.world.manager_orders.all
    for i = #all - 1, 0, -1 do if all[i].id == id then all:erase(i); return true, 'removed' end end
    return false, 'no order'
  end)
  W.act_result('order_material', function(id, mat)
    for _, o in ipairs(df.global.world.manager_orders.all) do
      if o.id == id then o.mat_type, o.mat_index, o.material_category = -1, -1, {wood = true}; return true, 'wood' end
    end
    return false, 'no order'
  end)
  if opts.setup then opts.setup(W, ctl) end
  local E = fresh('economy')
  W.load(E)
  ctl.E = E
  return W, ctl
end

local function order(W, spec)
  local o = {job_type = df.job_type[spec.job], mat_type = spec.mat_type or -1, mat_index = -1,
             amount_left = spec.left or 1, material_category = spec.cat or {}, frequency = spec.freq or ONE,
             status = {validated = spec.valid ~= false}, item_conditions = kmock.vec{}, item_subtype = -1,
             reaction_name = ''}
  if spec.cond then o.item_conditions = kmock.vec{{}} end
  return F.order(W, o)
end
local function engrave(W, n) for _ = 1, n do order(W, {job = 'EngraveSlab'}) end end
local function ids_of(job)
  local r = {}
  for _, o in ipairs(df.global.world.manager_orders.all) do
    if df.job_type[o.job_type] == job then r[#r + 1] = o.id end
  end
  return r
end
local function acts(W, fn, tag)
  local r = {}
  for _, a in ipairs(W.find_acts(fn)) do
    if not tag or (type(a.args[1]) == 'table' and tostring(a.args[1].tag):sub(1, #tag) == tag) then r[#r + 1] = a end
  end
  return r
end
local function stuck(W, pat)
  local r = {}
  for _, e in ipairs(W.find_events('ORDER_STUCK')) do
    if not pat or tostring(e.msg):find(pat, 1, true) or tostring(e.d.why):find(pat, 1, true) then r[#r + 1] = e end
  end
  return r
end
local function logged(W, pat)
  for _, l in ipairs(W.logs) do if tostring(l.msg):find(pat, 1, true) then return l.msg end end
end

T.test('BUG-730: a ConstructMechanisms order with no worker holding the Mechanics labor: the labor goes on (once), kern.log says so', function()
  local W = world{boulders = 40, shops = {'Mechanics'}, setup = function(W)
    order(W, {job = 'ConstructMechanisms', mat_type = 0, left = 2})
    W.act_result('labor_set', function(id, labor, on) W.labor_calls = (W.labor_calls or 0) + 1; W.labor_who = id; W.labor_set = {labor, on}; W.unit(id).status.labors[5] = true; return true end)
  end}
  days(W, 12)
  T.eq(W.labor_calls, 1, 'one labor_set, not one a day')
  T.eq(W.labor_set, {'mechanic', true})
  T.ok(logged(W, 'Mechanics labor on for unit ' .. W.labor_who), 'kern.log names it')
  T.ok(#stuck(W, 'no worker MECHANIC') >= 1, 'ORDER_STUCK as before')
end)

T.test('BUG-730: somebody holds the Mechanics labor: nothing is changed', function()
  local W = world{boulders = 40, shops = {'Mechanics'}, mechanic = true, setup = function(W)
    order(W, {job = 'ConstructMechanisms', mat_type = 0, left = 2})
    W.act_result('labor_set', function() W.labor_calls = (W.labor_calls or 0) + 1; return true end)
  end}
  days(W, 12)
  T.eq(W.labor_calls, nil, 'no labor change')
end)

T.test('BUG-730: mech_labor_note words what mechanic_labor did', function()
  local E = require('dfllm.economy')
  local old = E.mechanic_labor
  E.mechanic_labor = function() return 'set', 7 end
  T.eq(E.mech_labor_note({}), '; Mechanics labor set on for unit 7')
  E.mechanic_labor = function() return 'none' end
  T.eq(E.mech_labor_note({}), '; no citizen can take the Mechanics labor')
  E.mechanic_labor = function() return 'have', 3 end
  T.eq(E.mech_labor_note({}), '')
  E.mechanic_labor = function() error('boom') end
  T.eq(E.mech_labor_note({}), '')
  E.mechanic_labor = old
end)

T.done()
