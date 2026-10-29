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

T.test('BUG-203: workorder top = true puts the new order first (made-again orders); top is no field of the order', function()
  local W = H.world{tag = 'wotop'}
  local mo = df.global.world.manager_orders
  for id = 1, 3 do mo.all:insert('#', {id = id}) end
  mo.manager_order_next_id = 4
  local bodies = {}
  W.on_command = function(cmd, a, out, cr)
    if cmd == 'workorder' then
      bodies[#bodies + 1] = a[1]
      mo.all:insert('#', {id = mo.manager_order_next_id})
      mo.manager_order_next_id = mo.manager_order_next_id + 1
      return 'ok', 0
    end
    return out, cr
  end
  local env = mk('economy')
  T.eq({env.api.workorder{job = 'ConstructDoor', amount_total = 1, tag = 'dfllm:redo_1', top = true}}, {true, 4})
  local ids = {}
  for i = 0, #mo.all - 1 do ids[#ids + 1] = mo.all[i].id end
  T.eq(ids, {4, 1, 2, 3}, 'old: appended at the end')
  T.ok(not tostring(bodies[1]):find('top', 1, true), bodies[1])
  T.eq({env.api.workorder{job = 'ConstructDoor', amount_total = 1, tag = 'dfllm:x'}}, {true, 5})
  T.eq(mo.all[#mo.all - 1].id, 5, 'without top: at the end as before')
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

T.test('plant_ungather (BUG-057/FR-72): the gather designation of the shrubs at the positions is cancelled', function()
  H.world{tag = 'pu'}
  local un = {}
  local function shrub(x) return {pos = {x = x, y = 2, z = 3}} end
  local a, b, c = shrub(1), shrub(2), shrub(3)
  df.global.world.plants = {shrub_dry = kmock.vec{a, b}, shrub_wet = kmock.vec{c}}
  dfhack.designations = {isPlantMarked = function(p) return p ~= b end,
                         unmarkPlant = function(p) un[#un + 1] = p.pos.x; return true end}
  local env = mk('economy')
  T.eq({env.api.plant_ungather({{1, 2, 3}, {2, 2, 3}, {3, 2, 3}, {9, 9, 9}})}, {true, 2})
  T.eq(un, {1, 3}, 'a shrub that is not marked is left alone')
  T.eq({env.api.plant_ungather({})}, {true, 0})
  T.eq((env.api.plant_ungather('x')), false)
  T.eq((mk('military').api.plant_ungather({{1, 2, 3}})), false, 'only economy')
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

-- BUG-038 (Run 11): the plant gatherers at food_low; a detail on "nobody does this" grants nothing, so opts.select sets
-- it to "only selected" (the work details screen's toggle); without opts.select or on another mode nothing changes
T.test('work_detail opts.select: a "nobody does this" detail becomes "only selected"; other modes stay', function()
  local W = H.world{tag = 'wdsel', units = {{id = 7, citizen = true}, {id = 8, citizen = true}}}
  local HERB = 2
  local function wd(name, ids, mode)
    local al = setmetatable({[HERB] = true}, {__len = function() return 3 end})
    return {name = name, assigned_units = kmock.vec(ids), allowed_labors = al, flags = {mode = mode}}
  end
  df.work_detail_mode = {EverybodyDoesThis = 1, NobodyDoesThis = 2, OnlySelectedDoesThis = 3}
  df.unit_labor = {HERBALIST = HERB}
  local g = wd('Plant gatherers', {}, 2)
  df.global.plotinfo.labor_info = {work_details = kmock.vec{g}}
  W.unit(7).status = {labors = {}}
  W.unit(8).status = {labors = {}}
  local env = mk('economy')
  T.eq({env.api.work_detail('Plant gatherers', 7, true)}, {true, 'added'})
  T.eq(g.flags.mode, 2, 'no opts.select: the mode stays')
  T.eq({env.api.work_detail('Plant gatherers', 8, true, {select = true})}, {true, 'added; only selected do this now'})
  T.eq({g.flags.mode, W.unit(8).status.labors[HERB]}, {3, true})
  g.flags.mode = 1
  T.eq({env.api.work_detail('Plant gatherers', 7, true, {select = true})}, {true, 'already'})
  T.eq(g.flags.mode, 1, 'everybody does this stays')
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

-- BUG-053 (Run 11/12: 16 and 100 free picks lay loose for 1081 and 144 days): the stockpiles screen's Weapons pile, a
-- w x h pile named dfllm-tools through quickfort place mode (economy only)
T.test('tool_pile: a w x h dfllm-tools weapons stockpile (quickfort place key p) at the position; economy only', function()
  local W = H.world{tag = 'tp'}
  local calls = {}
  local n = 1
  W.scripts['quickfort'] = {apply_blueprint = function(p)
    calls[#calls + 1] = p
    return {place_designated = {label = 'Stockpiles designated', value = n}}
  end}
  local env = mk('economy')
  T.eq({env.api.tool_pile({60, 40, 5}, 3, 2)}, {true, 1})
  T.eq({calls[1].mode, calls[1].command, calls[1].pos}, {'place', 'run', {x = 60, y = 40, z = 5}})
  T.eq(calls[1].data[0][0][0], 'p{name=dfllm-tools bins=0}(3x2)')
  T.eq({env.api.tool_pile({60, 40, 5})}, {true, 1})
  T.eq(calls[2].data[0][0][0], 'p{name=dfllm-tools bins=0}(3x2)', 'defaults 3 x 2')
  T.eq({env.api.tool_pile({60, 40, 5}, 9, 9)}, {true, 1})
  T.eq(calls[3].data[0][0][0], 'p{name=dfllm-tools bins=0}(5x5)', 'capped at 5 x 5')
  T.eq((mk('runner').api.tool_pile({60, 40, 5}, 3, 2)), false, 'not owner')
  T.eq((env.api.tool_pile({60, 40}, 3, 2)), false, 'bad position')
  n = 0
  T.eq({env.api.tool_pile({61, 40, 5}, 3, 2)}, {false, 'quickfort designated no stockpile there'})
  T.eq(#calls, 4)
  -- BUG-128: the stockpile the tools sit in as its source (the sheet's take-from link, by building id), no bins
  n = 1
  T.eq({env.api.tool_pile({60, 40, 5}, 3, 2, 77)}, {true, 1})
  T.eq(calls[5].data[0][0][0], 'p{name=dfllm-tools bins=0 take_from=77}(3x2)')
  T.ok(#calls[5].data[0][0][0] <= 64)
end)

T.test('order_top (Run 11 siege 8, seal first): the named orders move to the top in the given order (runner only)',
       function()
  H.world{tag = 'otop'}
  local mo = df.global.world.manager_orders
  for id = 1, 5 do mo.all:insert('#', {id = id}) end
  T.eq({mk('economy').api.order_top({4})}, {false, 'not owner'})
  local env = mk('runner')
  T.eq({env.api.order_top({5, 4, 9})}, {true, 2}, 'an id not in the list is skipped')
  local ids = {}
  for i = 0, #mo.all - 1 do ids[#ids + 1] = mo.all[i].id end
  T.eq(ids, {5, 4, 1, 2, 3})
  T.eq({env.api.order_top({})}, {false, 'need 1-32 order ids'})
  T.eq({env.api.order_top({'x'})}, {false, 'bad order id x'})
end)

-- A DFHack struct as df-structures defines it (library/xml/df.workquota.xml, df.d_basics.xml): DFHack raises on a read or
-- write of any field the structure does not list (LuaWrapper lookup_field: "Cannot write field X.y: not found."). The
-- fakes the other tests use accept anything, which hid that job_material_category has no `stone` bit.
local function dfstruct(name, fields, init, wrote)
  local data = {}
  for k, v in pairs(init or {}) do data[k] = v end
  return setmetatable({}, {
    __index = function(_, k)
      if k == 'delete' then return function() end end
      if not fields[k] then error('Cannot read field ' .. name .. '.' .. tostring(k) .. ': not found.') end
      return data[k]
    end,
    __newindex = function(_, k, v)
      if not fields[k] then error('Cannot write field ' .. name .. '.' .. tostring(k) .. ': not found.') end
      data[k] = v
      wrote[#wrote + 1] = name .. '.' .. k
    end})
end
local function set_of(list) local s = {} for _, k in ipairs(list) do s[k] = true end return s end
local MATCAT = set_of{'plant', 'wood', 'cloth', 'silk', 'leather', 'bone', 'shell', 'wood2', 'soap', 'tooth', 'horn', 'pearl',
                      'yarn', 'strand'}
local SPECDATA = set_of{'hist_figure_id', 'race', 'improvement', 'dye_object_desired_post_dye_color_index'}
local STATUS = set_of{'validated', 'active'}
local ORDER = set_of{'id', 'job_type', 'item_type', 'item_subtype', 'reaction_name', 'mat_type', 'mat_index', 'specflag',
                     'specdata', 'material_category', 'art_spec', 'amount_left', 'amount_total', 'status', 'frequency',
                     'finished_year', 'finished_year_tick', 'workshop_id', 'max_workshops', 'item_conditions',
                     'order_conditions', 'items'}
local function dfhack_order(wrote)
  return dfstruct('manager_order', ORDER, {
    item_type = -1, item_subtype = -1, mat_type = 0, mat_index = -1, workshop_id = 0, max_workshops = 0, amount_left = 0,
    amount_total = 0, frequency = -1, material_category = dfstruct('job_material_category', MATCAT, {}, wrote),
    specdata = dfstruct('job_spec_data', SPECDATA, {}, wrote), status = dfstruct('manager_order_status', STATUS, {}, wrote),
  }, wrote)
end

T.test('BUG-078: engrave_order makes one EngraveSlab order for the figure as autoslab does, on a struct that has only the real fields',
       function()
  H.world{tag = 'eng'}
  df.job_type = {EngraveSlab = 77, [77] = 'EngraveSlab'}
  df.item_type = {SLAB = 55, [55] = 'SLAB'}
  df.workquota_frequency_type = {OneTime = 0}
  df.historical_figure = {find = function(id) return (id == 6001 or id == 6002) and {id = id} or nil end}
  local mo = df.global.world.manager_orders
  local made, wrote = 0, {}
  df.manager_order = {new = function() made = made + 1; return dfhack_order(wrote) end}
  local env = mk('economy')
  T.eq({mk('care').api.engrave_order(6001)}, {false, 'not owner'})
  T.eq({env.api.engrave_order(-1)}, {false, 'a historical figure id is required'})
  local ok, id = env.api.engrave_order(6001)
  T.eq(ok, true, 'the order is made on a struct that lists the real fields only: ' .. tostring(id))
  local o = mo.all[#mo.all - 1]
  T.eq({o.id, o.job_type, o.amount_left, o.amount_total, o.specdata.hist_figure_id, o.status.validated, o.frequency,
        mo.manager_order_next_id}, {id, 77, 1, 1, 6001, false, 0, id + 1})
  -- autoslab.cpp createSlabJob sets id, job_type, specdata.hist_figure_id, amount_left, amount_total, frequency and nothing
  -- else; EngraveSlab has no `item` attribute in df.job.xml (ConstructSlab has SLAB), so item_type stays NONE
  T.eq(o.item_type, -1, 'the job names no item type')
  local names = {}
  for _, w in ipairs(wrote) do names[w] = true end
  for w in pairs(names) do
    T.ok(({['manager_order.id'] = 1, ['manager_order.job_type'] = 1, ['manager_order.amount_left'] = 1,
           ['manager_order.amount_total'] = 1, ['manager_order.frequency'] = 1, ['job_spec_data.hist_figure_id'] = 1,
           ['manager_order_status.validated'] = 1, ['manager_order_status.active'] = 1})[w], 'wrote ' .. w)
  end
  T.eq({env.api.engrave_order(6001)}, {true, 'already'}, 'one order per figure')
  T.eq(made, 1)
  -- workorder.lua refuses a figure that does not exist ("Missing historical figure for manager order"); so does this
  local n = #mo.all
  T.eq({env.api.engrave_order(9999)}, {false, 'no historical figure 9999'})
  T.eq({made, #mo.all}, {1, n}, 'and makes nothing')
  df.manager_order = {new = function() return setmetatable({delete = function() end}, {__newindex = function(t, k, v)
    if k == 'specdata' then error('no field specdata') end rawset(t, k, v) end,
    __index = function(t, k) if k == 'material_category' or k == 'status' then return {} end end}) end}
  local ok2, err = env.api.engrave_order(6002)
  T.eq(ok2, false)
  T.ok(tostring(err):find('no such field', 1, true), err)
  T.eq(#mo.all, n, 'nothing was added')
end)


-- BUG-119 (Run 14 note 75): "order.add EngraveSlab fails for 7 of 8 ghosts: manager_order has no such field ... act.lua:1497:
-- Cannot write field job_material_ca..." The note blamed the scan of the foreign orders. That text is the answer of the
-- WRITE block (BUG-090: material_category.stone); the scan reads in a pcall per order. These tests pin the scan: a foreign
-- order whose specdata faults on a read, a vector that faults midway, and the shape of the message.
local function order_env(tag)
  H.world{tag = tag}
  df.job_type = {EngraveSlab = 77, [77] = 'EngraveSlab', WeaveCloth = 12, [12] = 'WeaveCloth'}
  df.workquota_frequency_type = {OneTime = 0}
  df.historical_figure = {find = function(id) return id >= 6000 and id < 7000 and {id = id} or nil end}
  local mo = df.global.world.manager_orders
  local wrote = {}
  df.manager_order = {new = function() return dfhack_order(wrote) end}
  return mo, mk('economy')
end

T.test('BUG-119: a foreign order whose specdata faults on a read does not stop a memorial order', function()
  local mo, env = order_env('eng2')
  -- the live fort had 204 orders, 136 stuck: a union read raises DFHack-style on an order of another job
  local function foreign(id, jt, hf)
    return setmetatable({id = id, job_type = jt, amount_left = 3}, {__index = function(t, k)
      if k == 'specdata' then
        return setmetatable({}, {__index = function(_, f)
          if f == 'hist_figure_id' then error('Cannot write field job_material_category.stone: not found.') end
        end})
      end
    end})
  end
  mo.all:insert('#', foreign(1, 12, nil))
  mo.all:insert('#', {id = 2, job_type = 77, amount_left = 1, specdata = {hist_figure_id = 6001}})
  mo.all:insert('#', foreign(3, 77, nil))             -- an EngraveSlab order whose figure cannot be read: not the same
  mo.next_id = nil
  mo.manager_order_next_id = 4
  local ok, id = env.api.engrave_order(6732)
  T.eq({ok, id}, {true, 4}, 'made for the figure of note 75: ' .. tostring(id))
  T.eq({env.api.engrave_order(6001)}, {true, 'already'}, 'an order of the figure still stands')
  T.eq({env.api.engrave_order(6732)}, {true, 'already'}, 'and the new one counts')
  T.eq(#env.fails, 0)
end)

T.test('BUG-119: a vector that faults midway never raises out of the act; the order is made', function()
  local mo, env = order_env('eng3')
  local real = mo.all
  local n = 0
  mo.all = setmetatable({}, {__index = function(_, k)
    if type(k) == 'number' and k >= 1 then error('vector read fault') end
    return real[k]
  end, __len = function() return 3 end})
  mo.all.insert = function(_, where, o) n = n + 1 end
  local ok, made, res = pcall(env.api.engrave_order, 6487)
  T.eq({ok, made}, {true, true}, 'the order is made although the scan faulted: ' .. tostring(res))
  T.eq(n, 1, 'inserted once')
end)

T.test('BUG-133: slab_place = Build > Furniture > Slab with that slab chosen: a planned Slab building with the item; the ' ..
       'forbid toggle cleared, a slab in a job, built in, carried or unreachable refused; care only', function()
  local W = H.world{tag = 'slab'}
  df.item_type = {SLAB = 55, BOULDER = 3, [55] = 'SLAB', [3] = 'BOULDER'}
  df.building_type = df.building_type or {}
  df.building_type.Slab = 40
  local function slab(id, flags, t) return {id = id, flags = flags or {}, _pos = {12, 12, 5}, getType = function() return t or 55 end} end
  W.items_by_id = {[5] = slab(5, {forbid = true}), [6] = slab(6, {in_job = true}), [7] = slab(7, {in_building = true}),
                   [8] = slab(8, {in_inventory = true}), [9] = slab(9, {}, 3), [10] = slab(10)}
  dfhack.items = dfhack.items or {}
  dfhack.items.getPosition = function(it) return it._pos[1], it._pos[2], it._pos[3] end
  rawset(_G, 'xyz2pos', function(x, y, z) return {x = x, y = y, z = z} end)
  local walk = true
  dfhack.maps = dfhack.maps or {}
  dfhack.maps.canWalkBetween = function(a, b) return walk end
  local made = {}
  dfhack.buildings = dfhack.buildings or {}
  dfhack.buildings.constructBuilding = function(spec)
    if spec.x == 99 then return nil, 'cannot place' end
    made[#made + 1] = {spec.type, spec.x, spec.y, spec.z, #spec.items, spec.items[1].id, spec.items[1].flags.forbid}
    return {id = 700 + #made}
  end
  local env = mk('care')
  T.eq({mk('economy').api.slab_place(5, 20, 20, 5)}, {false, 'not owner'})
  T.eq({env.api.slab_place(5, 20, 21, 5)}, {true, 701})
  T.eq(made, {{40, 20, 21, 5, 1, 5, false}}, 'one planned Slab building holding that slab; unforbidden first')
  T.eq({env.api.slab_place(6, 20, 21, 5)}, {false, 'the slab is in job'})
  T.eq({env.api.slab_place(7, 20, 21, 5)}, {false, 'the slab is in building'})
  T.eq({env.api.slab_place(8, 20, 21, 5)}, {false, 'the slab is in inventory'})
  T.eq({env.api.slab_place(9, 20, 21, 5)}, {false, 'not a slab'})
  T.eq({env.api.slab_place(44, 20, 21, 5)}, {false, 'no item 44'})
  walk = false
  T.eq({env.api.slab_place(10, 20, 21, 5)}, {false, 'not reachable from the tile'})
  walk = true
  local ok, why = env.api.slab_place(10, 99, 21, 5)
  T.eq(ok, false)
  T.ok(why:find('the game refused the slab here: cannot place', 1, true), why)
  T.eq(#made, 1)
end)

T.done()
