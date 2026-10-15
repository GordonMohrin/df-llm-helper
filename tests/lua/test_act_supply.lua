-- act.lua: the UI actions added for FR-01/10/16/17/25/39/40 against DF fakes (work orders screen remove, job
-- resume, farm plot crop, gather designation, work detail list of living citizens) and their owner checks.
local T = require('testlib')
local H = require('kern_world')
local kmock = require('dfllm.util.k_mock')
local actlib = require('dfllm.act')

local function mk(who)
  local env = {lines = {}, fails = {}}
  env.api = actlib.new{
    who = function() return who end,
    allowlist = function() return actlib.BUILTIN_ALLOWLIST end,
    log_cmd = function(origin, what, args, result) env.lines[#env.lines + 1] = {origin, what, args, result} end,
    fail = function(fn, err, module) env.fails[#env.fails + 1] = {fn, err, module} end,
  }
  return env
end

T.test('order_remove: the order leaves the list (economy only)', function()
  H.world{tag = 'orem'}
  local mo = df.global.world.manager_orders
  local deleted = {}
  for id = 1, 3 do mo.all:insert('#', {id = id, delete = function(o) deleted[#deleted + 1] = o.id end}) end
  T.eq({mk('care').api.order_remove(2)}, {false, 'not owner'})
  local env = mk('economy')
  T.eq({env.api.order_remove(2)}, {true, 'removed'})
  T.eq({mo.all[0].id, mo.all[1].id, #mo.all}, {1, 3, 2})
  T.eq(deleted, {2})
  T.eq({env.api.order_remove(2)}, {false, 'no order 2'})
  T.eq(#env.fails, 1)
end)

T.test('FR-39: workorder refuses an item-definition job without item_subtype, sends it with one', function()
  local W = H.world{tag = 'wo39'}
  local mo = df.global.world.manager_orders
  W.on_command = function(cmd, a, out, cr)
    if cmd == 'workorder' then
      mo.all:insert('#', {id = mo.manager_order_next_id})
      mo.manager_order_next_id = mo.manager_order_next_id + 1
      return 'ok', 0
    end
    return out, cr
  end
  local env = mk('economy')
  local ok, err = env.api.workorder{job = 'MakePants', material_category = {'cloth'}, amount_total = 4, tag = 'dfllm:t'}
  T.eq(ok, false)
  T.ok(err:find('FR-39', 1, true), err)
  T.eq(#W.commands, 0)
  T.eq({env.api.workorder{job = 'MakePants', item_subtype = 'ITEM_PANTS_PANTS', material_category = {'cloth'},
                          amount_total = 4, tag = 'dfllm:t'}}, {true, 1})
end)

T.test('job_resume: only suspended ConstructBuilding jobs with the given ids', function()
  H.world{tag = 'jr'}
  df.job_type = {ConstructBuilding = 68, Dig = 1, [68] = 'ConstructBuilding', [1] = 'Dig'}
  local jobs = {{id = 1, job_type = 68, flags = {suspend = true}}, {id = 2, job_type = 68, flags = {suspend = true}},
                {id = 3, job_type = 1, flags = {suspend = true}}, {id = 4, job_type = 68, flags = {suspend = false}}}
  local head, cur = {}, nil
  cur = head
  for _, j in ipairs(jobs) do cur.next = {item = j}; cur = cur.next end
  df.global.world.jobs = {list = head}
  local env = mk('economy')
  T.eq({env.api.job_resume({1, 3, 4})}, {true, 1})
  T.eq({jobs[1].flags.suspend, jobs[2].flags.suspend, jobs[3].flags.suspend}, {false, true, true})
  T.eq((mk('runner').api.job_resume({2})), false)
end)

T.test('farm_crop: a farm plot\'s season slot, a known plant or -1', function()
  local W = H.world{tag = 'fc'}
  df.building_type = {FarmPlot = 7, Workshop = 8}
  df.global.world.raws = {plants = {all = kmock.vec{{id = 'A'}, {id = 'B'}}}}
  local plot = W.add_building{getType = function() return 7 end, plant_id = {[0] = -1, [1] = -1, [2] = -1, [3] = -1}}
  local shop = W.add_building{getType = function() return 8 end}
  local env = mk('economy')
  T.eq({env.api.farm_crop(plot.id, 2, 1)}, {true, 1})
  T.eq(plot.plant_id[2], 1)
  T.eq({env.api.farm_crop(plot.id, 4, 1)}, {false, 'season must be 0..3'})
  T.eq({env.api.farm_crop(plot.id, 0, 9)}, {false, 'no plant 9'})
  T.eq({env.api.farm_crop(shop.id, 0, 1)}, {false, 'not a farm plot'})
  T.eq({env.api.farm_crop(plot.id, 2, -1)}, {true, -1})
end)

T.test('plant_gather: shrubs at the positions get the gather designation, once', function()
  H.world{tag = 'pg'}
  local marked = {}
  local function shrub(x) return {pos = {x = x, y = 2, z = 3}} end
  local a, b, c = shrub(1), shrub(2), shrub(3)
  df.global.world.plants = {shrub_dry = kmock.vec{a, b}, shrub_wet = kmock.vec{c}}
  dfhack.designations = {isPlantMarked = function(p) return p == b end,
                         markPlant = function(p) marked[#marked + 1] = p.pos.x; return true end}
  local env = mk('economy')
  T.eq({env.api.plant_gather({{1, 2, 3}, {2, 2, 3}, {3, 2, 3}, {9, 9, 9}})}, {true, 2})
  T.eq(marked, {1, 3}, 'the already marked shrub is left alone')
  T.eq({env.api.plant_gather({})}, {true, 0})
  T.eq((env.api.plant_gather('x')), false)
end)

T.test('work_detail_prune: ids of dead or departed units leave every detail; insane citizens stay', function()
  local W = H.world{tag = 'wdp', units = {{id = 1, citizen = true}, {id = 2, citizen = true, dead = true},
                                          {id = 3, citizen = true, insane = true}}}
  local a = {name = 'Planters', assigned_units = kmock.vec{1, 2, 3, 40}}
  local b = {name = 'Haulers', assigned_units = kmock.vec{41}}
  df.global.plotinfo.labor_info = {work_details = kmock.vec{a, b}}
  local env = mk('economy')
  T.eq({env.api.work_detail_prune({1})}, {true, 3})
  T.eq({a.assigned_units[0], a.assigned_units[1], #a.assigned_units, #b.assigned_units}, {1, 3, 2, 0})
  T.eq((mk('military').api.work_detail_prune({1})), false)
end)

T.test('item_flag: economy and military may unforbid (FR-23/25/46/50)', function()
  local W = H.world{tag = 'if'}
  W.items_by_id = {[5] = {id = 5, flags = {forbid = true}}}
  T.eq({mk('economy').api.item_flag(5, 'forbid', false)}, {true, nil})
  T.eq(W.items_by_id[5].flags.forbid, false)
  T.eq((mk('military').api.item_flag(5, 'forbid', true)), true)
  T.eq((mk('trade').api.item_flag(5, 'forbid', false)), false)
end)

T.done()
