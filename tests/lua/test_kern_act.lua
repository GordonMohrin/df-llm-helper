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
  T.eq(env.lines[1][3], '[{"cells":2,"command":"run","mode":"dig","pos":[60,40,120]}]', 'data summarized in commands.log')
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
  T.eq((env.api.setting('fps_cap', 100)), false, 'unknown setting')
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

T.test('military actions [S2]: create needs an assignment, add/remove, routine by name, orders', function()
  local W = H.world{tag = 'mil', units = {{id = 5, citizen = true, pos = {1, 1, 1}}}}
  local squads = {}
  dfhack.military.makeSquad = function(aid) local s = {id = 40 + aid, orders = kmock.vec{}, cur_routine_idx = 0}; squads[s.id] = s; return s end
  dfhack.military.addToSquad = function(uid, sid, pos) W.unit(uid).military.squad_id = sid; return true end
  dfhack.military.removeFromSquad = function(uid) W.unit(uid).military.squad_id = -1; return true end
  df.squad = {find = function(id) return squads[id] end}
  df.squad_order_movest = {new = function() return {pos = {}, kind = 'move', delete = function() end} end}
  df.squad_order_kill_listst = {new = function() return {units = kmock.vec{}, kind = 'kill', delete = function() end} end}
  df.global.plotinfo.alerts.routines = kmock.vec{{name = 'Off duty'}, {name = 'Staggered training'},
                                                  {name = 'Constant training'}, {name = 'Ready'}}
  local env = mk()
  env.who_v = 'military'
  T.eq({env.api.squad_create('A', {})}, {false, 'assignment_id required [S2]'})
  local ok, sid = env.api.squad_create('A', {assignment_id = 2})
  T.eq({ok, sid, squads[42].alias}, {true, 42, 'A'})
  T.eq({env.api.squad_add(42, 5)}, {true, 42})
  T.eq({env.api.squad_routine(42, 'constant training')}, {true, 2})
  T.eq(squads[42].cur_routine_idx, 2)
  T.eq((env.api.squad_routine(42, 'Off-duty-ish')), false)
  T.eq((env.api.squad_order(42, {kind = 'station', pos = {10, 11, 12}})), true)
  T.eq({squads[42].orders[0].kind, squads[42].orders[0].pos.z}, {'move', 12})
  T.eq((env.api.squad_order(42, {kind = 'kill', units = {77, 78}})), true)
  T.eq({#squads[42].orders, squads[42].orders[0].kind, #squads[42].orders[0].units}, {1, 'kill', 2}, 'new order replaces')
  T.eq((env.api.squad_order(42, {kind = 'train'})), true)
  T.eq(#squads[42].orders, 0)
  T.eq((env.api.squad_order(42, {kind = 'sortie'})), false)
  T.eq({env.api.squad_remove(42, 5)}, {true, nil})
  T.eq((env.api.squad_remove(42, 5)), false)
  T.eq((env.api.squad_uniform(42, {mode = 'replace'})), false, 'pending S2')
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
