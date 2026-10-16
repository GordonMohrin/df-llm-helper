-- WP1 act.lua: the only writer. Allowlist matching, owner checks, logging, ACT_FAIL, and every
-- implemented UI action against DF fakes (lever jobs, civ alert, quickfort, orders, kitchen, items...).
local T = require('testlib')
local H = require('kern_world')
local kmock = require('dfllm.util.k_mock')
local json = require('dfllm.util.json')
local actlib = require('dfllm.act')
local kern = require('dfllm.kern')

-- an act table with a settable caller, recording log lines and failures
local function mk(al)
  local env = {who_v = nil, lines = {}, fails = {}}
  env.api = actlib.new{
    who = function() return env.who_v end,
    allowlist = function() return al or actlib.BUILTIN_ALLOWLIST end,
    log_cmd = function(origin, what, args, result) env.lines[#env.lines + 1] = {origin, what, args, result} end,
    fail = function(fn, err, module) env.fails[#env.fails + 1] = {fn, err, module} end,
  }
  return env
end

local AL = {v = 2, armok_exceptions = {}, blocked = {'fastdwarf', 'caravan extend', '--instant', 'digv'},
            commands = {
              ['control-panel'] = {rw = 'w', args = {'enable *', 'disable *'}},
              ['labormanager'] = {rw = 'r', args = {'status'}},
              ['seedwatch'] = {rw = 'w', args = {'**'}},
              ['caravan'] = {rw = 'w', args = {'**'}},
              ['lever'] = {rw = 'w', args = {'pull **'}},
              ['uniform-unstick'] = {rw = 'w', args = {'--all --drop --free'}},
              ['combine'] = {rw = 'w', args = {}},
              ['prioritize'] = {rw = 'w', args = {'', '-a defaults'}},
            }}

T.test('allowlist: *, **, "", empty args, blocked prefixes and flags', function()
  local function ok(cmd, ...) return (actlib.allowed(AL, cmd, {...})) end
  T.ok(ok('control-panel', 'enable', 'autochop'))
  T.ok(not ok('control-panel', 'enable'))
  T.ok(not ok('control-panel', 'enable', 'a', 'b'))
  T.ok(ok('labormanager', 'status'))
  T.ok(not ok('labormanager', 'mode', 'modern'))
  T.ok(ok('seedwatch'))
  T.ok(ok('seedwatch', 'all', '12'))
  T.ok(ok('uniform-unstick', '--all --drop --free'), 'joined args are split into tokens')
  T.ok(ok('combine'))
  T.ok(not ok('combine', 'all'), 'empty args list allows only the bare command')
  T.ok(ok('prioritize'))
  T.ok(ok('prioritize', '-a', 'defaults'))
  T.ok(ok('caravan', 'list'))
  T.ok(not ok('caravan', 'extend'), 'blocked token prefix beats commands')
  T.ok(not ok('lever', 'pull', '--instant'), 'blocked flag anywhere')
  T.ok(not ok('lever', 'pull', '--instant=1'))
  T.ok(ok('lever', 'pull', '--id', '5'))
  T.ok(not ok('fastdwarf', '1'))
  T.ok(not ok('digv'))
  T.ok(not ok('lua', 'print(1)'), 'not allowlisted')
  T.ok(not ok('Bad Name'))
end)

T.test('armok cross-check removes allowlisted armok commands unless excepted', function()
  local al = json.decode(json.encode(AL))
  al.armok_exceptions = {'lever'}
  local removed = actlib.armok_filter(al, {'lever', 'combine', 'gui/gm-editor'})
  T.eq(removed, {'combine'})
  T.ok(al.commands.lever ~= nil)
  T.eq(al.commands.combine, nil)
end)

T.test('built-in allowlist is read-only; run() executes allowlisted commands only', function()
  H.world{tag = 'run'}
  local env = mk()
  T.eq({env.api.run('labormanager', 'status')}, {true, ''})
  local ok, err = env.api.run('control-panel', 'enable', 'autochop')
  T.eq(ok, false)
  T.ok(err:find('not allowlisted'))
  T.eq(#env.fails, 1)
  T.eq(env.lines[2][4]:sub(1, 3), 'ERR')
  local env2 = mk(AL)
  env2.who_v = 'selftest'
  T.eq((env2.api.run('labormanager', 'status')), true)
  T.eq((env2.api.run('seedwatch', 'all', '12')), false, 'selftest may only run read-only commands')
  env2.who_v = 'baseline'
  T.eq((env2.api.run('seedwatch', 'all', '12')), true)
  T.eq((env2.api.run('seedwatch', 7)), false, 'string args only')
end)

T.test('owners: contract.ACT decides; kern/test code may call anything; unknown functions raise', function()
  H.world{tag = 'owner'}
  local env = mk()
  env.who_v = 'runner'
  T.eq({env.api.popcap(60)}, {false, 'not owner'})
  env.who_v = 'readiness'
  T.eq((env.api.popcap(60)), true)
  T.eq(df.global.d_init.dwarf.population_cap, 60)
  T.eq((env.api.popcap(300)), false)
  T.raises(function() return env.api.make_items end, 'does not exist')
  T.eq(env.lines[1], {'runner', 'act.popcap', '[60]', 'ERR not owner'})
end)

T.test('pull: queues a PullLever job and returns its id; cancel only our own pending job', function()
  local W = H.world{tag = 'lever'}
  df.building_trapst = {is_instance = function(_, b) return b._trap == true end}
  df.trap_type, df.job_type = {Lever = 1}, {PullLever = 68}
  local next_job = 900
  W.scripts['lever'] = {leverPullJob = function(lever, prio)
    next_job = next_job + 1
    lever.jobs:insert('#', {id = next_job, job_type = df.job_type.PullLever, do_now = prio})
  end}
  local removed = {}
  dfhack.job = {removeJob = function(job)
    for b in pairs(W.buildings) do
      local lv = W.buildings[b]
      for i = #lv.jobs - 1, 0, -1 do if lv.jobs[i] == job then lv.jobs:erase(i) end end
    end
    removed[#removed + 1] = job.id
    return true
  end}
  -- k_mock.add_building deep-copies the spec, which loses DF-vector lengths: attach vectors afterwards
  local lever = W.add_building{id = 55, _trap = true, trap_type = 1}
  lever.jobs = kmock.vec{}
  W.add_building{id = 56}.jobs = kmock.vec{}
  local env = mk()
  env.who_v = 'gate'
  local ok, job = env.api.pull(55)
  T.eq({ok, job}, {true, 901})
  T.eq(lever.jobs[0].do_now, true, 'priority pull (lever.lua:4)')
  T.eq({env.api.pull(56)}, {false, 'not a lever'})
  T.eq({env.api.pull(99)}, {false, 'no building 99'})
  T.eq({env.api.cancel_own_lever_job(12345)}, {false, 'not our job'})
  T.eq({env.api.cancel_own_lever_job(901)}, {true, nil})
  T.eq(removed, {901})
  T.eq(#lever.jobs, 0)
  T.eq({env.api.cancel_own_lever_job(901)}, {false, 'not our job'}, 'only once')
  local _, j2 = env.api.pull(55)
  lever.jobs:erase(0)    -- the dwarf pulled it
  T.eq({env.api.cancel_own_lever_job(j2)}, {false, 'job no longer pending'})
end)

T.test('civ alert and alert burrows (gui/civ-alert API semantics)', function()
  local W = H.world{tag = 'alert'}
  local alerts = df.global.plotinfo.alerts
  alerts.list = kmock.vec{{burrows = kmock.vec{}}}
  W.scripts['gui/civ-alert'] = {
    sound_alarm = function() if #alerts.list >= 2 and #alerts.list[1].burrows > 0 then alerts.civ_alert_idx = 1 end end,
    clear_alarm = function() alerts.civ_alert_idx = 0 end,
    add_civalert_burrow = function(id)
      while #alerts.list < 2 do alerts.list:insert('#', {burrows = kmock.vec{}}) end
      local v, pos = alerts.list[1].burrows, #alerts.list[1].burrows
      for i = 0, #v - 1 do if v[i] > id then pos = i; break end end
      v:insert(pos, id)
    end,
    remove_civalert_burrow = function(id)
      local v = alerts.list[1].burrows
      for i = #v - 1, 0, -1 do if v[i] == id then v:erase(i) end end
      if #v == 0 then alerts.civ_alert_idx = 0 end
    end,
  }
  local kernb, deep = W.burrow('Kern+', {0, 0, 0, 10, 10, 10}), W.burrow('Tiefe+', {0, 0, 0, 1, 1, 1})
  local env = mk()
  env.who_v = 'siege'
  T.eq({env.api.civ_alert(true)}, {false, 'no alert burrows'})
  T.eq({env.api.alert_burrows({'Kern+'})}, {true, 1})
  T.eq((env.api.civ_alert(true)), true)
  T.eq(alerts.civ_alert_idx, 1)
  T.eq({env.api.alert_burrows({'Tiefe+'})}, {true, 1})
  T.eq(alerts.civ_alert_idx, 1, 'switching burrows keeps the alarm (add before remove)')
  T.eq({#alerts.list[1].burrows, alerts.list[1].burrows[0]}, {1, deep.id})
  T.eq({env.api.alert_burrows({'Nope+'})}, {false, 'no burrow Nope+'})
  T.eq((env.api.civ_alert(false)), true)
  T.eq(alerts.civ_alert_idx, 0)
  T.ok(kernb.id ~= deep.id)
end)

T.test('quickfort: params passed to apply_blueprint, stats flattened, bad input refused', function()
  local W = H.world{tag = 'qf'}
  local calls = {}
  W.scripts['quickfort'] = {apply_blueprint = function(p)
    calls[#calls + 1] = p
    return {dig_designated = {label = 'Tiles designated for digging', value = 2}, out_of_bounds = {label = 'x', value = 0}}
  end}
  local env = mk()
  env.who_v = 'runner'
  local ok, stats = env.api.quickfort{mode = 'dig', data = {[0] = {[0] = {[0] = 'd', [1] = 'd'}}}, pos = {60, 40, 120},
                                      priority = 3}
  T.ok(ok)
  T.eq(stats, {dig_designated = 2, out_of_bounds = 0})
  T.eq(calls[1].pos, {x = 60, y = 40, z = 120})
  T.eq({calls[1].mode, calls[1].command, calls[1].priority, calls[1].dry_run}, {'dig', 'run', 3, false})
  T.eq(env.lines[1][3], '[{"cells":2,"command":"run","mode":"dig","ms":0,"pos":[60,40,120]}]', 'data summarized in commands.log (ms = S6 cost)')
  T.eq((env.api.quickfort{mode = 'reveal', data = 'd'}), false)
  T.eq((env.api.quickfort{mode = 'dig', data = 'd', command = 'delete'}), false)
  T.eq((env.api.quickfort{mode = 'dig', data = 'd', priority = 9}), false)
  T.eq(#calls, 1)
end)

T.test('economy actions: orders import/sort, workorder tag and id, kitchen exclusion idempotent', function()
  local W = H.world{tag = 'eco'}
  local mo = df.global.world.manager_orders
  W.on_command = function(cmd, a, out, cr)
    if cmd == 'workorder' then
      local spec = json.decode(a[1])
      mo.all:insert('#', {id = mo.manager_order_next_id, job = spec.job})
      mo.manager_order_next_id = mo.manager_order_next_id + 1
      return 'Queuing ' .. spec.job, 0
    end
    return out, cr
  end
  local excl = {}
  dfhack.kitchen = {
    findExclusion = function(f, it, st, mt, mi) return excl[table.concat({next(f), it, st, mt, mi}, ':')] or -1 end,
    addExclusion = function(f, it, st, mt, mi) excl[table.concat({next(f), it, st, mt, mi}, ':')] = 0; return true end,
  }
  df.item_type = {PLANT = 53}
  local env = mk()
  env.who_v = 'economy'
  T.eq((env.api.orders_import('library/basic')), true)
  T.eq((env.api.orders_import('library/cheats')), false)
  T.eq((env.api.orders('sort')), true)
  T.eq((env.api.orders('clear')), false)
  T.eq({env.api.workorder{job = 'MakeCharcoal', amount_total = 5}}, {false, 'spec.tag must start with dfllm:'})
  T.eq({env.api.workorder{job = 'MakeCharcoal', amount_total = 5, tag = 'dfllm:fuel'}}, {true, 1})
  local last = W.commands[#W.commands]
  T.eq(last[1], 'workorder')
  T.eq(json.decode(last[2]).tag, nil, 'tag is not sent to workorder')
  T.eq({env.api.kitchen_exclude('PLANT', -1, 420, 0, 'Cook')}, {true, 'added'})
  T.eq({env.api.kitchen_exclude('PLANT', -1, 420, 0, 'Cook')}, {true, 'exists'})
  T.eq((env.api.kitchen_exclude('PLANT', -1, 420, 0, 'Eat')), false)
  T.eq((env.api.order_suspend(1, true)), false, 'no verified suspend flag')
  local cmds = {}
  for _, c in ipairs(W.commands) do cmds[#cmds + 1] = table.concat(c, ' ', 1, math.min(c.n, 3)) end
  T.eq(cmds[1], 'orders import library/basic')
  T.eq(cmds[2], 'orders sort')
end)

T.test('appoint: nobles screen records (assignment, histfig position link, assignments_by_type)', function()
  local H2 = require('kern_world')
  local W = H2.world{tag = 'appoint'}
  local vec = kmock.vec
  -- fort entity 321 at index 5 of world.entities.all; MANAGER (id 10) has MANAGE_PRODUCTION (4)
  local asg_mgr = {id = 6, position_id = 10, histfig = -1, histfig2 = -1}
  local asg_lead = {id = 8, position_id = 8, histfig = 4337, histfig2 = 4337}
  local ent = {id = 321,
               positions = {own = vec{{id = 8, code = 'EXPEDITION_LEADER', flags = {ACTIVE = true}, responsibilities = {[2] = true}},
                                      {id = 10, code = 'MANAGER', flags = {ACTIVE = true}, responsibilities = {[4] = true}},
                                      {id = 9, code = 'MAYOR', flags = {ACTIVE = false}, responsibilities = {}}},
                            assignments = vec{asg_lead, asg_mgr}},
               assignments_by_type = {[2] = vec{asg_lead}, [4] = vec{}}}
  df.global.plotinfo = df.global.plotinfo or {}
  df.global.plotinfo.main = {fortress_entity = ent}
  df.global.world.entities = {all = vec{{id = 1}, {id = 2}, {id = 3}, {id = 4}, {id = 5}, ent}}
  local hf = {id = 4188, entity_links = vec{}}
  df.historical_figure = {find = function(id) return id == 4188 and hf or nil end}
  df.histfig_entity_link_positionst = 'positionst'
  local units = {[18833] = {id = 18833, hist_figure_id = 4188}, [5] = {id = 5, hist_figure_id = 99}}
  local real_find = df.unit.find
  df.unit.find = function(id) return units[id] end
  local real = {isCitizen = dfhack.units.isCitizen, isAdult = dfhack.units.isAdult, isDead = dfhack.units.isDead}
  dfhack.units.isCitizen = function(u) return true end
  dfhack.units.isAdult = function(u) return u.id ~= 5 end
  dfhack.units.isDead = function(u) return false end
  local env = mk()
  env.who_v = 'economy'
  T.eq({env.api.appoint('MANAGER', 18833)}, {true, 6})
  T.eq({asg_mgr.histfig, asg_mgr.histfig2}, {4188, 4188})
  T.eq(#hf.entity_links, 1)
  local l = hf.entity_links[0]
  T.eq({l.new, l.entity_id, l.entity_vector_idx, l.assignment_id, l.assignment_vector_idx, l.link_strength},
       {'positionst', 321, 5, 6, 1, 100})
  T.eq(#ent.assignments_by_type[4], 1, 'DF finds the manager through assignments_by_type (live L1)')
  T.eq(ent.assignments_by_type[4][0].id, 6)
  T.eq({env.api.appoint('MANAGER', 18833)}, {true, 6}, 'idempotent')
  T.eq(#ent.assignments_by_type[4], 1)
  T.eq((env.api.appoint('MAYOR', 18833)), false, 'not offered yet')
  T.eq((env.api.appoint('MANAGER', 5)), false, 'children are no candidates')
  T.eq((env.api.appoint('manager', 18833)), false, 'bad code')
  env.who_v = 'care'
  T.eq({env.api.appoint('MANAGER', 18833)}, {false, 'not owner'})
  df.unit.find = real_find
  for k, f in pairs(real) do dfhack.units[k] = f end
end)

T.test('care actions: item flags (melt via dfhack.items), zone assignment like the zone screen', function()
  local W = H.world{tag = 'care', units = {{id = 7, pos = {1, 1, 1}}}}
  W.items_by_id = {[11] = {id = 11, flags = {forbid = false, dump = false}}}
  local melted = {}
  dfhack.items = {markForMelting = function(i) melted[i.id] = true; return true end,
                  cancelMelting = function(i) melted[i.id] = nil; return true end}
  df.general_ref_building_civzone_assignedst = {is_instance = function(_, r) return r._civzone == true end}
  df.new = function() return {_civzone = true} end
  W.unit(7).general_refs = kmock.vec{}
  local pit = W.add_building{id = 70}
  pit.assigned_units = kmock.vec{3, 9}
  local env = mk()
  env.who_v = 'care'
  T.eq((env.api.item_flag(11, 'forbid', true)), true)
  T.eq(W.items_by_id[11].flags.forbid, true)
  T.eq({env.api.item_flag(11, 'melt', true)}, {true, true})
  T.eq(melted[11], true)
  T.eq((env.api.item_flag(11, 'hidden', true)), false)
  T.eq((env.api.item_flag(99, 'dump', true)), false)
  T.eq((env.api.zone_assign(70, 7)), true)
  T.eq({pit.assigned_units[0], pit.assigned_units[1], pit.assigned_units[2]}, {3, 7, 9}, 'sorted insert')
  T.eq(W.unit(7).general_refs[0].building_id, 70)
  T.eq({env.api.zone_assign(70, 7)}, {false, 'unit already assigned'})
end)

T.test('economy work_detail: builtin tool details only, sorted membership, labors follow the detail', function()
  local W = H.world{tag = 'wd', units = {{id = 7, citizen = true}, {id = 8, citizen = true, adult = false}}}
  local MINE, CUT, HAUL = 0, 1, 2
  local function wd(name, labor, ids, mode)
    return {name = name, assigned_units = kmock.vec(ids), allowed_labors = {[0] = labor == MINE, [1] = labor == CUT,
            [2] = labor == HAUL}, flags = {mode = mode or 3}}
  end
  df.work_detail_mode = {EverybodyDoesThis = 1, OnlySelectedDoesThis = 3}
  df.global.plotinfo.labor_info = {work_details = kmock.vec{wd('Miners', MINE, {3, 9}), wd('Woodcutters', CUT, {}),
                                                              wd('Haulers', HAUL, {}, 1)}}
  -- a 3-entry bool array like DF's (allowed_labors is sized by unit_labor)
  for _, w in ipairs(df.global.plotinfo.labor_info.work_details) do
    setmetatable(w.allowed_labors, {__len = function() return 3 end})
  end
  W.unit(7).status = {labors = {}}
  local env = mk()
  env.who_v = 'care'
  T.eq({env.api.work_detail('Miners', 7, true)}, {false, 'not owner'})
  env.who_v = 'economy'
  T.eq({env.api.work_detail('Haulers', 7, true)}, {false, 'not a builtin tool detail: Haulers'})
  T.eq({env.api.work_detail('Miners', 8, true)}, {false, 'not an adult citizen'})
  T.eq({env.api.work_detail('Miners', 7, true)}, {true, 'added'})
  local v = df.global.plotinfo.labor_info.work_details[0].assigned_units
  T.eq({v[0], v[1], v[2]}, {3, 7, 9}, 'sorted insert')
  T.eq(W.unit(7).status.labors[MINE], true)
  T.eq({env.api.work_detail('Miners', 7, true)}, {true, 'already'})
  T.eq({env.api.work_detail('Miners', 7, false)}, {true, 'removed'})
  T.eq({#v, v[0], v[1]}, {2, 3, 9})
  T.eq(W.unit(7).status.labors[MINE], false)
  T.eq({env.api.work_detail('Miners', 9, false)}, {true, 'removed'}, 'a unit that left the fort is taken off')
  T.eq({env.api.work_detail('Woodcutters', 7, false)}, {true, 'not a member'})
end)

T.test('economy order_material: an open one-time rock furniture order is re-entered in wood (live L3)', function()
  local W = H.world{tag = 'om'}
  df.job_type = {ConstructDoor = 19, ConstructBed = 20, [19] = 'ConstructDoor', [20] = 'ConstructBed'}
  df.workquota_frequency_type = {OneTime = 0, Daily = 1}
  local mo = df.global.world.manager_orders
  local function order(id, jt, freq, mt, left)
    local o = {id = id, job_type = jt, frequency = freq, mat_type = mt, mat_index = -1, amount_left = left,
               material_category = {}}
    mo.all:insert('#', o)
    return o
  end
  local door = order(314, 19, 0, 0, 7)
  local daily = order(62, 19, 1, 0, 1)
  local bed = order(35, 20, 0, -1, 1)
  local done = order(319, 19, 0, 0, 0)
  local env = mk()
  env.who_v = 'runner'
  T.eq({env.api.order_material(314, 'wood')}, {false, 'not owner'})
  env.who_v = 'economy'
  T.eq({env.api.order_material(314, 'rock')}, {false, 'material must be wood'})
  T.eq({env.api.order_material(999, 'wood')}, {false, 'no order 999'})
  T.eq({env.api.order_material(62, 'wood')}, {false, 'repeating order'}, 'library orders keep their material')
  T.eq({env.api.order_material(35, 'wood')}, {false, 'no wood variant for this job'})
  T.eq({env.api.order_material(319, 'wood')}, {false, 'not an open rock order'})
  T.eq({env.api.order_material(314, 'wood')}, {true, 'wood'})
  T.eq({door.mat_type, door.mat_index, door.material_category.wood, door.amount_left}, {-1, -1, true, 7})
  T.eq({env.api.order_material(314, 'wood')}, {false, 'not an open rock order'}, 'once only')
  T.eq({daily.mat_type, bed.material_category.wood, done.mat_type}, {0, nil, 0})
end)

T.test('arbiter actions: settings return old values, timestream old fps, overlays, popups, pause', function()
  local W = H.world{tag = 'arb'}
  local env = mk()
  env.who_v = 'arbiter'
  T.eq({env.api.setting('gfps', 30)}, {true, 250})
  T.eq(df.global.enabler.gfps, 30)
  T.eq({env.api.setting('autosave', 'YEARLY')}, {true, 'SEASONAL'})
  T.eq(df.global.d_init.feature.autosave, df.d_init_autosave.YEARLY)
  T.eq((env.api.setting('autosave', 'NEVER')), false)
  T.eq((env.api.setting('gfps', 0)), false)
  T.eq({env.api.setting('weather', false)}, {true, true})
  T.eq({env.api.setting('fps_cap', 150)}, {true, 250}, 'the vanilla FPS cap (supply brake)')
  T.eq(df.global.enabler.fps, 150)
  T.eq((env.api.setting('fps_cap', 5)), false, 'cap range 10..1000')
  T.eq((env.api.setting('fps_magic', 100)), false, 'unknown setting')
  T.eq({env.api.timestream(500)}, {true, 250})
  T.eq(W.ts_fps, 500)
  T.eq((env.api.timestream(5)), false)
  T.eq({env.api.timestream(-1)}, {true, 500})
  T.eq({env.api.overlay('hotkeys.menu', false)}, {true, true})
  T.eq(W.ov['hotkeys.menu'].enabled, false)
  local ok, old = env.api.overlay({'hotkeys.menu', 'unsuspend.overlay'}, true)
  T.eq({ok, old}, {true, {['hotkeys.menu'] = false, ['unsuspend.overlay'] = true}})
  T.eq((env.api.overlay('bad name;x', true)), false)
  T.eq({env.api.dismiss_popup('tutorial')}, {false, 'no popup'})
  df.global.world.status.popups:insert('#', {text = 'hello'})
  T.eq({env.api.dismiss_popup('tutorial')}, {true, 'tutorial'})
  T.eq(#df.global.world.status.popups, 0)
  T.eq((env.api.set_paused(true)), true)
  T.eq(df.global.pause_state, true)
  env.api.set_paused(false)
end)

-- fort entity of the live L2 fort: MILITIA_COMMANDER (4, MILITARY_STRATEGY), MILITIA_CAPTAIN (5),
-- CAPTAIN_OF_THE_GUARD (7, a law squad); assignment 11 = the commander's
local function mil_world(W)
  local vec = kmock.vec
  local asg11 = {id = 11, position_id = 4, histfig = -1, histfig2 = -1, squad_id = -1, position_vector_idx = -1}
  local ent = {id = 321,
               positions = {own = vec{{id = 4, code = 'MILITIA_COMMANDER', squad_size = 10, flags = {ACTIVE = true},
                                       responsibilities = {MILITARY_STRATEGY = true}},
                                      {id = 5, code = 'MILITIA_CAPTAIN', squad_size = 10, flags = {ACTIVE = false},
                                       responsibilities = {}},
                                      {id = 7, code = 'CAPTAIN_OF_THE_GUARD', squad_size = 10, flags = {ACTIVE = false},
                                       responsibilities = {}}},
                            assignments = vec{{id = 9, position_id = 7, histfig = -1, squad_id = -1}, asg11},
                            next_assignment_id = 12},
               assignments_by_type = {MILITARY_STRATEGY = vec{}}}
  df.global.plotinfo.main = {fortress_entity = ent}
  df.global.plotinfo.group_id = 321
  df.global.plotinfo.equipment = {update = {}}
  df.global.world.entities = {all = vec{{id = 1}, ent}}
  df.entity_position_assignment = {new = function() return {flags = {}} end}
  df.histfig_entity_link_positionst = 'positionst'
  local hfs = {}
  df.historical_figure = {find = function(id) return hfs[id] end}
  local squads = {}
  df.squad = {find = function(id) return squads[id] end}
  dfhack.military.makeSquad = function(aid)
    for _, a in ipairs(ent.positions.assignments) do
      if a.id == aid and a.squad_id == -1 then
        local s = {id = 80 + aid, entity_id = 321, leader_assignment = aid, orders = vec{}, cur_routine_idx = 0,
                   positions = vec{}, ammo = {ammunition = vec{}, update = {}}, name = {}}
        for _ = 0, 9 do
          local u = {}
          for _, c in ipairs({'body', 'head', 'pants', 'gloves', 'shoes', 'shield', 'weapon'}) do u[c] = vec{} end
          s.positions:insert('#', {occupant = -1, equipment = {uniform = u, flags = {}}})
        end
        a.squad_id, squads[s.id] = s.id, s
        return s
      end
    end
  end
  for _, id in ipairs({5, 6, 7}) do
    hfs[100 + id] = {id = 100 + id, entity_links = vec{}}
    W.unit(id).hist_figure_id = 100 + id
  end
  return ent, squads, hfs, asg11
end

T.test('military actions [S2, live L2]: squads screen create + leader, captain assignments, add/remove, routine, orders', function()
  local W = H.world{tag = 'mil', units = {{id = 5, citizen = true, pos = {1, 1, 1}}, {id = 6, citizen = true, pos = {1, 1, 1}},
                                          {id = 7, citizen = true, pos = {1, 1, 1}}}}
  local ent, squads, hfs, asg11 = mil_world(W)
  dfhack.military.addToSquad = function(uid, sid, pos) W.unit(uid).military.squad_id = sid; return true end
  dfhack.military.removeFromSquad = function(uid) W.unit(uid).military.squad_id = -1; return true end
  df.squad_order_movest = {new = function() return {pos = {}, kind = 'move', delete = function() end} end}
  df.squad_order_kill_listst = {new = function() return {units = kmock.vec{}, kind = 'kill', delete = function() end} end}
  df.global.plotinfo.alerts.routines = kmock.vec{{name = 'Off duty'}, {name = 'Staggered training'},
                                                  {name = 'Constant training'}, {name = 'Ready'}}
  local env = mk()
  env.who_v = 'military'
  -- the first squad takes the vacant commander assignment (never the guard captain's), leader seated
  local ok, sid = env.api.squad_create('A', {leader = 5})
  T.eq({ok, sid, squads[91].alias}, {true, 91, 'A'})
  T.eq(asg11.squad_id, 91)
  T.eq({asg11.histfig, asg11.histfig2, asg11.position_vector_idx}, {105, 105, 0})
  T.eq(squads[91].positions[0].occupant, 105)
  T.eq({W.unit(5).military.squad_id, W.unit(5).military.squad_position}, {91, 0})
  local l = hfs[105].entity_links[0]
  T.eq({l.new, l.entity_id, l.entity_vector_idx, l.assignment_id, l.assignment_vector_idx}, {'positionst', 321, 1, 11, 1})
  T.eq(ent.assignments_by_type.MILITARY_STRATEGY[0].id, 11, 'the commander holds MILITARY_STRATEGY')
  T.eq(squads[91].ammo.update.weapon and df.global.plotinfo.equipment.update.armor, true, 'equipment update')
  -- the next squad gets a new militia captain assignment (the screen adds one per squad)
  ok, sid = env.api.squad_create('B', {})
  T.eq({ok, sid}, {true, 92})
  local a12 = ent.positions.assignments[2]
  T.eq({a12.id, a12.position_id, a12.squad_id, a12.histfig, ent.positions.next_assignment_id}, {12, 5, 92, -1, 13})
  T.eq(squads[92].positions[0].occupant, -1, 'no leader given')
  T.eq({env.api.squad_leader(92, 5)}, {false, 'unit is in a squad'})
  T.eq({env.api.squad_leader(92, 6)}, {true, 12})
  T.eq({env.api.squad_leader(92, 6)}, {true, 'already'})
  T.eq({env.api.squad_leader(92, 7)}, {false, 'leader already seated'})
  T.eq((env.api.squad_leader(99, 7)), false, 'no squad')
  T.eq(#ent.assignments_by_type.MILITARY_STRATEGY, 1, 'captains have no duty')
  T.eq({env.api.squad_create('X', {assignment_id = 11})}, {false, 'makeSquad failed'}, 'one squad per assignment')
  -- members, routine by name, orders
  T.eq({env.api.squad_add(92, 7)}, {true, 92})
  T.eq({env.api.squad_routine(92, 'constant training')}, {true, 2})
  T.eq(squads[92].cur_routine_idx, 2)
  T.eq((env.api.squad_routine(92, 'Off-duty-ish')), false)
  T.eq((env.api.squad_order(92, {kind = 'station', pos = {10, 11, 12}})), true)
  T.eq({squads[92].orders[0].kind, squads[92].orders[0].pos.z}, {'move', 12})
  T.eq((env.api.squad_order(92, {kind = 'kill', units = {77, 78}})), true)
  T.eq({#squads[92].orders, squads[92].orders[0].kind, #squads[92].orders[0].units}, {1, 'kill', 2}, 'new order replaces')
  T.eq((env.api.squad_order(92, {kind = 'train'})), true)
  T.eq(#squads[92].orders, 0)
  T.eq((env.api.squad_order(92, {kind = 'sortie'})), false)
  T.eq({env.api.squad_remove(92, 7)}, {true, nil})
  T.eq((env.api.squad_remove(92, 7)), false)
end)

T.test('squad_uniform [S2, live L2]: uniform specs per position and category, material class, ammo', function()
  local W = H.world{tag = 'uni', units = {{id = 5, citizen = true, pos = {1, 1, 1}}, {id = 6, citizen = true, pos = {1, 1, 1}},
                                          {id = 7, citizen = true, pos = {1, 1, 1}}}}
  local _, squads = mil_world(W)
  df.item_type = {ARMOR = 0, HELM = 1, SHIELD = 2, WEAPON = 3, AMMO = 4}
  df.entity_material_category = {Leather = 1, Armor = 16}
  df.global.world.raws = {itemdefs = {weapons = kmock.vec{{id = 'ITEM_WEAPON_AXE', subtype = 0},
                                                         {id = 'ITEM_WEAPON_CROSSBOW', subtype = 6}},
                                      ammo = kmock.vec{{id = 'ITEM_AMMO_BOLTS', subtype = 0}}}}
  local deleted = 0
  df.squad_uniform_spec = {new = function() return {indiv_choice = {}, delete = function() deleted = deleted + 1 end} end}
  df.squad_ammo_spec = {new = function() return {flags = {}} end}
  local env = mk()
  env.who_v = 'military'
  local _, sid = env.api.squad_create('C', {})
  local spec = {mode = 'replace', positions = {0, 1},
                items = {{cat = 'body', type = 'ARMOR', mat = 'metal'}, {cat = 'head', type = 'HELM', mat = 'leather'},
                         {cat = 'weapon', type = 'WEAPON', subtype = 'ITEM_WEAPON_CROSSBOW', mat = 'any'}},
                ammo = {type = 'AMMO', subtype = 'ITEM_AMMO_BOLTS', n = 100}}
  T.eq({env.api.squad_uniform(sid, spec)}, {true, 2})
  local p0, p2 = squads[sid].positions[0], squads[sid].positions[2]
  local b, h, w = p0.equipment.uniform.body[0], p0.equipment.uniform.head[0], p0.equipment.uniform.weapon[0]
  T.eq({b.item, b.item_type, b.item_subtype, b.material_class, b.mattype, b.matindex}, {-1, 0, -1, 16, -1, -1})
  T.eq(h.material_class, 1)
  T.eq({w.item_type, w.item_subtype, w.material_class}, {3, 6, -1})
  T.eq({p0.equipment.flags.replace_clothing, p0.equipment.flags.exact_matches}, {true, true})
  T.eq(#p2.equipment.uniform.body, 0, 'only the named positions')
  local a = squads[sid].ammo.ammunition[0]
  T.eq({a.item_type, a.item_subtype, a.amount, a.flags.use_combat, a.flags.use_training}, {4, 0, 100, true, true})
  T.eq({env.api.squad_uniform(sid, spec)}, {true, 2})
  T.eq({#p0.equipment.uniform.body, deleted, #squads[sid].ammo.ammunition}, {1, 6, 1}, 'replaced, ammo once')
  T.eq((env.api.squad_uniform(sid, {items = {{cat = 'tail', type = 'ARMOR'}}})), false)
  T.eq((env.api.squad_uniform(sid, {items = {{cat = 'weapon', type = 'WEAPON', subtype = 'ITEM_WEAPON_NOPE'}}})), false)
  T.eq((env.api.squad_uniform(424242, spec)), false)
end)

T.test('squad_unequip (live L6): squad equipment screen remove - specs, assigned items, quiver; weapon only', function()
  local W = H.world{tag = 'uneq', units = {{id = 5, citizen = true, pos = {1, 1, 1}}, {id = 6, citizen = true, pos = {1, 1, 1}},
                                           {id = 7, citizen = true, pos = {1, 1, 1}}}}
  local _, squads = mil_world(W)
  df.item_type = {ARMOR = 0, HELM = 1, SHIELD = 2, WEAPON = 3, AMMO = 4}
  df.global.world.raws = {itemdefs = {weapons = kmock.vec{{id = 'ITEM_WEAPON_AXE_BATTLE', subtype = 0}}}}
  local deleted = 0
  df.squad_uniform_spec = {new = function() return {indiv_choice = {}, assigned = kmock.vec{},
                                                     delete = function() deleted = deleted + 1 end} end}
  local env = mk()
  env.who_v = 'military'
  local _, sid = env.api.squad_create('A', {})
  for _, p in ipairs(squads[sid].positions) do
    p.equipment.assigned_items, p.equipment.quiver, p.equipment.backpack, p.equipment.flask = kmock.vec{}, -1, -1, -1
  end
  T.eq({env.api.squad_uniform(sid, {mode = 'replace', items = {{cat = 'body', type = 'ARMOR'},
                                                                {cat = 'weapon', type = 'WEAPON', subtype = 'ITEM_WEAPON_AXE_BATTLE'}}})},
       {true, 10})
  local p0, p1 = squads[sid].positions[0], squads[sid].positions[1]
  for _, p in ipairs({p0, p1}) do
    p.equipment.uniform.body[0].assigned:insert('#', 500)
    p.equipment.uniform.weapon[0].assigned:insert('#', 501)
    p.equipment.assigned_items:insert('#', 500); p.equipment.assigned_items:insert('#', 501)
  end
  p0.equipment.quiver = 502
  env.who_v = 'economy'
  T.eq({env.api.squad_unequip(sid)}, {false, 'not owner'})
  env.who_v = 'military'
  T.eq({env.api.squad_unequip(sid, {1}, {'weapon'})}, {true, 1}, 'the battle axe only')
  T.eq({#p1.equipment.uniform.weapon, #p1.equipment.uniform.body, #p1.equipment.assigned_items,
        p1.equipment.assigned_items[0]}, {0, 1, 1, 500})
  T.eq(#p0.equipment.uniform.weapon, 1, 'other positions untouched')
  T.eq({env.api.squad_unequip(sid, nil, {'tail'})}, {false, 'bad uniform category tail'})
  T.eq({env.api.squad_unequip(sid)}, {true, 4}, 'body + axe of position 0, the quiver, body of position 1')
  for _, p in ipairs(squads[sid].positions) do
    T.eq({#p.equipment.uniform.body, #p.equipment.uniform.weapon, #p.equipment.assigned_items, p.equipment.quiver},
         {0, 0, 0, -1})
  end
  T.eq(squads[sid].ammo.update.weapon, true, 'equipment update')
  T.eq((env.api.squad_unequip(4242)), false)
end)

T.test('BUG-023: a removed or replaced weapon spec gives its unheld item back to items_unassigned (no reservation left)', function()
  local W = H.world{tag = 'rel', units = {{id = 5, citizen = true, pos = {1, 1, 1}}, {id = 6, citizen = true, pos = {1, 1, 1}},
                                          {id = 7, citizen = true, pos = {1, 1, 1}}}}
  local _, squads = mil_world(W)
  df.item_type = {ARMOR = 0, HELM = 1, SHIELD = 2, WEAPON = 3, AMMO = 4, [0] = 'ARMOR', [1] = 'HELM', [2] = 'SHIELD',
                  [3] = 'WEAPON', [4] = 'AMMO'}
  df.global.world.raws = {itemdefs = {weapons = kmock.vec{{id = 'ITEM_WEAPON_PICK', subtype = 0},
                                                         {id = 'ITEM_WEAPON_SPEAR', subtype = 1}}}}
  df.squad_uniform_spec = {new = function() return {indiv_choice = {}, assigned = kmock.vec{}, delete = function() end} end}
  local items = {}
  for _, id in ipairs({501, 502, 503}) do items[id] = {id = id, getType = function() return 3 end} end
  local find0 = df.item.find
  df.item.find = function(id) return items[id] or find0(id) end
  local held = {[503] = true}
  dfhack.items = dfhack.items or {}
  local holder0 = dfhack.items.getHolderUnit
  dfhack.items.getHolderUnit = function(it) return held[it.id] and {id = 6} or nil end
  local env = mk()
  env.who_v = 'military'
  local _, sid = env.api.squad_create('A', {})
  local sq = squads[sid]
  df.global.world.squads = {all = kmock.vec{sq}}
  for _, p in ipairs(sq.positions) do p.equipment.assigned_items, p.equipment.quiver = kmock.vec{}, -1 end
  env.api.squad_uniform(sid, {mode = 'replace', positions = {0, 1, 2},
                              items = {{cat = 'weapon', type = 'WEAPON', subtype = 'ITEM_WEAPON_PICK'}}})
  for i, id in ipairs({501, 502, 503}) do
    local p = sq.positions[i - 1]
    p.equipment.uniform.weapon[0].assigned:insert('#', id)
    p.equipment.assigned_items:insert('#', id)
  end
  df.global.plotinfo.equipment = {items_assigned = {WEAPON = kmock.vec{501, 502, 503, 600}},
                                  items_unassigned = {WEAPON = kmock.vec{400, 700}}}
  local eq = df.global.plotinfo.equipment
  local function ids(v) local r = {} for _, x in ipairs(v) do r[#r + 1] = x end return r end
  -- the squads screen replaces position 0's pick by a spear: 501 leaves the position and the reservation
  T.eq((env.api.squad_uniform(sid, {mode = 'replace', positions = {0},
                                    items = {{cat = 'weapon', type = 'WEAPON', subtype = 'ITEM_WEAPON_SPEAR'}}})), true)
  T.eq(ids(sq.positions[0].equipment.assigned_items), {})
  T.eq({ids(eq.items_assigned.WEAPON), ids(eq.items_unassigned.WEAPON)}, {{502, 503, 600}, {400, 501, 700}})
  -- remove the weapon specs of positions 1 and 2: 502 goes back, 503 stays assigned (a soldier carries it)
  T.eq((env.api.squad_unequip(sid, {1, 2}, {'weapon'})), true)
  T.eq({ids(eq.items_assigned.WEAPON), ids(eq.items_unassigned.WEAPON)}, {{503, 600}, {400, 501, 502, 700}})
  df.item.find, dfhack.items.getHolderUnit = find0, holder0
end)

T.test('animal_slaughter (live L6): the animal sheet toggle for tame fort animals, never pets or citizens', function()
  local W = H.world{tag = 'slau', units = {{id = 5, citizen = true}, {id = 20, tame = true, animal = true},
                                           {id = 21, tame = true, animal = true}, {id = 22, animal = true},
                                           {id = 23, tame = true, animal = true, dead = true}}}
  for _, id in ipairs({5, 20, 21, 22, 23}) do
    W.unit(id).flags2 = {slaughter = false}
    W.unit(id).flags3 = {marked_for_gelding = true, available_for_adoption = false}
  end
  dfhack.units.isPet = function(u) return u.id == 21 end
  local env = mk()
  env.who_v = 'military'
  T.eq({env.api.animal_slaughter(20, true)}, {false, 'not owner'})
  env.who_v = 'economy'
  T.eq({env.api.animal_slaughter(20, true)}, {true, 'marked'})
  T.eq({W.unit(20).flags2.slaughter, W.unit(20).flags3.marked_for_gelding}, {true, false}, 'one mark at a time')
  T.eq({env.api.animal_slaughter(20, true)}, {true, 'already'})
  T.eq({env.api.animal_slaughter(21, true)}, {false, 'a pet'})
  T.eq({env.api.animal_slaughter(22, true)}, {false, 'not a tame fort animal'})
  T.eq({env.api.animal_slaughter(5, true)}, {false, 'not a living animal'})
  T.eq({env.api.animal_slaughter(23, true)}, {false, 'not a living animal'})
  T.eq({env.api.animal_slaughter(99, true)}, {false, 'no unit 99'})
  T.eq({env.api.animal_slaughter(20, false)}, {true, 'cleared'})
  T.eq(W.unit(20).flags2.slaughter, false)
end)

T.test('burrow_tiles (FR-33): burrows screen add + paint; seal only; new tiles counted; log line summarised', function()
  H.world{tag = 'btiles'}
  local bl = df.global.plotinfo.burrows
  bl.list, bl.next_id = kmock.vec{}, 7
  df.burrow = {new = function() return {} end}
  local set = {}
  local function k(b, p) return b.id .. ':' .. p.x .. ',' .. p.y .. ',' .. p.z end
  dfhack.burrows.findByName = function(n) for _, b in ipairs(bl.list) do if b.name == n then return b end end end
  dfhack.burrows.isAssignedTile = function(b, p) return set[k(b, p)] == true end
  dfhack.burrows.setAssignedTile = function(b, p, on) set[k(b, p)] = on; return true end
  local env = mk()
  env.who_v = 'siege'
  T.eq({env.api.burrow_tiles('Innen+', {{1, 2, 3}}, true)}, {false, 'not owner'})
  env.who_v = 'seal'
  T.eq({env.api.burrow_tiles('Innen+', {{1, 2, 3}})}, {false, 'no burrow Innen+'})
  T.eq({env.api.burrow_tiles('Innen+', {{1, 2, 3}, {1, 2, 3}, {4, 5, 6}}, true)}, {true, 2})
  T.eq({#bl.list, bl.list[0].id, bl.list[0].name, bl.next_id}, {1, 7, 'Innen+', 8})
  T.eq({env.api.burrow_tiles('Innen+', {{x = 4, y = 5, z = 6}, {7, 8, 9}})}, {true, 1})
  T.eq(#bl.list, 1, 'no second burrow')
  T.eq({env.api.burrow_tiles('Innen+;x', {})}, {false, 'bad burrow name'})
  local many = {}
  for i = 1, 2001 do many[i] = {i, 0, 0} end
  T.eq({env.api.burrow_tiles('Innen+', many)}, {false, 'need at most 2000 tiles'})
  local line = env.lines[3]
  T.eq({line[2], line[3]}, {'act.burrow_tiles', '["Innen+",{"first":[1,2,3],"tiles":3},true]'})
end)

T.test('door_forbid (FR-49/52, BUG-015): the door sheet lock; `close` also closes it; doors only; reflex only', function()
  local W = H.world{tag = 'dforbid'}
  df.building_type = df.building_type or {}
  df.building_type.Door = 23
  local d = W.add_building{id = 16970, door_flags = {forbidden = false, closed = false}}
  d.getType = function() return df.building_type.Door end
  local w = W.add_building{id = 16971}
  w.getType = function() return 99 end
  local env = mk()
  env.who_v = 'gate'
  T.eq({env.api.door_forbid(16970, true)}, {false, 'not owner'})
  env.who_v = 'reflex'
  T.eq({env.api.door_forbid(16971, true)}, {false, 'not a door'})
  T.eq({env.api.door_forbid(16970, true)}, {true, false})
  T.eq({d.door_flags.forbidden, d.door_flags.closed}, {true, false}, 'the plain lock leaves closed alone')
  T.eq({env.api.door_forbid(16970, false)}, {true, true})
  T.eq({env.api.door_forbid(16970, true, true)}, {true, false})
  T.eq({d.door_flags.forbidden, d.door_flags.closed}, {true, true}, 'the BUG-015 retry closes it too')
  T.eq({env.api.door_forbid(16970, false, true)}, {true, true})
  T.eq({d.door_flags.forbidden, d.door_flags.closed}, {false, true}, 'close only with on')
end)

T.test('zone_remove (live L6): only the zones of that dfllm-* name are deconstructed', function()
  local W = H.world{tag = 'zrm'}
  local gone = {}
  local zones = df.global.world.buildings.other.ACTIVITY_ZONE
  for i, n in ipairs({'dfllm-gather', 'Kern farm', 'dfllm-gather', ''}) do zones:insert('#', {id = 900 + i, name = n}) end
  dfhack.buildings = dfhack.buildings or {}
  dfhack.buildings.deconstruct = function(z) gone[#gone + 1] = z.id; return true end
  local env = mk()
  env.who_v = 'economy'
  T.eq({env.api.zone_remove('dfllm-gather')}, {false, 'not owner'})
  env.who_v = 'runner'
  T.eq({env.api.zone_remove('Kern farm')}, {false, 'zone name must be dfllm-*'})
  T.eq({env.api.zone_remove('dfllm-gather')}, {true, 2})
  T.eq(gone, {901, 903})
  T.eq({env.api.zone_remove('dfllm-none')}, {true, 0})
end)

T.test('link_lever [S3, live L2]: one LinkBuildingToTrigger job with two free reachable mechanisms', function()
  local W = H.world{tag = 'link'}
  local vec = kmock.vec
  df.building_trapst = {is_instance = function(_, b) return b._trap == true end}
  df.trap_type = {Lever = 1}
  df.job_type = {PullLever = 68, LinkBuildingToTrigger = 146}
  df.job_role_type = {LinkToTrigger = 3, LinkToTarget = 4}
  df.general_ref_type = {BUILDING_HOLDER = 1, BUILDING_TRIGGERTARGET = 2}
  local function bld(id, extra)
    local b = W.add_building{id = id}
    b.jobs, b.linked_mechanisms, b.stage = vec{}, vec{}, 1
    b.getBuildStage = function(self) return self.stage end
    b.getMaxBuildStage = function() return 1 end
    for k, v in pairs(extra or {}) do b[k] = v end
    return b
  end
  local lever = bld(55, {_trap = true, trap_type = 1, centerx = 10, centery = 10, z = 5})
  bld(60)
  local function mech(id, x, flags)
    local f = {}
    for k, v in pairs(flags or {}) do f[k] = v end
    return {id = id, _x = x, flags = f}
  end
  df.global.world.items.other.TRAPPARTS = vec{mech(1, 30), mech(2, 12), mech(3, 11, {forbid = true}),
                                               mech(4, 13, {in_building = true}), mech(5, 99)}
  local attached, refs, linked = {}, {}, 0
  dfhack.items = {getPosition = function(it) return it._x, 10, 5 end, getHolderUnit = function() return nil end,
                  getGeneralRef = function(m, t) return m._ref end}
  dfhack.maps = {canWalkBetween = function(a, b) return a.x ~= 99 end}
  df.job = {new = function() return {id = 777, general_refs = vec{}, delete = function() end} end}
  dfhack.job = {attachJobItem = function(j, it, role) attached[#attached + 1] = {it.id, role}; return true end,
                addGeneralRef = function(j, t, id) refs[#refs + 1] = {t, id} end,
                linkIntoWorld = function() linked = linked + 1 end, checkBuildingsNow = function() end}
  local env = mk()
  env.who_v = 'military'
  T.eq({env.api.link_lever(55, 60)}, {false, 'not owner'})
  env.who_v = 'gate'
  lever.stage = 0
  T.eq({env.api.link_lever(55, 60)}, {false, 'lever not built'})
  lever.stage = 1
  T.eq({env.api.link_lever(60, 55)}, {false, 'not a lever'})
  T.eq({env.api.link_lever(55, 60)}, {true, 777})
  T.eq(attached, {{2, 3}, {1, 4}}, 'nearest free reachable mechanisms; forbidden, built-in and unreachable ones skipped')
  T.eq(refs, {{1, 55}, {2, 60}})
  T.eq({#lever.jobs, lever.jobs[0].job_type, lever.jobs[0].pos.x, linked}, {1, 146, 10, 1})
  T.eq({env.api.link_lever(55, 60)}, {false, 'a link job is pending on this lever'})
  lever.jobs = vec{}
  lever.linked_mechanisms:insert('#', {_ref = {building_id = 60}})
  T.eq({env.api.link_lever(55, 60)}, {true, 'linked'})
  bld(56, {_trap = true, trap_type = 1, centerx = 10, centery = 10, z = 5})
  df.global.world.items.other.TRAPPARTS = vec{mech(9, 12)}
  T.eq({env.api.link_lever(56, 60)}, {false, 'needs 2 free reachable mechanisms, 1 found'})
end)

T.test('through the kernel: act lines in commands.log with the module, ACT_FAIL once per 1,200 ticks', function()
  local W = H.world{tag = 'kact'}
  local rd = {name = 'readiness', every = {ticks = 100}}
  function rd.step(K) K.act.popcap(500) end
  H.boot(W, {modules = {rd}})
  H.run(W, 1300)
  kern.stop()
  local af = H.find(H.events(W), 'ACT_FAIL')
  T.eq(#af, 2, 'at most once per 1,200 ticks')
  T.eq(af[1].d, {fn = 'popcap', err = 'cap must be 0..250', module = 'readiness'})
  local n = 0
  for _, l in ipairs(H.lines(W.sd .. '/commands.log')) do
    if l:find('\treadiness\tact.popcap\t[500]\tERR cap must be 0..250', 1, true) then n = n + 1 end
  end
  T.eq(n, 13, 'every call is logged')
end)

T.test('kernel loads config/allowlist.json and the armok list; falls back when missing', function()
  local W = H.world{tag = 'alcfg'}
  luahost.mkdir_recursive(W.dir .. '/config')
  H.write(W.dir .. '/config/allowlist.json', json.encode(AL))
  package.loaded['helpdb'] = {get_tag_data = function(tag) return {'combine', 'lever', description = 'armok'} end}
  local b = {name = 'baseline', every = {ticks = 33600}}
  H.boot(W, {modules = {b}})
  local K = kern.K()
  T.ok(K.cfg.allowlist.commands['control-panel'], 'file allowlist used')
  T.eq(K.cfg.allowlist.commands.combine, nil, 'armok command removed')
  T.eq(K.cfg.allowlist.commands.lever, nil, 'lever is not an exception here')
  T.ok(H.read(W.sd .. '/kern.log'):find('armok commands removed'))
  package.loaded['helpdb'] = nil
  kern.stop()
end)

T.done()
