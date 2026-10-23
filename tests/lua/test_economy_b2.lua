-- B2: BUG-061 (the EngraveSlab jam, autoslab restock), BUG-060 (orders that make no job), FR-73 (standing thread and
-- cloth orders, the farmer's workshop request). Run 13 y508/y523, Run 14 y558-y577.
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
  add_jobs({'ConstructSlab', 'EngraveSlab', 'SpinThread', 'ShearCreature', 'ProcessPlants'})
  df.slab_engraving_type = {Slab = -1, Memorial = 0, [-1] = 'Slab', [0] = 'Memorial'}
  df.unit_labor = {MASON = 1, CARPENTER = 2, BREWER = 3, COOK = 4, [1] = 'MASON', [2] = 'CARPENTER', [3] = 'BREWER',
                   [4] = 'COOK'}
  local ids = {}
  for i = 1, opts.cit or 8 do
    ids[i] = i
    local u = W.unit(i)
    u.job = {current_job = {id = 900 + i}}
    u.status.labors = {[1] = true, [2] = true, [3] = true, [4] = true}
    u.mood = -1
  end
  W.set_census('u', F.census_u(ids))
  W.load({name = 'runner', every = {ticks = 600}, dig_backlog = function() return 0 end,
          state = function() return {phase = ctl.phase} end})
  W.load({name = 'care', every = {ticks = 1200},
          state = function() return {care = {stressed_pct = 0, naked = 0, ghosts = ctl.ghosts, corpses_old = 0,
                                             tombs_free = 0, moods = 0}} end})
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

---------------------------------------------------------------- orderlib and the library
T.test('orderlib: EngraveSlab at the masons with its own input key, SpinThread at the farmers', function()
  T.eq(OL.workshops('EngraveSlab', 'any'), {'workshop:Masons'})
  T.eq(OL.workshops('SpinThread', 'any'), {'workshop:Farmers'})
  T.eq(OL.workshops('ShearCreature', 'any'), nil, 'a Gathering job: no workshop claimed')
  T.eq(OL.input('EngraveSlab', 'any'), 'slab_blank')
  T.eq(OL.labors('SpinThread', 'any', OL.workshops('SpinThread', 'any')), {'SPINNER'})
end)

T.test('orderfix: engrave_split keeps min(max, blank) of the oldest, restock covers ghosts and orders', function()
  local OF = require('dfllm.orderfix')
  local k, d = OF.engrave_split({4, 5, 9, 12, 13}, 0, 3)
  T.eq({#k, #d}, {0, 5})
  k, d = OF.engrave_split({4, 5, 9, 12, 13}, 2, 3)
  T.eq({k, d}, {{4, 5}, {9, 12, 13}})
  k, d = OF.engrave_split({4, 5, 9, 12, 13}, 40, 3)
  T.eq({k, d}, {{4, 5, 9}, {12, 13}})
  T.eq({OF.restock(0, 0, 0, 0, 5)}, {0, 0}, 'no ghost, no order: no slab')
  T.eq({OF.restock(0, 0, 6, 0, 5)}, {5, 5}, 'six ghosts, capped at 5')
  T.eq({OF.restock(2, 1, 6, 0, 5)}, {2, 5}, 'stock and ConstructSlab orders count')
  T.eq({OF.restock(0, 0, 0, 31, 5)}, {5, 5}, 'open engrave orders want slabs too')
  T.eq(OF.simple_spec({amount_left = 5, item_conditions = {}, item_subtype = -1, reaction_name = ''}, 'ConstructDoor',
                      'rock'), {job = 'ConstructDoor', amount_total = 5, frequency = 'OneTime', material = 'INORGANIC'})
  T.eq(OF.simple_spec({amount_left = 5, item_conditions = {{}}, item_subtype = -1}, 'ConstructDoor', 'rock'), nil)
  T.eq(OF.simple_spec({amount_left = 5, item_conditions = {}, item_subtype = -1}, 'MakeBarrel', 'wood'), nil)
  T.eq(OF.simple_spec({amount_left = 5, item_conditions = {}, item_subtype = -1}, 'ConstructDoor', 'metal'), nil)
end)

T.test('orderfix: the slab census reads engraving_type (Slab = -1 blank, Memorial = 0) and the free flags', function()
  local W = world{slabs = {blank = 3, memorial = 4, forbidden = 2}}
  local OF = require('dfllm.orderfix')
  local s = OF.slabs()
  T.eq({s.blank, s.held, s.memorial, s.other, s.n}, {3, 2, 4, 0, 9})
  T.ok(s.topics[3801] and s.topics[3804], 'memorial topics = historical figures')
end)

---------------------------------------------------------------- BUG-061
T.test('BUG-061: 31 EngraveSlab orders and no unengraved slab: all removed (named in the log), ConstructSlab first', function()
  local W = world{ghosts = 6, boulders = 40, setup = function(W) engrave(W, 31) end}
  order(W, {job = 'ConstructDoor', mat_type = 0, left = 4})
  days(W, 1)
  T.eq(#acts(W, 'order_remove'), 31)
  T.eq(ids_of('EngraveSlab'), {}, 'none left')
  T.eq(#ids_of('ConstructDoor'), 1, 'the door order stays')
  local cs = acts(W, 'workorder', 'dfllm:slab')
  T.eq(#cs, 1)
  T.eq({cs[1].args[1].job, cs[1].args[1].amount_total, cs[1].args[1].material}, {'ConstructSlab', 5, 'INORGANIC'},
       'min(restock_cap 5, max(6 ghosts, 31 orders))')
  T.ok(logged(W, 'EngraveSlab: 31 orders, 0 unengraved slabs'), 'the log line names the pass')
  T.ok(logged(W, 'orders 1,2,3,4,5,6,7,8,9,10,11,12 +19 removed, 0 kept'), 'and the orders')
  local ev = stuck(W, 'EngraveSlab')
  T.eq(#ev, 1)
  T.eq({ev[1].d.job, ev[1].d.n, ev[1].d.dropped}, {'EngraveSlab', 31, 1})
  days(W, 3)
  T.eq(#acts(W, 'workorder', 'dfllm:slab'), 1, 'the open ConstructSlab order is not ordered again')
  T.eq(#stuck(W, 'EngraveSlab'), 1, 'one announcement')
end)

T.test('BUG-061: with unengraved slabs the oldest min(3, slabs) orders stay', function()
  local W = world{boulders = 40, slabs = {blank = 2}, setup = function(W) engrave(W, 7) end}
  days(W, 1)
  T.eq(ids_of('EngraveSlab'), {1, 2})
  local W2 = world{boulders = 40, slabs = {blank = 9}, setup = function(W) engrave(W, 7) end}
  days(W2, 1)
  T.eq(ids_of('EngraveSlab'), {1, 2, 3}, 'slabs.max_orders')
  local W3 = world{boulders = 40, slabs = {forbidden = 4, blank = 0}, setup = function(W) engrave(W, 2) end}
  days(W3, 1)
  T.eq(ids_of('EngraveSlab'), {}, 'forbidden slabs are no blank slabs')
end)

T.test('BUG-061: the first "unengraved slab" cancel cuts the orders back at once, once per window', function()
  local W = world{boulders = 40}
  days(W, 1)
  engrave(W, 5)                                                -- autoslab queued them again
  W.event('REPORT', {type = 'CANCEL_JOB', text = 'Urist cancels Engrave Memorial Slab: Needs unengraved slab.'})
  W.run(1)
  T.eq(ids_of('EngraveSlab'), {}, 'removed without waiting for the daily pass')
  engrave(W, 3)
  W.event('REPORT', {type = 'CANCEL_JOB', text = 'Urist cancels Engrave Memorial Slab: Needs unengraved slab.'})
  W.run(1)
  T.eq(#ids_of('EngraveSlab'), 3, 'a second cancel inside slabs.trigger_ticks waits')
  W.run(700, {skip = 100})
  W.event('REPORT', {type = 'CANCEL_JOB', text = 'Urist cancels Engrave Memorial Slab: Needs unengraved slab.'})
  W.run(1)
  T.eq(ids_of('EngraveSlab'), {}, 'the next window')
end)

T.test('BUG-061 (note 56): ghosts and no unengraved slab, no engrave order yet: ConstructSlab for them, none when stocked', function()
  local W = world{ghosts = 3, boulders = 40, slabs = {memorial = 2}}
  days(W, 1)
  local cs = acts(W, 'workorder', 'dfllm:slab')
  T.eq(#cs, 1)
  T.eq(cs[1].args[1].amount_total, 3)
  local W2 = world{ghosts = 3, boulders = 40, slabs = {blank = 3}}
  days(W2, 1)
  T.eq(#acts(W2, 'workorder', 'dfllm:slab'), 0, 'three blank slabs cover three ghosts')
  local W3 = world{ghosts = 0, boulders = 40}
  days(W3, 1)
  T.eq(#acts(W3, 'workorder', 'dfllm:slab'), 0, 'no ghost, no engrave order: no slab')
  -- no masons or no stone: no order, the reason is kept
  local W4 = world{ghosts = 3, boulders = 40, shops = {'Carpenters'}}
  days(W4, 1)
  T.eq(#acts(W4, 'workorder', 'dfllm:slab'), 0)
  local r = W4.inbox('inspect', {what = 'orders'})
  T.eq(r.data.slabs.why, 'no Masons')
  local W5 = world{ghosts = 3, boulders = 1}
  days(W5, 1)
  T.eq(#acts(W5, 'workorder', 'dfllm:slab'), 0)
  T.ok(W5.inbox('inspect', {what = 'orders'}).data.slabs.why:find('free boulders for 3 slabs', 1, true))
end)

T.test('BUG-061: drop_per_day bounds the removals; slabs = false switches the pass off', function()
  local W = world{boulders = 40, eco = {slabs = {max_orders = 3, restock_cap = 5, drop_per_day = 10, trigger_ticks = 600,
                                                scan_max = 2000, jam_min = 3}}, setup = function(W) engrave(W, 31) end}
  days(W, 1)
  T.eq(#acts(W, 'order_remove'), 10)
  local W2 = world{boulders = 40, eco = {slabs = false}, setup = function(W) engrave(W, 5) end}
  days(W2, 2)
  T.eq(#acts(W2, 'order_remove'), 0)
end)

T.test('BUG-061: the masons\' slots full of cancelling jobs are the reason (ORDER_STUCK, inspect orders, state)', function()
  local W, ctl = world{boulders = 40, wood = 20, eco = {slabs = {max_orders = 3, restock_cap = 5, drop_per_day = 0,
                       trigger_ticks = 600, scan_max = 2000, jam_min = 3}}, setup = function(W, ctl)
    order(W, {job = 'ConstructDoor', mat_type = 0, left = 4})         -- id 1: a victim, no job of its own
    engrave(W, 5)                                                      -- ids 2-6
  end}
  local jobs = {}
  for i = 1, 5 do jobs[i] = {job_type = df.job_type.EngraveSlab, order_id = i + 1, flags = {working = false}} end
  ctl.shops.Masons.jobs = kmock.vec(jobs)
  days(W, 4)
  local ev = stuck(W, 'ConstructDoor')
  T.eq(#ev, 1, 'the door order is stuck for three days')
  T.ok(ev[1].d.why:find("masons' slots full of cancelling jobs (EngraveSlab x5: no unengraved slab)", 1, true), ev[1].d.why)
  local st = W.state()
  T.ok(st.orders.jam and st.orders.jam:find("masons' slots full", 1, true), 'state orders.jam')
  local r = W.inbox('inspect', {what = 'orders'})
  T.ok(r.msg:find('JAM', 1, true), r.msg)
  T.ok(r.data.jam:find("masons'", 1, true))
  local m
  for _, s in ipairs(r.data.shops) do if s.ws == 'workshop:Masons' then m = s end end
  T.eq({m.shops, m.jobs, m.working, m.blocked}, {1, 5, 0, 5})
  T.ok(r.data.slabs and r.data.slabs.blank == 0)
end)

T.test('BUG-061: 4 jobs of 10 blocked is no jam (fewer than half), 2 of 2 is none either (jam_min 3)', function()
  local OF = require('dfllm.orderfix')
  local e = {jobs = 10, list = {}}
  for i = 1, 10 do e.list[i] = {job = i <= 4 and 'EngraveSlab' or 'ConstructDoor', order = i, working = false} end
  local blocked = {[1] = true, [2] = true, [3] = true, [4] = true}
  T.eq((OF.jam_text('workshop:Masons', e, blocked, {}, 3)), nil)
  e.jobs = 7
  T.ok(OF.jam_text('workshop:Masons', e, blocked, {EngraveSlab = 'no unengraved slab'}, 3):find("masons' slots", 1, true))
  T.eq((OF.jam_text('workshop:Masons', {jobs = 2, list = {{job = 'a', order = 1}, {job = 'a', order = 2}}},
                    {[1] = true, [2] = true}, {}, 3)), nil)
end)

---------------------------------------------------------------- BUG-060
local function doors(W, n, cond)
  for _ = 1, n do order(W, {job = 'ConstructDoor', mat_type = 0, left = 5, cond = cond}) end
end

T.test('BUG-060: stone door orders with no job for stale.days are re-entered in wood (Run 13 y508)', function()
  local W = world{boulders = 40, wood = 80, setup = function(W) doors(W, 11) end}
  days(W, 6)
  T.eq(#acts(W, 'order_material'), 0, 'not before stale.days')
  days(W, 5)
  local sw = acts(W, 'order_material')
  T.eq(#sw, 6, 'stale.per_day orders the first day')
  T.eq(sw[1].args, {n = 2, 1, 'wood'})
  local ev = stuck(W, 'stale')
  T.eq(#ev, 6)
  T.ok(ev[1].d.why:find('Masons: 1 shop, 0 jobs (0 working), none from this order', 1, true), ev[1].d.why)
  T.ok(ev[1].d.why:find('free boulders', 1, true))
  T.ok(ev[1].msg:find('re-entered in wood', 1, true), ev[1].msg)
  T.eq({ev[1].d.job, ev[1].d.n, ev[1].d.dropped}, {'ConstructDoor', 5, 0})
  T.ok(logged(W, 'no job for 1'), 'kern.log names it')
  days(W, 1)
  T.eq(#acts(W, 'order_material'), 11, 'the rest on the next day')
  days(W, 12)
  T.eq(#acts(W, 'order_material'), 11, 'a wood order is not switched again')
end)

T.test('BUG-060: an order with a job in a workshop, a changing amount, conditions or another frequency is never stale', function()
  local W, ctl = world{boulders = 40, wood = 40, setup = function(W)
    doors(W, 1)                                          -- 1: has a job
    doors(W, 1)                                          -- 2: its amount changes
    doors(W, 1, true)                                    -- 3: item conditions
    order(W, {job = 'ConstructDoor', mat_type = 0, left = 5, freq = 1})   -- 4: Daily
    order(W, {job = 'ConstructDoor', mat_type = 0, left = 5, valid = false})   -- 5: unvalidated
    doors(W, 1)                                          -- 6: the control: no job, nothing else wrong
  end}
  ctl.shops.Masons.jobs = kmock.vec{{job_type = df.job_type.ConstructDoor, order_id = 1, flags = {working = true}}}
  for d = 1, 14 do
    days(W, 1)
    for _, o in ipairs(df.global.world.manager_orders.all) do if o.id == 2 then o.amount_left = 5 - (d % 4) end end
  end
  local sw = acts(W, 'order_material')
  T.eq(#sw, 1, 'only the control order (id 6) went wood')
  T.eq(sw[1].args[1], 6)
  T.eq(#stuck(W, 'stale'), 1)
end)

T.test('BUG-060: no carpenters or logs: a simple order is made again (the new one first), else only reported', function()
  local W = world{boulders = 40, shops = {'Masons'}, setup = function(W) doors(W, 1) end}
  days(W, 11)
  T.eq(#acts(W, 'order_material'), 0, 'no carpenters')
  local again = acts(W, 'workorder', 'dfllm:redo_')
  T.eq(#again, 1)
  T.eq({again[1].args[1].job, again[1].args[1].amount_total, again[1].args[1].material, again[1].args[1].tag},
       {'ConstructDoor', 5, 'INORGANIC', 'dfllm:redo_1'})
  local left = ids_of('ConstructDoor')
  T.ok(#left == 1 and left[1] ~= 1, 'the old one is gone, the new one stands')
  local ev = stuck(W, 'stale')
  T.eq(#ev, 1)
  T.eq(ev[1].d.dropped, 1)
  T.ok(ev[1].msg:find('made again', 1, true))
  -- nothing can make it (no free stone for a new one): reported only, once
  local W2 = world{boulders = 0, shops = {'Masons'}, setup = function(W) doors(W, 1) end}
  days(W2, 25)
  T.eq(#acts(W2, 'order_material'), 0)
  T.eq(#acts(W2, 'workorder', 'dfllm:redo_'), 0)
  T.eq(#acts(W2, 'order_remove'), 0)
  -- 0 boulders: the order itself is blocked ("no rock"), ORDER_STUCK's, not stale
  T.eq(#stuck(W2, 'stale'), 0)
end)

T.test('BUG-060: a stale wood order (the carpenters never take it) is made again in stone when stone is plentiful', function()
  local W = world{boulders = 40, wood = 40, setup = function(W)
    order(W, {job = 'ConstructCoffin', cat = {wood = true}, left = 3})
  end}
  days(W, 11)
  T.eq(#acts(W, 'order_material'), 0, 'already wood')
  local again = acts(W, 'workorder', 'dfllm:redo_')
  T.eq(#again, 1)
  T.eq({again[1].args[1].job, again[1].args[1].material, again[1].args[1].material_category},
       {'ConstructCoffin', 'INORGANIC', nil})
  T.ok(stuck(W, 'made again in stone')[1], 'the event says so')
  -- little stone: the wood order is made again in wood
  local W2 = world{boulders = 5, wood = 40, setup = function(W)
    order(W, {job = 'ConstructCoffin', cat = {wood = true}, left = 3})
  end}
  days(W2, 11)
  local a2 = acts(W2, 'workorder', 'dfllm:redo_')
  T.eq(#a2, 1)
  T.eq({a2[1].args[1].material, a2[1].args[1].material_category}, {nil, {'wood'}})
end)

T.test('BUG-060: the stale clock runs only in PEACE and RECOVERY', function()
  local W = world{boulders = 40, wood = 40, mode = 'SIEGE', setup = function(W) doors(W, 2) end}
  days(W, 15)
  T.eq(#acts(W, 'order_material'), 0)
  T.eq(#stuck(W, 'stale'), 0)
  local W2 = world{boulders = 40, wood = 40, mode = 'PEACE', setup = function(W) doors(W, 2) end}
  days(W2, 15)
  T.eq(#acts(W2, 'order_material'), 2, 'the same orders in PEACE')
end)

T.test('BUG-060: a stale order that waits behind a jam is reported with the jam as its reason', function()
  local W, ctl = world{boulders = 40, wood = 40, eco = {slabs = {max_orders = 3, restock_cap = 5, drop_per_day = 0,
                       trigger_ticks = 600, scan_max = 2000, jam_min = 3}}, setup = function(W) engrave(W, 4) end}
  local jobs = {}
  for i = 1, 4 do jobs[i] = {job_type = df.job_type.EngraveSlab, order_id = i, flags = {working = false}} end
  ctl.shops.Masons.jobs = kmock.vec(jobs)
  doors(W, 1)
  days(W, 12)
  local ev = stuck(W, 'stale')
  T.eq(#ev, 1)
  T.ok(ev[1].d.why:find("masons' slots full of cancelling jobs", 1, true), ev[1].d.why)
  T.ok(ev[1].msg:find('re-entered in wood', 1, true))
end)

---------------------------------------------------------------- FR-73
T.test('FR-73: from P1 the standing thread and cloth orders stand once their workshops do, monthly x30', function()
  local W = world{phase = 'P1', shops = {'Masons', 'Carpenters', 'Loom', 'Farmers'}}
  days(W, 3)
  local so = acts(W, 'workorder', 'dfllm:stand_')
  local by = {}
  for _, a in ipairs(so) do by[a.args[1].tag] = a.args[1] end
  local tags = {}
  for t in pairs(by) do tags[#tags + 1] = t end
  table.sort(tags)
  T.eq(tags, {'dfllm:stand_process', 'dfllm:stand_shear', 'dfllm:stand_spin', 'dfllm:stand_weave_plant',
              'dfllm:stand_weave_silk', 'dfllm:stand_weave_yarn'})
  T.eq(#so, 6, 'one each')
  for _, s in pairs(by) do T.eq({s.amount_total, s.frequency}, {30, 'Monthly'}) end
  T.eq({by['dfllm:stand_spin'].job, by['dfllm:stand_shear'].job, by['dfllm:stand_process'].job},
       {'SpinThread', 'ShearCreature', 'ProcessPlants'})
  T.eq(by['dfllm:stand_weave_yarn'].material_category, {'yarn'})
  T.eq(by['dfllm:stand_weave_yarn'].item_conditions,
       {{condition = 'AtLeast', value = 1, item_type = 'THREAD', flags = {'collected', 'yarn'}}})
  -- a monthly order sits at amount 0 between its months: no second one
  for _, o in ipairs(df.global.world.manager_orders.all) do o.amount_left = 0 end
  days(W, 40)
  T.eq(#acts(W, 'workorder', 'dfllm:stand_'), 6)
  -- the "Needs" pruner removes one: it waits orders.backoff_days, then comes back
  local gone
  for _, o in ipairs(df.global.world.manager_orders.all) do
    if o._spec and o._spec.tag == 'dfllm:stand_spin' then gone = o.id end
  end
  W.act_result('order_remove', function(id)
    local all = df.global.world.manager_orders.all
    for i = #all - 1, 0, -1 do if all[i].id == id then all:erase(i); return true end end
    return false
  end)
  W.K.act.order_remove(gone)
  days(W, 2)
  T.eq(#acts(W, 'workorder', 'dfllm:stand_spin'), 2, 'ordered again (no pruner backoff was set by this removal)')
end)

T.test('FR-73: nothing before P1; without a loom or a farmers\' shop only what can run; the shear order needs none', function()
  local W = world{phase = 'P0', shops = {'Masons', 'Carpenters', 'Loom', 'Farmers'}}
  days(W, 3)
  T.eq(#acts(W, 'workorder', 'dfllm:stand_'), 0)
  local W2 = world{phase = 'P1', shops = {'Masons', 'Carpenters'}}
  days(W2, 3)
  local so = acts(W2, 'workorder', 'dfllm:stand_')
  T.eq(#so, 1)
  T.eq(so[1].args[1].job, 'ShearCreature')
  local W3 = world{phase = 'P2', shops = {'Masons', 'Carpenters', 'Loom'}}
  days(W3, 3)
  T.eq(#acts(W3, 'workorder', 'dfllm:stand_'), 4, 'three weaves and the shear order')
end)

T.test('FR-73: no standing order is reported stuck for want of thread (they wait by design)', function()
  local W = world{phase = 'P1', shops = {'Masons', 'Carpenters', 'Loom', 'Farmers'}}
  days(W, 8)
  T.eq(#acts(W, 'workorder', 'dfllm:stand_'), 6)
  T.eq(#stuck(W), 0, 'no ORDER_STUCK for dfllm:stand_ orders')
end)

T.test('FR-73: no farmers\' shop at P1: PROJECT_REQUEST workshops why=farmers, every request_days, not while one is queued', function()
  local W = world{phase = 'P1', shops = {'Masons', 'Carpenters', 'Loom'}}
  days(W, 2)
  local ev = W.find_events('PROJECT_REQUEST')
  T.eq(#ev, 1)
  T.eq({ev[1].d.tpl, ev[1].d.why, ev[1].d.n}, {'workshops', 'farmers', 1})
  days(W, 10)
  T.eq(#W.find_events('PROJECT_REQUEST'), 1, 'request_days 14')
  days(W, 6)
  T.eq(#W.find_events('PROJECT_REQUEST'), 2)
  local W2 = world{phase = 'P0', shops = {'Masons'}}
  days(W2, 3)
  T.eq(#W2.find_events('PROJECT_REQUEST'), 0, 'not before P1')
  local W3 = world{phase = 'P1', shops = {'Masons', 'Farmers'}}
  days(W3, 3)
  T.eq(#W3.find_events('PROJECT_REQUEST'), 0, 'a farmers\' shop stands')
end)

T.done()
