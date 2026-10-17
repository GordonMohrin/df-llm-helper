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

T.test('work_detail opts (Run 10): a specialist leaves the everybody details; equip only when asked', function()
  local W = H.world{tag = 'wds', units = {{id = 7, citizen = true}}}
  local MINE, CUT, HAUL, PLANT, FEED = 0, 1, 2, 3, 4
  local function wd(name, labors, ids, mode)
    local al = setmetatable({}, {__len = function() return 5 end})
    for _, l in ipairs(labors) do al[l] = true end
    return {name = name, assigned_units = kmock.vec(ids), allowed_labors = al, flags = {mode = mode}}
  end
  df.work_detail_mode = {EverybodyDoesThis = 1, OnlySelectedDoesThis = 3}
  df.unit_labor = {FEED_WATER_CIVILIANS = FEED}
  local miners, cutters = wd('Miners', {MINE}, {}, 3), wd('Woodcutters', {CUT}, {}, 3)
  local planters, haulers = wd('Planters', {PLANT}, {7}, 1), wd('Haulers', {HAUL}, {7}, 1)
  local movers, orderly = wd('Movers', {HAUL}, {7}, 3), wd('Orderlies', {FEED}, {}, 1)
  df.global.plotinfo.labor_info = {work_details = kmock.vec{miners, cutters, planters, haulers, movers, orderly}}
  df.global.plotinfo.equipment = {update = {weapon = false}}
  local u = W.unit(7)
  u.status = {labors = {[PLANT] = true, [HAUL] = true, [FEED] = true}}
  u.uniform = {pickup_flags = {update = false}}
  local env = mk('economy')
  T.eq({env.api.work_detail('Miners', 7, true, {only = true, keep = {'FEED_WATER_CIVILIANS'}})}, {true, 'added'})
  T.eq({u.status.labors[MINE], u.status.labors[PLANT], u.status.labors[HAUL], u.status.labors[FEED]},
       {true, false, true, true}, 'PLANT off; HAUL from the selected Movers and the kept FEED stay')
  T.eq({#planters.assigned_units, #haulers.assigned_units, #movers.assigned_units}, {0, 0, 1},
       'out of the everybody details, still a selected mover')
  T.eq({u.uniform.pickup_flags.update, df.global.plotinfo.equipment.update.weapon}, {false, false},
       'no equipment request without opts.equip')
  T.eq({env.api.work_detail('Miners', 7, false, {only = true})}, {true, 'removed'})
  T.eq({u.status.labors[MINE], u.status.labors[PLANT]}, {false, true}, 'back to everybody work')
  T.eq({env.api.work_detail('Woodcutters', 7, true, {equip = true})}, {true, 'added'})
  T.eq({u.status.labors[CUT], u.uniform.pickup_flags.update, df.global.plotinfo.equipment.update.weapon},
       {true, true, true}, '[live-untested] the equipment update request with the tool labor')
  u.uniform.pickup_flags.update = false
  T.eq({env.api.work_detail('Woodcutters', 7, true, {equip = true})}, {true, 'already'})
  T.eq(u.uniform.pickup_flags.update, false, 'a member that has the labor is not asked again')
end)

-- BUG-023 (Run 11): one tool labor per dwarf (MINE, CUTWOOD, HUNT each want their own tool; the labors screen never
-- sets two): joining a tool detail switches off the other tool labors no detail grants; a second tool detail the unit
-- is a member of (the player's) keeps its labor
T.test('work_detail: joining Miners takes off a stray HUNT/CUTWOOD labor, a Hunters membership keeps HUNT', function()
  local W = H.world{tag = 'wdx', units = {{id = 7, citizen = true}, {id = 8, citizen = true}}}
  local MINE, CUT, HUNT = 0, 1, 2
  local function wd(name, labors, ids, mode)
    local al = setmetatable({}, {__len = function() return 3 end})
    for _, l in ipairs(labors) do al[l] = true end
    return {name = name, assigned_units = kmock.vec(ids), allowed_labors = al, flags = {mode = mode}}
  end
  df.work_detail_mode = {EverybodyDoesThis = 1, NobodyDoesThis = 2, OnlySelectedDoesThis = 3}
  df.unit_labor = {MINE = MINE, CUTWOOD = CUT, HUNT = HUNT}
  local hunters = wd('Hunters', {HUNT}, {8}, 3)
  df.global.plotinfo.labor_info = {work_details = kmock.vec{wd('Miners', {MINE}, {}, 3), wd('Woodcutters', {CUT}, {}, 3),
                                                              hunters}}
  local u7, u8 = W.unit(7), W.unit(8)
  u7.status = {labors = {[HUNT] = true, [CUT] = true}}
  u8.status = {labors = {[HUNT] = true}}
  local env = mk('economy')
  T.eq({env.api.work_detail('Miners', 7, true)}, {true, 'added'})
  T.eq({u7.status.labors[MINE], u7.status.labors[CUT], u7.status.labors[HUNT]}, {true, false, false},
       'no detail grants CUTWOOD or HUNT: off')
  T.eq({env.api.work_detail('Miners', 8, true)}, {true, 'added'})
  T.eq({u8.status.labors[MINE], u8.status.labors[HUNT]}, {true, true}, 'the player\'s Hunters membership keeps HUNT')
  hunters.flags.mode = 2                                               -- nobody does this: it grants nothing
  T.eq({env.api.work_detail('Miners', 8, true)}, {true, 'already'})
  T.eq(u8.status.labors[HUNT], false)
end)

-- Run 11 (Kilrudrabed, no gem vein): the zones screen's Sand zone, one tile, through quickfort zone mode (economy only)
T.test('sand_zone: a 1x1 dfllm-sand zone (quickfort zone key s) at the position; economy only', function()
  local W = H.world{tag = 'sz'}
  local calls = {}
  local n = 1
  W.scripts['quickfort'] = {apply_blueprint = function(p)
    calls[#calls + 1] = p
    return {zone_designated = {label = 'Zones designated', value = n}}
  end}
  local env = mk('economy')
  T.eq({env.api.sand_zone({20, 5, 100})}, {true, 1})
  T.eq({calls[1].mode, calls[1].command, calls[1].pos}, {'zone', 'run', {x = 20, y = 5, z = 100}})
  T.eq(calls[1].data[0][0][0], 's{name=dfllm-sand}')
  T.eq((mk('runner').api.sand_zone({20, 5, 100})), false, 'not owner')
  T.eq((env.api.sand_zone({20, 5})), false, 'bad position')
  n = 0
  T.eq({env.api.sand_zone({21, 5, 100})}, {false, 'quickfort designated no zone there'})
  T.eq(#calls, 2)
end)

-- Run 11 (Kilrudrabed: nobody fished, the kernel only read zones): the zones screen's Fishing zone over the water and,
-- with `up`, over the bank's level above it (economy only)
T.test('fish_zone: a side x side dfllm-fish zone (quickfort zone key f) centred on the water, up one level too', function()
  local W = H.world{tag = 'fz'}
  local calls = {}
  local n = 1
  W.scripts['quickfort'] = {apply_blueprint = function(p)
    calls[#calls + 1] = p
    return {zone_designated = {label = 'Zones designated', value = n}}
  end}
  local env = mk('economy')
  T.eq({env.api.fish_zone({80, 50, 99}, 3, true)}, {true, 2})
  T.eq({calls[1].mode, calls[1].pos, calls[2].pos}, {'zone', {x = 79, y = 49, z = 99}, {x = 79, y = 49, z = 100}})
  T.eq(calls[1].data[0][0][0], 'f{name=dfllm-fish}(3x3)')
  T.eq({env.api.fish_zone({60, 50, 100}, 3, false)}, {true, 1})
  T.eq(#calls, 3)
  T.eq((mk('runner').api.fish_zone({60, 50, 100}, 3)), false, 'not owner')
  T.eq((env.api.fish_zone({60, 50})), false, 'bad position')
  n = 0
  T.eq({env.api.fish_zone({61, 50, 100}, 9)}, {false, 'quickfort designated no zone there'})
  T.eq(calls[#calls].data[0][0][0], 'f{name=dfllm-fish}(7x7)', 'side capped at 7')
end)

T.done()
